---
name: task-review-cycle
description: >-
  Internal review-cycle primitive for `task-review`. Not a standalone entry
  point — do not invoke without an explicit caller argument.
---

# Dev Review Cycle

## Caller gate

This skill is a callable primitive. Before Setup, look for `--from <caller>` in the invocation.

- **Present** → strip it and run. Any caller name counts (`task-review`, `task-new`, `task-next`).
- **Absent** → stop before Step 0. Do not commit, push, open a PR, or merge. Say the review cycle
  is reached through `/task-review` and let the human fire it (`docs/invocation.md` → *The
  invariant*). The gate catches router auto-selection, which carries no token.

## Arguments

- `--from <caller>` — required caller token.
- `--auto` — skip the Step 3 confirmation; apply every in-scope finding.
- `--no-hub` — commit locally, review, apply, stop. No push, PR, CI, or merge.
- `--lite` / `--pr` — force the merge path. Without either, Step 1 routes by diff size (below).
- `--panel` — add the agy and Codex engines to the reviewer. Auto-enabled on a security hit, a
  diff of 300+ lines, or a diff that adds or changes a shipped script under `dev/`/`prod/`.

**Sprint Contract.** The caller restates it verbatim in the invocation (Tag / Scope / Acceptance
criteria / Out of scope / Lint-test command); the reviewer grades against it. None restated → the
reviewer grades the diff alone; say so in the report.

## Prerequisites and Setup

GitHub remote → `gh` authenticated. Forgejo/Gitea → `FORGEJO_TOKEN` or `GITEA_TOKEN` set
(`DRC_HUB_API_URL` overrides the API base). `--no-hub` needs no auth. `SKILL_DIR` is the absolute
parent directory of the `SKILL.md` loaded this turn.

```bash
SKILL_DIR="<absolute parent directory of the loaded SKILL.md>"
[[ -f "$SKILL_DIR/scripts/preflight.sh" ]] || { echo "Bundled preflight unavailable: $SKILL_DIR/scripts/preflight.sh" >&2; exit 1; }
PREFLIGHT=$(bash "$SKILL_DIR/scripts/preflight.sh")   # append --no-hub when that flag is set
BASE_BRANCH=$(jq -r '.base_branch' <<<"$PREFLIGHT")
FEATURE_BRANCH=$(jq -r '.feature_branch' <<<"$PREFLIGHT")
NATIVE_ENGINE=$(jq -r '.native_engine' <<<"$PREFLIGHT")
CLAUDE_CLI_AVAILABLE=$(jq -r '.claude_cli_available' <<<"$PREFLIGHT")
MERGE_STRATEGY=$(jq -c '.merge_strategy' <<<"$PREFLIGHT")
```

Stop if the bundled scripts cannot be resolved or `has_errors` is `true`. The result is cached per
branch, so later blocks re-run it for free and read the engine fields they need.

## Step 0: Feature branch

On the base branch: derive a short slug from the diff, then `git checkout -b <type>/<slug>`.

## Step 1: Commit, route, PR

Derive `COMMIT_MESSAGE` from `git diff --stat HEAD` and `git log --oneline -5`; the `[TYPE]`
prefix is mandatory (commit-guard runs inside the script and rejects otherwise).

```bash
SKILL_DIR="<absolute parent directory of the loaded SKILL.md>"
[[ -d "$SKILL_DIR/scripts" ]] || { echo "Bundled scripts unavailable: $SKILL_DIR/scripts" >&2; exit 1; }
COMMIT_MESSAGE="<[TYPE] derived message>"
RESULT=$(bash "$SKILL_DIR/scripts/commit-and-push.sh" --no-push --message "${COMMIT_MESSAGE}")
```

`guard_skipped: true` in `RESULT` means the commit went through unchecked — report it.

**Route by size** (skip when `--no-hub`, `--lite` or `--pr` was passed):

```bash
SKILL_DIR="<absolute parent directory of the loaded SKILL.md>"
PREFLIGHT=$(bash "$SKILL_DIR/scripts/preflight.sh")
BASE_BRANCH=$(jq -r '.base_branch' <<<"$PREFLIGHT")
CHANGED_FILES=$(git diff "${BASE_BRANCH}...HEAD" --name-only)
DELTA_TERMS=$(git diff "${BASE_BRANCH}...HEAD" --shortstat \
  | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | tr '\n' '+' | sed 's/+$//;s/^$/0/')
LINE_DELTA=$(( DELTA_TERMS ))
SECURITY_HIT=$(echo "$CHANGED_FILES" | grep -Ei 'auth|crypto|secret|permission|network|\.env$|/env[./]|/env$|environment|\.github/workflows' | head -1 || true)
BINARY_HIT=$(git diff "${BASE_BRANCH}...HEAD" --numstat | cut -f1,2 | grep -m1 -e '-' || true)
MODE_OR_RENAME=$(git diff "${BASE_BRANCH}...HEAD" --summary | grep -E '^ (mode change|rename) ' | head -1 || true)
SCRIPT_HIT=$(git diff "${BASE_BRANCH}...HEAD" --name-only --diff-filter=ACMR \
  | grep -E '^(dev|prod)/.*\.(sh|py|ps1|cjs)$' | head -1 || true)
```

| Condition | Path |
|-----------|------|
| `1 ≤ LINE_DELTA ≤ 100` and `SECURITY_HIT`, `BINARY_HIT`, `MODE_OR_RENAME` all empty | **lite** — no push, no PR, no CI; Step 6 merges locally |
| otherwise | **hub** — push and open the PR now |
| `SECURITY_HIT` non-empty, or `LINE_DELTA ≥ 300` | hub, and `--panel` is on |
| `SCRIPT_HIT` non-empty | `--panel` is on; the path stays whatever the rows above chose |

A zero line delta is unmeasured (binary, mode, rename), not trivial — it routes to hub. Announce
the chosen path in one line. `SCRIPT_HIT` matches on extension because a shipped script is where
the panel's non-Claude engines earn their slot — quoting, shell expansion, and interpreter-shim
defects a prose reviewer has no reason to look for (PR #267). It sets no path of its own: a small
script edit still merges lite, reviewed by three sources. A `.md`, `.json`, `.xml` or `.yaml` edit
cannot match, so a skill-doc change does not pull the panel in. Hub path — push and open the PR before any review:

```bash
SKILL_DIR="<absolute parent directory of the loaded SKILL.md>"
PREFLIGHT=$(bash "$SKILL_DIR/scripts/preflight.sh")
BASE_BRANCH=$(jq -r '.base_branch' <<<"$PREFLIGHT")
COMMIT_MESSAGE="<[TYPE] message from above>"
RESULT=$(bash "$SKILL_DIR/scripts/commit-and-push.sh" --pr --base "${BASE_BRANCH}" --message "${COMMIT_MESSAGE}")
PR_NUMBER=$(jq -r '.pr_number' <<<"$RESULT")
PR_URL=$(jq -r '.pr_url' <<<"$RESULT")
```

The script is idempotent: the local commit from above is reused. If `pr_number` is null but
`pr_url` is not, take `basename "$PR_URL"`. Both null → halt.

## Step 2: Review

**One reviewer, always.** Launch one Agent with `run_in_background: true`, no `subagent_type`,
no pinned model, with the prompt below. It runs the `code-review` skill and grades the Sprint
Contract in the same pass. `SECURITY_HIT` non-empty → `EFFORT="high"`, else empty.

When `NATIVE_ENGINE` is not `claude` (a non-Claude runtime is driving), shell out instead so a
Claude engine still reviews; skip the slot with `Reviewers Skipped: claude CLI unavailable` when
`CLAUDE_CLI_AVAILABLE` is `false`:

```bash
SKILL_DIR="<absolute parent directory of the loaded SKILL.md>"
[[ -f "$SKILL_DIR/scripts/claude-review.sh" ]] || { echo "Bundled claude-review unavailable: $SKILL_DIR/scripts/claude-review.sh" >&2; exit 1; }
PREFLIGHT=$(bash "$SKILL_DIR/scripts/preflight.sh")
BASE_BRANCH=$(jq -r '.base_branch' <<<"$PREFLIGHT")
EFFORT="<high when SECURITY_HIT is non-empty, else empty>"
bash "$SKILL_DIR/scripts/claude-review.sh" "${BASE_BRANCH}" "${EFFORT}" \
  || echo '{"code_review_slot":"inner-run-unavailable","detail":"claude-review.sh exited non-zero"}'
```

Reviewer prompt:

```
Review branch ${FEATURE_BRANCH} against ${BASE_BRANCH}.
1. git diff ${BASE_BRANCH}...HEAD --name-only
2. Invoke Skill "code-review" with args "${EFFORT}" — that exact skill name, effort in args (empty = default). No other review skill.
3. If a Sprint Contract follows, grade the diff against every acceptance criterion and run its lint/test command. A criterion without evidence of being met is a finding: severity P0, "source":"contract". Hunt for ways the change fails a criterion; record a pass only on evidence.
4. Return ONE JSON array, after the code-review run returns — never an interim one:
   [{"file":"...","line":N,"severity":"P0".."P3","confidence":0-100,"problem":"...","fix":"...","source":"code-review"|"contract"}]
   Include every finding the code-review run produced, unfiltered and unranked. `[]` means the run finished and found nothing. If the run never returned or you cannot read its output, return {"code_review_slot":"inner-run-unavailable","detail":"..."} instead of `[]`.
Flag only issues this branch introduced or made worse. Skip pre-existing issues, linter-owned style, generated files, speculative concerns, >5 style nits.
Deliver the JSON via SendMessage(to: "main") when done — including `[]`. A silent finish loses the review.
<Sprint Contract, verbatim, when the caller supplied one>
```

The sentinel, or a 1200s breach, is a dead slot: record `Reviewers Skipped: code-review inner run
unavailable (<detail>)` and review inline (diff, correctness, naming, error handling, coverage,
the contract). A later corrected array from the same agent supersedes the earlier one.

**`--panel`** — launch these in the same turn as the reviewer, `run_in_background: true`, 1200s
each; a source that fails or breaches is recorded as skipped and the cycle proceeds on the rest.

```bash
SKILL_DIR="<absolute parent directory of the loaded SKILL.md>"
[[ -d "$SKILL_DIR/scripts" ]] || { echo "Bundled scripts unavailable: $SKILL_DIR/scripts" >&2; exit 1; }
PREFLIGHT=$(bash "$SKILL_DIR/scripts/preflight.sh")
BASE_BRANCH=$(jq -r '.base_branch' <<<"$PREFLIGHT")
AGY_AVAILABLE=$(jq -r '.agy_available' <<<"$PREFLIGHT")
CODEX_AVAILABLE=$(jq -r '.codex_available' <<<"$PREFLIGHT")
CODEX_MODE=$(jq -r '.codex_mode' <<<"$PREFLIGHT")
CODEX_COMPANION_PATH=$(jq -r '.codex_companion_path' <<<"$PREFLIGHT")
[[ "$AGY_AVAILABLE" == "true" ]] && { bash "$SKILL_DIR/scripts/agy-review.sh" "${BASE_BRANCH}" || echo '{"agy_review":"failed"}' >&2; }
codex_status=0
if [[ "$CODEX_AVAILABLE" == "true" ]]; then
  bash "$SKILL_DIR/scripts/codex-review.sh" "${CODEX_MODE}" "${BASE_BRANCH}" "${CODEX_COMPANION_PATH}" || codex_status=$?
fi
if [ "$codex_status" -eq 75 ]; then
  echo '{"codex_review":"locked"}' >&2      # another cycle holds the workspace slot — skipped, not failed
elif [ "$codex_status" -ne 0 ]; then
  echo '{"codex_review":"failed"}' >&2
fi
```

Wait for every launched source before Step 3. A breached codex source leaves its result on disk — `references/late-source-reclaim.md` reclaims it before merge; no other source persists one.

## Step 3: Consolidate and confirm

Follow `references/consolidation-guide.md`: merge duplicates across sources, drop confidence
< 50 and the excluded categories, classify in/out of scope, sort by severity. A `contract`
finding is in-scope P0 and is never dropped by confidence or by `--auto`.

Without `--auto`: present the table and wait. With `--auto`: every in-scope finding is approved.
Out-of-scope findings go to `backlog.md` under `## Review Backlog` (format in the guide) — never
`tasks.md`.

## Step 4: Apply

Apply approved findings, run the repo's test command (Sprint Contract, else `package.json` /
`Makefile` / `pyproject.toml` / `go.mod` / `Cargo.toml`). On failure revert that file
(`git restore --staged <file> && git restore <file>`), report which finding failed, ask.
A fixed `contract` finding → re-run the reviewer once; still failing → stop, never merge. A fix
that newly touched another plugin or skill `SKILL.md` → re-run `scripts/bump-version.sh` for it.

**Retrospect (signal-gated).** Only if this cycle surfaced a user correction, a recurring gotcha,
or a reusable workflow: call the Skill tool with "dev:harness-capture" now, so a light memory or
`docs/` delta rides into this commit (heavy items go to `backlog.md`). No signal → skip silently.

## Step 5: Commit

```bash
SKILL_DIR="<absolute parent directory of the loaded SKILL.md>"
[[ -f "$SKILL_DIR/scripts/commit-and-push.sh" ]] || { echo "Bundled commit helper unavailable: $SKILL_DIR/scripts/commit-and-push.sh" >&2; exit 1; }
FILES_TO_STAGE="<exact files changed in Step 4, verified against git status --short>"
COMMIT_MESSAGE="<[TYPE] message from Step 1>"
# lite or --no-hub:
bash "$SKILL_DIR/scripts/commit-and-push.sh" --no-push --files "${FILES_TO_STAGE}" --message "${COMMIT_MESSAGE}"
# hub:
bash "$SKILL_DIR/scripts/commit-and-push.sh" --files "${FILES_TO_STAGE}" --message "${COMMIT_MESSAGE}"
```

Skip when Step 4 changed nothing. `--no-hub`: report and end here.

## Step 6: Merge

**Lite path** — reclaim a skipped codex source (`references/late-source-reclaim.md`), then merge locally and push `main`:

```bash
FEATURE_BRANCH="<from Setup>"
BASE_BRANCH="<from Setup>"
git checkout "$BASE_BRANCH" && git pull origin "$BASE_BRANCH"
git merge --no-ff "$FEATURE_BRANCH" -m "Merge branch '$FEATURE_BRANCH'"
git push origin "$BASE_BRANCH" && git branch -d "$FEATURE_BRANCH"
```

Push rejected (branch protection) → `git reset --hard origin/<base>`, `git checkout <feature>`,
continue on the hub path from Step 1's PR block. Report: "라이트 패스 완료 — main에 직접 병합 및
푸시됨. PR·CI 없음."

**Hub path** — follow `references/ci-failure-handling.md`: `scripts/ci-wait.sh <PR_NUMBER>`
(15 min; `reason:"rework-cap"`, `reason:"timeout"` and `reason:"checks-never-registered"` stop and ask), then reclaim a skipped codex source after CI green (`references/late-source-reclaim.md`), then:

```bash
SKILL_DIR="<absolute parent directory of the loaded SKILL.md>"
[[ -f "$SKILL_DIR/scripts/merge-and-cleanup.sh" ]] || { echo "Bundled merge helper unavailable: $SKILL_DIR/scripts/merge-and-cleanup.sh" >&2; exit 1; }
bash "$SKILL_DIR/scripts/merge-and-cleanup.sh" <PR_NUMBER> <BASE_BRANCH> <FEATURE_BRANCH> '<MERGE_STRATEGY_JSON>'
```

## Error handling

| Failure | Action |
|---------|--------|
| Bundled script unresolvable, or preflight `has_errors` | Stop, report |
| Commit rejected by commit-guard (`{"error": "commit blocked…"}`) | Fix the branch or the `[TYPE]`; never retry the same call |
| Guard crashed (traceback) or `guard_skipped: true` | Treat as unchecked — report; fix `guard.py`, do not work around it |
| Reviewer sentinel or >1200s | Inline review, note it in the report (this slot persists nothing) |
| Panel source fails, exits 75, or >1200s | Record `Reviewers Skipped: <reason>`, proceed; codex breach or failure → reclaim before merge |
| Contract finding still open after the one retry | Stop; no Step 5, no merge |
| CI `rework-cap` / `timeout` / `checks-never-registered` | Stop, ask the user |
| Merge fails (`merge_ok: false`) | Report; never force-delete |

Scripts: `preflight.sh` (probes, cached per branch), `commit-and-push.sh` (stage, guard, commit,
push, `--pr`; idempotent), `claude-review.sh`, `agy-review.sh`, `codex-review.sh`, `ci-wait.sh`
(3-strike counter), `ci-failure-logs.sh`, `merge-and-cleanup.sh`, `hub.sh` (GitHub / Forgejo
adapter the others call).
