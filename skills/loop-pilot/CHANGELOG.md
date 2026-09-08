# loop-pilot — changelog

## v7 — wave parallelism (2026-08-26)

The gap this closes: grillscaffold has always produced a wave table ("these phases can run
together"), and the unattended runner has always ignored it. prompts.md said so in as many
words — *"waves are for attended parallel terminals; the unattended `loop.sh` ignores waves
and runs one phase per iteration"*. A feature with an eight-phase plan and a three-wide wave
still ran eight phases back to back overnight. Parallelism existed only across features
(`fleet.sh`), never inside one.

### Runner — references/loop-template.md is now **template v3**

- **Scheduler instead of a for-loop.** Up to `MAX_PARALLEL` (default 3) phases in flight.
  Each phase's whole lifecycle — attempt, gate, evidence-fed retry, route-around — runs in a
  background worker; the parent fills free slots as workers finish. Bash 3.2 safe (macOS
  stock bash): no `wait -n`, no associative arrays; reaping is a result-file + `kill -0` /
  zombie-state poll.
- **The wave table decides who may fly together.** Parsed at run time from prompts.md
  ("Order and parallelism") or plan.md ("Concurrency and waves"). Same wave + dependencies
  met + no lane collision = dispatched together. **A phase in no wave row runs alone**, so a
  feature without a table behaves exactly like v2. Waves are barriers: wave 3 does not start
  while a wave-2 phase is still in flight.
- **`> LANE: <name>`** — a new prompts.md contract line beside `> GATE:` and `> OWNER:`.
  At most one phase per lane in flight; `> LANE: solo` runs a phase with nothing beside it.
  This is the machine-readable form of the plan's "only one contract-regenerating phase in
  flight" rule.
- **status.md writes are serialized** by a `mkdir` mutex (portable; macOS has no `flock`)
  held for every `set_state` and log append.
- **Concurrent agents are briefed.** When siblings are in flight, the phase prompt opens
  with a concurrency notice: work only your files, edit only your row, never reformat the
  table, don't run repo-wide builds. Suppressed entirely when `MAX_PARALLEL=1`.
- **Gates are serialized** by a second mutex, and a gate that goes red while siblings were
  in flight is re-run once after `GATE_SETTLE_SEC` before the done claim is revoked — a
  concurrent build is a plausible cause of a false red.
- **Escape hatches:** `PARALLEL_MODE=off` reproduces v2 exactly; `PARALLEL_MODE=deps`
  dispatches on the `Depends on` column alone (lanes still honoured) for features whose wave
  table is missing or wrong.
- `./loop.sh --preflight` (and `--plan`) print the dispatch plan.

### Scripts

- **`waves.sh` (new)** — prints the dispatch plan for a feature from its own files: what
  starts together, which lanes narrow a wave, which phases are in no wave row, and the
  ceiling (widest wave after lanes collapse it) to pick `MAX_PARALLEL` from. Version
  independent — safe on an un-upgraded scaffold. `--set-lane <P> <lane>` writes a `> LANE:`
  line (backup kept); `--json` feeds the dashboard.
- **`upgrade.sh`** — template selection is now **version-aware**: the highest
  `# template-version:` among the candidates wins (explicit `$GRILLSCAFFOLD_TEMPLATE` still
  overrides outright, an unmarked template counts as v0). loop-pilot's bundled runner
  therefore reaches every feature — including ones scaffolded later by an older
  grillscaffold — while a future grillscaffold runner newer than this one still wins.
- **`launch.sh`** — prints the dispatch plan before takeoff, reports max-parallel and mode
  in the LAUNCHED line, and explains the interleaved log.
- **`fleet.sh`** — defaults `MAX_PARALLEL` to 2 for fleet launches (a fleet is already wide)
  and prints the arithmetic: features x MAX_PARALLEL = agent processes.
- **`status.sh`** — names every phase in flight, not just the first, reads the runner's own
  `.run/inflight`, and reports the runner's template version and parallel width.
- **`scan.sh`** — a feature whose loop is alive reports `[RUNNING]` instead of
  `[NEEDS-OWNER]`; `in-progress` rows under a live loop are normal now.
- **`dashboard.py`** — cards show all in-flight phases.

### Dashboard

- **It starts itself.** `launch.sh` and `fleet.sh start` call the new **`dash.sh ensure`**,
  so http://localhost:8787 is up before phase 1 finishes. Idempotent: it probes the *port*,
  not a pid file, so a dashboard you started by hand is left alone instead of double-started.
  `dash.sh status|start|stop|restart|url [--open]`; `DASHBOARD_PORT` moves it,
  `LOOP_PILOT_NO_DASHBOARD=1` suppresses the auto-start, `LOOP_PILOT_OPEN_DASHBOARD=1` opens
  a browser tab. Stopping the board never touches a loop.
- **Finished runs age off after 7 days.** A card is hidden only when the loop is not alive
  AND every phase is `done` AND nothing in the feature folder has moved for 7 days — so a
  blocked, handed-off or half-finished run never vanishes, however old. The footer names
  what was hidden and links to `/?all=1`. `DASH_HIDE_DONE_AFTER_DAYS` changes the window
  (`0` disables). Nothing is deleted; `scan.sh` still lists everything.
- Finished cards show how long ago they finished.

### Install

- **`install.sh`** ships beside the skill in `loop-pilot-v7.zip`: copies the folder into
  `~/.claude/skills` (or `--dest`, or `--all` for codex/kimi dirs too), restores the exec
  bits a zip loses, backs up an existing install, warns about a python3/claude/timeout gap
  or a conflicting account-synced copy, and syntax-checks every script before declaring
  success. `--dry-run` and `--uninstall` included.

### Known limits

- **status.md remains a shared file.** The loop's own writes are locked; the agents' are
  not — nothing can lock a `claude -p` session. Three layers cover this: the concurrency
  notice in the prompt, the loop's own mutex, and **row repair** (the loop restores any
  `done` it confirmed that a concurrent session later overwrote). Verified in simulation:
  with four concurrent agents each rewriting the ENTIRE table from a deliberately stale
  read, the un-repaired runner stranded two phases at `in-progress` and never reached the
  audit; with repair on, the same run finished 6/6 and wrote the audit, at a cost of four
  "repaired Pn" log lines. What repair cannot recover is an agent that mangles the table's
  *structure* — that is why the notice says never to reformat it.
- **One working tree.** Parallel phases share the repo, which is exactly what the wave table
  has always meant (it was written for two attended terminals). Phases that fight over files
  need a lane, or a different wave.
- **grillscaffold is unchanged.** It still emits a v2 runner and prose that says the loop
  ignores waves; loop-pilot upgrades that runner on first engagement. A companion
  grillscaffold patch (emit `> LANE:` lines during the grill, drop the stale sentence) is
  the natural follow-up.

## v6 and earlier

Not tracked in this file. Highlights, for orientation: status.sh liveness verdicts, watch.sh
blocking watcher, dashboard.py with heartbeat, self-maintaining repo registry, per-phase
watchdog with self-heal retries, deterministic `> GATE:` verification, Telegram/webhook
notifications, and fleet.sh with the shared rate-limit brake.

## 8.2.0 — 2026-09-08

Released as part of the grillscaffold + loop-pilot bundle 8.2.0. Runner template v5 (one
orchestration contract, thin Claude/Codex/Kimi adapters), new `agents.sh` / `doctor.sh` /
`update.sh` / `render-loop.py`, rewritten `upgrade.sh`, A→Z verdicts in `status.sh`/`scan.sh`
and a tickable QA panel in the dashboard. Full detail in the repository's root CHANGELOG.md.
