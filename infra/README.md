# infra: Terraform for the Azure stack

Implements [decisions/02-infrastructure-plan.md](../decisions/02-infrastructure-plan.md) §12. Everything runs through [`tf.ps1`](tf.ps1), a PowerShell script that reads settings from `infra/.env`. It works in Windows PowerShell 5.1 and in PowerShell 7 (`pwsh`) on macOS and Linux; the commands below are the same in both, with `./` or `.\` in front.

```
bootstrap/   run once by hand: stack resource group, Terraform state storage, GitHub OIDC identities, provider registration
main/        the whole stack (state in the bootstrap storage account)
modules/     network, storage, messaging, database, compute, web, observability
scripts/     add-device-key.ps1 (device key hashes into Key Vault)
```

## First run

1. Install the tools, then open a new terminal:
   - macOS: `brew tap hashicorp/tap && brew install hashicorp/tap/terraform azure-cli && brew install --cask powershell`, then start PowerShell with `pwsh`.
   - Windows: `winget install Hashicorp.Terraform` and `winget install Microsoft.AzureCLI`.
2. `az login`, then `az account set --subscription <id>` if you have more than one.
3. `cp infra/.env.example infra/.env` (Windows: `Copy-Item infra/.env.example infra/.env`) and fill in the first block (the comments say which `az` command prints each value).
4. In `pwsh` (or Windows PowerShell): `cd infra; ./tf.ps1 bootstrap`. It writes the state settings into `.env` and prints the GitHub repo variables for CI.
5. `./tf.ps1 plan`, then `./tf.ps1 apply` (about 15 minutes; PostgreSQL is the slow part). The apply ends by removing a storage setting the provider writes by mistake ([Function host storage](#function-host-storage-provider-bug-read-before-applying)).
6. `./scripts/add-device-key.ps1 -DeviceId <Device ID>` for each phone, where the Device ID is the UUID the app shows in Settings (a key only works for the device it is stored under), and `-DeviceId replay` once for the replay tool. An existing entry under another name: add `-RenameFrom <old name>`. The function picks up new and renamed keys by itself within a minute; no restart is needed.
7. `./tf.ps1 output` prints `ingest_base_url` (`https://<function host>`, no path: paste it into the iPhone app's upload settings and into `REPLAY_API_URL`; both add `/api/ingest` themselves) and `read_api_url`. `ingest_batch_url` is the full `POST` endpoint, for manual checks.

After the hackathon: `./tf.ps1 destroy` (the bootstrap resource groups are deleted by hand).

## What runs on it now

Terraform creates every resource; the GitHub Actions deploys ship the code. Terraform ignores image changes after creation, so deploys and `terraform plan` don't fight.

| Resource | Running | Deployed by |
|---|---|---|
| Function app `func-roadride-ingest-*` | the ingest function | `deploy-ingest` on merge to `main` |
| Container app `ca-roadride-processor` | the stream processor + signal processing | `deploy-services` on merge to `main` |
| Container app `ca-roadride-read-api` | the read API (port 8000; a fresh app starts on 80 for the placeholder, deploy-services switches it) | `deploy-services` |
| Job `caj-roadride-migrate` | database migrations + Entra roles | `deploy-services`, before the apps are updated |
| Job `caj-roadride-finalize` | the finalize job (started by the `session-ready` queue) | `deploy-services` |
| Job `caj-roadride-aggregate` | the aggregation step, started by hand | `deploy-services` |
| Static Web App `stapp-roadride-dashboard` | nothing yet: run **deploy-dashboard** (manual) | `deploy-dashboard` |

The deploys use the `prod` GitHub environment and these repo variables: `AZURE_CLIENT_ID_DEPLOY`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `INGEST_FUNCTION_APP`, `ACR_NAME`, `RESOURCE_GROUP`. CI's test database is a throwaway container with trust authentication (no password), so no secret is needed and fork PRs work (the old `POSTGRES_PASSWORD` repo secret can be deleted once this is on `main`).

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

## CI for Terraform

| Workflow | Runs | Identity | What it does |
|---|---|---|---|
| `terraform-plan` | every PR touching `infra/**` | `plan` (Reader + state blob access) | `fmt -check`, `validate` (main and bootstrap), then `plan -refresh=false -lock=false` against the remote state, posted as a PR comment; fails if the plan deletes or replaces the database, a storage account or container, Event Hubs, Service Bus, Key Vault or the registry |
| `terraform-apply` | manual (Actions → Run workflow) | `deploy` (`prod` environment) | plan with refresh, the same delete guard (override: `allow_data_loss`), apply, then the host-storage clean-up |
| `security` | every PR and push to `main` | none | gitleaks over the whole history |

The plan runs with `-refresh=false` because Reader can't call the "list" actions the provider uses while
refreshing (function app settings, keys). It shows what the PR changes relative to the last apply, not
drift made outside Terraform; `tf.ps1 plan` on a laptop shows both. Fork and Dependabot PRs get the fmt
and validate job only (no OIDC token there). Teardown stays on a laptop (`tf.ps1 destroy`): purging the
soft-deleted Key Vault needs rights at subscription level.

Set once in the repo (Settings → Secrets and variables → Actions):

| Name | Kind | Value |
|---|---|---|
| `AZURE_CLIENT_ID_PLAN` | variable | from `terraform -chdir=infra/bootstrap output github_variables` |
| `TFSTATE_RESOURCE_GROUP`, `TFSTATE_STORAGE_ACCOUNT`, `TFSTATE_CONTAINER` | variables | same output (also in `infra/.env`) |
| `TF_VAR_ADMIN_OBJECT_IDS` | variable | the JSON list from `infra/.env`, exactly (a different list = role assignments added or removed) |
| `TF_VAR_ALERT_EMAIL` | **secret** | from `infra/.env` (a secret so the public logs mask it) |
| `TF_VAR_BUDGET_AMOUNT`, `TFSTATE_KEY` | variables, optional | only if `infra/.env` overrides them |

The workflows don't read `psql_nat_gateway_enabled` (~$1/day) or `eventhub_local_auth_enabled` (key login)
from repo variables, so editing a variable can't switch either on for the next apply. Turning one on takes a
PR that changes its default in `main/variables.tf`, with the user's OK (root `CLAUDE.md`); then laptop and CI
applies agree. Setting it only in `infra/.env` works for a laptop apply, but the next terraform-apply run
turns it off again.

`AZURE_CLIENT_ID_DEPLOY`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` are already set for the deploys.

### If the Azure login fails in a workflow

The federated credentials in `bootstrap/main.tf` use GitHub's immutable subject format
(`repo:ghimpumihai@163877193/DataInfrastructure_Chuds@1465690625:environment:prod` and `…:pull_request`),
which GitHub uses for repositories created after 2026-07-15 (plan §5, D36). On 2026-11-21 the repo's
OIDC settings returned exactly that prefix:

```
gh api repos/ghimpumihai/DataInfrastructure_Chuds/actions/oidc/customization/sub
```

If a login fails with `AADSTS700213` (no matching federated identity record), compare the `sub` that
terraform-plan prints in its "Show the OIDC subject GitHub sends" step with the credential's subject.
A job with `environment:` gets `…:environment:<name>`; a `pull_request` job without one gets `…:pull_request`.

## Function host storage (provider bug, read before applying)

The function app's own storage (`stroadridefn*`) has storage keys switched off, so the Functions host
must log in with the ingest identity through the `AzureWebJobsStorage__accountName` / `__credential` /
`__clientId` settings. azurerm 4.x (checked in v4.81.0, `function_app_flex_consumption_resource.go`)
**also writes a plain `AzureWebJobsStorage=DefaultEndpointsProtocol=https;AccountName=…;AccountKey=;…`
on every create and on every update of the function app**, whatever `storage_authentication_type` says
([#29149](https://github.com/hashicorp/terraform-provider-azurerm/issues/29149),
[#33211](https://github.com/hashicorp/terraform-provider-azurerm/issues/33211)). The host prefers that
string, has no key to use with it, can't take its lock lease and never starts: every request then fails.

It is removed automatically:

- by `tf.ps1 apply`, right after Terraform (`tf.ps1 fix-ingest-storage` runs only this step);
- by the **terraform-apply** workflow, after the apply;
- by **deploy-ingest**, before every deploy, which then checks that the function answers.

If you apply some other way, run this afterwards (bash or PowerShell, same line):

```
az functionapp config appsettings delete -g rg-roadride -n <ingest function> --setting-names AzureWebJobsStorage
```

Terraform doesn't see the setting (the provider hides it), so deleting it never shows up as drift.

## Where this differs from the plan

- Identities and the data-plane role assignments live in `main/` (`identities.tf`, `rbac.tf`), not in the compute module, so every module can use them without circular references.
- The worker identity gets **Azure Service Bus Data Owner** on the one queue instead of Sender + Receiver: the KEDA Service Bus scaler reads the queue length through the management API, which needs the Manage right.
- The ingest function reads the device-key secret with the Key Vault SDK at start-up instead of a Key Vault reference in its settings (the plan already says "loaded once at start-up"; this avoids reference-identity wiring on Flex Consumption).
- The read API's CORS origins are passed as an environment variable and enforced by FastAPI, not by the ingress setting.
- The function app's host storage and deployment package live in their own small storage account, so the ingest identity is Owner only there and has plain write access on `lake`.
- The Static Web App is in **East US 2**: Static Web Apps isn't offered in North Europe, and West Europe refused new customers on 2026-11-20. It serves files from a global network anyway.
- Plan §13 applies on merge to `main` after approval in `prod`; `prod` has no required reviewers (the code deploys use it unattended), so **terraform-apply is manual** instead, and there is no teardown workflow (`tf.ps1 destroy`). The PR plan runs with `-refresh=false` because the plan identity is Reader only (see "CI for Terraform").
- The read API's ingress port is set by deploy-services together with the image, and the `AzureWebJobsStorage` setting the provider writes is deleted by `tf.ps1 apply` / the workflows: both are outside Terraform on purpose (`ignore_changes`, provider bug).
- `psql_nat_gateway_enabled = true` adds a NAT gateway to the database subnet (~$1/day), for when default outbound access can't reach Entra ID. It needs the user's OK and goes in as a default change in `main/variables.tf` (see "CI for Terraform").
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

The log tiles parse the services' log lines (`<date> <time> LEVEL logger message`, `services/processor/roadride/stream.py` and `finalize.py`); a change to those lines needs the matching change in `workbook.tf`. The read API also sends its requests, logs and traces to Application Insights (`azure-monitor-opentelemetry`, `services/read-api/app/main.py`), but its section uses the Container Apps `Requests` metric, which counts every request at the ingress, including those that never reach the app. A tile shows an error instead of an empty chart until its table has its first row (for example `ContainerAppConsoleLogs_CL` before any app has logged).

## Known risks to check on the first apply

- The `plan` identity for pull requests only has Reader, so terraform-plan runs with `-refresh=false` (see "CI for Terraform"). If a full refresh is ever wanted in CI, it needs a custom role with the provider's "list" actions, which would also expose keys to PR workflows.
- If Event Hubs Basic refuses managed-identity login (plan §16 day-0 test), the fallback is `eventhub_local_auth_enabled = true`: key login, so ask the user first (root `CLAUDE.md`). With their OK, change its default in `main/variables.tf` in a PR and apply it (with their OK too); a value in `.env` alone is undone by the next terraform-apply run.
