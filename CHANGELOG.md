# Changelog

This file is the canonical history for the bundle. Each skill also keeps its own
`CHANGELOG.md` for skill-specific detail; entries there point back here.

## 8.2.0 — 2026-09-08

Packaged for distribution, and the runner became genuinely agent-neutral.

**Added**
- `install.sh` — idempotent, no-sudo installer for Claude Code (`~/.claude/skills`) and Codex
  (`~/.agents/skills`). Works from a checkout, a release archive, or piped from curl; verifies
  release checksums; stages and swaps atomically with rollback; backs up what it replaces;
  refuses to touch a directory it does not own. `--dry-run` and `--verify` included.
- `uninstall.sh`, with `--legacy-codex` for old `~/.codex/skills` copies and `--purge-state`.
- `loop-pilot/scripts/agents.sh`, `doctor.sh` (with opt-in `--smoke <agent>` real-agent test),
  `update.sh`, and `render-loop.py` — the single renderer shared by grillscaffold and upgrade.
- Test suites (static, runner, installer, upgrade) driven by fake agent binaries that record
  argv, stdin and environment; GitHub Actions on Ubuntu and macOS; tagged release workflow.
- `release-manifest.json`, `VERSION`, and `scripts/check-versions.sh` enforcing that the two
  skills, the runner template and the docs never disagree.

**Changed**
- Runner **template v5**: one orchestration contract with thin adapters. An adapter now owns
  exactly five things — invocation, prompt transport, working directory, write permissions,
  extra repo roots — and nothing else is agent-specific. Claude Code gets `--permission-mode
  acceptEdits --allowedTools Bash` with `git commit`/`git push` denied at tool level and
  `--permission-prompts none` only when the installed version supports it; Codex gets
  `codex exec --sandbox workspace-write -c approval_policy=never` with the prompt on stdin.
  Extra repos are `--add-dir` on both.
- `--preflight` is provably side-effect-free and now runs before any state is touched (the v3
  template deleted its own run directory before parsing arguments).
- `upgrade.sh` renders through the shared renderer, recovers `EXTRA_REPOS` from the old script
  or `prompts.md`/`plan.md`, reports CURRENT / OUTDATED-minor / OUTDATED-contract / MISSING,
  and refuses to write while a run is alive.
- `status.sh`, `scan.sh`, `launch.sh` and the dashboard speak the A→Z contract: COMPLETE /
  INCOMPLETE from `.runinfo`, QA-READY / NEEDS-FIX verdicts, and a QA panel that ticks
  checkboxes back into `QA.md`. The word "handoff" is gone from the tooling.
- Templates are agent-neutral: prompts say "fresh coding-agent session", the wave table is
  documented as the loop's authority, and the Claude-Code-only `/loop` orchestrator is marked
  optional. `status.md` now states that `qa-pending` satisfies dependencies unless
  `STRICT_DEPS=1`; `plan.md` explains that at-keyboard phases are attempted, and that
  `> HUMAN-ONLY:` is the only hard brake.

**Fixed**
- Paths containing spaces, apostrophes or `$` render and execute correctly everywhere
  (renderer quoting, argv arrays, installer with a `$HOME` that has a space).
- The runner no longer relies on bash 4 features; macOS stock bash 3.2 is a supported target
  and is tested in CI.

## Earlier

grillscaffold 3.x and loop-pilot v1–v8 were distributed by hand and have no tagged releases.
Their per-skill changelogs are kept in `skills/*/CHANGELOG.md`.
