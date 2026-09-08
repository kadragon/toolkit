#!/usr/bin/env bash
# Launch Antigravity (agy) CLI code review against a base branch.
#
# Usage: agy-review.sh <base_branch>
# Output: Antigravity's review text to stdout.

set -euo pipefail

BASE_BRANCH="${1:?Usage: agy-review.sh <base_branch>}"

# Gate on empty diff up front so we don't spin up agy for nothing.
# The diff itself is fetched by agy via its shell tool — embedding large
# diffs directly in the prompt can overload context.
CHANGED_FILES=$(git diff "${BASE_BRANCH}...HEAD" --name-only 2>/dev/null \
  || git diff "${BASE_BRANCH}" --name-only 2>/dev/null || true)
if [ -z "$CHANGED_FILES" ]; then
  echo "No changes detected against ${BASE_BRANCH} — skipping Antigravity review." >&2
  exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

REVIEW_PROMPT="You are reviewing a proposed code change in the repository at ${REPO_ROOT}.

## How to obtain the diff

Use your shell tool to compare the current branch (${CURRENT_BRANCH}) against ${BASE_BRANCH}. Your shell tool runs outside the repository directory, so every git command MUST use \`git -C ${REPO_ROOT}\`. Run these commands yourself — do NOT ask the user for the diff:

1. \`git -C ${REPO_ROOT} diff ${BASE_BRANCH}...HEAD --stat\` — get an overview of which files changed.
2. \`git -C ${REPO_ROOT} diff ${BASE_BRANCH}...HEAD -- <path>\` — inspect specific files. Prefer reviewing per-file or per-hunk instead of loading the whole diff at once if the change is large.
3. \`git -C ${REPO_ROOT} log ${BASE_BRANCH}..HEAD --oneline\` — understand commit intent.
4. Read full file contents when a hunk's context is insufficient (files are available in the workspace at ${REPO_ROOT}).

If \`${BASE_BRANCH}...HEAD\` fails (e.g., detached HEAD or missing merge-base), fall back to \`git -C ${REPO_ROOT} diff ${BASE_BRANCH}\`.

## What to flag

Only flag issues introduced by this change — not pre-existing problems. Each finding must be:
- A concrete bug, security vulnerability, or performance regression with a clear reproduction scenario
- Discrete and actionable (one issue per finding, not vague observations)
- Something the author would fix if made aware of it

Prefer no finding over a weak finding. Do not pad the review with style nits, praise, or generic advice.

## Priority levels

Tag each finding:
- [P0] Blocking — data loss, security hole, crash in production
- [P1] Urgent — incorrect behavior under normal conditions
- [P2] Normal — edge case bugs, performance issues, maintainability risks
- [P3] Low — minor improvements worth noting

## Comment format

For each finding, provide:
1. **Priority tag and title** (one line, imperative mood)
2. **file:line** reference
3. **Why** it is a problem (1 paragraph max, matter-of-fact tone)
4. **When** it manifests (specific inputs, environments, or conditions)
5. **Suggested fix** (concrete code snippet if applicable, 3 lines max)

## Output structure

List findings ordered by priority (P0 first). After all findings, add:
- **Overall verdict**: \"LGTM\" if no P0/P1 issues, or \"Changes Requested\" with a 1-sentence explanation.
- If no issues worth flagging exist, say so plainly — do not invent findings."

# --print-timeout is agy's ONLY deadline. Nothing outside this script bounds it: the cycle
# launches it in the background and moves on without waiting (SKILL.md Step 2), and
# run_in_background enforces no timeout of its own. Keep the cap here so a slow run fails
# with a reportable reason instead of running on with no result anyone reads.
# Capture stdout and stderr separately so we can detect empty output and report
# the failure reason (Windows: agy exits non-zero before producing output, which
# set -euo pipefail would otherwise swallow silently).
AGY_OUT=$(mktemp)
AGY_ERR=$(mktemp)
trap 'rm -f "$AGY_OUT" "$AGY_ERR"' EXIT

AGY_EXIT=0
NO_COLOR=1 TERM=dumb agy -p "$REVIEW_PROMPT" \
  --dangerously-skip-permissions \
  --add-dir "$REPO_ROOT" \
  --print-timeout 15m 2>"$AGY_ERR" | tee "$AGY_OUT" || AGY_EXIT=$?

if ! grep -q '[^[:space:]]' "$AGY_OUT"; then
  echo "agy returned empty output (exit: $AGY_EXIT) — review skipped" >&2
  if [ -s "$AGY_ERR" ]; then
    echo "agy stderr:" >&2
    cat "$AGY_ERR" >&2
  fi
  exit 1
fi

# agy wrote output but exited non-zero — output is likely truncated; treat as failure
# rather than silently using partial review content.
if [ "$AGY_EXIT" -ne 0 ]; then
  echo "agy exited $AGY_EXIT with partial output — review skipped" >&2
  if [ -s "$AGY_ERR" ]; then
    echo "agy stderr:" >&2
    cat "$AGY_ERR" >&2
  fi
  exit 1
fi

# Forward any agy stderr (warnings, auth notices, rate-limit messages) even on success.
# Must not be the script's last command as a bare `[ ... ] && ...` list: when stderr is
# empty the test fails, the list returns 1, and — being last — that becomes the script's
# exit status. The caller reads a non-zero exit as failure and prints its
# `{"agy_review":"failed"}` sentinel after a perfectly good review. Hence the explicit exit 0.
if [ -s "$AGY_ERR" ]; then
  cat "$AGY_ERR" >&2
fi

exit 0
