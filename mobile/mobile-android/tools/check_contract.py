#!/usr/bin/env python3
"""Runs the bodies the Android unit tests wrote (app/build/contract) through the real ingest validator.
Standard library only.

    ./gradlew :app:testDebugUnitTest && python -I tools/check_contract.py
"""
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "services/ingest"))
from ingest_core import contract  # noqa: E402

out = HERE.parent / "app/build/contract"


def body(name):
    raw, was_gzip = contract.decode_body((out / name).read_bytes())
    assert was_gzip, name
    return contract.parse_json(raw)


contract.validate_batch(body("batch.json.gz"))
for name, phase in (("session_start.json.gz", "start"), ("session_stop.json.gz", "stop")):
    m = body(name)
    assert contract.validate_session_meta(m, m["sessionId"]) == phase, name
print("contract OK")
