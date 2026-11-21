"""One image, several roles: RUN_MODE is set per container app / job by Terraform."""

from __future__ import annotations

import logging
import os
import sys


def main() -> int:
    logging.basicConfig(level=logging.INFO, stream=sys.stdout,
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    for noisy in ("azure", "uamqp", "urllib3"):
        logging.getLogger(noisy).setLevel(logging.WARNING)

    from . import telemetry

    telemetry.setup()  # only when APPLICATIONINSIGHTS_CONNECTION_STRING is set

    mode = os.environ.get("RUN_MODE", "stream")
    if mode == "migrate":
        from .migrate import run
    elif mode == "stream":
        from .stream import run
    elif mode == "finalize":
        from .finalize import run
    elif mode == "aggregate":
        from .aggregate import run
    else:
        logging.error("unknown RUN_MODE %r (stream, migrate, finalize, aggregate)", mode)
        return 2
    run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
