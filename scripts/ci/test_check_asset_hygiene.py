#!/usr/bin/env python3
"""
Unit tests for check_asset_hygiene.py.

Two halves, and the second is the load-bearing one.

The fail cases pin each rule: delete `check_forbidden_chars`'s bidi range, the Cyrillic
regex, or the personal-path match and the corresponding case goes red.

The pass cases pin the *allowlists*, which is where a linter over this repo actually
breaks. The shipped assets carry ~6,900 Hangul characters, box-drawing tables, emoji
with U+FE0F presentation selectors, typographic punctuation, an intentional `1.0.0α`
version fixture in `dev/skills/repo-dependabot/scripts/consolidate-deps.py`, and eight
placeholder home paths (`/Users/me/…`, `/c/Users/First Last`). A rule that fires on any
of those is not a stricter linter, it is a broken one — and the tempting repair is to
weaken the legitimate fixture instead. These cases make that regression visible here
rather than in review.

Run: python3 scripts/ci/test_check_asset_hygiene.py
"""

import importlib.util
import sys
from pathlib import Path

def _load(name: str, path: Path):
    """Load a module from source text, deliberately bypassing `__pycache__`.

    `spec_from_file_location` reads a cached `.pyc` whenever its recorded size and
    whole-second mtime still match the source — which a one-character edit and its revert
    both satisfy. That made a real drift check here read stale, so the comparison this file
    exists to make cannot go through the cache. Compiling the text costs microseconds.
    """
    module = importlib.util.module_from_spec(
        importlib.util.spec_from_loader(name, loader=None)
    )
    module.__file__ = str(path)
    exec(compile(path.read_text(encoding="utf-8"), str(path), "exec"), module.__dict__)
    return module


SCRIPT = Path(__file__).parent / "check_asset_hygiene.py"
mod = _load("check_asset_hygiene", SCRIPT)

# The shipped hook that carries a copy of the same table. Loading it here rather than in
# the hook is the only direction that works: this file runs in the repo, where both paths
# exist, while the hook runs on a machine that has no `scripts/` at all.
GUARD = Path(__file__).resolve().parents[2] / "dev" / "hooks" / "memory-guard" / "guard.py"
guard_mod = _load("memory_guard", GUARD)

PASS = "\033[92mPASS\033[0m"
FAIL = "\033[91mFAIL\033[0m"
_results = []


def check(name, condition, detail=""):
    label = PASS if condition else FAIL
    print(f"  {label}  {name}" + (f"\n       {detail}" if detail and not condition else ""))
    _results.append(condition)


def main() -> int:
    print("check_forbidden_chars — invisible and control characters")

    check(
        "U+202E right-to-left override is caught",
        len(mod.check_forbidden_chars("run \u202egnp.exe\n")) == 1,
    )
    check(
        "U+2066 bidi isolate is caught",
        len(mod.check_forbidden_chars("a \u2066b\n")) == 1,
    )
    check(
        "U+200B zero-width space is caught",
        len(mod.check_forbidden_chars("ad\u200bmin\n")) == 1,
    )
    check(
        "U+FEFF is caught mid-file, not just as a BOM",
        len(mod.check_forbidden_chars("line one\nli\ufeffne two\n")) == 1,
    )
    check(
        "a C1 control is caught",
        len(mod.check_forbidden_chars("text \u0085 more\n")) == 1,
    )
    check(
        "a C0 control is caught",
        len(mod.check_forbidden_chars("text \x01 more\n")) == 1,
    )
    # Regression: the first draft looped over `text.splitlines()`, which breaks on and
    # *consumes* U+000B, U+000C, U+001C-1E, U+0085, U+2028 and U+2029 — so a file whose
    # only defect was one of them scanned clean. Restore the per-line loop and these go
    # red. U+0085 above is part of the same family.
    check(
        "U+2028 line separator is caught (splitlines() would swallow it)",
        len(mod.check_forbidden_chars("a\u2028b\n")) == 1,
    )
    check(
        "U+000B vertical tab is caught (splitlines() would swallow it)",
        len(mod.check_forbidden_chars("a\x0bb\n")) == 1,
    )
    check(
        "the finding names the line, the column and the codepoint",
        "line 2" in mod.check_forbidden_chars("ok\nbad \u202e\n")[0]
        and "col 5" in mod.check_forbidden_chars("ok\nbad \u202e\n")[0]
        and "U+202E" in mod.check_forbidden_chars("ok\nbad \u202e\n")[0],
        mod.check_forbidden_chars("ok\nbad \u202e\n"),
    )

    # Allowlist regressions — every one of these appears in the real tree.
    check(
        "TAB and LF are structure, not violations",
        mod.check_forbidden_chars("a\tb\nc\n") == [],
    )
    check(
        "CR is not reported here — the line-ending job owns CRLF",
        mod.check_forbidden_chars("a\r\nb\r\n") == [],
        "reporting one defect under two job names helps nobody",
    )
    check(
        "U+FE0F emoji variation selector is allowed",
        mod.check_forbidden_chars("\u26a0\ufe0f warning\n") == [],
    )
    check(
        "a Hangul paragraph is clean",
        mod.check_forbidden_chars("한글 문서는 그대로 통과해야 한다.\n") == [],
    )
    check(
        "typographic punctuation and box drawing are clean",
        mod.check_forbidden_chars("├─ a — b → c ≥ d · e …\n") == [],
    )
    check(
        "emoji are clean",
        mod.check_forbidden_chars("🟢 ✅ ▼\n") == [],
    )

    print("\ncheck_cyrillic_homoglyphs — Latin tokens carrying a lookalike")

    check(
        "Cyrillic a inside `admin` is caught",
        len(mod.check_cyrillic_homoglyphs("\u0430dmin\n")) == 1,
    )
    check(
        "a trailing Cyrillic letter is caught too",
        len(mod.check_cyrillic_homoglyphs("scriptс\n")) == 1,
    )
    check(
        "the finding names the codepoint and the offending token",
        "U+0430" in mod.check_cyrillic_homoglyphs("\u0430dmin\n")[0],
        mod.check_cyrillic_homoglyphs("\u0430dmin\n"),
    )
    check(
        "Greek alpha beside ASCII digits is NOT flagged",
        mod.check_cyrillic_homoglyphs("qux==1.0.0\u03b1\n") == [],
        "consolidate-deps.py uses this shape as a deliberate non-ASCII fixture",
    )
    check(
        "Hangul beside ASCII is not flagged",
        mod.check_cyrillic_homoglyphs("dev 플러그인 v2\n") == [],
    )
    check(
        "standalone Cyrillic words are not flagged",
        mod.check_cyrillic_homoglyphs("\u043f\u0440\u0438\u0432\u0435\u0442\n") == [],
        "the defect is substitution into a Latin token, not Cyrillic text as such",
    )

    print("\ncheck_personal_paths — a specific account's home directory")

    check(
        "a POSIX personal path is caught",
        len(mod.check_personal_paths("cd /Users/kdonguk/dev/x\n")) == 1,
    )
    check(
        "a Windows personal path is caught",
        len(mod.check_personal_paths("C:\\Users\\KNUE\\dev\\x\n")) == 1,
    )
    check(
        "a Linux personal path is caught",
        len(mod.check_personal_paths("/home/kadragon/x\n")) == 1,
    )
    check(
        "the finding quotes the matched path",
        "/Users/kdonguk" in mod.check_personal_paths("cd /Users/kdonguk/dev\n")[0],
        mod.check_personal_paths("cd /Users/kdonguk/dev\n"),
    )

    # Allowlist regressions — all eight path-shaped strings in the tree are these.
    check(
        "`/Users/me/...` is a documented placeholder",
        mod.check_personal_paths("/Users/me/Dev/toolkit\n") == [],
    )
    check(
        "`/Users/someone/...` is a documented placeholder",
        mod.check_personal_paths("/Users/someone/Dev/agent-toolkit\n") == [],
    )
    check(
        "`/c/Users/First Last` — the two-word IFS example — is a placeholder",
        mod.check_personal_paths("# space (`/c/Users/First Last`) breaks IFS\n") == [],
    )
    check(
        "`/home/runner/work` is GitHub Actions, not a person",
        mod.check_personal_paths("/home/runner/work/repo\n") == [],
    )
    check(
        "an angle-bracket placeholder is allowed",
        mod.check_personal_paths("C:\\Users\\<name>\\dev\n") == [],
    )
    check(
        "a shell substitution segment is allowed",
        mod.check_personal_paths("/Users/$USER/dev and /Users/${OWNER}/x\n") == [],
    )
    check(
        "`~/.claude/...` never matches — it has no /Users segment",
        mod.check_personal_paths("~/.claude/plugins/cache/kadragon\n") == [],
    )
    check(
        "an elided segment is a placeholder, POSIX and Windows alike",
        mod.check_personal_paths("/Users/.../SKILL.md and C:\\Users\\...\\Temp\n") == [],
        "the shipped tree writes elisions in exactly these two shapes",
    )

    # Review finding: the regex's optional second word fired on any path followed by a
    # space and a word, so a placeholder used in ordinary prose failed the gate with a
    # message telling the author to use a placeholder. Drop the first-word fallback in
    # check_personal_paths and these three go red.
    check(
        "a placeholder at the end of a path in prose is not a false positive",
        mod.check_personal_paths("On macOS /Users/me is the home directory.\n") == [],
    )
    check(
        "`/home/user notes` — placeholder plus a following word — is not flagged",
        mod.check_personal_paths("/home/user notes\n") == [],
    )
    check(
        "a real path followed by a word is still flagged, reported without the word",
        mod.check_personal_paths("/Users/kdonguk runs this\n")
        == [
            "line 1: hardcoded personal path '/Users/kdonguk' — "
            "use ~, $HOME or a placeholder segment instead"
        ],
        mod.check_personal_paths("/Users/kdonguk runs this\n"),
    )

    # Review finding: drive-letter forms were case-sensitive, so the lowercase spelling
    # shell snippets actually use slipped through.
    check(
        "lowercase `c:\\users\\...` is caught",
        len(mod.check_personal_paths("c:\\users\\knue\\dev\n")) == 1,
    )
    check(
        "lowercase `/c/users/...` is caught",
        len(mod.check_personal_paths("/c/users/knue/dev\n")) == 1,
    )
    check(
        "bare lowercase `/users/123` stays unflagged — it is a REST path, not a home dir",
        mod.check_personal_paths("GET /users/123/profile\n") == [],
        "macOS always capitalises /Users; matching the lowercase form would fire on API docs",
    )

    # Review finding: the elision rule was "no letter or digit", which waved through every
    # punctuation-only segment rather than just an ellipsis.
    check(
        "a punctuation-only segment that is not an ellipsis is still flagged",
        len(mod.check_personal_paths("/Users/_/dev/x\n")) == 1
        and len(mod.check_personal_paths("/Users/---/dev/x\n")) == 1,
    )

    print("\nis_placeholder_segment")

    check(
        "matching is case-insensitive",
        mod.is_placeholder_segment("Me") and mod.is_placeholder_segment("First Last"),
    )
    check(
        "a real account name is not a placeholder",
        not mod.is_placeholder_segment("kdonguk"),
    )
    check(
        "an ellipsis is a placeholder; other punctuation-only segments are not",
        mod.is_placeholder_segment("...")
        and mod.is_placeholder_segment(".")
        and not mod.is_placeholder_segment("__")
        and not mod.is_placeholder_segment("---"),
    )

    print("\ncorpus collection")

    files = mod.find_asset_files()
    check(
        "untracked artefacts are excluded — the corpus is what git tracks",
        not any("__pycache__" in p.as_posix() for p in files),
    )
    check(
        "the corpus is non-empty and confined to the shipped roots",
        len(files) > 0
        and all(p.relative_to(mod.REPO_ROOT).parts[0] in mod.CORPUS_ROOTS for p in files),
    )

    print("\nempty_corpus_errors — a gate that scans nothing must not report green")

    check(
        "the real corpus covers every declared root",
        mod.empty_corpus_errors(files) == [],
    )
    check(
        "a root contributing no files is an error, named",
        len(mod.empty_corpus_errors([mod.REPO_ROOT / "dev" / "x.md"])) == 1
        and "prod" in mod.empty_corpus_errors([mod.REPO_ROOT / "dev" / "x.md"])[0],
        mod.empty_corpus_errors([mod.REPO_ROOT / "dev" / "x.md"]),
    )
    check(
        "an entirely empty corpus errors once per declared root",
        len(mod.empty_corpus_errors([])) == len(mod.CORPUS_ROOTS),
    )

    print("\ndev/hooks/memory-guard/guard.py — the duplicated character table stays in sync")

    ours = mod._forbidden_chars()
    theirs = guard_mod._forbidden_chars()
    drift = sorted(set(ours) ^ set(theirs))
    relabelled = sorted(cp for cp in set(ours) & set(theirs) if ours[cp] != theirs[cp])
    check(
        "check_asset_hygiene._forbidden_chars() == memory-guard's copy",
        ours == theirs,
        "the two tables are duplicated deliberately — the hook ships to machines that never "
        "receive scripts/ci/, so it cannot import this one — which makes them free to drift "
        "silently. Reconcile "
        f"{mod.REPO_ROOT / 'scripts' / 'ci' / 'check_asset_hygiene.py'} and {GUARD}. "
        f"codepoints in one table only: {[f'U+{cp:04X}' for cp in drift]}; "
        f"same codepoint, different reason: {[f'U+{cp:04X}' for cp in relabelled]}",
    )

    print("\n----")
    failed = _results.count(False)
    if failed:
        print(f"FAIL: {failed}/{len(_results)} checks failed")
        return 1
    print(f"OK: {len(_results)}/{len(_results)} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
