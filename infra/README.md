# infra: Terraform for the Azure stack

Implements [decisions/02-infrastructure-plan.md](../decisions/02-infrastructure-plan.md) §12. Everything runs on Windows PowerShell through [`tf.ps1`](tf.ps1), which reads settings from `infra/.env`.

```
bootstrap/   run once by hand: stack resource group, Terraform state storage, GitHub OIDC identities, provider registration
main/        the whole stack (state in the bootstrap storage account)
modules/     network, storage, messaging, database, compute, web, observability
scripts/     add-device-key.ps1 (device key hashes into Key Vault)
```

## First run

1. Install the tools: `winget install Hashicorp.Terraform` and `winget install Microsoft.AzureCLI`, then open a new terminal.
2. `az login`, then `az account set --subscription <id>` if you have more than one.
3. `Copy-Item infra/.env.example infra/.env` and fill in the first block (the comments say which `az` command prints each value).
4. `cd infra; .\tf.ps1 bootstrap`. It writes the state settings into `.env` and prints the GitHub repo variables for CI.
5. `.\tf.ps1 plan`, then `.\tf.ps1 apply` (about 15 minutes; PostgreSQL is the slow part).
6. `.\scripts\add-device-key.ps1 -DeviceId <phone-name>` for each phone and for the replay tool, then restart the function app.
7. `.\tf.ps1 output` prints the ingest URL for the app and the read API URL for `dashboard/public/config.json`.

After the hackathon: `.\tf.ps1 destroy` (the bootstrap resource groups are deleted by hand).

## What runs on it now

Terraform creates every resource; the GitHub Actions deploys ship the code. Terraform ignores image changes after creation, so deploys and `terraform plan` don't fight.

| Resource | Running | Deployed by |
|---|---|---|
| Function app `func-roadride-ingest-*` | the ingest function | `deploy-ingest` on merge to `main` |
| Container app `ca-roadride-processor` | the stream processor + signal processing | `deploy-services` on merge to `main` |
| Container app `ca-roadride-read-api` | the read API (port 8000) | `deploy-services` |
| Job `caj-roadride-migrate` | database migrations + Entra roles | `deploy-services`, before the apps are updated |
| Job `caj-roadride-finalize` | the finalize job (started by the `session-ready` queue) | `deploy-services` |
| Job `caj-roadride-aggregate` | the aggregation step, started by hand | `deploy-services` |
| Static Web App `stapp-roadride-dashboard` | nothing yet: run **deploy-dashboard** (manual) | `deploy-dashboard` |

The deploys use the `prod` GitHub environment and these repo variables: `AZURE_CLIENT_ID_DEPLOY`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `INGEST_FUNCTION_APP`, `ACR_NAME`, `RESOURCE_GROUP`. CI's test database uses the `POSTGRES_PASSWORD` repo secret.

Contracts the service code must follow (set as environment variables by Terraform):

| Service | Port / trigger | Logs in as | Notes |
|---|---|---|---|
| ingest function | `POST /api/ingest`, `PUT /api/ingest/sessions/{id}` | `AZURE_CLIENT_ID` (ingest identity) | reads the secret `DEVICE_KEYS_SECRET_NAME` from `KEY_VAULT_URI`: JSON `{deviceId: sha256hex(key)}` |
| read API | listens on **port 8000** (non-root) | PG user `reader` | allow the origins in `CORS_ALLOWED_ORIGINS` |
| processor | no ingress, `RUN_MODE=stream` | PG user `writer` | |
| finalize job | Service Bus queue `session-ready`, `RUN_MODE=finalize` | PG user `writer` | renew the message lock while working |
| aggregate job | manual, `RUN_MODE=aggregate` | PG user `writer` | |
| migrate job | manual, `RUN_MODE=migrate` | PG user `migrator` (Entra admin) | creates `writer`/`reader` from `WRITER_OBJECT_ID`/`READER_OBJECT_ID` |

Database tokens: request `https://ossrdbms-aad.database.windows.net/.default` with `ManagedIdentityCredential(client_id=AZURE_CLIENT_ID)` and use it as the password with `sslmode=require`.

## Where this differs from the plan

- Identities and the data-plane role assignments live in `main/` (`identities.tf`, `rbac.tf`), not in the compute module, so every module can use them without circular references.
- The worker identity gets **Azure Service Bus Data Owner** on the one queue instead of Sender + Receiver: the KEDA Service Bus scaler reads the queue length through the management API, which needs the Manage right.
- The ingest function reads the device-key secret with the Key Vault SDK at start-up instead of a Key Vault reference in its settings (the plan already says "loaded once at start-up"; this avoids reference-identity wiring on Flex Consumption).
- The read API's CORS origins are passed as an environment variable and enforced by FastAPI, not by the ingress setting.
- The function app's host storage and deployment package live in their own small storage account, so the ingest identity is Owner only there and has plain write access on `lake`.
- The Static Web App is in **East US 2**: Static Web Apps isn't offered in North Europe, and West Europe refused new customers on 2026-11-20. It serves files from a global network anyway.
- `TF_VAR_psql_nat_gateway_enabled=true` adds a NAT gateway to the database subnet (~$1/day), for when default outbound access can't reach Entra ID.
- Bootstrap may not register `microsoft.insights` (Azure lists it in lowercase); if Application Insights fails with `MissingSubscriptionRegistration`, run `az provider register --namespace Microsoft.Insights --wait`.
- No alert rules yet: the plan wants an email on errors and on processor lag. The email action group and the budget exist.

## Monitoring workbook

`modules/observability/workbook.tf` defines one Azure Monitor workbook, **Road & Ride: live path**. In the portal: Application Insights `appi-roadride-*` → Workbooks. It is free (queries and platform metrics only) and follows the time range picked at the top (4 h by default).

| Section | Shows | From |
|---|---|---|
| Ingest function | requests by status code, per route with p95 duration, the latest rejections (4xx/5xx log lines), warnings and exceptions | Application Insights (`AppRequests`, `AppTraces`, `AppExceptions`) |
| Event Hubs | messages in and out of the `ingest` hub, throttled requests, server and user errors | platform metrics |
| Stream processor | commit lag (`lag_s`) per partition, events per minute by outcome, the last committed batch per partition, warnings, errors and process starts, replica restarts | the processor's per-batch log lines (`ContainerAppConsoleLogs_CL`), the `RestartCount` metric |
| | the `roadride.processor.lag` gauge, which keeps rising while the processor is stuck | `AppMetrics`: empty until the processor exports it |
| Finalize job and queue | trips queued, finalized, failed (retried) and dead-lettered; job executions by state; `session-ready` messages waiting and dead-lettered, sent, completed and abandoned; finalized trips by data quality; the latest finalize lines | job log lines, `Executions` metric, Service Bus metrics |
| PostgreSQL | CPU and memory %, CPU credits left (B1ms is burstable), storage %, active and failed connections | platform metrics |
| Read API | requests by status class, average response time, restarts, error lines; platform warnings (crash loops, failed image pulls) for the processor, read API and finalize job | Container Apps metrics, `ContainerAppConsoleLogs_CL`, `ContainerAppSystemLogs_CL` |

The log tiles parse the services' log lines (`<date> <time> LEVEL logger message`, `services/processor/roadride/stream.py` and `finalize.py`); a change to those lines needs the matching change in `workbook.tf`. The read API has no Application Insights SDK, so its requests come from the Container Apps `Requests` metric. A tile shows an error instead of an empty chart until its table has its first row (for example `ContainerAppConsoleLogs_CL` before any app has logged).

## Known risks to check on the first apply

- The `plan` identity for pull requests only has Reader. If `terraform plan` in CI fails reading the function app's settings or the Static Web App's key (those are "list" actions Reader doesn't have), give it a custom role with those read actions.
- If Event Hubs Basic refuses managed-identity login (plan §16 day-0 test), set `TF_VAR_eventhub_local_auth_enabled=true` in `.env` and apply.
