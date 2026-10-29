-- =====================================================================
-- TrackAS database schema for Supabase
-- Run this whole file once in: Supabase Dashboard -> SQL Editor -> New query
--
-- Before running, in Dashboard -> Authentication -> Providers -> Email,
-- turn OFF "Confirm email" (the app signs the lecturer up and writes the
-- lecturer row in the same step, which needs an active session).
--
-- What this gives you:
--   * lecturers + classes tables
--   * Row Level Security: lecturers see/edit only their own data;
--     anonymous visitors (students) cannot read or write tables directly
--   * get_class_public(): the only way a student can read a class
--     (never exposes other students' names or matric numbers)
--   * mark_attendance(): the only way a student can record attendance.
--     It checks distance, time window and duplicates ON THE SERVER, and
--     appends atomically, so simultaneous scans never overwrite each other.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
create table if not exists public.lecturers (
  lecturer_id  uuid primary key default gen_random_uuid(),
  "fullName"   text not null,
  email        text not null unique,
  phone_number text,
  created_at   timestamptz not null default now()
);

create table if not exists public.classes (
  id            bigint generated always as identity primary key,
  course_id     uuid not null unique default gen_random_uuid(),
  lecturer_id   uuid not null references public.lecturers (lecturer_id) on delete cascade,
  course_title  text not null,
  course_code   text not null,
  location_name text,
  lat           double precision not null check (lat between -90 and 90),
  lng           double precision not null check (lng between -180 and 180),
  "time"        timestamptz not null,          -- class start (date + time combined by the app)
  date          timestamptz not null,
  note          text,
  qr_code       text,
  attendees     jsonb not null default '[]'::jsonb,

  -- attendance rules, adjustable per class
  radius_m              integer not null default 20  check (radius_m between 5 and 500),
  opens_before_minutes  integer not null default 30  check (opens_before_minutes >= 0),
  window_minutes        integer not null default 180 check (window_minutes > 0),

  created_at    timestamptz not null default now()
);

create index if not exists classes_lecturer_idx on public.classes (lecturer_id);

-- ---------------------------------------------------------------------
-- Helper: the lecturer_id of the logged-in user (matched by email)
-- ---------------------------------------------------------------------
create or replace function public.current_lecturer_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select lecturer_id
  from public.lecturers
  where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  limit 1;
$$;

-- ---------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------
alter table public.lecturers enable row level security;
alter table public.classes   enable row level security;

drop policy if exists lecturers_select_own on public.lecturers;
drop policy if exists lecturers_insert_own on public.lecturers;
drop policy if exists lecturers_update_own on public.lecturers;

create policy lecturers_select_own on public.lecturers
  for select to authenticated
  using (lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));

create policy lecturers_insert_own on public.lecturers
  for insert to authenticated
  with check (lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));

create policy lecturers_update_own on public.lecturers
  for update to authenticated
  using (lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')))
  with check (lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));

drop policy if exists classes_select_own on public.classes;
drop policy if exists classes_insert_own on public.classes;
drop policy if exists classes_update_own on public.classes;
drop policy if exists classes_delete_own on public.classes;

create policy classes_select_own on public.classes
  for select to authenticated
  using (lecturer_id = public.current_lecturer_id());

create policy classes_insert_own on public.classes
  for insert to authenticated
  with check (lecturer_id = public.current_lecturer_id());

create policy classes_update_own on public.classes
  for update to authenticated
  using (lecturer_id = public.current_lecturer_id())
  with check (lecturer_id = public.current_lecturer_id());

create policy classes_delete_own on public.classes
  for delete to authenticated
  using (lecturer_id = public.current_lecturer_id());

-- Students are anonymous: no direct table access at all.
revoke all on public.lecturers from anon;
revoke all on public.classes   from anon;

-- ---------------------------------------------------------------------
-- Distance in metres between two lat/lng points (Haversine)
-- ---------------------------------------------------------------------
create or replace function public.haversine_m(
  lat1 double precision, lng1 double precision,
  lat2 double precision, lng2 double precision
) returns double precision
language sql
immutable
as $$
  select 2 * 6371000 * asin(
    least(1, sqrt(
      power(sin(radians(lat2 - lat1) / 2), 2) +
      cos(radians(lat1)) * cos(radians(lat2)) *
      power(sin(radians(lng2 - lng1) / 2), 2)
    ))
  );
$$;

-- ---------------------------------------------------------------------
-- get_class_public: what a student may see about a class
-- ---------------------------------------------------------------------
create or replace function public.get_class_public(p_course_id uuid)
returns table (
  course_title  text,
  course_code   text,
  location_name text,
  class_time    timestamptz,
  note          text,
  lat           double precision,
  lng           double precision,
  radius_m      integer,
  is_open       boolean,
  opens_at      timestamptz,
  closes_at     timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    c.course_title, c.course_code, c.location_name, c."time", c.note,
    c.lat, c.lng, c.radius_m,
    now() between c."time" - make_interval(mins => c.opens_before_minutes)
              and c."time" + make_interval(mins => c.window_minutes),
    c."time" - make_interval(mins => c.opens_before_minutes),
    c."time" + make_interval(mins => c.window_minutes)
  from public.classes c
  where c.course_id = p_course_id;
$$;

-- ---------------------------------------------------------------------
-- mark_attendance: the only way to record attendance
--   * class must exist
--   * must be inside the attendance time window
--   * student must be within radius_m of the venue
--     (plus GPS accuracy, capped at 25 m so a bad fix cannot be abused)
--   * one record per matric number per class
--   * the row is locked while appending, so concurrent scans are safe
-- ---------------------------------------------------------------------
create or replace function public.mark_attendance(
  p_course_id uuid,
  p_matric_no text,
  p_name      text,
  p_lat       double precision,
  p_lng       double precision,
  p_accuracy  double precision default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c        public.classes%rowtype;
  v_matric text := upper(btrim(coalesce(p_matric_no, '')));
  v_name   text := upper(btrim(coalesce(p_name, '')));
  v_dist   double precision;
  v_slack  double precision := least(greatest(coalesce(p_accuracy, 0), 0), 25);
begin
  if v_matric = '' or length(v_matric) > 50 then
    raise exception 'A valid matriculation number is required.' using errcode = 'P0001';
  end if;
  if v_name = '' or length(v_name) > 100 then
    raise exception 'Your name is required.' using errcode = 'P0001';
  end if;
  if p_lat is null or p_lng is null
     or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Your location could not be read.' using errcode = 'P0001';
  end if;

  -- lock the class row so two students cannot overwrite each other
  select * into c from public.classes where course_id = p_course_id for update;
  if not found then
    raise exception 'Class not found.' using errcode = 'P0001';
  end if;

  if now() < c."time" - make_interval(mins => c.opens_before_minutes) then
    raise exception 'Attendance has not opened yet.' using errcode = 'P0001';
  end if;
  if now() > c."time" + make_interval(mins => c.window_minutes) then
    raise exception 'Attendance for this class is closed.' using errcode = 'P0001';
  end if;

  v_dist := public.haversine_m(p_lat, p_lng, c.lat, c.lng);
  if v_dist > c.radius_m + v_slack then
    raise exception 'You are % m from the venue; you must be within % m.',
      round(v_dist)::int, c.radius_m using errcode = 'P0001';
  end if;

  if exists (
    select 1 from jsonb_array_elements(c.attendees) a
    where a ->> 'matric_no' = v_matric
  ) then
    raise exception 'This matriculation number has already been registered.' using errcode = 'P0001';
  end if;

  update public.classes
  set attendees = attendees || jsonb_build_array(jsonb_build_object(
        'matric_no', v_matric,
        'name',      v_name,
        'timestamp', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
        'distance_m', round(v_dist::numeric, 1)
      ))
  where id = c.id;

  return jsonb_build_object('ok', true, 'distance_m', round(v_dist::numeric, 1));
end;
$$;

-- Only expose the two student-facing functions to anonymous users.
revoke all on function public.get_class_public(uuid) from public;
revoke all on function public.mark_attendance(uuid, text, text, double precision, double precision, double precision) from public;
grant execute on function public.get_class_public(uuid) to anon, authenticated;
grant execute on function public.mark_attendance(uuid, text, text, double precision, double precision, double precision) to anon, authenticated;
