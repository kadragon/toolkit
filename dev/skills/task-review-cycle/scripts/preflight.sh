#!/usr/bin/env bash
# Pre-flight checks for task-review-cycle
# Detects available tools and repository metadata, outputs JSON.
#
# Usage: preflight.sh [--no-hub] [--refresh]
#
# Per-cycle cache: one review cycle invokes this script from ~7 separate SKILL.md blocks, each
# block re-running it purely so it reads standalone. Every run costs two hub.sh round trips plus
# a `git fetch`. The result is cached at $(git rev-parse --git-dir)/task-review-cycle-preflight.json
# and served back when it is still valid, so only the first run in a cycle pays.
#
# Only the *expensive* fields are cached: hub type/auth and the repo metadata behind them. The
# tool probes (agy, codex, claude CLI, native engine) are plain `command -v` calls costing nothing,
# so they are re-run on every invocation and overlaid onto a cache hit. Caching them would let an
# entry written under one runtime be served to another within the TTL — the exact case that decides
# 2-1's launch path, so a stale `native_engine` would silently drop the Claude slot from the panel.
#
# Validity is keyed on the *current branch*, not on time alone: Setup runs before the cycle's
# Step 0 creates the feature branch, so a Setup-era entry names the wrong `feature_branch` the
# moment the branch is cut, and must not be reused. A cache hit therefore requires all of:
# same feature_branch, same --no-hub mode, has_errors false, and younger than the TTL.
# An errored result is never written, so a failure always re-surfaces on the next run.
#
# A cache hit still fast-forwards the local base branch. That sync is what keeps a downstream
# `git diff base...HEAD` from being scoped against a stale ref, and the base can move while a
# review panel waits — so it must not become a side effect only the first run of a cycle performs.
#
#   --refresh                  force a live run and rewrite the cache
#   PREFLIGHT_CACHE=0          disable the cache entirely (read and write)
#   PREFLIGHT_CACHE_TTL_MIN=N  TTL in minutes (default 15)

set -euo pipefail

# --- jq is required for all scripts in this workflow ---
if ! command -v jq >/dev/null 2>&1; then
  echo '{"has_errors": true, "errors": ["jq is required but not installed. Install via: brew install jq"]}' >&2
  exit 1
fi

# --- Keep local base branch current so downstream `git diff base...HEAD` isn't scoped against a
# --- stale ref (picks up already-merged commits otherwise). Only fast-forward: skip if it's
# --- checked out, has diverged, or fetch fails. Called on the live path AND on a cache hit —
# --- the base can move while a background review panel runs, so this cannot be a first-run-only
# --- side effect.
sync_base_branch() {
  local base="$1" feature="$2"
  [ -n "$base" ] || return 0
  if [ "$base" != "$feature" ] \
    && git show-ref --verify --quiet "refs/heads/${base}" 2>/dev/null \
    && git fetch -q origin "${base}" 2>/dev/null; then
    local local_sha remote_sha merge_base
    local_sha=$(git rev-parse "refs/heads/${base}" 2>/dev/null || true)
    remote_sha=$(git rev-parse "FETCH_HEAD" 2>/dev/null || true)
    if [ -n "$local_sha" ] && [ -n "$remote_sha" ] && [ "$local_sha" != "$remote_sha" ]; then
      merge_base=$(git merge-base "$local_sha" "$remote_sha" 2>/dev/null || true)
      if [ "$merge_base" = "$local_sha" ]; then
        git fetch -q origin "${base}:${base}" 2>/dev/null || true
      fi
    fi
  fi
}

NO_HUB=false
REFRESH=false
for arg in "$@"; do
  [[ "$arg" == "--no-hub" ]] && NO_HUB=true
  [[ "$arg" == "--refresh" ]] && REFRESH=true
done

errors=()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Per-cycle cache ---------------------------------------------------------
CACHE_ENABLED="${PREFLIGHT_CACHE:-1}"
CACHE_TTL_MIN="${PREFLIGHT_CACHE_TTL_MIN:-15}"
CACHE_FILE=""
if [ "$CACHE_ENABLED" != "0" ]; then
  GIT_DIR_PATH=$(git rev-parse --git-dir 2>/dev/null || true)
  [ -n "$GIT_DIR_PATH" ] && CACHE_FILE="${GIT_DIR_PATH}/task-review-cycle-preflight.json"
fi

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || true)

# --- Antigravity (agy) CLI ---
AGY_AVAILABLE=false
# Windows/Git Bash was once excluded here: agy.exe wrote through the Windows console API
# (text_drip renderer) instead of stdout, so `agy ... | tee` in agy-review.sh captured nothing.
# Fixed upstream — verified on agy 1.1.8 / MINGW64, where both `agy -p ... > file` and the
# review script's own `agy -p ... | tee` shape return the full response with PIPESTATUS 0 0.
# No platform gate: agy-review.sh already fails closed on empty or truncated output, which
# covers a regression better than a preflight probe (a probe costs an API round trip per run).
if command -v agy >/dev/null 2>&1; then
  AGY_AVAILABLE=true
fi

# --- Codex ---
# Plugin mode is strongly preferred: `codex-companion.mjs review --json` yields the final
# review alone, while the bare `codex review` CLI streams its whole session transcript.
# The companion ships at two layouts — a versioned plugin cache and the marketplace checkout:
#   ~/.claude/plugins/cache/<marketplace>/codex/<version>/scripts/codex-companion.mjs
#   ~/.claude/plugins/marketplaces/<marketplace>/plugins/codex/scripts/codex-companion.mjs
# Rank cached hits by the <version> component alone — sorting whole paths would compare
# <marketplace> first, letting a lexically-later marketplace supply an older companion (plain
# `head -1` is worse still: it picks the lexically-first, i.e. oldest, copy). Address that
# component by offset (`$(NF-2)`), not by matching the literal "codex" component: a marketplace
# directory may itself be named `codex`. Fall back to the marketplace checkout only when no
# cached copy exists. Plugin mode also needs node.
CODEX_AVAILABLE=false
CODEX_MODE="none"
CODEX_COMPANION_PATH=""
# Use globs instead of find for predictable plugin structure
CODEX_CACHED=$(ls ~/.claude/plugins/cache/*/codex/*/scripts/codex-companion.mjs 2>/dev/null \
  | awk -F/ '{print $(NF-2) "\t" $0}' || true)
CODEX_COMPANION=""
if [ -n "$CODEX_CACHED" ]; then
  # `sort -V` is absent on some BSD/macOS sorts. Falling through to CLI mode there would be the
  # exact silent degradation this block exists to stop, so retry with a plain lexical sort —
  # wrong only when versions cross a digit-count boundary, still better than no companion.
  CODEX_COMPANION=$(printf '%s\n' "$CODEX_CACHED" | sort -V -k1,1 2>/dev/null | tail -1 | cut -f2-)
  [ -z "$CODEX_COMPANION" ] && \
    CODEX_COMPANION=$(printf '%s\n' "$CODEX_CACHED" | sort -k1,1 | tail -1 | cut -f2-)
fi
if [ -z "$CODEX_COMPANION" ]; then
  CODEX_COMPANION=$(ls ~/.claude/plugins/marketplaces/*/plugins/codex/scripts/codex-companion.mjs \
    ~/.claude/plugins/*/codex/*/codex-companion.mjs 2>/dev/null | head -1 || true)
fi
if command -v codex >/dev/null 2>&1; then
  CODEX_AVAILABLE=true
  if [ -n "$CODEX_COMPANION" ] && command -v node >/dev/null 2>&1; then
    CODEX_MODE="plugin"
    CODEX_COMPANION_PATH="$CODEX_COMPANION"
  else
    CODEX_MODE="cli"
  fi
fi

# --- Native runtime engine + Claude CLI (cross-runtime Claude review) ---
# CLAUDECODE is set only when Claude Code is the driver; it does NOT leak into
# Codex sessions. (The inverse test is unreliable: the codex plugin sets
# CODEX_COMPANION_SESSION_ID even under Claude Code, so only the positive Claude
# test can be trusted.) Nothing branches the review slot on this any more:
# SKILL.md Step 2 shells out to claude-review.sh for every runtime, and reads
# claude_cli_available alone to decide whether that slot can run.
NATIVE_ENGINE="other"
[ -n "${CLAUDECODE:-}" ] && NATIVE_ENGINE="claude"
CLAUDE_CLI_AVAILABLE=false
command -v claude >/dev/null 2>&1 && CLAUDE_CLI_AVAILABLE=true

if [ -n "$CACHE_FILE" ] && [ "$REFRESH" = "false" ] && [ -f "$CACHE_FILE" ]; then
  # -mmin is honoured by both GNU and BSD find; an empty result means "older than the TTL".
  CACHE_FRESH=$(find "$CACHE_FILE" -mmin "-${CACHE_TTL_MIN}" 2>/dev/null || true)
  if [ -n "$CACHE_FRESH" ]; then
    CACHE_VALID=$(jq -r \
      --arg branch "$CURRENT_BRANCH" \
      --argjson no_hub "$NO_HUB" \
      'if (.feature_branch == $branch
           and .no_hub == $no_hub
           and (.has_errors // false | not))
       then "yes" else "no" end' "$CACHE_FILE" 2>/dev/null || echo "no")
    if [ "$CACHE_VALID" = "yes" ]; then
      # Overlay the freshly-probed tool availability: those fields are env-derived and free to
      # re-read, and serving a stale `native_engine` would send 2-1 down the wrong launch path.
      # Fast-forward the base branch too — it can move while a review panel waits, so that sync
      # must not be a side effect only the first run of a cycle performs.
      # --no-hub promises no remote access, and sync_base_branch fetches — so it is gated the
      # same way the live path gates it, not run unconditionally.
      if [ "$NO_HUB" = "false" ]; then
        CACHED_BASE=$(jq -r '.base_branch // ""' "$CACHE_FILE")
        sync_base_branch "$CACHED_BASE" "$CURRENT_BRANCH"
      fi
      jq \
        --argjson agy_available "$AGY_AVAILABLE" \
        --argjson codex_available "$CODEX_AVAILABLE" \
        --arg codex_mode "$CODEX_MODE" \
        --arg codex_companion_path "$CODEX_COMPANION_PATH" \
        --arg native_engine "$NATIVE_ENGINE" \
        --argjson claude_cli_available "$CLAUDE_CLI_AVAILABLE" \
        '.agy_available = $agy_available
         | .codex_available = $codex_available
         | .codex_mode = $codex_mode
         | .codex_companion_path = $codex_companion_path
         | .native_engine = $native_engine
         | .claude_cli_available = $claude_cli_available' "$CACHE_FILE"
      exit 0
    fi
  fi
fi

# --- Hub detection (GitHub via gh, Forgejo/Gitea via REST) ---
HUB_TYPE="none"
HUB_AUTHENTICATED=false
if [ "$NO_HUB" = "false" ]; then
  DETECT=$(bash "${SCRIPT_DIR}/hub.sh" detect 2>/dev/null || echo '{}')
  HUB_TYPE=$(jq -r '.hub_type // "none"' <<<"$DETECT")
  HUB_AUTHENTICATED=$(jq -r '.token_present // false' <<<"$DETECT")
  DETECT_ERRORS=$(jq -r '(.errors // [])[]' <<<"$DETECT")
  if [ -n "$DETECT_ERRORS" ]; then
    while IFS= read -r e; do errors+=("$e"); done <<<"$DETECT_ERRORS"
  fi
fi

# --- Repository metadata ---
FEATURE_BRANCH=$(git branch --show-current)

OWNER_REPO=""
BASE_BRANCH=""
MERGE_INFO='{}'

if [ "$NO_HUB" = "false" ]; then
  REPO_INFO=$(bash "${SCRIPT_DIR}/hub.sh" repo-info 2>/dev/null || echo '{}')
  OWNER_REPO=$(jq -r '.owner_repo // ""' <<<"$REPO_INFO")
  BASE_BRANCH=$(jq -r '.default_branch // ""' <<<"$REPO_INFO")
  [ -z "$BASE_BRANCH" ] && BASE_BRANCH="main"
  MERGE_INFO=$(jq -c '.merge_strategy // {}' <<<"$REPO_INFO")

  sync_base_branch "$BASE_BRANCH" "$FEATURE_BRANCH"
else
  # Detect base branch purely locally — no remote references
  BASE_BRANCH=$(git config init.defaultBranch 2>/dev/null || true)
  if [ -z "$BASE_BRANCH" ]; then
    for b in main master; do
      if git show-ref --verify --quiet "refs/heads/$b" 2>/dev/null; then
        BASE_BRANCH="$b"
        break
      fi
    done
  fi
  [ -z "$BASE_BRANCH" ] && BASE_BRANCH="main"
fi

# --- Build JSON safely with jq ---
ERRORS_JSON="[]"
if [ ${#errors[@]} -gt 0 ]; then
  ERRORS_JSON=$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)
fi

PREFLIGHT_JSON=$(jq -n \
  --argjson no_hub "$NO_HUB" \
  --arg hub_type "$HUB_TYPE" \
  --argjson hub_authenticated "$HUB_AUTHENTICATED" \
  --argjson agy_available "$AGY_AVAILABLE" \
  --argjson codex_available "$CODEX_AVAILABLE" \
  --arg codex_mode "$CODEX_MODE" \
  --arg codex_companion_path "$CODEX_COMPANION_PATH" \
  --arg native_engine "$NATIVE_ENGINE" \
  --argjson claude_cli_available "$CLAUDE_CLI_AVAILABLE" \
  --arg feature_branch "$FEATURE_BRANCH" \
  --arg base_branch "$BASE_BRANCH" \
  --arg owner_repo "$OWNER_REPO" \
  --argjson merge_strategy "$MERGE_INFO" \
  --argjson errors "$ERRORS_JSON" \
  '{
    no_hub: $no_hub,
    hub_type: $hub_type,
    hub_authenticated: $hub_authenticated,
    agy_available: $agy_available,
    codex_available: $codex_available,
    codex_mode: $codex_mode,
    codex_companion_path: $codex_companion_path,
    native_engine: $native_engine,
    claude_cli_available: $claude_cli_available,
    feature_branch: $feature_branch,
    base_branch: $base_branch,
    owner_repo: $owner_repo,
    merge_strategy: $merge_strategy,
    has_errors: (($errors | length) > 0),
    errors: $errors
  }')

# Cache only a clean result: an errored probe must re-run rather than be served back.
if [ -n "$CACHE_FILE" ] \
  && [ "$(jq -r '.has_errors' <<<"$PREFLIGHT_JSON")" = "false" ]; then
  printf '%s\n' "$PREFLIGHT_JSON" >"$CACHE_FILE" 2>/dev/null || true
fi

printf '%s\n' "$PREFLIGHT_JSON"
