# grillscaffold — Changelog

Version lives in `SKILL.md` frontmatter (`version:`). Verify an install with:
`grep '^version:' ~/.claude/skills/grillscaffold/SKILL.md`

## 3.3.0 — 2026-08-25

Completes the 2.x re-merge begun in 3.2 — all five remaining Pocock features —
plus two bug fixes.

- **Stage 0 vocabulary grounding**: `docs/CONTEXT.md` (project vocabulary + short
  ADRs) is read, or drafted by a non-blocking sub-agent and confirmed with the
  user, before the grill; written/appended at scaffold time. ADR enforcement is a
  universal rule baked into every prompt block: names verbatim, no concept
  renames, no ADR contradictions; new architectural decisions go to Deferred.
- **Vertical slice + demoable outcome**: first building phase cuts thinly through
  every layer; every phase carries a one-sentence demoable outcome (grilled,
  recorded in plan.md, verified at phase end and re-tested by the AUDIT — code
  without the outcome is qa-pending, never done).
- **Expand → migrate → contract**: wide refactors are three independently green,
  independently patch-snapshotted phases; the run may stop after migrate.
- **P0 prefactor**: behavior-neutral phase zero to make the feature landable;
  gate = existing tests pass, zero new behavior; recommended whenever exploration
  shows the landing zone is in bad shape.
- **Named test seams with prior art**: per phase, a discovered seam to test
  through plus an existing test file to imitate — baked into the phase block; the
  AUDIT flags invented testing styles.
- **Fix**: prompts-template's unattended-run prose and the interactive `/loop`
  variant still described the pre-3.1 stop-the-world contract; both now carry the
  route-around ONE START, ONE FINISH contract (SKIP list, handoff.md, audit).
- **Fix**: loop.sh now resets rows left `in-progress` by a killed run to
  `blocked` at startup (never during `--preflight`) — previously they were
  stranded forever and misfiled by the handoff as "waiting".

## 3.2.0 — 2026-08-25

The frontier-grill release: re-merges the Pocock grill mechanics from the 2.x
branch that were lost in the 2.x/3.x divergence.

- **Frontier-round grilling** replaces one-question-at-a-time. The grill is an
  explicit design tree; each round asks the whole frontier (every question whose
  prerequisites are settled), numbered `❓ Q1/Q2/…` with a `➡️` recommended answer
  each. Answers reshape the tree; the frontier is recomputed per round; a question
  depending on one still open this round waits for a later round. Rounds stay
  digestible (~3–6 questions).
- **Non-blocking parallel sub-agent fact-finding**: environment facts are fetched
  by dispatched sub-agents; a running exploration only holds back its downstream
  questions — the rest of the frontier is asked immediately.
- Grill completion redefined: done when the frontier is empty, not when a linear
  question list runs out. Confirmation gate unchanged.

Still not re-merged from 2.x (candidates for 3.3): Stage 0 `docs/CONTEXT.md`
vocabulary grounding with ADR enforcement, vertical slice test with per-phase
"Demoable outcome", expand→migrate→contract for wide refactors, P0 prefactor,
named test seams with prior-art references.

## 3.1.0 — 2026-08-19

The loop-rebuild release. Fixes the core frustration of runs dying mid-flight.

- **Route-around contract** in `loop.sh`: ONE START, ONE FINISH. Blocked phases,
  qa-pending rows, silent sessions, missing prompt blocks, and at-keyboard phases
  are recorded and skipped, never fatal. Dependents wait; independent branches
  continue. Run ends with either the AUDIT (all done) or `handoff.md` (a
  categorized manual TODO). Rerun after handoff work — it continues.
- **`--preflight` flag**: surfaces every required manual task before the run starts.
- **`> OWNER:` checklists**: at-keyboard phases carry machine-parseable owner
  instructions instead of vague "needs human" markers.
- **`design-brief-template.md`** added — the Stage 1.5 template referenced by
  SKILL.md now actually ships (was missing in v3).
- `version:` frontmatter field and this changelog introduced retroactively
  (2026-08-22) — earlier builds carried no version marker.

Division of labor clarified: runtime concerns (verifier agents, RETRO mining,
watchdogs, notifications, gate verification, fleet launching, dashboard) live in
the **loop-pilot** companion skill, not here. grillscaffold is planning-time only.

## 3.0.0 — 2026-08-15

- Independent `VERIFIER_AGENT` per phase (different model, can flip to qa-pending).
- RETRO block after audit: mines the run for lessons, proposes CLAUDE.md additions.
- Baseline drift detection (repo HEAD SHAs recorded at scaffold time).
- Update mode: prior version documents as grill input, output versioned into `v2/`.
- `--dry-run` mode; end-of-run notifications via `NOTIFY_CMD` / macOS native.
- Stage 1.5 design spike: paste-ready `design-brief.md` for Claude Design with
  D-ID questions gating confirmation.

(Most runtime pieces above later migrated to loop-pilot.)

## 2.x — 2026-08 (early)

- Pocock-derived enhancements: Stage 0 `docs/CONTEXT.md` vocabulary grounding with
  ADR enforcement, frontier-round grilling (3–6 questions per round with
  recommendations), parallel sub-agent fact-finding, vertical slice test with
  per-phase "Demoable outcome", expand→migrate→contract for wide refactors,
  P0 prefactor, named test seams with prior-art references.
- Note: this branch and the v3 branch diverged; the Pocock grill mechanics were
  not carried into the 3.x SKILL.md. Re-merging them is the candidate scope for
  a future 3.2.

## 1.x

- Original Grill → Scaffold → Loop workflow: relentless one-question-at-a-time
  interview, `plan.md` / `prompts.md` / `status.md` in `docs/features/<slug>/`,
  fresh session per phase, `.patches/` rollback boundary, no-commit posture,
  AUDIT block.

## 3.5.0 — 2026-09-08

Released as part of the grillscaffold + loop-pilot bundle 8.2.0. Ships runner template v5
(byte-identical to loop-pilot's copy) and agent-neutral plan/prompts/status templates: the
wave table is the loop's authority on concurrency, `qa-pending` satisfies dependencies,
at-keyboard phases are attempted unattended, and `> HUMAN-ONLY:` is the only hard brake.
Full detail in the repository's root CHANGELOG.md.
