#!/usr/bin/env bash
# loop-pilot upgrade — regenerate a feature's loop.sh from the CURRENT runner template,
# preserving that feature's own config (primary repo, extra repos, at-keyboard phases).
#
# Usage:
#   upgrade.sh <feature-dir>            upgrade if outdated (idempotent; backs up first)
#   upgrade.sh <feature-dir> --check    report a verdict, change nothing (exit 0/2/3)
#
# Template source: the HIGHEST `# template-version:` among the candidates wins, so a feature
# scaffolded by any grillscaffold version gets the newest runner, and a future grillscaffold
# runner newer than loop-pilot's still wins. Candidates:
#   1. $GRILLSCAFFOLD_TEMPLATE (explicit path — always wins outright)
#   2. loop-pilot/references/loop-template.md      (this skill owns the canonical runner)
#   3. the grillscaffold skill installed next to this one
# A template with no version marker counts as version 0.
#
# Safety: never runs while a loop for that feature is alive, always backs up, always
# syntax-checks the result and restores the backup if the render is bad.
set -uo pipefail

FDIR="${1:?usage: upgrade.sh <feature-dir> [--check]}"; FDIR="${FDIR%/}"
MODE="${2:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP="$FDIR/loop.sh"
FEAT="$(basename "$FDIR")"
RENDER="$HERE/render-loop.py"
[ -f "$RENDER" ] || { echo "ERROR: renderer missing: $RENDER"; exit 1; }

tpl_version() {  # '# template-version: N' inside the fenced bash block; 0 if absent
  local v
  v="$(awk '/^```bash/{f=1;next} f&&/^```$/{exit} f&&/^# *template-version:/{gsub(/[^0-9]/,"",$0); print; exit}' "$1")"
  case "$v" in ''|*[!0-9]*) echo 0;; *) echo "$v";; esac
}

TPL=""; TPL_V=-1
if [ -n "${GRILLSCAFFOLD_TEMPLATE:-}" ] && [ -f "$GRILLSCAFFOLD_TEMPLATE" ]; then
  TPL="$GRILLSCAFFOLD_TEMPLATE"; TPL_V="$(tpl_version "$TPL")"
else
  for cand in "$HERE/../references/loop-template.md" "$HERE/../../grillscaffold/references/loop-template.md"; do
    [ -f "$cand" ] || continue
    cv="$(tpl_version "$cand")"
    if [ "$cv" -gt "$TPL_V" ]; then TPL="$cand"; TPL_V="$cv"; fi
  done
fi
[ -z "$TPL" ] && { echo "ERROR: no loop-template.md found (loop-pilot bundle or grillscaffold skill)"; exit 1; }
TPL_SHA="$(python3 "$RENDER" --template "$TPL" --body-sha)" || exit 1

# ── verdict ──────────────────────────────────────────────────────────────────
# CURRENT           — already this exact runner
# OUTDATED-contract — pre-v4 runner: stops for a human / no QA.md — NOT an A→Z run
# OUTDATED-minor    — v4+ contract but the template has moved on (new adapters, fixes)
# MISSING           — no loop.sh at all
verdict() {
  [ -f "$LOOP" ] || { echo "MISSING"; return; }
  local have_sha have_v
  have_sha="$(grep -m1 '^# template-sha:' "$LOOP" | awk '{print $3}')"
  [ "$have_sha" = "$TPL_SHA" ] && { echo "CURRENT"; return; }
  have_v="$(grep -m1 '^# template-version:' "$LOOP" | grep -oE '[0-9]+' | head -1)"
  case "$have_v" in ''|*[!0-9]*) have_v=0;; esac
  # a runner is A→Z only if it writes QA.md and treats qa-pending as completion
  if [ "$have_v" -ge 4 ] && grep -q 'write_qa' "$LOOP"; then echo "OUTDATED-minor"; else echo "OUTDATED-contract"; fi
}
V="$(verdict)"

if [ "$MODE" = "--check" ]; then
  echo "$V — $LOOP (template v$TPL_V, sha $TPL_SHA, from $TPL)"
  case "$V" in CURRENT) exit 0;; MISSING) exit 2;; *) exit 3;; esac
fi
# ── never swap the runner under a live run ───────────────────────────────────
live_pid=""
[ -f "$FDIR/loop.pid" ] && live_pid="$(cat "$FDIR/loop.pid" 2>/dev/null)"
if [ -z "$live_pid" ] && [ -f "$FDIR/.runinfo" ] && ! grep -q '^ended=' "$FDIR/.runinfo" 2>/dev/null; then
  live_pid="$(grep '^pid=' "$FDIR/.runinfo" | cut -d= -f2)"
fi
if [ -n "$live_pid" ] && kill -0 "$live_pid" 2>/dev/null; then
  echo "ERROR: a loop is running for $FEAT (pid $live_pid). Stop it first, then upgrade."; exit 1
fi

[ "$V" = "CURRENT" ] && { echo "CURRENT — loop.sh already matches template v$TPL_V (sha $TPL_SHA). Nothing to do."; exit 0; }

# ── recover per-feature config ───────────────────────────────────────────────
# 1) primary repo: the old script's value, else the folder layout (<repo>/docs/features/<feat>)
REPO=""
[ -f "$LOOP" ] && REPO="$(grep -m1 '^PRIMARY_REPO=' "$LOOP" | sed 's/^PRIMARY_REPO=//; s/^"//; s/"$//')"
case "$REPO" in ''|*'<'*) REPO="$(cd "$FDIR/../../.." 2>/dev/null && pwd)";; esac
[ -n "$REPO" ] || { echo "ERROR: cannot determine primary repo for $FEAT"; exit 1; }

# 2) extra repos: old loop.sh EXTRA_REPOS=(…) → prompts.md '## Repos' table → plan.md 'Repos touched:'
EXTRAS_SRC=""
EXTRAS="$(python3 - "$LOOP" "$FDIR/prompts.md" "$FDIR/plan.md" "$REPO" <<'PY'
import os, re, shlex, sys
loop, prompts, plan, primary = sys.argv[1:5]
found, src = [], ""
if os.path.exists(loop):
    m = re.search(r'^EXTRA_REPOS=\((.*)\)\s*$', open(loop, encoding="utf-8", errors="replace").read(), re.M)
    if m and "<" not in m.group(1):
        try: found = [p for p in shlex.split(m.group(1)) if p.startswith("/")]
        except ValueError: found = []
        if found: src = "previous loop.sh"
if not found and os.path.exists(prompts):
    txt = open(prompts, encoding="utf-8", errors="replace").read()
    sec = re.search(r'^## Repos\b(.*?)(^## |\Z)', txt, re.S | re.M)
    if sec:
        found = [p for p in re.findall(r'`(/[^`]+)`', sec.group(1))]
        if found: src = "prompts.md ## Repos table"
if not found and os.path.exists(plan):
    m = re.search(r'Repos touched:(.*)', open(plan, encoding="utf-8", errors="replace").read())
    if m:
        found = re.findall(r'`(/[^`]+)`', m.group(1)) or re.findall(r'(/[^\s,()]+)', m.group(1))
        if found: src = "plan.md 'Repos touched:'"
out, seen = [], {os.path.normpath(primary)}
for p in found:
    p = os.path.normpath(p.strip().rstrip("/"))
    if p and p not in seen:
        seen.add(p); out.append(p)
print(src)
for p in out: print(p)
PY
)"
EXTRAS_SRC="$(printf '%s\n' "$EXTRAS" | head -1)"
EXTRA_ARGS=(); EXTRA_LIST=""
while IFS= read -r line; do
  [ -n "$line" ] && { EXTRA_ARGS+=(--extra "$line"); EXTRA_LIST="$EXTRA_LIST $line"; }
done <<< "$(printf '%s\n' "$EXTRAS" | tail -n +2)"

# 3) at-keyboard phases: old loop.sh → plan.md 'at-keyboard' → prompts.md OWNER sections
ATK=""; ATK_SRC=""
if [ -f "$LOOP" ]; then
  ATK="$(grep -m1 '^AT_KEYBOARD=(' "$LOOP" | sed 's/^AT_KEYBOARD=(//; s/).*//' | tr -d '"')"
  case "$ATK" in *'<'*) ATK="";; esac
  [ -n "$ATK" ] && ATK_SRC="previous loop.sh"
fi
if [ -z "$ATK" ] && [ -f "$FDIR/plan.md" ]; then
  ATK="$(grep -iE 'at.keyboard' "$FDIR/plan.md" | grep -oE 'P[0-9]+[a-z]?' | sort -u | tr '\n' ' ')"
  [ -n "$ATK" ] && ATK_SRC="plan.md"
fi
if [ -z "$ATK" ] && [ -f "$FDIR/prompts.md" ]; then
  ATK="$(awk '/^## P[0-9]/{ph=$2} /^> OWNER:/{print ph}' "$FDIR/prompts.md" | sort -u | tr '\n' ' ')"
  [ -n "$ATK" ] && ATK_SRC="prompts.md OWNER sections (inferred)"
fi
ATK="$(echo "$ATK" | xargs || true)"

# ── render (same renderer grillscaffold uses, so the result is byte-identical) ─
BAK=""
if [ -f "$LOOP" ]; then BAK="$FDIR/loop.sh.bak-$(date +%Y%m%d-%H%M%S)"; cp "$LOOP" "$BAK"; fi
TMP="$FDIR/.loop.sh.new.$$"
if ! python3 "$RENDER" --template "$TPL" --feature "$FEAT" --primary "$REPO" \
      ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} --at-keyboard "$ATK" \
      --stamp "upgraded by loop-pilot $(date '+%Y-%m-%d %H:%M')" --out "$TMP"; then
  echo "ERROR: render failed — nothing was changed."; rm -f "$TMP"; exit 1
fi
if ! bash -n "$TMP" 2>/dev/null; then
  echo "ERROR: rendered loop.sh failed the syntax check — keeping the existing runner."; rm -f "$TMP"; exit 1
fi
mv "$TMP" "$LOOP"; chmod +x "$LOOP"

[ -f "$FDIR/status.md" ] && \
  printf -- '- [pilot] upgraded loop.sh to template v%s (sha %s; was: %s; extra repos:%s from %s; at-keyboard: %s from %s; backup: %s)\n' \
    "$TPL_V" "$TPL_SHA" "$V" "${EXTRA_LIST:- none}" "${EXTRAS_SRC:-n/a}" "${ATK:-none}" "${ATK_SRC:-n/a}" "${BAK:-none}" >> "$FDIR/status.md"

echo "UPGRADED — $LOOP now runs template v$TPL_V (sha $TPL_SHA)"
echo "  was:          $V"
echo "  primary repo: $REPO"
echo "  extra repos: ${EXTRA_LIST:- none} ${EXTRAS_SRC:+(from $EXTRAS_SRC)}"
echo "  at-keyboard:  ${ATK:-none} ${ATK_SRC:+(from $ATK_SRC)}"
[ -n "$BAK" ] && echo "  backup:       $BAK"
if [ -z "$ATK" ] && [ -z "$ATK_SRC" ]; then
  echo "  ⚠ no at-keyboard phases found anywhere — if a phase truly needs a human at the"
  echo "    keyboard, add it to AT_KEYBOARD=() in $LOOP before flying."
fi
case "$V" in OUTDATED-contract)
  echo "  ⚠ the old runner stopped for a human. The new one goes A→Z: qa-pending completes,"
  echo "    at-keyboard phases are attempted, and every ending writes QA.md. Read the plan:"
  echo "      AGENT=claude $LOOP --preflight" ;;
esac
