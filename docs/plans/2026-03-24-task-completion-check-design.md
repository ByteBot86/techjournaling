# Task Completion Check — Design Document

**Status:** Zaakceptowany
**Data:** 2026-03-24

## Overview

Rozszerzenie systemu o sprawdzanie realizacji zadań z Google Tasks na przestrzeni tygodnia. Dane o realizacji zasilają kondensację tygodniową (sobota) i wiadomość niedzielną.

## Zasada liczby tasków

Łączna liczba tasków w Google Tasks dla danego tygodnia ≤ 4.
Niewykonane taski z poprzedniego tygodnia **pozostają** w Google Tasks bez zmian.
Claude generuje wyłącznie **nowe** taski: `max_nowych = 4 − incomplete_count`.

## Nowa tabela Supabase

```sql
create table task_completions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  week_start date not null,
  completed jsonb default '[]',   -- ["Tytuł taska 1", ...]
  incomplete jsonb default '[]',  -- ["Tytuł taska 2", ...]
  created_at timestamptz default now()
);
create index on task_completions (user_id, week_start);
```

Brak embeddingów — tabela służy tylko do przekazania danych między workflow (sobota → niedziela).

## Zmiany w `[TJ] weekly-processing`

### Nowe węzły (przed `Get Journal Entries`)

```
Set User
  └─→ Get Weekly Tasks        (Google Tasks getAll, showHidden: true, showCompleted: true)
        └─→ Collect Task Status  (Code — rozdziela completed/incomplete, filtr po created ostatnie 7 dni)
              └─→ Save Task Completions  (Supabase insert → task_completions)
                    └─→ Get Journal Entries  (istniejące)
```

**`Get Weekly Tasks`** — `getAll`, `showCompleted: true`, `showHidden: true` — żeby widzieć ukończone.

**`Collect Task Status`** — Code node:
- Filtruje taski po `created` >= 7 dni temu
- Rozdziela na `completed` (status = "completed") i `incomplete` (status = "needsAction")
- Oblicza `incomplete_count` i `max_new_tasks = max(0, 4 - incomplete_count)`
- Output: `{ completed_tasks, incomplete_tasks, incomplete_count, max_new_tasks, week_start }`

**`Save Task Completions`** — Supabase insert do `task_completions`.

### Zmiany w istniejących węzłach

**`Build Weekly Prompt`** — dodaje do promptu sekcję:
```
REALIZACJA ZADAŃ Z MINIONEGO TYGODNIA:
✅ <completed_tasks>
❌ <incomplete_tasks>
```

**`Build Tasks Prompt`** — zmiana: `max_new_tasks` zamiast stałego "3-5", z informacją że niewykonane już istnieją w Google Tasks i nie należy ich ponownie tworzyć.

## Zmiany w `[TJ] weekly-summary`

### Nowe węzły (po `Set User`, przed `Get Weekly Condensation`)

```
Set User
  └─→ Get Task Completions  (Supabase getAll z task_completions, filtr user_id + week_start >= 7 dni temu)
        └─→ Get Weekly Condensation  (istniejące)
```

**`Build Summary Prompt`** — dodaje sekcję realizacji zadań do promptu Claude:
```
REALIZACJA ZADAŃ Z MINIONEGO TYGODNIA:
✅ <completed>
❌ <incomplete — do uwzględnienia w tym tygodniu>
```

## Znane pułapki

- **Google Tasks API `created` field** — API zwraca taski posortowane domyślnie, filtrowanie po dacie wymaga JS-owego porównania dat po stronie Code node (brak server-side date filter w n8n Google Tasks node)
- **Pusta lista tasków** — pierwszy tydzień: brak tasków z poprzedniego tygodnia → `incomplete_count = 0`, `max_new_tasks = 4`
- **`task_completions` bez embeddingów** — tabela służy tylko jako most między workflow, nie do semantic search
