-- D45: a pass's sickness counts only its moving, valid windows (speed at least 1 m/s, phone not
-- handled), so a bus standing at a stop doesn't dilute the segment. Additive: passes written by a
-- processor without these columns keep NULL, and the aggregate falls back to duration_s and aw_rms.
ALTER TABLE segment_observations
    ADD COLUMN sickness_s      double precision,  -- seconds of moving, valid windows in the pass
    ADD COLUMN sickness_aw_rms double precision;  -- m/s², Wf a_w RMS over those windows; null when 0 s
