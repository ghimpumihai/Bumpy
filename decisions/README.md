# Decisions

Plans and the decision log for the Codelap 2026 project: road quality and motion sickness from phone sensors.

| File | What it is |
|---|---|
| [01-initial-plan.md](01-initial-plan.md) | The original iPhone recorder spec, updated for the Azure backend. Read this to build the app. |
| [02-infrastructure-plan.md](02-infrastructure-plan.md) | The Azure backend: architecture diagram, every tool explained, why we chose it, data model, processing, IaC, CI/CD, cost, build order. |
| [03-research-notes.md](03-research-notes.md) | Facts, prices and sources behind the decisions. |

## Implementation status

The plan in 02 is being built in its day-1/day-2 order. What's done, deployed and still open is kept in the [root README](../README.md#status-2026-11-21). Where the code differs from the plan (e.g. the read API on port 8000, the Static Web App in East US 2, Service Bus Data Owner for the KEDA scaler), the differences are listed in each part's README: [infra](../infra/README.md#where-this-differs-from-the-plan), [ingest](../services/ingest/README.md#differences-from-the-mock-and-the-plan), [processor](../services/processor/README.md).

## Decision log

Decisions D1–D17 were researched and then reviewed by an independent advisor model before being accepted. D18 and D19 are scope cuts made by the team. D20 is a correctness fix found while rechecking the plan. D21–D31 move the backend from AWS to Azure (same day); D30 also fixes gaps found in a review of the AWS version (what starts the backfill, where aggregation runs, concurrent migrations). D32–D33 make the live path (phone → cloud → dashboard) the main path. D34–D36 come from the final research pass (02 §20).

| # | Decision | Status | Main alternative rejected | Details |
|---|---|---|---|---|
| D1 | Cloud is AWS, region `eu-west-1` (Ireland) | Superseded by D21 | Azure; `eu-central-1` | 02 §2 |
| D2 | Collect many real sessions (car, bus, tram) and aggregate; no simulated fleet | Accepted | Fleet simulator | 02 §3 |
| D3 | Session files uploaded to S3 are the main dataset; live upload is a capability | Superseded by D32 | Live-only ingest | 02 §3, §7 |
| D4 | Streaming with Kinesis on-demand (+ Firehose archive) | Superseded by D22 | Kafka on MSK, self-hosted Redpanda | 02 §5, §6 |
| D5 | Ingest: API Gateway HTTP API + Lambda outside the VPC; duplicates removed in the database | Superseded by D23 | DynamoDB duplicate check (data-loss bug) | 02 §5 |
| D6 | Processing in Python on ECS Fargate; same code for live and batch | Superseded by D24 | Lambda windows, Managed Flink | 02 §5, §9 |
| D7 | RDS PostgreSQL `db.t4g.micro` + PostGIS; raw samples stay in S3 as Parquet | Superseded by D25 | Aurora Serverless, Timestream, DynamoDB | 02 §3, §5 |
| D8 | Road segments as H3 hexagons first, OSM snapping later | Superseded by D18 | OSM snapping from day one | 02 §8 |
| D9 | Cross-vehicle normalization by regression; sickness not normalized | Accepted | Raw averages | 02 §9 |
| D10 | Replay tool sends recorded trips through the live API (test and demo) | Accepted | Video only | 02 §5 |
| D11 | No NAT gateway; Fargate in public subnets, database private | Superseded by D26 | NAT gateway | 02 §5 |
| D12 | Terraform, one cloud environment, S3 state with native locking | Superseded by D27 | CDK, SAM; dev + demo environments | 02 §12 |
| D13 | GitHub Actions only, OIDC to AWS | Superseded by D27 | Second CI/CD system | 02 §13 |
| D14 | Job queue on SQS | Superseded by D28 | RabbitMQ (Amazon MQ) | 02 §6 |
| D15 | Audio off on public transport; replays excluded from aggregates | Accepted | n/a | 02 §10 |
| D16 | Read API logs in to RDS with IAM auth; processor uses its own writer user from Secrets Manager | Superseded by D29 | Secrets Manager VPC endpoint or NAT for the read Lambda | 02 §5 |
| D17 | Live raw batches archived to S3 by Firehose (newline-delimited JSON, gzip) | Superseded by D22 | Archive code in the processor | 02 §5 |
| D18 | Road segments are H3 hexagons only; OSM road snapping dropped | Accepted | OSM snapping as a later upgrade | 02 §8, §19 |
| D19 | Dropped from scope: Athena/Glue, lateral sickness metric, checkov, iOS CI build | Accepted | Keeping them as optional extras | 02 §19 |
| D20 | Uploads end with a `_complete.json` marker that triggers processing; uploaded files replace live results for the same session | Accepted | Triggering on `session.json` (written at trip start, could start on a half-uploaded folder) | 02 §5, §7 |
| D21 | Cloud is Azure, region North Europe (Ireland); the whole stack runs on the free account | Accepted | AWS (Free plan blocks Kinesis and Firehose, Paid plan bills a card) | 02 §2 |
| D22 | Streaming with Event Hubs Basic (partition key = device); the ingest function writes the raw archive itself | Accepted | Event Hubs Standard + Capture; Service Bus sessions | 02 §5, §6 |
| D23 | Ingest: HTTP-triggered Azure Function (Flex Consumption) outside the VNet, no API gateway; duplicates removed in the database | Accepted | API Management in front | 02 §5 |
| D24 | Processing in Python on Container Apps: processor as an app, backfill/aggregate/migrate as jobs; same code for live and batch | Accepted | Functions, Stream Analytics, AKS | 02 §5, §9 |
| D25 | PostgreSQL Flexible Server `B1ms` + PostGIS (free 12 months); raw samples stay in Blob Storage as Parquet | Accepted | Azure SQL free offer (no PostGIS), Cosmos DB | 02 §3, §5 |
| D26 | No NAT gateway: database in a private subnet, subnets keep default outbound access | Partly superseded by D35 (outbound access, NSG rule) | NAT gateway, private endpoints | 02 §5 |
| D27 | Terraform `azurerm`, one cloud environment, state in Blob Storage; GitHub Actions only, OIDC via federated credentials | Accepted | Bicep; dev + demo environments | 02 §12, §13 |
| D28 | Job queue: Event Grid (`_complete.json` filter) → Service Bus Basic queue with dead-letter → backfill job started by KEDA | Accepted | Storage Queues, RabbitMQ | 02 §5, §7 |
| D29 | All database logins use Entra managed identities (migrator, writer, reader); password login off | Accepted | Admin password in Key Vault | 02 §5 |
| D30 | Migrations run in their own job before deploys; aggregation runs at the end of each backfill under an advisory lock; only uploaded sessions are aggregated | Partly superseded by D32 (which trips are aggregated) | Migrations at processor start-up; live sessions in the aggregate | 02 §5, §7, §9 |
| D31 | Dashboard hosted on Static Web Apps (Free) | Accepted | Storage static website + Front Door | 02 §5 |
| D32 | The live path is the main path: the app's disk-queued batches carry the full dataset, the dashboard's Live view is the main screen, and a finalize job reprocesses each finished trip from the raw archive and aggregates it; laptop upload is only a fallback | Accepted | Uploaded session files as the main dataset (D3) | 02 §1, §3, §5, §7 |
| D33 | The app sends `session.json` at Start and Stop (`PUT /api/ingest/sessions/{id}`) through the same queue; it travels on the device's Event Hubs partition, so the processor sees context first and the trip end after the last batch | Accepted | Trip end by inactivity only; context from laptop upload only | 02 §5, 01 §6.1 |
| D34 | The read API runs as a Container App in the existing environment, not as a VNet-joined function | Accepted | Flex Consumption function with VNet integration (needs a NAT gateway on new, private-by-default subnets) | 02 §5, §20 |
| D35 | Networking: two subnets (Container Apps `/27`, PostgreSQL `/28`); Container Apps use their own outbound IPs; the database subnet keeps default outbound access and an NSG rule to `AzureActiveDirectory`; database TLS with `sslmode=require` | Accepted | NAT gateway; `sslmode=verify-full` (unsupported by Microsoft) | 02 §5, §20 |
| D36 | GitHub OIDC federated credentials use GitHub's immutable subject format (repo created after 2026-07-15); KEDA scale rules and the database admin use user-assigned identities | Accepted | Name-based subjects; system-assigned identities | 02 §5, §20 |

To change a decision: add a row with a new number, mark the old one "Superseded by Dxx", and explain why in the plan.
