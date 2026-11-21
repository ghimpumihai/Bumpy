-- Results of the signal processing (plan §8, §9): chart series, detected events, the trip's
-- motion-sickness dose, and the pipeline state that lets the stream processor continue a trip's
-- filters across batches and restarts. New tables get the writer/reader grants from the default
-- privileges set by the migrate job.

ALTER TABLE sessions ADD COLUMN msdv_z double precision;  -- MSDV so far, m/s^1.5 (ISO 2631-1 Wf, vertical)

-- About 5 Hz per trip, for the session charts.
CREATE TABLE session_series (
    session_id  text NOT NULL REFERENCES sessions (session_id) ON DELETE CASCADE,
    t           timestamptz NOT NULL,
    a_vert      double precision NOT NULL,   -- m/s², 1–30 Hz band, largest |value| in the 0.2 s window
    a_lat       double precision NOT NULL,   -- m/s², 0 until the forward axis is known
    a_lon       double precision NOT NULL,
    speed_ms    double precision,
    msdv        double precision NOT NULL,   -- m/s^1.5 so far
    PRIMARY KEY (session_id, t)
);

-- Detected road events. Position is interpolated from the trip's GPS fixes.
CREATE TABLE events (
    session_id     text NOT NULL REFERENCES sessions (session_id) ON DELETE CASCADE,
    type           text NOT NULL CHECK (type IN ('pothole', 'speed_bump', 'rail_joint')),
    t              timestamptz NOT NULL,
    geom           geography (Point, 4326),
    speed_ms       double precision,
    magnitude      double precision NOT NULL,
    confidence     double precision NOT NULL CHECK (confidence BETWEEN 0 AND 1),
    matched_label  boolean NOT NULL DEFAULT false,
    PRIMARY KEY (session_id, type, t)
);

-- The live pipeline's memory per trip (filters, dose, grid, forward axis), saved in the same
-- transaction as the rows above and the stream checkpoint.
CREATE TABLE signal_state (
    session_id      text PRIMARY KEY REFERENCES sessions (session_id) ON DELETE CASCADE,
    state           jsonb NOT NULL,
    last_batch_seq  integer NOT NULL,
    gaps            integer NOT NULL DEFAULT 0,  -- times the filters restarted (missing batch or time gap)
    updated_at      timestamptz NOT NULL DEFAULT now()
);
