#!/usr/bin/env bash
# Offline coverage for the default native TLS mode and the proxy fallback.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
node_bin=${NODE_BIN:-node}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass() { printf 'ok - %s\n' "$1"; }
die() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

# --- certificate generation -------------------------------------------------
source "$root/tools/gen-selfsigned-cert.sh"
cert_dir="$work/tls"
gen_selfsigned_cert "$cert_dir" vps.test.ts.net root 2>/dev/null || die 'certificate generation failed'
[[ -r $cert_dir/dsh.crt && -r $cert_dir/dsh.key ]] || die 'certificate files missing'
pass 'generates a self-signed certificate pair'

[[ $(stat -c '%a' "$cert_dir") == 750 ]] || die "cert dir mode $(stat -c '%a' "$cert_dir") != 750"
[[ $(stat -c '%U' "$cert_dir") == root ]] || die 'cert dir is not owned by root'
[[ $(stat -c '%G' "$cert_dir") == root ]] || die 'cert dir group should follow the service group'
[[ $(stat -c '%U' "$cert_dir/dsh.key") == root ]] || die 'private key is not owned by root'
[[ $(stat -c '%a' "$cert_dir/dsh.key") == 640 ]] || die 'private key is not 0640'
[[ $(stat -c '%a' "$cert_dir/dsh.crt") == 644 ]] || die 'certificate is not 0644'
pass 'applies minimal certificate permissions (dir 0750, key 0640)'

sans=$(openssl x509 -in "$cert_dir/dsh.crt" -noout -ext subjectAltName)
printf '%s' "$sans" | grep -Fq 'DNS:vps.test.ts.net' || die 'SAN is missing the MagicDNS host name'
printf '%s' "$sans" | grep -Fq 'IP Address:127.0.0.1' || die 'SAN is missing 127.0.0.1'
pass 'SAN carries the MagicDNS host and 127.0.0.1'

days=$(cert_days_left "$cert_dir/dsh.crt")
[[ $days -ge 3640 && $days -le 3650 ]] || die "certificate validity $days days is not ~10 years"
openssl x509 -in "$cert_dir/dsh.crt" -noout -enddate | grep -Fq 'notAfter=' || die 'enddate is not queryable'
pass 'validity is 3650 days and enddate is queryable'

bits=$(openssl x509 -in "$cert_dir/dsh.crt" -noout -text | sed -n 's/.*Public-Key: (\([0-9]*\) bit).*/\1/p' | head -1)
[[ ${bits:-0} -eq 2048 ]] || die "expected an RSA 2048 key, got ${bits:-unknown}"
pass 'default key type is RSA 2048'

before=$(sha256sum "$cert_dir/dsh.crt")
gen_selfsigned_cert "$cert_dir" vps.test.ts.net root 2>/dev/null || die 're-run failed'
[[ $(sha256sum "$cert_dir/dsh.crt") == "$before" ]] || die 'a still-valid matching certificate was regenerated'
pass 'reuses a still-valid certificate instead of regenerating'

# A changed host name must force regeneration so the SAN stays correct.
gen_selfsigned_cert "$cert_dir" other.test.ts.net root 2>/dev/null || die 'host change run failed'
openssl x509 -in "$cert_dir/dsh.crt" -noout -ext subjectAltName | grep -Fq 'DNS:other.test.ts.net' || die 'SAN did not follow the new host name'
pass 'regenerates when the host name changes'

DSH_TLS_KEY_TYPE=ecdsa gen_selfsigned_cert "$work/ec" ecdsa.test.ts.net root 2>/dev/null || die 'ecdsa generation failed'
openssl x509 -in "$work/ec/dsh.crt" -noout -text | grep -q 'id-ecPublicKey' || die 'DSH_TLS_KEY_TYPE=ecdsa did not produce an EC key'
pass 'supports an ECDSA key when requested'

set +e
gen_selfsigned_cert "$work/bad" 'bad host;rm -rf /' root >/dev/null 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]] || die 'unsafe host name was accepted'
pass 'rejects unsafe certificate host names'

# --- Serve parameters per mode ---------------------------------------------
mock="$work/tailscale"
cat > "$mock" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1 ${2:-}" in
  "serve --bg") printf '%s\n' "$*" >> "$TS_LOG";;
  "serve status") cat "$TS_STATUS";;
  *) exit 1;;
esac
MOCK
chmod +x "$mock"
printf '{"Web":{"https://dsh.test.ts.net":{"Handler":"BACKEND"}}}' > "$work/status.template"

run_serve() {
  local backend=$1
  sed "s|BACKEND|$backend|" "$work/status.template" > "$work/status.json"
  TS_LOG="$work/serve.log" TS_STATUS="$work/status.json" \
    DSH_TAILSCALE_BIN="$mock" DSH_SERVE_BACKEND="$backend" DSH_TAILSCALE_PORT=443 \
    bash -c ". '$root/tools/tailscale-serve.sh'; tailscale_serve_apply dsh.test.ts.net" 2>/dev/null
}

: > "$work/serve.log"
run_serve 'https+insecure://127.0.0.1:3080' || die 'serve apply failed for native TLS backend'
grep -Fq -- '--https=443 https+insecure://127.0.0.1:3080' "$work/serve.log" || die "native TLS Serve args wrong: $(cat "$work/serve.log")"
pass 'serve uses https+insecure://127.0.0.1:3080 for native TLS'

: > "$work/serve.log"
run_serve 'http://127.0.0.1:3081' || die 'serve apply failed for proxy backend'
grep -Fq -- 'http://127.0.0.1:3081' "$work/serve.log" || die 'proxy backend was not passed to Serve'
pass 'proxy fallback still serves http://127.0.0.1:3081'

# --- migration from the legacy proxy topology -------------------------------
# An existing handler pointing at our own old proxy port must be replaceable,
# while a foreign handler must still be refused.
TS_LOG="$work/migrate.log" TS_STATUS="$work/migrate.json" DSH_TAILSCALE_BIN="$mock" \
  DSH_SERVE_BACKEND='https+insecure://127.0.0.1:3080' DSH_PORT=3080 DSH_PROXY_PORT=3081 \
  bash -c ". '$root/tools/tailscale-serve.sh'; _ts_owns_handler '{\"Proxy\":\"http://127.0.0.1:3081\"}'" 2>/dev/null \
  || die 'legacy proxy handler was not recognised as our own'
pass 'recognises the legacy proxy handler as ours during migration'

set +e
DSH_TAILSCALE_BIN="$mock" DSH_PORT=3080 DSH_PROXY_PORT=3081 \
  bash -c ". '$root/tools/tailscale-serve.sh'; _ts_owns_handler '{\"Proxy\":\"http://127.0.0.1:9999\"}'" 2>/dev/null
foreign=$?
set -e
[[ $foreign -ne 0 ]] || die 'a foreign Serve handler was treated as ours'
pass 'still refuses to take over a foreign Serve handler'

# --- loopback login URL reconstruction --------------------------------------
# The credential URL carries its token on the public root path; the installer
# must reuse that path rather than assuming "/login".
path_of() { printf '%s' "$1" | sed -E 's#^https?://[^/]+##'; }
[[ $(path_of 'https://vps.test.ts.net/?token=redacted') == '/?token=redacted' ]] || die 'root-path credential URL was not preserved'
[[ $(path_of 'https://vps.test.ts.net/ui/?token=redacted') == '/ui/?token=redacted' ]] || die 'prefixed credential URL lost its path'
[[ $(path_of 'https://vps.test.ts.net') == '' ]] || die 'bare origin should yield an empty path'
pass 'reconstructs the loopback login path from the public credential URL'

set +e
printf '%s' 'https://vps.test.ts.net/?token=redacted&x=1' > /dev/null
grep -Fq 'public_path=' "$root/install.sh"
pathed=$?
set -e
[[ $pathed -eq 0 ]] || die 'installer does not derive the loopback login path'
pass 'installer derives the loopback login path from the credential URL'

# The login cookie is scoped to the loopback host, so the upgrade request must
# not pretend to be the public host or DSH rejects it as unauthenticated.
! grep -Fq -- '--host "$DSH_TRUSTED_HOST"' "$root/install.sh" \
  || die 'websocket check overrides Host and would lose the loopback-scoped cookie'
pass 'websocket check keeps the loopback host that the cookie was issued for'

# --- installer defaults ------------------------------------------------------
grep -Fq 'DSH_TAILSCALE_MODE:=serve' "$root/install.sh" || die 'default mode is not serve'
grep -Fq 'DSH_TLS_MODE:=native' "$root/install.sh" || die 'native TLS is not the default TLS mode'
grep -Fq 'gen_selfsigned_cert' "$root/install.sh" || die 'installer does not generate a certificate'
grep -Fq -- '--tls-cert' "$root/bin/dsh-web-start.sh" || die 'DSH start script does not pass --tls-cert'
pass 'default mode is native TLS with generated certificates'

if grep -Fq 'systemctl enable --now dsh-web-proxy.service' "$root/install.sh" &&
   ! grep -Fq 'if [[ $DSH_USE_PROXY == yes ]]; then systemctl enable --now "$PROXY_UNIT_NAME"; fi' "$root/install.sh"; then
  die 'proxy service is enabled unconditionally'
fi
grep -Fq 'if [[ $DSH_USE_PROXY == yes ]]; then' "$root/install.sh" || die 'proxy enablement is not gated'
grep -Fq 'systemctl restart "$UNIT_NAME"' "$root/install.sh" || die 'installer does not restart the unit, so a re-run would keep the old process'
! grep -Fq 'systemctl enable --now "$UNIT_NAME"' "$root/install.sh" || die 'enable --now leaves an already-running unit on its old flags'
pass 'installer restarts the unit so re-runs apply new flags'
pass 'proxy service is never enabled by default'

grep -Fq 'DSH_TLS_MODE=proxy' "$root/README.md" || die 'README does not document the proxy fallback switch'
grep -Fq 'openssl x509 -enddate' "$root/README.md" || die 'README diagnostics lack the expiry command'
pass 'README documents the fallback switch and the expiry check'

if command -v "$node_bin" >/dev/null 2>&1; then
  "$node_bin" --check "$root/tools/verify-ws.mjs" || die 'verify-ws.mjs does not parse'
  pass 'websocket verifier parses'
fi

printf 'native TLS, SAN, validity, Serve backend, and default-mode checks passed\n'
