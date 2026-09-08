---
name: loop-pilot
version: 8.2.0
description: Execution-time companion to grillscaffold. Use when the user wants to start, resume, or check on unattended feature runs — trigger on "start the loop", "run the loop", "resume the loop", "which loops didn't finish", "check my runs", "what's pending in my features", "pilot", "what do I need to test", "where's my QA list", or when the user mentions a stopped or blocked loop.sh run. It scans repos for every grillscaffold feature and reports run state, then walks the owner through pre-run items one at a time — each with a what-and-why briefing plus a paste-ready command when scriptable, verifying completion rather than trusting it — and once everything is clear it launches the loop itself, detached with a log, running independent phases concurrently where the plan's wave table sanctions it. Runs go A→Z without stopping and end in a tickable QA.md test list. Do NOT use for planning or scaffolding a new feature — that is grillscaffold's job; this skill only flies loops that grillscaffold already scaffolded.
---

# loop-pilot

Grillscaffold plans; loop-pilot flies. This skill operates on already-scaffolded features —
`docs/features/<feature>/` folders containing `plan.md`, `prompts.md`, `status.md`, `loop.sh` —
and does three jobs:

1. **Scan** — find every feature across the user's repos and report which runs are
   unfinished, and why.
2. **Clear for takeoff** — before starting or resuming a loop, verify item by item that
   everything a human must do is actually done, fixing blocked rows along the way.
3. **Launch / hand over** — start the run correctly, or hand the user the exact command.

Since template v3 the runner flies **several phases at once** when the plan says they are
independent. loop-pilot's job there is to show the owner the dispatch plan before takeoff and
to name what is in flight afterwards — never to invent parallelism the plan did not sanction.

**Since template v4 the run does not stop.** `qa-pending` is a completion state, not a brake:
it satisfies dependents and becomes a line in `QA.md`. At-keyboard phases are attempted rather
than skipped. Phases stranded behind a failed dependency are swept forward with a
degraded-dependency notice. Every run — clean or not — ends with the AUDIT and a tickable
`QA.md`. There is no handoff-and-rerun ending any more, so the question loop-pilot answers
after a run is never "what do I have to clear before it can finish" but "what do I have to
test now that it has".

State always lives in the feature folder (`status.md`, `QA.md`, `.runinfo`) — never in this skill's
head. loop.sh is stateless and resumes by re-reading `status.md`, so "resume" and "start" are
the same command; loop-pilot's value is making sure that command will get far, not tracking
position.

## Job 1 — Scan ("which loops didn't finish?")

Run `scripts/scan.sh` with the repo roots as arguments, or with none to use the registry
(`~/.loop-pilot/repos.txt`). **The registry maintains itself**: every `launch.sh` run
registers that feature's repo automatically (deduped), so any repo that has ever flown a
loop through loop-pilot is already visible to scan, status, and the dashboard — no setup
step. Manage it with `scripts/repos.sh`:

```
repos.sh list            numbered entries, each with health: OK (n features, m running),
                         NO-FEATURES, or MISSING (directory gone)
repos.sh add <repo>      register manually (e.g. a repo whose loops run outside launch.sh)
repos.sh remove <n|path> remove one entry — always confirms first (--yes to skip)
repos.sh prune           walk dead entries one at a time, confirm each removal
```

When a scan or dashboard session surfaces MISSING or NO-FEATURES entries, offer a prune —
present each candidate with its reason and get a yes/no per entry (`--yes` only when the
user says remove all). Removal only edits the registry; the repo itself is never touched.
If invoked inside a repo, scanning just that repo is a fine default; ask before scanning
wider.

The script prints one entry per feature:

- `[RUNNING]` — a live loop
- `[QA-READY]` — the run ended and `QA.md` has unticked boxes: the owner's test list is waiting
- `[NEEDS-FIX]` — blocked or silent in-progress rows: real defects, listed in QA.md section 2
- `[FINISHED]` — every phase settled (`done` or `qa-pending`) and nothing left to tick
- `[RESUMABLE]` — partial progress, nothing wrong: a rerun will continue
- `[NOT-STARTED]` — scaffolded, never run

Present the results worst first: NEEDS-FIX, then QA-READY, then RESUMABLE, then NOT-STARTED.
For each one, read `QA.md` (the run's own summary of what it left for a human) and the tail of
`status.md`'s progress log, and say in one line what is actually wanted — "P3's gate is still
red; 4 boxes to tick, two of them on the payments screen" beats "2 phases pending". QA-READY
is not a failure state: it is the normal, successful ending of a v4 run. FINISHED features are
one summary line unless asked.

## Job 2 — Clear for takeoff (before any start or resume)

When the user picks a feature to run, do NOT just launch. Work through this sequence, and
where the grill answer style applies — one item at a time, with a recommendation:

1. **Read the state.** `status.md` phase table, `QA.md` if a previous run left one (and
   `handoff.md` on a feature that last flew a pre-v4 runner), and the `> OWNER:` /
   `> HUMAN-ONLY:` lines in `prompts.md` for every supervised phase whose deps are (or will
   soon be) met.
2. **Resolve broken rows first — and know which rows are actually broken.** A `qa-pending`
   row is NOT broken: under the v4 contract it is finished work waiting on the owner's eyes,
   it satisfies dependents, and a rerun will not redo it. For each one, ask only "have you
   verified this since?" — yes → mark `done`; not yet → leave it, and carry it into QA.md.
   For each genuinely `blocked` row, or a stale `in-progress` row: show its Notes cell and
   last log lines, then ask — *fixed already → mark done*, *let a fresh session retry → mark
   todo*, or *leave it → it stays a QA.md defect*. Update `status.md` yourself when the user
   decides. A stale `in-progress` row with no live session is always reset (to `todo` or
   `blocked`), never left — the loop treats silent in-progress as poison.
3. **Walk the owner checklist item by item — briefing + script for each.** For each
   `> OWNER:` line on upcoming supervised phases and each unticked box in a previous run's
   `QA.md` (or handoff.md section 1 on a pre-v4 feature),
   present one item at a time in this exact shape:
   - **What & why** — two sentences max: what the task is, and what breaks if it's skipped
     ("Export a Firestore backup — P3 rewrites security rules and this backup is the only
     rollback if they lock everyone out").
   - **Paste-ready command** — if the item is scriptable, generate the exact command block
     for the user's real paths, project IDs, and repo locations (read them from plan.md,
     .firebaserc, package.json — never placeholder-ware). If it's not scriptable (a console
     toggle, a phone approval), give the click-path instead.
   - **Then ask**: "run it for you here, you paste it, or already done?" — and **verify what
     is verifiable** regardless of the answer: backup file exists at the stated path,
     credential env var set, console command succeeds, gate command passes. Only tick items
     you checked or the user explicitly confirmed.
4. **Front-load, then decide what the loop may attempt.** If a whole at-keyboard phase can be
   done now, offer to do it now in this session — that is still the best outcome. For the rest,
   the v4 contract means the loop will *attempt* them unattended and end them `qa-pending`
   rather than skipping them, so go through each at-keyboard phase once with the user and ask
   the only question that matters: **is an unattended attempt safe here?** Code, config, rules
   files and migration scripts: yes, let it attempt. A production console toggle, a live
   payment, a physical device, anything irreversible: no — add
   `> HUMAN-ONLY: <one-line reason>` under that phase's heading in prompts.md and the loop
   will not touch it (it lands in QA.md section 3 instead). This and `> GATE:` / `> LANE:` are
   the only prompts.md edits loop-pilot may make, and like them it needs the user's yes.
5. **Ask what "tested" means, once per phase.** Every `> QA:` line under a phase heading is
   copied verbatim into `QA.md` as a tick box when the run ends. If the phases have none,
   propose one or two per phase from the plan's demoable outcomes ("Open /settlements as a
   garage owner — one real row, correct total") and add them with the user's approval. A run
   that ends with a QA.md full of phase IDs and no instructions is a worse handover than one
   with three concrete things to click.
6. **Environment sanity.** Confirm: the headless agent command works (`claude -p 'say ok'`
   or equivalent for codex/kimi), permission/approval settings allow unattended runs,
   `loop.sh` is executable, and — on a laptop — the machine will stay awake
   (macOS: `caffeinate -dimsu`).
7. **Runner freshness — upgrade automatically, don't ask.** The moment loop-pilot engages
   with a feature (scan hit, preflight, or launch), run
   `scripts/upgrade.sh <feature-dir> --check`. If it reports OUTDATED, run
   `scripts/upgrade.sh <feature-dir>` immediately: it regenerates `loop.sh` from the
   current grillscaffold template while preserving the feature's own config (primary repo
   path, at-keyboard phases — recovered from the old script, or inferred from plan.md /
   prompts.md OWNER sections), keeps a timestamped `loop.sh.bak-*`, stamps a
   `# template-sha:` marker for idempotency, and logs the upgrade to status.md. This is
   what makes old scaffolds autonomous: the oldest runners *exit* on an at-keyboard or
   qa-pending phase, v2/v3 route around them but still end in a handoff the owner must clear,
   and the current v4 template treats qa-pending as completion, sweeps stranded phases
   forward, and always finishes with the audit plus a tickable QA.md. Tell the user it happened in one line — don't ask permission, it is a
   runner swap, never a plan/prompt/state change. The only time upgrade refuses is when
   that feature's loop is currently alive (never swap a runner mid-flight) or the rendered
   script fails `bash -n` (it restores the backup). If at-keyboard phases could not be
   found anywhere, relay the script's warning and confirm the list with the user before
   flying.

8. **Parallel plan — show it, don't assume it.** Run `scripts/waves.sh <feature-dir>`. It
   prints, from the feature's own files, exactly which phases will start together, which
   lanes narrow a wave, which phases are in no wave row (those run alone), and the ceiling —
   the widest wave after lanes collapse it. Relay it in one or two lines ("wave 2 runs P2,
   P3 and P4 together; P5 waits for all three") and pick `MAX_PARALLEL` from the ceiling,
   not from optimism. Three things to watch for and raise with the user:
   - **No wave table** → the feature runs serially, exactly like before. Offer the fix: add
     an "Order and parallelism" table to prompts.md (grillscaffold writes one by default;
     older scaffolds may not have it), or fly it with `PARALLEL_MODE=deps` if the
     `Depends on` column is trustworthy. Do not silently launch `deps` mode — it drops the
     plan's blocking rules, which is precisely what the wave table exists to keep.
   - **A wave that shouldn't be one.** If two phases in one wave obviously touch the same
     files, or both regenerate a shared artifact, propose a `> LANE:` line —
     `scripts/waves.sh <dir> --set-lane P4 generated-client` writes it (backup kept). This
     is the second sanctioned prompts.md edit and, like gates, it needs the user's yes.
   - **Wide fleets.** `fleet.sh` multiplies: features in flight x `MAX_PARALLEL`. Say the
     number out loud before launching a fleet overnight.

Only when every item is ticked is the run clear.

## Job 3 — Launch

When every preflight item is ticked, **start the loop yourself — that is the default, not an
offer.** Run `scripts/launch.sh <feature-dir> <agent>`: it auto-upgrades an old-contract
loop.sh first (see preflight item 6), prints the dispatch plan, registers the repo in
`~/.loop-pilot/repos.txt`, brings the dashboard up if it isn't already (`dash.sh ensure` —
idempotent, never a second server; `LOOP_PILOT_NO_DASHBOARD=1` opts out)
so scan and the dashboard see it from now on, then starts loop.sh detached (`nohup`,
survives this session ending), writes a timestamped log and a pid file, refuses a double-start,
and prints the three commands below. Pass concurrency as environment, not as a flag:
`MAX_PARALLEL=2 scripts/launch.sh <dir> claude` (default 3; `PARALLEL_MODE=off` for the
old one-phase-at-a-time behaviour when a feature has to be watched closely). Relay them verbatim — this block is the entire user
interface to a running loop:

```
watch:   http://localhost:8787               already running — one card per ACTIVE feature
status:  scripts/status.sh <feature-dir>     is it alive, which phase, or how it ended
notify:  scripts/watch.sh  <feature-dir>     blocks until it really stops, then pings
test:    <feature-dir>/QA.md                 written at the end — your tickable test list
stop:    kill <pid>                          safe — a rerun resumes from status.md
```

Give the user the URL first — it is the answer to "is it working?" that costs them nothing.
The dashboard is a viewer, never a controller: closing it, or `scripts/dash.sh stop`, does
not touch a single loop.

**Never end a launch with "ping me when it stops."** The user cannot see when it stops; that
is the single biggest confusion this skill creates. Hand over `watch.sh` (it pings them) or
`status.sh` (they ask any time), and say plainly what the ending will look like — under the v4
contract there is only one shape: the run goes A→Z, writes `audit-<date>.md` and `QA.md`, and
stops. Say roughly when, and say that nothing will be waiting on them mid-run. If defects
remain the ending is reported INCOMPLETE, which means "some boxes in QA.md are fixes, not
checks" — not "it gave up". When phases run in parallel, say what that
buys in plain terms ("wave 2 is three phases wide, so this run should take about the length
of its slowest phase, not the sum of three") — and warn once that the log interleaves: every
line is tagged with its phase, and each phase also has its own file under `logs/`.

Because the launched loop spawns its own fresh headless agent processes, do not babysit it
from this session — confirm from the log's first lines that phase 1 started, then leave it
alone. If the user prefers their own terminal:

```
cd <feature primary repo>
AGENT=<claude|codex|kimi> ./docs/features/<feature>/loop.sh
```

After launch, offer: "when status.sh says it ended, invoke me again and I'll read the audit
and QA.md and walk you through the test list — worst finding first, then the quickest checks."

## Job 4 — "Is it working or did it stop?"

This question has one answer and it is never a guess. Run `scripts/status.sh <feature-dir>`
(no argument scans every launched loop in `~/.loop-pilot/repos.txt`) and report its verdict.
Never infer liveness from log volume, elapsed time, or the phase table alone.

The mental model to teach the user, once, in plain words:

- **The loop is one long-lived process** (`loop.pid`). Alive = working, full stop.
- **It can have several phases in the air at once.** Two or three `in-progress` rows during
  a live run are normal on a v3 runner, not a corrupted table — status.sh names them. Only
  `in-progress` rows with *no live loop* are poison (preflight resets those).
- **Each phase is a fresh agent process it spawns.** During a phase there is *no output* —
  a 10-20 minute silence in `tail -f` is the normal sound of work, not a hang. This is why
  `tail -f` cannot answer the question and `status.sh` can.
- **It does not stop for you any more.** A v4 loop never parks itself waiting on a human
  mid-run: a phase that needs your eyes ends `qa-pending`, dependents carry on, and the need
  is recorded. Silence therefore never means "it is waiting for me".
- **One ending, two flavours:** every run finishes with `audit-<date>.md` and `QA.md`.
  `.runinfo` records the ending as COMPLETE (every phase settled) or INCOMPLETE (defects
  remain — QA.md section 2 names them). EXITED still exists for a killed or crashed process:
  neither file was written, read the log tail. status.sh names which.
- **QA.md is the deliverable, not the audit.** Point the owner there first: it is short, it is
  ordered, and its boxes tick — in any markdown editor or in the dashboard's QA panel.

For continuous visibility there is the dashboard, and since v7 **it starts itself**: every
`launch.sh` and `fleet.sh start` calls `scripts/dash.sh ensure`, so by the time phase 1 is
running the board is already at http://localhost:8787. Manage it with
`scripts/dash.sh status|start|stop|restart|url [--open]` (`DASHBOARD_PORT` to move it,
`LOOP_PILOT_NO_DASHBOARD=1` to suppress the auto-start, `LOOP_PILOT_OPEN_DASHBOARD=1` to
have it open a browser tab). `ensure` checks the port, not a pid file, so a dashboard the
user started by hand is left alone rather than double-started.

**The board shows what is still live or still yours to act on.** A settled run ages off after
**5 days**: a card is hidden only when the loop is not alive AND every phase is settled
(`done` or `qa-pending`) AND nothing in the feature has moved for 5 days — so a blocked or
half-finished run never disappears, no matter how old, and a run whose QA list you are still
working through keeps its card while you touch it. The footer names what was hidden and links
to `/?all=1`, which shows everything; `DASH_HIDE_DONE_AFTER_DAYS` changes the window (`0`
disables hiding). Nothing is deleted — this is a view filter, and `scan.sh` still lists every
feature.

**Every card carries the run's clock**: started at, ended at, and how long it took, read from
the runner's `.runinfo` (older runs fall back to the launch stamp in the log filename and the
log's last write). A live card shows "started 14:02 · running 23m"; a finished one shows
"started 14:02 · ended 15:47 · took 1h45m". The header counts active vs idle.

**And every card with a `QA.md` opens a QA panel** — the checklist rendered with real
checkboxes, and ticking one rewrites the box in the actual `QA.md` file. That is the intended
way to work the list: open the board, tick things off as you test them, and the count on the
card goes down.

The board shows one card per feature across every repo in `~/.loop-pilot/repos.txt`,
refreshing every 5s with verdict, run clock, phase table, progress bar, QA panel, log tail,
and a **heartbeat**: files the agent modified in the repo in the last 3 minutes. This heartbeat is the signal the
log cannot give — `claude -p` prints nothing until a phase ends, so a silent log with fresh
file writes means *working*, and a silent log with zero writes for 30+ minutes means *wedged*.
Cards sort running-first; stopping the dashboard never touches the loops.

Escalate only on real evidence: pid alive, nothing in flight finishing, and the log unmoved for >30 min means a wedged
agent — offer `kill <pid>` and a relaunch, which resumes from `status.md` and loses at most
the current phase.

## Job 5 — Fleet ("run everything")

`scripts/fleet.sh start [agent]` launches every unfinished, not-already-flying feature
across all registered repos CONCURRENTLY (each via launch.sh, so upgrade + registration
happen per feature). `fleet.sh status` shows the pause state plus a scan; `fleet.sh pause
[min]` / `resume` control the shared brake manually.

**Two dimensions of concurrency.** `fleet.sh` widens across features; each v3 loop widens
across phases. Total agent processes = features x `MAX_PARALLEL`, so `fleet.sh start`
defaults `MAX_PARALLEL` to 2 rather than the runner's 3, and prints the arithmetic. Export
`MAX_PARALLEL=1` for a fleet you want deliberately narrow.

**The rate-limit brake:** loops rendered from the current template detect rate/usage-limit
text in their agent output. On a hit, the phase's row is reset to todo (no retry consumed)
and a shared pause file (`~/.loop-pilot/pause`, epoch resume time) is written. Every loop
checks that file before each phase, so ONE loop hitting the cap pauses the WHOLE fleet at
phase boundaries — mid-phase work always finishes — and everything resumes automatically
when the pause expires (`LIMIT_BACKOFF_MIN`, default 30, env-overridable). The pause state
is visible in status.sh, the dashboard banner, and `fleet.sh status`. Never kill loops to
handle a rate limit; the brake exists so nothing is lost.

## The autonomy stack (what the current template does by itself)

Loops rendered from the current template (any feature after its auto-upgrade) run to the end
and self-heal in this order, and loop-pilot should explain failures in these terms:

0. **The A→Z contract.** `qa-pending` satisfies dependents and counts as complete; at-keyboard
   phases are attempted unattended (`AT_KEYBOARD_MODE=defer` opts out) unless marked
   `> HUMAN-ONLY:`; anything stranded behind a failed dependency is swept forward with a
   degraded-dependency notice (`FORCE_FORWARD=0` opts out); the audit runs on every ending and
   `QA.md` is always written. `STRICT_DEPS=1` restores "only `done` satisfies a dependency" for
   a feature where building on unverified work is genuinely unsafe — offer it, don't assume it.

1. **Watchdog** — each attempt runs under `PHASE_TIMEOUT_SEC` (default 45 min). A wedged
   agent is killed, not waited on.
2. **Evidence-fed retry** — timeout, silent session, self-blocked, or failed gate triggers
   ONE fresh retry (`MAX_RETRIES`) whose prompt opens with the failure evidence (log tail,
   gate output, notes cell). Only after retries is a phase routed around.
3. **Gates** — a `> GATE: <shell cmd>` line under a phase heading in prompts.md is run BY
   THE LOOP after the agent claims done; failure revokes the done claim (→ retry). During
   preflight, if autonomous phases lack gates, propose defaults from the repo's stack
   (`npx tsc --noEmit`, `next build`, a targeted test) and add them to prompts.md WITH the
   user's approval — gate lines are the one prompts.md edit loop-pilot may make, and only
   with consent.
4. **Wave parallelism** — up to `MAX_PARALLEL` phases in flight, but only phases the plan's
   wave table places in the same wave, whose dependencies are met, and whose `> LANE:`
   values don't collide. A phase in no wave row runs alone. status.md writes are serialized
   by a lock the loop holds; concurrent agents are told in their prompt to touch only their
   own row and their own files; gates are serialized too, and a gate that goes red while
   siblings were in flight is re-run once after a settle window before the done claim is
   revoked. Explain a parallel failure in these terms before blaming the agent.
5. **Notifications** — endings (COMPLETE/INCOMPLETE, with the QA item count), recorded defects, and fleet pauses
   call `scripts/notify.sh` (Telegram and/or generic JSON webhook, config in
   `~/.loop-pilot/notify.env`). On first engagement, if notify.env is absent, offer the
   two-minute Telegram setup (BotFather token + chat id, then `notify.sh --test`).

**Converting at-keyboard QA phases (still the biggest autonomy win):** under v4 an
at-keyboard phase no longer blocks the run — but it does still end `qa-pending`, which means
work for the owner. Converting it to a gate turns that into work for the machine. Most
at-keyboard phases are device/browser QA, and many convert. For React Native: have an early phase
generate a Maestro flow file as a deliverable, then give the QA phase
`> GATE: maestro test .maestro/<feature>-flow.yaml` and remove it from AT_KEYBOARD. For
Next.js/Firebase: `> GATE: firebase hosting:channel:deploy <feature>` — deploy success
passes the gate and the preview URL lands in the gate log and the QA.md item, turning human QA
into "tap this link". During preflight, actively propose these
conversions for each at-keyboard phase; each conversion is a user decision.

## Guardrails

- Regenerating `loop.sh` via `scripts/upgrade.sh` is sanctioned and automatic — it is a
  runner, not plan content, and a backup is always kept.
- Never edit `plan.md` or `prompts.md` content on a feature's behalf (four exceptions, each
  requiring the user's explicit approval: `> GATE:` lines, `> LANE:` lines via
  `waves.sh --set-lane`, `> QA:` lines, and `> HUMAN-ONLY:` lines) — state changes go to
  `status.md` only, and only with the user's decision.
- **Never let "it never stops" become "it does anything."** The A→Z contract removes the
  loop's ability to pause for a human, which makes `> HUMAN-ONLY:` the only remaining brake.
  Raise it explicitly during preflight for every phase touching production, payments, auth,
  live data, or a physical device, and record the user's answer. An unattended attempt at a
  reversible thing is a QA item; an unattended attempt at an irreversible one is an incident.
- Never treat a `qa-pending` row as a failure, in any report to the user. It is the contract
  working: code complete, verification queued.
- Never mark an owner-checklist item done that was neither verified nor explicitly
  confirmed. A clean preflight that lied is worse than no preflight.
- If the feature folder is missing `loop.sh` or `prompts.md`, this is a scaffolding gap:
  send the user to grillscaffold rather than improvising a runner.
- Never describe a run's state in hedged language ("it should be running", "it may have
  stopped"). Run status.sh and state the verdict, or say you cannot reach the machine.
- Never widen a run beyond what the plan sanctions. `PARALLEL_MODE=deps` and hand-added
  wave rows are the user's call, made with the blocking rules in front of them — parallelism
  the plan did not approve is how two agents end up editing one file with no commits and
  only `.patches/` to fall back on.
- Registry removals (`repos.sh remove`/`prune`) always get a per-entry confirmation from
  the user; additions are automatic and harmless (the registry is a watch list, nothing more).

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
