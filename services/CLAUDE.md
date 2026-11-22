# Backend services

Python 3.12 everywhere (Function runtime, Dockerfiles, CI); no 3.13+ features.

## Migrations
- Tracked by filename stem (`processor/roadride/migrate.py`): editing an applied file is silently ignored, and renaming one re-runs it. Add a new `db/migrations/NNNN_<name>.sql` instead.
- Each file runs in one transaction, so no `CREATE INDEX CONCURRENTLY`.
- The migrate job runs before the new processor and read API are deployed (`deploy-services.yml`), so a migration must also work with the processor that is still running: additive changes only.
- Grants: `GRANTS` in `migrate.py` covers schema `public` only and re-runs on every deploy. Locally migrate skips the `writer`/`reader` roles and everything runs as the superuser, so a missing grant or a write from the read API passes the tests and fails only on Azure.

## Processor
- A new `RUN_MODE` needs its app or job in `infra/modules/compute/main.tf` and an image-update step in `.github/workflows/deploy-services.yml`.
- A batch's rows and its partition's checkpoint (`stream_checkpoints`) commit in one transaction. Never commit one without the other.
- `dsp.py` must give the same result fed batch by batch as in one pass (`test_chunked_feed_equals_one_pass`). The DSP state is saved as JSON in `signal_state` per trip: new keys need defaults in `Pipeline.__init__`, and changing the filter design or sample grid breaks trips that are in progress during a deploy.
- The app sends acceleration in g; convert with `G`. The `WF` values are cited ISO 2631-1 constants, not tunables; only the pothole, speed-bump and forward-axis thresholds and the lateral weighting `WY` / `LATERAL_K` (PROVISIONAL in the `dsp.py` docstring) may be tuned.

## Ingest
- Validation order and status codes mirror `mobile/mobile-ios/tools/mock_ingest_server.py` (`tests/test_parity.py`), except the differences listed in `ingest/README.md`; add any new one there.
- Answer 200 only after the session owner check (D53), the Event Hubs send and the `lake` blob write succeed; any Azure failure (Key Vault and the owner marker included) is 503 so the app retries.

## Deploys ship a whitelist
- Ingest ships only `function_app.py`, `host.json`, `requirements.txt` and `ingest_core/` (`deploy-ingest.yml`).
- The processor image ships only `roadride/`, `requirements.txt` and `db/migrations/` (root `.dockerignore`).
- A new file outside those passes CI and is missing in Azure.

## Read API
- A route that reads new tables or functions goes into the smoke-check route list in `deploy-services.yml`; that check is the only proof on Azure that the `reader` grants work.
- Port 8000 is set in two places: the read-api `Dockerfile` and `READ_API_PORT` in `deploy-services.yml`, which switches the ingress to it. Terraform (`infra/modules/compute/main.tf`) creates the ingress on 80 for the placeholder image and ignores `target_port` after that.

## Tests
- Processor and read-API integration tests **skip silently** without a database: set `POSTGRES_PASSWORD`, run `docker compose up -d db` from the repo root, set the `PG*` variables listed in `docker-compose.yml`, and run `pytest -q -rs tests` so skips show.
- The read-API tests seed data through the processor's `Store`: after a processor change, run both suites.
