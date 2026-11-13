#!/usr/bin/env bash
# Validation-only guards, run before the installer changes anything on the host.
#
# They live in their own file so the tests can exercise them directly instead of
# running install.sh, which would create users and directories on the test
# machine. Every function here reads, decides, and fails; none of them writes.
set -Eeuo pipefail

# require_safe_dsh_home DSH_HOME
# The unit sets ProtectHome=true, which makes /home, /root and /run/user
# unreadable to the service. A data directory under any of them installs cleanly
# and then fails at startup with an inaccessible home, so refuse it up front.
require_safe_dsh_home() {
  local home=$1
  case "$home/" in
    /home/*|/root/*|/run/user/*)
      printf 'error: DSH_HOME must not be under /home, /root or /run/user: the unit sets ProtectHome=true, which hides those paths from the service (got %s)\n' "$home" >&2
      return 1
      ;;
  esac
}

# require_safe_app_root DSH_APP_ROOT
# `install -d` re-applies owner and mode to a directory that already exists, so
# pointing DSH_APP_ROOT at someone else's tree would silently re-own it and widen
# its permissions. An existing tree must already be root-owned and not writable
# by group or other; anything else is refused rather than rewritten.
require_safe_app_root() {
  local app_root=$1 owner mode
  if [[ -e $app_root && ! -d $app_root ]]; then
    printf 'error: DSH_APP_ROOT exists and is not a directory: %s\n' "$app_root" >&2
    return 1
  fi
  [[ -d $app_root ]] || return 0

  owner=$(stat -c '%U' "$app_root") || {
    printf 'error: cannot read the owner of DSH_APP_ROOT: %s\n' "$app_root" >&2
    return 1
  }
  mode=$(stat -c '%a' "$app_root") || {
    printf 'error: cannot read the mode of DSH_APP_ROOT: %s\n' "$app_root" >&2
    return 1
  }
  if [[ $owner != root ]]; then
    printf 'error: DSH_APP_ROOT is owned by %s, not root; refusing to take it over (move it aside or set DSH_APP_ROOT)\n' "$owner" >&2
    return 1
  fi
  # Group- or world-writable: refuse instead of quietly tightening, because the
  # directory is not ours and its permissions may be load-bearing for whoever
  # created it.
  if (( (8#$mode & 8#022) != 0 )); then
    printf 'error: DSH_APP_ROOT has mode %s (group- or world-writable); refusing to reuse it\n' "$mode" >&2
    return 1
  fi
}

# require_safe_tls_dir DSH_TLS_DIR
# Same ProtectHome reasoning as DSH_HOME: the service must read the certificate
# and key at runtime.
require_safe_tls_dir() {
  local tls_dir=$1
  case "$tls_dir/" in
    /home/*|/root/*|/run/user/*)
      printf 'error: DSH_TLS_DIR must not be under /home, /root or /run/user: the unit sets ProtectHome=true, which hides those paths from the service (got %s)\n' "$tls_dir" >&2
      return 1
      ;;
  esac
}
