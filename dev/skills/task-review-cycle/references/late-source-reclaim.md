# Late Review-Source Reclaim

A panel source that has not reported by the time the reviewer returns is recorded as skipped and
the cycle proceeds — but the process does not stop, and its findings can still be real. This is
the step that collects them before the merge closes the window.

**Only `codex-review.sh` persists a result, so only the codex panel source is reclaimable.** The
reviewer slot (`claude-review.sh`) and `agy-review.sh` write no sidecar, and a codex run that
exits 75 (another cycle holds the workspace lock) never started one either. For those, a source
that never reported leaves nothing on disk to come back for — the inline fallback stands.

## Why a late return is structural, not a tail

`agy-review.sh` caps itself (`--print-timeout 15m`) and so fails reportably on its own.
`codex-review.sh` has no internal deadline, and the cycle no longer waits on either: it moves on
as soon as the reviewer's array is in hand, which stops the *cycle* listening but never stops the
*run*. So a late codex return is the expected shape, not an anomaly — three consecutive cycles
(PR #260, #263, #264) returned late, and #260's late output named two real defects that had to
land in a follow-up PR after the merge. Do not "fix" this by killing the run at a deadline: that
discards exactly the findings this step exists to recover.

## Where a late result lands

`codex-review.sh` persists every finished run under `CODEX_REVIEW_RESULT_DIR`, defaulting to
`$(git rev-parse --absolute-git-dir)/codex-review` — inside the git dir, so per-worktree, never
tracked. Key is the branch name with non-`[A-Za-z0-9._-]` runs collapsed to `-`, then leading
and trailing `-` stripped.

| File | Meaning |
|------|---------|
| `<key>.pending` | the run has not finished; carries `pid=` (this bash process — probe with `kill -0`, never `tasklist`) |
| `<key>.review.txt` | the full, untruncated review text (stdout may have been head/tail truncated) |
| `<key>.meta` | written last, so its presence means the review file beside it is complete |

`.meta` fields: `pid`, `started_at`, `mode`, `branch`, `base`, `head_sha`, `status`, `exit_code`,
`finished_at`, `elapsed_seconds`, `review_file`. `status` is `ok` (a review was produced),
`failed` (the companion exited non-zero) or `empty` (it ran but produced no extractable review).

The key is lossy — `feat/x-2` and `feat-x-2` sanitize to the same name — and a file can also be
left from an earlier cycle on this branch. So before using a result, check that its `branch`
matches the current branch and that `started_at` is later than this cycle's launch. A `.meta`
that fails either check belongs to a different run: leave it alone.

`timings.log` in the same directory gets one line per run —
`<iso8601> elapsed=<N>s mode=<...> status=<...> files=<N> lines=<N> branch=<raw branch>`. It is the
evidence for any future argument about how much runway the companion needs: elapsed alone cannot
separate "the companion is reliably slower than the cycle" from "that diff was unusual", so diff
size is recorded beside it. Argue from this log, not from a single cycle's impression.

## Pre-merge reclaim

Run this **immediately before the merge command**, when the codex panel source was recorded as
`Reviewers Skipped` this cycle — still running, or failed. On the hub path that means *after*
`ci-wait.sh` returns green — the CI wait is free runway for a slow companion, so reclaiming
earlier throws it away.

The key derivation must match `sanitize_key` exactly, trailing-hyphen strip included, or a branch
like `fix-` looks up `fix-.meta` while the script wrote `fix.meta`:

```bash
RESULT_DIR="${CODEX_REVIEW_RESULT_DIR:-$(git rev-parse --absolute-git-dir)/codex-review}"
KEY=$(git rev-parse --abbrev-ref HEAD \
  | sed -e 's/[^a-zA-Z0-9._-][^a-zA-Z0-9._-]*/-/g' -e 's/^-*//' -e 's/-*$//')
cat "$RESULT_DIR/$KEY.meta" 2>/dev/null || cat "$RESULT_DIR/$KEY.pending" 2>/dev/null || echo "no result"
```

| State | Action |
|-------|--------|
| `.meta` with `status=ok` and a non-empty `review_file` | Read the review file. Put its findings through `references/consolidation-guide.md` and Step 4 apply, exactly as an in-time source. A resulting change commits via `commit-and-push.sh`; on the hub path that re-enters CI — wait for it green again, and say in the report that the reclaim cost an extra CI round. |
| `.pending` only, `pid` alive under `kill -0` | The source is still running. Merge, and report the `.meta` path the user can read when it lands. |
| `.pending` only, `pid` dead | The run died without a result. Nothing to reclaim; the `Reviewers Skipped` line stands. |
| `.meta` with `status=failed` or `empty`, or no files at all | Nothing to reclaim; the `Reviewers Skipped` line stands. |
| `.review.txt` and `.pending` but no `.meta` | The meta write failed after the review landed. Read the review file directly and treat it as `status=ok`. |

`head_sha` in the meta is the commit the late review actually read. When it does not match the
branch's current HEAD — a fix round landed after the source was launched — the findings may
already be closed; re-read the diff before applying, per the consolidation guide's step 2.

## Post-merge arrival

A result that surfaces after the merge is **reported, never auto-filed**. Name the `.meta` and
`.review.txt` paths and the branch they reviewed, and let the user route it.

Do not append it to `## Review Backlog` automatically. The branch is merged, so the findings are
unverified against current `main`, and PR #263 is the recorded case where every late finding had
already been closed by the fix round — auto-filing would have queued two dead items.
