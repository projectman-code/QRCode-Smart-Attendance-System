import { useLocation, useNavigate } from "react-router-dom";
import { useCallback, useEffect, useState } from "react";
import { calculateDistance } from "../utils/distanceCalculation";
import Input from "../component/Input";
import { supabase } from "../utils/supabaseClient";
import toast from "react-hot-toast";
import Spinner from "../component/Spinner";
import dayjs from "dayjs";
import logo from "../../public/trackAS.png";

// Ask the browser for a fresh, high-accuracy GPS fix.
const getPosition = () =>
  new Promise((resolve, reject) => {
    if (!navigator.geolocation) {
      reject(new Error("Geolocation is not supported by this browser."));
      return;
    }
    navigator.geolocation.getCurrentPosition(
      (p) =>
        resolve({
          lat: p.coords.latitude,
          lng: p.coords.longitude,
          accuracy: p.coords.accuracy,
        }),
      (err) => reject(new Error(err.message)),
      { enableHighAccuracy: true, timeout: 15000, maximumAge: 0 }
    );
  });

const StudentLogin = () => {
  const location = useLocation();
  const navigate = useNavigate();
  const courseId = new URLSearchParams(location.search).get("courseId");

  const [isLoading, setIsLoading] = useState(false);
  const [classInfo, setClassInfo] = useState(null);
  const [loadError, setLoadError] = useState("");
  const [position, setPosition] = useState(null);
  const [matricNumber, setMatricNumber] = useState("");
  const [name, setName] = useState("");

  // The class details (including the venue coordinates) come from the
  // database, not from the link, so editing the link changes nothing.
  useEffect(() => {
    const fetchClassDetails = async () => {
      if (!courseId) {
        setLoadError("This attendance link is not valid.");
        return;
      }
      const { data, error } = await supabase.rpc("get_class_public", {
        p_course_id: courseId,
      });
      if (error || !data || data.length === 0) {
        setLoadError("This attendance link is not valid.");
        return;
      }
      setClassInfo(data[0]);
    };

    fetchClassDetails();
  }, [courseId]);

  const refreshPosition = useCallback(async () => {
    try {
      const p = await getPosition();
      setPosition(p);
      return p;
    } catch (e) {
      toast.error(`Error getting your location: ${e.message}`);
      return null;
    }
  }, []);

  useEffect(() => {
    refreshPosition();
  }, [refreshPosition]);

  const userDistance =
    classInfo && position
      ? calculateDistance(position.lat, position.lng, classInfo.lat, classInfo.lng)
      : null;
  const radius = classInfo?.radius_m ?? 20;
  // Display only. The server repeats this check and is the one that decides.
  const isWithinRange = userDistance !== null && userDistance <= radius + 25;
  const isOpen = classInfo?.is_open ?? false;

  const handleRegister = async (e) => {
    e.preventDefault();

    if (!name.trim()) {
      toast.error("Your name is required.");
      return;
    }
    if (!matricNumber.trim()) {
      toast.error("Matriculation number is required.");
      return;
    }

    setIsLoading(true);

    // Use a fresh GPS reading at the moment of submitting.
    const p = await refreshPosition();
    if (!p) {
      setIsLoading(false);
      return;
    }

    const { error } = await supabase.rpc("mark_attendance", {
      p_course_id: courseId,
      p_matric_no: matricNumber,
      p_name: name,
      p_lat: p.lat,
      p_lng: p.lng,
      p_accuracy: p.accuracy,
    });

    setIsLoading(false);

    if (error) {
      toast.error(error.message);
      return;
    }

    toast.success("Attendance marked successfully.");
    setMatricNumber("");
    setName("");
    navigate("/success", { replace: true });
  };

  if (loadError) {
    return (
      <section className="studentLogin h-screen grid place-items-center">
        <div className="bg-white px-6 py-4 rounded-xl text-center">
          <img src={logo} alt="logo" className="mx-auto" />
          <p className="text-red-500 font-semibold mt-4">{loadError}</p>
        </div>
      </section>
    );
  }

  return (
    <section className="studentLogin h-screen grid place-items-center ">
      <div className="bg-white px-6 py-4 md:px-16 max-w-3xl  rounded-xl">
        <div className="items-center flex self-center justify-center">
          <img src={logo} alt="logo" />
        </div>
        <h2 className="text-[2.5rem] text-[#000D46] text-center font-bold mb-2">
          TrackAS
        </h2>
        {classInfo && (
          <div className="flex justify-between items-center">
            <div>
              <p className="text-[#000D46] font-bold">
                Title: {classInfo.course_title}
              </p>
              <p className="text-[#000D46]  font-bold">
                Code: {classInfo.course_code}
              </p>
              <p className="text-[#000D46]  font-bold">
                Venue: {classInfo.location_name}
              </p>
              <p className="text-[#000D46]  font-bold">
                Date: {dayjs(classInfo.class_time).format("DD MMMM, YYYY")}
              </p>
              <p className="text-[#000D46]  font-bold">
                Time: {dayjs(classInfo.class_time).format("hh:mm A")}
              </p>
              {classInfo.note && (
                <p className="text-[#000D46] mb-2 text-lg font-bold">
                  Note: {classInfo.note}
                </p>
              )}
              <p>
                Distance to Lecture Venue:{" "}
                {userDistance !== null
                  ? `${userDistance.toFixed(2)} meters`
                  : "Calculating..."}
              </p>
              {position?.accuracy ? (
                <p className="text-xs text-gray-500">
                  GPS accuracy: about {Math.round(position.accuracy)} m
                </p>
              ) : null}
            </div>
          </div>
        )}
        <form onSubmit={handleRegister}>
          <Input
            type="text"
            name="name"
            label="Name"
            placeholder={"Enter your name"}
            value={name}
            onChange={(e) => setName(e.target.value)}
          />

          <Input
            type="text"
            name="matricNumber"
            label="Matriculation Number"
            placeholder={"Your matriculation number"}
            value={matricNumber}
            onChange={(e) => setMatricNumber(e.target.value)}
          />

          {classInfo && !isOpen ? (
            <p className="text-xs text-red-500 pt-2">
              Attendance is not open for this class right now. It is open from{" "}
              {dayjs(classInfo.opens_at).format("DD MMM, hh:mm A")} to{" "}
              {dayjs(classInfo.closes_at).format("DD MMM, hh:mm A")}.
            </p>
          ) : isWithinRange ? (
            <button
              className="btn my-5 btn-block text-lg"
              type="submit"
              disabled={isLoading}
            >
              {isLoading ? <Spinner /> : "Mark Attendance"}
            </button>
          ) : (
            <p className="text-xs text-red-500 pt-2">
              You must be within {radius} meters of the lecture venue to
              register.
            </p>
          )}
        </form>
      </div>
    </section>
  );
};

export default StudentLogin;
