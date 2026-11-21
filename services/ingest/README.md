# Ingest function

The phone's front door (plan §5, "Azure Functions"). Python 3.12 on Flex Consumption, outside the VNet.

| Route | Body | Answer |
|---|---|---|
| `POST /api/ingest` | one gzipped 2-second batch | `200 {"ok":true,"sessionId","batchSeq"}` |
| `PUT /api/ingest/sessions/{sessionId}` | gzipped `session.json`, at Start and at Stop | `200 {"ok":true,"sessionId","phase"}` |

Every request is checked in the same order as [`mock_ingest_server.py`](../../src/mobile-ios/tools/mock_ingest_server.py), the server the app was built against: device key (401) → Content-Type (400) → gunzip and size (413/400) → JSON (400) → schema and string limits (400) → idempotency header (400). The app's connectivity probe `{"probe":true}` gets a 400 that means "reachable, key accepted".

- **Gzip is decided by the magic bytes** `1f 8b`, not by `Content-Encoding`: the Functions host may inflate the body itself and drop the header (plan §5). A body without them is taken as JSON the host already inflated, within the same size limit.
- **Strings:** `deviceId` at most 128 characters, `labels[].type` at most 64, every other string and object key at most 2000; no NUL character or unpaired surrogate anywhere (PostgreSQL text/jsonb can't store them; IDs and label types are in primary keys). The app sends UUIDs, label types of at most 15 characters and short notes.

Then the message:

1. goes to Event Hubs `ingest` as plain JSON, with the device ID as the partition key and the properties `kind` (`batch`/`session`), `sessionId`, `deviceId`, `batchSeq` or `phase`, and `receivedAtUtc`;
2. is archived to `lake/raw/session=<sessionId>/<batchSeq:08d>.json.gz` (batches) or `session-start.json.gz` / `session-stop.json.gz` (metadata);
3. gets `200`. Retries of the same batch overwrite the same blob; repeats on Event Hubs are dropped in the database.

If Key Vault, Event Hubs or Storage fails, the answer is `503` and the app retries later.

## Layout

```
function_app.py      Azure Functions routes + Azure SDK clients (thin)
ingest_core/
  contract.py        decoding and schema checks, ported from the mock server
  keys.py            device-key hashes from Key Vault, constant-time check, reload for new keys
  handler.py         the request flow above, independent of Azure
tests/               pytest; test_parity.py runs the same bodies through the mock and this code
deploy.ps1           deploy from a laptop
```

## Device keys

`infra/scripts/add-device-key.ps1 -DeviceId <name>` adds a key's SHA-256 hash to the Key Vault secret `device-key-hashes`. The function reloads the secret by itself when it sees an unknown key (at most once a minute), so no restart is needed.

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
$key = '<device key>'; $url = (..\..\infra\tf.ps1 output -raw ingest_base_url | Select-Object -Last 1)
$ms = New-Object IO.MemoryStream; $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Compress); $b = [Text.Encoding]::UTF8.GetBytes('{"probe":true}'); $gz.Write($b, 0, $b.Length); $gz.Close()
try { Invoke-WebRequest $url -Method Post -Body $ms.ToArray() -ContentType 'application/json' -Headers @{ 'Content-Encoding' = 'gzip'; 'x-device-key' = $key; 'x-probe' = '1' } } catch { $_.Exception.Response.StatusCode.value__; $_.ErrorDetails.Message }
```

## Differences from the mock and the plan

- Session IDs must match `[A-Za-z0-9_-]{1,128}` in batches too (the mock accepts any string): the ID becomes part of a blob path. The app uses UUIDs.
- A new batch and a repeat both get `200` (the mock says `201` for new). The app treats every 2xx as delivered.
- Session metadata is archived as one blob per phase instead of a single `session.json.gz`, so a late retry of the Start copy can't overwrite the Stop copy.
- Validation is plain Python ported from the mock instead of pydantic (plan §5), so the two can be tested for identical behaviour.
