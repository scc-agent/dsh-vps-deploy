#!/usr/bin/env bash
set -Eeuo pipefail
# DSH_TRUSTED_HOST is a whitespace-separated authority list (local-only mode
# appends 127.0.0.1 for the loopback self-check); --trusted-host is repeatable.
trusted=()
for host in ${DSH_TRUSTED_HOST:-}; do
  trusted+=(--trusted-host "$host")
done
args=(--profile web --no-open --host 127.0.0.1 --port "${DSH_PORT}" --public-url "${DSH_PUBLIC_URL}" "${trusted[@]}")
if [[ -n ${DSH_TLS_CERT:-} && -n ${DSH_TLS_KEY:-} ]]; then
  args+=(--tls-cert "${DSH_TLS_CERT}" --tls-key "${DSH_TLS_KEY}")
fi
exec "${DSH_BIN}" "${args[@]}"
