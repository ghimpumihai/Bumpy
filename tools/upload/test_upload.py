"""tools/upload against a fake Blob Storage: what is sent, in which order, and that the manifest the
finalize job checks matches what arrived. The finalize side of the same folders is tested in
services/processor/tests/test_upload.py."""

from __future__ import annotations

import base64
import hashlib
import json
import re
import sys
import threading
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import upload  # noqa: E402

SID = "4F1C2B9E-1111-4222-8333-444455556666"


@pytest.fixture
def folder(tmp_path) -> Path:
    d = tmp_path / "2025-11-21T09-15-32Z_4f1c"
    d.mkdir()
    meta = {"sessionId": SID, "deviceId": "PHONE-1", "startedAtUtc": "2025-11-21T09:15:32.000Z",
            "endedAtUtc": "2025-11-21T09:45:00.000Z",
            "people": {"raterSeat": "rear left", "raterName": "Someone", "raterPosture": "seated"}}
    (d / "session.json").write_text(json.dumps(meta))
    (d / "device_motion.csv").write_text("t_up,t_utc_ms,ua_x\n" + "".join(f"{i},{i},0.1\n" for i in range(5000)))
    (d / "location.csv").write_text("t_up,t_utc_ms,lat,lon\n1,1,46.7,23.6\n")
    (d / "labels.csv").write_text('t_up,t_utc_ms,type,value,note\n2,2,sickness,3,"a, b"\n')
    (d / "app_log.txt").write_text("INFO started\n")
    (d / "audio_000.m4a").write_bytes(b"\0" * 100)
    (d / "mount.jpg").write_bytes(b"\xff\xd8photo")
    (d / ".DS_Store").write_bytes(b"x")
    return d


class FakeBlobs:
    """Put Blob / Put Block / Put Block List, with optional failures per blob."""

    def __init__(self):
        self.blobs: dict[str, bytes] = {}
        self.blocks: dict[tuple[str, str], bytes] = {}
        self.order: list[str] = []
        self.requests: list[dict] = []
        self.fail: dict[str, list[int]] = {}  # blob -> statuses to answer first
        self.lock = threading.Lock()

    def handle(self, path: str, query: dict, headers, body: bytes) -> int:
        blob = unquote(path).split("/", 2)[2]  # /<container>/<blob>
        with self.lock:
            self.requests.append({"blob": blob, "query": query, "headers": dict(headers)})
            if self.fail.get(blob):
                return self.fail[blob].pop(0)
            if headers.get("Authorization") != "Bearer TOKEN" or not headers.get("x-ms-version"):
                return 403
            comp = query.get("comp", [None])[0]
            if comp == "block":
                self.blocks[(blob, query["blockid"][0])] = body
            elif comp == "blocklist":
                ids = re.findall(r"<Latest>([^<]+)</Latest>", body.decode())
                self.blobs[blob] = b"".join(self.blocks[(blob, i)] for i in ids)
                self.order.append(blob)
            else:
                assert headers.get("x-ms-blob-type") == "BlockBlob"
                self.blobs[blob] = body
                self.order.append(blob)
            return 201


@pytest.fixture
def blobs():
    store = FakeBlobs()

    class Handler(BaseHTTPRequestHandler):
        def do_PUT(self):
            u = urlparse(self.path)
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            status = store.handle(u.path, parse_qs(u.query), self.headers, body)
            self.send_response(status)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *a):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    store.endpoint = f"http://127.0.0.1:{server.server_address[1]}"
    yield store
    server.shutdown()


def _client(blobs, **kw):
    return upload.BlobClient(blobs.endpoint, "sessions", "TOKEN", sleep=lambda s: None, log=lambda m: None, **kw)


def _check_manifest(files: dict[str, bytes]):
    m = json.loads(files[upload.MANIFEST])
    assert m["sessionId"] == SID and m["tool"] == upload.TOOL
    assert set(m["files"]) == set(files) - {upload.MANIFEST}
    for name, info in m["files"].items():
        assert info == {"bytes": len(files[name]), "sha256": hashlib.sha256(files[name]).hexdigest()}
    return m


def test_uploads_the_folder_then_the_manifest_last(folder, blobs):
    upload.run(folder, client=_client(blobs), dry_run=None, log=lambda m: None, block_bytes=10_000)
    files = {k.split("/", 1)[1]: v for k, v in blobs.blobs.items()}
    assert blobs.order[-1] == f"{SID}/{upload.MANIFEST}"
    assert set(files) == {"session.json", "device_motion.csv", "location.csv", "labels.csv", "app_log.txt",
                          upload.MANIFEST}
    m = _check_manifest(files)
    assert sorted(m["skipped"]) == [".DS_Store", "audio_000.m4a", "mount.jpg"]
    assert files["device_motion.csv"] == (folder / "device_motion.csv").read_bytes()  # sent in blocks
    assert sum(1 for r in blobs.requests if r["query"].get("comp") == ["block"]) > 3
    meta = json.loads(files["session.json"])
    assert "raterName" not in meta["people"] and meta["people"]["raterSeat"] == "rear left"


def test_transient_errors_are_retried_and_a_missing_role_stops_at_once(folder, blobs):
    blobs.fail[f"{SID}/location.csv"] = [503, 500]
    blobs.fail[f"{SID}/{upload.MANIFEST}"] = [429]
    upload.run(folder, client=_client(blobs), dry_run=None, log=lambda m: None)
    assert blobs.order[-1] == f"{SID}/{upload.MANIFEST}"
    _check_manifest({k.split("/", 1)[1]: v for k, v in blobs.blobs.items()})

    bad = upload.BlobClient(blobs.endpoint, "sessions", "WRONG", sleep=lambda s: None, log=lambda m: None)
    blobs.requests.clear()
    with pytest.raises(upload.UploadError, match="Storage Blob Data Contributor"):
        upload.run(folder, client=bad, dry_run=None, log=lambda m: None)
    assert len(blobs.requests) == 1


def test_no_manifest_when_a_file_fails(folder, blobs):
    blobs.fail[f"{SID}/labels.csv"] = [503] * 10
    with pytest.raises(upload.UploadError, match="503"):
        upload.run(folder, client=_client(blobs, tries=3), dry_run=None, log=lambda m: None)
    assert f"{SID}/{upload.MANIFEST}" not in blobs.blobs  # so nothing is processed


def test_block_ids_have_one_length():
    ids = [base64.b64decode(base64.b64encode(f"{i:08d}".encode())) for i in (0, 9, 10, 12345)]
    assert len({len(i) for i in ids}) == 1


def test_dry_run_and_zip(folder, tmp_path, capsys):
    out = tmp_path / "out"
    assert upload.main([str(folder), "--dry-run", str(out)]) == 0
    files = {p.name: p.read_bytes() for p in (out / SID).iterdir()}
    _check_manifest(files)
    assert "_complete.json last" in capsys.readouterr().out

    z = tmp_path / "trip.zip"
    with zipfile.ZipFile(z, "w") as zf:
        for p in folder.iterdir():
            zf.write(p, f"{folder.name}/{p.name}")
    out2 = tmp_path / "out2"
    assert upload.main([str(z), "--dry-run", str(out2)]) == 0
    assert {p.name for p in (out2 / SID).iterdir()} == set(files)


@pytest.mark.parametrize("sid", ["../etc", "a/b", "", None])
def test_unusable_session_ids_are_refused(folder, sid):
    meta = json.loads((folder / "session.json").read_text())
    meta["sessionId"] = sid
    (folder / "session.json").write_text(json.dumps(meta))
    with pytest.raises(upload.UploadError, match="sessionId"):
        upload.prepare(folder)


def test_plain_http_is_refused_except_locally():
    with pytest.raises(upload.UploadError, match="https"):
        upload.BlobClient("http://example.blob.core.windows.net", "sessions", "T")


def test_missing_required_file_is_refused(folder, tmp_path):
    (folder / "location.csv").unlink()
    with pytest.raises(upload.UploadError, match="location.csv"):
        upload.open_session(folder, tmp_path)
