/** Static explanations of the method (plan 02 §7–§11), shown on the Method page. */
export const PIPELINE_STEPS = [
  { title: "Capture", text: "An iPhone records motion at 100 Hz, GPS, barometer and labels to local files first." },
  { title: "Transmit", text: "After the trip the session folder is uploaded to S3; live batches go through API Gateway into Kinesis." },
  { title: "Process", text: "The same Python code (batch and live) aligns clocks and axes, checks quality and computes the metrics." },
  { title: "Store", text: "Results — not raw samples — go to PostgreSQL + PostGIS; raw data stays in S3 as Parquet." },
  { title: "Visualize", text: "This dashboard reads the results through a read-only API." },
] as const;

export const METHOD_SECTIONS = [
  {
    title: "Road segments",
    points: [
      "Every GPS point is assigned to an H3 hexagon of about 25 m, so different trips on the same street land in the same cells.",
      "One observation is stored per session, segment and pass; the map combines all of them.",
    ],
  },
  {
    title: "Road roughness",
    points: [
      "Vertical acceleration is band-passed (about 1–30 Hz) and its RMS computed per segment pass, together with the speed.",
      "A bus and a car feel the same road differently, so one model is fitted over all observations: log(roughness) = segment + vehicle + β·log(speed).",
      "The map shows what a reference car would feel at 36 km/h. With too little overlap between vehicles it falls back to per-session percentiles.",
    ],
  },
  {
    title: "Potholes and speed bumps",
    points: [
      "A pothole is a sharp jump in high-passed vertical acceleration, counted only above 15 km/h; a speed bump is a double peak in pitch rate (front axle, then rear axle).",
      "Detections are scored against the passenger's taps within ±1.5 s (precision and recall).",
      "A pothole is confirmed on the map when it was detected in at least k of n passes, with thresholds per vehicle type. Tram rail joints are labelled separately.",
    ],
  },
  {
    title: "Motion sickness",
    points: [
      "Vertical acceleration is weighted with the ISO 2631-1 Wf filter; the motion sickness dose value is MSDV = √(∫ a_w² dt).",
      "Roughly MSDV / 3 percent of unadapted people may vomit. The prediction is compared with the passengers' MISC ratings (0–10).",
      "Sickness is not normalized across vehicles: “the bus is worse than the car on this route” is a finding. Results are split by seat and by seated or standing.",
      "Known limit: the ISO metric only covers up-and-down motion, while sideways sway in cars is a strong cause of sickness.",
    ],
  },
  {
    title: "Data quality and privacy",
    points: [
      "Windows are invalid when “phone moved” was tapped, gravity drifts in the phone frame, or the gyro's turn rate disagrees with GPS.",
      "Hand-held or loose mounts are excluded from roughness; replays and bad sessions are never counted in the map.",
      "Tracks are trimmed near the start and end of every trip; audio is never uploaded live and is off on public transport.",
    ],
  },
] as const;
