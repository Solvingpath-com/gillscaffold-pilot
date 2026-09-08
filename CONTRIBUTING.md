# Contributing

## The one rule

`skills/loop-pilot/references/loop-template.md` is the **canonical runner**. grillscaffold's
copy is generated from it and must be byte-identical. Edit the loop-pilot copy, then:

```bash
scripts/sync-templates.sh
scripts/check-versions.sh
tests/run-all.sh
```

CI fails the build if the two copies drift, so this is not optional.

## Versioning

Four numbers move together and are checked by `scripts/check-versions.sh`:

| where | what it means |
|---|---|
| `VERSION` and `release-manifest.json.release` | the bundle release, e.g. `8.2.0` |
| `skills/grillscaffold/SKILL.md` `version:` | grillscaffold's own semver |
| `skills/loop-pilot/SKILL.md` `version:` | loop-pilot's own semver |
| `# template-version:` in the runner | the runner **contract** version, an integer |

Rules of thumb:

- **Bump the template version only when the contract changes** — the meaning of a state, when
  a phase may be dispatched, what an ending writes. Adapters, wording and bug fixes do not
  change the contract, so they do not bump it. `upgrade.sh` picks the highest template version
  it can find, so the number must only ever go up.
- Contract change → **major** bundle bump, because existing features get a new runner.
- New capability, same contract → **minor**. Fixes and docs → **patch**.
- Every release needs a `## <version>` section in `CHANGELOG.md`; the version gate checks it.

The GitHub slug lives in exactly one place per file and is kept consistent by
`scripts/set-github-repo.sh <owner/repo>`. Never hand-edit it.

## Release contract

A release is a tag, an archive, and a checksum. Nothing else is published.

1. Land your changes; make sure `tests/run-all.sh` is green locally.
2. Update `VERSION`, `release-manifest.json`, both `SKILL.md` `version:` fields, and
   `CHANGELOG.md`. Run `scripts/check-versions.sh` until it is clean.
3. Build and test the artifact exactly as a user would receive it:
   ```bash
   scripts/package-release.sh
   ./install.sh --from dist/grillscaffold-loop-pilot.tar.gz --dry-run
   ```
4. Commit, then tag with a leading `v`: `git tag v8.2.0 && git push --tags`.
5. `.github/workflows/release.yml` refuses the tag if it does not match `VERSION`, then runs
   the suites, builds `grillscaffold-loop-pilot.tar.gz` and `SHA256SUMS`, and attaches both to
   the GitHub release. The installer verifies that checksum on every download, so the asset
   names must not change.

Never publish a release whose two `loop-template.md` copies differ, whose tag disagrees with
`VERSION`, or whose suites did not run on both Ubuntu and macOS.

## Tests

- `tests/test-static.sh` — portability (no bash-4-only constructs), consistency, and the
  safety invariants: no sandbox-bypassing flags, `git commit`/`git push` denied, no sudo.
- `tests/test-runner.sh` — whole loops against fake `claude`/`codex`/`kimi` binaries that
  record argv, stdin and environment. This is where the CLI contract is pinned.
- `tests/test-install.sh` — fresh install, upgrade in place, dry run, verify, foreign-skill
  protection, install from the built archive, uninstall.
- `tests/test-upgrade.sh` — old runners becoming current without losing their configuration.

Tests must never invoke a real agent or touch anything outside a temp directory. Sandbox HOMEs
deliberately contain a space; keep it that way.

Run the macOS-shaped suite locally with `BASH_BIN=/bin/bash tests/run-all.sh` on a Mac.

## Style

Shell targets bash 3.2. No `mapfile`, `wait -n`, associative arrays, `${var,,}` or `local -n`.
Guard array expansions with `${#arr[@]}`. Prefer `mkdir` mutexes over `flock`. Quote every path.
