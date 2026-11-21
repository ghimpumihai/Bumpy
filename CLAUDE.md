# Road & Ride: project rules

## Decisions
- Design rationale: `decisions/02-infrastructure-plan.md`. The Status column of the decision log (`decisions/README.md`) says which decisions are current.
- A design change gets a new `Dxx` row; mark the old row "Superseded by Dxx" or "Partly superseded by Dxx (what)". Never rewrite an accepted row.

## Contracts span folders
Additive fields may land one side at a time; a breaking change updates every side in the same PR.
- Phone → ingest (batch JSON, `session.json`): `decisions/01-initial-plan.md` §6/§6.1, `services/ingest/`, `services/processor/roadride/live.py` (the parser), `src/mobile-ios/tools/mock_ingest_server.py`, `src/mobile-ios/tools/fixtures/`, `tools/replay/`.
- Session folder (spec §4 CSVs, `session.json`) and the upload's `_complete.json` manifest: `tools/upload/`, `services/processor/roadride/upload.py`, `tools/replay/`.
- Read API → dashboard: `dashboard/API.md`, `services/read-api/`, `dashboard/src/types/`, `dashboard/src/mock/`, `dashboard/src/utils/api-shape.ts`.

## Never
- Commit secrets, device keys or a `.env`. Device keys go into Key Vault with `infra/scripts/add-device-key.ps1`.
- On Azure, use password or key logins. Services use Entra managed identities; the Event Hubs key fallback (`eventhub_local_auth_enabled`) needs the user's OK.
- Change Azure outside Terraform, except image and code deploys done by the workflows and device keys added by the script. Never run `terraform apply/destroy`, a deploy workflow or a state-changing `az` command without the user's OK. Merging to `main` deploys ingest and services, so it needs the same OK. PRs target `staging` (the default branch, tests only, no deploys); `main` only receives `staging` → `main` release PRs.
- Count replays (`source=replay`) in aggregates, upload raw audio, or return GPS without the 200 m start/end trim.

## Data safety
Losing trip data is the worst bug: it can't be collected again.
- A batch is identified by `(session_id, batch_seq)` (primary key of `ingest_batches`) and blob names derive from the message, so a retry overwrites instead of duplicating. Keep every new write path repeatable the same way.
- During a trip-collection window, don't merge to `main` and don't change the app build or the ingest contract. Nothing is deleted on a phone until its trip is verified in the cloud.

## Where to spend effort
- Tests are for the data path only: the app's upload queue and on-disk files, ingest, the processor's checkpoints and DSP, migrations. Elsewhere, skip them.
- Outside the data path, hard-coded config and `HACKATHON:` TODOs are fine. Never cut corners on the data path, secrets or Terraform.
- Do only the task; don't refactor or restyle neighbouring code.
- Comment only what the code can't say: a non-obvious reason, a trap, a spec or decision reference. No comments that restate the code.

## Cost and dependencies
- Don't raise any SKU or replica count, or enable `psql_nat_gateway_enabled` (~$1/day), without asking.
- Ask before adding an Azure service, or any dependency to the ingest Function or the iOS app. For other libraries, say why in the PR.
- `tools/replay/`, `tools/upload/` and `src/mobile-ios/tools/` use the Python standard library only.
