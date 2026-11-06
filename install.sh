#!/usr/bin/env bash
set -Eeuo pipefail

readonly VERSION='0.2.2-rc.1'
readonly PACKAGE="@deepseek-ai/dsh@${VERSION}"
readonly EXPECTED_INTEGRITY='sha512-ijR9UEVYkG15Q/Q79JzvzLBzQOQfc63VLr9n6flpwHPhr5IKn2UxthnSoto/P9l7qGd7pPvI1Ra6TW7LH3oKpg=='
readonly UNIT_NAME='dsh-web.service'
readonly PROXY_UNIT_NAME='dsh-web-proxy.service'
readonly MARKER='# Managed by dsh-vps-deploy; review before changing.'
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

: "${DSH_USER:=dsh}"
: "${DSH_HOME:=/var/lib/dsh}"
# Program code lives outside the service home so the service user (and the
# agent it hosts) cannot rewrite its own installation.
: "${DSH_APP_ROOT:=/opt/dsh}"
: "${DSH_PORT:=3080}"
: "${DSH_PROXY_PORT:=3081}"
: "${DSH_ENABLE:=yes}"
# serve (default: native TLS + Serve), serve-proxy (legacy local proxy),
# local-only (SSH tunnel), external-proxy.
: "${DSH_TAILSCALE_MODE:=serve}"
# native (default) or proxy; proxy downgrades the default serve mode to the
# legacy 3081 local-proxy topology.
: "${DSH_TLS_MODE:=native}"
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
readonly DSH_WS_PATH='/api/remote.mux'

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  cat <<'USAGE'
usage: sudo ./install.sh

Default: native TLS with a generated self-signed certificate in /etc/dsh/tls,
served by DSH on https 127.0.0.1:3080 and published with
  tailscale serve --bg --https=443 https+insecure://127.0.0.1:3080
No local proxy is installed or enabled in this mode.

Modes:
  DSH_TLS_MODE=proxy                       legacy proxy fallback (127.0.0.1:3081)
  DSH_TAILSCALE_MODE=serve-proxy           same as above, explicit form
  DSH_TAILSCALE_MODE=local-only            loopback only, for SSH tunnels
  DSH_TAILSCALE_MODE=external-proxy        bring your own HTTPS reverse proxy

Variables:
  DSH_USER=dsH                 service user (default dsh)
  DSH_HOME=/var/lib/dsh        service data dir, DSH_HOME (default /var/lib/dsh)
  DSH_APP_ROOT=/opt/dsh        program root, app installed in $DSH_APP_ROOT/app
  DSH_PORT=3080                DSH listener port
  DSH_PROXY_PORT=3081          legacy proxy port (fallback modes only)
  DSH_TLS_CERT / DSH_TLS_KEY   use an existing certificate pair instead
  DSH_TLS_DIR=/etc/dsh/tls     where self-signed files are written
  DSH_TLS_KEY_TYPE             rsa2048 (default) or ecdsa
  DSH_TLS_DAYS=3650            self-signed validity in days
  DSH_VERIFY_WS=yes            verify a WebSocket upgrade returns 101
  DSH_DRY_RUN=yes              validate inputs, change nothing
USAGE
  exit 0
fi
[[ $EUID -eq 0 ]] || fail 'run as root (for example: sudo ./install.sh)'
[[ $DSH_PORT =~ ^[0-9]+$ && $DSH_PORT -ge 1 && $DSH_PORT -le 65535 ]] || fail 'DSH_PORT must be 1..65535'
[[ $DSH_PROXY_PORT =~ ^[0-9]+$ && $DSH_PROXY_PORT -ge 1 && $DSH_PROXY_PORT -le 65535 && $DSH_PROXY_PORT != "$DSH_PORT" ]] || fail 'DSH_PROXY_PORT must be 1..65535 and differ from DSH_PORT'
[[ $DSH_TAILSCALE_MODE == serve || $DSH_TAILSCALE_MODE == serve-proxy || $DSH_TAILSCALE_MODE == local-only || $DSH_TAILSCALE_MODE == external-proxy ]] || fail 'DSH_TAILSCALE_MODE must be serve, serve-proxy, local-only, or external-proxy'
[[ $DSH_TLS_MODE == native || $DSH_TLS_MODE == proxy ]] || fail 'DSH_TLS_MODE must be native or proxy'
[[ $DSH_DRY_RUN == yes || $DSH_DRY_RUN == no ]] || fail 'DSH_DRY_RUN must be yes or no'
[[ $DSH_ENABLE == yes || $DSH_ENABLE == no ]] || fail 'DSH_ENABLE must be yes or no'
[[ $DSH_VERIFY_WS == yes || $DSH_VERIFY_WS == no ]] || fail 'DSH_VERIFY_WS must be yes or no'
[[ $DSH_APP_ROOT == /* && $DSH_APP_ROOT != / ]] || fail 'DSH_APP_ROOT must be an absolute path other than /'
[[ $DSH_HOME == /* && $DSH_HOME != / ]] || fail 'DSH_HOME must be an absolute path other than /'
[[ $DSH_APP_ROOT/ != "$DSH_HOME"/* && $DSH_HOME/ != "$DSH_APP_ROOT"/* ]] || fail 'DSH_APP_ROOT and DSH_HOME must not contain each other'

# The legacy proxy topology is now strictly opt-in. DSH_TLS_MODE=proxy is the
# short form of asking for it in the default serve mode.
if [[ $DSH_TAILSCALE_MODE == serve && $DSH_TLS_MODE == proxy ]]; then
  DSH_TAILSCALE_MODE=serve-proxy
fi

DSH_USE_PROXY=no
DSH_NATIVE_TLS=no
case "$DSH_TAILSCALE_MODE" in
  serve) DSH_NATIVE_TLS=yes;;
  serve-proxy|external-proxy) DSH_USE_PROXY=yes;;
  local-only) ;;
esac
DSH_PROXY_SECURE_COOKIES=no
[[ $DSH_USE_PROXY == yes ]] && DSH_PROXY_SECURE_COOKIES=yes

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
[[ -r "$SCRIPT_DIR/bin/dsh-web-proxy.cjs" ]] || fail "missing resource: $SCRIPT_DIR/bin/dsh-web-proxy.cjs"
[[ -r "$SCRIPT_DIR/systemd/dsh-web-proxy.service.in" ]] || fail "missing resource: $SCRIPT_DIR/systemd/dsh-web-proxy.service.in"

if [[ $DSH_DRY_RUN == yes ]]; then
  printf 'dry-run: mode=%s, tls=%s, proxy=%s, resources=%s, unit=%s, no host changes made\n' \
    "$DSH_TAILSCALE_MODE" "$([[ $DSH_NATIVE_TLS == yes ]] && printf selfsigned || printf none)" "$DSH_USE_PROXY" "$SCRIPT_DIR" "$UNIT_NAME"
  exit 0
fi

source "$SCRIPT_DIR/tools/tailscale-serve.sh"
source "$SCRIPT_DIR/tools/verify-auth-cookie.sh"
source "$SCRIPT_DIR/tools/gen-selfsigned-cert.sh"
source "$SCRIPT_DIR/tools/probe-url.sh"

tailscale_host=''
if [[ $DSH_TAILSCALE_MODE == serve || $DSH_TAILSCALE_MODE == serve-proxy ]]; then
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
if [[ $DSH_TAILSCALE_MODE == serve || $DSH_TAILSCALE_MODE == serve-proxy ]]; then
  [[ $DSH_PUBLIC_URL == https://* ]] || fail 'private HTTPS modes require an https DSH_PUBLIC_URL (secure cookies need the external HTTPS origin)'
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

npm_integrity="$(npm view "$PACKAGE" dist.integrity --registry=https://registry.npmjs.org)"
[[ $npm_integrity == "$EXPECTED_INTEGRITY" ]] || fail "npm integrity mismatch for $PACKAGE"
# Install into a fresh staging tree under the program root and swap it in: npm
# cannot reliably rewrite an existing node_modules, and a half-updated tree is
# worse than none. The tree stays root-owned, so the service user can only read
# it (and the agent, whose workspace is $DSH_WORKSPACE, cannot see it at all).
app_stage="$DSH_APP_ROOT/.app.stage.$$"
app_previous="$DSH_APP_ROOT/.app.previous.$$"
cleanup_app_stage() { rm -rf "$app_stage" "$app_previous"; }
trap cleanup_app_stage EXIT
rm -rf "$app_stage" "$app_previous"
install -d -o root -g root -m 0755 "$app_stage"
npm install --prefix "$app_stage" --omit=dev --ignore-scripts --bin-links=false "$PACKAGE"
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
proxy_unit_path=/etc/systemd/system/$PROXY_UNIT_NAME
if [[ -e $unit_path ]] && ! grep -Fqx "$MARKER" "$unit_path"; then
  fail "$unit_path exists and is not managed by this project"
fi
if [[ -e $proxy_unit_path ]] && ! grep -Fqx "$MARKER" "$proxy_unit_path"; then
  fail "$proxy_unit_path exists and is not managed by this project"
fi
install -d -m 0755 /usr/local/libexec
install -m 0755 "$SCRIPT_DIR/bin/dsh-cli.sh" /usr/local/libexec/dsh-cli
install -m 0644 "$SCRIPT_DIR/bin/dsh-web-proxy.cjs" /usr/local/libexec/dsh-web-proxy.cjs
start_template=$(<"$SCRIPT_DIR/bin/dsh-web-start.sh")
start_template=${start_template//@DSH_BIN@/$DSH_BIN}
printf '%s\n' "$start_template" | install -m 0755 /dev/stdin /usr/local/libexec/dsh-web-start
unit_template=$(<"$SCRIPT_DIR/systemd/dsh-web.service.in")
unit_template=${unit_template//@MARKER@/$MARKER}
unit_template=${unit_template//@DSH_USER@/$DSH_USER}
unit_template=${unit_template//@DSH_HOME@/$DSH_HOME}
unit_template=${unit_template//@DSH_WORKSPACE@/$DSH_WORKSPACE}
unit_template=${unit_template//@DSH_APP_DIR@/$DSH_APP_DIR}
printf '%s\n' "$unit_template" | install -m 0644 /dev/stdin "$unit_path"

# The loopback proxy unit is only materialised for the opt-in fallback modes.
if [[ $DSH_USE_PROXY == yes ]]; then
  proxy_unit_template=$(<"$SCRIPT_DIR/systemd/dsh-web-proxy.service.in")
  proxy_unit_template=${proxy_unit_template//@MARKER@/$MARKER}
  proxy_unit_template=${proxy_unit_template//@DSH_USER@/$DSH_USER}
  proxy_unit_template=${proxy_unit_template//@DSH_HOME@/$DSH_HOME}
  proxy_unit_template=${proxy_unit_template//@DSH_WORKSPACE@/$DSH_WORKSPACE}
  proxy_unit_template=${proxy_unit_template//@DSH_APP_DIR@/$DSH_APP_DIR}
  printf '%s\n' "$proxy_unit_template" | install -m 0644 /dev/stdin "$proxy_unit_path"
fi

# Write secrets/config atomically; the env file is never world-readable.
env_tmp=$(mktemp /etc/dsh/dsh-web.env.XXXXXX)
trap 'rm -f "$env_tmp"' EXIT
{
  printf 'DSH_BIN=%q\n' "$DSH_BIN"
  printf 'DSH_NODE=%q\n' "$(command -v node)"
  printf 'DSH_ENTRYPOINT=%q\n' "$DSH_ENTRYPOINT"
  printf 'DSH_PUBLIC_URL=%q\n' "$DSH_PUBLIC_URL"
  printf 'DSH_TRUSTED_HOST=%q\n' "$DSH_TRUSTED_HOST"
  printf 'DSH_PORT=%q\n' "$DSH_PORT"
  printf 'DSH_PROXY_PORT=%q\n' "$DSH_PROXY_PORT"
  printf 'DSH_PROXY_SECURE_COOKIES=%q\n' "$DSH_PROXY_SECURE_COOKIES"
  printf 'DSH_TAILSCALE_MODE=%q\n' "$DSH_TAILSCALE_MODE"
  printf 'DSH_TLS_MODE=%q\n' "$([[ $DSH_NATIVE_TLS == yes ]] && printf native || printf proxy)"
  printf 'DSH_TLS_CERT=%q\n' "$DSH_TLS_CERT"
  printf 'DSH_TLS_KEY=%q\n' "$DSH_TLS_KEY"
} > "$env_tmp"
chown root:"$DSH_USER" "$env_tmp"
chmod 0640 "$env_tmp"
mv -f "$env_tmp" /etc/dsh/dsh-web.env
trap - EXIT

systemctl daemon-reload
if [[ $DSH_USE_PROXY == no && -e $proxy_unit_path ]]; then
  # Migrating away from the legacy topology: stop and forget the proxy unit.
  systemctl disable --now "$PROXY_UNIT_NAME" >/dev/null 2>&1 || true
  rm -f "$proxy_unit_path"
  systemctl daemon-reload
  printf 'retired legacy %s (native TLS mode does not use it)\n' "$PROXY_UNIT_NAME"
fi
if [[ $DSH_ENABLE == yes ]]; then
  # `enable --now` is a no-op on an already-running unit, which would leave the
  # old process (old env file, old flags) serving traffic. Always restart.
  systemctl enable "$UNIT_NAME"
  systemctl restart "$UNIT_NAME"
  if [[ $DSH_USE_PROXY == yes ]]; then
    systemctl enable "$PROXY_UNIT_NAME"
    systemctl restart "$PROXY_UNIT_NAME"
  fi
fi
if [[ $DSH_TAILSCALE_MODE == serve || $DSH_TAILSCALE_MODE == serve-proxy ]]; then
  if [[ $DSH_NATIVE_TLS == yes ]]; then
    # Self-signed certificate is only trusted inside the tunnel.
    DSH_SERVE_BACKEND="https+insecure://127.0.0.1:${DSH_PORT}"
  else
    DSH_SERVE_BACKEND="http://127.0.0.1:${DSH_PROXY_PORT}"
  fi
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
  verify_authenticated_entrypoint "$login_url" "$([[ $DSH_NATIVE_TLS == yes || $DSH_PROXY_SECURE_COOKIES == yes ]] && printf yes || printf no)" \
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

printf 'installed %s, mode=%s, unit=%s, user=%s, proxy=%s\n' "$PACKAGE" "$DSH_TAILSCALE_MODE" "$UNIT_NAME" "$DSH_USER" "$DSH_USE_PROXY"
printf 'full login URL is intentionally not written to logs or reports; obtain it in the operator terminal with:\n'
printf 'sudo node --experimental-strip-types %s/tools/login-url.ts --unit %s --public-url %s\n' "$SCRIPT_DIR" "$UNIT_NAME" "$DSH_PUBLIC_URL"
if [[ $DSH_NATIVE_TLS == yes ]]; then
  printf 'certificate expiry, for the README diagnostics section:\n'
  printf '  openssl x509 -in %s -noout -enddate\n' "$DSH_TLS_CERT"
fi
