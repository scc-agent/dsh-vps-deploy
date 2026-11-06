#!/usr/bin/env bash
set -Eeuo pipefail
exec "${DSH_NODE:?DSH_NODE is not configured}" "${DSH_ENTRYPOINT:?DSH_ENTRYPOINT is not configured}" "$@"
