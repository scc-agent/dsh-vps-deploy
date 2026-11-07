#!/usr/bin/env bash
set -Eeuo pipefail

readonly VERSION='0.2.2-rc.1'
readonly PACKAGE="@deepseek-ai/dsh@${VERSION}"
readonly EXPECTED_INTEGRITY='sha512-ijR9UEVYkG15Q/Q79JzvzLBzQOQfc63VLr9n6flpwHPhr5IKn2UxthnSoto/P9l7qGd7pPvI1Ra6TW7LH3oKpg=='
readonly UNIT_NAME='dsh-web.service'
readonly LEGACY_PROXY_UNIT_NAME='dsh-web-proxy.service'
readonly MARKER='# Managed by dsh-vps-deploy; review before changing.'
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

: "${DSH_USER:=dsh}"
: "${DSH_HOME:=/var/lib/dsh}"
# Program code lives outside the service home so the service user (and the
# agent it hosts) cannot rewrite its own installation.
: "${DSH_APP_ROOT:=/opt/dsh}"
: "${DSH_PORT:=3080}"
: "${DSH_ENABLE:=yes}"
# serve (default: native TLS + Serve) or local-only (SSH tunnel).
: "${DSH_TAILSCALE_MODE:=serve}"
: "${DSH_TLS_DIR:=/etc/dsh/tls}"
: "${DSH_PUBLIC_URL:=}"
: "${DSH_TRUSTED_HOST:=}"
: "${DSH_TLS_CERT:=}"
: "${DSH_TLS_KEY:=}"
: "${DSH_TLS_KEY_TYPE:=rsa2048}"
: "${DSH_TLS_DAYS:=3650}"
: "${DSH_DRY_RUN:=no}"
: "${DSH_TAILSCALE_INSTALL:=no}"
: "${DSH_VERIFY_WS:=yes}"
# Resource ceilings for the DSH unit; override with DSH_MEMORY_HIGH=1G etc.
# Measured on a 2 GiB VPS under normal agent use: ~400 MiB peak, so the defaults
# leave roughly 100 MiB under MemoryHigh. Crossing MemoryHigh throttles with
# reclaim pressure; crossing MemoryMax OOM-kills the whole Web UI, not one turn.
: "${DSH_MEMORY_HIGH:=512M}"
: "${DSH_MEMORY_MAX:=768M}"
: "${DSH_CPU_QUOTA:=75%}"
: "${DSH_TASKS_MAX:=128}"
readonly DSH_WS_PATH='/api/remote.mux'

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  cat <<'USAGE'
usage: sudo ./install.sh

Default: native TLS with a generated self-signed certificate in /etc/dsh/tls,
served by DSH on https 127.0.0.1:3080 and published with
  tailscale serve --bg --https=443 https+insecure://127.0.0.1:3080
DSH terminates TLS itself; no local reverse proxy is installed.

Modes:
  DSH_TAILSCALE_MODE=serve                 native TLS + Tailscale Serve (default)
  DSH_TAILSCALE_MODE=local-only            loopback only, for SSH tunnels

Variables:
  DSH_USER=dsh                 service user (default dsh)
  DSH_HOME=/var/lib/dsh        service data dir, DSH_HOME (default /var/lib/dsh)
  DSH_APP_ROOT=/opt/dsh        program root, app installed in $DSH_APP_ROOT/app
  DSH_PORT=3080                DSH listener port
  DSH_MEMORY_HIGH=512M         unit MemoryHigh; a size suffix is mandatory
  DSH_MEMORY_MAX=768M          unit MemoryMax; a size suffix is mandatory
  DSH_CPU_QUOTA=75%            unit CPUQuota
  DSH_TASKS_MAX=128            unit TasksMax
  DSH_TLS_CERT / DSH_TLS_KEY   use an existing certificate pair instead
  DSH_TLS_DIR=/etc/dsh/tls     where self-signed files are written
  DSH_TLS_KEY_TYPE             rsa2048 (default) or ecdsa
  DSH_TLS_DAYS=3650            self-signed validity in days
  DSH_VERIFY_WS=yes            verify a WebSocket upgrade returns 101
  DSH_DRY_RUN=yes              validate inputs, change nothing
USAGE
  exit 0
fi
# A dry run only reads inputs and resources; it must stay usable for unprivileged
# operators and CI, so the privilege check comes after the dry-run exit.
if [[ $DSH_DRY_RUN != yes ]]; then
  [[ $EUID -eq 0 ]] || fail 'run as root (for example: sudo ./install.sh)'
fi
[[ $DSH_PORT =~ ^[0-9]+$ && $DSH_PORT -ge 1 && $DSH_PORT -le 65535 ]] || fail 'DSH_PORT must be 1..65535'
[[ $DSH_TAILSCALE_MODE == serve || $DSH_TAILSCALE_MODE == local-only ]] || fail 'DSH_TAILSCALE_MODE must be serve or local-only'
[[ $DSH_DRY_RUN == yes || $DSH_DRY_RUN == no ]] || fail 'DSH_DRY_RUN must be yes or no'
[[ $DSH_ENABLE == yes || $DSH_ENABLE == no ]] || fail 'DSH_ENABLE must be yes or no'
[[ $DSH_VERIFY_WS == yes || $DSH_VERIFY_WS == no ]] || fail 'DSH_VERIFY_WS must be yes or no'
[[ $DSH_APP_ROOT == /* && $DSH_APP_ROOT != / ]] || fail 'DSH_APP_ROOT must be an absolute path other than /'
[[ $DSH_HOME == /* && $DSH_HOME != / ]] || fail 'DSH_HOME must be an absolute path other than /'
[[ $DSH_APP_ROOT/ != "$DSH_HOME"/* && $DSH_HOME/ != "$DSH_APP_ROOT"/* ]] || fail 'DSH_APP_ROOT and DSH_HOME must not contain each other'
# systemd reads a bare memory number as bytes, so DSH_MEMORY_MAX=1024 would mean
# a 1 KiB ceiling and a unit that never starts. Require the suffix instead of
# letting that fail silently at cgroup level.
[[ $DSH_MEMORY_HIGH =~ ^([0-9]+[KMGTPkmgtp]|infinity)$ ]] || fail 'DSH_MEMORY_HIGH needs a size suffix (for example 512M or 1G); a bare number means bytes to systemd'
[[ $DSH_MEMORY_MAX =~ ^([0-9]+[KMGTPkmgtp]|infinity)$ ]] || fail 'DSH_MEMORY_MAX needs a size suffix (for example 768M or 1G); a bare number means bytes to systemd'
[[ $DSH_CPU_QUOTA =~ ^[0-9]{1,3}%$ ]] || fail 'DSH_CPU_QUOTA must be a percentage such as 75%'
[[ $DSH_TASKS_MAX =~ ^[0-9]+$ ]] || fail 'DSH_TASKS_MAX must be an integer'

DSH_NATIVE_TLS=no
case "$DSH_TAILSCALE_MODE" in
  serve) DSH_NATIVE_TLS=yes;;
  local-only) ;;
esac

if [[ -n $DSH_TLS_CERT || -n $DSH_TLS_KEY ]]; then
  [[ -n $DSH_TLS_CERT && -n $DSH_TLS_KEY ]] || fail 'DSH_TLS_CERT and DSH_TLS_KEY must be provided together'
  [[ -r $DSH_TLS_CERT && -r $DSH_TLS_KEY ]] || fail 'TLS files must exist and be readable before installation'
  DSH_NATIVE_TLS=yes
fi
[[ -r "$SCRIPT_DIR/bin/dsh-web-start.sh" ]] || fail "missing resource: $SCRIPT_DIR/bin/dsh-web-start.sh"
[[ -r "$SCRIPT_DIR/systemd/dsh-web.service.in" ]] || fail "missing resource: $SCRIPT_DIR/systemd/dsh-web.service.in"
[[ -r "$SCRIPT_DIR/tools/tailscale-serve.sh" ]] || fail "missing resource: $SCRIPT_DIR/tools/tailscale-serve.sh"
[[ -r "$SCRIPT_DIR/tools/verify-auth-cookie.sh" ]] || fail "missing resource: $SCRIPT_DIR/tools/verify-auth-cookie.sh"
[[ -r "$SCRIPT_DIR/tools/gen-selfsigned-cert.sh" ]] || fail "missing resource: $SCRIPT_DIR/tools/gen-selfsigned-cert.sh"
[[ -r "$SCRIPT_DIR/tools/probe-url.sh" ]] || fail "missing resource: $SCRIPT_DIR/tools/probe-url.sh"
[[ -r "$SCRIPT_DIR/tools/verify-ws.mjs" ]] || fail "missing resource: $SCRIPT_DIR/tools/verify-ws.mjs"

if [[ $DSH_DRY_RUN == yes ]]; then
  printf 'dry-run: mode=%s, tls=%s, resources=%s, unit=%s, no host changes made\n' \
    "$DSH_TAILSCALE_MODE" "$([[ $DSH_NATIVE_TLS == yes ]] && printf selfsigned || printf none)" "$SCRIPT_DIR" "$UNIT_NAME"
  exit 0
fi

source "$SCRIPT_DIR/tools/tailscale-serve.sh"
source "$SCRIPT_DIR/tools/verify-auth-cookie.sh"
source "$SCRIPT_DIR/tools/gen-selfsigned-cert.sh"
source "$SCRIPT_DIR/tools/probe-url.sh"

tailscale_host=''
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
if [[ $DSH_TAILSCALE_MODE == serve ]]; then
  [[ $DSH_PUBLIC_URL == https://* ]] || fail 'serve mode requires an https DSH_PUBLIC_URL (secure cookies need the HTTPS origin)'
fi
if [[ $DSH_NATIVE_TLS == yes ]]; then
  # Native TLS terminates HTTPS locally, so the advertised origin must be https.
  [[ $DSH_PUBLIC_URL == https://* ]] || fail 'native TLS requires an https DSH_PUBLIC_URL so DSH marks its cookies Secure'
fi
if [[ $DSH_TAILSCALE_MODE == local-only ]]; then
  # The post-install self-check probes http(s)://127.0.0.1:$DSH_PORT/, and DSH's
  # /api browser-trust fence only accepts the loopback Host when the authority is
  # trusted; without it a healthy service answers 421 to its own self-check.
  # This only widens the fence for loopback, which is what DSH already binds.
  DSH_TRUSTED_HOST=$(ensure_trusted_loopback "$DSH_TRUSTED_HOST")
fi
command -v node >/dev/null || fail 'Node.js is required (>= 24.9.0)'
command -v npm >/dev/null || fail 'npm is required'
command -v systemctl >/dev/null || fail 'systemd is required'
command -v openssl >/dev/null || fail 'openssl is required to generate the self-signed certificate'
node -e 'const [a,b,c]=process.versions.node.split(".").map(Number); if (a<24 || (a===24 && b<9)) process.exit(1)' || fail 'Node.js >= 24.9.0 is required'

if ! id "$DSH_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$DSH_HOME" --create-home --shell /usr/sbin/nologin "$DSH_USER"
fi
DSH_GROUP=$(id -gn "$DSH_USER") || fail "cannot resolve the primary group of $DSH_USER"
DSH_APP_DIR="$DSH_APP_ROOT/app"
DSH_WORKSPACE="$DSH_HOME/workspace"
# Data dir: the service user owns it (it holds profiles, credentials, sessions
# under $DSH_HOME/.dsh, and the agent workspace). World-inaccessible.
install -d -o "$DSH_USER" -g "$DSH_GROUP" -m 0750 "$DSH_HOME"
# Workspace: the DSH default working directory, a sibling of .dsh rather than
# the home directory itself, so the agent never sees the data-dir layout root.
install -d -o "$DSH_USER" -g "$DSH_GROUP" -m 0750 "$DSH_WORKSPACE"
# Program root: root-owned and only readable by the service user. Combined with
# ProtectSystem=strict + ReadWritePaths=$DSH_HOME the service cannot modify it,
# and because it lives outside $DSH_HOME the agent cannot see it from its
# workspace.
install -d -o root -g root -m 0755 "$DSH_APP_ROOT"
# The service user may traverse /etc/dsh (to reach the TLS files) but must not
# be able to write to it.
install -d -o root -g "$DSH_GROUP" -m 0750 /etc/dsh

if [[ $DSH_NATIVE_TLS == yes ]]; then
  # Self-signed by default (10 years); an operator-supplied pair is used as-is.
  if [[ -z $DSH_TLS_CERT ]]; then
    # The first authority is the advertised host name; extra loopback entries
    # are only for the in-host trust fence, not certificate SANs.
    cert_host=${DSH_TRUSTED_HOST%%[[:space:]]*}
    [[ $cert_host == *.invalid ]] && fail 'native TLS needs a real MagicDNS host name to put in the certificate SAN'
    gen_selfsigned_cert "$DSH_TLS_DIR" "$cert_host" "$DSH_GROUP" || fail 'self-signed certificate generation failed'
    DSH_TLS_CERT="$DSH_TLS_DIR/dsh.crt"
    DSH_TLS_KEY="$DSH_TLS_DIR/dsh.key"
  fi
  [[ -r $DSH_TLS_CERT && -r $DSH_TLS_KEY ]] || fail 'native TLS certificate files are not readable'
  # systemd runs DSH as the service user, so the key group must be readable there.
  chmod 0644 "$DSH_TLS_CERT"
  if ! chgrp "$DSH_GROUP" "$DSH_TLS_KEY" 2>/dev/null || ! chmod 0640 "$DSH_TLS_KEY"; then
    printf 'warning: could not set %s to root:%s 0640; verify DSH can still read it\n' "$DSH_TLS_KEY" "$DSH_GROUP" >&2
  fi
fi

# Fetch the exact tarball once, verify its digest locally, then install from that
# file. Comparing a separately-queried "npm view dist.integrity" would not bind
# the check to the bytes actually installed (TOCTOU).
pkg_tmp=$(mktemp -d)
trap 'rm -rf "$pkg_tmp"' EXIT
npm pack "$PACKAGE" --pack-destination "$pkg_tmp" --registry=https://registry.npmjs.org >/dev/null \
  || fail "could not download $PACKAGE"
pkg_tarball=$(find "$pkg_tmp" -maxdepth 1 -name '*.tgz' -print -quit)
[[ -n $pkg_tarball ]] || fail "npm pack produced no tarball for $PACKAGE"
pkg_integrity="sha512-$(openssl dgst -sha512 -binary "$pkg_tarball" | openssl base64 -A)"
[[ $pkg_integrity == "$EXPECTED_INTEGRITY" ]] || fail "tarball integrity mismatch for $PACKAGE"
# Install into a fresh staging tree under the program root and swap it in: npm
# cannot reliably rewrite an existing node_modules, and a half-updated tree is
# worse than none. The tree stays root-owned, so the service user can only read
# it (and the agent, whose workspace is $DSH_WORKSPACE, cannot see it at all).
app_stage="$DSH_APP_ROOT/.app.stage.$$"
app_previous="$DSH_APP_ROOT/.app.previous.$$"
cleanup_app_stage() { rm -rf "$app_stage" "$app_previous" "$pkg_tmp"; }
trap cleanup_app_stage EXIT
rm -rf "$app_stage" "$app_previous"
install -d -o root -g root -m 0755 "$app_stage"
# --no-save/--no-package-lock keep npm from baking the temporary tarball path
# into the installed tree: it would record "file:/tmp/…/dsh-<ver>.tgz" for a file
# the cleanup trap deletes, leaving a dangling dependency spec nobody can replay.
npm install --prefix "$app_stage" --omit=dev --ignore-scripts --bin-links=false \
  --no-save --no-package-lock "$pkg_tarball"
STAGED_ENTRYPOINT="$app_stage/node_modules/@deepseek-ai/dsh/lib/bin.js"
[[ -r $STAGED_ENTRYPOINT ]] || fail 'DSH entrypoint was not found in the staged installation'
if [[ -d $DSH_APP_DIR ]]; then mv "$DSH_APP_DIR" "$app_previous"; fi
mv "$app_stage" "$DSH_APP_DIR"
rm -rf "$app_previous"
chmod 0755 "$DSH_APP_DIR"
trap - EXIT
# npm must never leave the program tree writable by the service user.
chown -R root:root "$DSH_APP_DIR"
# Retire the pre-split layout, where the program tree lived inside the service
# home and was writable by the service user. Only ever remove a tree that is
# recognisably ours; anything else is left for the operator to inspect.
legacy_app="$DSH_HOME/app"
if [[ -d $legacy_app ]]; then
  if [[ -d $legacy_app/node_modules/@deepseek-ai/dsh ]]; then
    rm -rf "$legacy_app"
    printf 'removed the legacy program tree %s (programs now live in %s)\n' "$legacy_app" "$DSH_APP_DIR"
  else
    printf 'warning: %s exists but is not a DSH tree; leaving it alone\n' "$legacy_app" >&2
  fi
fi
DSH_ENTRYPOINT="$DSH_APP_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
[[ -r $DSH_ENTRYPOINT ]] || fail 'DSH entrypoint was not found after npm installation'
DSH_BIN=/usr/local/libexec/dsh-cli

unit_path=/etc/systemd/system/$UNIT_NAME
# Retired topology: an old install may still have this unit on disk.
proxy_unit_path=/etc/systemd/system/$LEGACY_PROXY_UNIT_NAME
if [[ -e $unit_path ]] && ! grep -Fqx "$MARKER" "$unit_path"; then
  fail "$unit_path exists and is not managed by this project"
fi
if [[ -e $proxy_unit_path ]] && ! grep -Fqx "$MARKER" "$proxy_unit_path"; then
  fail "$proxy_unit_path exists and is not managed by this project"
fi
install -d -m 0755 /usr/local/libexec
install -m 0755 "$SCRIPT_DIR/bin/dsh-cli.sh" /usr/local/libexec/dsh-cli
start_template=$(<"$SCRIPT_DIR/bin/dsh-web-start.sh")
start_template=${start_template//@DSH_BIN@/$DSH_BIN}
printf '%s\n' "$start_template" | install -m 0755 /dev/stdin /usr/local/libexec/dsh-web-start
unit_template=$(<"$SCRIPT_DIR/systemd/dsh-web.service.in")
unit_template=${unit_template//@MARKER@/$MARKER}
unit_template=${unit_template//@DSH_USER@/$DSH_USER}
unit_template=${unit_template//@DSH_HOME@/$DSH_HOME}
unit_template=${unit_template//@DSH_WORKSPACE@/$DSH_WORKSPACE}
unit_template=${unit_template//@DSH_APP_DIR@/$DSH_APP_DIR}
unit_template=${unit_template//@DSH_MEMORY_HIGH@/$DSH_MEMORY_HIGH}
unit_template=${unit_template//@DSH_MEMORY_MAX@/$DSH_MEMORY_MAX}
unit_template=${unit_template//@DSH_CPU_QUOTA@/$DSH_CPU_QUOTA}
unit_template=${unit_template//@DSH_TASKS_MAX@/$DSH_TASKS_MAX}
printf '%s\n' "$unit_template" | install -m 0644 /dev/stdin "$unit_path"

# Write secrets/config atomically; the env file is never world-readable.
# systemd's EnvironmentFile is not bash: a bare value may contain spaces, but a
# backslash, quote or $ must be escaped, and %q would emit bash-only quoting.
env_escape() {
  local v=$1
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  v=${v//\$/\\$}
  printf '%s' "$v"
}
env_line() { printf '%s=%s\n' "$1" "$(env_escape "$2")"; }
env_tmp=$(mktemp /etc/dsh/dsh-web.env.XXXXXX)
trap 'rm -f "$env_tmp"' EXIT
{
  env_line DSH_BIN "$DSH_BIN"
  env_line DSH_NODE "$(command -v node)"
  env_line DSH_ENTRYPOINT "$DSH_ENTRYPOINT"
  env_line DSH_PUBLIC_URL "$DSH_PUBLIC_URL"
  env_line DSH_TRUSTED_HOST "$DSH_TRUSTED_HOST"
  env_line DSH_PORT "$DSH_PORT"
  env_line DSH_TAILSCALE_MODE "$DSH_TAILSCALE_MODE"
  env_line DSH_TLS_CERT "$DSH_TLS_CERT"
  env_line DSH_TLS_KEY "$DSH_TLS_KEY"
} > "$env_tmp"
chown root:"$DSH_USER" "$env_tmp"
chmod 0640 "$env_tmp"
mv -f "$env_tmp" /etc/dsh/dsh-web.env
trap - EXIT

systemctl daemon-reload
if [[ -e $proxy_unit_path ]]; then
  # Upgrading from the removed proxy topology: stop and forget that unit so it
  # cannot keep listening on 3081 or shadow the native TLS listener.
  systemctl disable --now "$LEGACY_PROXY_UNIT_NAME" >/dev/null 2>&1 || true
  rm -f "$proxy_unit_path"
  systemctl daemon-reload
  printf 'retired legacy %s (native TLS replaces it)\n' "$LEGACY_PROXY_UNIT_NAME"
fi
if [[ $DSH_ENABLE == yes ]]; then
  # `enable --now` is a no-op on an already-running unit, which would leave the
  # old process (old env file, old flags) serving traffic. Always restart.
  systemctl enable "$UNIT_NAME"
  systemctl restart "$UNIT_NAME"
fi
if [[ $DSH_TAILSCALE_MODE == serve ]]; then
  # Self-signed certificate is only trusted inside the tunnel.
  DSH_SERVE_BACKEND="https+insecure://127.0.0.1:${DSH_PORT}"
  export DSH_SERVE_BACKEND
  tailscale_serve_apply "${DSH_TRUSTED_HOST%%[[:space:]]*}" || fail 'Tailscale Serve was not verified; no success is claimed'
fi

if [[ $DSH_ENABLE == yes ]]; then
  # Exercise the real authenticated entrypoint without printing the credential.
  command -v curl >/dev/null || fail 'curl is required to verify the authenticated entrypoint'
  # Where to probe. In local-only mode DSH binds 127.0.0.1 only, so a
  # non-loopback DSH_PUBLIC_URL is unreachable from the host: probing it would
  # fail against a perfectly healthy service. Probe loopback there, and leave
  # the advertised DSH_PUBLIC_URL (what DSH serves and what the operator uses)
  # untouched.
  probe_url=$(dsh_probe_url "$DSH_TAILSCALE_MODE" "$DSH_PUBLIC_URL" "$DSH_PORT" "$DSH_NATIVE_TLS")
  VERIFY_INSECURE=$(dsh_probe_insecure "$DSH_TAILSCALE_MODE" "$DSH_NATIVE_TLS")
  export VERIFY_INSECURE
  probe_curl_insecure=()
  ws_insecure=()
  if [[ $VERIFY_INSECURE == yes ]]; then
    # Only ever for the loopback probe of our own self-signed certificate.
    probe_curl_insecure=(--insecure)
    ws_insecure=(--insecure)
  fi
  if [[ $probe_url != "$DSH_PUBLIC_URL" ]]; then
    printf 'self-check probes %s (loopback) because mode=%s binds 127.0.0.1 only; advertised URL stays %s\n' \
      "$probe_url" "$DSH_TAILSCALE_MODE" "$DSH_PUBLIC_URL"
  fi

  login_url=''
  for _ in {1..30}; do
    login_url=$(node --experimental-strip-types "$SCRIPT_DIR/tools/login-url.ts" --unit "$UNIT_NAME" --public-url "$probe_url" 2>/dev/null) && break
    sleep 1
  done
  [[ -n $login_url ]] || fail 'could not read the current startup credential; inspect the unit journal and rerun'

  # 1. Unauthenticated base URL must be refused.
  verify_unauthenticated_entrypoint "$probe_url" 401 || fail 'unauthenticated base URL was not rejected with 401'
  # 2. The credential URL must redirect, and set a hardened cookie.
  verify_login_redirect "$login_url" 303 || fail 'credential login URL did not answer with a 303 redirect'
  verify_authenticated_entrypoint "$login_url" "$([[ $DSH_NATIVE_TLS == yes ]] && printf yes || printf no)" \
    || fail 'authenticated entrypoint did not satisfy the configured Cookie policy; refusing to claim installation success'
  printf 'entry verification: 401 unauthenticated, 303 login redirect, hardened cookie at %s\n' "$probe_url"

  # 3. WebSocket upgrade over the same origin a browser would use: the public
  #    entrypoint in Serve modes (which exercises Serve), loopback in local-only
  #    mode where nothing else is reachable. The login cookie is scoped to that
  #    host, so it must be presented there.
  if [[ $DSH_VERIFY_WS == yes ]]; then
    ws_url="${probe_url%/}${DSH_WS_PATH}"
    jar=$(mktemp)
    chmod 0600 "$jar"
    curl --silent --show-error --output /dev/null --max-time 15 \
      ${probe_curl_insecure[@]+"${probe_curl_insecure[@]}"} \
      -c "$jar" "$login_url" >/dev/null 2>&1 || true
    if node "$SCRIPT_DIR/tools/verify-ws.mjs" --url "$ws_url" --cookie-jar "$jar" \
        ${ws_insecure[@]+"${ws_insecure[@]}"}; then
      rm -f "$jar"
      printf 'websocket verification: upgrade handshake returned 101 at %s\n' "$ws_url"
    else
      rm -f "$jar"
      fail 'WebSocket upgrade did not return 101; inspect the unit journal and rerun'
    fi
  fi

  if [[ $DSH_NATIVE_TLS == yes ]]; then
    printf 'certificate: %s expires %s (%s days left)\n' \
      "$DSH_TLS_CERT" "$(openssl x509 -in "$DSH_TLS_CERT" -noout -enddate | sed 's/^notAfter=//')" "$(cert_days_left "$DSH_TLS_CERT")"
  fi
else
  printf 'installed but not started: rerun with DSH_ENABLE=yes to verify the authenticated entrypoint\n'
fi

printf 'installed %s, mode=%s, unit=%s, user=%s\n' "$PACKAGE" "$DSH_TAILSCALE_MODE" "$UNIT_NAME" "$DSH_USER"
printf 'full login URL is intentionally not written to logs or reports; obtain it in the operator terminal with:\n'
printf 'sudo node --experimental-strip-types %s/tools/login-url.ts --unit %s --public-url %s\n' "$SCRIPT_DIR" "$UNIT_NAME" "$DSH_PUBLIC_URL"
if [[ $DSH_NATIVE_TLS == yes ]]; then
  printf 'certificate expiry, for the README diagnostics section:\n'
  printf '  openssl x509 -in %s -noout -enddate\n' "$DSH_TLS_CERT"
fi
