#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
node_bin=${NODE_BIN:-node}
bash -n "$root/install.sh" "$root/tools/tailscale-serve.sh" "$root/bin/dsh-web-start.sh" "$root/tests/test.sh"
grep -Fq '0.2.2-rc.1' "$root/install.sh"
grep -Fq '127.0.0.1' "$root/bin/dsh-web-start.sh"
grep -Fq 'NoNewPrivileges=true' "$root/systemd/dsh-web.service.in"
grep -Fq 'MemoryMax=768M' "$root/systemd/dsh-web.service.in"
grep -Fq -- '--profile web' "$root/bin/dsh-web-start.sh"
grep -Fq 'DSH_TAILSCALE_MODE:=serve' "$root/install.sh"
grep -Fq 'tailscale_auto_install' "$root/tools/tailscale-serve.sh"
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
  "funnel status") exit 1;;
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
run_case 0 success
run_case 0 success # repeated configuration is accepted when it is already ours
set +e
TS_CASE=apply-fail DSH_TAILSCALE_BIN="$mock" DSH_PORT=3080 bash -c ". '$root/tools/tailscale-serve.sh'; tailscale_serve_apply dsh.test.ts.net" >/dev/null 2>"$tmp/error"
actual=$?
set -e
[[ $actual -ne 0 ]] || { cat "$tmp/error" >&2; exit 1; }

printf 'static, preflight, conflict, repeat, apply-failure, and isolated mock checks passed\n'
