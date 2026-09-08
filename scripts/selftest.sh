#!/usr/bin/env bash
# Run the whole test suite (what CI runs).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/tests/run-all.sh" "$@"
