#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
node_bin=${NODE_BIN:-node}
bash -n "$root/install.sh" "$root/tools/tailscale-serve.sh" "$root/tools/verify-auth-cookie.sh" "$root/bin/dsh-web-start.sh" "$root/bin/dsh-cli.sh" "$root/tests/test.sh"
grep -Fq '0.2.2-rc.1' "$root/install.sh"
grep -Fq '127.0.0.1' "$root/bin/dsh-web-start.sh"
grep -Fq 'NoNewPrivileges=true' "$root/systemd/dsh-web.service.in"
grep -Fq 'MemoryMax=768M' "$root/systemd/dsh-web.service.in"
grep -Fq -- '--profile web' "$root/bin/dsh-web-start.sh"
grep -Fq 'DSH_TAILSCALE_MODE:=serve' "$root/install.sh"
grep -Fq 'tailscale_auto_install' "$root/tools/tailscale-serve.sh"
grep -Fq 'npm install --prefix' "$root/install.sh"
grep -Fq -- '--bin-links=false' "$root/install.sh"
grep -Fq 'DSH_ENTRYPOINT' "$root/bin/dsh-cli.sh"
! grep -Fq 'npm install --global' "$root/install.sh"
grep -Fq 'MemoryMax=768M' "$root/systemd/dsh-web.service.in"
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
      conflict) printf '{"Web":{"https://other":{"Handler":"http://127.0.0.1:9999"}}}';;
      *) printf '{"Web":{"https://dsh.test.ts.net":{"Handler":"http://127.0.0.1:3080"}}}';;
    esac;;
  "funnel status")
    case ${TS_CASE:-success} in
      funnel-on) printf 'https://dsh.test.ts.net (Funnel on)\n|-- / proxy http://127.0.0.1:3080\n';;
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
run_case 23 funnel-on
run_case 0 success
run_case 0 success # repeated configuration is accepted when it is already ours
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
case ${COOKIE_CASE:-secure} in
  secure) printf 'Set-Cookie: session=redacted; Secure; HttpOnly; SameSite=Strict\r\n' > "$header";;
  missing-secure) printf 'Set-Cookie: session=redacted; HttpOnly; SameSite=Strict\r\n' > "$header";;
  missing-http-only) printf 'Set-Cookie: session=redacted; Secure; SameSite=Strict\r\n' > "$header";;
  missing-same-site) printf 'Set-Cookie: session=redacted; Secure; HttpOnly\r\n' > "$header";;
  no-cookie) : > "$header";;
  *) exit 1;;
esac
printf '200'
MOCK
chmod +x "$tmp/curl"
source "$root/tools/verify-auth-cookie.sh"
run_cookie_case() {
  local expected=$1 case_name=$2
  set +e
  COOKIE_CASE=$case_name PATH="$tmp:$PATH" verify_authenticated_entrypoint 'https://dsh.example.invalid/login?credential=redacted' >/dev/null 2>"$tmp/cookie-error"
  local actual=$?
  set -e
  [[ $actual -eq $expected ]] || { cat "$tmp/cookie-error" >&2; return 1; }
}
run_cookie_case 0 secure
run_cookie_case 1 missing-secure
run_cookie_case 1 missing-http-only
run_cookie_case 1 missing-same-site
run_cookie_case 1 no-cookie

printf 'static, secure-cookie, preflight, conflict, repeat, apply-failure, and isolated mock checks passed\n'
