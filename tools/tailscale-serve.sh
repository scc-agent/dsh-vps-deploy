#!/usr/bin/env bash
# Tailscale Serve checks and operations for dsh-vps-deploy.
set -Eeuo pipefail

: "${DSH_TAILSCALE_BIN:=tailscale}"
: "${DSH_TAILSCALE_PORT:=443}"
: "${DSH_PROXY_PORT:=3081}"

_ts_json_field() {
  local json=$1 field=$2 value=''
  if command -v node >/dev/null 2>&1; then
    value=$(node -e 'const v=JSON.parse(process.argv[1]); let x=v; for (const p of process.argv[2].split(".")) x=x?.[p]; if (x != null) process.stdout.write(String(x));' "$json" "$field" 2>/dev/null || true)
  else
    case "$field" in
      BackendState) value=$(printf '%s' "$json" | sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p') ;;
      Self.DNSName) value=$(printf '%s' "$json" | sed -n 's/.*"DNSName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p') ;;
    esac
  fi
  printf '%s' "$value"
}

_ts_continue() {
  printf 'continue: sudo DSH_TAILSCALE_MODE=serve DSH_TAILSCALE_INSTALL=yes ./install.sh\n' >&2
}

tailscale_preflight() {
  if ! command -v "$DSH_TAILSCALE_BIN" >/dev/null 2>&1; then
    printf 'error: Tailscale CLI is missing; install it from the official package repository first.\n' >&2
    printf 'supported automatic install: Debian/Ubuntu with apt and an already configured trusted Tailscale apt source.\n' >&2
    printf 'refusing curl|sh or an unverified platform.\n' >&2
    _ts_continue
    return 20
  fi

  local status
  if ! status=$($DSH_TAILSCALE_BIN status --json 2>/dev/null); then
    printf 'error: Tailscale is not running or this user is not logged in.\n' >&2
    printf 'authorize with: sudo tailscale up\n' >&2
    _ts_continue
    return 21
  fi
  local backend dns
  backend=$(_ts_json_field "$status" BackendState)
  dns=$(_ts_json_field "$status" Self.DNSName)
  if [[ $backend != Running || -z $dns ]]; then
    printf 'error: Tailscale is not authorized on this machine (BackendState=%s).\n' "${backend:-unknown}" >&2
    printf 'authorize with: sudo tailscale up\n' >&2
    _ts_continue
    return 21
  fi

  local serve_status
  if ! serve_status=$($DSH_TAILSCALE_BIN serve status --json 2>/dev/null); then
    printf 'error: Tailscale HTTPS/Serve is not available; enable HTTPS for this tailnet and retry.\n' >&2
    printf 'see: https://tailscale.com/kb/1153/enabling-https\n' >&2
    _ts_continue
    return 22
  fi
  local funnel_status
  funnel_status=$($DSH_TAILSCALE_BIN funnel status 2>&1) || funnel_status=''
  if printf '%s\n' "$funnel_status" | grep -Eiq 'Funnel[[:space:]]+on([[:space:])]|$)|Funnel[[:space:]]+(is[[:space:]]+)?(enabled|active)'; then
    printf 'error: Funnel is enabled/configured; refusing to alter or widen that public exposure.\n' >&2
    printf 'disable Funnel yourself, verify the result, then rerun the continue command.\n' >&2
    _ts_continue
    return 23
  fi

  # Any existing Serve config is owned by someone else unless it already points
  # at this deployment's loopback port. Never reset or replace other handlers.
  if [[ -n $serve_status && $serve_status != '{}' && $serve_status != 'null' ]]; then
    if ! printf '%s' "$serve_status" | grep -Fq "127.0.0.1:${DSH_PROXY_PORT}" ||
       [[ $(printf '%s' "$serve_status" | grep -o '"Handler"' | wc -l) -gt 1 ]]; then
      printf 'error: Tailscale Serve already has a different handler; refusing to overwrite it.\n' >&2
      printf 'inspect with: sudo tailscale serve status --json\n' >&2
      _ts_continue
      return 24
    fi
  fi
  printf '%s\n' "$dns"
}

tailscale_auto_install() {
  [[ ${DSH_TAILSCALE_INSTALL:-no} == yes ]] || return 0
  command -v apt-get >/dev/null 2>&1 || { printf 'error: automatic install is limited to Debian/Ubuntu apt.\n' >&2; return 25; }
  [[ -r /etc/os-release ]] || { printf 'error: cannot verify Linux distribution.\n' >&2; return 25; }
  . /etc/os-release
  [[ ${ID:-} == debian || ${ID:-} == ubuntu || ${ID_LIKE:-} == *debian* ]] || {
    printf 'error: automatic Tailscale installation refused on unverified platform (%s).\n' "${ID:-unknown}" >&2; return 25;
  }
  apt-cache show tailscale >/dev/null 2>&1 || {
    printf 'error: apt has no verified tailscale package source; configure the official repository and rerun.\n' >&2; return 25;
  }
  printf 'installing Tailscale from the already configured apt source\n' >&2
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tailscale
}

tailscale_serve_apply() {
  local host=$1
  [[ $host != *.invalid ]] || { printf 'error: cannot configure Serve with placeholder hostname %s\n' "$host" >&2; return 26; }
  # --bg changes only the current machine's Serve config; never use funnel.
  if ! "$DSH_TAILSCALE_BIN" serve --bg --https="$DSH_TAILSCALE_PORT" "http://127.0.0.1:${DSH_PROXY_PORT}"; then
    printf 'error: Tailscale Serve could not enable HTTPS or install the handler; enable tailnet HTTPS and retry.\n' >&2
    _ts_continue
    return 22
  fi
  local final
  final=$($DSH_TAILSCALE_BIN serve status --json 2>/dev/null) || {
    printf 'error: Serve apply returned success but status could not be read\n' >&2; return 27;
  }
  printf '%s' "$final" | grep -Fq "127.0.0.1:${DSH_PROXY_PORT}" || {
    printf 'error: Serve verification did not find the DSH proxy handler\n' >&2; return 27;
  }
}
