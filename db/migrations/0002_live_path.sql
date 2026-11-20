-- Tables for the live path (plan §8): phones → ingest → Event Hubs → stream processor → these tables
-- → read API. Segments, events, chart series and aggregates come with the processing step.
--
-- Vehicle context is stored on the session (vehicle_type, vehicle_make_model, vehicle_line) instead of
-- a separate vehicles table: every trip carries its own context in session.json, and nothing yet needs
-- to identify one physical vehicle across trips.

CREATE TABLE devices (
    device_id      text PRIMARY KEY,
    first_seen_at  timestamptz NOT NULL DEFAULT now(),
    last_seen_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE sessions (
    session_id            text PRIMARY KEY,
    device_id             text REFERENCES devices (device_id),
    source                text NOT NULL DEFAULT 'live' CHECK (source IN ('live', 'upload', 'replay')),
    replay_of             text,
    status                text NOT NULL DEFAULT 'live' CHECK (status IN ('live', 'processing', 'complete')),
    incomplete            boolean NOT NULL DEFAULT false,
    quality_status        text NOT NULL DEFAULT 'pending'
                          CHECK (quality_status IN ('pending', 'ok', 'degraded', 'bad')),
    include_in_agg        boolean NOT NULL DEFAULT false,
    exclusion_reasons     text[] NOT NULL DEFAULT '{}',

    -- Context from session.json (spec §6.1); context_known is false until it arrives.
    context_known         boolean NOT NULL DEFAULT false,
    vehicle_type          text NOT NULL DEFAULT 'unknown',
    vehicle_make_model    text,
    vehicle_line          text,
    mount                 jsonb,
    people                jsonb,
    conditions            jsonb,
    audio_enabled         boolean,
    synthetic_sensors     boolean NOT NULL DEFAULT false,
    recovered             boolean NOT NULL DEFAULT false,
    metadata              jsonb,         -- the latest session.json as received (Stop copy wins)

    started_at            timestamptz,
    ended_at              timestamptz,
    expected_batch_count  integer CHECK (expected_batch_count >= 0),   -- batchCount from the Stop copy

    -- Live bookkeeping
    last_batch_seq        integer,
    last_received_at      timestamptz,
    received_batches      integer NOT NULL DEFAULT 0,
    duplicate_batches     integer NOT NULL DEFAULT 0,
    late_batches          integer NOT NULL DEFAULT 0,

    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX sessions_device_idx ON sessions (device_id, started_at DESC);

-- One row per live batch: the unique key is what drops repeats (plan §8, "ON CONFLICT DO NOTHING").
CREATE TABLE ingest_batches (
    session_id     text NOT NULL REFERENCES sessions (session_id) ON DELETE CASCADE,
    batch_seq      integer NOT NULL CHECK (batch_seq >= 0),
    device_id      text NOT NULL,
    t0_utc         timestamptz NOT NULL,
    end_utc        timestamptz NOT NULL,     -- time of the batch's newest sample
    received_at    timestamptz NOT NULL,     -- when the ingest function got it
    processed_at   timestamptz NOT NULL DEFAULT now(),
    late           boolean NOT NULL DEFAULT false,   -- arrived after a newer batch of the same session
    sample_counts  jsonb NOT NULL,
    PRIMARY KEY (session_id, batch_seq)
);

-- How far the processor has read each Event Hubs partition; updated in the same transaction as the
-- rows written from those events, so a restart continues exactly where it stopped (plan §5).
CREATE TABLE stream_checkpoints (
    eventhub         text NOT NULL,
    consumer_group   text NOT NULL,
    partition_id     text NOT NULL,
    sequence_number  bigint NOT NULL,
    enqueued_at      timestamptz,
    updated_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (eventhub, consumer_group, partition_id)
);

-- Every GPS fix of a trip (≈ 1 Hz): the light track for the live view and the session map.
CREATE TABLE track_points (
    session_id   text NOT NULL REFERENCES sessions (session_id) ON DELETE CASCADE,
    t            timestamptz NOT NULL,
    geom         geography (Point, 4326) NOT NULL,
    speed_ms     double precision,
    course_deg   double precision,
    h_acc_m      double precision,
    PRIMARY KEY (session_id, t)
);

-- Manual taps and ratings from the app (labels.csv / the batch's labels).
CREATE TABLE labels (
    session_id  text NOT NULL REFERENCES sessions (session_id) ON DELETE CASCADE,
    t           timestamptz NOT NULL,
    type        text NOT NULL,
    value       text,
    note        text,
    PRIMARY KEY (session_id, t, type)
);

-- Latest state per device for the Live page (plan §5 "Dashboard").
CREATE TABLE live_state (
    device_id      text PRIMARY KEY REFERENCES devices (device_id),
    session_id     text NOT NULL REFERENCES sessions (session_id) ON DELETE CASCADE,
    updated_at     timestamptz NOT NULL,   -- time of the newest sample (phone clock, UTC)
    received_at    timestamptz NOT NULL,   -- arrival of the batch holding it
    fix_at         timestamptz,            -- time of the position below
    lat            double precision,
    lon            double precision,
    speed_ms       double precision,
    course_deg     double precision,
    h_acc_m        double precision,
    roughness_now  double precision,
    msdv_so_far    double precision,
    battery        double precision,
    thermal        text,
    low_power      boolean
);
