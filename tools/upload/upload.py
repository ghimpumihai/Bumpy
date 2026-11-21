#!/usr/bin/env python3
"""Upload a recorded trip from a laptop (plan 02 §7, "Fallback: a trip that never reached the cloud").

Copies a session folder exported from the iPhone app (or its .zip) to the `sessions` container under
`<sessionId>/`, then writes `_complete.json` last. Event Grid turns that file into a "session ready"
message and the finalize job processes the folder like a streamed trip. If part of the trip did
stream, the uploaded folder replaces those results (same sessionId, nothing counted twice).

What is uploaded: every file at the top of the folder except the raw audio (`*.m4a`, never leaves
the laptop) and the mount photo (`mount.jpg`, nothing in the cloud uses it). `session.json` goes
without `people.raterName`, as in the app's own cloud copy (spec §6.2).

Logs in with your Azure CLI login (`az login`; needs "Storage Blob Data Contributor" on the
container, which Terraform gives everyone in `admin_object_ids`), or a token in
$UPLOAD_ACCESS_TOKEN. No keys. Running it again overwrites the same blobs and finalizes the trip
again.

Python 3 standard library only.

    az login
    python tools/upload/upload.py <session folder or .zip> --account <storage_account_name>
    python tools/upload/upload.py <folder> --dry-run out/     # write what would be uploaded
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import email.utils
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

MANIFEST = "_complete.json"
TOOL = "tools/upload 1"
API_VERSION = "2023-11-03"
BLOCK_BYTES = 8 * 1024 * 1024  # files above this go up in blocks, each retried on its own
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")  # the ingest function's rule: it's a blob prefix
REQUIRED = ("session.json", "device_motion.csv", "location.csv")
CONTENT_TYPES = {".csv": "text/csv", ".json": "application/json", ".txt": "text/plain"}
RETRY_STATUS = {408, 429, 500, 502, 503, 504}


class UploadError(Exception):
    """A problem the user has to fix (bad folder, no permission)."""


# --- The folder -----------------------------------------------------------------------------

def open_session(path: Path, workdir: Path) -> Path:
    """The session folder itself, or the folder inside an exported .zip."""
    if path.is_dir():
        folder = path
    elif path.suffix.lower() == ".zip" and path.is_file():
        with zipfile.ZipFile(path) as z:
            for name in z.namelist():
                target = (workdir / name).resolve()
                if workdir.resolve() not in target.parents and target != workdir.resolve():
                    raise UploadError(f"{path}: unsafe path in zip: {name}")
            z.extractall(workdir)
        found = sorted(p.parent for p in workdir.rglob("session.json"))
        if not found:
            raise UploadError(f"{path}: no session.json in the zip")
        folder = found[0]
    else:
        raise UploadError(f"{path}: not a session folder or .zip")
    for name in REQUIRED:
        if not (folder / name).is_file():
            raise UploadError(f"{folder}: no {name} (is this a session folder?)")
    return folder


def skipped(name: str) -> bool:
    return name.startswith(".") or name.lower().endswith(".m4a") or name.lower() == "mount.jpg" \
        or name == MANIFEST


@dataclass
class Prepared:
    session_id: str
    meta: dict
    files: dict[str, bytes | Path]  # blob name under <sessionId>/ -> content or the file to send
    skipped: list[str]


def prepare(folder: Path) -> Prepared:
    try:
        meta = json.loads((folder / "session.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise UploadError(f"session.json: {e}")
    if not isinstance(meta, dict):
        raise UploadError("session.json is not a JSON object")
    sid = meta.get("sessionId")
    if not isinstance(sid, str) or not SESSION_ID_RE.match(sid):
        raise UploadError(f"session.json: sessionId {sid!r} isn't usable as a folder name")
    if isinstance(meta.get("people"), dict):
        meta["people"].pop("raterName", None)
    files: dict[str, bytes | Path] = {
        "session.json": (json.dumps(meta, indent=2, ensure_ascii=False) + "\n").encode("utf-8")}
    skip = []
    for p in sorted(folder.iterdir()):
        if not p.is_file() or p.name == "session.json":
            continue
        if skipped(p.name):
            skip.append(p.name)
        else:
            files[p.name] = p
    return Prepared(sid, meta, files, skip)


def digest(content: bytes | Path) -> tuple[int, str]:
    h = hashlib.sha256()
    if isinstance(content, bytes):
        h.update(content)
        return len(content), h.hexdigest()
    n = 0
    with open(content, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
            n += len(chunk)
    return n, h.hexdigest()


def manifest(prep: Prepared, sizes: dict[str, tuple[int, str]], now: dt.datetime | None = None) -> bytes:
    now = now or dt.datetime.now(dt.timezone.utc)
    doc = {
        "sessionId": prep.session_id,
        "uploadedAtUtc": now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z",
        "tool": TOOL,
        "files": {name: {"bytes": n, "sha256": sha} for name, (n, sha) in sizes.items()},
        "skipped": prep.skipped,
    }
    return (json.dumps(doc, indent=2) + "\n").encode("utf-8")


# --- Blob Storage (REST, Entra token) -------------------------------------------------------

def az_token() -> str:
    az = shutil.which("az")
    if not az:
        raise UploadError("Azure CLI not found: install it and run `az login`, or set $UPLOAD_ACCESS_TOKEN")
    r = subprocess.run([az, "account", "get-access-token", "--resource", "https://storage.azure.com/",
                        "--query", "accessToken", "-o", "tsv"], capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        raise UploadError(f"az account get-access-token failed (run `az login`): {r.stderr.strip()[:300]}")
    return r.stdout.strip()


class BlobClient:
    def __init__(self, endpoint: str, container: str, token: str, *, timeout: float = 120.0,
                 tries: int = 6, sleep: Callable[[float], None] = time.sleep, log: Callable[[str], None] = print):
        if not (endpoint.startswith("https://") or endpoint.startswith("http://127.0.0.1")
                or endpoint.startswith("http://localhost")):
            raise UploadError("the storage endpoint must be https://")
        self.base = endpoint.rstrip("/") + "/" + container
        self.token = token
        self.timeout = timeout
        self.tries = tries
        self.sleep = sleep
        self.log = log

    def _put(self, blob: str, body: bytes, query: str = "", headers: dict | None = None) -> None:
        url = f"{self.base}/{urllib.parse.quote(blob, safe='/')}{query}"
        wait = 1.0
        for attempt in range(1, self.tries + 1):
            req = urllib.request.Request(url, data=body, method="PUT", headers={
                "Authorization": f"Bearer {self.token}", "x-ms-version": API_VERSION,
                "x-ms-date": email.utils.formatdate(usegmt=True), "Content-Length": str(len(body)),
                **(headers or {})})
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    resp.read()
                    return
            except urllib.error.HTTPError as e:
                detail = e.read().decode("utf-8", "replace")[:300]
                if e.code in (401, 403):
                    raise UploadError(
                        f"{e.code} from Blob Storage for {blob}: your login needs \"Storage Blob Data "
                        f"Contributor\" on the container (Terraform admin_object_ids). {detail}")
                if e.code not in RETRY_STATUS or attempt == self.tries:
                    raise UploadError(f"{e.code} from Blob Storage for {blob}: {detail}")
                self.log(f"  {blob}: {e.code}, retrying in {wait:.0f} s")
            except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
                if attempt == self.tries:
                    raise UploadError(f"{blob}: {e}")
                self.log(f"  {blob}: {e}, retrying in {wait:.0f} s")
            self.sleep(wait)
            wait = min(wait * 2, 30.0)

    def upload(self, blob: str, content: bytes | Path, content_type: str, block_bytes: int = BLOCK_BYTES) -> None:
        size = len(content) if isinstance(content, bytes) else content.stat().st_size
        if size <= block_bytes:
            data = content if isinstance(content, bytes) else content.read_bytes()
            self._put(blob, data, headers={"x-ms-blob-type": "BlockBlob", "Content-Type": content_type})
            return
        ids = []
        with (open(content, "rb") if isinstance(content, Path) else _BytesReader(content)) as fh:
            for i, chunk in enumerate(iter(lambda: fh.read(block_bytes), b"")):
                block_id = base64.b64encode(f"{i:08d}".encode()).decode()  # same length for every block
                self._put(blob, chunk, f"?comp=block&blockid={urllib.parse.quote(block_id, safe='')}")
                ids.append(block_id)
        body = ('<?xml version="1.0" encoding="utf-8"?><BlockList>'
                + "".join(f"<Latest>{b}</Latest>" for b in ids) + "</BlockList>").encode()
        self._put(blob, body, "?comp=blocklist", {"x-ms-blob-content-type": content_type,
                                                   "Content-Type": "application/xml"})


class _BytesReader:
    def __init__(self, data: bytes):
        self.data, self.pos = data, 0

    def read(self, n: int) -> bytes:
        out = self.data[self.pos:self.pos + n]
        self.pos += len(out)
        return out

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


# --- Running --------------------------------------------------------------------------------

def run(folder: Path, *, client: BlobClient | None, dry_run: Path | None,
        log: Callable[[str], None] = print, block_bytes: int = BLOCK_BYTES) -> Prepared:
    """Uploads every file, then the manifest. With dry_run, writes them to <dry_run>/<sessionId>/."""
    prep = prepare(folder)
    sizes = {name: digest(content) for name, content in prep.files.items()}
    items = list(prep.files.items()) + [(MANIFEST, manifest(prep, sizes))]
    total = sum(n for n, _ in sizes.values())
    log(f"Uploading {prep.session_id}: {len(prep.files)} files, {total / 1e6:.1f} MB"
        + (f" (left out: {', '.join(prep.skipped)})" if prep.skipped else ""))
    for name, content in items:
        blob = f"{prep.session_id}/{name}"
        if dry_run is not None:
            target = dry_run / blob
            target.parent.mkdir(parents=True, exist_ok=True)
            if isinstance(content, Path):
                shutil.copyfile(content, target)
            else:
                target.write_bytes(content)
        else:
            assert client is not None
            client.upload(blob, content, CONTENT_TYPES.get(Path(name).suffix.lower(), "application/octet-stream"),
                          block_bytes)
        log(f"  {name}")
    return prep


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("session", type=Path, help="session folder exported from the app, or its .zip")
    ap.add_argument("--account", default=os.environ.get("UPLOAD_STORAGE_ACCOUNT"),
                    help="storage account name (Terraform output storage_account_name; "
                         "default: $UPLOAD_STORAGE_ACCOUNT)")
    ap.add_argument("--endpoint", default=None, help="blob endpoint URL instead of --account")
    ap.add_argument("--container", default="sessions")
    ap.add_argument("--dry-run", type=Path, default=None, metavar="DIR",
                    help="write what would be uploaded to DIR/<sessionId>/ instead")
    args = ap.parse_args(argv)

    client = None
    if args.dry_run is None:
        endpoint = args.endpoint or (f"https://{args.account}.blob.core.windows.net" if args.account else None)
        if not endpoint:
            ap.error("--account (or $UPLOAD_STORAGE_ACCOUNT, or --endpoint) is required unless --dry-run")
    try:
        if args.dry_run is None:
            client = BlobClient(endpoint, args.container, os.environ.get("UPLOAD_ACCESS_TOKEN") or az_token())
        with tempfile.TemporaryDirectory(prefix="upload-") as tmp:
            folder = open_session(args.session, Path(tmp))
            prep = run(folder, client=client, dry_run=args.dry_run)
    except UploadError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nstopped before _complete.json: nothing is processed until you upload again", file=sys.stderr)
        return 130
    if not prep.meta.get("endedAtUtc"):
        print("note: session.json has no endedAtUtc (the app crashed or is still recording); "
              "the trip is finalized as incomplete")
    where = f"written to {args.dry_run / prep.session_id}" if args.dry_run else "uploaded"
    print(f"Done: {prep.session_id} {where}; _complete.json last.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
