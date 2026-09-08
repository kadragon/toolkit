---
name: task-review
description: >-
  Post-dev review cycle for this branch — commit, review, apply findings, merge (lite or PR+CI
  by diff size). Flags: --no-hub (local only), --auto (skip confirmation), --pr / --lite
  (force the merge path), --panel (add agy + Codex).
disable-model-invocation: true
---

# Dev Review Cycle

## Arguments

- `--no-hub` — commit locally, review, apply, stop. No push, PR, CI, or merge.
- `--auto` — skip the consolidation confirmation; apply every in-scope finding.
- `--pr` / `--lite` — force the PR+CI path or the direct-merge path. Default routes by diff size.
- `--panel` — add the agy and Codex engines. Auto on a security hit, a 300+ line diff, or a diff
  that adds or changes a shipped script under `dev/`/`prod/`.

Restate the Sprint Contract in the same invocation when the implementation was not yet verified
against it; the reviewer grades it.

Call the Skill tool with "dev:task-review-cycle", passing `--from task-review` **plus** this
invocation's `args` unchanged — e.g. `--from task-review --auto`. Forward it on every path,
including a bare `/task-review`. The whole workflow lives in `dev:task-review-cycle`.
