# Design: Harness Altitude Audit — is `task-*` over-constrained?

**Status:** analysis (no behavior change in this doc)
**Branch:** `plan/harness-altitude-audit`
**Type:** `[PLAN]` — revises `backlog.md`, produces new items.
**Supersedes the enforcement direction of:** `docs/design/task-graph-audit.md`

## Why this exists

`task-graph-audit.md` measured the `task-*` pipeline as a graph and found **5 of 12 edges
mechanically enforced**, filing 5 backlog items to close the rest. That framing has an unstated
premise: *an unenforced edge is a defect.* This doc tests that premise against published evidence
and against the repo's own token cost, and concludes the premise is wrong for roughly half the
filed work.

The audit's own diagnosis is not disputed. Its *ratio metric* is.

## Evidence

### 1. Prompt-resident instructions spend a finite attention budget

Anthropic's [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
states the constraint directly: *"LLMs have an 'attention budget' that they draw on when parsing
large volumes of context. Every new token introduced depletes this budget."* The design target is
*"the smallest possible set of high-signal tokens that maximize the likelihood of some desired
outcome."*

The same article names both failure modes of a system prompt. The one this repo is exposed to is
over-specification — *"hardcoding complex, brittle logic in their prompts to elicit exact agentic
behavior. This approach creates fragility and increases maintenance complexity over time."* And on
direction of travel: *"smarter models require less prescriptive engineering, allowing agents to
operate with more autonomy."*

Chroma's [Context Rot](https://www.trychroma.com/research/context-rot) (Hong, Troynikov, Huber,
2025-07-14) measured the degradation across 18 models: performance *"varies significantly as input
length changes, even on simple tasks"* — accuracy falls non-uniformly as input grows, well before
the documented context limit. Long instructions do not merely cost money; they cost
accuracy on the instructions themselves.

### 2. Harness verbosity can invert on capable models

[*It's Not the Capability: Harness Sensitivity Is Non-Monotone Across LLM Agent Tiers*](https://arxiv.org/pdf/2605.26731)
measures the same task under a light and a strict harness. On a frontier chat model the strict
harness **lost 29 points** (95.8% → 66.7%), which the authors name a *"harness-complexity paradox"*.
The failure signature matters: *"format_violation is the dominant harness-induced failure, never
wrong_answer"* — 25 of 26 failures under complex harness conditions. The models understood the task
and failed the ceremony. Note the finding is genuinely non-monotone: a frontier *reasoning* model
gained +4.2 under the strict harness. Verbosity is not universally bad — it is a cost that must be
paid for.

### 3. Process layers that don't tighten the acceptance condition subtract

[*Natural-Language Agent Harnesses*](https://arxiv.org/html/2603.25723v1) ablates one harness module
at a time from a basic agent:

| Module | SWE-bench Verified | OSWorld |
|--------|-------------------|---------|
| File-Backed State | **+1.6** | **+5.5** |
| Evidence-Backed Answering | +1.6 | 0.0 |
| Self-Evolution | **+4.8** | +2.7 |
| Dynamic Orchestration | 0.0 | +2.7 |
| Verifier | **−0.8** | **−8.4** |
| Multi-Candidate Search | **−2.4** | **−5.6** |

Their conclusion: modules *"help when they tighten the path from intermediate behavior to the
evaluator's acceptance condition, and help less when they mainly add local process layers whose
notion of success is only weakly aligned with the final benchmark."*

Read carefully before reusing: their **Verifier** is a *self*-checking stage inside the agent loop,
not an independent second agent. It does not directly indict `qa-verifier`. What it does indict is
adding *more* process layers whose success signal is local. Meanwhile **File-Backed State** — moving
state out of prose and into files/scripts — is the single most reliable positive in the table on
both benchmarks.

## The measurement the graph audit did not take

Enforcement mechanisms are not one thing. They split on cost, and the two halves point opposite ways.

| | Axis A — prompt-resident prose | Axis B — out-of-band checks |
|---|---|---|
| Where | `SKILL.md`, `docs/*.md` | hooks, CI jobs, lints |
| Token cost per run | full text, every invocation | ~0 (fires outside the model's context) |
| Failure when wrong | silent drift, attention dilution | loud — exit 2, red CI |
| Right move | **shrink aggressively** | add *selectively*, each one earns its place |

Current Axis A load for a single `task-next` run, before a single repo file is read:

```
dev/skills/task-next/SKILL.md   452 lines
docs/workflows.md               101
docs/conventions.md             197
docs/eval-criteria.md            83
docs/delegation.md               84
AGENTS.md                       ~100
                              ------
                        ≈ 8,500 words ≈ 12k tokens of procedure
```

Inside `task-next/SKILL.md` specifically:

| Region | Lines | Assessment |
|--------|-------|------------|
| Step 1 candidate gathering (`:38–156`) | 119 | ~95 of these restate, in prose, the logic of the bundled `backlog_candidates.py` — plus a 6-branch stderr diagnosis taxonomy. Textbook over-specification. |
| Pre-merge cleanup (`:307–358`) | 52 | three near-identical variants of one procedure, differing only in which file the task came from |
| QA delegation rationale (`:283–290`) | 8 | argues with the reader about *why* an exception to the delegation gate exists; instructs nothing |
| Edge cases (`:411–466`) | 56 | a 3-step shell diagnosis tree for "work already in flight" |

Line numbers are as of this branch's HEAD; the enumerated regions are the durable anchors.

And the CHANGELOG Entry Contract's `≤160 chars` rule is restated in **7 locations across 5 files**
(`docs/conventions.md`, `harness-invariants.md`, `task-new/SKILL.md`,
`task-next/SKILL.md` ×3, `batch.md`) — the backlog's own item says "four files" and
undercounts.

## Verdict on the premise

"5 of 12 edges enforced" reads as 42% complete only if 12/12 is the target. It is not. Score each
edge on three questions:

1. **Silent** — is the violation invisible *to the orchestrator, at its next decision point*? Not
   "invisible forever" — visible only in a log nobody reads still counts as silent.
2. **Costly** — does the damage **survive the session**? Three ways it can: it lands on
   `main`/remote, it corrupts tracked state, or it burns an unbounded resource a re-run does not
   reclaim (CI minutes, API spend, an unbounded retry loop). Damage a re-run undoes is not costly.
3. **Decidable** — does a file or an exit code settle it, with no model judgment?

Scoring, not a gate:

- **3/3** — mechanism warranted.
- **2/3** — warranted only if the residual failure is *unbounded* (escapes the session or compounds
  across runs). Otherwise document the rule and move on.
- **0–1/3** — process ceremony. It costs maintenance and a new failure mode, and buys a check the
  model was already passing. That is the −0.8 / −8.4 column.

The graded band exists because a strict AND-gate would discard a cheap check against a rare but
unbounded failure — an objection raised in review (see *Review* below) and accepted.

## Re-scoring the five filed items

| # | Item | Silent | Costly | Decidable | Verdict |
|---|------|:---:|:---:|:---:|---------|
| 4 | Script the deterministic `task-next`/`task-new` nodes; invoke `bump-version.sh` | — | — | — | **Promote to first.** Not enforcement at all — it *deletes* Axis A prose and moves it to code. This is File-Backed State (+1.6 / +5.5). |
| 5 | CHANGELOG Entry Contract lint | ✅ | ⚠️ merges fine, wrong forever | ✅ regex | **Keep.** Its real payoff is deleting 6 prose restatements, not the blocking. |
| 1 | qa-verifier gate on commit | ✅ | ✅ | ⚠️ proxy only | **Keep, descope.** 2.5/3. An evidence file proves *something ran*, not that it was independent, so the hook's acceptance condition must be restated as what it actually checks — "an evidence file exists and matches the current diff" — not "verification was independent". **Withdrawn — re-scored ≈0.5/3 and cut; see *Superseded* below.** |
| 7→2 | Review transport accounting | ❌ **verified, not assumed** | ❌ | ✅ | **Cut, 1/3.** See below. |
| 8→3a | *Semantic* same-fix detector (C2) | ❌ repeated failure is loud | ❌ bounded within the session | ❌ "same fix attempted" is a judgment call | **Cut, 0/3** — the local-process-layer class that measured negative. |
| 8→3b | *Numeric* cap on C3 (CI rework 3×) | ⚠️ | ✅ each rework burns CI minutes a re-run does not reclaim | ✅ count `ci-wait.sh` non-zero exits | **Re-file, low priority, 2.5/3.** Split out in review — see below. |

**#7 is cut on evidence, not on assumption.** The original scoring asserted "an unreturned slot shows
up as missing output"; review correctly flagged that as an unverified claim. Checking
`task-review/SKILL.md` settles it: `:90` gives each source a 600s budget and, on breach, records
`"Reviewers Skipped: timeout (>600s)"` in the consolidation table before proceeding; `:162` requires
every slot to send its array *even when empty* "so the slot is recorded as reviewed, not stalled";
`:281` repeats the rule in the edge table. Reviewed-but-empty and skipped are therefore already
distinct, and both are surfaced. What transport accounting would add is separating *died without
sending* from *timed out* — and both already route to the identical action (proceed with the
remaining sources, note the gap). A mechanism that changes no decision is diagnostics, not
enforcement.

**#8 needed splitting.** The original row scored one item that was really two, and the numeric half
does not deserve the semantic half's verdict. A hard attempt cap is decidable from exit codes; only
"is this the *same* fix?" needs judgment. C3 also fails the old, too-narrow definition of *costly*
but passes the corrected one, since CI minutes do not come back. C1 (qa retry 1×) is already
enforced by task-review's own flow and needs nothing; C2 stays cut.

**Edges #9, #11, #12 — scored individually, not struck as a group** (a fair objection in review):

| # | Edge | Silent | Costly | Decidable | Verdict |
|---|------|:---:|:---:|:---:|---------|
| 9 | Sprint Contract exists before implement | ⚠️ surfaces as a vague QA pass | ❌ same-session | ✅ `grep '^status: active' tasks.md` | 1.5/3 — cut. If item #1's commit hook ships anyway, adding this costs ~3 lines; take it then, do not file it now. |
| 11 | working-tree / plan-mode gate | ❌ a dirty tree is visible in every `git` call | ❌ | ⚠️ tree yes, plan-mode no | 0.5/3 — cut. |
| 12 | `task-new` ↔ `task-next` double entry | ✅ | ❌ duplicate selection is caught at pick time | ❌ | 1/3 — cut. |

## New work this audit adds (Axis A reduction)

Higher expected value than anything remaining on the enforcement side, because it pays every run.

1. **Tighten the guard, then delete the Step 1 hand-grep fallback** (~95 lines). The original
   version of this item claimed the existing guard already rejects the fallback's trigger state.
   Review disproved it: `task-next/SKILL.md:44` and `:115` test `[[ -d "$SKILL_DIR/scripts" ]]` —
   the **directory**, not the file. A missing, unreadable or non-executing
   `backlog_candidates.py`, or a `python3` failure, slips straight past it. So the guard must be
   fixed *first* — test the file and the script's exit status — and only then does deleting the
   fallback leave no uncovered state. *Tradeoff to accept explicitly:* the skill then stops instead
   of degrading when the script is unavailable. That is the correct failure mode for a bundled
   dependency; state it in one line where 95 stood.
2. **Collapse the three pre-merge cleanup variants** into one parameterized block plus a 3-row
   source table.
3. **Cut the QA delegation rationale** (the *QA (workflows.md Step 4)* exception paragraph) to a single sentence; move the argument to
   `docs/delegation.md` where it is read once, not every run.
4. **Single-source the CHANGELOG contract** — one canonical statement in
   `harness-invariants.md`, links everywhere else. Rides item #5's lint.

Target: `task-next/SKILL.md` 452 → **≈250 lines**, no capability removed.

**Acceptance criteria for the reduction** — "no capability removed" is the load-bearing claim and
the one most likely to be wrong, so it gets checked, not asserted:

- Enumerate every behavior in the current `SKILL.md` as a checklist *before* editing; each line
  deleted maps to a checklist row that is either preserved elsewhere or explicitly retired with a
  reason. A row that is neither is a regression.
- Record `wc -w` on the full load path before and after. The `12k tokens` figure in this doc is
  `wc -w × ~1.4`, an estimate — report the measured word delta, not a token claim.
- `backlog_candidates.py`'s existing test coverage must still pass, and the tightened guard from
  item 1 needs a test for each new failure mode (file missing, non-zero exit).

## Review

Reviewed by Codex (session `019fc290-cc42-7e50-bf62-3f2751dd1d05`) against this doc and the revised
`backlog.md`. Adopted, each of them a correction to this doc rather than a note on it:

1. The three-question test was a hard AND-gate with no weighting, so a cheap check against a rare
   but unbounded failure would be discarded. → replaced with a graded 3/3 · 2/3 · 0–1/3 scoring.
2. *Costly* was defined too narrowly (`main`/remote or tracked state only), excluding burnt CI
   minutes and unbounded loops. → definition widened; this is what re-admits C3.
3. *Silent* had no observation point. → pinned to the orchestrator's next decision point.
4. #8 conflated a semantic detector with a numeric cap; only the former needs judgment. → split,
   3b re-filed.
5. #6's stated acceptance condition still implied it enforces independence. → restated as what the
   hook literally checks.
6. #9/#11/#12 were struck as a group with no individual scores. → scored individually.
7. The fallback-deletion rationale rested on a guard that checks a directory, not a file. → item
   rewritten to fix the guard first. This was a factual error in the original doc.
8. The priority claim was declared, not measured. → acceptance criteria added above.

Rejected, with reason:

- *"#7's cut rests on an unverified assumption."* The premise was correct — the original scoring
  did assume it — but the conclusion survives verification. `task-review/SKILL.md` already
  distinguishes reviewed-empty from skipped and surfaces both — its *Collect Reviews* 600s-breach
  rule, the three "Reviewers Skipped: …" labels, and the reviewer prompt's *"Send the array even
  when it is empty ([])"* instruction. Cut stands, now on evidence.
- *"`bounded within one session` assumes away token and time cost."* Accepted in general and folded
  into the new *costly* definition, but it does not rescue C2 specifically: C2's blocker is
  Decidable, and a widened cost test cannot fix an undecidable predicate.

## Superseded (2026-08-03)

**Row #1 — "qa-verifier gate on commit", scored 2.5/3 "Keep, descope" — is withdrawn and cut.**
Re-scored to ~0.5/3 when the item reached implementation. The decisive finding is that the hook
cannot fire where the row assumed it would: `task-review/SKILL.md` Steps 1 and 5 commit through
`bash "$SKILL_DIR/scripts/commit-and-push.sh"`, and the real `git commit -m "$MESSAGE"` runs inside
that script, so `guard.py`'s `_is_git_commit()` sees only the `bash <script>` command string and
returns without checking. *Silent* and *Costly* also survive only on `task-next`'s lite
path — the full cycle gates every commit behind three reviewers, the P0/P1 verifier, and CI before
merge, which bounds the residual failure and so fails this doc's own "2/3 ships only if the residual
failure is unbounded" clause. Full reasoning and the re-file bar: *Cut — do not re-file without new
evidence* below.

That finding also invalidates the second bullet below as written. It was re-filed as a 3/3 `[FIX]`
and shipped in dev v4.0.33 (`guard.py`'s `--precommit-check` mode, called from
`commit-and-push.sh`). The residual gap — merges into a protected branch, which are not `git
commit` and so still pass unguarded — was filed, then **scored ≈1/3 and cut**: neither known site
is an unintended landing (`merge-and-cleanup.sh`'s `--ff-only` runs only after the remote merge
succeeded and merely fast-forwards local `main` onto an already-pushed commit; `task-next`'s lite
path merges by explicit user opt-in at Step 2.5), and the only opt-out `guard.py` implements is the
repo-wide allow-main marker that both guards read — so exempting the lite path would also disable
the branch guard on `git commit`. Full grounds and the re-file bar: *Cut — do not re-file
without new evidence* below.

## Cut — do not re-file without new evidence

Moved here from `backlog.md` (2026-09-08): a cut item is audit state, not queued work.

Re-filing requires evidence of the specific kind each item failed on, not a restated intuition:

- **commit-guard merge coverage** — cut at ≈1/3 after scoring, which is what the item itself asked for before any build. Both named sites were read, and neither is a mistake to catch. (1) `merge-and-cleanup.sh:86–89` runs its `git merge --ff-only FETCH_HEAD` only inside `if [ "$MERGE_OK" = "true" ]` — the remote PR merge has already landed — and immediately after `git fetch origin "$BASE_BRANCH"`, so it fast-forwards local `main` onto a commit that is already on the remote. It creates no state and pushes nothing; there is nothing there to guard. (2) `task-next`'s lite path merges to `main` **by design**, reached only when the user picks `[1] 라이트 패스` at Step 2.5 — a decision, not the unintended landing the commit guard exists for. (3) Decisive: the only opt-out `guard.py` implements is the repo-wide `<!-- commit-guard: allow-main -->` marker read by `_marker_present`, and both guards consult it. Marking the repo to let the lite path merge would also switch off the branch guard on `git commit` — trading a 3/3 mechanism for a 1/3 one. A separate marker avoids that only by adding a second opt-in surface to maintain. *Silent* and *Costly* therefore rest on a hypothetical third site; only *Decidable* holds outright. Re-file only with a recorded incident where a merge landed on `main` unintentionally — not from either site above.
- **qa-verifier evidence check (edge #6)** — cut on verified grounds, re-scored from 2.5/3 to ~0.5/3. Three findings, in order of decisiveness. (1) *Decidable fails outright:* the gate cannot fire where the item assumed it would — `task-review` commits through `commit-and-push.sh`, which `commit-guard` did not see at the time this was cut (`docs/design/harness-altitude-audit.md` → *Superseded*, which also records the dev v4.0.33 `--precommit-check` fix that closed it). (2) *Silent and Costly hold only on the lite path:* the full cycle puts every commit through three reviewers, the P0/P1 verifier agent, and CI before merge, so a skipped QA is caught pre-merge and the residual failure is bounded — failing the doc's own "2/3 ships only if the residual failure is unbounded" clause. Only `task-next`'s lite path (direct `merge --no-ff` + push to `main`, no PR, no CI) leaves it unbounded. (3) *The diff match is unworkable even if (1) were fixed:* `task-review` Step 5 commits code edited in Step 4 — review findings applied **after** QA ran — so the evidence hash is stale on every cycle where any finding is applied, and excluding bookkeeping files does not help because these are real code edits. Separately, the gated actor holds the write primitive: an orchestrator with Bash can create the evidence file in one command, so the hook cannot establish even that *something* ran. Re-file only with a recorded cycle where QA was skipped on the lite path and the miss reached `main`.
- **Review transport accounting (edge #7)** — cut on verified grounds: `task-review/SKILL.md` already distinguishes reviewed-empty from skipped and surfaces both — see its *Collect Reviews* 600s-breach rule, the three "Reviewers Skipped: …" labels, and the reviewer prompt's *"Send the array even when it is empty ([]) so the slot is recorded as reviewed, not stalled"* — and both route to the same action. Re-file only with a recorded cycle where the two states led to *different* correct actions.
- **Semantic same-fix detector (edge #8, C2)** — failed Decidable. Re-file only with a deterministic predicate (an exact rule over files/exit codes) that does not require judging whether two attempts are "the same fix".
- **Edges #9, #11, #12** — scored 1.5/3, 0.5/3, 1/3 individually. #9 (assert `tasks.md` has a `status: active` block) was only ever viable as ~3 lines riding inside the edge #6 hook; with #6 cut it has no carrier and does not stand alone at 1.5/3. All three need a recorded failure that escaped the session.

## What this does not claim

- Not an argument against mechanical enforcement. Golden Principle 1 holds — the CI jobs are
  exactly right, and all five already-enforced edges stay. The commit-guard hook is the right
  shape, but see *Superseded* above: neither of its two guards reached the `task-review` commit
  path until dev v4.0.33 wired `--precommit-check` into `commit-and-push.sh`, so its coverage was
  overstated here.
- Not an argument that `qa-verifier` should go. Independence is a correctness property, not process
  ceremony, and the cited Verifier ablation measures a self-check stage, not an independent agent.
- Not a claim that any of this is measured *in this repo*. The evidence is external; the
  repo-specific numbers here are line counts, not accuracy deltas. No A/B was run.

## Explicitly out of scope

- Rewriting `harness-init` / `harness-curate` — already exempted as judgment-heavy, unchanged.
- Removing the `dev/hooks/commit-guard` hook or any `harness-check.yml` job.
