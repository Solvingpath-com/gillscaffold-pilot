# grillscaffold + loop-pilot

Two skills that turn a fuzzy feature idea into a plan, a set of self-contained phase prompts,
and an unattended runner that executes them **start to finish without stopping to ask you
anything** — then hands you a tickable QA list.

- **grillscaffold** interviews you until every decision is locked, then writes
  `docs/features/<feature>/` — `plan.md`, `prompts.md`, `status.md`, `loop.sh`.
- **loop-pilot** flies those features: scan, preflight, launch, watch, upgrade old runners.

Each phase runs in a **fresh headless process** of whichever agent you choose — Claude Code,
Codex, or Kimi — so no context leaks between phases. One orchestration contract, thin agent
adapters: `AGENT=claude ./loop.sh` and `AGENT=codex ./loop.sh` do exactly the same thing.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/Solvingpath-com/gillscaffold-pilot/main/install.sh | bash
```

That installs both skills for every agent it supports. Then:

```bash
~/.claude/skills/loop-pilot/scripts/doctor.sh     # is this machine able to fly a loop?
```

Ask your agent *"grill me on <feature>"*, answer the questions, and you get a feature folder.
Then read the plan before spending tokens, and fly it:

```bash
cd <repo>/docs/features/<feature>
./loop.sh --preflight       # read-only: what runs, in what order, what only you can do
AGENT=claude ./loop.sh      # or AGENT=codex
```

## Install

| | command |
|---|---|
| both agents (default) | `curl -fsSL .../install.sh \| bash` |
| Claude Code only | `curl -fsSL .../install.sh \| bash -s -- --claude` |
| Codex only | `curl -fsSL .../install.sh \| bash -s -- --codex` |
| a specific release | `curl -fsSL .../install.sh \| bash -s -- --version v8.2.0` |
| from a local checkout | `./install.sh --all` |
| see what it would do | `./install.sh --dry-run` |
| check an install | `./install.sh --verify` |
| update later | `~/.claude/skills/loop-pilot/scripts/update.sh` |
| remove | `./uninstall.sh --all` |

Skills land in `~/.claude/skills/` for Claude Code and `~/.agents/skills/` for Codex (Codex's
official user-skills directory; if you have an older copy in `~/.codex/skills`, the installer
tells you, and `./uninstall.sh --legacy-codex` removes it). No sudo, ever. Re-running the
installer is safe: it backs up whatever it replaces into `.loop-pilot-backups/`, stages the
new copy, and swaps it in one move — a failed install rolls back to what you had.

Downloads from GitHub releases are checksum-verified against the published `SHA256SUMS`.

**Prerequisites:** bash (macOS's stock 3.2 is fine), python3, git, and at least one agent CLI,
authenticated — `claude auth login` or `codex login`. `doctor.sh` checks all of it.

## What the run actually does

The runner goes **A → Z**. It does not stop for a human, and it never commits, pushes or deploys.

| | behaviour |
|---|---|
| `qa-pending` | a **completion** state: dependents proceed, the gap becomes a QA.md line (`STRICT_DEPS=1` to require `done`) |
| at-keyboard phase | **attempted** alone, told no human is present; builds what it can, refuses anything irreversible, ends `qa-pending` (`AT_KEYBOARD_MODE=defer` routes around it) |
| `> HUMAN-ONLY: <reason>` | the only hard brake — never attempted, lands in QA.md section 3 |
| a phase fails | retried once with the failure output as evidence, then recorded as a defect |
| dependents of a failure | swept forward once with a degraded-dependency notice (`FORCE_FORWARD=0` to opt out) |
| `> GATE: <cmd>` | run **by the loop**, not the agent; red revokes the `done` claim |
| every ending | AUDIT in a fresh process + `QA.md` (verify these · defects · only you can do these · done and gate-verified) + `.runinfo` recording COMPLETE or INCOMPLETE |

Parallelism comes from the plan's wave table: phases on one row run together, up to
`MAX_PARALLEL` (default 3); a phase in no row runs alone. `> LANE: <name>` keeps phases that
share a scarce resource (an emulator, a preview deploy) from overlapping.

## Everyday commands

```bash
loop-pilot/scripts/scan.sh                  # every feature, and what it needs from you
loop-pilot/scripts/launch.sh <fdir> codex   # start detached, with log + pid
loop-pilot/scripts/status.sh <fdir>         # alive, or stopped and why
loop-pilot/scripts/watch.sh  <fdir>         # block until it ends, then notify
loop-pilot/scripts/dash.sh   ensure         # browser dashboard, with a tickable QA panel
loop-pilot/scripts/fleet.sh  start          # fly every unfinished feature, shared rate-limit brake
loop-pilot/scripts/upgrade.sh <fdir>        # bring an old feature's loop.sh up to the current contract
loop-pilot/scripts/agents.sh                # which agents are installed and authenticated
loop-pilot/scripts/doctor.sh --smoke codex  # one real tiny phase, end to end (spends tokens)
```

Useful environment variables: `MAX_PARALLEL`, `PARALLEL_MODE=waves|deps|off`, `STRICT_DEPS`,
`AT_KEYBOARD_MODE`, `FORCE_FORWARD`, `PHASE_TIMEOUT_SEC`, `MAX_RETRIES`, `LOOP_EPHEMERAL`,
`LOOP_EXTRA_REPOS`, plus per-agent knobs (`CLAUDE_PERMISSION_MODE`, `CODEX_SANDBOX`,
`AGENT_EXTRA_ARGS`, …). `./loop.sh --help` lists them.

## Upgrading an existing feature

Features scaffolded by older versions keep working, and `upgrade.sh` brings their `loop.sh` up
to the current contract in place: it recovers the primary repo, extra repos and at-keyboard
phases from the old script (falling back to `prompts.md` and `plan.md`), backs the old runner
up, syntax-checks the new one, and refuses outright while a loop is running. `launch.sh` does
this automatically rather than flying a runner that would stop and wait for you.

## Development

```bash
tests/run-all.sh              # static checks, runner, installer, upgrade suites
scripts/check-versions.sh     # version/template/slug consistency gate
scripts/sync-templates.sh     # copy the canonical runner into grillscaffold
scripts/package-release.sh    # build dist/ exactly as CI does
scripts/set-github-repo.sh <owner/repo>    # point the whole repo at your fork
```

The tests never call a real agent: fake `claude`/`codex`/`kimi` binaries record the argv,
stdin and environment they were handed, so the suite asserts the actual CLI contract. CI runs
them on Ubuntu and macOS. Release process and versioning rules are in
[CONTRIBUTING.md](CONTRIBUTING.md).

## Layout

```
install.sh  uninstall.sh  VERSION  release-manifest.json
skills/grillscaffold/     SKILL.md, references/ (plan, prompts, status, loop templates)
skills/loop-pilot/        SKILL.md, references/loop-template.md, scripts/
scripts/                  maintainer tooling
tests/                    suites + fake agent fixtures
.github/workflows/        test.yml (ubuntu+macos), release.yml (tags)
```
