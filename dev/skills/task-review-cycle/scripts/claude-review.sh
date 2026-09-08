#!/usr/bin/env bash
# Headless Claude code review against a base branch, invoking a review skill,
# emitting the findings-JSON array to stdout.
#
# Purpose: the Claude review slot, whichever runtime drives the cycle. This is
# the mirror of agy-review.sh / codex-review.sh. SKILL.md Step 2 calls it in the
# FOREGROUND under a Bash timeout, which is the whole point: the in-process Agent
# path this replaced had no timeout of its own, so a hung inner run — or one that
# finished while its completion notification was lost (upstream claude-code
# #49150, #58637, #68117) — stalled the cycle with no bound. A headless run also
# carries no session context, making it a stricter independent check than an
# in-process spawn, not a weaker one.
#
# Requires the `claude` CLI to be installed AND authenticated in the caller's
# environment. If it is not, the caller records "Reviewers Skipped".
#
# Usage: claude-review.sh <base_branch> [effort] [sprint_contract]
#   The review skill is fixed to "code-review" — SKILL.md Step 2 pins the Claude
#   slot to exactly one skill, so there is no slot argument. The optional effort
#   arg mirrors that step's escalation: the caller passes "high" when its
#   SECURITY_HIT capture is non-empty, and nothing otherwise. The optional third
#   arg is the Sprint Contract; when non-empty the run also grades the diff
#   against it, which keeps that grading independent of the agent that wrote the
#   code. Grading is read-only judgment only — running the contract's lint/test
#   command stays with the orchestrator, both because --permission-mode plan
#   forbids it here and because that half is already the orchestrator's job.
# Output: JSON array of findings on stdout — the contract Step 3 consolidation
#         consumes, with contract findings tagged "source":"contract".

set -euo pipefail

BASE_BRANCH="${1:?Usage: claude-review.sh <base_branch> [effort] [sprint_contract]}"
SLOT_ID="code-review"
EFFORT="${2:-}"
CONTRACT="${3:-}"

command -v claude >/dev/null 2>&1 || { echo "ERROR: claude CLI not found" >&2; exit 1; }

# SKILL.md Step 2 delegates the whole reviewer prompt to this script, so this
# block is its only copy — there is no second prompt to keep in sync. The strict
# "JSON array and NOTHING else" instruction is what lets .result be parsed
# directly as the findings array.
# Read the heredoc straight into the variable rather than through
# PROMPT=$(cat <<EOF ...). Inside a command substitution, bash 3.2 does not treat
# heredoc content as literal: it scans the body for quotes, so the apostrophes
# below (run's, branch's) opened a quote that swallowed the rest of the file. The
# script then died at exit 127 running its own comments as commands — on macOS
# only, since bash 5 parses it correctly and CI runs Linux. read -d '' takes the
# body verbatim and returns non-zero at EOF, hence the || true under set -e.
IFS= read -r -d '' PROMPT <<EOF || true
Review changes on the current branch against ${BASE_BRANCH}.
1. git diff ${BASE_BRANCH}...HEAD --name-only
2. Invoke Skill "${SLOT_ID}" with args "${EFFORT}" to review — the skill name is exactly \`${SLOT_ID}\`; the effort goes in the args field, never in the name. Empty args = default effort. Do not invoke any other review skill or command.
3. Return findings as a JSON array and NOTHING else — no prose, no code fence:
   [{"file":"...","line":N,"severity":"P0".."P3","confidence":0-100,"problem":"...","fix":"...","source":"${SLOT_ID}"}]
   confidence = certainty the issue is real in THIS code (not a pattern match). 100 = verified by reading actual code path.
   The array IS the \`${SLOT_ID}\` run's findings — every one of them, as it reported them. Do not filter, re-rank, re-judge, merge, summarize or drop a finding. \`[]\` means the reviewer ran and found nothing; it never means you could not read its output.
If docs/design/{slug}.md exists for this branch's slug, also verify the diff fulfills its User Stories and Implementation/Testing Decisions and flag scope creep or missing requirements as additional findings.
Only flag issues introduced or made significantly worse by this branch's diff.
Do NOT flag: pre-existing issues, linter-owned style, generated/vendored files, speculative concerns, >5 style nits.
If there are no findings, return [].
EOF

# The heredoc above is UNQUOTED, so it expands dollar signs and backticks. A
# Sprint Contract is caller-supplied text that legitimately carries both: a
# lint/test command, or a shell snippet inside an acceptance criterion. Appending
# it into that heredoc would therefore run command substitution taken from the
# contract, in this shell. Concatenate by parameter expansion instead, which
# substitutes the value and never re-parses it.
#
# Keep backticks, command-substitution punctuation and apostrophes out of the
# block below and out of this comment. Once the heredoc body above contains
# backticks, bash 3.2 mis-tracks quoting across the rest of the file and rejects
# it outright, while bash 5 on the CI runner accepts it — so this breaks on macOS
# where CI stays green. test_claude_review.py runs `bash -n` to catch it.
if [ -n "$CONTRACT" ]; then
  PROMPT="${PROMPT}

Then grade the diff against the Sprint Contract below. Judge every acceptance criterion by reading
the diff. A criterion without evidence of being met is a finding: severity P0, \"source\":\"contract\".
Hunt for ways the change fails a criterion; record a pass only on evidence. Append contract findings
to the SAME JSON array as the ${SLOT_ID} findings. Do NOT run the lint/test command named in the
contract — this session is read-only, and the orchestrator runs that command itself.

Sprint Contract:
${CONTRACT}"
fi

# --permission-mode plan makes the headless session structurally read-only: it
# can still read the diff and files (git diff, Read) but cannot Edit/Write or
# run mutating commands. A review must never touch the tree — without this, a
# headless session that misreads its task (or trips the target repo's hooks) can
# create/modify files instead of just reporting findings.
#
# Do NOT pass --model: under a non-Claude driver there is no live session to
# inherit, so the CLI's configured default model is the intended choice.
RAW=""
status=0
RAW=$(claude -p --permission-mode plan --output-format json "$PROMPT") || status=$?
if [ "$status" -ne 0 ]; then
  printf '%s\n' "${RAW:-claude CLI exited $status with no stdout}" >&2
  exit "$status"
fi

# --output-format json wraps the run in an envelope; .result holds the model's
# text output (the JSON array). Fall back to the raw payload if jq is missing or
# the field is absent, then strip an optional ```json code fence.
RESULT=$(jq -r '.result // empty' <<<"$RAW" 2>/dev/null || true)
[ -z "$RESULT" ] && RESULT="$RAW"
RESULT=$(printf '%s' "$RESULT" | sed -E 's/^```[a-zA-Z]*[[:space:]]*//; s/[[:space:]]*```$//')

emit_if_array() { jq -e 'type == "array"' <<<"$1" >/dev/null 2>&1 && { printf '%s\n' "$1"; return 0; }; return 1; }

# Prefer the clean case: the whole result is the array. If not — a headless
# session can wrap the array in prose (e.g. a repo Stop hook injects a nudge the
# model answers before re-emitting JSON) — recover the outermost [...] block and
# revalidate. Only if BOTH fail do we surface the raw text and report the slot as
# unavailable: an unread run is a dead slot, and `[]` would consolidate as a clean
# Claude review — the failure mode the sentinel rule in SKILL.md Step 2 exists to stop.
if emit_if_array "$RESULT"; then
  exit 0
fi
EXTRACTED=$(printf '%s' "$RESULT" | tr '\n' ' ' | grep -oE '\[.*\]' | tail -1 || true)
if [ -n "$EXTRACTED" ] && emit_if_array "$EXTRACTED"; then
  exit 0
fi
printf 'WARN: claude review did not return a parseable JSON array:\n%s\n' "$RESULT" >&2
echo '{"code_review_slot":"inner-run-unavailable","detail":"claude-review.sh could not parse a findings array from the run output"}'
