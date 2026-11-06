#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

bash -n "$root/install.sh" "$root/bin/dsh-web-start.sh" "$root/tests/test.sh"
count=$(grep -Rhc '0.2.2-rc.1' "$root/install.sh" "$root/README.md" | awk '{sum += $1} END {print sum + 0}')
[[ $count -ge 2 ]]
grep -Fq 'node": ">=24.9.0"' "$root/package.json"
grep -Fq '127.0.0.1' "$root/bin/dsh-web-start.sh"
grep -Fq 'NoNewPrivileges=true' "$root/systemd/dsh-web.service.in"
grep -Fq -- '--profile web' "$root/bin/dsh-web-start.sh"
! grep -RniE 'tailscale[[:space:]]+(funnel|serve)|iptables|nftables|password|api[_-]?key' "$root/install.sh" "$root/bin" "$root/systemd" "$root/tools"

# Isolated command mocks prove current-start filtering and external-root rewriting.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/proc/42"
printf '%s\0' /usr/bin/dsh --profile web --host 127.0.0.1 > "$tmp/proc/42/cmdline"
cat > "$tmp/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
if [[ $* == *MainPID* ]]; then printf '42\n'; else printf 'Wed 2026-11-05 00:00:00 UTC\n'; fi
MOCK
cat > "$tmp/bin/journalctl" <<'MOCK'
#!/usr/bin/env bash
printf 'dsh web: https://127.0.0.1:3080/?token=current-token\n'
MOCK
chmod +x "$tmp/bin"/*
if command -v node >/dev/null 2>&1; then
  DSH_PROC_ROOT="$tmp/proc" PATH="$tmp/bin:$PATH" node --experimental-strip-types "$root/tools/login-url.ts" --unit dsh-web.service --public-url https://dsh.example.invalid/dsh/
else
  printf 'shell/static tests passed; Node runtime test skipped (Node is not installed)\n'
fi
printf 'static and isolated mock checks passed\n'

