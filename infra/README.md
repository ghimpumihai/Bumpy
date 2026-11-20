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

## What runs before the services exist

Until CI pushes real images, the container apps and jobs run Microsoft's public quickstart images, and the function app is empty. Terraform ignores image changes after creation, so CI deploys and `terraform plan` don't fight.

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
- The monitoring workbook and alert rules are not written yet (first on the plan's cut list). The budget and the email action group are.

## Known risks to check on the first apply

- The `plan` identity for pull requests only has Reader. If `terraform plan` in CI fails reading the function app's settings or the Static Web App's key (those are "list" actions Reader doesn't have), give it a custom role with those read actions.
- If Event Hubs Basic refuses managed-identity login (plan §16 day-0 test), set `TF_VAR_eventhub_local_auth_enabled=true` in `.env` and apply.
