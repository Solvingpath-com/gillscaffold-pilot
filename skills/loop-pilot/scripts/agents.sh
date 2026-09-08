#!/usr/bin/env bash
# loop-pilot agents — which coding agents can fly a loop on this machine?
# Usage:
#   agents.sh            table of every supported agent: installed? version? authenticated?
#   agents.sh <agent>    check one; exit 0 only if it is installed AND authenticated
#
# Read-only: it runs `--version` and the agent's own auth-status command. It never sends a
# prompt, never spends tokens, and never writes anything outside stdout.
set -uo pipefail

check_one() {  # check_one <agent> → prints "<agent>|<path>|<version>|<auth>"; exit 0 if ready
  local a="$1" path ver auth rc=0
  path="$(command -v "$a" 2>/dev/null)" || path=""
  if [ -z "$path" ]; then printf '%s|—|—|not installed\n' "$a"; return 1; fi
  case "$a" in
    claude) ver="$("$a" --version 2>/dev/null | awk '{print $1; exit}')"
            if claude auth status >/dev/null 2>&1; then auth="authenticated"; else auth="NOT authenticated (claude auth login)"; rc=1; fi ;;
    codex)  ver="$("$a" --version 2>/dev/null | awk '{print $NF; exit}')"
            if codex login status >/dev/null 2>&1; then auth="authenticated"; else auth="NOT authenticated (codex login)"; rc=1; fi ;;
    kimi)   ver="$("$a" --version 2>/dev/null | head -1)"; auth="unknown (legacy adapter — verify manually)" ;;
    *)      printf '%s|—|—|unsupported agent\n' "$a"; return 1 ;;
  esac
  printf '%s|%s|%s|%s\n' "$a" "$path" "${ver:-?}" "$auth"
  return $rc
}

if [ $# -ge 1 ]; then
  out="$(check_one "$1")"; rc=$?
  printf '%s\n' "$out" | awk -F'|' '{printf "%-7s %-30s %-12s %s\n", $1, $2, $3, $4}'
  exit $rc
fi

echo "AGENT   PATH                           VERSION      AUTH"
ready=0
for a in claude codex kimi; do
  out="$(check_one "$a")" && ready=$((ready+1))
  printf '%s\n' "$out" | awk -F'|' '{printf "%-7s %-30s %-12s %s\n", $1, $2, $3, $4}'
done
echo
if [ "$ready" -eq 0 ]; then
  echo "No agent is ready. Install and authenticate at least one, then rerun:"
  echo "  Claude Code   https://code.claude.com/docs   →  claude auth login"
  echo "  Codex CLI     https://developers.openai.com/codex  →  codex login"
  exit 1
fi
echo "Fly a feature with any ready agent:   AGENT=<agent> <feature-dir>/loop.sh"
