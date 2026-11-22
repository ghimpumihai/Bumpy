#!/usr/bin/env bash
# Checks that the deployed ingest function really runs. Used by deploy-ingest.yml after a deploy and by
# terraform-apply.yml after an apply that changed the function app. Needs APP, RG and an Azure login.
#
# No real device key in CI on purpose: the request sends a random x-device-key that can't be on file.
# An absent key is refused before the keys are loaded (ingest_core/keys.py `identify`), but an
# unknown one makes the function read the Key Vault secret first, so its own 401 ("bad x-device-key")
# proves the host runs, both routes are registered and Key Vault is readable; its 503 ("device keys
# unavailable") means KEY_VAULT_URI or the identity's secret role is broken and every phone would get
# 503 too. A host that can't start answers some other 5xx or times out, so only that is retried.
set -eo pipefail

# Flex Consumption apps report the host under properties (the top-level field is empty).
host=$(az functionapp show -n "$APP" -g "$RG" --query "properties.defaultHostName || defaultHostName || properties.hostNames[0] || hostNames[0]" -o tsv)
if [ -z "$host" ]; then
  echo "::error::Could not read the default host name of $APP"; exit 1
fi
echo "ingest host: $host"
key="ci-smoke-$(openssl rand -hex 24)"
probe="$RUNNER_TEMP/probe.json.gz"
printf '{"probe":true}' | gzip -c > "$probe"
check() { # method, path
  curl -s -o "$RUNNER_TEMP/body" -w '%{http_code}' --max-time 60 -X "$1" "https://$host$2" \
    -H 'Content-Type: application/json' -H 'Content-Encoding: gzip' -H 'x-probe: 1' \
    -H "x-device-key: $key" --data-binary @"$probe" || true
}
keys_broken() { [ "$1" = "503" ] && grep -q 'device keys unavailable' "$RUNNER_TEMP/body"; }
ok=0
for _ in $(seq 1 30); do # cold start after a deploy can take a few minutes
  code=$(check POST /api/ingest)
  echo "POST /api/ingest with an unknown key -> $code $(head -c 200 "$RUNNER_TEMP/body")"
  if keys_broken "$code"; then
    echo "::error::The ingest function can't read the device keys from Key Vault. Check KEY_VAULT_URI and the function identity's Key Vault Secrets User role, then the function's logs in Application Insights."
    exit 1
  fi
  if [ "$code" = "401" ] && grep -q 'bad x-device-key' "$RUNNER_TEMP/body"; then ok=1; break; fi
  sleep 10
done
if [ "$ok" != 1 ]; then
  echo "::error::The ingest function did not answer 401 on POST /api/ingest (last: $code). Check that AzureWebJobsStorage is gone and look at the function's logs in Application Insights."
  exit 1
fi
code=$(check PUT /api/ingest/sessions/ci-smoke-check)
echo "PUT /api/ingest/sessions/ci-smoke-check with an unknown key -> $code $(head -c 200 "$RUNNER_TEMP/body")"
if [ "$code" != "401" ]; then
  echo "::error::PUT /api/ingest/sessions/{id} answered $code, expected 401"; exit 1
fi
echo "ingest function is up at https://$host and reads its device keys"
