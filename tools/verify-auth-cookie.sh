#!/usr/bin/env bash
# Verify the first authenticated response without exposing its URL or cookies.
set -Eeuo pipefail

verify_authenticated_entrypoint() {
  local login_url=$1
  local headers curl_error http_code
  headers=$(mktemp)
  curl_error=$(mktemp)

  if ! http_code=$(curl --silent --show-error --output /dev/null \
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
  cookie_check=$(awk '
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
      else if (!secure) print "missing Secure"
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
