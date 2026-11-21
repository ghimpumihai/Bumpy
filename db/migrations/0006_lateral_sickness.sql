-- Side-to-side sway in the motion-sickness dose (D49, plan §9 step 6).
--
-- The pipeline now adds a lateral dose (Donohew & Griffin weighting) to the vertical ISO 2631-1 one.
-- sessions.msdv_z stays the vertical part; msdv_y is the lateral part. The combined MSDV is
-- √(msdv_z² + msdv_y²): that is what live_state.msdv_so_far, session_series.msdv and
-- segment_observations.aw_rms now hold. Additive only, so the processor still running during the
-- deploy keeps working (it leaves msdv_y null, read as 0).

ALTER TABLE sessions ADD COLUMN msdv_y double precision;  -- lateral MSDV so far, m/s^1.5

COMMENT ON COLUMN sessions.msdv_z IS 'vertical MSDV so far, m/s^1.5 (ISO 2631-1 Wf)';
COMMENT ON COLUMN sessions.msdv_y IS 'lateral MSDV so far, m/s^1.5 (Donohew & Griffin 2004 weighting, D49)';
COMMENT ON COLUMN segment_observations.aw_rms IS 'm/s², weighted RMS of vertical and lateral combined: sqrt(a_wz² + a_wy²)';
COMMENT ON COLUMN segment_observations.sickness_aw_rms IS 'm/s², vertical and lateral combined over the moving, valid windows (D45, D49)';
COMMENT ON COLUMN session_series.msdv IS 'm/s^1.5 so far, vertical and lateral combined';
COMMENT ON COLUMN live_state.msdv_so_far IS 'm/s^1.5 so far, vertical and lateral combined';
