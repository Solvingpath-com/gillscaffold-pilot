#!/usr/bin/env bash
# grillscaffold + loop-pilot installer.
#
# Local:   ./install.sh [--all|--claude|--codex] [--dry-run] [--verify] [--from <dir|archive>]
# Remote:  curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/install.sh | bash
#          curl -fsSL .../install.sh | bash -s -- --codex --version v8.2.0
#
# Targets (user scope, no sudo, ever):
#   Claude Code  ~/.claude/skills/{grillscaffold,loop-pilot}
#   Codex        ~/.agents/skills/{grillscaffold,loop-pilot}     (official location)
#
# Properties: idempotent (re-running is a no-op or a clean upgrade), atomic per skill (staged
# then swapped, rolled back on failure), backs up whatever it replaces, never deletes a skill
# it does not own, and works with spaces in $HOME.
set -uo pipefail

DEFAULT_REPO="OWNER/REPO"          # ← the single source of truth for the GitHub slug
GITHUB_REPO="${LOOP_PILOT_REPO:-$DEFAULT_REPO}"
ASSET="grillscaffold-loop-pilot.tar.gz"

WANT_CLAUDE=0; WANT_CODEX=0; DRY=0; VERIFY_ONLY=0; FROM=""; VERSION_TAG=""; QUIET=0
say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
step() { say "→ $*"; }

usage() {
  cat <<EOF
grillscaffold + loop-pilot installer

  --all            install for every supported agent (default)
  --claude         install only into ~/.claude/skills
  --codex          install only into ~/.agents/skills
  --from <path>    install from a local checkout or a release archive instead of GitHub
  --version <tag>  install a specific published release (e.g. v8.2.0); default: latest
  --dry-run        print exactly what would change, touch nothing
  --verify         check an existing installation and exit
  --quiet          only errors
  -h, --help       this text

Environment: LOOP_PILOT_REPO=owner/repo   LOOP_PILOT_REF=<branch>   (branch installs skip checksums)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --all) WANT_CLAUDE=1; WANT_CODEX=1 ;;
    --claude) WANT_CLAUDE=1 ;;
    --codex) WANT_CODEX=1 ;;
    --from) FROM="${2:?--from needs a path}"; shift ;;
    --version) VERSION_TAG="${2:?--version needs a tag}"; shift ;;
    --dry-run) DRY=1 ;;
    --verify) VERIFY_ONLY=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done
[ "$WANT_CLAUDE" = 0 ] && [ "$WANT_CODEX" = 0 ] && { WANT_CLAUDE=1; WANT_CODEX=1; }

CLAUDE_DIR="$HOME/.claude/skills"
CODEX_DIR="$HOME/.agents/skills"
LEGACY_CODEX_DIR="$HOME/.codex/skills"
SKILLS="grillscaffold loop-pilot"

# ── locate the source tree ───────────────────────────────────────────────────
SELF_DIR=""
case "${BASH_SOURCE[0]:-}" in
  ''|bash|-*) : ;;                                        # piped from curl: no file on disk
  *) SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" ;;
esac
TMPROOT=""; cleanup() { [ -n "$TMPROOT" ] && rm -rf "$TMPROOT"; }; trap cleanup EXIT

fetch_release() {  # downloads + verifies the release archive, echoes the extracted dir
  command -v curl >/dev/null 2>&1 || die "curl is required to install from GitHub"
  command -v tar  >/dev/null 2>&1 || die "tar is required to install from GitHub"
  TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/gs-lp-install.XXXXXX")"
  local base url sums
  if [ -n "${LOOP_PILOT_REF:-}" ]; then
    step "fetching branch $LOOP_PILOT_REF of $GITHUB_REPO (no checksum available for branch installs)"
    curl -fsSL "https://codeload.github.com/$GITHUB_REPO/tar.gz/refs/heads/$LOOP_PILOT_REF" -o "$TMPROOT/src.tar.gz" \
      || die "could not download branch $LOOP_PILOT_REF from $GITHUB_REPO"
    tar -xzf "$TMPROOT/src.tar.gz" -C "$TMPROOT" || die "archive did not extract"
    printf '%s\n' "$(find "$TMPROOT" -maxdepth 1 -type d -name '*-*' | head -1)"; return
  fi
  if [ -n "$VERSION_TAG" ]; then base="https://github.com/$GITHUB_REPO/releases/download/$VERSION_TAG"
  else base="https://github.com/$GITHUB_REPO/releases/latest/download"; fi
  url="$base/$ASSET"; sums="$base/SHA256SUMS"
  step "downloading ${VERSION_TAG:-latest} from $GITHUB_REPO"
  curl -fsSL "$url" -o "$TMPROOT/$ASSET" || die "could not download $url"
  if curl -fsSL "$sums" -o "$TMPROOT/SHA256SUMS" 2>/dev/null; then
    local want have
    want="$(awk -v a="$ASSET" '$2 ~ a {print $1; exit}' "$TMPROOT/SHA256SUMS")"
    have="$(shasum -a 256 "$TMPROOT/$ASSET" 2>/dev/null | awk '{print $1}')"
    [ -z "$have" ] && have="$(sha256sum "$TMPROOT/$ASSET" | awk '{print $1}')"
    [ -n "$want" ] || die "SHA256SUMS has no entry for $ASSET"
    [ "$want" = "$have" ] || die "checksum mismatch for $ASSET (expected $want, got $have) — refusing to install"
    step "checksum verified"
  else
    say "  ⚠ no SHA256SUMS published for this release — continuing without checksum verification"
  fi
  mkdir -p "$TMPROOT/x"; tar -xzf "$TMPROOT/$ASSET" -C "$TMPROOT/x" || die "archive did not extract"
  if [ -d "$TMPROOT/x/skills" ]; then printf '%s\n' "$TMPROOT/x"
  else printf '%s\n' "$(find "$TMPROOT/x" -maxdepth 1 -mindepth 1 -type d | head -1)"; fi
}

SRC=""
if [ -n "$FROM" ]; then
  if [ -d "$FROM" ]; then SRC="$(cd "$FROM" && pwd)"
  elif [ -f "$FROM" ]; then
    TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/gs-lp-install.XXXXXX")"; mkdir -p "$TMPROOT/x"
    tar -xzf "$FROM" -C "$TMPROOT/x" || die "could not extract $FROM"
    if [ -d "$TMPROOT/x/skills" ]; then SRC="$TMPROOT/x"; else SRC="$(find "$TMPROOT/x" -maxdepth 1 -mindepth 1 -type d | head -1)"; fi
  else die "--from path not found: $FROM"; fi
elif [ -n "$SELF_DIR" ] && [ -d "$SELF_DIR/skills/loop-pilot" ]; then
  SRC="$SELF_DIR"                                          # running from a checkout or an archive
elif [ "$VERIFY_ONLY" = 1 ]; then SRC=""
else SRC="$(fetch_release)"; fi

if [ "$VERIFY_ONLY" != 1 ]; then
  [ -n "$SRC" ] && [ -d "$SRC/skills" ] || die "no source tree found (looked in ${FROM:-$SELF_DIR}${SRC:+ / $SRC})"
  for s in $SKILLS; do [ -f "$SRC/skills/$s/SKILL.md" ] || die "source is incomplete: skills/$s/SKILL.md missing"; done
  [ -f "$SRC/skills/loop-pilot/references/loop-template.md" ] || die "source is incomplete: runner template missing"
  if ! cmp -s "$SRC/skills/loop-pilot/references/loop-template.md" "$SRC/skills/grillscaffold/references/loop-template.md"; then
    die "source is inconsistent: the two loop-template.md copies differ — do not install this build"
  fi
fi

REL="unknown"
[ -n "$SRC" ] && [ -f "$SRC/release-manifest.json" ] && REL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["release"])' "$SRC/release-manifest.json" 2>/dev/null || echo unknown)"

# ── verification ─────────────────────────────────────────────────────────────
installed_version() {  # installed_version <skill-dir>
  [ -f "$1/release-manifest.json" ] && python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["release"])' "$1/release-manifest.json" 2>/dev/null && return
  grep -m1 '^version:' "$1/SKILL.md" 2>/dev/null | awk '{print $2}'
}
owns() {  # only ever touch a directory that is one of OUR skills
  local d="$1" n="$2"
  [ -d "$d" ] || return 1
  [ -f "$d/SKILL.md" ] || return 1
  grep -qE "^name: *$n *$" "$d/SKILL.md"
}
verify_target() {  # verify_target <label> <root>
  local label="$1" root="$2" ok=1 s
  say "$label — $root"
  for s in $SKILLS; do
    if [ ! -d "$root/$s" ]; then say "  ✗ $s not installed"; ok=0; continue; fi
    if ! owns "$root/$s" "$s"; then say "  ✗ $root/$s exists but is not our skill (left alone)"; ok=0; continue; fi
    say "  ✓ $s $(installed_version "$root/$s")"
    if [ "$s" = loop-pilot ]; then
      for f in scripts/launch.sh scripts/status.sh scripts/scan.sh scripts/upgrade.sh scripts/doctor.sh scripts/agents.sh scripts/render-loop.py references/loop-template.md; do
        [ -f "$root/$s/$f" ] || { say "    ✗ missing $f"; ok=0; }
      done
      for f in "$root/$s"/scripts/*.sh; do [ -x "$f" ] || { say "    ✗ not executable: $(basename "$f")"; ok=0; }; done
    fi
  done
  if [ -f "$root/grillscaffold/references/loop-template.md" ] && [ -f "$root/loop-pilot/references/loop-template.md" ]; then
    cmp -s "$root/grillscaffold/references/loop-template.md" "$root/loop-pilot/references/loop-template.md" \
      && say "  ✓ both skills carry the identical runner template" \
      || { say "  ✗ the two runner templates differ — reinstall"; ok=0; }
  fi
  [ "$ok" = 1 ]
}

if [ "$VERIFY_ONLY" = 1 ]; then
  rc=0
  [ "$WANT_CLAUDE" = 1 ] && { verify_target "Claude Code" "$CLAUDE_DIR" || rc=1; }
  [ "$WANT_CODEX" = 1 ] && { verify_target "Codex" "$CODEX_DIR" || rc=1; }
  if [ -d "$LEGACY_CODEX_DIR/loop-pilot" ]; then
    say "⚠ a copy also exists in the legacy Codex path $LEGACY_CODEX_DIR — remove it to avoid duplicate skills:"
    say "    ./uninstall.sh --legacy-codex"
  fi
  exit $rc
fi

# ── install ──────────────────────────────────────────────────────────────────
install_into() {  # install_into <label> <root>
  local label="$1" root="$2" s stage backup_root ts rc=0
  ts="$(date +%Y%m%d-%H%M%S)"
  say "$label → $root"
  if [ "$DRY" = 1 ]; then
    for s in $SKILLS; do
      if [ -d "$root/$s" ]; then say "  would REPLACE $root/$s ($(installed_version "$root/$s") → $REL), backup kept"
      else say "  would INSTALL $root/$s ($REL)"; fi
    done
    return 0
  fi
  mkdir -p "$root" || die "cannot create $root"
  backup_root="$root/.loop-pilot-backups"
  for s in $SKILLS; do
    stage="$root/.$s.staging.$$"
    rm -rf "$stage"
    cp -R "$SRC/skills/$s" "$stage" || { rm -rf "$stage"; say "  ✗ could not stage $s"; rc=1; continue; }
    [ -f "$SRC/release-manifest.json" ] && cp "$SRC/release-manifest.json" "$stage/release-manifest.json"
    find "$stage" -name '*.sh' -exec chmod +x {} \; 2>/dev/null
    find "$stage" -name '*.py' -exec chmod +x {} \; 2>/dev/null
    # sanity: never swap in a broken runner
    if ! python3 "$stage/scripts/render-loop.py" --template "$stage/references/loop-template.md" --body-sha >/dev/null 2>&1; then
      if [ "$s" = loop-pilot ]; then rm -rf "$stage"; say "  ✗ staged loop-pilot failed its self-check — nothing was changed"; rc=1; continue; fi
    fi
    if [ -d "$root/$s" ]; then
      if owns "$root/$s" "$s"; then
        mkdir -p "$backup_root"
        mv "$root/$s" "$backup_root/$s-$(installed_version "$root/$s" | tr -d ' ')-$ts" 2>/dev/null \
          || { rm -rf "$stage"; say "  ✗ could not back up the existing $s"; rc=1; continue; }
      else
        rm -rf "$stage"; say "  ✗ $root/$s exists and is NOT our skill — left untouched"; rc=1; continue
      fi
    fi
    if mv "$stage" "$root/$s"; then say "  ✓ $s $REL"
    else                                                  # roll back to the backup we just made
      local b; b="$(ls -dt "$backup_root/$s-"* 2>/dev/null | head -1)"
      [ -n "$b" ] && mv "$b" "$root/$s"
      rm -rf "$stage"; say "  ✗ install of $s failed — previous version restored"; rc=1
    fi
  done
  return $rc
}

RC=0
[ "$WANT_CLAUDE" = 1 ] && { install_into "Claude Code" "$CLAUDE_DIR" || RC=1; }
[ "$WANT_CODEX" = 1 ] && { install_into "Codex" "$CODEX_DIR" || RC=1; }

if [ "$DRY" = 1 ]; then say; say "(dry run — nothing was written)"; exit 0; fi

say
[ "$WANT_CLAUDE" = 1 ] && { verify_target "Claude Code" "$CLAUDE_DIR" >/dev/null || RC=1; }
[ "$WANT_CODEX" = 1 ] && { verify_target "Codex" "$CODEX_DIR" >/dev/null || RC=1; }
if [ "$RC" = 0 ]; then
  say "Installed grillscaffold + loop-pilot $REL."
  say
  say "Next:"
  [ "$WANT_CLAUDE" = 1 ] && say "  check it        \"$CLAUDE_DIR/loop-pilot/scripts/doctor.sh\""
  [ "$WANT_CODEX" = 1 ] && [ "$WANT_CLAUDE" = 0 ] && say "  check it        \"$CODEX_DIR/loop-pilot/scripts/doctor.sh\""
  say "  plan a feature  ask your agent: \"grill me on <feature>\""
  say "  fly one         cd <repo>/docs/features/<feature> && ./loop.sh --preflight"
else
  say "Finished with problems — see the ✗ lines above. Re-run with --verify for detail."
fi
if [ -d "$LEGACY_CODEX_DIR/loop-pilot" ]; then
  say
  say "⚠ an older copy exists in the legacy Codex path $LEGACY_CODEX_DIR."
  say "  Codex reads ~/.agents/skills now; remove the old one: ./uninstall.sh --legacy-codex"
fi
exit $RC
