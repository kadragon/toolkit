# Workflows

Six workflows. Pick the primary one per cycle. The `code` cycle's step-by-step procedure ships with `dev:task-next` (`references/cycle.md`); this page states the contract. See `docs/delegation.md` for how to brief a sub-agent once you have decided to delegate.

## `plan` — Spec Generation

Expand a short prompt into a concrete spec.

1. Expand into `docs/design/{feature}.md`: user stories, high-level design, phased list. No granular implementation details.
2. Review with user. Do not proceed until approved.
3. Generate `backlog.md` items from approved spec.

Skip for trivial features (one-line skill fix, comment update).

Steps 1-2 are automated by `dev:task-spec` (synthesizes conversation + `dev:task-grill`
output into `docs/design/{slug}.md`; does not interview the user). Step 3 is automated by
`dev:task-tickets` (breaks an approved spec into vertical-slice `backlog.md` items in
dependency order, using a `*(blocked by: <n>-<slug>)*` marker for blocking). `dev:task-new`
routes ad-hoc, non-trivial free-text requests through this same
task-grill → task-spec → task-tickets chain automatically, then runs the resulting work through `code`.

## `code` — Implementation

Primary cycle for behavioral changes.

**Step 0: Branch**
Ensure you're on a feature branch. `git checkout -b <type>/<slug>` if on `main`.

**Step 1: Scope check**
Establish what the change touches. Look yourself first (1–2 searches). Spawn `explorer` only when
this cycle was directed to (by the user, or by the skill driving it) **and** the survey also clears
the global gate — 10+ files to read, or output that would flood main context.

**Step 2: Sprint Contract**
Before writing, define "done" in concrete, testable terms. Template in `docs/eval-criteria.md`.

**Step 3: Implement**
Implement directly. Delegate to `implementer` (with spec + conventions) only when the global
delegation bar is met — e.g. a backlog batch of independent items.

**Step 4: QA**
Run the Sprint Contract's lint/test command yourself. Independent verification happens in the
review cycle (Step 6): its single reviewer — a headless `claude -p` shell-out, not a subagent —
grades the diff against the contract, so the agent that implemented never certifies its own work.
Grading is read-only there; running the command stays here, which is why this step exists. `--tree` / `--all` verify per worktree with `qa-verifier`.

**Step 5: Version bump**
Bump `plugin.json` patch/minor/major per `docs/conventions.md`. Do this AFTER all skill changes, BEFORE committing.

**Step 6: PR + review cycle**
Call the Skill tool with "dev:task-review-cycle" and `args: --from <your skill name> --auto`, restating the Sprint Contract verbatim (the model-invoked half; `/task-review` is the human entry point and no skill may call it). The `--from` token is required — see `dev:task-review-cycle` → *Caller gate*. The cycle commits, reviews the diff against the contract, routes by diff size (direct merge under 100 lines, PR + CI otherwise), applies findings, and merges. Do NOT inline-manage it. It runs a signal-gated retrospect (`dev:harness-capture`) only when a correction or gotcha surfaced, so a durable lesson rides into the same commit.

## `draft` — Documentation

Write or update `docs/`. Ground every claim in current code. Never modify production code during draft. If the doc reveals a missing constraint, add to `backlog.md`.

## `constrain` — Architectural Enforcement

1. Write CI check or lint rule first.
2. Run it.
3. If current code violates → add to `backlog.md`, don't fix here.
4. Update `docs/architecture.md`.

## `sweep` — Garbage Collection

Run between features or on schedule (`bash tools/sweep.sh`).

- Run `tools/sweep.sh`
- List findings tagged `[doc]`, `[constraint]`, `[debt]`, or `[harness]`
- Fix trivials inline
- Leave complex items in `backlog.md`
- Assess whether harness components are still load-bearing (see `references/sweep-template.md`)

## `explore` — Research

State the question → research/prototype → report options and tradeoffs → do not commit. Flows into `plan` or `code` if approved.

---

## Handoff Files

To combat context anxiety within a session (including across compaction) or before spawning a fresh subagent/switching teammates, write `handoff-{feature}.md` to your scratchpad dir at the START (when context is fresh). This does NOT survive a new CLI session — for genuine multi-day continuity there is currently no supported mechanism; say so explicitly rather than implying otherwise.

Schema from `references/handoff-template.md`.

## Context Anxiety

Models prematurely wrap up work as context fills. Countermeasures:

1. Context resets over compaction for large tasks
2. Handoff files — write early, not when degraded
3. Sprint decomposition if quality drops mid-session

## Permitted Side-Effects

| Primary workflow | Permitted |
|-----------------|-----------|
| `code` | Add `[doc]` or `[constraint]` item to `backlog.md` |
| `code` | Update relevant docs after implementation |
| `draft` | Add `backlog.md` item when doc reveals missing behavior |
| `sweep` | Fix trivial `[doc]` items inline |

Not permitted: writing production code during `draft` or `sweep`.
