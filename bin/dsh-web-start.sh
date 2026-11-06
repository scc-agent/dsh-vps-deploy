#!/usr/bin/env bash
set -Eeuo pipefail
args=(--profile web --no-open --host 127.0.0.1 --port "${DSH_PORT}" --public-url "${DSH_PUBLIC_URL}" --trusted-host "${DSH_TRUSTED_HOST}")
if [[ -n ${DSH_TLS_CERT:-} && -n ${DSH_TLS_KEY:-} ]]; then
  args+=(--tls-cert "${DSH_TLS_CERT}" --tls-key "${DSH_TLS_KEY}")
fi
exec "${DSH_BIN}" "${args[@]}"
