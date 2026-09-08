# Backlog

## Harness — `task-*` edge enforcement (rescoped)

Source: `docs/design/task-graph-audit.md`, re-scored in `docs/design/harness-altitude-audit.md`.
Each edge is scored on three questions — **Silent** (invisible to the orchestrator at its next
decision point), **Costly** (damage survives the session: lands on `main`/remote, corrupts tracked
state, or burns a resource a re-run does not reclaim), **Decidable** (a file or exit code settles
it). 3/3 ships; 2/3 ships only if the residual failure is unbounded; 0–1/3 is ceremony.

Cut items and their re-file bars live in `docs/design/harness-altitude-audit.md` →
*Cut — do not re-file without new evidence*. Nothing from this group is queued.

## Review Backlog

### PR #272 — review slot shell-out follow-ups

- [ ] [HARNESS] Re-fit `agy-review.sh`'s `--print-timeout` to the reviewer's runway — the Claude slot now holds the foreground for at most 600s and the cycle no longer waits past it, so agy's 15m self-cap means it will almost never report in time; decide the new cap against `timings.log` per `late-source-reclaim.md`, not against one cycle
- [ ] [HARNESS] Give the `--lite` merge path some panel runway — the reclaim's free runway is `ci-wait.sh`, which lite skips, so a codex source is always `.pending` at reclaim and its findings land strictly post-merge; small shipped-script edits auto-enable `--panel` and route lite, so this is the common path
- [ ] [DOCS] Close or annotate row 7 of `docs/design/task-graph-audit.md` — it still lists the `2-1 Agent-path review slot → SendMessage` gap as an open P0 and calls `claude-review.sh` the non-Claude fallback; PR #272 removed both *(deferred: audit doc, no runtime effect)*
- [ ] [HARNESS] Convert the remaining interpolated free-text assignments in `task-review-cycle/SKILL.md` to quoted heredocs — `COMMIT_MESSAGE="<[TYPE] derived message>"` at three blocks (Step 1 twice, Step 5) is the same injection class PR #272 fixed for `CONTRACT`; this repo's commit subjects do carry backticks (`[HARNESS] drift linter fails on `2a.`-style ordered-list markers`), so the wrong form runs them. Rule now in `docs/conventions.md` → *Capturing free text*. Needs ~6 lines, and the file sits at the 250-line cap, so it lands with a trim
- [ ] [HARNESS] Revisit the reviewer budget — the Bash tool caps `timeout` at 600000 ms, half the old 1200s, while the slot does more work in a colder headless session; on timeout the documented fallback is inline review by the agent that wrote the code, which is the one case where the independence property does not hold

### PR #254 — memory-guard follow-ups

- [ ] [FEAT] Gate shell-based memory writes in `memory-guard` — the hook matches `Write|Edit` only, so `printf ... > ~/.claude/projects/<slug>/memory/note.md` writes ungated; `commit-guard`'s PreToolUse(Bash) static command analysis is the precedent to follow *(deferred: no shell-path memory write has been observed; the other four PR #254 follow-ups shipped without it in PR for 4.9.6 — revisit against a recorded case)*
