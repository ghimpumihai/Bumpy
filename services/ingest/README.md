# Ingest function

The phone's front door (plan §5, "Azure Functions"). Python 3.12 on Flex Consumption, outside the VNet.

| Route | Body | Answer |
|---|---|---|
| `POST /api/ingest` | one gzipped 2-second batch | `200 {"ok":true,"sessionId","batchSeq"}` |
| `PUT /api/ingest/sessions/{sessionId}` | gzipped `session.json`, at Start and at Stop | `200 {"ok":true,"sessionId","phase"}` |

Every request is checked in the same order as [`mock_ingest_server.py`](../../src/mobile-ios/tools/mock_ingest_server.py), the server the app was built against: device key (401) → compressed size (413) → Content-Type (400) → gunzip and decompressed size (413/400) → JSON (400) → schema and string limits (400) → the key's device (403) → idempotency header (400) → the session's device (403, below). The app's connectivity probe `{"probe":true,"deviceId":"<Device ID>"}` is checked against the key's device first (403 if the key is stored under another name) and otherwise gets a 400 that means "reachable, key accepted"; a probe without `deviceId` (older app builds) always gets the 400. The session route first answers `404` for a path ID that isn't a valid session ID, as the mock does.

- **Gzip is decided by the magic bytes** `1f 8b`, not by `Content-Encoding`: the Functions host may inflate the body itself and drop the header (plan §5). A body without them is taken as JSON the host already inflated, within the same size limit.
- **Size:** at most 20 MB as sent and 200 KB decompressed. The app setting `MAX_BODY_BYTES` can lower the decompressed limit; it can't go above 240 KB (an Event Hubs Basic event is at most 256 KB).
- **Strings:** `deviceId` at most 128 characters, `labels[].type` at most 64, every other string and object key at most 2000; no NUL character or unpaired surrogate anywhere (PostgreSQL text/jsonb can't store them; IDs and label types are in primary keys). The app sends UUIDs, label types of at most 15 characters and short notes.
- **Ranges:** every number fits a float (a 400-digit integer is a `400`, not a crash); `batchSeq` and `batchCount` at most 2³¹−1 (PostgreSQL `integer`); `t0Utc`, `t0UtcMs`, `location[].tUtcMs`, `startedAtUtc` and `endedAtUtc` from 1970 to 2099; the `t` of `deviceMotion`, `accelRaw`, `gyroRaw`, `altimeter` and `labels` within ±30 days of the batch start. `startedAtUtc`/`endedAtUtc` must parse as the processor reads them (`roadride/live.py` `parse_iso`: ISO-8601, no zone = UTC). Outside these the processor can't turn the value into a time or a column and would skip the message, leaving the data only in the archive.

Then the message:

1. goes to Event Hubs `ingest` as plain JSON, with the device ID as the partition key and the properties `kind` (`batch`/`session`), `sessionId`, `deviceId`, `batchSeq` or `phase`, and `receivedAtUtc`;
2. is archived to `lake/raw/session=<sessionId>/<batchSeq:08d>.json.gz` (batches) or `session-start.json.gz` / `session-stop.json.gz` (metadata);
3. gets `200`. Blobs are never overwritten: a retry of the same batch finds its blob already there and still gets `200` (logged as `archive=already-there`), so the archive keeps the first copy, as the database does (`ON CONFLICT DO NOTHING`). Repeats on Event Hubs are dropped in the database.

If Key Vault, Event Hubs or Storage fails, the answer is `503` and the app retries later.

## Layout

```
function_app.py      Azure Functions routes + Azure SDK clients (thin)
ingest_core/
  contract.py        decoding and schema checks, ported from the mock server
  keys.py            device-key hashes from Key Vault, constant-time check, reload, key → deviceId
  owners.py          session owner markers (D53), cached per worker
  handler.py         the request flow above, independent of Azure
tests/               pytest; test_parity.py runs the same bodies through the mock and this code
deploy.ps1           deploy from a laptop
```

## Device keys

`infra/scripts/add-device-key.ps1 -DeviceId <the app's Device ID>` adds a key's SHA-256 hash to the Key Vault secret `device-key-hashes` (`{"<deviceId>": "<sha256 hex>"}`). The app shows its Device ID in Settings. The function reloads the secret by itself, so no restart is needed: when it sees an unknown key, when a known key sends as a device it isn't stored under (so a rename is picked up by the app's next retry), each at most once a minute, and every 5 minutes in any case (so a revoked key stops working). If Key Vault fails on that 5-minute reload, the cached keys keep working for up to 6 hours after the last successful load; past that every request gets `503` (the app keeps its batches and retries) until Key Vault answers, so a revoked key can't outlive a long outage.

A key may only send batches and session metadata whose `deviceId` is the name it is stored under (case-insensitive), so one key can't post as another phone. Otherwise the answer is `403`, which the app retries with backoff, so nothing is lost while a key's name is fixed. For [the replay tool](../../tools/replay/README.md): a key stored as `replay` (or `replay-<anything>`) may send any `replay-…` device ID but never a phone's, and a phone's key may send `replay-<its own ID>`.

## Sessions belong to one device (D53)

The first batch or `session.json` of a session that passes every check above records its `deviceId` as the session's owner in `lake/owners/session=<sessionId>.json` (written once, never overwritten; outside `raw/session=<id>/`, which the finalize job reads as batches). Any later batch or `session.json` for that session with another `deviceId` (case-insensitive) gets `403` before anything is sent or archived, so a valid key can't take another phone's archive blobs first or add to its trip. The app sends a whole session under one `deviceId`, and `tools/replay` uses a new session ID under `replay-<deviceId>` (it has no option to reuse a session ID). Owners are cached per worker; if the marker can't be written or read, the answer is `503` and the phone retries. The ingest identity's Storage Blob Data Contributor role on `lake` covers both. Sessions already in progress at the deploy are claimed by their next message.

To rename an existing entry to the phone's Device ID without issuing a new key: `add-device-key.ps1 -DeviceId <Device ID> -RenameFrom <old name>`.

## Telemetry

Terraform sets `APPLICATIONINSIGHTS_CONNECTION_STRING` (`site_config.application_insights_connection_string`). The Functions host reads it itself: requests, failures and the function's `logging` lines (one per request, with status and reason) go to Application Insights without any SDK in `requirements.txt`. Sampling is set in `host.json` and never drops requests or exceptions.

## Test and deploy

```powershell
cd services/ingest; python -m pytest -q tests
```

```powershell
.\deploy.ps1
```

`deploy.ps1` zips the app and deploys it with a remote build (Azure installs `requirements.txt` for Linux). After a merge to `main`, `.github/workflows/deploy-ingest.yml` does the same with GitHub OIDC.

Quick check after a deploy (needs a device key); `400` with a "probe request" reason means it works:

```powershell
$key = '<device key>'; $url = (..\..\infra\tf.ps1 output -raw ingest_batch_url | Select-Object -Last 1)
$ms = New-Object IO.MemoryStream; $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Compress); $b = [Text.Encoding]::UTF8.GetBytes('{"probe":true}'); $gz.Write($b, 0, $b.Length); $gz.Close()
try { Invoke-WebRequest $url -Method Post -Body $ms.ToArray() -ContentType 'application/json' -Headers @{ 'Content-Encoding' = 'gzip'; 'x-device-key' = $key; 'x-probe' = '1' } } catch { $_.Exception.Response.StatusCode.value__; $_.ErrorDetails.Message }
```

## Differences from the mock and the plan

- Session IDs must match `[A-Za-z0-9_-]{1,128}` in batches too (the mock accepts any string): the ID becomes part of a blob path. The app uses UUIDs.
- The mock has a single key and doesn't check the key's device (the `403` above), for batches, session metadata or the probe.
- The mock doesn't record session owners (D53): it never answers `403` for a session first sent by another `deviceId`.
- A new message and a repeat both get `200` (the mock says `201` for new). The app treats every 2xx as delivered.
- Session metadata is archived as one blob per phase instead of a single `session.json.gz`, so a late retry of the Start copy can't touch the Stop copy. Plan §5 says a retry overwrites its blob; it now keeps the first copy instead, so a key can't replace an archived trip.
- Validation is plain Python ported from the mock instead of pydantic (plan §5), so the two can be tested for identical behaviour.
