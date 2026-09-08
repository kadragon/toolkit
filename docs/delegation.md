# Delegation

**This file does not decide *whether* to delegate — it defines *how*, once that decision is made.**
The threshold lives in your platform's global instruction layer — `~/.claude/CLAUDE.md` (Claude
Code) or `~/.codex/AGENTS.md` (Codex). Default inline. Delegate only when the user asks or a skill
directs — **and** only if the work then also clears the global gate (10+ files to read/summarize ·
3+ truly independent units · output would flood main context). Both conditions, not either.
Coupled, sequential, or judgment-heavy work stays inline. This repo imposes no lower bar.

## Pattern Selection

```
Q1. Does the task decompose into >1 genuinely parallel subtask?
    No  → single session. No delegation. Stop.
    Yes → Q2.
Q2. Do subtasks need to share findings mid-flight?
    Yes → Agent Team (Agent with name: + SendMessage)
    No  → Sub-agent (Agent tool, run_in_background ok)
```

Most work in this repo is sequential: explore → implement → verify. Default to sub-agent mode.

## Role Routing

No row below is a gate. When the threshold above is met, match the job to the role:

| Job | Delegate to | Model | Context to pass |
|-----|-------------|-------|-----------------|
| Read-only map of an unexplored plugin area | `explorer` | sonnet | Plugin dir path |
| Implementation task from `backlog.md` | `implementer` | sonnet | Backlog item, conventions, target files |
| Verifying an implementation | `qa-verifier` | sonnet | Modified files, test/lint commands |
| Skill quality assessment requested | `skill-evaluator` | opus | Skill path, eval-criteria.md |

`qa-verifier` never runs on its own output — whoever implemented must not be the one who verifies.
That constraint holds whenever a verifier runs; it does not by itself mandate spawning one.

**Why the review cycle reviews out-of-process.** `task-review-cycle` always runs one reviewer,
which runs `code-review` and grades the Sprint Contract. What that buys is **independence** — a
check by something that did not write the code — which is a correctness property, not a volume
one: a 1-file fix needs it as much as a 20-file one. It is not a subagent: the cycle shells out to
a headless `claude -p` (`scripts/claude-review.sh`) in the foreground, because the Bash tool
enforces a timeout while the `Agent` tool does not, and an agent's completion notification can be
lost (upstream claude-code #49150, #58637, #68117) — which stalled cycles on reviews that had
already finished. A headless process also carries no session context, so independence is stronger
there, not weaker. `task-next --tree` / `--all` keep a per-worktree `qa-verifier` for the same
correctness reason. Every other delegation still requires both conditions.

## Background Routing (non-blocking)

| Trigger | Delegate to | Context |
|---------|-------------|---------|
| Every PR | `dev:task-review-cycle` skill, with `--from <your skill name>` (`/task-review` is the human entry point and supplies the token itself) | PR number or current branch |
| Harness check request | `dev:harness-curate` skill | — |

## Escalation

| Trigger | Action |
|---------|--------|
| Same failure ×2 | `codex:rescue` with an explicit brief — what failed, what was already tried |
| Once the cause is known | Encode the fix mechanically (hook/lint/test) per the global harness-ratchet rule so it cannot recur |

## Spawn Prompt Contract (all 4 fields mandatory)

Every `Agent(...)` call must include:

```
- Objective: {what specifically to accomplish}
- Output format: {diff / report / table / verdict}
- Tools to use: {subset of role's allowlist}
- Boundaries: {files/modules this spawn must NOT touch}
```

Missing any field → reject and rewrite the spawn prompt.

## Effort Tier

Embed in every spawn prompt:

| Tier | Use for | Tool calls | Model |
|------|---------|------------|-------|
| Simple | Known-answer lookup, single-file edit, mechanical check | 3–10 | haiku/sonnet |
| Comparison | Weighing options, multi-file review, cross-module check | 10–15 | sonnet |
| Complex | Root cause unknown, architectural decision | 15+ | opus |

## Data Transfer Protocols

| Strategy | Mechanism | Use when |
|----------|-----------|----------|
| Return value | Agent tool result | Sub-agent reports to orchestrator |
| File-based | Session scratchpad dir, `{phase:02d}_{agent}_{artifact}.{ext}` | Large artifacts, cross-phase handoff |
| Task-based | `TaskCreate`/`TaskUpdate` | Progress tracking, dependency gates |

Naming: `{phase:02d}_{agent}_{artifact}.{ext}` — e.g. `01_explorer_map.md`, `02_implementer_diff.md`.

The orchestrator determines its scratchpad path once (from its own system prompt) and embeds the full path explicitly in every spawn prompt — sub-agents must not guess or reconstruct it. Scratchpad is ephemeral: gone when the session ends, no cross-session resume.

## Result handoff

A role-file agent (`.claude/agents/*.md`) runs under its `tools:` allowlist, and none of those
lists grants `SendMessage` — as a subagent or as a named teammate. It reports through its **final
output**, which reaches the orchestrator as the Agent tool result (the completion notification for
a background spawn) — brief it to put the full result in its final response and never finish
silently, even when the result is empty or the run failed. Brief `SendMessage(to: "main")` only to
a spawn whose tools actually include it: a bare `Agent` with no `subagent_type`; never to a
role-file agent. Do not rely on it as the only channel — a lost notification is a known upstream
failure, which is why the review cycle returns its findings over a shell boundary instead.
