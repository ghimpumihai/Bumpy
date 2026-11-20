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

    mode = os.environ.get("RUN_MODE", "stream")
    if mode == "migrate":
        from .migrate import run
    elif mode == "stream":
        from .stream import run
    else:
        logging.error("RUN_MODE %r is not implemented yet (finalize and aggregate come with processing)", mode)
        return 2
    run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
