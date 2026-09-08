#!/usr/bin/env bash
# Run every test suite. CI runs exactly this.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
for t in test-static.sh test-runner.sh test-install.sh test-upgrade.sh; do
  echo
  echo "════════════════════════════════════════════ $t"
  "${BASH_BIN:-bash}" "$HERE/$t" || fail=1
done
echo
if [ "$fail" = 0 ]; then echo "ALL SUITES PASSED"; else echo "SOME SUITES FAILED"; fi
exit $fail
