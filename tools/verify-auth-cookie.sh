#!/usr/bin/env bash
# Verify the first authenticated response without exposing its URL or cookies.
set -Eeuo pipefail

# VERIFY_INSECURE=yes relaxes certificate checks for a loopback probe against
# the DSH self-signed certificate. It must never be used for the public URL.
_verify_curl_opts() {
  VERIFY_CURL_OPTS=()
  if [[ ${VERIFY_INSECURE:-no} == yes ]]; then
    VERIFY_CURL_OPTS+=(--insecure)
  fi
}

verify_authenticated_entrypoint() {
  local login_url=$1 require_secure=${2:-yes}
  local headers curl_error http_code
  headers=$(mktemp)
  curl_error=$(mktemp)
  _verify_curl_opts

  if ! http_code=$(curl --silent --show-error --output /dev/null \
      ${VERIFY_CURL_OPTS[@]+"${VERIFY_CURL_OPTS[@]}"} \
      --dump-header "$headers" --write-out '%{http_code}' --max-time 15 \
      "$login_url" 2>"$curl_error"); then
    rm -f "$headers" "$curl_error"
    printf 'error: authenticated entrypoint request failed\n' >&2
    return 1
  fi
  rm -f "$curl_error"

  case "$http_code" in
    2*|3*) ;;
    *)
      rm -f "$headers"
      printf 'error: authenticated entrypoint returned HTTP %s\n' "$http_code" >&2
      return 1
      ;;
  esac

  local cookie_check
  cookie_check=$(awk -v require_secure="$require_secure" '
    BEGIN { found=0; secure=0; http_only=0; same_site=0 }
    /^[[:space:]]*[Ss][Ee][Tt]-[Cc][Oo][Oo][Kk][Ii][Ee]:/ {
      found=1
      line=tolower($0)
      if (line ~ /(^|[;[:space:]])secure([;[:space:]]|$)/) secure=1
      if (line ~ /(^|[;[:space:]])httponly([;[:space:]]|$)/) http_only=1
      if (line ~ /(^|[;[:space:]])samesite[[:space:]]*=[[:space:]]*strict([;[:space:]]|$)/) same_site=1
    }
    END {
      if (!found) print "missing Set-Cookie"
      else if (require_secure == "yes" && !secure) print "missing Secure"
      else if (!http_only) print "missing HttpOnly"
      else if (!same_site) print "missing SameSite=Strict"
      else print "ok"
    }
  ' "$headers")
  rm -f "$headers"

  if [[ $cookie_check != ok ]]; then
    printf 'error: authenticated entrypoint cookie verification failed: %s\n' "$cookie_check" >&2
    return 1
  fi
}

# verify_unauthenticated_entrypoint BASE_URL EXPECTED_CODE
# The bare public URL must refuse anonymous access. Headers are not printed.
verify_unauthenticated_entrypoint() {
  local base_url=$1 expected=${2:-401}
  local url="${base_url%/}/"
  local http_code
  _verify_curl_opts
  if ! http_code=$(curl --silent --show-error --output /dev/null \
      ${VERIFY_CURL_OPTS[@]+"${VERIFY_CURL_OPTS[@]}"} \
      --write-out '%{http_code}' --max-time 15 "$url" 2>/dev/null); then
    printf 'error: unauthenticated request to the entrypoint failed\n' >&2
    return 1
  fi
  if [[ $http_code != "$expected" ]]; then
    printf 'error: unauthenticated entrypoint returned HTTP %s, expected %s\n' "$http_code" "$expected" >&2
    return 1
  fi
}

# verify_login_redirect LOGIN_URL EXPECTED_CODE
# The one-shot credential URL must redirect; neither the URL nor the token is
# ever printed, only the status line.
verify_login_redirect() {
  local login_url=$1 expected=${2:-303}
  local http_code
  _verify_curl_opts
  if ! http_code=$(curl --silent --show-error --output /dev/null \
      ${VERIFY_CURL_OPTS[@]+"${VERIFY_CURL_OPTS[@]}"} \
      --write-out '%{http_code}' --max-time 15 "$login_url" 2>/dev/null); then
    printf 'error: credential login request failed\n' >&2
    return 1
  fi
  if [[ $http_code != "$expected" ]]; then
    printf 'error: credential login returned HTTP %s, expected %s\n' "$http_code" "$expected" >&2
    return 1
  fi
}
