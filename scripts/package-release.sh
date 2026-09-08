#!/usr/bin/env bash
# Build the release archive + checksums into dist/. This is exactly what CI attaches to a tag.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VER="$(tr -d ' \n' < "$ROOT/VERSION")"
OUT="$ROOT/dist"
NAME="grillscaffold-loop-pilot"
rm -rf "$OUT"; mkdir -p "$OUT/$NAME"
cp -R "$ROOT/skills" "$OUT/$NAME/skills"
for f in install.sh uninstall.sh VERSION release-manifest.json README.md CHANGELOG.md; do
  [ -f "$ROOT/$f" ] && cp "$ROOT/$f" "$OUT/$NAME/$f"
done
mkdir -p "$OUT/$NAME/scripts"; cp "$ROOT"/scripts/*.sh "$OUT/$NAME/scripts/" 2>/dev/null || true
find "$OUT/$NAME" -name '*.sh' -exec chmod +x {} \;
find "$OUT/$NAME" -name '*.py' -exec chmod +x {} \;
( cd "$OUT" && tar -czf "$NAME.tar.gz" "$NAME" )
rm -rf "$OUT/$NAME"
( cd "$OUT" && { shasum -a 256 "$NAME.tar.gz" 2>/dev/null || sha256sum "$NAME.tar.gz"; } > SHA256SUMS )
echo "built $OUT/$NAME.tar.gz ($VER)"
cat "$OUT/SHA256SUMS"
