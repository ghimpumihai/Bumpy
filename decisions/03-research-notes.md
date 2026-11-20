# Research notes

> Collected 2026-11-20 by research agents (web search, mostly official AWS, Microsoft, HashiCorp and GitHub docs). **Unverified** marks facts that came from one secondary source or from memory. These notes support [02-infrastructure-plan.md](02-infrastructure-plan.md).
>
> The plan moved to Azure on 2026-11-20 (D21). The Azure facts come first; the AWS sections below are kept as background for decisions D1–D20. Signal processing and dashboard notes apply to both.

## Azure account and free offers

- **Free account:** $200 credit valid for 30 days, plus 12 months of selected free services and a set of always-free services. A spending limit is on by default: when the credit is used up, services are disabled rather than billed. After 30 days, the account must be upgraded to pay-as-you-go to keep resources running; 12-month free services continue.
- **PostgreSQL Flexible Server:** 750 hours per month of Burstable `B1ms`, 32 GB storage and 32 GB backup storage, free for 12 months. New customers only; the 12 months start when the account is created. The portal still shows an "estimated cost" while creating it.
- **Azure for Students:** credit without a card for eligible students; amount and limits **unverified** for 2026.
- **AWS for comparison:** the new AWS Free plan does not include Kinesis Data Streams or Firehose; they need the Paid plan.

Sources: [Azure free account](https://azure.microsoft.com/en-us/pricing/purchase-options/azure-account?cid=msft_learn), [Azure free services](https://azure.microsoft.com/en-gb/pricing/free-services/), [PostgreSQL on the free account](https://learn.microsoft.com/azure/postgresql/flexible-server/how-to-deploy-on-azure-free-account), [AWS services on the new sign-up](https://docs.aws.amazon.com/accounts/latest/reference/supported-services-sign-up-new.md), [AWS Free Tier FAQs](https://aws.amazon.com/free/faqs/).

## Azure services

- **Event Hubs Basic:** 1 consumer group per event hub, 256 KB maximum message, 1 day maximum retention, 100 connections per namespace, no Capture. Price about $0.015 per throughput-unit hour plus about $0.028 per million events (**unverified**, check the calculator). Capture is a paid add-on on Standard, billed per throughput-unit hour, and writes Avro.
- **Functions Flex Consumption:** monthly free grant of 100,000 GB-s and 250,000 executions per subscription, on the on-demand meters of pay-as-you-go subscriptions; always-ready instances have no free grant; the plan's storage account is billed separately. Supports VNet integration. Whether the Functions host decompresses a `Content-Encoding: gzip` request body is **unverified**; the ingest code handles gzip itself and must be tested with a real request.
- **Container Apps:** monthly free grant of 180,000 vCPU-seconds, 360,000 GiB-seconds and 2 million requests per subscription (from memory, **unverified** for 2026). Jobs can be event-triggered by KEDA scalers, including Service Bus with a managed identity.
- **Container Registry:** listed as free for 12 months (one Standard registry) on the free account, from one search result (**unverified**); Basic is about $5 per month.
- **Service Bus Basic:** queues only (no topics, no sessions), about $0.05 per million operations; dead-letter queue and max delivery count included. Lock duration up to 5 minutes, so long jobs must renew the lock.
- **Default outbound access:** new VNets no longer give subnets outbound internet by default; Terraform's `default_outbound_access_enabled` on each subnet keeps it on. How the Container Apps environment and Flex Consumption VNet integration get outbound in this case is **unverified**; test on day 1.
- **PostgreSQL extensions:** must be allow-listed in `azure.extensions` before `CREATE EXTENSION`. Entra users are created with `pgaadauth_create_principal_with_oid`, which only an Entra admin can run.

Sources: [Event Hubs quotas](https://learn.microsoft.com/en-us/azure/event-hubs/event-hubs-quotas), [Event Hubs tiers](https://learn.microsoft.com/en-us/azure/event-hubs/compare-tiers), [Event Hubs pricing](https://azure.microsoft.com/en-us/pricing/details/event-hubs/), [Flex Consumption plan](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan), [Functions pricing](https://azure.microsoft.com/pricing/details/functions/).

## AWS streaming (background for D1–D20)

| Option | Price (us-east-1) | Notes |
|---|---|---|
| Kinesis Data Streams, on-demand | $0.04 per stream-hour, $0.08/GB in, $0.04/GB out | Public endpoint with IAM. Default retention 24 h, up to 365 days. |
| Kinesis Firehose to S3 | $0.029/GB (+ $0.018/GB for Parquet conversion) | Can also read from MSK at $0.055/GB. |
| MSK Serverless | $0.75 per cluster-hour + $0.0015 per partition-hour + $0.10/GB in + $0.05/GB out | IAM auth mandatory. PrivateLink/VPC access only, no public access. 200 MB/s ingress per cluster. |
| MSK Provisioned | e.g. m7g.large $0.204/h per broker | Public access only enabled after creation, with many prerequisites. t3 brokers allow 4 new IAM connections per second per broker. |
| Amazon MQ (RabbitMQ) | mq.m5.large 3-node cluster ≈ $0.86/h | Single small instances exist; price **unverified**. |
| SQS | 1M requests/month free | Right tool for job queues. |

Other notes:
- Lambda tumbling windows on Kinesis cap state at 1 MB per shard, too small for per-vehicle filter state.
- Managed Flink: $0.11 per KPU-hour, plus 1 orchestration KPU. Packaging numpy and scipy for PyFlink is **unverified**.
- Python stream libraries:
  - plain `confluent-kafka` or `boto3` consumers are simplest;
  - Quix Streams is maintained;
  - Bytewax's company wound down (GitHub issue #560);
  - the faust-streaming fork has unclear maintenance.

Sources: [MSK pricing](https://aws.amazon.com/msk/pricing/), [MSK limits](https://docs.aws.amazon.com/msk/latest/developerguide/limits.html), [MSK Serverless](https://docs.aws.amazon.com/msk/latest/developerguide/serverless.html), [Kinesis pricing](https://aws.amazon.com/kinesis/data-streams/pricing/), [Firehose pricing](https://aws.amazon.com/firehose/pricing/), [Lambda Kinesis windows](https://docs.aws.amazon.com/lambda/latest/dg/services-kinesis-windows.html), [Managed Flink pricing](https://aws.amazon.com/kinesis/analytics/pricing), [Amazon MQ pricing](https://aws.amazon.com/amazon-mq/pricing/), [Bytewax status](https://github.com/bytewax/bytewax/issues/560).

## AWS account and quotas

- New accounts: up to $200 in credits ($100 at signup plus up to $100 from activities), valid 6 months.
- On the **Free plan**, Kinesis, Firehose and MSK are not available; upgrading to the Paid plan is needed. Lambda, API Gateway, RDS, ECS, S3, SQS, Glue and Athena are available on the Free plan. Whether credits carry over after the upgrade is **unverified**.
- New accounts can have Lambda concurrency capped low (reports of 10). Check Service Quotas.

Sources: [AWS Free Tier](https://aws.amazon.com/free/), [Lambda quotas](https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html), [re:Post on concurrency 10](https://repost.aws/questions/QUto8jBkZtQfSL-Qr3XEHybg/what-can-i-do-about-lambda-concurrency-being-set-to-10-in-new-accounts-even-though-default-is-1000).

## AWS ingest and storage

- **API Gateway HTTP API:** $1.00 per million requests. No API keys or usage plans (those are REST-only). Supports Lambda authorizers, JWT and mutual TLS (needs a custom domain). Whether HTTP API decompresses a gzip request body is **unverified**; the ingest code handles base64 and gzip itself and must be tested with a real request.
- **Lambda:** 6 MB synchronous payload limit. $0.20 per million requests plus compute; free tier of 1M requests and 400k GB-s per month.
- **S3 presigned URLs:** valid up to 7 days; multipart for large files.
- **IoT Core MQTT:** $1.00 per million messages, $0.08 per million connection-minutes. Not worth the certificate setup for one phone.
- **Timestream for LiveAnalytics:** closed to new customers since 2025-06-20.
- **Aurora PostgreSQL Serverless v2:** can scale to 0 ACU with auto-pause on recent versions; $0.12 per ACU-hour. Resume latency **unverified**.
- **RDS PostgreSQL** supports PostGIS (e.g. 3.5.x on PG 17).
- **Athena:** $5 per TB scanned. **Glue Data Catalog:** first 1M objects free.
- **Secrets Manager:** $0.40 per secret per month. **WAF:** $5 per web ACL per month plus rules. **Cognito:** free up to 10k MAU. **Managed Grafana:** $9 per editor per month.
- **CloudWatch Logs:** $0.50/GB ingested, 5 GB free.
- **NAT gateway:** $0.045/h per AZ plus $0.045/GB. **Public IPv4:** $0.005/h per address. **S3 and DynamoDB gateway endpoints:** free.

Sources: [API Gateway pricing](https://aws.amazon.com/api-gateway/pricing/), [HTTP vs REST APIs](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-vs-rest.html), [compressed payloads](https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-make-request-with-compressed-payload.html), [Lambda pricing](https://aws.amazon.com/lambda/pricing/), [S3 presigned uploads](https://docs.aws.amazon.com/AmazonS3/latest/userguide/PresignedUrlUploadObject.html), [IoT Core pricing](https://aws.amazon.com/iot-core/pricing/), [Timestream availability change](https://docs.aws.amazon.com/timestream/latest/developerguide/AmazonTimestreamForLiveAnalytics-availability-change.html), [Aurora pricing](https://aws.amazon.com/rds/aurora/pricing/), [RDS PostgreSQL extensions](https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-extensions.html), [Athena pricing](https://aws.amazon.com/athena/pricing/), [VPC pricing](https://aws.amazon.com/vpc/pricing/).

## Terraform and CI/CD

- S3 backend native locking: `use_lockfile = true` (Terraform 1.10+). The DynamoDB lock table is deprecated since 1.11.
- `terraform-aws-modules`: vpc v6, ecs v6 and msk v3 are current major versions. Pin with `~>` and check each changelog.
- GitHub OIDC to AWS:
  - an IAM OIDC provider for `token.actions.githubusercontent.com` with audience `sts.amazonaws.com`;
  - roles trusted on the `sub` claim (`repo:ORG/REPO:pull_request`, `repo:ORG/REPO:environment:prod`);
  - `aws-actions/configure-aws-credentials@v6`.

  Repos created after 2026-07-15 may use immutable IDs in `sub`; check the real claim if matching fails.
- Standard GitHub-hosted runners, including macOS, are free for public repos.
- LocalStack merged Community and Pro in March 2026 and now requires an auth token.
- Azure equivalents (from memory, check the docs while building): `azurerm` backend with `use_azuread_auth = true` and `use_oidc = true` (blob leases lock the state); `azure/login@v2` with a federated credential on a user-assigned managed identity, trusted on the same `sub` claims as above.

Sources: [Terraform S3 backend](https://developer.hashicorp.com/terraform/language/v1.15.x/settings/backends/s3), [GitHub OIDC in AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws), [configure-aws-credentials](https://github.com/aws-actions/configure-aws-credentials/releases), [LocalStack licensing](https://docs.localstack.cloud/aws/licensing/).

## Dashboard

- MapLibre GL JS with OpenFreeMap tiles (no key, no SLA; keep a MapTiler free key as a fallback). Don't use `tile.openstreetmap.org` from an app.
- GeoJSON from PostGIS (`ST_AsGeoJSON`) is enough for thousands of segments; vector tiles aren't needed.
- uPlot is the fastest option for long time series; decimate server-side.
- For a handful of viewers, polling is simplest. API Gateway WebSockets cost $1 per million messages; AppSync Events is the serverless push option.

Sources: [OpenFreeMap](https://openfreemap.org/), [uPlot](https://github.com/leeoniya/uPlot), [API Gateway pricing](https://aws.amazon.com/api-gateway/pricing/).

## Signal processing

- **ISO 2631-1 Wf** (motion sickness, vertical axis). Parameters agree between memory and an independent open-source implementation; the ISO table itself has not been read:
  - f1 = 0.08 Hz, f2 = 0.63 Hz (band-limiting, Q = 1/√2);
  - f4 = 0.25 Hz with Q4 = 0.86;
  - f5 = 0.0625 Hz with Q5 = 0.80;
  - f6 = 0.1 Hz with Q6 = 0.80;
  - gain 1.

  Expected magnitude (calculated from those parameters, for tests):
  - about 0 dB at 0.16 Hz;
  - −3.2 dB at 0.1 Hz;
  - −1.4 dB at 0.25 Hz;
  - −13.0 dB at 0.5 Hz;
  - −32.6 dB at 1 Hz.
- **MSDV** = √(∫ a_w² dt) in m/s^1.5. Motion sickness incidence ≈ (1/3) · MSDV_z, as a percentage of unadapted adults who may vomit (one secondary source).
- **Lateral weighting (Donohew & Griffin, 2004):** flat from 0.0315 to 0.25 Hz, then −12 dB per octave to 0.8 Hz. Exact coefficients not found. TNO (Bos, 2024) reports that the ISO weighting may underestimate symptoms and that the sickness peak sits near 0.23 Hz.
- **Road roughness:** RMS of vertical acceleration is the most common proxy. Studies use ~100 m segments; 10 m is too noisy. Speed dependence follows a power law, so fit it from data rather than dividing by speed.
- **Pothole detection:** Z-threshold, Z-diff, std-dev and G-zero methods (Mednis et al.). They need a fixed mount; evaluate with precision and recall against labels.
- **Map matching:** OSRM `/match`, Valhalla Meili, or PostGIS snapping. H3 hexagons are a no-import alternative.

Sources: [ISO2631.m reference implementation](https://github.com/janiex/SimulinkMatlab/blob/master/Matlab/ISO2631.m), [NI human vibration filters](https://www.ni.com/en/support/documentation/supplemental/08/human-vibration-weighting-filters-in-labview-sound-and-vibration.html), [Donohew & Griffin 2004](https://eprints.soton.ac.uk/28230), [TNO Bos 2024](https://publications.tno.nl/publication/34645611/uTQT32eq/bos-2024-advancing.pdf), [smartphone roughness validation](https://arxiv.org/pdf/1902.10699), [roughness review](https://arxiv.org/pdf/2411.07315).
