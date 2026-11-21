# Infrastructure plan: Azure backend

> **Status:** final, 2026-11-20. Every open point was researched (prices from the Azure Retail Prices API, behaviour from Microsoft Learn and the Terraform provider docs); the answers and what they changed are in §20 (D34–D36). Moved from AWS to Azure the same day (D21 to D31 in the [decision log](README.md)). The AWS version, which was researched and reviewed by an independent advisor model, is in git history (commit `83e1dec`); everything that does not depend on the cloud (data model, processing, aggregation, data-quality rules) carries over unchanged. Later the same day, the **live path (phone → cloud → dashboard) became the main path**, with laptop upload only as a fallback (D32, D33). The app side is in [01-initial-plan.md](01-initial-plan.md); research sources are in [03-research-notes.md](03-research-notes.md).
>
> **Who this is for:** anyone on the team, including people who have not used these Azure tools before. Every tool is explained in plain words in §5, together with why we picked it and what we rejected.

---

## 1. The plan in one paragraph

Phones record trips (a "session") in cars, buses and trams and **send them to the cloud while driving**: every 2 seconds the app posts a batch of sensor data to an **ingest function**, which puts it into **Event Hubs** (a stream). A **stream processor** turns the batches into road-quality and motion-sickness numbers per small piece of road and stores them in a **PostgreSQL database with PostGIS** (maps support). The **web dashboard** shows the vehicle moving on the map, the road colouring in and the sickness score rising, a few seconds behind the phone. When a trip ends, a **finalize job** reprocesses the whole trip from the archived batches, and an **aggregation step** combines all trips, so every trip makes the shared map better. If the phone has no network, the app keeps the batches on disk and sends them later; only if a trip never reaches the cloud is its folder uploaded from a laptop, through the same finalize job. A **replay tool** sends a recorded trip through the live path, so we can show "live" in the presentation room without a car. Everything is created by **Terraform** (infrastructure as code) and deployed by **GitHub Actions** (CI/CD).

---

## 2. What changed

### From the first plan

| Topic | First plan | Now | Why |
|---|---|---|---|
| Cloud | Azure | **Azure**, region **North Europe** (Ireland) | We moved to AWS and back (see below). North Europe is a large, mature region with every service we need. |
| Where the data comes from | One test drive | **Many real trips** in cars, buses, trams, aggregated | More real data makes a better map and an honest story. No simulated cars. |
| How data reaches the cloud | Live upload | **Live upload is the main path**; laptop upload of session files is only a fallback | The product is phone → cloud → dashboard. Each batch carries every sensor at full rate, and the app's disk queue resends until the backend accepts it, so a bad network delays data but doesn't lose it. |
| Demo | Live drive | The **live dashboard** fed by a **replay** of a real trip through the live path, a **video** of a real drive, and if possible a car streaming live during the presentation | A presentation room has no moving car and unreliable Wi-Fi, so the replay is the safe version of the same path. |
| Streaming | Kafka considered | **Event Hubs (Basic)** | Same idea as Kafka, much less setup and cost at our volume. See §6. |

### From the AWS version (2026-11-20)

Why we went back to Azure:
- **The whole stack fits the free account.** On AWS, the new Free plan does not allow Kinesis or Firehose, so streaming would have forced the Paid plan, where anything above the credits goes on a card. On Azure everything here runs on the free account's $200 credit, and the account has a spending limit: when the credit runs out, resources stop instead of billing.
- **Some parts get simpler.** The PostgreSQL server is free for 12 months, Container Apps Jobs start the finalize job straight from the queue (on AWS this needed extra glue), and Static Web Apps hosts the dashboard for free.
- **No passwords at all.** Every service logs in to the database with its own Azure identity.

| AWS version | Azure now |
|---|---|
| S3 | Blob Storage |
| S3 event → SQS | Event Grid → Service Bus queue |
| ECS Fargate (processor, backfill) | Container Apps (processor) + Container Apps Jobs (finalize, aggregate, migrate) |
| ECR | Azure Container Registry |
| API Gateway + Lambda (ingest) | Azure Function with an HTTP trigger (no separate gateway) |
| Kinesis Data Streams | Event Hubs (Basic) |
| Firehose | The ingest function writes the raw archive itself |
| RDS PostgreSQL + PostGIS | Azure Database for PostgreSQL Flexible Server + PostGIS |
| RDS IAM login | Microsoft Entra login with managed identities |
| VPC, subnets, security groups | VNet, delegated subnets, network security groups |
| IAM roles | Managed identities + role assignments (RBAC) |
| Parameter Store + Secrets Manager + KMS | Key Vault; encryption at rest is on by default |
| S3 + CloudFront | Static Web Apps |
| CloudWatch + Budgets | Azure Monitor (Log Analytics, Application Insights) + Cost Management budgets |
| Terraform state in S3 | Terraform state in Blob Storage |
| GitHub OIDC → IAM role | GitHub OIDC → managed identity with a federated credential |

---

## 3. Does "collect a lot of real data" change the architecture?

Yes, in five places. The overall shape (capture, transmit, process, store, visualize) stays the same.

1. **The live stream is the dataset, not just a preview.** Each batch holds every sensor at full rate (only raw audio stays on the phone), and the app resends until the backend accepts it. So once a trip has ended and all its batches have arrived, a finalize job reprocesses it as a whole and it joins the dataset. Uploaded files are only needed when a phone never got a connection.
2. **A new aggregation layer.** We need to line up many trips on the same roads. That means fixed road segments (§8), a table of "one observation per session per segment", and a step that combines them. This is now core, not a stretch goal.
3. **Raw samples stay out of the database.** One hour of driving is about a million sensor rows. Fifty hours would be about fifty million rows, too much for a small database. So raw samples stay in Blob Storage as files (converted to Parquet, a compact column format), and the database only stores results: segments, events, a light track, and downsampled chart data. This keeps the database small and cheap no matter how much we drive.
4. **Every session carries its context.** Vehicle type, bus line, how the phone was mounted, seated or standing. Without that, a bumpy bus would look like a bumpy road. Normalization between vehicles is in §9.
5. **Data quality rules.** Some sessions will be bad (hand-held phone, phone moved). The pipeline marks them and keeps them out of the aggregated map automatically.

How much data is "a lot"? Expect about **5 to 15 sessions** in the time we have. The story to tell is "the method gets better with every trip", not "big data". Storage is no problem either way: each hour is about 100 to 150 MB (CSV plus audio), so even 50 hours is under 10 GB.

---

## 4. Architecture diagram

```mermaid
flowchart TB
  subgraph CAP["Capture"]
    phone["iPhone recorder<br/>car, bus, tram"]
    replay["Replay tool<br/>re-sends a recorded trip"]
    laptop["Laptop (fallback)<br/>uploads a session folder"]
  end

  subgraph AZ["Azure North Europe"]
    subgraph LIVE["Live path (main)"]
      ingest["Ingest Function<br/>batches + session metadata"]
      eh["Event Hubs<br/>ordered per device"]
      proc["Stream processor<br/>Container App"]
    end
    subgraph FIN["After each trip"]
      sb["Service Bus queue<br/>session ready"]
      fin["Finalize job<br/>Container Apps Job<br/>reprocess + aggregate"]
      blobS["Blob container: sessions<br/>fallback uploads"]
      eg["Event Grid<br/>_complete.json created"]
    end
    lake["Blob container: lake<br/>raw batches + Parquet samples"]
    pg[("PostgreSQL Flexible Server + PostGIS<br/>sessions, segments, results")]
    read["Read API<br/>Container App"]
    web["Dashboard<br/>live view + aggregated map<br/>Static Web Apps"]
    ops["Azure Monitor workbook<br/>+ budget alerts"]
  end

  gh["GitHub Actions<br/>Terraform + deploys (OIDC)"]

  phone -->|"HTTPS, gzip batch every 2 s"| ingest
  replay -->|"same API, real speed"| ingest
  ingest --> eh --> proc --> pg
  ingest -->|"raw archive"| lake
  proc -->|"trip ended, all batches in"| sb
  phone -.->|"only if the trip never reached the cloud"| laptop
  laptop -->|"tools/upload"| blobS --> eg --> sb
  sb --> fin
  lake --> fin
  blobS --> fin
  fin --> lake
  fin --> pg
  pg --> read --> web
  gh -.-> AZ
```

---

## 5. Every component: what it is, why we chose it

Read this section if a tool name is unfamiliar. Each entry says what the tool is in plain words, what job it does for us, and what we considered instead.

### Capture side

**iPhone recorder app** (built by our teammate, see [01-initial-plan.md](01-initial-plan.md)). Writes every sensor to CSV files on the phone first, so nothing is lost if the network fails. Every 2 seconds it builds a batch with all sensors at full rate (everything except raw audio), saves it in a **queue on disk**, and sends the queue oldest first, retrying with backoff until the backend accepts each batch. A dead zone therefore delays data, it doesn't lose it. It also sends the session's metadata (`session.json`: vehicle, mount, seat, posture) at Start and again at Stop, through the same queue, so the backend knows the context and when the trip ended. This metadata call is a **small addition to the app** (spec §6.1).

**Laptop upload (fallback)** (`tools/upload`, a few lines wrapping `azcopy copy --recursive` after `azcopy login`). Only for a trip that never reached the cloud (no network at all, upload switched off, or the app's queue was cleared). The session folder is AirDropped to a laptop and uploaded with one command. The script uploads all files first and writes a small `_complete.json` marker **last**, so processing never starts on a half-uploaded folder. Team members log in with their own Azure account; they need the "Storage Blob Data Contributor" role on the `sessions` container.

**Replay tool** (`tools/replay`, a small Python script). Reads a recorded session folder, builds the same 2-second batches the phone would send, and posts them to the real API at real speed (or faster). It is our end-to-end test before every drive, and our backup demo: in the room we can show the map updating live from a real trip. Replays are tagged `source=replay` with a new session ID, and are never counted in the aggregated map, so nothing is counted twice.

### Getting data into Azure

**Azure Functions (ingest function, Flex Consumption plan).** Azure Functions runs a small piece of code only when a request arrives; you pay per run, and it costs nothing when idle. An HTTP-triggered function already has a public HTTPS address with a certificate, so we don't need a separate API gateway. It serves two routes:

| Route | What it does |
|---|---|
| `POST /api/ingest` | one 2-second batch (spec §6) |
| `PUT /api/ingest/sessions/{sessionId}` | the session's metadata, sent at Start and at Stop (spec §6.1) |

There is no health route. The app tests its connection with a **probe**: a gzipped `{"probe":true}` with the device key and the header `x-probe: 1`, sent to `/api/ingest`. Because the function checks the key before the body, the answer tells the app everything it needs: `401`/`403` = wrong key, `400` = reachable and key accepted (the probe is rejected and never stored), `404` = wrong address. `src/mobile-ios/tools/mock_ingest_server.py` implements exactly this order and is the reference for the function's responses.

For each batch or metadata message the function:
- checks the `x-device-key` header against hashed device keys (stored in Key Vault, loaded once at start-up, compared in constant time so timing can't leak them);
- decompresses the gzip body and checks its format (with pydantic, a Python validation library), and rejects bodies over 200 KB. The Functions host does not document whether it decompresses request bodies itself, so the code checks the gzip magic bytes (`1f 8b`) and only decompresses when they are there; that works either way;
- sends it to Event Hubs as **decompressed JSON**, marked `kind=batch` or `kind=session`, with the **device ID as the partition key**, so a phone's metadata and batches stay in the order the phone sent them;
- writes it to the raw archive under `lake/raw/session=<sessionId>/` (`<batchSeq>.json.gz` or `session.json.gz`), then answers `200`, for a new batch and for a repeat alike (it can't tell them apart; the database drops repeats). Invalid bodies get `400`/`422` with a reason; the app moves those to its `upload_failed/` folder.

The archive file name comes from the message itself, so if the phone retries, the same file is simply overwritten: no duplicates in the archive. Duplicates in the stream are removed later in the database (§8). The archive is the long-term copy of every trip: the finalize job rebuilds a whole trip from it.

It runs **outside** our private network (VNet) on purpose: it then needs no network setup and reaches Event Hubs, Blob Storage and Key Vault directly over their public, login-protected endpoints. Abuse is limited by the device keys and by a cap on how many copies of the function may run at once (`maximum_instance_count`), so a flood of bad requests can't run up the bill.

Setup details: Python 3.12 (GA on Flex Consumption), instance memory 512 MB (billing counts memory × time, so the free grant lasts longer), North Europe (one of the first Flex Consumption regions; confirm with `az functionapp list-flexconsumption-locations` on day 0).

*Rejected:* API Management (an extra service and extra configuration for what the function already does; it can be put in front later if we need per-client throttling).

*Why no duplicate check here?* The AWS design once wrote a "seen" record to a separate store first. The advisor found a data-loss bug: if that record was written but the next step failed, the phone's retry would get "duplicate" and delete the batch, and the data would be gone. Duplicates are removed in the database instead (§8), where it is safe.

**Event Hubs (Basic tier, 1 throughput unit, 2 partitions).** A stream is an ordered, durable log of messages. Producers append to it; consumers read from it at their own pace. Messages stay for 1 day, so if the processor crashes or is redeployed, nothing is lost: it continues where it stopped. Messages are split into "partitions" by a key; we use the **device ID**, so each phone's batches stay in order, which our filters need.

*Why have a stream at all, with only a few phones?* Honestly, not for volume. We keep it because it:
- **decouples** receiving data from processing it, so the phone always gets a fast answer even if processing is slow or down;
- keeps **order per device**, which matters because the filters carry state from one batch to the next, and because the Stop metadata must arrive after the trip's last batch;
- **buffers** a day of data, so a processor crash or redeploy during a drive loses nothing;
- costs about **$0.36 per day**.

Basic tier limits that matter: one reader group (fine, only the processor reads; the archive is written by the ingest function), 256 KB per message (a batch is about 30 KB, billed as one event because events are counted in 64 KB units), 1 day of retention, up to 32 partitions, 100 connections per namespace. Price in North Europe: $0.015 per throughput-unit hour plus $0.028 per million events.

Login: the ingest function and processor use their managed identities ("Azure Event Hubs Data Sender" / "Data Receiver" roles) and key-based access is switched off. Microsoft's tier tables don't list authentication per tier, so on day 0 we send one test event with a managed identity; if Basic refused it, the fallback is a send-only and a listen-only access key stored in Key Vault. *Rejected:* Event Hubs Standard with **Capture**, which writes the stream to storage by itself, like Firehose. Capture costs extra per hour on Standard and writes Avro files instead of plain JSON; a few lines in the ingest function do the same job for free. See §6 for Kafka and others.

### Processing: live, then once more per trip

**Stream processor.** Reads Event Hubs continuously and handles each message within a second or two:
- a `session` message creates or updates the trip and its context (vehicle, mount, seat);
- a `batch` message runs the same calculations as the full pipeline (§9), incrementally: it updates the vehicle's live position and scores, writes segment observations as each 25 m hexagon is passed, adds detected potholes and the downsampled chart data;
- it records how far it has read in the same database transaction, so a restart continues exactly where it left off.

Gaps and late data. If a batch number is skipped (still queued on the phone, or rejected), the processor resets its filters at the gap and flags it; when a dead zone ends, the phone sends a burst of older batches, which the dashboard shows as "catching up" rather than live. These live results are good enough to watch, and the finalize job replaces them with exact ones.

**Trip end.** A trip is ready when its Stop metadata has arrived (it carries the number of batches) and every batch up to that number is in. The processor then puts a "session ready" message in the Service Bus queue. If no Stop arrives (app crashed, phone died), a trip with no new batch for 15 minutes is closed as incomplete and finalized anyway, with its gaps marked.

**Finalize job.** Runs once per finished trip, a few seconds after it ends. It reads the whole trip, either from the raw archive (live trips) or from the uploaded folder (fallback), recomputes everything over the complete trip in one pass (no gaps, filters run over the whole signal), writes Parquet samples to `lake`, replaces the trip's live results in the database, then runs the aggregation step (§9). If a trip arrives both ways, the uploaded folder wins, since it also has the samples a failed batch may have lost.

**Blob Storage.** Azure's file storage ("containers" of files in a storage account). Very cheap, very durable, and the place where all raw data lives. We use two containers:
- `lake`: the raw live archive and processed Parquet files;
- `sessions`: fallback uploads of session folders, exactly as recorded.

Public access and storage keys are switched off; everything logs in with an Azure identity.

**Parquet.** A compressed, column-based file format used for analytics. A 100 Hz sensor file shrinks a lot, and pandas reads it fast.

**Event Grid.** Azure's event router, used only by the fallback upload. When a file whose name ends in `_complete.json` is created in `sessions`, Event Grid puts a message in the Service Bus queue. The filter is set in Terraform, so other files don't trigger anything.

**Service Bus (Basic tier) queue.** A queue of small "to-do" messages: "session X is ready", sent by the processor (live trips) or by Event Grid (uploads, which delivers with its own managed identity holding "Azure Service Bus Data Sender" on the queue). The finalize job takes a message, processes the session, and completes the message. If processing fails, the message comes back and is retried; after 5 failed tries (`max_delivery_count = 5`) it moves to a **dead-letter queue**, so one broken session can't loop forever. Costs $0.05 per million operations. *Rejected:* Storage Queues (no dead-letter queue built in), RabbitMQ (something to run and secure).

**Azure Container Apps.** Runs Docker containers without us managing servers. Everything that needs the private database runs here, in one environment connected to our VNet:
- the **stream processor**: a long-running container app (always 1 copy, 0.25 vCPU, 0.5 GiB) that reads Event Hubs continuously;
- the **read API**: a small web container app with public HTTPS ingress (see Dashboard);
- **Container Apps Jobs**: containers that run to completion and stop. The **finalize job** is started automatically by the Service Bus queue: when a message arrives, Azure starts one copy, which processes that session and exits. Two more jobs, **aggregate** and **migrate**, are started by hand or by CI (see below).

The processor and jobs run the **same Python code** (numpy and scipy for signal processing). *Why not Functions for processing?* The filters keep state for minutes (motion-sickness dose accumulates over a whole trip), and functions are short-lived and stateless. A container can keep that state in memory and checkpoint it to the database.

Setup details:
- A **workload profiles** environment with only the free-of-fee Consumption profile, on its own `/27` subnet (the minimum; the size can't change later). It is **external**, so the read API can have public ingress; the processor and jobs have no ingress at all, so they stay unreachable. The environment brings its own static public IP for outgoing traffic (and one for incoming), so it doesn't depend on the VNet's default outbound access.
- The finalize job uses a KEDA rule (Azure's built-in autoscaler) on the Service Bus queue: 0 copies when the queue is empty, at most 3 at once, a 30-minute time limit per run (`replica_timeout_in_seconds = 1800`). The rule logs in with a **user-assigned** identity (`identity_id` on the rule) that Terraform creates and gives "Azure Service Bus Data Receiver" **before** the job exists; with a system-assigned identity the job would need the role before it could be created.
- A long session can take longer than the 5-minute maximum message lock, so the job renews the lock while it works (`AutoLockRenewer` in the Service Bus SDK).
- Jobs are billed only while they run, at the active rate; there are no idle or request charges for jobs.

**Azure Container Registry (ACR).** Where our Docker images are stored so Container Apps can run them. CI pushes a new image on every merge. Containers pull images with their own identity; the registry's admin password is switched off. We use the **Standard** tier, because one Standard registry is free for 12 months on the free account (Basic costs $0.17 per day otherwise).

### Storage and results

**Azure Database for PostgreSQL Flexible Server** (Burstable `B1ms`, 1 vCore, 2 GB RAM, 32 GB storage, PostgreSQL 17, no high availability). A managed database: Azure runs PostgreSQL for us, including backups and patching. It is **free for 12 months** on a new free account (750 hours a month, so it can run all the time). The small size is enough because only results go in (see §3). It sits in a **private subnet**, unreachable from the internet. *Rejected:* Azure SQL Database (has a free offer, but no PostGIS), Cosmos DB (no map queries), Azure Data Explorer (another query language to learn).

**PostGIS.** A PostgreSQL extension for geographic data: it stores points, lines and polygons and answers questions like "which road segments are within 20 m of this GPS point". The map runs on it. On Azure it must be allow-listed first (server parameter `azure.extensions = POSTGIS`, set in Terraform) before the migration runs `CREATE EXTENSION postgis`.

**H3.** Uber's open-source system that covers the Earth with hexagons of fixed sizes. We assign every GPS point to a small hexagon (about 25 m across) in Python, so that different trips on the same street land in the same cells and can be compared. It needs no map data import. Snapping to real OpenStreetMap roads was considered and dropped (§19).

**Database logins: Microsoft Entra, no passwords.** Password login is switched off on the server. Every service has its own **managed identity** (an Azure identity attached to the service, with no secret to store) and logs in with a short-lived token from it:

| Database user | Used by | Rights |
|---|---|---|
| `migrator` (the server's Entra admin) | migrate job | creates PostGIS, tables and the other users |
| `writer` | stream processor, finalize and aggregate jobs | read and write on our tables |
| `reader` | read API | `SELECT` only |

Setup details:
- Turn on Entra authentication and turn off password authentication in Terraform; make the migrate job's user-assigned identity the Entra admin (a managed identity can be an Entra admin). Turning Entra on restarts the server once.
- The migrate job creates the other users with `pgaadauth_create_principal_with_oid('<role>', '<identity object ID>', 'service', false, false)`, then grants rights. The object ID matters: the server matches tokens to roles by Entra ID, not by name.
- Tokens are requested for `https://ossrdbms-aad.database.windows.net/.default` and used as the password, with the role name as the user name. A token is only needed to *open* a connection; keep the connection in a global variable and reconnect (with a fresh token) when it fails.
- To check Entra tokens, the server itself must reach Microsoft Entra ID: its subnet's network security group allows outgoing HTTPS to the `AzureActiveDirectory` service tag.
- TLS is required (`require_secure_transport` on the server). Clients connect with `sslmode=require`, which is what Microsoft recommends: Azure rotates the intermediate certificates without notice, and Microsoft documents `verify-ca`/`verify-full` as unsupported for that reason. The connection is still encrypted, and it never leaves our VNet.

**Migrations run once, in their own job.** PostGIS and tables are created by SQL migrations (`db/migrations/`). CI starts the **migrate job** before updating the processor, so two containers can never run migrations at the same time.

### Dashboard

**What the dashboard shows.** The web app is where the whole system becomes visible, so it is built around the live path:

The dashboard is already built (`dashboard/`, React + MapLibre + uPlot) and runs on a mock backend until the read API is deployed. Its pages:

| Page | What you see | Fed by |
|---|---|---|
| **Live** (the main screen) | Each vehicle that sent data in the last 60 s moves on the map with its last ~2 minutes of track; speed, current roughness, motion-sickness dose so far, and how fresh the data is. Polled every 2 s. | stream processor (`live_state`) |
| **Map** | All finished trips combined: H3 hexagons coloured by normalized roughness or sickness score, filtered by vehicle type; confirmed potholes; a panel per segment. | finalize job + aggregation |
| **Sessions** / **Session** | The list of trips, and one trip: acceleration, speed and sickness dose over time, its track and events on the map, detection scores. | processor while live, finalize job after |
| **Quality** | The data-quality panel for every trip (§10). | processor + finalize job |
| **Method** | How the numbers are computed, including the fitted vehicle effects and β. | aggregation |

End-to-end delay target: under 10 seconds from the phone to the screen (2 s batch, upload, stream, processing, 2 s polling). The processor stores when each batch arrived, so the dashboard can show the real delay instead of claiming "live".

**Read API (Container App).** A small Python web service (FastAPI) in the Container Apps environment. It only reads from the database and returns JSON and GeoJSON (map data) to the dashboard. Its routes, response types and rules (privacy trimming, aggregation rules, units) are fixed by [`dashboard/API.md`](../dashboard/API.md), and the dashboard's mock backend implements the same contract. It logs in as `reader` with its managed identity and keeps 1 copy running so the live view never waits for a cold start.

*Why a container, not a second function?* A Flex Consumption function joined to the VNet sends **all** its outgoing traffic through the VNet, including logs and its own storage. Subnets in new VNets no longer get internet access by default, so that would need a NAT gateway (about $1 per day) or a fragile workaround. The Container Apps environment already has its own outgoing IP and is already in the VNet, so the read API fits there at almost no cost.

**React + Vite + MapLibre + uPlot, hosted on Static Web Apps.**
- *React + Vite*: a common way to build a web app; Vite is the build tool.
- *MapLibre GL JS*: an open-source map library, with free OpenFreeMap tiles (the background map). We colour road segments by roughness or sickness score.
- *uPlot*: a very fast chart library for long time series.
- *Azure Static Web Apps (Free plan)*: hosts the built website (plain files) over HTTPS from a global network. Free.

The read API allows browser requests (CORS, set in the container app's ingress settings) only from the dashboard's Static Web Apps address; Terraform passes that address to the container app in the same run. The Free plan of Static Web Apps allows 100 GB of traffic a month and 250 MB per app, far more than we need. The dashboard reads its API address at runtime from `/config.json` (`{"apiBase": "https://<read-api>.<env>.northeurope.azurecontainerapps.io"}`); the deploy workflow writes that file from a Terraform output just before uploading, and the empty `public/config.json` in the repo keeps the mock backend for local work. It polls the read API every 2 to 5 seconds when showing live data. *Rejected:* WebSockets or SignalR (more moving parts for a handful of viewers), Front Door + Storage static website (Front Door has a monthly base fee).

### Running and watching it

**VNet (virtual network).** Our own private network in Azure (`10.20.0.0/24`), split into two subnets:
- `snet-aca` (`/27`, handed over to Container Apps): the processor, the jobs and the read API;
- `snet-psql` (`/28`, handed over to PostgreSQL): the database, unreachable from the internet.

A private DNS zone lets our services find the database by name. Network security groups (Azure's firewall rules) allow the database only from `snet-aca`, and allow the database to reach Microsoft Entra ID (to check login tokens).

Outgoing internet access: since 31 March 2026, subnets in **new** VNets are private by default (no implicit internet access). That doesn't hurt us: the Container Apps environment has its own outgoing IP, the ingest function isn't in the VNet, and Terraform's `default_outbound_access_enabled` is `true` by default and we set it explicitly on `snet-psql`, so the database can still reach Entra ID. *Why not a NAT gateway* (Microsoft's recommended way to give private subnets internet access)? It costs about $1 per day plus data, and with this layout nothing needs it. Storage, Event Hubs and Service Bus are reached over their login-protected public endpoints.

**Managed identities and role assignments.** Azure's permission system. Each service gets its own identity with only the roles it needs:

| Identity | Roles |
|---|---|
| ingest function | send to the event hub; write to `lake`; read the device-key secret |
| processor and jobs | read from the event hub; send to and receive from the queue; read `sessions`; read and write `lake`; pull images; database `writer` |
| migrate job | database Entra admin; pull images |
| read API | database `reader`; pull images |
| Event Grid | send to the Service Bus queue |

Event Hubs, Service Bus and Storage have **key-based access switched off**, so there are no connection strings to leak.

**Key Vault.** Azure's store for secrets. It keeps the hashed device keys, which the ingest function reads through a Key Vault reference in its settings. There are no database passwords to store. Encryption at rest for Storage, PostgreSQL and Event Hubs is on by default with Microsoft-managed keys; we don't need our own keys.

Nothing secret is ever committed to the repo.

**Azure Monitor: Log Analytics and Application Insights.** Azure's logs, metrics and alerts. All services send logs and traces to one Log Analytics workspace. The first 5 GB a month per billing account are free, and the workspace has a daily cap (`daily_quota_gb = 0.5`) so logs can't run up the bill. One **workbook** (an Azure dashboard), defined in Terraform, shows ingest rate, errors, Event Hubs incoming messages, **processor lag** (now minus the time of the last processed message, a custom metric the processor reports), rows written and data-quality counts. An action group emails us on errors and lag.

**Cost Management budget.** Sends an email when spending crosses $20 and $50, so a forgotten resource can't surprise us. On the free account, the spending limit is a second safety net: when the credit is used up, resources are stopped, not billed. Note that the credit can't pay for Marketplace products, so we use none.

### Building and deploying

**Terraform.** Infrastructure as code: we describe every Azure resource in `.tf` files (the `azurerm` provider), and Terraform creates, changes or deletes the real resources to match. `terraform plan` shows what would change; `terraform apply` does it. The current state is stored in a Blob Storage container, which locks it automatically, so two people can't apply at once. Because storage keys are off, the provider uses Entra login for storage (`storage_use_azuread = true`, and `use_azuread_auth = true` in the backend). We write plain `azurerm` resources and use Azure Verified Modules only where they clearly save time.

**GitHub Actions.** CI/CD inside GitHub: workflows run on every pull request and every merge. They log in to Azure with **OIDC**: GitHub proves which repo and branch a job comes from, Azure trusts that through a **federated credential** on a managed identity, and hands out short-lived tokens (`azure/login@v2`). No Azure secrets are stored anywhere; the client, tenant and subscription IDs are plain repo variables.

Our repo was created on 2026-11-20, after GitHub switched new repos to **immutable subject claims** (2026-07-15). The token's subject therefore carries the numeric owner and repo IDs, and the federated credentials must match them exactly:
- deploy: `repo:ghimpumihai@163877193/DataInfrastructure_Chuds@1465690625:environment:prod`
- plan: `repo:ghimpumihai@163877193/DataInfrastructure_Chuds@1465690625:pull_request`

These IDs are public and never change, even if the repo is renamed. If login fails, print the real `sub` claim in a workflow step and compare.

**Docker Compose (local development).** Runs PostgreSQL with PostGIS on a laptop. The processor can run directly on session CSV files, so most development and testing needs no Azure at all.

---

## 6. Why not Kafka, RabbitMQ and other popular tools

We looked at each seriously. The guiding rule: use a tool when the data or the demo needs it, not to fill the slide.

| Tool | What it would do | Why not (for us, now) |
|---|---|---|
| **Event Hubs Standard (Kafka endpoint) + Capture** | Stream with Kafka clients and automatic archive | Twice the base price, and Capture is billed per hour on top. Basic does what we need. |
| **Self-hosted Kafka or Redpanda on a VM** | Same, "real" Kafka | We'd have to run, secure and fix a broker ourselves. |
| **Service Bus Standard with sessions** | Ordered messages per device | Works, similar price, but a queue forgets messages once read, so the processor can't re-read the last hours after a bug. |
| **RabbitMQ** | Job queue | Service Bus does the same job with nothing to run and costs cents. |
| **IoT Hub** | Device messaging | The free tier counts messages in small chunks, so one drive would use up the daily quota; per-device registration and certificates add setup. HTTPS plus device keys gives a similar security story. |
| **Stream Analytics** | Stream processing engine | Its SQL-like language can't run numpy and scipy, and it bills every hour it runs. |
| **Durable Functions** | Stateful serverless code | Possible, but long numpy filters with minutes of state fit a plain container better. |
| **Read API as a VNet-joined Function** | Serverless dashboard API | All its outgoing traffic would go through a VNet subnet that has no internet by default; it would need a NAT gateway. A container app in the existing environment avoids that. |
| **Cosmos DB** | Duplicate check | Same data-loss risk as the old DynamoDB idea; the database handles duplicates safely. |
| **Azure SQL Database (free offer)** | Database | No PostGIS. |
| **AKS (Kubernetes)** | Container platform | Nodes cost money all the time and it takes days to set up; Container Apps does what we need. |
| **API Management** | API gateway | The function already has HTTPS; it can be added later for throttling. |
| **NAT gateway, private endpoints** | Private internet access, private service access | About $1 per day each; not needed at our scale (see VNet in §5). |
| **A second CI/CD system (Azure DevOps)** | More pipelines | Adds nothing judges can see; GitHub Actions covers everything. |

If the project ever grows to thousands of vehicles, the design moves to Kafka cleanly: switching Event Hubs to Standard turns on its Kafka endpoint, and the stream sits behind the ingest function, so phones would not change.

---

## 7. How the data flows

**During a trip (main path).**
1. At Start, the app sends the session metadata (`PUT /api/ingest/sessions/{id}`). The trip appears on the dashboard with its vehicle and context.
2. Every 2 seconds the phone (or the replay tool) posts a gzip batch to the ingest function. Without network, batches wait in the app's disk queue and are sent oldest first when the network returns.
3. The ingest function checks each message, sends it to Event Hubs keyed by device, and writes it to the raw archive.
4. The stream processor reads the messages in order, runs the calculations incrementally, and writes live state, segment observations, events and chart data. It records how far it has read (the partition's sequence number, in `stream_checkpoints`) in the same database transaction.
5. The dashboard polls the read API every 2 seconds: the vehicle moves, the road colours in, the sickness dose rises.

**When the trip ends.**
1. At Stop, the app sends the metadata again, now with the end time and the number of batches. It goes through the same queue, so it arrives after the last batch.
2. Once every batch is in, the processor puts "session ready" in the Service Bus queue (or after 15 minutes of silence, as incomplete).
3. Container Apps starts the finalize job: it rebuilds the trip from the raw archive, recomputes it in one pass (§9), writes Parquet to `lake`, replaces the trip's live results, and runs the aggregation step.
4. The trip now counts in the aggregated map.

**Fallback: a trip that never reached the cloud.**
1. `tools/upload` copies the session folder to the `sessions` container under `<sessionId>/` and writes `_complete.json` last.
2. Event Grid puts "session ready" in the same queue; the same finalize job reads the CSVs instead of the archive.
3. If part of the trip had arrived live, the uploaded files win: the job replaces that trip's results, so nothing is counted twice (the app uses the same `sessionId` for both).

---

## 8. Data model (PostgreSQL + PostGIS)

| Table | One row per | Key fields |
|---|---|---|
| `vehicles` | vehicle | type (car/bus/tram), make/model, line |
| `devices` | phone | device ID, hashed key |
| `sessions` | trip | vehicle, device, mount (rigid, handheld, location), rater seat and posture (from `session.json`), `source` (`live`/`upload`/`replay`), `status` (`live` while recording, `processing` until finalized, `complete`; plus an `incomplete` flag for trips closed without a Stop), `quality_status` (`pending`/`ok`/`degraded`/`bad`), exclusion reasons, expected batch count, quality status, `include_in_agg` |
| `ingest_batches` | live batch received | (session_id, batch_seq) **unique**: a repeated batch is ignored with `ON CONFLICT DO NOTHING`; arrival time, for the delay shown on the dashboard |
| `stream_checkpoints` | Event Hubs partition | last sequence number processed |
| `segments` | road piece | H3 cell ID, geometry |
| `segment_observations` | session × segment × pass | speed, raw roughness, MSDV contribution, sample count, quality flags |
| `events` | detected pothole or speed bump | position, time, type, confidence, session |
| `labels` | manual tap | type, value, time (from the app's `labels.csv`; MISC ratings from older app builds are stored but never shown, D47) |
| `session_series` | downsampled chart data | about 5 Hz vertical and lateral acceleration, speed, MSDV so far |
| `live_state` | device | last position, speed, current scores (for the live view) |
| `segment_agg` | segment × vehicle type | normalized roughness, pothole confirmation ratio, sickness score, number of sessions; rebuilt by the aggregation step |

`include_in_agg` is true only for **finalized** trips (live or uploaded, never replays) whose context is known and that pass the quality rules (§10). The dashboard shows why a trip is excluded: `replay`, `live_only` (a live trip that isn't finalized yet), bad quality, and so on.

Raw values are always stored as measured; normalization happens only in the aggregation step, so we can change the method later without reprocessing.

**Road segments.** We use **H3 hexagons** (about 25 m). Two trips on the same street fall in the same cells, which is what aggregation needs, and it requires no map import. Its weakness: it can blur two parallel roads or a junction. Watch for that when picking the drive loop.

---

## 9. Processing and aggregation

**Per session** (the same code runs live, batch by batch, and in the finalize job over the whole trip):
1. **Clock alignment.** Convert all timestamps to UTC using the clock anchors (`clock.csv`).
2. **Phone-to-vehicle axes.** Use gravity at rest for "down" and GPS course or the main direction of acceleration for "forward". Everything else depends on this step.
3. **Quality checks.** Measure sample rates and gaps. Mark windows invalid when `phone_moved` was tapped, when gravity drifts in the phone's frame, or when the gyro's turn rate disagrees with GPS. Report what fraction of the session is valid.
4. **Road roughness.** Band-pass vertical acceleration (about 1 to 30 Hz), compute RMS per segment pass, and record speed with it.
5. **Potholes and speed bumps.**
   - A pothole is a sharp jump in band-passed (1–30 Hz) vertical acceleration, counted only above 15 km/h.
   - A speed bump shows a double peak in pitch rate (front axle, then rear axle).
   - Detections are scored against manual taps within ±1.5 s, since people react late, as precision and recall.
6. **Motion sickness.**
   - Vertical acceleration through the ISO 2631-1 Wf filter (f1 0.08, f2 0.63, f4 0.25 with Q 0.86, f5 0.0625 with Q 0.80, f6 0.1 with Q 0.80 Hz), then MSDV = √(∫a_w² dt). Roughly MSDV/3 percent of unadapted people may vomit.
   - The sickness number comes from the measured motion only. Passengers are not asked how they feel, so there is no comparison with ratings (D47, §19).
   - The filter has a unit test checking its frequency response against reference values.
   - Side-to-side sway (D49, 2026-11-21): lateral acceleration goes through the Donohew & Griffin (2004) lateral weighting (flat 0.0315–0.25 Hz, then −12 dB per octave), and its dose is added to the vertical one as energy: MSDV = √(∫(a_wz² + a_wy²) dt) = √(MSDV_z² + MSDV_y²), the root sum of squares ISO 2631-1 uses to combine axes, with k_y = 1. The combined value is the one shown everywhere and divided by 3 for the MSI; the vertical and lateral parts are stored too.
   - Known limits, to state openly: the lateral weighting isn't part of ISO 2631-1 and its exact coefficients weren't published (the corners and k_y are provisional), the MSDV/3 rule was fitted to vertical motion, lateral is only counted once the forward axis has been learned from GPS speed changes, and in long curves a tilted gravity estimate (D46) adds an error of about θ·g to the horizontal acceleration the lateral dose is built from.

**Across sessions** (the aggregation step). It runs at the end of every finalize job, and can be re-run by hand with the **aggregate** job (for example after changing the method). It takes a PostgreSQL advisory lock, so two runs never overlap, and rebuilds `segment_agg` in one transaction.
- **Roughness is normalized per vehicle.** A bus and a car feel the same road differently. We fit one model across all observations: `log(roughness) = road segment effect + vehicle effect + β·log(speed)`. Segments driven by several vehicles tie the vehicle effects together. A vehicle type that shares no segment with the car (directly or through other vehicles) can't be tied to it: it is left out of the fit and its segments show their percentile (D45). If there is too little overlap, the fallback is per-session percentiles.
- **Potholes are crowd-confirmed.** A pothole counts as confirmed when it was detected in at least *k* of *n* passes over that segment, with thresholds set per vehicle type.
- **Sickness is not normalized.** It measures what passengers actually feel, so "the bus is worse than the car on this route" is a finding, not an error. Results are split by seat and by seated or standing. Per segment it counts only moving, valid time (speed ≥ 1 m/s, phone not handled), so a bus standing at a stop doesn't dilute it (D45).

**Plan the trips for overlap.** Crowd confirmation only works if the same streets are driven several times. Pick one fixed loop that shares streets with a bus or tram line, and drive it several times, including at two different speeds.

---

## 10. Data quality and session rules

- **A rigid mount is required for roughness.** Tape or clamp the phone; run the stillness preflight. Sessions with `mount.rigid = false` or `handheld = true` are excluded from roughness and marked "experimental" for sickness.
- **Buses.** Frequent stops, door cycles, kneeling and idling engines are separated using speed near zero and the activity data.
- **Trams.** Rail joints cause regular, repeating impacts. They are labelled as rail joints so they don't count as potholes.
- **Audio is off on public transport** (other passengers, GDPR).
- **Only finalized trips count in aggregates.** A trip still recording, or one whose context (vehicle, mount) never arrived, shows on the live view but not in the aggregated map. Replays never count.
- A **data-quality panel** on the dashboard shows per session: sample rates, gaps, GPS accuracy, valid fraction and rejected batches.

---

## 11. Security

| Concern | Measure |
|---|---|
| Data in transit | HTTPS only (ingest function, read API ingress, Static Web Apps), TLS 1.2 minimum; database connections require TLS (`sslmode=require`, Microsoft's recommendation) and stay inside the VNet |
| Who may send data | Per-device keys, stored only as hashes in Key Vault, compared in constant time; strict payload validation and a size limit |
| Data at rest | Storage, PostgreSQL and Event Hubs encrypted by default; blob public access off |
| Database exposure | Private subnet only, no public access; password login off, Entra login only |
| Permissions | One managed identity per service, least privilege; key-based access off on Storage, Event Hubs and Service Bus |
| CI/CD credentials | GitHub OIDC with federated credentials; no stored Azure secrets; deploy identity usable only from the protected `prod` environment |
| Secrets in the repo | None; gitleaks scans every push |
| Privacy | Raw audio never uploaded live; audio off on public transport; GPS shown whole, start and end included (D40: the start/end trim hid every short test drive and isn't wanted; everyone recording accepts that their routes are visible to anyone with the dashboard link) |

---

## 12. Infrastructure as code (Terraform)

```
infra/
  bootstrap/          # run once by hand: state storage account, GitHub identities + federated credentials, resource provider registration
  main/               # the whole stack (one cloud environment)
    main.tf  variables.tf  outputs.tf  backend.tf (azurerm, use_azuread_auth = true, use_oidc = true)
  modules/
    network/          # VNet, subnets (snet-aca, snet-psql), NSGs (incl. outbound to AzureActiveDirectory), private DNS zone
    storage/          # storage account, containers (sessions, lake), Event Grid subscription to Service Bus
    messaging/        # Service Bus (Basic) queue + dead-letter, Event Hubs (Basic) namespace + hub
    database/         # PostgreSQL Flexible Server, server parameters (azure.extensions, TLS), Entra admin
    compute/          # ACR, Container Apps environment, processor and read API apps, finalize/aggregate/migrate jobs, ingest function app, Key Vault, user-assigned identities + role assignments
    web/              # Static Web App for the dashboard
    observability/    # Log Analytics, Application Insights, workbook, alerts, budget
```

- **One cloud environment plus local**, not dev and prod copies; that halves cost and wiring.
- **One resource group** for the stack, so `terraform destroy` (or deleting the group) removes everything.
- Terraform owns resource definitions; CI only ships new code and images. Terraform ignores those fields (`lifecycle { ignore_changes }` on image tags), so plan and deploy don't fight.
- The CI deploy identity needs Contributor plus "Role Based Access Control Administrator" on the resource group, because Terraform creates role assignments.

---

## 13. CI/CD (GitHub Actions)

| Workflow | Runs when | What it does |
|---|---|---|
| `python-ci.yml` | PR touching `services/**` or `tools/**` | ruff (lint), pytest (including the Wf filter test and a test on a sample session) |
| `terraform-plan.yml` | PR touching `infra/**` | fmt, validate, plan; posts the plan as a PR comment; read-only identity |
| `terraform-apply.yml` | merge to `main` touching `infra/**` | apply, after approval in the protected `prod` environment |
| `deploy-services.yml` | merge to `main` touching `services/**` or `db/**` | build images, push to ACR, run the migrate job and wait for it, update the processor, read API and jobs, deploy the ingest function app |
| `deploy-dashboard.yml` | merge to `main` touching `dashboard/**` | build, write `config.json` with the read API address from Terraform, deploy to Static Web Apps (the deploy token is fetched with `az` after OIDC login, not stored) |
| `security.yml` | every PR | gitleaks (scans for committed secrets) |
| `ios-app.yml` (exists) | push or PR touching `src/mobile-ios/**` | builds the app for device (unsigned) and runs its tests on a macOS runner (free for public repos) |
| `teardown.yml` | manual | `terraform destroy` after the hackathon |

---

## 14. Cost estimate

Prices are North Europe list prices from the Azure Retail Prices API (2026-11-20, USD).

| Item | Price | Per day for us |
|---|---|---|
| Event Hubs Basic, 1 throughput unit (exists 24/7) | $0.015/hour + $0.028 per million events | $0.36 |
| Container Apps environment: 2 static public IPs (outgoing, incoming) | $0.005/hour each | $0.24 |
| Container Apps: processor + read API (0.25 vCPU, 0.5 GiB each, always on) | active $0.000024/vCPU-s, idle $0.000003/vCPU-s, memory $0.000003/GiB-s; free grant 180,000 vCPU-s + 360,000 GiB-s per month | $0 for the first ~4 days of each month, then $0.40 (idle) to $1.30 (busy) |
| Container Apps Jobs (finalize, aggregate, migrate) | active rate, only while running | ~$0.01 |
| PostgreSQL Flexible Server `B1ms` + 32 GB | $0.018/hour + $0.1265/GB-month | $0 for 12 months on the free account ($0.57 after) |
| Functions Flex Consumption (ingest) | free grant 100,000 GB-s + 250,000 runs per month, then $0.000026/GB-s | $0 (a 3-hour drive is ~5,400 runs) |
| Container Registry Standard | free for 12 months on the free account (Basic: $0.17/day) | $0 |
| Service Bus Basic | $0.05 per million operations | ~$0 |
| Event Grid | first 100,000 operations per month free | $0 |
| Log Analytics | first 5 GB per month free; daily cap 0.5 GB | $0 |
| Static Web Apps Free, Storage, Key Vault | free / cents | < $0.05 |
| **Total** | | **≈ $0.65 per day during the hackathon; at most ≈ $2.20 once the monthly free grants are used up** |

**Which account.**
- **Azure free account:** $200 credit for 30 days (card needed for identity, not charged while the spending limit is on). Within 30 days, or when the credit runs out, it must be upgraded to pay-as-you-go to keep running; the 12-month free services (PostgreSQL, Container Registry) continue after the upgrade. Credits can't pay for Marketplace products. One free account per person.
- **Azure for Students** (if a team member is a full-time student at a degree-granting school): $100 credit for 12 months, **no card**; when the credit is gone the subscription is disabled.

Either covers the hackathon: three days cost about $2. Run `teardown.yml` after the event.

---

## 15. Repository layout

```
decisions/            # this folder: plans and decision log
src/mobile-ios/       # iPhone app (teammate, built on a Mac)
services/
  ingest/             # Function app: validate, send to Event Hubs, archive
  read-api/           # Container App (FastAPI): dashboard queries
  processor/          # shared Python package + entry points: stream, finalize, aggregate, migrate
tools/
  upload/             # fallback: upload a session folder to Blob Storage, marker file last
  replay/             # re-send a recorded session through the live API
  quick_check/        # sanity check of a session folder (from the initial plan §10)
dashboard/            # React + MapLibre + uPlot
db/migrations/        # SQL: PostGIS, tables, users
infra/                # Terraform (see §12)
.github/workflows/    # see §13
docker-compose.yml    # local PostGIS
```

---

## 16. Build order and what to cut

**Day 0 (setup).**
- Create the Azure free account (or Azure for Students, if a team member qualifies: no card needed). The 30-day credit clock starts now.
- Register the resource providers the stack needs (`Microsoft.App`, `Microsoft.EventHub`, `Microsoft.ServiceBus`, `Microsoft.EventGrid`, `Microsoft.DBforPostgreSQL`, `Microsoft.Web`, `Microsoft.ContainerRegistry`, `Microsoft.OperationalInsights`); `infra/bootstrap` does this.
- Check the region: `az functionapp list-flexconsumption-locations` lists North Europe, and creating the `B1ms` server in North Europe succeeds (capacity isn't guaranteed by quota).
- Send one test event to Event Hubs Basic with a managed identity (or `az login` user with the Data Sender role); if Basic refuses Entra login, switch to the key-in-Key-Vault fallback (§5).
- Create the GitHub federated credentials with the immutable subjects from §5.
- Create the budget, run `infra/bootstrap`, and set up OIDC.

**Day 1: the thin live slice first.**
- Morning: phone (or replay tool) → ingest function → Event Hubs → processor → PostgreSQL → read API → a dot moving on the dashboard's Live page (the dashboard already exists; point its `config.json` at the real read API). No signal processing yet, just position and speed. Once this works end to end, every later step only adds detail to a path that already runs.
- Early check in that slice: the read API and processor log in to the private database with their managed identities (this exercises Entra login and the database's outbound rule to Entra ID).
- In parallel: processing on the first real session folders, locally (this is where the value is); Terraform; CI workflows; the app's session metadata call (spec §6.1).

**Day 2.**
- Plug the processing into the processor: roughness colouring, potholes, sickness dose on the live view.
- Trip end detection, finalize job, segments, aggregation, the Map view.
- Real drives on the loop, watched live.

**Day 3.** Fallback upload path, monitoring workbook, data-quality panel, tests, README and architecture slide, rehearsal, recording the live video.

**Cut in this order if time runs out:** monitoring workbook (keep the budget alerts) → laptop upload fallback (the app's queue covers most network gaps) → aggregated Map view (keep Live and Trip).

**Never cut:** the live path from phone to dashboard, real data on the map, Terraform, CI/CD.

---

## 17. Top risks

1. **Account limits.** The free account's credit lasts 30 days and some sizes may be unavailable in the region. Fix on day 0; fall back to West Europe if needed.
2. **Login and network surprises.** The database must reach Entra ID to accept token logins (NSG rule plus default outbound access on `snet-psql`); a scale rule that can't log in never starts the finalize job. Test both on day 1. Reported quirk: suspending or updating a Container Apps Job can break its event trigger; if the finalize job stops starting, recreate it (`terraform apply -replace`).
3. **The app's metadata call isn't ready.** Without it the backend doesn't know the vehicle or when a trip ended. Fallback: the processor creates the trip from its first batch with unknown context and closes it after 15 minutes of silence; such trips stay out of the aggregated map until their folder is uploaded.
4. **Bad recordings:** loose mount, clock problems, wrong axes. Do a 10-minute dry run, watch it live on the dashboard, and check the folder with `quick_check` before the first real drive.
5. **Mobile network on the route.** Dead zones delay data (the queue catches up) but don't lose it. Pick a loop with decent coverage so the live view looks live.
6. **Not enough overlapping trips** for aggregation. Plan a fixed loop and repeat it.
7. **Live parts fail in the room** (Wi-Fi, function cold start). The replay through the real live path is the main demo; the video of a real drive is the backup.
8. **Expert questions on the method** (few raters, timing noise). Be open about it, and tune on some sessions and test on others.

---

## 18. Open questions

- Free account (card) or Azure for Students (no card), and in whose name? (§14)
- Can the app's session metadata call (spec §6.1) be added on day 1?
- Can a car stream live during the presentation (organizers, parking, mobile coverage), or do we show the replay only?
- Which loop will we drive repeatedly, and which bus or tram line overlaps it?
- Who owns which part (processing, infra, dashboard, app)?
- When is the dry run?
- How much GPS trimming do we want on the public dashboard and in the public repo?

---

## 19. Dropped from scope (2026-11-20)

These were in earlier versions of the plan. We removed them because they mainly added polish, not value, for a 3-day build. Each can be added back later without changing the rest of the architecture.

| Dropped | What it would have given | Why it's dropped | If we ever want it back |
|---|---|---|---|
| SQL on raw files (Athena + Glue on AWS) | SQL queries directly on raw files in storage | Nobody would use it in 3 days; pandas on the Parquet files does the same job | DuckDB on the `lake` container, or Synapse serverless SQL; the `session=` folders already fit |
| OpenStreetMap road snapping | Segments that follow real roads, no blurring at junctions or parallel roads | H3 hexagons are good enough for aggregation and need no map import | Import an OSM extract, cut roads into 25 m pieces, add a road ID to `segments` |
| Lateral (sideways) sickness metric (back in scope: D49, §9 step 6) | A second, non-standard sickness score based on Donohew & Griffin (2004) | Scientifically interesting, not required. The ISO vertical metric covers the requirement | The lateral acceleration is still stored in `session_series`, so the metric can be computed later from existing data |
| checkov in CI | Automatic checks for Terraform misconfigurations | Extra checks that judges rarely open; gitleaks stays for secrets | Add one step to `security.yml` |
| Passenger MISC ratings (D47, 2026-11-21) | A 0–10 "how do you feel" prompt every 2 minutes in the app, shown next to the dose, and a rank correlation between the two | No time to collect ratings from real passengers; the dose from ISO 2631-1 is the result we show | The `labels` table and `labels.csv` still take a `sickness` label; bring back the app prompt (spec §3.7 H1) and the read API's `ratings` / `latestRating` |

---

## 20. Research answers (2026-11-20)

Every point the plan had marked as unsure, what we found, and what it changed. Sources are in [03-research-notes.md](03-research-notes.md).

| Question | Answer | Effect on the plan |
|---|---|---|
| What does Event Hubs Basic cost? | $0.015 per throughput-unit hour + $0.028 per million events (events counted in 64 KB units) | $0.36/day; batches are one event each (§14) |
| Does Event Hubs Basic accept Entra (managed identity) login? | Not stated per tier in Microsoft's tables; Entra login is documented for Event Hubs in general | Day-0 test; fallback is a send-only and a listen-only key in Key Vault (§5, §16) |
| What are Container Apps' free grant and rates? | 180,000 vCPU-s, 360,000 GiB-s and 2 M requests per subscription per month; active $0.000024/vCPU-s, idle $0.000003/vCPU-s, memory $0.000003/GiB-s; jobs billed only while running | Costs in §14 |
| Is Container Registry free? | One Standard registry is free for 12 months on the free account | Use Standard, not Basic (§5) |
| Is PostgreSQL `B1ms` free? | Yes: 750 hours, 32 GB storage, 32 GB backup per month for 12 months, new customers only; $0.018/hour after | Unchanged |
| Azure for Students? | $100 for 12 months, no card, full-time students only; disabled when the credit runs out | Listed as an option (§14) |
| Do new VNets still have internet access by default? | No: since 31 March 2026, subnets in new VNets are private by default. Terraform's `default_outbound_access_enabled` still defaults to `true` | Kept `true` explicitly on the database subnet (§5) |
| How do Container Apps get outgoing access in a VNet? | Through the environment's own static public IP (billed), not the subnet's default access; needs a `/27` subnet (workload profiles) | No NAT gateway needed; 2 IPs added to costs (§5, §14) |
| How does a VNet-joined Flex Consumption function get outgoing access? | All its traffic goes through the subnet, which is now private by default | **Read API moved from a function to a container app** (D34) |
| Does PostgreSQL with private networking need anything for Entra login? | Yes: an outbound rule to the `AzureActiveDirectory` service tag | NSG rule added (§5, D35) |
| Which TLS mode for PostgreSQL? | Microsoft recommends `require`; `verify-ca`/`verify-full` are unsupported because intermediate certificates rotate without notice | `sslmode=require` (D35) |
| Can a Container Apps Job's KEDA rule log in with a managed identity? | Yes: `identity_id` on the rule in `azurerm_container_app_job`; needs "Service Bus Data Receiver". Reported quirk: suspending or updating a job can break its trigger | User-assigned identity created first; recreate the job if it stops starting (§5, §17) |
| Does Event Grid deliver to a Service Bus Basic queue with a managed identity? | Yes, with "Azure Service Bus Data Sender" on the queue | Unchanged (§5) |
| Service Bus Basic limits? | $0.05 per million operations, 256 KB messages, dead-letter queue, message lock up to 5 minutes | Lock renewal kept (§5) |
| Does the Functions host decompress gzip request bodies? | Not documented; reports suggest the body arrives as sent | Code checks the gzip magic bytes and handles both (§5) |
| Is Flex Consumption in North Europe, with which Python? | North Europe was a launch region; Python 3.12 and 3.13 are GA | Python 3.12; confirm region with the CLI on day 0 |
| Is Log Analytics free? | First 5 GB per month per billing account | Daily cap 0.5 GB (§5) |
| Static Web Apps Free limits? | 100 GB traffic per month, 250 MB per app, 10 apps per subscription | Unchanged |
| GitHub OIDC subject format for this repo? | Repo created 2026-11-20, after GitHub's switch to immutable subjects (2026-07-15) | Federated credentials use `repo:ghimpumihai@163877193/DataInfrastructure_Chuds@1465690625:...` (§5, D36) |
| What can't the free credit pay for? | Marketplace products, support plans and a few others; the account must be upgraded within 30 days to keep running | Noted in §5 and §14 |
| Does the plan match what is already built on `main`? (merged 2026-11-20) | The app has no health route and tests its connection with a probe POST; the dashboard is built with its own read-API contract (`dashboard/API.md`) and a mock backend | Ingest follows the probe and status rules of `mock_ingest_server.py`; the read API follows `API.md`; dashboard pages listed in §5; session status names match the dashboard |
| Where does the session metadata call go? | The read API already uses `GET /api/sessions/{id}` on another host | The app's call is `PUT /api/ingest/sessions/{id}`, so every app route sits under `/api/ingest` |
