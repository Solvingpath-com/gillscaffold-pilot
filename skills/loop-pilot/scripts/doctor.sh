#!/usr/bin/env bash
# loop-pilot doctor — is this machine able to fly an unattended loop?
# Usage:
#   doctor.sh                  read-only diagnosis (no agent is ever invoked with a prompt)
#   doctor.sh --smoke claude   ALSO run one real, tiny phase with that agent (spends tokens)
#
# The smoke test builds a throwaway git repo in a temp dir, scaffolds a one-phase feature
# whose whole job is to create a file, and flies it with the real runner. It proves the
# adapter, the permissions, the gate and QA.md end-to-end. Nothing outside the temp dir is touched.
set -uo pipefail
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SDIR/.." && pwd)"
TPL="$SKILL_DIR/references/loop-template.md"
ok=0; warn=0; bad=0
good() { echo "  ✓ $*"; ok=$((ok+1)); }
meh()  { echo "  ⚠ $*"; warn=$((warn+1)); }
err()  { echo "  ✗ $*"; bad=$((bad+1)); }

echo "loop-pilot doctor"
echo
echo "Shell and tools:"
bv="${BASH_VERSION:-?}"
case "$bv" in 3.*) meh "bash $bv (macOS stock) — supported; the runner is written for it";; *) good "bash $bv";; esac
command -v python3 >/dev/null 2>&1 && good "python3 $(python3 --version 2>&1 | awk '{print $2}')" || err "python3 missing — the runner uses it for safe status.md edits"
command -v git >/dev/null 2>&1 && good "git $(git --version | awk '{print $3}')" || meh "git missing — features usually live in git repos"
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then good "coreutils timeout available (watchdog)"
else meh "no coreutils timeout — the runner falls back to a bash watchdog (macOS: brew install coreutils)"; fi
command -v curl >/dev/null 2>&1 && good "curl available (installer/updates)" || meh "curl missing — updates must be done by hand"

echo
echo "Skills:"
[ -f "$TPL" ] && good "runner template: $TPL (v$(awk '/^```bash/{f=1;next} f&&/^# *template-version:/{gsub(/[^0-9]/,"",$0);print;exit}' "$TPL"))" || err "runner template missing at $TPL"
GS="$SKILL_DIR/../grillscaffold/references/loop-template.md"
if [ -f "$GS" ]; then
  if cmp -s "$GS" "$TPL"; then good "grillscaffold's template copy is byte-identical"
  else meh "grillscaffold's template copy DIFFERS from loop-pilot's — reinstall the bundle so both skills scaffold the same runner"; fi
else meh "grillscaffold skill not installed next to loop-pilot (planning half of the pair)"; fi
for f in "$SKILL_DIR/release-manifest.json" "$SKILL_DIR/../grillscaffold/release-manifest.json"; do
  [ -f "$f" ] && { echo "  · $(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print("bundle %s (grillscaffold %s, loop-pilot %s, runner template v%s)"%(d["release"],d["grillscaffold"],d["loopPilot"],d["runnerTemplate"]))' "$f" 2>/dev/null || echo "manifest unreadable: $f")"; break; }
done

echo
echo "Agents:"
if [ -x "$SDIR/agents.sh" ]; then "$SDIR/agents.sh" | sed 's/^/  /'; else err "agents.sh missing"; fi

echo
echo "Features known to this machine:"
if [ -x "$SDIR/scan.sh" ]; then "$SDIR/scan.sh" 2>/dev/null | sed 's/^/  /' | head -30; else meh "scan.sh missing"; fi

# ── optional smoke test ──────────────────────────────────────────────────────
SMOKE=""
[ "${1:-}" = "--smoke" ] && SMOKE="${2:?usage: doctor.sh --smoke <claude|codex|kimi>}"
if [ -n "$SMOKE" ]; then
  echo
  echo "SMOKE TEST with $SMOKE — this spends real tokens. One phase, in a temp repo."
  if ! "$SDIR/agents.sh" "$SMOKE" >/dev/null 2>&1; then echo "  ✗ $SMOKE is not installed/authenticated — skipping"; exit 1; fi
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/lp-smoke.XXXXXX")"
  REPO="$TMP/smoke repo"; FEAT=smoke; FD="$REPO/docs/features/$FEAT"
  mkdir -p "$FD"; ( cd "$REPO" && git init -q . && git config user.email d@d && git config user.name d && echo smoke > README.md && git add -A && git commit -qm init )
  cat > "$FD/plan.md" <<EOF
# smoke — Plan
Repos touched: \`$REPO\` (primary).
## Concurrency and waves
| Wave | Run together |
|---|---|
| 1 | P1 |
EOF
  cat > "$FD/prompts.md" <<EOF
# smoke — Session Prompts

## Order and parallelism

| Wave | Run together |
|---|---|
| 1 | P1 |

## P1 — write one file

> GATE: test -f smoke-ok.txt

\`\`\`
Create a file named smoke-ok.txt in the repo root containing the single word: ok
Then edit docs/features/smoke/status.md and set the P1 row's State cell to done.
Do nothing else. Do not commit.
\`\`\`

## AUDIT — did it work?

\`\`\`
Audit the smoke feature: confirm smoke-ok.txt exists and says ok.
Write docs/features/smoke/audit-\$(date +%Y-%m-%d).md with one line. READ-ONLY otherwise.
\`\`\`
EOF
  cat > "$FD/status.md" <<EOF
# smoke — Status

## Phase table

| Phase | State | Depends on | Date | Gates | Notes |
|---|---|---|---|---|---|
| P1 | todo | — | — | — | — |

## Progress log

EOF
  python3 "$SDIR/render-loop.py" --template "$TPL" --feature "$FEAT" --primary "$REPO" --stamp "doctor smoke" --out "$FD/loop.sh"
  chmod +x "$FD/loop.sh"
  ( cd "$FD" && AGENT="$SMOKE" MAX_PARALLEL=1 PHASE_TIMEOUT_SEC=600 ./loop.sh ) 2>&1 | sed 's/^/  | /'
  echo
  if [ -f "$REPO/smoke-ok.txt" ] && grep -q '^result=COMPLETE' "$FD/.runinfo" 2>/dev/null; then
    echo "  ✓ SMOKE PASSED — $SMOKE wrote the file, the loop ran the gate, QA.md and the audit exist."
    echo "    artifacts: $FD/QA.md"
  else
    echo "  ✗ SMOKE FAILED — inspect $FD (logs/, status.md, QA.md) before flying a real feature."
    exit 1
  fi
  echo "  temp dir kept for inspection: $TMP"
fi

echo
echo "Summary: $ok ok, $warn warning(s), $bad error(s)"
[ "$bad" -eq 0 ]
