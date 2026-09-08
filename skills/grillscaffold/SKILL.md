---
name: grillscaffold
version: 3.5.0
description: Plan and scaffold autonomous feature development through a Grill → Scaffold → Loop workflow. Use this whenever the user wants to plan, spec, design, or build a substantial feature — trigger on phrases like "I want to build X", "plan the Y feature", "let's spec this out", "grill me", "feature workflow", or any request to design a multi-session piece of work, even if they don't name the skill. It interviews the user relentlessly in frontier rounds (every currently-answerable question at once, each with a recommendation) until every decision is locked, then generates the planning documents — plan.md, prompts.md, status.md, loop.sh, plus docs/CONTEXT.md vocabulary grounding — in a docs/features/feature-slug/ folder that let fresh sessions or an unattended loop execute the feature phase by phase. The loop runs start to finish without stopping and ends with a self-audit plus a tickable QA.md test list. Do NOT use for small bug fixes, single-file changes, or quick questions — a full grill is overkill there.
---

# grillscaffold

Grill → Scaffold → Loop. This skill turns a fuzzy feature idea into a locked plan and a set of
self-contained session prompts that fresh agent sessions — Claude Code, Codex, or Kimi Code —
can execute one phase at a time, with state tracked on disk, an agent-agnostic unattended
runner, and an audit at the end.

This skill runs at **planning time only**. It produces documents; it does not execute phases.
Everything an executing session needs is written into the generated prompt blocks, because no
skill will be present when they run. That is why the generated documents must be explicit and
self-contained — a rule that lives only in your head right now is a rule that will be broken at
3am by a session that never saw it.

## What gets produced

On completion, `docs/features/<feature>/` in the primary repo contains four files:

| File | Role | Template |
|---|---|---|
| `plan.md` | The locked reference: decisions, architecture, phases, waves. **Read-only to executing sessions.** | `references/plan-template.md` |
| `prompts.md` | Copy-paste prompt blocks — one per phase — plus ordering rules and the AUDIT block. | `references/prompts-template.md` |
| `loop.sh` | Agent-agnostic unattended runner: one fresh headless process per phase, runs A→Z without stopping, audit + `QA.md` at the end. | `references/loop-template.md` |
| `status.md` | Machine-readable state: strict phase table, progress log, deferred items. The only file sessions update. | `references/status-template.md` |
| `design-brief.md` | *Optional* (Stage 1.5): paste-ready prototyping prompt for Claude Design. | `references/design-brief-template.md` |

The scaffold also writes or appends `docs/CONTEXT.md` in the primary repo (Stage 0): the
project vocabulary and ADRs, extended with the feature's own new entities.

Read the relevant template from `references/` **only when you reach the Scaffold stage** — not
during the grill. They carry the exact document structures and the boilerplate that must appear
verbatim.

---

## Stage 0 — Vocabulary grounding (`docs/CONTEXT.md`)

Before the first grill round, check whether the primary repo has `docs/CONTEXT.md`. This file
is the project's shared vocabulary and decision record — the thing that stops ten fresh
sessions from inventing ten dialects.

- **If it exists**: read it. Grill in its vocabulary from the first question, and treat its
  ADRs as settled unless the user reopens one.
- **If it is missing**: dispatch a sub-agent (non-blocking — start round 1 meanwhile) to
  draft one from the repos: the entities and what they are actually called, module
  boundaries, project-specific words with precise meanings, and any architectural decisions
  visible in the code or docs, written up as short numbered ADRs (context → decision →
  consequence). Present the draft to the user — **proposed, not assumed** — let them amend,
  and write the confirmed version to `docs/CONTEXT.md` at scaffold time alongside the other
  documents.

**ADR enforcement** is what makes the file matter: every generated prompt block instructs the
session to use CONTEXT.md's names verbatim (code identifiers, labels, table columns, docs) and
to honour its ADRs. A session must never rename a concept or contradict an ADR; if a phase
surfaces a genuinely new architectural decision, it is logged in status.md Deferred for the
owner — executing sessions do not write ADRs. New vocabulary the grill introduces (the
feature's own entities) is appended to CONTEXT.md at scaffold time, so the next feature's
Stage 0 starts current.

---

## Stage 1 — The Grill

Interview the user relentlessly until you reach a shared understanding. Map the feature as a
**design tree**: every decision branches into the decisions that hang off it. Work the tree in
rounds until every branch has been visited and nothing is left silently assumed.

**The rules of the grill:**

1. **Work the tree in frontier rounds.** The frontier is every decision whose prerequisites
   are already settled: the questions you can ask now without guessing at answers you haven't
   heard yet. Ask the whole frontier in one round — number each question and give your
   recommended answer — then wait for the user's answers before the next round. A question
   whose answer depends on another question still open in this round belongs to a later
   round, not this one. If a frontier is huge, lead with the questions that unblock the most
   of the tree and carry the rest to the next round — a round should stay digestible
   (roughly 3–6 questions). Format a round like so:

   ````
   ❓ **Q1** - **<question title>**: <question body, may be multiple paragraphs, including
   multiple choices>

   ➡️ <your recommended answer>

   ---

   ❓ **Q2** - **<question title>**: <question body>

   ➡️ <your recommended answer>
   ````

2. **Every question carries your recommended answer**, with a short reason. The user should be
   able to answer most questions with one word ("Q1 yes, Q2 the second option, Q3–Q5 as you
   recommend").
3. **Each round the user answers reshapes the tree.** Settled decisions push the frontier
   outward and unblock the questions that depended on them. Recompute the frontier and ask
   the next round. It is fine (encouraged) to show the user the shape of the remaining tree
   between rounds so they know where the interview is going.
4. **Facts are looked up, decisions are asked — and fact-finding never blocks a round.**
   Finding facts is your job, never the user's. If something can be found by exploring the
   environment — gate commands in `package.json` scripts, repo paths, conventions in
   `CLAUDE.md`, existing code the feature will break, environment quirks documented in the
   repo — dispatch a sub-agent to find it rather than asking. A running exploration is an
   unsettled prerequisite: only the questions downstream of it wait for the sub-agent to
   report; ask the rest of the frontier now. The decisions, though, are the user's: put each
   one to them and wait.
5. **Discovered facts are proposed, not assumed.** After exploring, present what you found —
   "here are the gates I found per repo, here are the conventions I'll bake into every prompt —
   correct?" — and let the user amend. Wrong discovered facts poison every generated prompt.
6. **The grill is done when the frontier is empty — and no document is written until the user
   confirms.** An empty frontier means every branch of the design tree was visited. The grill
   then ends with a decision summary (see the confirmation gate below), and only an explicit
   confirmation unlocks the Scaffold.

**What the grill must cover** (adapt depth to the feature; skip branches that obviously don't
apply, but say so rather than silently skipping):

- The feature itself: scope, data model, flows, per-surface behavior, what's explicitly out of scope
- What existing code breaks — found by exploring, confirmed with the user
- Migration, if existing data/users are affected
- Repos touched, primary repo, gate commands per repo (discovered)
- Project-specific conventions to bake into prompts (discovered from CLAUDE.md and repo docs)
- Open questions that can't be resolved now → parked as Decision record items (D-1, D-2, …)
- For UI-heavy features: whether to run a **design spike** (Stage 1.5) — prototype in Claude
  Design first and let the prototype answer the open UX D-IDs, instead of deciding blind
- Whether the feature's landing zone needs a **P0 prefactor** — a behavior-neutral phase
  zero that only reshapes existing code so the feature lands cleanly (extract the function
  about to be extended, split already-oversized files, introduce the interface the new code
  implements). Its gate is brutal and simple: all existing tests pass, zero new behavior —
  which also makes it the safest phase to run unattended first. Recommend one whenever
  exploration shows the touched files are in bad shape.
- The phase breakdown (see sizing below), dependencies between phases, which phases can run in
  parallel, and **which phases are at-keyboard-only**
- **A demoable outcome per phase** — one sentence stating what a human can see or do when
  the phase is done ("owner opens /settlements and sees one real row"), not what code
  exists. Put each phase's proposed outcome to the user; a phase with no describable
  demoable outcome is usually a horizontal layer that should be re-cut (see vertical slice
  below). P0 prefactor and pure-migration phases may use "no behavior change — all existing
  tests still green" as their outcome.
- **A named test seam per phase, with prior art** — discovered, not invented: a sub-agent
  explores the repos' existing tests and proposes, for each phase, the boundary to test
  through ("test the settlement engine via `SettlementEngine.compute()` with a fake clock,
  never through the HTTP layer") plus one existing test file that does it the right way, to
  be imitated ("copy the pattern in `dispatch/__tests__/engine.test.ts`"). Confirm with the
  user like any discovered fact. If a repo has no tests at all, that is itself a finding to
  put to the user — seam or no seam is their decision.
- **Per phase, what "tested" means** — one or two lines a human can act on when the run ends
  ("open /settlements as a garage owner: one real row, correct total; then a garage with none:
  empty state, not a spinner"). These become `> QA:` lines in prompts.md and tick boxes in the
  run's `QA.md`. Derive them from the demoable outcome and put them to the user; a phase whose
  QA line is "check it works" has no QA line.
- **Which phases a machine must never attempt** — ask this separately from at-keyboard, because
  the unattended runner now *attempts* at-keyboard phases (doing everything that needs no human
  hand and ending `qa-pending`). What it must not attempt is the irreversible and the physical:
  a production console toggle, a live payment, a device in someone's hand, a destructive
  migration against real data. Each of those gets a `> HUMAN-ONLY: <reason>` line and is the
  one hard brake on the run — so ask about it for every phase touching production, payments,
  auth or live data, and record the answer rather than inferring it.
- **For every at-keyboard phase, an owner checklist** — ask explicitly: what must the owner
  run or prepare beforehand (backup scripts, credentials, consoles open, D-IDs answered),
  what should the agent stop-and-ask about mid-phase, and what does the owner verify after?
  These become `> OWNER:` lines above the phase's prompt block, which `loop.sh --preflight`
  and `QA.md` surface verbatim — a manual phase without a checklist tells the owner nothing
  but "run it yourself". Also ask whether any of the manual work is **front-loadable**
  (doable before the run starts); if a whole at-keyboard phase can be done upfront, say so —
  the owner can complete it first and the unattended run then covers everything else.
- Order phases so human-only ones sit as early or as late in the dependency graph as
  correctness allows — nothing is stranded behind them permanently (the runner sweeps
  dependents forward), but a phase built against a placeholder is worth less than one built
  against the real thing.
- The feature slug (short kebab-case, e.g. `garage-settlements`) — confirm it explicitly

**Phase sizing heuristics.** Prefer **bigger, fewer phases** — each phase is one fresh Claude
Code session's worth of work, and fewer sessions means less orchestration overhead:

- A phase may span multiple repos and may bundle a backend change with its consuming UI when
  they form one coherent deliverable.
- **Vertical slice first.** The first building phase (after any P0 prefactor) cuts thinly
  through every layer — one field from schema through API to a pixel on screen — rather than
  building a whole layer at a time. Horizontal phasing ("P1: all backend, P2: all UI") defers
  integration risk to the last phase, the worst place for it; the slice forces the layers to
  meet on day one and every later phase widens a path that already works.
- **Expand → migrate → contract for wide refactors.** A change with many dependents never
  lands as one phase: **expand** (add the new path beside the old — nothing uses it yet, so
  nothing breaks), **migrate** (move callers/data over, incrementally checkable), **contract**
  (delete the old path once nothing references it). Each of the three is independently green
  and patch-snapshotted, and the run can safely stop after migrate with contract deferred —
  which matters in a no-commit workflow where the `.patches/` files are the only rollback
  boundaries.
- Forced seams — split regardless of size:
  - Only one contract-regenerating (or equivalent shared-artifact-fighting) phase in flight at
    a time; phases that would fight over a generated artifact cannot merge or parallelize.
  - Anything rewriting security rules, auth, payments, or a core engine gets isolated as its
    own phase, flagged **at-keyboard-only** (and `> HUMAN-ONLY:` if a machine must not attempt
    it at all), and runs alone. Risk must never be buried inside an unrelated 80% of a big
    phase — that isolation matters more now that the runner attempts supervised phases rather
    than skipping them.
- If a phase's scope won't fit in one tight prompt block, it is two phases.

**The confirmation gate.** When the tree is exhausted, present a compact decision summary:
every locked decision numbered, every parked decision with its D-ID, the proposed phase list
with dependencies, at-keyboard and human-only flags, each phase's demoable outcome, QA steps
and test seam, the feature slug, and the discovered rules (CONTEXT.md vocabulary and ADRs included) that will be baked
in. The user replies "confirmed" or corrects things (re-present after corrections).
Only then write the files — all in one go.

---

## Stage 1.5 — Design spike (optional, UI-heavy features)

If the feature has significant UI surface, ask during the grill — before the confirmation
gate — whether the user wants to **prototype first in Claude Design** (or any prototyping
tool) and let the prototype settle the open UX decisions.

If yes:

1. Mark the UX decisions that genuinely need visual/interactive judgment as D-IDs with the
   note "prototype will answer" — do not force the user to answer them verbally now.
2. Generate `docs/features/<feature>/design-brief.md` from
   `references/design-brief-template.md`: a single paste-ready prompt carrying the screens,
   flows, states, the **exact field names from the data model** (so the prototype speaks the
   code's vocabulary), constraints, explicit do-NOT-prototype exclusions, and the D-IDs the
   prototype must answer.
3. Pause the grill there. Tell the user: paste the brief into Claude Design, prototype, and
   come back with the deliverables the brief requests (D-ID answers + screenshots/export
   saved into `docs/features/<feature>/design/`).
4. On return, resolve the D-IDs from the prototype's answers, fold in anything the prototype
   revealed (new states, missing fields), re-present the decision summary, and proceed to
   the confirmation gate as normal.

The prototype is a **reference, not source**: when a spike ran, UI phase blocks in prompts.md
point at `docs/features/<feature>/design/` as the visual reference — subordinate to plan.md
wherever they differ — and prototype code is never copied wholesale into the repos (the
1000-line and feature-folder rules apply to built code regardless of what the prototype did).

If the user declines the spike, the UX decisions are grilled verbally like everything else.

---

## Stage 2 — The Scaffold

On confirmation, read the templates in `references/` and generate the documents into
`docs/features/<feature>/` in the primary repo. Fill every placeholder; delete template
guidance comments; sections that don't apply are removed, not left empty.

**Universal rules — bake these into every generated prompt block, verbatim in spirit.** They
are non-negotiable regardless of project, and each block must carry them itself because
executing sessions have no skill to remind them:

1. **NEVER `git commit`, `git push`, or deploy** — in any repo, in any circumstance. The
   working tree is left dirty on purpose; the owner reviews and commits. Every phase ends by
   suggesting commit messages per repo touched.
2. **Keep every file under 1000 lines** — split, don't grow. A phase that touches an
   already-oversized file must split it.
3. **Feature-based folders** — new code lives inside the feature's own folder with its own
   `hooks/`, `components/`, `functions/` (etc.) subfolders, never scattered into global
   directories. This keeps features modifiable and lets the audit check for leaks.
4. **`plan.md` is read-only.** If the plan is wrong, log it in status.md's Deferred section and
   stop; never edit the plan. The plan must remain evidence of what was intended.
5. **Update `status.md` on completion** — phase table row, gate cells, a dated progress log
   entry, deferred items. A session that skips the status update is not finished.
6. **Save a patch snapshot** — `git diff > .patches/<phase>-<repo>.patch` for each repo
   touched. With no commits, these patches are the only rollback boundaries.
7. **Log, don't fix** — anything found outside the phase's scope goes to Deferred.
8. **Speak the project's vocabulary** — names come verbatim from `docs/CONTEXT.md` (and the
   plan's data model); never rename a concept, never contradict an ADR. A new architectural
   decision discovered mid-phase goes to Deferred for the owner — sessions do not write ADRs.
9. **Test through the phase's named seam, imitating its prior-art file** — never invent a
   new testing style, never test through a layer the seam excludes.
10. **Check your dependencies, then finish anyway** — before starting, the session checks
   status.md. A dependency that is `done` or `qa-pending` is settled: proceed (`qa-pending`
   means the code is there and a human's eyes are pending, not that the work is missing). If a
   dependency is genuinely missing — `blocked`, or `todo` — say so, build the part of the scope
   that does not need it, cross the gap with the smallest honest placeholder rather than
   reimplementing the missing phase, name every gap in Notes, and end `qa-pending`. Never end
   the run waiting on a person: `qa-pending` with the gap named always beats `blocked`.

**The finish rule.** Every phase ends in a terminal state the same session writes: `done` when
everything held, `qa-pending` when the code is complete but something needs a human's eyes, and
`blocked` only when the work genuinely did not land. `qa-pending` is a *successful* ending —
the runner treats it as complete, dependents proceed, and its Notes cell becomes one line on
the owner's QA checklist. That is why the Notes cell must be written as an instruction for
someone who was not in the session ("open /settlements as a garage owner: one real row, correct
total"), never as "needs testing". Bake this into every block.

**The phase-end check** (written into every block): before a phase may be marked `done`, the
session (a) re-reads the phase's plan section and confirms each claim against what was actually
built — including the phase's **demoable outcome**, stated in the status.md progress log as
achieved with one line of evidence (a "code exists but the outcome isn't demoable" phase is
`qa-pending`, not `done`) — any gap is fixed or the phase is marked `qa-pending` with the gap
named; (b) runs every
gate for every repo touched — a failed gate means the phase cannot be `done`; (c) spot-checks
the universal invariants against this phase's diff only; (d) performs the status update and
patch snapshot. Deep verification is the AUDIT's job, not the phase's.

**Always generate the AUDIT block (in prompts.md) and `loop.sh`**, customized with the
feature's repos, gates, and at-keyboard exclusions. The loop's architecture is one **fresh
headless agent process per phase** (`claude -p` / `codex exec` / `kimi -p`, configurable), so
every phase starts at token zero of its own context window no matter which agent runs it.
Its run contract is **A → Z: the run does not stop for a human.** A phase that comes back
`qa-pending` counts as complete — dependents proceed and it becomes a line on the owner's test
list. At-keyboard phases are attempted (everything that needs no human hand, nothing
irreversible, ending `qa-pending` with the human steps in Notes); only a `> HUMAN-ONLY:` phase
is left alone. A failed gate after its retry is a recorded defect, not an exit. Phases stranded
behind something that never completed are swept forward once with a degraded-dependency notice.
Every run ends the same way: the AUDIT runs in a fresh process, and **`QA.md`** is written — a
tickable owner checklist in four sections (verify these · defects the loop could not clear ·
only you can do these · done and gate-verified), headed with when the run started and ended.
There is no rerun-to-continue ending. `./loop.sh --preflight` prints the dispatch plan, the
human-only phases, the owner checklists and the declared QA steps before anything runs, so
front-loadable prep happens upfront instead of surfacing as a surprise. prompts.md also carries
a Claude-Code-only interactive `/loop` variant with the same A→Z contract. Generated prompt blocks must stay agent-neutral: no
agent-specific slash commands inside a block except as parenthetical alternatives (e.g.
"Claude Code: /add-dir; other agents: start from a common parent directory").

**After writing the files**, tell the user how to run: paste phase blocks manually into any
agent (attended, waves allow two terminals), or go unattended — `./loop.sh --preflight` first
to see the dispatch plan and do anything front-loadable, then `AGENT=<claude|codex|kimi>
./loop.sh` and walk away. The run finishes on its own, once, every time: `audit-<date>.md` and
`QA.md` are both waiting when it ends, and QA.md is the one to read first — it is the test
list. Say plainly what the trade is: the run will not pause for them, so some phases will
finish `qa-pending` (complete but unverified) and QA.md is where that is recorded. Remind them
to check their agent's headless permission settings first, and that `> HUMAN-ONLY:` is the only
thing that stops the loop attempting a phase.

---

## Guardrails

- If invoked for something trivially small (a bug fix, a one-file change), say the workflow is
  overkill and offer to just do the task.
- If the user says "skip the grill, just scaffold from what I told you", comply — but present
  the decision summary anyway before writing, since the confirmation gate is what protects the
  ten sessions that follow from one misunderstanding now.
- Never invent gate commands or repo paths; if exploration can't find them, ask.
- Never mark a phase `> HUMAN-ONLY:` on the user's behalf, and never leave it off a phase that
  needs it. The runner will attempt anything without that line, so the question "must a machine
  never try this?" is asked explicitly for every phase touching production, payments, auth, live
  data or a physical device — and the user's answer is recorded in plan.md, not inferred.

---

## This skill ships as half of a versioned bundle

`grillscaffold` (planning) and `loop-pilot` (execution) are released together from one
repository and share one runner template. `release-manifest.json` sits next to this file and
records the exact set that was installed:

```json
{ "release": "8.2.0", "grillscaffold": "3.5.0", "loopPilot": "8.2.0", "runnerTemplate": 5 }
```

The two skills' copies of `references/loop-template.md` are **byte-identical** by construction
— CI fails the build if they drift — so a feature scaffolded by grillscaffold and a feature
upgraded by loop-pilot produce the same `loop.sh`. When only one of the pair is installed,
things still work: grillscaffold scaffolds a complete runner on its own, and loop-pilot flies
any feature folder it finds. Install or update both with the repository's `install.sh`, check
what is installed with `loop-pilot/scripts/doctor.sh`, and update with
`loop-pilot/scripts/update.sh`.
