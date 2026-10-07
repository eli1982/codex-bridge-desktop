#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")" && pwd)"
exec "$repo/scripts/install-unix.sh" "$@"
