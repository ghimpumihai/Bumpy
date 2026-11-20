# Decisions

Plans and the decision log for the Codelap 2026 project: road quality and motion sickness from phone sensors.

| File | What it is |
|---|---|
| [01-initial-plan.md](01-initial-plan.md) | The original iPhone recorder spec, updated for AWS. Read this to build the app. |
| [02-infrastructure-plan.md](02-infrastructure-plan.md) | The AWS backend: architecture diagram, every tool explained, why we chose it, data model, processing, IaC, CI/CD, cost, build order. |
| [03-research-notes.md](03-research-notes.md) | Facts, prices and sources behind the decisions. |

## Decision log

Decisions D1–D17 were researched and then reviewed by an independent advisor model before being accepted. D18 and D19 are scope cuts made by the team. D20 is a correctness fix found while rechecking the plan.

| # | Decision | Status | Main alternative rejected | Details |
|---|---|---|---|---|
| D1 | Cloud is AWS, region `eu-west-1` (Ireland) | Accepted | Azure; `eu-central-1` | 02 §2 |
| D2 | Collect many real sessions (car, bus, tram) and aggregate; no simulated fleet | Accepted | Fleet simulator | 02 §3 |
| D3 | Session files uploaded to S3 are the main dataset; live upload is a capability | Accepted | Live-only ingest | 02 §3, §7 |
| D4 | Streaming with Kinesis on-demand (+ Firehose archive) | Accepted | Kafka on MSK, self-hosted Redpanda | 02 §5, §6 |
| D5 | Ingest: API Gateway HTTP API + Lambda outside the VPC; duplicates removed in the database | Accepted | DynamoDB duplicate check (data-loss bug) | 02 §5 |
| D6 | Processing in Python on ECS Fargate; same code for live and batch | Accepted | Lambda windows, Managed Flink | 02 §5, §9 |
| D7 | RDS PostgreSQL `db.t4g.micro` + PostGIS; raw samples stay in S3 as Parquet | Accepted | Aurora Serverless, Timestream, DynamoDB | 02 §3, §5 |
| D8 | Road segments as H3 hexagons first, OSM snapping later | Superseded by D18 | OSM snapping from day one | 02 §8 |
| D9 | Cross-vehicle normalization by regression; sickness not normalized | Accepted | Raw averages | 02 §9 |
| D10 | Replay tool sends recorded trips through the live API (test and demo) | Accepted | Video only | 02 §5 |
| D11 | No NAT gateway; Fargate in public subnets, database private | Accepted | NAT gateway | 02 §5 |
| D12 | Terraform, one cloud environment, S3 state with native locking | Accepted | CDK, SAM; dev + demo environments | 02 §12 |
| D13 | GitHub Actions only, OIDC to AWS | Accepted | Second CI/CD system | 02 §13 |
| D14 | Job queue on SQS | Accepted | RabbitMQ (Amazon MQ) | 02 §6 |
| D15 | Audio off on public transport; replays excluded from aggregates | Accepted | n/a | 02 §10 |
| D16 | Read API logs in to RDS with IAM auth; processor uses its own writer user from Secrets Manager | Accepted | Secrets Manager VPC endpoint or NAT for the read Lambda | 02 §5 |
| D17 | Live raw batches archived to S3 by Firehose (newline-delimited JSON, gzip) | Accepted | Archive code in the processor | 02 §5 |
| D18 | Road segments are H3 hexagons only; OSM road snapping dropped | Accepted | OSM snapping as a later upgrade | 02 §8, §19 |
| D19 | Dropped from scope: Athena/Glue, lateral sickness metric, checkov, iOS CI build | Accepted | Keeping them as optional extras | 02 §19 |
| D20 | Uploads end with a `_complete.json` marker that triggers processing; uploaded files replace live results for the same session | Accepted | Triggering on `session.json` (written at trip start, could start on a half-uploaded folder) | 02 §5, §7 |

To change a decision: add a row with a new number, mark the old one "Superseded by Dxx", and explain why in the plan.
