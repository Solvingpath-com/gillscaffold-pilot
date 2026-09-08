# plan.md template

Generate `docs/features/<feature>/plan.md` with this structure. Sections scale with the
feature; remove what doesn't apply (say so in the header if notable). This file is the stable
reference every session reads — **no status tracking lives here**, ever. Status belongs to
status.md from birth.

Write in the plan's voice: decisions stated as settled facts, reasons attached where a future
session might otherwise "improve" something deliberately chosen (e.g. "No ETAs anywhere in V1 —
this removes the need for per-driver fields that don't exist today").

---

```markdown
# <Feature Name> — Plan

Owner decisions locked <date>. Supersedes <what, if anything>. Everything not mentioned here
is unchanged: <list the adjacent systems that keep working as-is — this sentence prevents
sessions from "helpfully" touching them>.

Repos touched: <primary repo> (primary), <others with paths>.

---

## 1. Decisions locked

| # | Decision | Choice |
|---|---|---|
| 1 | <area> | **<choice>** — <one-line reason if the choice is non-obvious> |

<Call out any decision that is a simplification win or that removes work, so its absence isn't
mistaken for an oversight.>

## 2..N. Domain sections

<Data model, flows, per-surface behavior. For each new node/schema/endpoint, show the exact
shape (code block) with inline comments explaining ownership — who writes it, who reads it,
what must never write it. For each screen/flow, a table of steps with the backend each step
touches. Number these sections; prompt blocks will reference them as "plan §3".>

## What this breaks

<Per area, the existing files/constants/rules the feature invalidates — discovered by
exploring the repos during the grill, not guessed. Exact paths. This section is what makes
phase prompts precise.>

## Migration

<Only if existing data/users are affected: mapping rules, backfill steps, and the conditions
under which migration may run (e.g. "no in-flight request may be migrated; run while the
table is quiet").>

## Decision record

<Open questions parked during the grill. Each gets an ID. Phases depending on an unanswered
item are `blocked` in status.md until it is answered.>

| ID | Question | Options | Blocks | Answer |
|---|---|---|---|---|
| D-1 | <question> | <options with your recommendation marked> | <phase IDs> | _open_ |

## Phase breakdown

<One subsection per phase. If a P0 prefactor was agreed, it is the first phase: scope limited
to behavior-neutral reshaping, demoable outcome "no behavior change", gate = existing tests
pass. If a wide refactor was split expand→migrate→contract, keep the three as separate
phases and say which stage each is — the run may deliberately stop after migrate.>

### <P-ID> — <Phase name>

- **Scope:** <what this phase builds, tight enough to fit one prompt block>
- **Demoable outcome:** <one sentence: what a human can see or do when this phase is done —
  for a P0 prefactor or pure-migration phase: "no behavior change; all existing tests green">
- **Test seam:** <the boundary to test through, e.g. "SettlementEngine.compute() with a fake
  clock — never through the HTTP layer"> · prior art: `<existing test file to imitate>`
- **Repos:** <primary for this phase; others are granted to the runner automatically and, in an interactive session, added by hand (Claude Code: /add-dir)>
- **Files expected:** <feature-folder paths where new code lands; existing files touched>
- **Gates:** <the exact commands for the repos this phase touches>
- **At-keyboard-only:** yes/no <yes for security rules / auth / payments / core-engine work.
  The unattended loop still ATTEMPTS these alone, builds everything that needs no human hand,
  refuses anything irreversible, and ends them qa-pending with your steps in Notes. If a phase
  must never be attempted without you, give it a `> HUMAN-ONLY: <reason>` line in prompts.md —
  that is the only hard brake.>
- **Depends on:** <phase IDs or —>

## Concurrency and waves

<The dependency graph, operationally. The same content appears summarized in prompts.md's
"Order and parallelism" — this section is the authoritative version with full reasoning.>

| Wave | Run together |
|---|---|
| 1 | <phases> |

Hard rules behind it:
- <"X before Y because both edit Z" — always give the reason; a rule without a reason can't
  be re-evaluated when the code changes>
- Only one <contract-regenerating / shared-artifact> phase in flight at a time.
- <At-keyboard phases> run alone, attended.

## Rollback and abort

- No commits are ever made; each phase saves `git diff > .patches/<phase>-<repo>.patch` per
  repo touched. To roll back a phase: `git checkout -- .` in the affected repos, or apply
  patches selectively to reconstruct a known-good point.
- A phase that goes sideways mid-run: stop, log what happened in status.md Deferred, mark the
  phase `blocked`, do not attempt repair in the same session — a fresh session with the
  patch files and the log makes better decisions than a tangled one.
- If the plan itself is discovered to be wrong: the plan is not edited. Log the contradiction
  in Deferred, mark affected phases `blocked`, and stop for the owner.
```
