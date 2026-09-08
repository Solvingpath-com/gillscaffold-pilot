#!/usr/bin/env bash
# Shared helpers for the test suite. Source this; do not run it.
# Every test runs in a temporary HOME and a temporary workspace so the real machine is never touched.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
BASH_BIN="${BASH_BIN:-bash}"          # CI sets BASH_BIN=/bin/bash on macOS to force bash 3.2
FIXTURES="$TESTS_DIR/fixtures"
PASS=0; FAIL=0; CURRENT=""

t_begin() { CURRENT="$1"; printf '  · %s ... ' "$1"; }
t_ok()    { PASS=$((PASS+1)); echo "ok"; }
t_fail()  { FAIL=$((FAIL+1)); echo "FAIL"; echo "      $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      | /' | head -40; return 1; }
assert()  { if eval "$1"; then t_ok; else t_fail "assertion failed: $1" "${2:-}"; fi; }
assert_grep() { if grep -qE -- "$1" "$2" 2>/dev/null; then t_ok; else t_fail "expected /$1/ in $2" "$(cat "$2" 2>/dev/null | tail -30)"; fi; }
assert_not_grep() { if grep -qE -- "$1" "$2" 2>/dev/null; then t_fail "did NOT expect /$1/ in $2" "$(grep -nE -- "$1" "$2")"; else t_ok; fi; }
t_summary() { echo; echo "$(basename "$0"): $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; }

# fresh temp HOME + workspace; paths deliberately contain a space and an apostrophe
mk_sandbox() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/lp-test.XXXXXX")"
  export HOME="$SANDBOX/home dir"; mkdir -p "$HOME"
  export LOOP_PILOT_STATE="$HOME/.loop-pilot"
  export FAKE_AGENT_LOG_DIR="$SANDBOX/agent-log"; mkdir -p "$FAKE_AGENT_LOG_DIR"
  export FAKE_AGENT_SCRIPT="$SANDBOX/agent-script"; : > "$FAKE_AGENT_SCRIPT"
  export LOOP_PILOT_NO_DASHBOARD=1
  unset LOOP_PILOT_NESTED
  # fake agents on PATH
  mkdir -p "$SANDBOX/bin"
  for a in claude codex kimi; do cp "$FIXTURES/bin/fake-agent" "$SANDBOX/bin/$a"; chmod +x "$SANDBOX/bin/$a"; done
  export PATH="$SANDBOX/bin:$PATH"
}
rm_sandbox() { [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"; }

# make_repo <path>  — a git repo with one commit
make_repo() { mkdir -p "$1"; ( cd "$1" && git init -q . && git config user.email t@t && git config user.name t && echo hi > README.md && git add . && git commit -qm init ) ; }

# make_feature <primary-repo> <feature> [phases-spec]
#   phases-spec: lines "P1|—|" "P2|P1|GATE:cmd" "P3|P2|HUMAN-ONLY:reason" "P4|P2|QA:step;OWNER:item"
# writes plan.md, prompts.md (with wave table), status.md. Does NOT write loop.sh.
make_feature() {
  local repo="$1" feat="$2" spec="${3:-}" fdir line ph dep extra
  fdir="$repo/docs/features/$feat"; mkdir -p "$fdir"
  [ -z "$spec" ] && spec=$'P1|—|\nP2|P1|\nP3|P2|'
  {
    echo "# $feat — Plan"; echo; echo "Repos touched: $repo (primary)."; echo; echo "## Phase breakdown"
    printf '%s\n' "$spec" | while IFS='|' read -r ph dep extra; do echo "### $ph — phase $ph"; echo "- **Depends on:** ${dep:-—}"; done
    echo; echo "## Concurrency and waves"; echo; echo "| Wave | Run together |"; echo "|---|---|"
  } > "$fdir/plan.md"
  {
    echo "# $feat — Session Prompts"; echo
    echo "## Repos"; echo; echo "| Short name | Path |"; echo "|---|---|"; echo "| primary | \`$repo\` |"
    for extra in "${EXTRA_REPO_LIST[@]:-}"; do [ -n "$extra" ] && echo "| extra | \`$extra\` |"; done
    echo; echo "## Order and parallelism"; echo; echo "| Wave | Run together |"; echo "|---|---|"
    if [ -n "${WAVES:-}" ]; then printf '%s\n' "$WAVES"; fi
    echo
    printf '%s\n' "$spec" | while IFS='|' read -r ph dep extra; do
      echo "## $ph — phase $ph"; echo
      if [ -n "$extra" ]; then printf '%s\n' "$extra" | tr ';' '\n' | while IFS= read -r l; do [ -n "$l" ] && echo "> $l"; done; echo; fi
      echo '```'; echo "Read plan.md. Execute phase $ph in the primary repo. Set the $ph row in docs/features/$feat/status.md to in-progress before starting."
      echo "Multi-line body with \"quotes\", 'apostrophes', \$dollars, \`backticks\` and a trailing tab	."; echo '```'; echo
    done
    echo "## AUDIT — did the plan actually get followed?"; echo; echo '```'; echo "Audit the $feat work. READ-ONLY. Write docs/features/$feat/audit-<today>.md"; echo '```'
  } > "$fdir/prompts.md"
  {
    echo "# $feat — Status"; echo; echo "## Phase table"; echo; echo "| Phase | State | Depends on | Date | Gates | Notes |"; echo "|---|---|---|---|---|---|"
    printf '%s\n' "$spec" | while IFS='|' read -r ph dep extra; do echo "| $ph | todo | ${dep:-—} | — | — | — |"; done
    echo; echo "## Progress log"; echo; echo "## Deferred"; echo
  } > "$fdir/status.md"
  EXTRA_REPO_LIST=(); WAVES=""      # one-shot: never leak into the next fixture
}

# render_loop <fdir> <feature> <primary> [extra…]  — renders loop.sh from the canonical template
render_loop() {
  local fdir="$1" feat="$2" primary="$3"; shift 3
  local args=() r
  for r in "$@"; do args+=(--extra "$r"); done
  python3 "$REPO_ROOT/skills/loop-pilot/scripts/render-loop.py" --template "$REPO_ROOT/skills/loop-pilot/references/loop-template.md" \
    --feature "$feat" --primary "$primary" --at-keyboard "${ATK:-}" ${args[@]+"${args[@]}"} --stamp test --out "$fdir/loop.sh"
  chmod +x "$fdir/loop.sh"
  ATK=""                            # one-shot, like the fixture helpers above
}

state_of() { grep -E "^\| *$2 *\|" "$1/status.md" | head -1 | awk -F'|' '{gsub(/ /,"",$3); print $3}'; }
argv_of() { cat "$FAKE_AGENT_LOG_DIR/$1.argv"; }
tree_hash() { ( cd "$1" && find . -type f ! -name '*.log' | sort | xargs -I{} sh -c 'printf "%s " "{}"; sha256sum < "{}"' ) 2>/dev/null | sha256sum | cut -c1-16; }
