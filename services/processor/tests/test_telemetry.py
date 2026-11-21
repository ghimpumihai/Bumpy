"""Azure Monitor wiring: off without a connection string, and the lag gauge reports per partition."""

from roadride import telemetry


def test_off_without_a_connection_string(monkeypatch):
    monkeypatch.delenv("APPLICATIONINSIGHTS_CONNECTION_STRING", raising=False)
    assert telemetry.setup() is False
    telemetry.observe_lag(lambda: {"0": 1.0})  # the global no-op meter: must not fail


def test_lag_gauge_reports_each_partition():
    from opentelemetry.sdk.metrics import MeterProvider
    from opentelemetry.sdk.metrics.export import InMemoryMetricReader

    reader = InMemoryMetricReader()
    meter = MeterProvider(metric_readers=[reader]).get_meter("test")
    telemetry.observe_lag(lambda: {"0": 0.0, "1": 42.5}, meter=meter)

    points = {}
    for rm in reader.get_metrics_data().resource_metrics:
        for sm in rm.scope_metrics:
            for m in sm.metrics:
                assert m.name == telemetry.LAG_METRIC and m.unit == "s"
                for dp in m.data.data_points:
                    points[dp.attributes["partition_id"]] = dp.value
    assert points == {"0": 0.0, "1": 42.5}
