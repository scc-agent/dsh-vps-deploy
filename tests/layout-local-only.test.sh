#!/usr/bin/env bash
# Offline coverage for the split install layout and the local-only self-check.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass() { printf 'ok - %s\n' "$1"; }
die() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

# --- split layout -----------------------------------------------------------
grep -Fq ': "${DSH_APP_ROOT:=/opt/dsh}"' "$root/install.sh" || die 'program root is not /opt/dsh by default'
grep -Fq 'install -d -o root -g root -m 0755 "$DSH_APP_ROOT"' "$root/install.sh" || die 'program root is not created root-owned'
grep -Fq 'app_stage="$DSH_APP_ROOT/.app.stage.$$"' "$root/install.sh" || die 'npm still stages inside the data dir'
! grep -Fq 'DSH_APP_DIR="$DSH_HOME/app"' "$root/install.sh" || die 'app is still installed under DSH_HOME'
grep -Fq 'chown -R root:root "$DSH_APP_DIR"' "$root/install.sh" || die 'installed program tree is not forced to root ownership'
grep -Fq 'DSH_WORKSPACE="$DSH_HOME/workspace"' "$root/install.sh" || die 'workspace is not $DSH_HOME/workspace'
grep -Fq 'install -d -o "$DSH_USER" -g "$DSH_GROUP" -m 0750 "$DSH_WORKSPACE"' "$root/install.sh" \
  || die 'workspace is not created for the service user'
grep -Fq 'legacy_app="$DSH_HOME/app"' "$root/install.sh" || die 'the legacy program tree is never retired'
pass 'program, data and workspace directories are separated, legacy tree retired'

for unit in "$root/systemd/dsh-web.service.in" "$root/systemd/dsh-web-proxy.service.in"; do
  grep -Fq 'WorkingDirectory=@DSH_WORKSPACE@' "$unit" || die "$(basename "$unit") does not run in the workspace"
  grep -Fq 'ReadWritePaths=@DSH_HOME@' "$unit" || die "$(basename "$unit") lost its writable data path"
done
grep -Fq 'MemoryMax=768M' "$root/systemd/dsh-web.service.in" || die 'MemoryMax regression'
grep -Fq 'NoNewPrivileges=true' "$root/systemd/dsh-web.service.in" || die 'NoNewPrivileges regression'
grep -Fq 'unit_template=${unit_template//@DSH_WORKSPACE@/$DSH_WORKSPACE}' "$root/install.sh" \
  || die 'installer does not template the workspace path into the unit'
pass 'systemd units run in the workspace without loosening hardening'

# Rendering the unit must produce a workspace WorkingDirectory and keep the
# app directory out of the writable set.
unit_template=$(<"$root/systemd/dsh-web.service.in")
fake_home=/var/lib/dsh
fake_workspace=/var/lib/dsh/workspace
fake_app=/opt/dsh/app
unit_template=${unit_template//@MARKER@/marker}
unit_template=${unit_template//@DSH_USER@/dsh}
unit_template=${unit_template//@DSH_HOME@/$fake_home}
unit_template=${unit_template//@DSH_WORKSPACE@/$fake_workspace}
unit_template=${unit_template//@DSH_APP_DIR@/$fake_app}
printf '%s\n' "$unit_template" > "$work/unit"
grep -Fqx 'WorkingDirectory=/var/lib/dsh/workspace' "$work/unit" || die 'rendered unit does not use the workspace'
grep -Fqx 'ReadWritePaths=/var/lib/dsh' "$work/unit" || die 'rendered unit writable set is wrong'
! grep -Fq '/opt/dsh' <(grep -E '^(ReadWritePaths|WorkingDirectory)=' "$work/unit") \
  || die 'rendered unit exposes the program root to the service'
pass 'rendered unit keeps the program root out of reach'

# --- local-only self-check --------------------------------------------------
source "$root/tools/probe-url.sh"

[[ $(dsh_probe_url local-only 'https://vps-jp.tail21c504.ts.net:3082/' 3080 no) == 'http://127.0.0.1:3080/' ]] \
  || die 'local-only probe does not fall back to loopback'
[[ $(dsh_probe_url local-only 'https://vps-jp.tail21c504.ts.net:3082/' 3080 yes) == 'https://127.0.0.1:3080/' ]] \
  || die 'local-only probe ignores native TLS'
[[ $(dsh_probe_url serve 'https://dsh.test.ts.net/' 3080 yes) == 'https://dsh.test.ts.net/' ]] \
  || die 'serve mode should probe the public entrypoint'
[[ $(dsh_probe_url serve-proxy 'https://dsh.test.ts.net/' 3080 no) == 'https://dsh.test.ts.net/' ]] \
  || die 'serve-proxy mode should probe the public entrypoint'
pass 'probe URL follows the mode, not the advertised URL'

[[ $(dsh_probe_insecure local-only yes) == yes ]] || die 'native TLS loopback probe must allow the self-signed cert'
[[ $(dsh_probe_insecure local-only no) == no ]] || die 'plain local-only probe must not disable verification'
[[ $(dsh_probe_insecure serve yes) == no ]] || die 'the public probe must verify certificates'
pass 'certificate relaxation is limited to the loopback probe'

[[ $(ensure_trusted_loopback 'vps-jp.tail21c504.ts.net') == 'vps-jp.tail21c504.ts.net 127.0.0.1' ]] \
  || die 'loopback was not added to the trusted hosts'
[[ $(ensure_trusted_loopback 'a.test 127.0.0.1') == 'a.test 127.0.0.1' ]] || die 'loopback was duplicated'
[[ $(ensure_trusted_loopback '127.0.0.1') == '127.0.0.1' ]] || die 'loopback-only trusted host was mangled'
pass 'trusted hosts gain 127.0.0.1 exactly once'

# The installer must probe the derived URL, never the advertised one.
grep -Fq 'verify_unauthenticated_entrypoint "$probe_url" 401' "$root/install.sh" \
  || die 'the 401 check still uses the advertised URL'
grep -Fq 'verify_login_redirect "$login_url" 303' "$root/install.sh" || die 'the 303 check was removed'
grep -Fq 'ws_url="${probe_url%/}${DSH_WS_PATH}"' "$root/install.sh" || die 'the WS check still uses the advertised URL'
grep -Fq 'dsh_probe_url "$DSH_TAILSCALE_MODE" "$DSH_PUBLIC_URL" "$DSH_PORT" "$DSH_NATIVE_TLS"' "$root/install.sh" \
  || die 'the installer does not derive a probe URL'
grep -Fq 'source "$SCRIPT_DIR/tools/probe-url.sh"' "$root/install.sh" \
  || die 'the installer never sources probe-url.sh, so dsh_probe_url is undefined'
grep -Fq '$SCRIPT_DIR/tools/probe-url.sh' "$root/install.sh" \
  || die 'probe-url.sh is missing from the installer resource checks'
grep -Fq 'DSH_TRUSTED_HOST=$(ensure_trusted_loopback "$DSH_TRUSTED_HOST")' "$root/install.sh" \
  || die 'local-only does not trust the loopback authority'
grep -Fq 'DSH_PUBLIC_URL=%q' "$root/install.sh" || die 'the advertised URL is no longer written to the env file'
pass 'the self-check probes loopback while DSH keeps the real public URL'

# --- end to end with a mock curl -------------------------------------------
# A local-only install whose public URL is a non-loopback name must pass its
# 401/303/Cookie/WS checks against the loopback probe.
cat > "$work/curl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
header='' write_out='' url=''
while (($#)); do
  case "$1" in
    --dump-header|-D) header=$2; shift 2;;
    --write-out|-w) write_out=$2; shift 2;;
    --max-time|-c|-b) shift 2;;
    --insecure|--silent|--show-error) shift;;
    --output) shift 2;;
    *) url=$1; shift;;
  esac
done
case "$url" in
  http://127.0.0.1:*|https://127.0.0.1:*) ;;
  *) printf 'mock curl: unexpected probe host: %s\n' "$url" >&2; exit 7;;
esac
[[ -z ${CURL_LOG:-} ]] || printf '%s\n' "$url" >> "$CURL_LOG"
if [[ -n $header ]]; then
  printf 'Set-Cookie: session=redacted; Secure; HttpOnly; SameSite=Strict\r\n' > "$header"
fi
case "$url" in
  *credential*) printf '%s' 303;;
  *) printf '%s' 401;;
esac
MOCK
chmod +x "$work/curl"
cat > "$work/ws.mjs" <<'MOCK'
process.exit(process.argv.includes('--insecure') ? 0 : 1);
MOCK

module_probe=$(dsh_probe_url local-only 'https://vps-jp.tail21c504.ts.net:3082/' 3080 no)
[[ $module_probe == 'http://127.0.0.1:3080/' ]] || die 'probe mismatch'
set +e
CURL_LOG="$work/curl.log" PATH="$work:$PATH" bash -c "
  source '$root/tools/verify-auth-cookie.sh'
  set -e
  verify_unauthenticated_entrypoint '$module_probe' 401 || exit 1
  verify_login_redirect 'http://127.0.0.1:3080/login?credential=redacted' 303 || exit 1
  verify_authenticated_entrypoint 'http://127.0.0.1:3080/login?credential=redacted' no || exit 1
" >/dev/null 2>"$work/e2e.err"
actual=$?
set -e
[[ $actual -eq 0 ]] || { cat "$work/e2e.err" >&2; die 'local-only loopback checks rejected a healthy service'; }
[[ -s $work/curl.log ]] || die 'the checks never reached curl'
! grep -vq '^http://127\.0\.0\.1:3080' "$work/curl.log" || die 'the checks did not stay on the loopback probe'
pass 'local-only 401/303/cookie checks pass against the loopback probe'

# The same mock must fail if the advertised non-loopback URL were probed.
set +e
CURL_LOG='' PATH="$work:$PATH" bash -c "
  source '$root/tools/verify-auth-cookie.sh'
  verify_unauthenticated_entrypoint 'https://vps-jp.tail21c504.ts.net:3082/' 401
" >/dev/null 2>&1
actual=$?
set -e
[[ $actual -ne 0 ]] || die 'probe of an unreachable public URL unexpectedly succeeded'
pass 'probing the advertised URL in local-only mode is what used to fail'

printf 'layout split and local-only self-check checks passed\n'
