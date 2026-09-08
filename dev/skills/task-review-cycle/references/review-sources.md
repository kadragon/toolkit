# Panel Review Sources

The non-Claude engines. The Claude slot itself is not here: SKILL.md Step 2 calls
`scripts/claude-review.sh` in the foreground, the same way for every runtime, so there is no
engine-dependent branch left to document.

## Panel source launch

Launch the `--panel` sources in the turn **before** the reviewer call, `run_in_background: true`,
so they run while the reviewer holds the foreground for up to its 600s.

**The cycle never waits on them.** When the reviewer's array is in hand, whichever sources have
reported are consolidated and each one that has not is recorded as
`Reviewers Skipped: still running`; Step 3 begins there. A source that failed or exited 75 is
recorded with that reason instead. Nothing here is ever stopped — see SKILL.md Step 2 and
`late-source-reclaim.md`, which is what makes not waiting safe for codex.

Launch agy and codex as **two separate background tasks**, one block each. A single task id
cannot serve both: stopping it to close a breached agy would kill the codex child mid-run, and
`late-source-reclaim.md` then finds a `.pending` whose pid is dead — the late findings the reclaim
exists to recover are gone. Neither is stopped by the cycle (SKILL.md Step 2); the split is what
keeps that safe.

```bash
SKILL_DIR="<absolute parent directory of the loaded SKILL.md>"
[[ -d "$SKILL_DIR/scripts" ]] || { echo "Bundled scripts unavailable: $SKILL_DIR/scripts" >&2; exit 1; }
PREFLIGHT=$(bash "$SKILL_DIR/scripts/preflight.sh")
BASE_BRANCH=$(jq -r '.base_branch' <<<"$PREFLIGHT")
AGY_AVAILABLE=$(jq -r '.agy_available' <<<"$PREFLIGHT")
[[ "$AGY_AVAILABLE" == "true" ]] && { bash "$SKILL_DIR/scripts/agy-review.sh" "${BASE_BRANCH}" || echo '{"agy_review":"failed"}' >&2; }
```

```bash
SKILL_DIR="<absolute parent directory of the loaded SKILL.md>"
[[ -d "$SKILL_DIR/scripts" ]] || { echo "Bundled scripts unavailable: $SKILL_DIR/scripts" >&2; exit 1; }
PREFLIGHT=$(bash "$SKILL_DIR/scripts/preflight.sh")
BASE_BRANCH=$(jq -r '.base_branch' <<<"$PREFLIGHT")
CODEX_AVAILABLE=$(jq -r '.codex_available' <<<"$PREFLIGHT")
CODEX_MODE=$(jq -r '.codex_mode' <<<"$PREFLIGHT")
CODEX_COMPANION_PATH=$(jq -r '.codex_companion_path' <<<"$PREFLIGHT")
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

`codex_status` 75 is the workspace lock held by another cycle: skipped, not failed. Only
`codex-review.sh` persists a result; a run still going when the cycle moves on is reclaimed before
merge per `late-source-reclaim.md`.
