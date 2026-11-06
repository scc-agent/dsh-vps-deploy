#!/usr/bin/env bash
set -Eeuo pipefail

readonly VERSION='0.2.2-rc.1'
readonly PACKAGE="@deepseek-ai/dsh@${VERSION}"
readonly EXPECTED_INTEGRITY='sha512-ijR9UEVYkG15Q/Q79JzvzLBzQOQfc63VLr9n6flpwHPhr5IKn2UxthnSoto/P9l7qGd7pPvI1Ra6TW7LH3oKpg=='
readonly UNIT_NAME='dsh-web.service'
readonly MARKER='# Managed by dsh-vps-deploy; review before changing.'
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

: "${DSH_USER:=dsh}"
: "${DSH_HOME:=/var/lib/dsh}"
: "${DSH_PORT:=3080}"
: "${DSH_ENABLE:=yes}"
: "${DSH_TAILSCALE_MODE:=serve}" # serve (default), local-only, external-proxy, native-tls
: "${DSH_PUBLIC_URL:=}"
: "${DSH_TRUSTED_HOST:=}"
: "${DSH_TLS_CERT:=}"
: "${DSH_TLS_KEY:=}"
: "${DSH_DRY_RUN:=no}"
: "${DSH_TAILSCALE_INSTALL:=no}"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail 'run as root (for example: sudo ./install.sh)'
[[ $DSH_PORT =~ ^[0-9]+$ && $DSH_PORT -ge 1 && $DSH_PORT -le 65535 ]] || fail 'DSH_PORT must be 1..65535'
[[ $DSH_TAILSCALE_MODE == serve || $DSH_TAILSCALE_MODE == local-only || $DSH_TAILSCALE_MODE == external-proxy || $DSH_TAILSCALE_MODE == native-tls ]] || fail 'DSH_TAILSCALE_MODE must be serve, local-only, external-proxy, or native-tls'
[[ $DSH_DRY_RUN == yes || $DSH_DRY_RUN == no ]] || fail 'DSH_DRY_RUN must be yes or no'
[[ $DSH_ENABLE == yes || $DSH_ENABLE == no ]] || fail 'DSH_ENABLE must be yes or no'
if [[ -n $DSH_TLS_CERT || -n $DSH_TLS_KEY ]]; then
  [[ -n $DSH_TLS_CERT && -n $DSH_TLS_KEY ]] || fail 'DSH_TLS_CERT and DSH_TLS_KEY must be provided together'
  [[ -r $DSH_TLS_CERT && -r $DSH_TLS_KEY ]] || fail 'TLS files must exist and be readable before installation'
fi
[[ -r "$SCRIPT_DIR/bin/dsh-web-start.sh" ]] || fail "missing resource: $SCRIPT_DIR/bin/dsh-web-start.sh"
[[ -r "$SCRIPT_DIR/systemd/dsh-web.service.in" ]] || fail "missing resource: $SCRIPT_DIR/systemd/dsh-web.service.in"
[[ -r "$SCRIPT_DIR/tools/tailscale-serve.sh" ]] || fail "missing resource: $SCRIPT_DIR/tools/tailscale-serve.sh"

if [[ $DSH_DRY_RUN == yes ]]; then
  printf 'dry-run: mode=%s, resources=%s, unit=%s, no host changes made\n' "$DSH_TAILSCALE_MODE" "$SCRIPT_DIR" "$UNIT_NAME"
  exit 0
fi

source "$SCRIPT_DIR/tools/tailscale-serve.sh"
if [[ $DSH_TAILSCALE_MODE == serve ]]; then
  if ! command -v "$DSH_TAILSCALE_BIN" >/dev/null 2>&1; then
    tailscale_auto_install || exit $?
  fi
  tailscale_host=$(tailscale_preflight) || exit $?
  [[ -n $DSH_PUBLIC_URL ]] || DSH_PUBLIC_URL="https://${tailscale_host%\.}/"
  [[ -n $DSH_TRUSTED_HOST ]] || DSH_TRUSTED_HOST="${tailscale_host%\.}"
else
  if [[ $DSH_TAILSCALE_MODE == local-only ]]; then
    DSH_PUBLIC_URL=${DSH_PUBLIC_URL:-"http://127.0.0.1:${DSH_PORT}/"}
    DSH_TRUSTED_HOST=${DSH_TRUSTED_HOST:-127.0.0.1}
  fi
  [[ -n $DSH_PUBLIC_URL ]] || DSH_PUBLIC_URL='https://dsh.example.invalid/'
  [[ -n $DSH_TRUSTED_HOST ]] || DSH_TRUSTED_HOST='dsh.example.invalid'
fi
[[ $DSH_PUBLIC_URL == https://* || $DSH_PUBLIC_URL == http://* ]] || fail 'DSH_PUBLIC_URL must be an http(s) URL'
[[ -n $DSH_TRUSTED_HOST ]] || fail 'DSH_TRUSTED_HOST is required'
if [[ $DSH_TAILSCALE_MODE == serve || $DSH_TAILSCALE_MODE == native-tls ]]; then
  [[ $DSH_PUBLIC_URL == https://* ]] || fail 'private HTTPS modes require an https DSH_PUBLIC_URL (secure cookies need the external HTTPS origin)'
fi
if [[ $DSH_TAILSCALE_MODE == native-tls ]]; then
  [[ -n $DSH_TLS_CERT && -n $DSH_TLS_KEY ]] || fail 'native-tls requires DSH_TLS_CERT and DSH_TLS_KEY'
fi
command -v node >/dev/null || fail 'Node.js is required (>= 24.9.0)'
command -v npm >/dev/null || fail 'npm is required'
command -v systemctl >/dev/null || fail 'systemd is required'
node -e 'const [a,b,c]=process.versions.node.split(".").map(Number); if (a<24 || (a===24 && b<9)) process.exit(1)' || fail 'Node.js >= 24.9.0 is required'

if ! id "$DSH_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$DSH_HOME" --create-home --shell /usr/sbin/nologin "$DSH_USER"
fi
install -d -o "$DSH_USER" -g "$DSH_USER" -m 0750 "$DSH_HOME"
install -d -o root -g root -m 0750 /etc/dsh
npm_integrity="$(npm view "$PACKAGE" dist.integrity --registry=https://registry.npmjs.org)"
[[ $npm_integrity == "$EXPECTED_INTEGRITY" ]] || fail "npm integrity mismatch for $PACKAGE"
npm install --global --omit=dev --ignore-scripts "$PACKAGE"
DSH_BIN="$(command -v dsh || true)"
[[ -x $DSH_BIN ]] || fail 'dsh was not found after npm installation'

unit_path=/etc/systemd/system/$UNIT_NAME
if [[ -e $unit_path ]] && ! grep -Fqx "$MARKER" "$unit_path"; then
  fail "$unit_path exists and is not managed by this project"
fi
install -d -m 0755 /usr/local/libexec
start_template=$(<"$SCRIPT_DIR/bin/dsh-web-start.sh")
start_template=${start_template//@DSH_BIN@/$DSH_BIN}
printf '%s\n' "$start_template" | install -m 0755 /dev/stdin /usr/local/libexec/dsh-web-start
unit_template=$(<"$SCRIPT_DIR/systemd/dsh-web.service.in")
unit_template=${unit_template//@MARKER@/$MARKER}
unit_template=${unit_template//@DSH_USER@/$DSH_USER}
unit_template=${unit_template//@DSH_HOME@/$DSH_HOME}
printf '%s\n' "$unit_template" | install -m 0644 /dev/stdin "$unit_path"

# Write secrets/config atomically; the env file is never world-readable.
env_tmp=$(mktemp /etc/dsh/dsh-web.env.XXXXXX)
trap 'rm -f "$env_tmp"' EXIT
{
  printf 'DSH_BIN=%q\n' "$DSH_BIN"
  printf 'DSH_PUBLIC_URL=%q\n' "$DSH_PUBLIC_URL"
  printf 'DSH_TRUSTED_HOST=%q\n' "$DSH_TRUSTED_HOST"
  printf 'DSH_PORT=%q\n' "$DSH_PORT"
  printf 'DSH_TLS_CERT=%q\n' "$DSH_TLS_CERT"
  printf 'DSH_TLS_KEY=%q\n' "$DSH_TLS_KEY"
} > "$env_tmp"
chown root:"$DSH_USER" "$env_tmp"
chmod 0640 "$env_tmp"
mv -f "$env_tmp" /etc/dsh/dsh-web.env
trap - EXIT

systemctl daemon-reload
if [[ $DSH_ENABLE == yes ]]; then
  systemctl enable --now "$UNIT_NAME"
fi
if [[ $DSH_TAILSCALE_MODE == serve ]]; then
  tailscale_serve_apply "$DSH_TRUSTED_HOST" || fail 'Tailscale Serve was not verified; no success is claimed'
fi

if [[ $DSH_ENABLE == yes ]]; then
  # Exercise the real authenticated entrypoint without printing the credential.
  command -v curl >/dev/null || fail 'curl is required to verify the authenticated entrypoint'
  login_url=$(runuser -u "$DSH_USER" -- node --experimental-strip-types "$SCRIPT_DIR/tools/login-url.ts" --unit "$UNIT_NAME" --public-url "$DSH_PUBLIC_URL" 2>/dev/null) || fail 'could not read the current startup credential; inspect the unit journal and rerun'
  http_code=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 15 "$login_url") || fail 'authenticated entrypoint request failed'
  case "$http_code" in
    2*|3*) ;;
    *) fail "authenticated entrypoint returned HTTP $http_code";;
  esac
  printf 'entry verification: authenticated request succeeded at %s\n' "$DSH_PUBLIC_URL"
else
  printf 'installed but not started: rerun with DSH_ENABLE=yes to verify the authenticated entrypoint\n'
fi

printf 'installed %s, mode=%s, unit=%s, user=%s\n' "$PACKAGE" "$DSH_TAILSCALE_MODE" "$UNIT_NAME" "$DSH_USER"
printf 'full login URL is intentionally not written to logs or reports; obtain it in the operator terminal with:\n'
printf 'sudo -u %s node --experimental-strip-types %s/tools/login-url.ts --unit %s --public-url %s\n' "$DSH_USER" "$SCRIPT_DIR" "$UNIT_NAME" "$DSH_PUBLIC_URL"
