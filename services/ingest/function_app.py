"""Ingest function (plan §5): receives the phone's batches and session metadata, sends them to Event
Hubs and archives them to the `lake` container. All logic is in ingest_core/; this file only wires
it to Azure Functions and the Azure SDKs.

Settings (set by Terraform, infra/modules/compute):
  AZURE_CLIENT_ID                     the ingest managed identity (picked up by DefaultAzureCredential)
  EVENTHUB_FULLY_QUALIFIED_NAMESPACE, EVENTHUB_NAME
  STORAGE_BLOB_ENDPOINT, LAKE_CONTAINER
  KEY_VAULT_URI, DEVICE_KEYS_SECRET_NAME
"""

from __future__ import annotations

import json
import logging
import os
import threading

import azure.functions as func
from azure.core.exceptions import ResourceExistsError, ResourceNotFoundError
from azure.eventhub import EventData, EventHubProducerClient
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from azure.storage.blob import BlobServiceClient, ContentSettings

from ingest_core.handler import Response, handle_batch, handle_session
from ingest_core.keys import KeyStore, parse_secret

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)  # auth is the device key

_credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)


class AzureSinks:
    """Event Hubs producer + lake container client, created once per worker and reused."""

    def __init__(self) -> None:
        self._producer = EventHubProducerClient(
            fully_qualified_namespace=os.environ["EVENTHUB_FULLY_QUALIFIED_NAMESPACE"],
            eventhub_name=os.environ["EVENTHUB_NAME"],
            credential=_credential,
        )
        self._producer_lock = threading.Lock()  # the producer client is not thread-safe
        self._lake = BlobServiceClient(os.environ["STORAGE_BLOB_ENDPOINT"], credential=_credential) \
            .get_container_client(os.environ.get("LAKE_CONTAINER", "lake"))

    def publish(self, partition_key: str, body: bytes, properties: dict) -> None:
        event = EventData(body)
        event.content_type = "application/json"
        event.properties = properties
        with self._producer_lock:
            batch = self._producer.create_batch(partition_key=partition_key)
            batch.add(event)
            self._producer.send_batch(batch)

    def archive(self, blob_name: str, gz_body: bytes) -> bool:
        # The name comes from the message, so a retried batch finds its blob already there. Never
        # overwrite: the first copy stays, as in the database (ON CONFLICT DO NOTHING).
        try:
            self._lake.upload_blob(
                blob_name, gz_body, overwrite=False,
                content_settings=ContentSettings(content_type="application/json", content_encoding="gzip"),
            )
        except ResourceExistsError:
            return False
        return True


def _load_device_key_hashes() -> dict[str, frozenset[str]]:
    client = SecretClient(os.environ["KEY_VAULT_URI"], credential=_credential)
    try:
        value = client.get_secret(os.environ.get("DEVICE_KEYS_SECRET_NAME", "device-key-hashes")).value
    except ResourceNotFoundError:
        logging.warning("device key secret not found: every request will get 401 until a key is added")
        return {}
    return parse_secret(value)


_keys = KeyStore(_load_device_key_hashes)
_sinks: AzureSinks | None = None
_sinks_lock = threading.Lock()


def _get_sinks() -> AzureSinks:
    global _sinks
    with _sinks_lock:
        if _sinks is None:
            _sinks = AzureSinks()
        return _sinks


def _to_http(resp: Response, route: str) -> func.HttpResponse:
    level = logging.INFO if resp.status < 500 else logging.ERROR
    logging.log(level, "%s %s %s", resp.status, route, resp.log_info)
    return func.HttpResponse(body=json.dumps(resp.body), status_code=resp.status,
                             mimetype="application/json")


@app.route(route="ingest", methods=["POST"])
def ingest_batch(req: func.HttpRequest) -> func.HttpResponse:
    resp = handle_batch(dict(req.headers), req.get_body(), _keys, _LazySinks())
    return _to_http(resp, "POST /api/ingest")


@app.route(route="ingest/sessions/{sessionId}", methods=["PUT"])
def ingest_session(req: func.HttpRequest) -> func.HttpResponse:
    path_id = req.route_params.get("sessionId", "")
    resp = handle_session(path_id, dict(req.headers), req.get_body(), _keys, _LazySinks())
    return _to_http(resp, "PUT /api/ingest/sessions/{id}")


class _LazySinks:
    """Creates the Azure clients only once a request has passed every check, so bad requests
    and probes never open connections; a failure to create them becomes a 503 in the handler."""

    def publish(self, partition_key: str, body: bytes, properties: dict) -> None:
        _get_sinks().publish(partition_key, body, properties)

    def archive(self, blob_name: str, gz_body: bytes) -> bool:
        return _get_sinks().archive(blob_name, gz_body)
