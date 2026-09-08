# Review Sources Other Than the Agent Slot

## Non-Claude engine fallback

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

## Panel source launch

The `--panel` sources, launched in the same turn as the reviewer, each `run_in_background: true`
with a 1200s wait. A source that fails or breaches is recorded as `Reviewers Skipped: <reason>`
and the cycle proceeds on the rest.

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
`codex-review.sh` persists a result; a breached run is reclaimed before merge per
`late-source-reclaim.md`.
