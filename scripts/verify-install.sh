#!/usr/bin/env bash
# Thin wrapper: verify whatever is installed on this machine.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/install.sh" --verify "$@"
