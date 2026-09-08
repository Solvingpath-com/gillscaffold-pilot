# prompts.md template

Generate `docs/features/<feature>/prompts.md` with this structure. Every phase block must be
**fully self-contained** — a fresh session with zero prior context pastes one block and has
everything it needs, because no skill is present at execution time. That means the universal
rules and the completion contract are repeated in every block, not referenced. Repetition here
is a feature: it is what survives long sessions and context pressure.

Customize everything in angle brackets from the grill's answers: repo paths, gates,
conventions, at-keyboard exclusions.

---

````markdown
# <Feature Name> — Session Prompts

Copy/paste blocks. Each one is a complete, self-contained prompt for a fresh coding-agent
session (Claude Code, Codex, or any agent that takes a prompt and edits this repo). The plan carries the detail ([plan.md](plan.md)); these prompts aim the session.

**Rules baked into every block:** never `git commit`/`push`/deploy · gates green before
finishing · keep every file under 1000 lines (split, don't grow) · new code lives in the
feature's folder (own `hooks/`, `components/`, `functions/` subfolders) · plan.md is
read-only · names come verbatim from `docs/CONTEXT.md` and the plan's data model — never
rename a concept, never contradict an ADR (new architectural decisions go to Deferred, not
into CONTEXT.md) · test through the phase's named seam, imitating its prior-art file ·
<project-specific universals discovered in the grill, e.g. contract regeneration>

**Status update contract — every session, on completion:**

1. **status.md phase table** — set the row's State (`done`, or `qa-pending` with the gap
   named in Notes — code complete but unverified is never `done`), stamp the Date, fill every
   applicable Gates cell (`skipped — <reason>` rather than a blank).
2. **status.md progress log** — append one dated entry: what changed, what was verified, what
   was deliberately left.
3. **status.md deferred** — append anything found but not acted on. Log it, don't fix it.
4. **Patch snapshot** — `git diff > .patches/<phase>-<repo>.patch` for each repo touched.

A session that skips the status update is not finished.

## Repos

| Short name | Path |
|---|---|
| <name> | `<absolute path>` |

Start each session from the repo the phase edits most, and bring the other repos into the
workspace. Claude Code: `/add-dir <path>` interactively, `--add-dir <path>` headless.
Codex: `--add-dir <path>`. Any other agent: launch from a parent directory containing all
repos, or add them as whatever workspace root your agent supports. The unattended runner
reads the paths in the table above, so keep them absolute and backticked.

## Order and parallelism

Remaining work runs as <N> waves. This table is the loop's authority on what may run
concurrently: phases on one row start together (up to `MAX_PARALLEL`), and a phase listed in
no row runs alone. It doubles as the plan for attended parallel terminals.

| Wave | Run together |
|---|---|
| 1 | <phases> |

**Sequential spine:** <P1 → P2 → …, the strict must-finish-before chain>

**Blocking rules, with reasons:**
- <X> before <Y> — both edit <Z>.
- Only one <shared-artifact> phase in flight — they all regenerate <artifact> and will fight
  over it.
- <P-risky> runs alone, at the keyboard — <it rewrites security rules / auth / payments /
  a core engine>.

## Gates by repo

| Repo | Commands |
|---|---|
| <repo> | `<exact commands>` <environment caveats discovered in the grill> |

---

## <P-ID> — <Phase name>

```
Read docs/features/<feature>/plan.md §<X><, and §<Y> for context>. Execute phase <P-ID> in the
<repo> repo<; also work across <other repo paths> — the runner already grants write access
to them; in an interactive session add them yourself (Claude Code: /add-dir)>. Set the <P-ID> row in
docs/features/<feature>/status.md to in-progress before starting.

<The scope, written as numbered directives with the plan's exact file paths and shapes. Pull
the sharp constraints out of the plan and restate them here — the session should not need to
infer anything that matters. Include the "do NOT" items explicitly: deliberate omissions from
the plan's decisions that a helpful session might otherwise add back.>

Use the names in docs/CONTEXT.md and plan.md verbatim — identifiers, labels, columns; never
rename a concept or contradict an ADR (a new architectural decision goes to status.md
Deferred). Test this phase through its seam: <the phase's named seam from plan.md>, imitating
the pattern in <prior-art test file> — do not invent a new testing style.

Keep every file under 1000 lines — split rather than grow<; note any already-oversized files
this phase may touch by name>. New code lives under <feature folder path> with its own
hooks/components/functions subfolders. Never edit plan.md — if the plan is wrong, log it in
status.md Deferred and stop.

Before marking this phase done: (1) re-read plan §<X> and confirm each claim it makes against
what you actually built — above all the phase's demoable outcome: "<the outcome from
plan.md>" must actually be achievable, and your progress-log entry states it with one line of
evidence; code that exists without the outcome being demoable is qa-pending, not done. Fix
any gap or mark the phase qa-pending with the gap named;
(2) run the gates: <exact commands for this phase's repos> — a failed gate means the phase is
not done; (3) check this phase's diff only: no file over 1000 lines, no code outside the
feature folder, nothing committed, plan.md untouched. Then apply the full status update
contract from the top of this doc and save git diff > .patches/<P-ID>-<repo>.patch per repo
touched. Suggest a commit message per repo. NEVER git commit, push, or deploy.
```

<...one block per phase. At-keyboard-only phases additionally open with: "This is a
supervised phase — the owner is at the keyboard. Stop and ask before <the risky act>. Nothing
else should be in flight." and, where a D-ID gates them: "Stop and ask if plan.md's Decision
record <D-ID> is unanswered.">

---

## AUDIT — did the plan actually get followed?

Read-only. Run after any phase, before any commit, or whenever you want to know where things
really stand. It **reports and never fixes** — a session that repairs what it audits destroys
the evidence of what was actually wrong.

```
Audit the <feature> work. This is a READ-ONLY verification pass: report findings, never fix
them, never edit code, never commit, never deploy, never run a migration or seed script. The
only commands you may run are read-only inspections and the repos' own build/lint/test gates.

Start in <primary repo path>; also work across: <other repo paths> (already granted in an
unattended run; in an interactive session add them yourself, e.g. Claude Code /add-dir).

Read docs/features/<feature>/plan.md, prompts.md and status.md in full. TREAT THE PLAN AND
STATUS AS CLAIMS TO BE TESTED, NOT AS TRUTH. A `done` row is a claim that something was
built; your job is to find the evidence in the code or contradict it.

PART 1 — Plan fidelity. For every done/qa-pending row in status.md: confirm the files the
plan's phase breakdown expects exist and contain what the scope claims, and test the phase's
stated demoable outcome — a done row whose outcome cannot actually be demonstrated is your
finding, whatever the progress log says. Flag rows where the claim overstates the code. Re-run every gate marked ✅ and report any that no longer passes:
<gates by repo>.

PART 2 — <Shared-artifact integrity, if the project has one: regenerate and diff the
contract/codegen, confirm downstream copies match. A downstream copy silently behind the
source is the most likely silent defect — check it properly, do not eyeball it.>

PART 3 — Decisions honoured. For each row in plan §1 and each answered Decision record item,
find the code that implements it and confirm it matches, or report it as
unimplemented/contradicted. For decisions belonging to unbuilt phases say "not yet due
(phase <P-ID>)" rather than flagging a failure.

PART 4 — Invariants:
  a) Every file under 1000 lines — list violations in all repos, marking pre-existing vs new.
  b) All new code inside the feature folder — list leaks.
  e) Vocabulary and ADRs honoured — new code uses docs/CONTEXT.md's and the plan's names
     verbatim (flag renamed or duplicated concepts — two names for one entity is the finding),
     and no ADR is contradicted. New tests go through the plan's named seams, imitating the
     prior art — flag phases that invented a new testing style.
  c) <Project-specific invariants from the grill — privileged-write rules, audit-log
     requirements, security-rule posture, payment guarantees. These are the things that break
     silently and are the real reason for this audit.>
  d) No commits were made; .patches/ holds a patch per completed phase per repo.

PART 5 — What is incomplete. Every non-done phase, every open Deferred item, every TODO/FIXME
this feature added. Separately: anything you consider risky, under-specified, or likely to
bite later — your own judgement, not just what the docs say. Rank by severity; say "nothing"
rather than padding.

PART 6 — OWNER ACTIONS. The most important output. Everything that needs a human, because
neither of us will deploy, commit, or touch production. Split into: NOW-BLOCKING ·
BEFORE-DEPLOY · COMMITS (per repo: dirty file count, suggested grouping and messages — do not
commit) · LATER. Give the exact copy-pasteable command where one exists, and say plainly what
breaks if it is skipped.

Write the full report to docs/features/<feature>/audit-<today's date>.md and give a short
prioritised summary in chat — worst finding first. Do NOT edit plan.md or status.md; if
either is wrong, say so in the report and let the owner decide.
```

### When to run it

- After any phase, before you commit that phase
- Before any at-keyboard phase — it deserves a known-clean baseline
- Before any deploy, as the pre-flight
- After an unattended `loop.sh` run the loop runs it for you — read it first thing

---

## After every session

The agent leaves the working tree dirty on purpose. You review, then commit and deploy
yourself. Every prompt ends by suggesting commit messages per repo.

---

## Unattended run — start to audit, without you

The runner is [`loop.sh`](loop.sh) in this folder — agent-agnostic, one **fresh headless
process per phase** (`claude -p` / `codex exec` / `kimi -p`), so every phase starts with
completely clean context regardless of which agent runs it. Keep the machine awake (macOS:
`caffeinate -dimsu` in a spare terminal) — nothing is committed or pushed, so a cloud agent
has no repo to work from.

<If any Decision record item blocks early phases: "Answer <D-IDs> before starting. Without
them those phases run against a placeholder and end qa-pending.">

```
cd docs/features/<feature>
./loop.sh --preflight      # read-only: what will run, in what order, and what only you can do
AGENT=claude ./loop.sh     # or AGENT=codex, AGENT=kimi
```

**The run goes A → Z and does not stop to ask you anything.**

- A phase whose agent ends it `qa-pending` counts as **complete**: dependents proceed and the
  gap becomes a line in `QA.md` (`STRICT_DEPS=1` if you want only `done` to satisfy deps).
- At-keyboard phases are **attempted** anyway, alone, with a notice telling the agent no human
  is present: it builds everything that needs no human hand, refuses anything irreversible,
  and ends `qa-pending` with your remaining steps in Notes. `AT_KEYBOARD_MODE=defer` routes
  around them instead.
- Only a `> HUMAN-ONLY: <reason>` line under a phase heading stops the loop attempting a phase.
- Phases stranded behind work that failed are swept forward once with a degraded-dependency
  notice, so one bad phase cannot hold the feature hostage.
- `> GATE:` commands are run **by the loop**, never trusted to the agent; a red gate revokes
  the `done` claim, retries once with the failure output as evidence, then records a defect.
- Every ending — clean or not — runs the AUDIT in a fresh process and writes **`QA.md`**: your
  tickable list in four sections (verify these · defects the loop could not clear · only you
  can do these · done and gate-verified). `.runinfo` records COMPLETE or INCOMPLETE.

Before the first unattended run, check the headless flags for your agent version — the process
must be allowed to edit files and run the gates, and nothing more. The runner's adapters
already do this: Claude Code gets `--permission-mode acceptEdits --allowedTools Bash` with
`git commit`/`git push` denied at tool level; Codex gets `--sandbox workspace-write` with
`approval_policy=never`. Extra repos are passed as `--add-dir` to both.

**Optional, Claude Code only** — if you would rather stay inside one interactive session, the
`/loop` orchestrator prompt is the same contract with subagents instead of processes. It is a
convenience, not the supported path: it cannot run gates outside the agent, and it has no
watchdog. Prefer `loop.sh`.

### Why it goes forward rather than stopping

No commits means no rollback boundaries beyond the per-phase `.patch` files — so nothing is
ever built silently on a failed phase: a stranded phase is told exactly which dependency is
missing and is asked to cross the gap with the smallest honest placeholder and end
`qa-pending`. Better to come back to a feature that is 90% built with a precise ten-item test
list than to three good phases and a loop that died at 1am waiting for a human who was asleep.

### On return

Read the audit report first — worst finding first — then status.md's Deferred (where a
stopped run explains itself), then review each repo's diff and commit per the suggested
messages.
````
