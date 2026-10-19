#!/usr/bin/env python3
"""Make sure CHANGELOG.md has a "## New in <version>" section before a release.

    python tools/changelog_draft.py 1.30.2          write the section if it's missing (no-op if it's there)
    python tools/changelog_draft.py 1.30.2 --print  only show what would be written

The draft is one "- line" per commit since the last release tag, from the commit subjects (release and
changelog-only commits are left out). It's a starting point: edit it in the Release tab's step 2 or in
CHANGELOG.md at any time. dev\\Release.bat runs this, so a release never stops for a missing section.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP = re.compile(r"^(Release \d+\.\d+\.\d+|Changelog\b|Merge (branch|pull request)|Revert \"Release)", re.I)


def git(root, *args):
    r = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, encoding="utf-8", errors="replace")
    return r.stdout if r.returncode == 0 else ""


def last_tag(root):
    tags = [t.strip() for t in git(root, "tag", "-l", "v*", "--sort=-v:refname").splitlines()]
    tags = [t for t in tags if re.fullmatch(r"v\d+\.\d+\.\d+", t)]
    return tags[0] if tags else None


def has_section(text, version):
    return re.search(rf"^##\s+New in {re.escape(version)}\b", text, re.M) is not None


def draft_lines(root=ROOT, since=None):
    """['- What changed.', ...] from the commit subjects since `since` (default: the last release tag)."""
    since = since or last_tag(root)
    rng = f"{since}..HEAD" if since else "HEAD"
    out, seen = [], set()
    for subj in git(root, "log", "--no-merges", "--format=%s", rng).splitlines():
        s = " ".join(subj.split()).strip()
        if not s or SKIP.match(s):
            continue
        s = s.rstrip(".")
        if len(s) > 220:
            s = s[:217].rsplit(" ", 1)[0] + "…"
        s = s[0].upper() + s[1:]
        if s.lower() not in seen:
            seen.add(s.lower())
            out.append(f"- {s}.")
    return out or ["- Fixes and small improvements."]


def with_section(text, version, lines):
    """CHANGELOG.md text with the section added above the newest one (or at the end)."""
    block = f"## New in {version}\n" + "\n".join(lines) + "\n\n"
    m = re.search(r"^##\s+New in ", text, re.M)
    if m:
        return text[:m.start()] + block + text[m.start():]
    return text.rstrip("\n") + "\n\n" + block


def ensure(version, root=ROOT, dry=False):
    """(wrote, lines): the section for `version`, drafted from commits when CHANGELOG.md lacks it."""
    path = os.path.join(root, "CHANGELOG.md")
    with open(path, encoding="utf-8", newline="") as f:
        text = f.read()
    if has_section(text, version):
        return False, []
    lines = draft_lines(root)
    if not dry:
        crlf = "\r\n" in text
        new = with_section(text.replace("\r\n", "\n"), version, lines)
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(new.replace("\n", "\r\n") if crlf else new)
    return True, lines


def main(argv):
    if not argv or not re.fullmatch(r"\d+\.\d+\.\d+", argv[0]):
        print(__doc__.strip())
        return 2
    version, dry = argv[0], "--print" in argv
    wrote, lines = ensure(version, dry=dry)
    if not wrote:
        print(f"CHANGELOG.md already has a section for {version}.")
        return 0
    print(("Would write" if dry else "Wrote") + f" '## New in {version}' from the commits since {last_tag(ROOT) or 'the start'}:")
    for line in lines:
        print("  " + line)
    if not dry:
        print("Edit CHANGELOG.md any time to reword it for players.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
