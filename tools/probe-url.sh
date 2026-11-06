#!/usr/bin/env bash
# Resolve the origin the post-install self-check probes.
#
# local-only binds DSH to 127.0.0.1 only, so a non-loopback DSH_PUBLIC_URL
# (for example https://vps-jp.tail21c504.ts.net:3082/) is simply not reachable
# from the host itself: the 401/303 probes would fail against a service that is
# perfectly healthy. Probe loopback there instead and leave the advertised
# DSH_PUBLIC_URL untouched for DSH itself.
set -Eeuo pipefail

# dsh_probe_url MODE PUBLIC_URL PORT NATIVE_TLS
dsh_probe_url() {
  local mode=$1 public_url=$2 port=$3 native_tls=$4
  if [[ $mode == local-only ]]; then
    if [[ $native_tls == yes ]]; then
      printf 'https://127.0.0.1:%s/' "$port"
    else
      printf 'http://127.0.0.1:%s/' "$port"
    fi
    return 0
  fi
  printf '%s' "$public_url"
}

# dsh_probe_insecure MODE NATIVE_TLS -> yes when the loopback probe speaks TLS
# with a self-signed certificate (curl needs --insecure for that, loopback only).
dsh_probe_insecure() {
  local mode=$1 native_tls=$2
  if [[ $mode == local-only && $native_tls == yes ]]; then
    printf 'yes'
  else
    printf 'no'
  fi
}

# ensure_trusted_loopback TRUSTED_HOST -> the value plus 127.0.0.1 when missing.
# The /api browser-trust fence must accept the probe's Host header; without it a
# loopback probe can be answered with 421 even though the service is fine.
ensure_trusted_loopback() {
  local hosts=${1:-}
  case " $hosts " in
    *' 127.0.0.1 '*) printf '%s' "$hosts";;
    *) printf '%s 127.0.0.1' "${hosts% }";;
  esac
}
