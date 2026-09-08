#!/usr/bin/env python3
"""Render docs/features/<feature>/loop.sh from the canonical loop-template.md.

Usage:
    render-loop.py --template <loop-template.md> --feature <slug> --primary <abs path>
                   [--extra <abs path>]... [--at-keyboard "P3 P5"] [--sha <12hex>] [--stamp <text>]
                   [--out <path>]           (default: stdout)
    render-loop.py --template <loop-template.md> --body-sha   (print the 12-char sha of the bash block)

Placeholders are replaced with properly shell-quoted values so paths containing spaces,
apostrophes, `$`, backslashes or `|` render correctly. This is the ONLY renderer: grillscaffold
(at scaffold time) and loop-pilot upgrade.sh (when regenerating) both call it, so a feature's
loop.sh is byte-identical whichever path produced it.
"""
import argparse, hashlib, re, sys

PH_FEATURE = "<feature>"
PH_PRIMARY = "<primary repo absolute path>"
PH_EXTRA = "<extra repo absolute paths, single-quoted, space-separated, or nothing>"
PH_ATK = "<space-separated at-keyboard phase IDs, e.g. P3>"


def body_of(template_text: str) -> str:
    """The single fenced ```bash block of the template, without the fences."""
    m = re.search(r"^```bash\n(.*?)^```", template_text, re.S | re.M)
    if not m:
        sys.exit("ERROR: no ```bash block in template")
    return m.group(1).rstrip("\n")


def body_sha(body: str) -> str:
    return hashlib.sha256(body.encode()).hexdigest()[:12]


def dq(s: str) -> str:
    """Escape for use inside a bash double-quoted string."""
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")


def sq(s: str) -> str:
    """Single-quote a bash word (handles embedded single quotes)."""
    return "'" + s.replace("'", "'\\''") + "'"


def render(body: str, feature: str, primary: str, extras, at_keyboard: str, sha: str, stamp: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9._-]+", feature):
        sys.exit(f"ERROR: feature slug must be [A-Za-z0-9._-]+, got {feature!r}")
    for p in [primary] + list(extras):
        if not p.startswith("/"):
            sys.exit(f"ERROR: repo path must be absolute: {p!r}")
        if "\n" in p:
            sys.exit("ERROR: repo path contains a newline")
    atk = " ".join(x for x in at_keyboard.split() if x)
    if atk and not re.fullmatch(r"(P[0-9][A-Za-z0-9]*\s*)+", atk + " "):
        sys.exit(f"ERROR: at-keyboard IDs must look like P3 P4b, got {at_keyboard!r}")
    out = body
    out = out.replace(f'FEATURE="{PH_FEATURE}"', f'FEATURE="{dq(feature)}"')
    out = out.replace(PH_FEATURE, feature)
    out = out.replace(f'PRIMARY_REPO="{PH_PRIMARY}"', f'PRIMARY_REPO="{dq(primary)}"')
    out = out.replace(f"EXTRA_REPOS=({PH_EXTRA})", "EXTRA_REPOS=(" + " ".join(sq(p) for p in extras) + ")")
    out = out.replace(f"AT_KEYBOARD=({PH_ATK})", f"AT_KEYBOARD=({atk})")
    for ph in (PH_PRIMARY, PH_EXTRA, PH_ATK):
        if ph in out:
            sys.exit(f"ERROR: placeholder not rendered: {ph}")
    lines = out.split("\n")
    marker = f"# template-sha: {sha}" + (f" ({stamp})" if stamp else "")
    # shebang first, sha marker second, then the rest (template-version line stays third)
    return "\n".join([lines[0], marker] + lines[1:]) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--template", required=True)
    ap.add_argument("--body-sha", action="store_true")
    ap.add_argument("--feature")
    ap.add_argument("--primary")
    ap.add_argument("--extra", action="append", default=[])
    ap.add_argument("--at-keyboard", default="")
    ap.add_argument("--sha")
    ap.add_argument("--stamp", default="")
    ap.add_argument("--out")
    a = ap.parse_args()
    body = body_of(open(a.template, encoding="utf-8").read())
    sha = body_sha(body)
    if a.body_sha:
        print(sha)
        return
    if not a.feature or not a.primary:
        sys.exit("ERROR: --feature and --primary are required")
    text = render(body, a.feature, a.primary, a.extra, a.at_keyboard, a.sha or sha, a.stamp)
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
