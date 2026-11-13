#!/usr/bin/env bash
# Guards added after review: group/user confusion, ProtectHome paths, temp leaks.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$*"; }

# --- 1. The unit and the env file must use the resolved group --------------
grep -Fq 'Group=@DSH_GROUP@' "$root/systemd/dsh-web.service.in" \
  || fail 'unit template does not use @DSH_GROUP@ for Group='
! grep -Fq 'Group=@DSH_USER@' "$root/systemd/dsh-web.service.in" \
  || fail 'unit template still sets Group= to the user name'
grep -Fq 'unit_template=${unit_template//@DSH_GROUP@/$DSH_GROUP}' "$root/install.sh" \
  || fail 'install.sh does not substitute @DSH_GROUP@'
grep -Fq 'chown root:"$DSH_GROUP" "$env_tmp"' "$root/install.sh" \
  || fail 'env file is still chowned to the user name as a group'
! grep -Fq 'chown root:"$DSH_USER"' "$root/install.sh" \
  || fail 'install.sh still treats the user name as a group'
ok 'unit and env file use the resolved group name'

# --- 2. The certificate helper resolves a GROUP, not a user ----------------
# Pick a group that exists without a user of the same name: that is exactly the
# shape the old `id -gn "$group"` lookup got wrong, because it asked for a USER.
probe_group=''
for candidate in nogroup bin daemon adm sys; do
  if getent group "$candidate" >/dev/null 2>&1 && ! getent passwd "$candidate" >/dev/null 2>&1; then
    probe_group=$candidate
    break
  fi
done
[[ -n $probe_group ]] || fail 'no group-without-same-named-user found to test against'

DSH_TLS_DAYS=1 bash -c ". '$root/tools/gen-selfsigned-cert.sh'; gen_selfsigned_cert '$tmp/tls' 'dsh.test.ts.net' '$probe_group'" \
  || fail "gen_selfsigned_cert rejected the group name $probe_group"
[[ -r $tmp/tls/dsh.crt && -r $tmp/tls/dsh.key ]] || fail 'certificate files were not created'
openssl x509 -in "$tmp/tls/dsh.crt" -noout -checkhost dsh.test.ts.net >/dev/null 2>&1 \
  || fail 'generated certificate does not cover the requested host'
if [[ $(id -u) -eq 0 ]]; then
  [[ $(stat -c '%G' "$tmp/tls/dsh.key") == "$probe_group" ]] \
    || fail "key group is $(stat -c '%G' "$tmp/tls/dsh.key"), expected $probe_group"
fi
ok "certificate helper accepts a group name that is not a user name ($probe_group)"

# A name that is neither a group nor a user must be refused, not silently root.
set +e
DSH_TLS_DAYS=1 bash -c ". '$root/tools/gen-selfsigned-cert.sh'; gen_selfsigned_cert '$tmp/tls2' 'dsh.test.ts.net' 'no-such-group-xyz'" >/dev/null 2>&1
actual=$?
set -e
[[ $actual -ne 0 ]] || fail 'an unknown group name was accepted'
ok 'certificate helper refuses an unknown group name'

# --- 3. DSH_HOME under ProtectHome paths must be refused -------------------
# Dry run: the suite must pass unprivileged (see README), and a dry run still
# reaches every input guard before it stops.
for bad_home in /home/dsh /root/dsh /run/user/0/dsh; do
  set +e
  DSH_DRY_RUN=yes DSH_HOME="$bad_home" bash "$root/install.sh" >/dev/null 2>"$tmp/err"
  actual=$?
  set -e
  [[ $actual -ne 0 ]] || fail "DSH_HOME=$bad_home was accepted although ProtectHome=true hides it"
  grep -Fq 'ProtectHome' "$tmp/err" || fail "DSH_HOME=$bad_home failed without explaining ProtectHome"
done
ok 'DSH_HOME under /home, /root or /run/user is refused with a reason'

# The TLS directory is read at runtime by the service too, so the same
# ProtectHome paths must be refused there.
set +e
DSH_DRY_RUN=yes DSH_TLS_DIR=/root/tls bash "$root/install.sh" >/dev/null 2>"$tmp/err"
actual=$?
set -e
[[ $actual -ne 0 ]] || fail 'DSH_TLS_DIR under /root was accepted although ProtectHome=true hides it'
grep -Fq 'ProtectHome' "$tmp/err" || fail 'DSH_TLS_DIR=/root/tls failed without explaining ProtectHome'
ok 'DSH_TLS_DIR under a ProtectHome path is refused with a reason'

DSH_DRY_RUN=yes DSH_HOME=/var/lib/dsh bash "$root/install.sh" >/dev/null \
  || fail 'a normal DSH_HOME was rejected'
ok 'a normal DSH_HOME still passes'

# --- 4. Existing program roots are not silently re-owned or widened --------
# `install -d` rewrites owner and mode on an existing directory. A pre-existing
# tree that is not ours must be refused instead of being taken over.
if [[ $(id -u) -eq 0 ]]; then
  foreign="$tmp/foreign-root"
  install -d -o nobody -g nogroup -m 0700 "$foreign" 2>/dev/null || install -d -m 0700 "$foreign"
  chown nobody "$foreign" 2>/dev/null || true
  set +e
  DSH_DRY_RUN=yes DSH_APP_ROOT="$foreign" DSH_HOME=/var/lib/dsh bash "$root/install.sh" >/dev/null 2>"$tmp/err2"
  actual=$?
  set -e
  [[ $actual -ne 0 ]] || fail 'a DSH_APP_ROOT owned by another user was taken over'
  grep -Fq 'DSH_APP_ROOT' "$tmp/err2" || fail 'the foreign DSH_APP_ROOT failure did not name the variable'
  [[ $(stat -c '%U' "$foreign") == nobody ]] || fail 'the foreign DSH_APP_ROOT was re-owned'
  [[ $(stat -c '%a' "$foreign") == 700 ]] || fail 'the foreign DSH_APP_ROOT mode was widened'
  ok 'an existing program root owned by someone else is refused and left untouched'

  # A root-owned but group/world-writable tree is still not ours to reuse.
  loose="$tmp/loose-root"
  install -d -o root -g root -m 0777 "$loose"
  set +e
  DSH_DRY_RUN=yes DSH_APP_ROOT="$loose" bash "$root/install.sh" >/dev/null 2>"$tmp/err3"
  actual=$?
  set -e
  [[ $actual -ne 0 ]] || fail 'a world-writable DSH_APP_ROOT was accepted'
  [[ $(stat -c '%a' "$loose") == 777 ]] || fail 'the world-writable DSH_APP_ROOT was modified instead of refused'
  ok 'a group- or world-writable program root is refused and left untouched'

  # The normal case must still pass.
  tight="$tmp/tight-root"
  install -d -o root -g root -m 0755 "$tight"
  DSH_DRY_RUN=yes DSH_APP_ROOT="$tight" bash "$root/install.sh" >/dev/null \
    || fail 'a normal root-owned 0755 DSH_APP_ROOT was rejected'
  ok 'a normal program root still passes'
fi

# --- 5. Temporary files are cleaned on every exit path ---------------------
leak_test=$(mktemp -d)
bash -c '
set -Eeuo pipefail
source "'"$root"'/tools/tmp-cleanup.sh"
tmp_install_trap
mkdir -p "$1/keepme"
touch "$1/keepme/file"
tmp_track "$1/keepme"
exit 0
' _ "$leak_test"
[[ ! -e $leak_test/keepme ]] || fail 'tracked temporary path survived a successful exit'
rm -rf "$leak_test"

leak_test=$(mktemp -d)
set +e
bash -c '
set -Eeuo pipefail
source "'"$root"'/tools/tmp-cleanup.sh"
tmp_install_trap
mkdir -p "$1/keepme"
tmp_track "$1/keepme"
false
' _ "$leak_test" >/dev/null 2>&1
set -e
[[ ! -e $leak_test/keepme ]] || fail 'tracked temporary path survived a failing exit'
rm -rf "$leak_test"

# Several tracked paths must all be removed: the old installer replaced its EXIT
# trap twice, so only the last one ever ran.
leak_test=$(mktemp -d)
bash -c '
set -Eeuo pipefail
source "'"$root"'/tools/tmp-cleanup.sh"
tmp_install_trap
for n in 1 2 3; do mkdir -p "$1/p$n"; tmp_track "$1/p$n"; done
' _ "$leak_test"
[[ -z $(ls -A "$leak_test") ]] || fail 'not every tracked temporary path was removed'
rm -rf "$leak_test"

# The installer must never clear the EXIT trap after installing the cleanup one,
# and must not install competing traps of its own.
! grep -Eq '^[[:space:]]*trap[[:space:]]+-[[:space:]]+EXIT' "$root/install.sh" \
  || fail 'install.sh still clears its EXIT trap, which drops the temp cleanup'
grep -Fq 'tmp_install_trap' "$root/install.sh" || fail 'install.sh never installs the cleanup trap'
! grep -Eq "^[[:space:]]*trap[[:space:]]+['\"]?(rm|cleanup)" "$root/install.sh" \
  || fail 'install.sh still installs a competing EXIT trap'
ok 'temporary paths are cleaned on success and on failure'

printf 'group, ProtectHome, program-root and temp-cleanup guards passed\n'
