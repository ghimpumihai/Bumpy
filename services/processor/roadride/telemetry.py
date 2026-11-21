"""Azure Monitor (plan §5 "Running and watching it"): logs and the processor-lag metric.

Terraform sets APPLICATIONINSIGHTS_CONNECTION_STRING on the container app and jobs. Without it (local
runs, tests) nothing is configured and the metric calls are no-ops.

Only metrics and the `roadride` loggers are exported. Tracing stays off: the processor serves no
requests, and spans for every Event Hubs receive would eat the workspace's 0.5 GB daily cap.
"""

from __future__ import annotations

import logging
import os
from typing import Callable

log = logging.getLogger(__name__)

LAG_METRIC = "roadride.processor.lag"

_lag_gauge = None  # kept alive: the SDK holds callbacks weakly in some versions


def setup() -> bool:
    """Returns True when Azure Monitor was configured."""
    if not os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING"):
        return False
    try:
        from azure.monitor.opentelemetry import configure_azure_monitor
    except ImportError:
        log.warning("APPLICATIONINSIGHTS_CONNECTION_STRING is set but azure-monitor-opentelemetry "
                    "is not installed: no telemetry")
        return False
    configure_azure_monitor(
        logger_name="roadride",
        disable_tracing=True,
        enable_live_metrics=False,
    )
    log.info("Azure Monitor telemetry configured")
    return True


def observe_lag(read: Callable[[], dict[str, float]], meter=None) -> None:
    """Reports `read()` (partition -> seconds) as the gauge roadride.processor.lag, read at every
    export (once a minute by default). It keeps rising if the processor stalls. Without
    setup() the global meter is a no-op."""
    global _lag_gauge
    try:
        from opentelemetry import metrics
        from opentelemetry.metrics import CallbackOptions, Observation
    except ImportError:
        return

    def callback(_options: CallbackOptions):
        return [Observation(v, {"partition_id": pid}) for pid, v in read().items()]

    meter = meter or metrics.get_meter("roadride.stream")
    _lag_gauge = meter.create_observable_gauge(
        LAG_METRIC, callbacks=[callback], unit="s",
        description="Now minus the enqueued time of the last processed event; 0 when caught up",
    )
