# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Tech AI Journaling** — career-coaching journaling bot. Users interact via Telegram; Claude acts as a coach (asks deepening questions, never gives ready answers). Memory is hierarchical RAG: daily journal → weekly/monthly/yearly condensations + a long-lived "amphitheater" of values, current goal, and insights.

Stack: **n8n** (orchestration) + **Supabase** with pgvector (data + embeddings) + **Claude `claude-sonnet-4-6`** (dialog/analysis) + **OpenAI text-embedding-3-small** (1536-dim embeddings) + **Telegram Bot API** (UI).

Single-user today, multi-user-ready schema (every table carries `user_id`, identified by `telegram_id`). All in-workflow comments and Claude prompts are **in Polish** — match that language when editing existing nodes.

## Architecture

11 modular workflows in `workflows/*.json`. Each is mirrored 1:1 in n8n; live IDs are tracked in `docs/plans/2026-03-13-techjournaling-design.md` (update that table when you add or rename a workflow).

**Two sub-workflows** (called via `Execute Workflow`):
- `memory-retrieval` — `{ user_id, context_type, query_text }` → maps `context_type` to a vector table + RPC, runs semantic search, fetches the full `amphitheater`, returns `{ context }`.
- `amphitheater-update` — `{ user_id, weekly_condensation_text }` → Claude extracts insights → inserts into `amphitheater` via `Default Data Loader`.

**Entry point — `telegram-router`** (Telegram webhook): extracts message + telegram_id → looks up user → checks active onboarding/goal session → Switch routes:
- `/start` → `onboarding` (multi-turn dialog → `onboarding_profile` + amphitheater seed)
- `/goal` → `goal-change` (multi-turn → new SMART goal as new `amphitheater` row, marking the old one with `metadata.superseded_at`)
- `/export` → `export` (full user dump as a Telegram document)
- no command → `journal-entry` (memory retrieval → save entry → Claude coach picks a persona → one deepening question)

**Cron workflows** (currently inactive — activate manually after testing):
- `weekly-processing` (Sat 23:00) — condenses the week → `weekly_condensations` + plan → `weekly_plans` + amphitheater update; conditionally rolls up to monthly/yearly.
- `weekly-summary` (Sun 08:00) — sends the user the previous week's condensation + plan + inconsistencies.
- `monthly-summary` — monthly rollup.
- `daily-reminder` (18:00 daily) — personalized journal reminder; skipped when monthly mode is active.

**Conditional RAG** — the time horizon picks the source; `amphitheater` always comes back in full because it's small and is the user's "foundation":

| Horizon | Source |
|---|---|
| Daily dialog | last 7–14 days of `journal_entries` (semantic) + `amphitheater` |
| Weekly summary | `journal_entries` for that week (date filter) + `amphitheater` |
| Monthly | `weekly_condensations` for that month + `amphitheater` |
| Yearly | `monthly_condensations` for that year + `amphitheater` |
| Since inception | `yearly_condensations` + `amphitheater` |

## Data model (Supabase)

Vector tables use the **n8n-native shape**: `content` column (NOT `text`), `metadata jsonb`, `embedding vector(1536)`, plus a dedicated `user_id uuid FK` column.

n8n's Vector Store insert only writes `content`/`metadata`/`embedding`; the `user_id` FK column is back-filled by a `BEFORE INSERT` trigger from `metadata->>'user_id'` (see `supabase/migrations/002_user_id_triggers.sql`). RPC `match_*` functions filter by the FK column directly for efficient per-user search.

Vector tables: `journal_entries`, `weekly_condensations`, `monthly_condensations`, `yearly_condensations`, `amphitheater`, `weekly_plans`. Non-vector: `users`, `onboarding_profile`, `onboarding_sessions`, `task_completions`.

New migrations: `supabase/migrations/NNN_*.sql`, applied via the Supabase MCP (`mcp__supabase__apply_migration`).

**Goal history convention:** new goal = new row in `amphitheater` + `metadata.superseded_at = now()` on the previous one. Current goal lookup: `metadata->>'category' = 'goal' AND metadata->>'superseded_at' IS NULL`.

## Critical n8n patterns (read before editing workflows)

These traps are documented in the design doc under "Znane pułapki implementacyjne" — the same ones will re-bite you if ignored.

1. **Vector Store insert MUST use `Default Data Loader` on the `ai_document` port**, JSON mode:
   - `dataType: "json"`, `jsonMode: "expressionData"`, `jsonData: "={{ $json.pageContent }}"`
   - Metadata: each key as a separate field referencing `$json.metadata.*`
   - The upstream "Prepare" Code node must return `{ pageContent: "...", metadata: {...} }`, one item per row.
   - Without this the loader treats the whole item as a blob and explodes every JSON value into its own row.

2. **`Execute Workflow` can return N items** → the next node (e.g., Telegram send) fires N times. After any `executeWorkflow` whose output feeds a side-effecting node, add a `Normalize Complete` / `Collapse Output` Code node with `runOnceForAllItems: true` to collapse to a single item.

3. **Supabase `IS NULL` filter:** use the **string** `"null"`, not JS `null`. JS `null` produces a broken `user_id=is.`; the string produces `user_id=is.null`.

4. **`alwaysOutputData: true`** on `Supabase Vector Store` (load) and `Supabase` (getAll) nodes that may return zero rows — without it, downstream nodes don't fire on a fresh-user / empty-DB path.

5. **Multi-turn dialogs** (onboarding, goal-change) keep state in `onboarding_sessions.state`. Every workflow that participates must read+write this and clear it on `complete`. The router consults this session before applying its Switch so an in-flight onboarding/goal flow takes precedence over command parsing.

## Workflow sync discipline

Workflows exist in two places: `workflows/<name>.json` (canonical, in repo) and the live n8n instance. **They must stay structurally equivalent.**

- Always write the JSON file *first*, then push via `mcp__n8n-mcp__n8n_update_full_workflow` (or `n8n_create_workflow` for new ones).
- If a change happens in the n8n UI, immediately mirror it back to the local JSON (pull via `mcp__n8n-mcp__n8n_get_workflow`).
- Credentials are referenced **by name** in JSON (e.g., `"Supabase account"`) — never paste secrets.
- Validate before pushing: `mcp__n8n-mcp__validate_workflow` and `mcp__n8n-mcp__n8n_validate_workflow`.

## Skills to prefer

- `n8n-mcp-skills:n8n-workflow-patterns` — architectural patterns
- `n8n-mcp-skills:n8n-node-configuration` — configuring individual nodes
- `n8n-mcp-skills:n8n-code-javascript` — JS in Code nodes
- `n8n-mcp-skills:n8n-expression-syntax` — `{{ }}` expressions and `$json` / `$node` / `$input`
