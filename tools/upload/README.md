# Upload tool

The fallback for a trip that never reached the cloud (plan 02 §7): a phone with no connection for the whole drive, a crash before the queue drained, or a recording made with the upload URL empty. It copies the session folder from a laptop to Blob Storage, and the finalize job processes it like a streamed trip.

Python 3 standard library only. It logs in with your Azure CLI login, so no keys are involved.

## Use

1. Export the session from the app (Sessions → the trip → Export), or copy its folder from the Files app.
2. Log in and upload:

```sh
az login
python3 tools/upload/upload.py <session folder or .zip> --account <storage_account_name>
```

`storage_account_name` is a Terraform output (`./infra/tf.ps1 output`, in `pwsh` on macOS or in Windows PowerShell). On Windows the command is `python` instead of `python3`. Your login needs **Storage Blob Data Contributor** on the `sessions` container. Terraform gives that to everyone in `admin_object_ids`. You can also pass `--endpoint https://<account>.blob.core.windows.net`, or put a token in `UPLOAD_ACCESS_TOKEN` instead of using `az`.

`--dry-run out/` writes what would be uploaded to `out/<sessionId>/` and sends nothing. Point the finalize job's `UPLOAD_DIR` at `out/` to run it locally.

## What happens

1. Every file at the top of the folder goes to `sessions/<sessionId>/`, with retries. Files over 8 MB go in blocks.
2. `_complete.json` is written **last**. Event Grid only reacts to that name, so the trip is processed once every file is there.
3. The finalize job checks every file against the manifest, rebuilds the trip's 2-second batches from the CSVs (the same windows the phone and `tools/replay` use), and runs the same pipeline as for a streamed trip. It writes Parquet to `lake/processed/session=<id>/`, replaces the trip's results and rebuilds the map.

If part of the trip did stream, the uploaded folder wins: the job replaces the live results, keeps `source = live`, and nothing is counted twice. Backlog batches that arrive from the phone later reopen the trip, and it is finalized from the upload again. Running the tool again overwrites the same blobs and finalizes the trip again.

**Not uploaded:** raw audio (`*.m4a`, it never leaves the laptop) and the mount photo (`mount.jpg`, nothing in the cloud uses it). `session.json` is sent without `people.raterName`, as in the app's own cloud copy (spec §6.2).

If the job can't use an upload, it dead-letters the message with the reason: a file missing or changed since the manifest was written, or a `session.json` for another trip. Run the upload again.

## `_complete.json`

```json
{
  "sessionId": "<sessionId>",
  "uploadedAtUtc": "2026-11-21T12:00:00.000Z",
  "tool": "tools/upload 1",
  "files": {"session.json": {"bytes": 2345, "sha256": "<hex>"}, "device_motion.csv": {"bytes": 160000000, "sha256": "<hex>"}},
  "skipped": ["audio_000.m4a", "mount.jpg"]
}
```

Required in `files`: `session.json`, `device_motion.csv` and `location.csv`. The finalize side is `services/processor/roadride/upload.py`; a change to this format updates both.

## Tests

```sh
python3 -m pytest -q tools/upload                       # the tool against a fake Blob Storage
cd services/processor && python3 -m pytest -q tests/test_upload.py   # the finalize side, same folders
```
