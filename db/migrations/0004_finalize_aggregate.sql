-- Finalize and aggregation (plan §5 "Finalize job", §8, §9 "Across sessions").
--
-- The finalize job rebuilds a finished trip from the raw archive, replaces its live results and
-- writes one segment observation per H3 cell pass. The aggregation step rebuilds segments,
-- segment_agg, segment_sickness and aggregation_fit from every included trip's observations.
-- New tables get the writer/reader grants from the default privileges set by the migrate job.

ALTER TABLE sessions
    ADD COLUMN finalized_at   timestamptz,       -- last successful finalize
    ADD COLUMN ready_sent_at  timestamptz,       -- "session ready" put on the queue (resent if stuck)
    ADD COLUMN valid_fraction double precision,  -- 0–1, from the finalize job's quality checks
    ADD COLUMN distance_m     double precision,  -- length of the GPS track
    ADD COLUMN quality        jsonb;             -- the finalize job's quality measurements

-- One row per pass of a trip through an H3 cell (resolution 11, ≈ 25 m). Raw values as measured;
-- normalization happens only in the aggregation step (plan §8).
CREATE TABLE segment_observations (
    session_id       text NOT NULL REFERENCES sessions (session_id) ON DELETE CASCADE,
    pass_idx         integer NOT NULL,
    h3               text NOT NULL,
    t_start          timestamptz NOT NULL,
    duration_s       double precision NOT NULL,
    mean_speed_ms    double precision,           -- over the same (moving) windows as roughness_rms
    roughness_rms    double precision,           -- m/s², 1–30 Hz vertical; null when hardly moving
    aw_rms           double precision NOT NULL,  -- m/s², ISO 2631-1 Wf vertical
    pothole_count    integer NOT NULL DEFAULT 0,
    n_windows        integer NOT NULL,           -- 0.2 s series windows in the pass
    in_privacy_zone  boolean NOT NULL DEFAULT false,  -- first or last 200 m of the trip
    PRIMARY KEY (session_id, pass_idx)
);
CREATE INDEX segment_observations_h3_idx ON segment_observations (h3);

-- Every cell with at least one aggregated observation, with its hexagon for the map.
CREATE TABLE segments (
    h3        text PRIMARY KEY,
    center    geography (Point, 4326) NOT NULL,
    boundary  geography (Polygon, 4326) NOT NULL
);

-- segment × vehicle type, plus an 'all' row (API.md SegmentAggregate).
CREATE TABLE segment_agg (
    h3                 text NOT NULL REFERENCES segments (h3) ON DELETE CASCADE,
    vehicle_type       text NOT NULL,
    n_sessions         integer NOT NULL,
    n_passes           integer NOT NULL,
    mean_speed_kmh     double precision,
    roughness          double precision,
    roughness_pctl     double precision,
    roughness_method   text NOT NULL CHECK (roughness_method IN ('model', 'percentile', 'none')),
    pothole_hits       integer NOT NULL,
    pothole_passes     integer NOT NULL,
    pothole_ratio      double precision,
    pothole_confirmed  boolean NOT NULL,
    sickness_aw_rms    double precision,
    msi_1h_pct         double precision,
    sickness_sessions  integer NOT NULL,
    PRIMARY KEY (h3, vehicle_type)
);

-- Sickness by vehicle, rater seat and posture per segment (API.md SegmentSicknessSplit).
CREATE TABLE segment_sickness (
    h3               text NOT NULL REFERENCES segments (h3) ON DELETE CASCADE,
    vehicle_type     text NOT NULL,
    rater_seat       text NOT NULL,
    rater_posture    text NOT NULL,
    sickness_aw_rms  double precision,
    msi_1h_pct       double precision,
    n_sessions       integer NOT NULL,
    PRIMARY KEY (h3, vehicle_type, rater_seat, rater_posture)
);

-- The latest roughness fit (one row): log(r) = segment + vehicle + β·log(v / v_ref).
CREATE TABLE aggregation_fit (
    id               boolean PRIMARY KEY DEFAULT true CHECK (id),
    method           text NOT NULL CHECK (method IN ('model', 'percentile', 'none')),
    beta             double precision,
    vehicle_effects  jsonb NOT NULL DEFAULT '{}',
    n_observations   integer NOT NULL,
    n_sessions       integer NOT NULL,
    fitted_at        timestamptz NOT NULL DEFAULT now()
);
