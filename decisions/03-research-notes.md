# Research notes

> Collected 2026-11-20 by research agents (web search, mostly official AWS, Microsoft, HashiCorp and GitHub docs). **Unverified** marks facts that came from one secondary source or from memory. These notes support [02-infrastructure-plan.md](02-infrastructure-plan.md).
>
> The plan moved to Azure on 2026-11-20 (D21). The Azure facts come first; the AWS sections below are kept as background for decisions D1–D20. Signal processing and dashboard notes apply to both.

## Azure prices (North Europe, USD, Azure Retail Prices API, 2026-11-20)

| Service | Meter | Price |
|---|---|---|
| Event Hubs Basic | throughput unit | $0.015 per hour |
| Event Hubs Basic | ingress events | $0.028 per million (events counted in 64 KB units) |
| Service Bus Basic | messaging operations | $0.05 per million |
| Container Apps (Consumption) | vCPU active / idle | $0.000024 / $0.000003 per vCPU-second |
| Container Apps (Consumption) | memory active / idle | $0.000003 / $0.000003 per GiB-second |
| Container Apps (Consumption) | requests | $0.40 per million |
| Container Registry Basic | registry unit; storage | $0.1666 per day; $0.10 per GB-month |
| PostgreSQL Flexible Server | `B1MS` compute; storage; backup | $0.018 per hour; $0.1265 per GB-month; $0.095 per GB-month |
| Functions Flex Consumption (on demand) | executions; execution time | first 250,000 free, then $0.000004 per 10; first 100,000 GB-s free, then $0.000026 per GB-s |
| Functions Flex Consumption (always ready) | baseline; execution time | $0.000004 per GB-s; $0.000016 per GB-s (no free grant) |
| Event Grid | operations | first 100,000 free, then $0.06 per 100,000 |

Not from the API: standard static public IPv4 about $0.005 per hour (from memory); Log Analytics first 5 GB per month per billing account free.

Sources: [Azure Retail Prices API](https://prices.azure.com/api/retail/prices) (filtered by `armRegionName eq 'northeurope'` and service), [Event Hubs export pricing note](https://learn.microsoft.com/en-us/troubleshoot/azure/azure-monitor/diagnostic-settings/data-flow/troubleshoot-data-export-pricing-problems), [Log Analytics pricing](https://azure.microsoft.com/pricing/details/log-analytics/).

## Azure accounts and free offers

- **Free account:** $200 credit within 30 days, plus 12 months of selected free services and always-free services. Within 30 days or when the credit runs out, the subscription must be upgraded to pay-as-you-go by removing the spending limit. Credits can't pay for support plans, Azure DevOps, Marketplace or third-party products. One free account per customer. Compute may be removed after 90 days of inactivity.
- **12-month free services used here:** PostgreSQL Flexible Server `B1MS` (750 hours, 32 GB storage, 32 GB backup per month; new customers only; the 12 months start at sign-up) and one Standard Container Registry (100 GB, 10 webhooks).
- **Monthly free grants:** Container Apps 180,000 vCPU-s, 360,000 GiB-s and 2 million requests per subscription; Functions Flex Consumption 100,000 GB-s and 250,000 executions per subscription (on-demand meters only).
- **Azure for Students:** $100 credit within 12 months, no card, full-time students at accredited degree-granting schools, verified by school email; the subscription is disabled when the credit runs out. Annual renewal is mentioned on one Microsoft page but not in the offer terms (**unverified**).
- **Static Web Apps Free:** 100 GB traffic per month per subscription (no overage: the site stops being served), 250 MB per app, 500 MB total, 10 apps per subscription, 2 custom domains per app.
- **AWS for comparison:** the new AWS Free plan does not include Kinesis Data Streams or Firehose; they need the Paid plan.

Sources: [free account terms](https://azure.microsoft.com/pricing/offers/ms-azr-0044p/), [Azure free services](https://azure.microsoft.com/en-gb/pricing/free-services/), [PostgreSQL on the free account](https://learn.microsoft.com/azure/postgresql/flexible-server/how-to-deploy-on-azure-free-account), [Azure for Students](https://azure.microsoft.com/en-us/pricing/offers/ms-azr-0170p/), [Container Apps billing](https://learn.microsoft.com/azure/container-apps/billing), [Flex Consumption plan](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan), [Static Web Apps quotas](https://learn.microsoft.com/azure/static-web-apps/quotas), [AWS services on the new sign-up](https://docs.aws.amazon.com/accounts/latest/reference/supported-services-sign-up-new.md).

## Azure service behaviour

- **Event Hubs Basic:** 1 consumer group, 256 KB per event, 1 day retention, 32 partitions per hub, 10 hubs and 100 connections per namespace, no Capture, no private link or IP firewall. Microsoft's tier tables don't say whether Basic supports Entra (RBAC) login or disabling local auth; Entra login with the "Azure Event Hubs Data Sender/Receiver" roles is documented for Event Hubs in general (**test on day 0**).
- **Service Bus Basic:** queues only (no topics), 256 KB messages, dead-letter queue and max delivery count, message lock up to 5 minutes (secondary sources; the quotas page doesn't list it).
- **Event Grid → Service Bus:** delivery with a system- or user-assigned identity holding "Azure Service Bus Data Sender" on the queue is supported, including Basic-tier Service Bus queues.
- **Container Apps networking:** workload profiles environments need at least a `/27` subnet (14 addresses reserved), the size can't change later, and NAT gateway or UDR egress is only possible there. An environment in a custom VNet is billed one standard static public IP for egress, plus one for ingress if it is external.
- **Container Apps Jobs:** event-driven jobs use ScaledJob-based KEDA scalers; Service Bus, Storage Queue and Event Hubs rules can log in with a managed identity (`identity_id` on `event_trigger_config.scale.rules` in `azurerm_container_app_job`; `--scale-rule-identity` in the CLI). The identity needs "Azure Service Bus Data Receiver". A Microsoft Q&A answer reports that suspending or updating a job can break its trigger until the job is recreated (**anecdotal**). Jobs pay no idle or request charges.
- **Default outbound access:** for API versions after 31 March 2026, subnets in new VNets have `defaultOutboundAccess = false`; existing VNets are unchanged. Microsoft recommends a NAT gateway. In Terraform, `azurerm_subnet.default_outbound_access_enabled` defaults to `true`.
- **Flex Consumption:** VNet integration needs a dedicated subnet delegated to `Microsoft.App/environments` (no underscores in its name; `Microsoft.App` provider registered); North Europe was a launch region (check with `az functionapp list-flexconsumption-locations`); Python 3.12 and 3.13 are GA.
- **Functions and gzip request bodies:** not documented; community reports suggest bodies arrive as sent, so the code checks the gzip magic bytes itself.
- **PostgreSQL Flexible Server and Entra:** an Entra admin can be a user, group, service principal or managed identity; enabling Entra restarts the server; roles for identities are created with `pgaadauth_create_principal_with_oid(role, object_id, 'service', is_admin, is_mfa)` and tokens are matched by object ID. With private access (VNet), allow outbound traffic to the `AzureActiveDirectory` service tag; NSG rules with application security groups aren't supported on that subnet. Extensions must be allow-listed in `azure.extensions`.
- **PostgreSQL TLS:** Azure rotates intermediate CAs (from November 2025 into 2026) without announcing each change; the root CAs (DigiCert Global Root G2, Microsoft RSA Root CA 2017, Microsoft TLS RSA Root G2) stay. Microsoft recommends `sslmode=require` and calls `verify-ca`/`verify-full` unsupported in this context.
- **GitHub OIDC immutable subjects:** repositories created after 2026-07-15 (and renames or transfers after that date) get subjects with numeric IDs: `repo:<owner>@<owner_id>/<repo>@<repo_id>:...`. Entra federated credentials must match that format. Our repo: created 2026-11-20, owner ID 163877193, repo ID 1465690625.

Sources: [Event Hubs tiers](https://learn.microsoft.com/en-us/azure/event-hubs/compare-tiers), [Event Hubs quotas](https://learn.microsoft.com/en-us/azure/event-hubs/event-hubs-quotas), [Event Hubs managed identity](https://learn.microsoft.com/azure/event-hubs/authenticate-managed-identity), [Service Bus quotas](https://learn.microsoft.com/azure/service-bus-messaging/service-bus-quotas), [Event Grid managed identity delivery](https://learn.microsoft.com/en-us/azure/event-grid/deliver-events-using-managed-identity), [Service Bus as Event Grid handler](https://learn.microsoft.com/azure/event-grid/handler-service-bus), [Container Apps custom VNets](https://learn.microsoft.com/azure/container-apps/custom-virtual-networks), [Container Apps networking](https://learn.microsoft.com/azure/container-apps/networking), [Container Apps scale rules](https://learn.microsoft.com/azure/container-apps/scale-app), [Q&A: job not triggered](https://learn.microsoft.com/en-us/answers/questions/5762857/container-application-job-not-triggered-when-a-mes), [azurerm container_app_job docs](https://github.com/hashicorp/terraform-provider-azurerm/blob/main/website/docs/r/container_app_job.html.markdown), [default outbound access](https://learn.microsoft.com/azure/virtual-network/ip-services/default-outbound-access), [azurerm subnet docs](https://github.com/hashicorp/terraform-provider-azurerm/blob/main/website/docs/r/subnet.html.markdown), [Functions networking](https://learn.microsoft.com/azure/azure-functions/functions-networking-options), [Functions languages](https://learn.microsoft.com/azure/azure-functions/supported-languages), [PostgreSQL Entra concepts](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-azure-ad-authentication), [PostgreSQL Entra roles](https://learn.microsoft.com/azure/postgresql/flexible-server/how-to-manage-azure-ad-users), [PostgreSQL Entra configuration](https://learn.microsoft.com/en-ca/azure/postgresql/security/security-entra-configure), [PostgreSQL TLS](https://learn.microsoft.com/azure/postgresql/flexible-server/security-tls), [GitHub immutable subjects](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens), [Entra immutable subjects](https://learn.microsoft.com/entra/workload-id/workload-identities-github-immutable-subjects).

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
- Azure: `azurerm` backend with `use_azuread_auth = true` and `use_oidc = true` (blob leases lock the state); `azure/login@v2` with a federated credential on a user-assigned managed identity, using the immutable `sub` format above.

Sources: [Terraform S3 backend](https://developer.hashicorp.com/terraform/language/v1.15.x/settings/backends/s3), [GitHub OIDC in AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws), [configure-aws-credentials](https://github.com/aws-actions/configure-aws-credentials/releases), [LocalStack licensing](https://docs.localstack.cloud/aws/licensing/).

## Dashboard

- MapLibre GL JS with OpenFreeMap tiles (no key, no SLA; keep a MapTiler free key as a fallback). Don't use `tile.openstreetmap.org` from an app.
- GeoJSON from PostGIS (`ST_AsGeoJSON`) is enough for thousands of segments; vector tiles aren't needed.
- uPlot is the fastest option for long time series; decimate server-side.
- For a handful of viewers, polling is simplest. API Gateway WebSockets cost $1 per million messages; AppSync Events is the serverless push option.

Sources: [OpenFreeMap](https://openfreemap.org/), [uPlot](https://github.com/leeoniya/uPlot), [API Gateway pricing](https://aws.amazon.com/api-gateway/pricing/).

## Signal processing

- **ISO 2631-1 Wf** (motion sickness, vertical axis). Parameters agree between memory and an independent open-source implementation. Checked (2026-11-21) against Wf's one-third-octave values 0.02–4 Hz as calculated by Virtins and the first row of ISO's Table 3 (ANSI S2.72 preview): the analog filter is within 0.06 %, the backend's digital one within 1 % up to 0.63 Hz:
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
- **MSDV** = √(∫ a_w² dt) in m/s^1.5. Motion sickness incidence ≈ (1/3) · MSDV_z, as a percentage of unadapted adults who may vomit, for exposures of 20 minutes to 6 hours (secondary sources: the VTI report quoting ISO 2631-1 and Lawther & Griffin 1987). The backend applies it to the combined vertical + lateral MSDV (D49); no published factor exists for lateral motion.
- **Lateral weighting (Donohew & Griffin, 2004):** an acceleration weighting, flat from 0.0315 to 0.25 Hz, then −12 dB per octave (proportional to displacement) to 0.8 Hz; it "may not apply where roll accompanies lateral motion" (abstract). Exact coefficients not found; D50 fits a realizable filter to the straight line. BS 6841 and ISO 2631-1 weight only vertical motion for sickness. TNO (Bos, 2024) reports that the ISO weighting may underestimate symptoms and that the sickness peak sits near 0.23 Hz.
- **Road roughness:** RMS of vertical acceleration is the most common proxy. Studies use ~100 m segments; 10 m is too noisy. Speed dependence follows a power law, so fit it from data rather than dividing by speed.
- **Pothole detection:** Z-threshold, Z-diff, std-dev and G-zero methods (Mednis et al.). They need a fixed mount; evaluate with precision and recall against labels.
- **Map matching:** OSRM `/match`, Valhalla Meili, or PostGIS snapping. H3 hexagons are a no-import alternative.

Sources: [ISO2631.m reference implementation](https://github.com/janiex/SimulinkMatlab/blob/master/Matlab/ISO2631.m), [NI human vibration filters](https://www.ni.com/en/support/documentation/supplemental/08/human-vibration-weighting-filters-in-labview-sound-and-vibration.html), [Virtins weighting tables](https://www.virtins.com/doc/Frequency-Weightings-for-Sound-and-Vibration-Perceived-by-Humans-using-Multi-Instrument.pdf), [ANSI S2.72 / ISO 2631-1 preview](https://webstore.ansi.org/preview-pages/ASA/preview_ANSI+S2.72+Part+1-2002+(R+2007)+++ISO+2631-1-1997.pdf), [VTI report (MSI)](https://www.diva-portal.org/smash/get/diva2:675200/FULLTEXT01.pdf), [Donohew & Griffin 2004](https://eprints.soton.ac.uk/28230), [TNO Bos 2024](https://publications.tno.nl/publication/34645611/uTQT32eq/bos-2024-advancing.pdf), [smartphone roughness validation](https://arxiv.org/pdf/1902.10699), [roughness review](https://arxiv.org/pdf/2411.07315).
