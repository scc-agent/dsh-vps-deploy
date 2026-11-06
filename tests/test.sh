#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
node_bin=${NODE_BIN:-node}
bash -n "$root/install.sh" "$root/tools/tailscale-serve.sh" "$root/tools/verify-auth-cookie.sh" \
  "$root/tools/gen-selfsigned-cert.sh" "$root/tools/probe-url.sh" \
  "$root/bin/dsh-web-start.sh" "$root/bin/dsh-cli.sh" \
  "$root/tests/test.sh" "$root/tests/native-tls.test.sh" "$root/tests/layout-local-only.test.sh"

# The env file is parsed by systemd, not bash: %q quoting would leak bash syntax.
! grep -Fq "printf 'DSH_BIN=%q" "$root/install.sh" || { printf 'env file still uses bash %q quoting\n' >&2; exit 1; }
grep -Fq '0.2.2-rc.1' "$root/install.sh"
grep -Fq '127.0.0.1' "$root/bin/dsh-web-start.sh"
grep -Fq 'NoNewPrivileges=true' "$root/systemd/dsh-web.service.in"
grep -Fq 'MemoryMax=@DSH_MEMORY_MAX@' "$root/systemd/dsh-web.service.in"
grep -Fq 'MemoryHigh=@DSH_MEMORY_HIGH@' "$root/systemd/dsh-web.service.in"
grep -Fq 'CPUQuota=@DSH_CPU_QUOTA@' "$root/systemd/dsh-web.service.in"
grep -Fq 'TasksMax=@DSH_TASKS_MAX@' "$root/systemd/dsh-web.service.in"
grep -Fq 'DSH_MEMORY_MAX:=768M' "$root/install.sh"
grep -Fq 'PrivateDevices=true' "$root/systemd/dsh-web.service.in"
grep -Fq 'CapabilityBoundingSet=' "$root/systemd/dsh-web.service.in"
grep -Fq -- '--profile web' "$root/bin/dsh-web-start.sh"
grep -Fq 'DSH_TAILSCALE_MODE:=serve' "$root/install.sh"
# The proxy topology is gone; only the one-off retirement of a stale unit stays.
! grep -Fq 'DSH_USE_PROXY' "$root/install.sh"
grep -Fq 'LEGACY_PROXY_UNIT_NAME' "$root/install.sh"
grep -Fq 'DSH_TLS_CERT' "$root/bin/dsh-web-start.sh"
grep -Fq 'https+insecure' "$root/install.sh"
! grep -RqE 'serve-proxy|external-proxy|DSH_TLS_MODE|DSH_PROXY_PORT' "$root/install.sh"
! grep -RqE 'DSH_TLS_MODE|DSH_PROXY_PORT' "$root/README.md"
[[ ! -e $root/bin/dsh-web-proxy.cjs && ! -e $root/systemd/dsh-web-proxy.service.in && ! -e $root/tests/proxy.test.cjs ]]
grep -Fq 'tailscale_auto_install' "$root/tools/tailscale-serve.sh"
grep -Fq 'npm install --prefix' "$root/install.sh"
grep -Fq -- '--bin-links=false' "$root/install.sh"
grep -Fq 'DSH_ENTRYPOINT' "$root/bin/dsh-cli.sh"
! grep -Fq 'npm install --global' "$root/install.sh"
# Tests must never execute the real installer (it would touch the host).
! grep -RqE '(^|[^[:alnum:]_])(bash|sh|source)[[:space:]]+"?\$root/install\.sh' "$root/tests/native-tls.test.sh" \
  "$root/tests/layout-local-only.test.sh" \
  || { printf 'refusing to run: a test executes install.sh\n' >&2; exit 1; }
! grep -RniE 'curl[^\n]*\|[[:space:]]*sh|tailscale[[:space:]]+funnel' "$root/install.sh" "$root/bin" "$root/systemd"

if ! command -v "$node_bin" >/dev/null 2>&1; then
  printf 'Node.js not found: continuing shell-only checks (runtime DSH checks unavailable)\n'
fi

isolated=$(mktemp -d)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp" "$isolated"' EXIT
cp -a "$root" "$isolated/repo with spaces"
(cd "$isolated" && DSH_DRY_RUN=yes bash "repo with spaces/install.sh")

mock="$tmp/tailscale"
cat > "$mock" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1 ${2:-}" in
  "status --json")
    case ${TS_CASE:-success} in
      unauth) printf '{"BackendState":"NeedsLogin","Self":{}}'; exit 0;;
      *) printf '{"BackendState":"Running","Self":{"DNSName":"dsh.test.ts.net."}}';;
    esac;;
  "serve status")
    case ${TS_CASE:-success} in
      https-off) exit 1;;
      conflict) printf '{"Web":{"dsh.test.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9999"}}}}}';;
      multi) printf '{"Web":{"dsh.test.ts.net:443":{"Handlers":{"/":{"Proxy":"%s"},"/other":{"Proxy":"%s"}}}}}' "${TS_BACKEND:-https+insecure://127.0.0.1:3080}" "${TS_BACKEND:-https+insecure://127.0.0.1:3080}";;
      *) printf '{"Web":{"dsh.test.ts.net:443":{"Handlers":{"/":{"Proxy":"%s"}}}}}' "${TS_BACKEND:-https+insecure://127.0.0.1:3080}";;
    esac;;
  "funnel status")
    case ${TS_CASE:-success} in
      funnel-on) printf 'https://dsh.test.ts.net (Funnel on)\n|-- / proxy http://127.0.0.1:9999\n';;
      *) printf 'No serve config\n';;
    esac;;
  "serve --bg")
    [[ ${TS_CASE:-success} != apply-fail ]] || exit 1
    printf 'configured\n';;
  *) printf 'unexpected mock args: %s\n' "$*" >&2; exit 1;;
esac
MOCK
chmod +x "$mock"

run_case() {
  local expected=$1 case_name=$2
  set +e
  TS_CASE=$case_name DSH_TAILSCALE_BIN="$mock" DSH_PORT=3080 bash -c ". '$root/tools/tailscale-serve.sh'; tailscale_preflight" >/dev/null 2>"$tmp/error"
  local actual=$?
  set -e
  [[ $actual -eq $expected ]] || { cat "$tmp/error" >&2; return 1; }
}
run_case 21 unauth
run_case 22 https-off
run_case 24 conflict
run_case 24 multi
run_case 23 funnel-on
run_case 0 success
run_case 0 success # repeated configuration is accepted when it is already ours

# The preflight must accept the native TLS backend as "already ours".
set +e
TS_CASE=success TS_BACKEND='https+insecure://127.0.0.1:3080' DSH_SERVE_BACKEND='https+insecure://127.0.0.1:3080' \
  DSH_TAILSCALE_BIN="$mock" DSH_PORT=3080 bash -c ". '$root/tools/tailscale-serve.sh'; tailscale_preflight" >/dev/null 2>"$tmp/error"
actual=$?
set -e
[[ $actual -eq 0 ]] || { cat "$tmp/error" >&2; exit 1; }
set +e
TS_CASE=apply-fail DSH_TAILSCALE_BIN="$mock" DSH_PORT=3080 bash -c ". '$root/tools/tailscale-serve.sh'; tailscale_serve_apply dsh.test.ts.net" >/dev/null 2>"$tmp/error"
actual=$?
set -e
[[ $actual -ne 0 ]] || { cat "$tmp/error" >&2; exit 1; }

cat > "$tmp/curl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
header=''
while (($#)); do
  case "$1" in
    --dump-header|-D) header=$2; shift 2;;
    --write-out|-w) shift 2;;
    *) shift;;
  esac
done
# Status-only callers pass no --dump-header: answer with the code alone.
if [[ -z $header ]]; then printf '%s' "${COOKIE_STATUS:-200}"; exit 0; fi
case ${COOKIE_CASE:-secure} in
  secure) printf 'Set-Cookie: session=redacted; Secure; HttpOnly; SameSite=Strict\r\n' > "$header";;
  missing-secure) printf 'Set-Cookie: session=redacted; HttpOnly; SameSite=Strict\r\n' > "$header";;
  missing-http-only) printf 'Set-Cookie: session=redacted; Secure; SameSite=Strict\r\n' > "$header";;
  missing-same-site) printf 'Set-Cookie: session=redacted; Secure; HttpOnly\r\n' > "$header";;
  no-cookie) : > "$header";;
  *) exit 1;;
esac
printf '%s' "${COOKIE_STATUS:-200}"
MOCK
chmod +x "$tmp/curl"
source "$root/tools/verify-auth-cookie.sh"
run_cookie_case() {
  local expected=$1 case_name=$2 require_secure=${3:-yes}
  set +e
  COOKIE_CASE=$case_name PATH="$tmp:$PATH" verify_authenticated_entrypoint 'https://dsh.example.invalid/login?credential=redacted' "$require_secure" >/dev/null 2>"$tmp/cookie-error"
  local actual=$?
  set -e
  [[ $actual -eq $expected ]] || { cat "$tmp/cookie-error" >&2; return 1; }
}
run_cookie_case 0 secure
run_cookie_case 0 missing-secure no
run_cookie_case 1 missing-secure
run_cookie_case 1 missing-http-only
run_cookie_case 1 missing-same-site
run_cookie_case 1 no-cookie

# Unauthenticated base must be 401 and the credential URL must be 303.
set +e
COOKIE_STATUS=401 PATH="$tmp:$PATH" bash -c ". '$root/tools/verify-auth-cookie.sh'; verify_unauthenticated_entrypoint 'https://dsh.example.invalid/' 401" >/dev/null 2>&1
actual=$?
set -e
[[ $actual -eq 0 ]] || { printf 'expected 401 to be accepted\n' >&2; exit 1; }
set +e
COOKIE_STATUS=200 PATH="$tmp:$PATH" bash -c ". '$root/tools/verify-auth-cookie.sh'; verify_unauthenticated_entrypoint 'https://dsh.example.invalid/' 401" >/dev/null 2>&1
actual=$?
set -e
[[ $actual -ne 0 ]] || { printf 'expected 200 to be rejected where 401 is required\n' >&2; exit 1; }
set +e
COOKIE_STATUS=303 PATH="$tmp:$PATH" bash -c ". '$root/tools/verify-auth-cookie.sh'; verify_login_redirect 'https://dsh.example.invalid/login?credential=redacted' 303" >/dev/null 2>&1
actual=$?
set -e
[[ $actual -eq 0 ]] || { printf 'expected 303 to be accepted\n' >&2; exit 1; }
set +e
COOKIE_STATUS=200 PATH="$tmp:$PATH" bash -c ". '$root/tools/verify-auth-cookie.sh'; verify_login_redirect 'https://dsh.example.invalid/login?credential=redacted' 303" >/dev/null 2>&1
actual=$?
set -e
[[ $actual -ne 0 ]] || { printf 'expected 200 to be rejected where 303 is required\n' >&2; exit 1; }

if command -v "$node_bin" >/dev/null 2>&1; then
  "$node_bin" --test "$root/tests/verify-ws.test.cjs"
else
  printf 'websocket verifier runtime tests skipped: Node.js is unavailable\n'
fi
bash "$root/tests/native-tls.test.sh"
bash "$root/tests/layout-local-only.test.sh"
printf 'static, secure-cookie, 401/303, native TLS, layout, local-only probe, preflight, conflict, repeat, apply-failure, and isolated mock checks passed\n'
