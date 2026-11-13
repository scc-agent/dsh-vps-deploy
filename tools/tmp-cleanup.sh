#!/usr/bin/env bash
# Remove every temporary path the installer created, on any exit path.
#
# Why this is a module instead of inline traps: bash keeps exactly one EXIT
# trap, so each new `trap ... EXIT` silently replaces the previous one and
# `trap - EXIT` removes it outright. The installer used to set a trap for the
# npm tarball and then overwrite it twice, so a successful run left the tarball
# behind in /tmp. Tracking paths in one list and installing a single trap keeps
# every path covered no matter how many are added later.
set -Eeuo pipefail

INSTALL_TMP_PATHS=()

# tmp_track PATH — remember a path for removal at exit.
tmp_track() {
  INSTALL_TMP_PATHS+=("$1")
}

# tmp_cleanup — remove everything tracked so far. Safe to call directly.
tmp_cleanup() {
  local path
  # Guard the empty case: bash < 4.4 treats "${arr[@]}" as an unbound
  # variable under `set -u`, which would make the cleanup trap itself fail.
  for path in ${INSTALL_TMP_PATHS[@]+"${INSTALL_TMP_PATHS[@]}"}; do
    [[ -n $path ]] && rm -rf "$path"
  done
  INSTALL_TMP_PATHS=()
}

# tmp_install_trap — install the single EXIT trap. Call once, early.
tmp_install_trap() {
  trap tmp_cleanup EXIT
}
