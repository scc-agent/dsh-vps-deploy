#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
node_bin=${NODE_BIN:-node}

bash -n "$root/install.sh" "$root/bin/dsh-web-start.sh" "$root/tests/test.sh"
count=$(grep -Rhc '0.2.2-rc.1' "$root/install.sh" "$root/README.md" | awk '{sum += $1} END {print sum + 0}')
[[ $count -ge 2 ]]
grep -Fq 'node": ">=24.9.0"' "$root/package.json"
grep -Fq '127.0.0.1' "$root/bin/dsh-web-start.sh"
grep -Fq 'NoNewPrivileges=true' "$root/systemd/dsh-web.service.in"
grep -Fq 'MemoryMax=768M' "$root/systemd/dsh-web.service.in"
grep -Fq -- '--profile web' "$root/bin/dsh-web-start.sh"
grep -Fq 'SCRIPT_DIR=' "$root/install.sh"
grep -Fq 'DSH_DRY_RUN' "$root/install.sh"
! grep -RniE 'tailscale[[:space:]]+(funnel|serve)|iptables|nftables|password|api[_-]?key' "$root/install.sh" "$root/bin" "$root/systemd" "$root/tools"

if ! node_bin=$(command -v "$node_bin"); then
  printf 'runtime checks skipped: Node.js not found in PATH (install Node >=24.9.0 or set NODE_BIN)\n'
  exit 0
fi

# Run installer preflight from a path containing spaces; it must not mutate host state.
isolated=$(mktemp -d)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp" "$isolated"' EXIT
cp -a "$root" "$isolated/repo with spaces"
(cd "$isolated" && DSH_DRY_RUN=yes bash "repo with spaces/install.sh")

# Isolated command mocks prove current-start filtering and external-root rewriting.
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
DSH_PROC_ROOT="$tmp/proc" PATH="$tmp/bin:$PATH" "$node_bin" --experimental-strip-types "$root/tools/login-url.ts" --unit dsh-web.service --public-url https://dsh.example.invalid/dsh/
printf 'static and isolated mock checks passed\n'

