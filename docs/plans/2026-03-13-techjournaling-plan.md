# Tech AI Journaling — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Zbudować system codziennego journalingu kariery z AI coachem, hierarchiczną pamięcią RAG i integracją Telegram, oparty na n8n + Supabase.

**Architecture:** 7 modularnych workflow n8n (2 sub-workflow + 5 głównych). Supabase jako baza danych z pgvector do embeddingów. Warunkowa strategia RAG dobiera źródło danych w zależności od horyzontu czasowego.

**Tech Stack:** n8n (MCP), Supabase (PostgreSQL + pgvector), Claude claude-sonnet-4-6, Whisper (OpenAI), text-embedding-3-small (OpenAI), Telegram Bot API.

**Design doc:** `docs/plans/2026-03-13-techjournaling-design.md`

---

## Kolejność implementacji

```
Task 1  → Supabase: tabele i pgvector
Task 2  → Supabase: credentials w n8n
Task 3  → sub-workflow: memory-retrieval
Task 4  → sub-workflow: amphitheater-update
Task 5  → workflow: onboarding (/start)
Task 6  → workflow: journal-entry (tekst + głos)
Task 7  → workflow: goal-change (/goal)
Task 8  → workflow: weekly-processing (cron sobota)
Task 9  → workflow: weekly-summary (cron niedziela)
Task 10 → workflow: export (/export)
Task 11 → Telegram: router (jeden webhook → wiele workflow)
Task 12 → n8n Chat page: konfiguracja web interface
```

Każdy workflow zapisywany jako JSON w `workflows/` przed wysłaniem do n8n przez MCP.

---

## Task 1: Supabase — setup tabel i pgvector

> **Uwaga schematu:** Tabele wektorowe używają formatu n8n-native (`text`, `metadata jsonb`, `embedding`) zamiast custom kolumn. Dzięki temu działają natywnie z n8n Supabase Vector Store node. Dane relacyjne (user_id, daty itp.) trzymamy w kolumnie `metadata` jako jsonb.

**Files:**
- Create: `supabase/migrations/001_initial_schema.sql`

**Step 1: Utwórz plik migracji**

```sql
-- supabase/migrations/001_initial_schema.sql

-- Włącz pgvector
create extension if not exists vector;

-- Users
create table users (
  id uuid primary key default gen_random_uuid(),
  telegram_id bigint unique not null,
  user_login text unique,
  created_at timestamptz default now()
);

-- Onboarding profile (jednorazowy, niezmienny — bez embeddingu, nie wyszukiwany semantycznie)
create table onboarding_profile (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  gender text,
  values_raw text not null,
  completed_at timestamptz default now()
);

-- Onboarding sessions (stan wieloturowego dialogu)
create table onboarding_sessions (
  user_id uuid primary key references users(id) on delete cascade,
  state text not null,  -- 'values'|'values_confirm'|'gender'|'goal'|'goal_confirm'
  collected_data jsonb default '{}',
  updated_at timestamptz default now()
);

-- Journal entries (pamięć krótkoterminowa)
-- n8n-native schema: text + metadata + embedding + user_id FK
create table journal_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  text text not null,
  metadata jsonb default '{}',   -- {week_start} lub inne n8n-specific dane
  embedding vector(1536),
  created_at timestamptz default now()
);

-- Weekly condensations (pamięć średnioterminowa)
create table weekly_condensations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  text text not null,
  metadata jsonb default '{}',   -- {week_start}
  embedding vector(1536),
  created_at timestamptz default now()
);

-- Monthly condensations
create table monthly_condensations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  text text not null,
  metadata jsonb default '{}',   -- {month}
  embedding vector(1536),
  created_at timestamptz default now()
);

-- Yearly condensations
create table yearly_condensations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  text text not null,
  metadata jsonb default '{}',   -- {year}
  embedding vector(1536),
  created_at timestamptz default now()
);

-- Amphitheater (pamięć długoterminowa)
create table amphitheater (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  text text not null,
  metadata jsonb default '{}',   -- {category, superseded_at}
  embedding vector(1536),
  created_at timestamptz default now()
);

-- Weekly plans
create table weekly_plans (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  text text not null,
  metadata jsonb default '{}',   -- {week_start}
  embedding vector(1536),
  created_at timestamptz default now()
);

-- Indeksy do semantic search
create index on journal_entries using ivfflat (embedding vector_cosine_ops);
create index on weekly_condensations using ivfflat (embedding vector_cosine_ops);
create index on monthly_condensations using ivfflat (embedding vector_cosine_ops);
create index on yearly_condensations using ivfflat (embedding vector_cosine_ops);
create index on amphitheater using ivfflat (embedding vector_cosine_ops);
create index on weekly_plans using ivfflat (embedding vector_cosine_ops);

-- Indeksy na user_id do filtrowania po użytkowniku
create index on journal_entries (user_id);
create index on weekly_condensations (user_id);
create index on monthly_condensations (user_id);
create index on yearly_condensations (user_id);
create index on amphitheater (user_id);
create index on weekly_plans (user_id);
```

**Step 2: Uruchom migrację przez Supabase MCP**

```
mcp__supabase__apply_migration(name="initial_schema", query=<zawartość pliku>)
```

**Step 3: Utwórz funkcje RPC do semantic search (n8n-compatible)**

n8n Supabase Vector Store node wywołuje RPC o nazwie `match_<table_name>`. Utwórz dla każdej tabeli:

```sql
-- match_journal_entries — filtruje po user_id (kolumna) i dacie
create or replace function match_journal_entries(
  query_embedding vector(1536),
  match_count int,
  filter jsonb default '{}'
)
returns table (id uuid, text text, metadata jsonb, similarity float)
language sql stable
as $$
  select id, text, metadata,
    1 - (embedding <=> query_embedding) as similarity
  from journal_entries
  where
    (filter->>'user_id' is null or user_id = (filter->>'user_id')::uuid)
    and (filter->>'days_back' is null or
         created_at > now() - ((filter->>'days_back') || ' days')::interval)
  order by embedding <=> query_embedding
  limit match_count;
$$;

-- match_weekly_condensations
create or replace function match_weekly_condensations(
  query_embedding vector(1536),
  match_count int,
  filter jsonb default '{}'
)
returns table (id uuid, text text, metadata jsonb, similarity float)
language sql stable
as $$
  select id, text, metadata,
    1 - (embedding <=> query_embedding) as similarity
  from weekly_condensations
  where (filter->>'user_id' is null or user_id = (filter->>'user_id')::uuid)
  order by embedding <=> query_embedding
  limit match_count;
$$;

-- match_amphitheater — tylko aktualny (superseded_at IS NULL w metadata)
create or replace function match_amphitheater(
  query_embedding vector(1536),
  match_count int,
  filter jsonb default '{}'
)
returns table (id uuid, text text, metadata jsonb, similarity float)
language sql stable
as $$
  select id, text, metadata,
    1 - (embedding <=> query_embedding) as similarity
  from amphitheater
  where
    (filter->>'user_id' is null or user_id = (filter->>'user_id')::uuid)
    and metadata->>'superseded_at' is null
  order by embedding <=> query_embedding
  limit match_count;
$$;

-- match_monthly_condensations
create or replace function match_monthly_condensations(
  query_embedding vector(1536),
  match_count int,
  filter jsonb default '{}'
)
returns table (id uuid, text text, metadata jsonb, similarity float)
language sql stable
as $$
  select id, text, metadata,
    1 - (embedding <=> query_embedding) as similarity
  from monthly_condensations
  where (filter->>'user_id' is null or user_id = (filter->>'user_id')::uuid)
  order by embedding <=> query_embedding
  limit match_count;
$$;

-- match_yearly_condensations
create or replace function match_yearly_condensations(
  query_embedding vector(1536),
  match_count int,
  filter jsonb default '{}'
)
returns table (id uuid, text text, metadata jsonb, similarity float)
language sql stable
as $$
  select id, text, metadata,
    1 - (embedding <=> query_embedding) as similarity
  from yearly_condensations
  where (filter->>'user_id' is null or user_id = (filter->>'user_id')::uuid)
  order by embedding <=> query_embedding
  limit match_count;
$$;

-- match_weekly_plans
create or replace function match_weekly_plans(
  query_embedding vector(1536),
  match_count int,
  filter jsonb default '{}'
)
returns table (id uuid, text text, metadata jsonb, similarity float)
language sql stable
as $$
  select id, text, metadata,
    1 - (embedding <=> query_embedding) as similarity
  from weekly_plans
  where (filter->>'user_id' is null or user_id = (filter->>'user_id')::uuid)
  order by embedding <=> query_embedding
  limit match_count;
$$;
```

**Step 4: Commit**

```bash
git add supabase/
git commit -m "feat: add Supabase schema with n8n-native vector columns"
```

---

## Task 2: Credentials w n8n

**Step 1: Dodaj credentials w n8n UI**

W n8n → Settings → Credentials, dodaj:

| Nazwa | Typ | Dane |
|---|---|---|
| `Supabase Tech Diary` | Supabase | URL + anon key z Supabase Dashboard |
| `OpenAI Tech Diary` | OpenAI | API key |
| `Anthropic Tech Diary` | Anthropic | API key |
| `Telegram Tech Diary` | Telegram Bot | Bot token z @BotFather |

**Step 2: Zanotuj ID credentials**

Po zapisaniu każdego credential, skopiuj jego ID z URL (będzie potrzebne w JSON workflow).

**Step 3: Utwórz plik z ID credentials**

```bash
# workflows/credentials.json  (NIE commituj tego pliku!)
```

Dodaj do `.gitignore`:
```
workflows/credentials.json
```

```bash
git add .gitignore
git commit -m "chore: ignore credentials file"
```

---

## Task 3: Sub-workflow — memory-retrieval

**Files:**
- Create: `workflows/memory-retrieval.json`

**Step 1: Zdefiniuj strukturę workflow**

Sub-workflow przyjmuje przez `Execute Workflow Trigger`:
```json
{
  "user_id": "uuid",
  "context_type": "daily|weekly|monthly|yearly|inception",
  "query_embedding": [/* vector 1536 */],
  "query_text": "opcjonalnie"
}
```

Zwraca: `{ "context": "skonkatenowany tekst relevantnych rekordów" }`

**Step 2: Utwórz plik JSON**

Zapisz `workflows/memory-retrieval.json` z węzłami:
1. `Execute Workflow Trigger` — odbiera parametry
2. `Switch` — rozgałęzia po `context_type`
3. Dla każdej gałęzi: `Supabase` node z odpowiednim zapytaniem:
   - `daily` → RPC `match_journal_entries` (ostatnie 14 dni)
   - `weekly` → `journal_entries` filtr date (bieżący tydzień)
   - `monthly` → `weekly_condensations` filtr date (bieżący miesiąc)
   - `yearly` → `monthly_condensations` filtr date (bieżący rok)
   - `inception` → `yearly_condensations` wszystkie
4. Każda gałąź pobiera też `amphitheater` (`superseded_at IS NULL`)
5. `Code` node — łączy wyniki w jeden string `context`
6. Zwraca przez `Respond to Webhook` lub bezpośrednio

**Step 3: Wyślij do n8n przez MCP**

```
n8n_create_workflow(name="[TJ] memory-retrieval", nodes=[...], connections={...})
```

**Step 4: Zapisz ID workflow**

Zanotuj ID zwrócone przez MCP — potrzebne w innych workflow jako `workflowId`.

**Step 5: Commit**

```bash
git add workflows/memory-retrieval.json
git commit -m "feat: add memory-retrieval sub-workflow"
```

---

## Task 4: Sub-workflow — amphitheater-update

**Files:**
- Create: `workflows/amphitheater-update.json`

**Step 1: Zdefiniuj wejście**

Przyjmuje:
```json
{
  "user_id": "uuid",
  "weekly_condensation_text": "tekst kondensacji tygodnia"
}
```

**Step 2: Logika workflow**

Węzły:
1. `Execute Workflow Trigger`
2. `Anthropic` (Claude) — prompt:
   ```
   Na podstawie poniższej kondensacji tygodnia wyodrębnij
   ponadczasowe informacje (kluczowe osoby, projekty, wnioski).
   Zwróć JSON: {"insights": [{"category": "insight|person|project", "content": "..."}]}
   Kondensacja: {{ $json.weekly_condensation_text }}
   ```
3. `Code` node — parsuje JSON z Claude
4. `Loop` — dla każdego insight:
   a. `OpenAI` — generuje embedding dla `content`
   b. `Supabase` — INSERT do `amphitheater`

**Step 3: Wyślij do n8n przez MCP, zapisz JSON lokalnie**

```bash
git add workflows/amphitheater-update.json
git commit -m "feat: add amphitheater-update sub-workflow"
```

---

## Task 5: Workflow — onboarding

**Files:**
- Create: `workflows/onboarding.json`

**Step 1: Logika workflow**

Trigger: Telegram wiadomość `/start`

```
Sprawdź czy user istnieje w tabeli users (po telegram_id)
  → TAK i onboarding_profile istnieje → wyślij "Już masz profil. Użyj /goal żeby zmienić cel."
  → NIE → utwórz user → rozpocznij wywiad
```

Wywiad (konwersacja wieloturowa przez Telegram):
1. Powitanie + pytanie o wartości życiowe
2. Claude zadaje pogłębiające pytania o wartości (3-4 tury)
3. Claude podsumowuje wartości i prosi o potwierdzenie
4. Pytanie o podstawowe info (płeć)
5. Przejście do definiowania celu:
   - Claude pyta "Co jest Twoim najważniejszym celem zawodowym?"
   - Jedna tura pogłębienia
   - Claude formułuje SMART cel i prosi o potwierdzenie
6. Zapis do `onboarding_profile` i `amphitheater` (values + goal)
7. Wiadomość końcowa: "Profil gotowy! Możesz teraz codziennie pisać swoje przemyślenia."

**Step 2: Zarządzanie stanem konwersacji**

Użyj n8n `Static Data` lub Supabase tabeli `onboarding_sessions` do przechowywania stanu wieloturowego dialogu:
```sql
create table onboarding_sessions (
  user_id uuid primary key references users(id),
  state text not null,  -- 'values'|'values_confirm'|'gender'|'goal'|'goal_confirm'
  collected_data jsonb default '{}',
  updated_at timestamptz default now()
);
```

Dodaj tę tabelę do migracji lub uruchom osobno w SQL Editor.

**Step 3: Wyślij do n8n, zapisz JSON**

```bash
git add workflows/onboarding.json
git commit -m "feat: add onboarding workflow"
```

---

## Task 6: Workflow — journal-entry

**Files:**
- Create: `workflows/journal-entry.json`

**Step 1: Logika workflow**

Trigger: Telegram (wiadomość tekstowa lub voice) + n8n Chat Trigger

```
Odczytaj wiadomość
  → voice message? → OpenAI Whisper transcribe → content = transcript
  → text message?  → content = text

Generuj embedding (OpenAI text-embedding-3-small) dla content

Zapisz do journal_entries (user_id, content, embedding)

Wywołaj memory-retrieval sub-workflow:
  context_type = "daily"
  query_embedding = embedding z powyżej
  user_id = user_id

Zbuduj prompt dla Claude z:
  - system: rola coacha + instrukcja doboru persony
  - context: wynik memory-retrieval (relevantne wpisy + amfiteatr)
  - user: content (wpis użytkownika)

Claude:
  1. Klasyfikuje wpis → wybiera personę (Strateg/CBT/Trener/Analityk)
  2. Zadaje JEDNO precyzyjne pytanie pogłębiające z perspektywy persony

Wyślij pytanie Claude'a użytkownikowi (Telegram lub Chat)
```

**Step 2: System prompt dla Claude**

```
Jesteś AI coachem kariery dla osoby technicznej. Twoja rola to pogłębianie
refleksji, nie dawanie gotowych odpowiedzi.

Profil użytkownika:
Wartości: {{ $json.values }}
Główny cel: {{ $json.goal }}

Kontekst z ostatnich 14 dni:
{{ $json.context }}

Na podstawie wpisu użytkownika:
1. Wybierz jedną personę: Strateg (kariera/decyzje), Coach CBT (emocje/blokady),
   Trener mentalny (motywacja/energia), Analityk (procesy/nawyki)
2. Zadaj JEDNO precyzyjne pytanie pogłębiające z perspektywy tej persony.
   Nie dawaj odpowiedzi, nie dawaj rad. Tylko pytanie.
```

**Step 3: Wyślij do n8n, zapisz JSON**

```bash
git add workflows/journal-entry.json
git commit -m "feat: add journal-entry workflow"
```

---

## Task 7: Workflow — goal-change

**Files:**
- Create: `workflows/goal-change.json`

**Step 1: Logika workflow**

Trigger: Telegram wiadomość `/goal`

```
Pobierz aktualny cel z amphitheater (category='goal', superseded_at IS NULL)
Wyświetl aktualny cel użytkownikowi

Dialog z Claude (2-3 tury):
  - "Co chcesz zmienić w swoim celu?"
  - Claude pogłębia i formułuje nowy cel
  - Claude prezentuje nowy cel SMART i prosi o potwierdzenie

Po potwierdzeniu:
  UPDATE amphitheater SET superseded_at = now()
    WHERE user_id = ? AND category = 'goal' AND superseded_at IS NULL
  INSERT INTO amphitheater (user_id, category, content, embedding)
    VALUES (?, 'goal', nowy_cel, embedding)

Wyślij potwierdzenie: "Nowy cel zapisany. Poprzedni zachowany w historii."
```

**Step 2: Wyślij do n8n, zapisz JSON**

```bash
git add workflows/goal-change.json
git commit -m "feat: add goal-change workflow"
```

---

## Task 8: Workflow — weekly-processing

**Files:**
- Create: `workflows/weekly-processing.json`

**Step 1: Logika workflow**

Trigger: Schedule (sobota 23:00, `0 23 * * 6`)

```
Dla każdego aktywnego użytkownika (users table):

  1. KONDENSACJA TYGODNIA
     Pobierz journal_entries z ostatnich 7 dni
     Pobierz amphitheater (aktualny cel + wartości)
     Claude kondensuje wpisy → weekly_condensations (INSERT)
     Generuj embedding dla kondensacji

  2. PLAN NA NASTĘPNY TYDZIEŃ
     Claude generuje konkretny plan na bazie:
       - kondensacji tygodnia
       - amphitheater (cel + wartości)
       - weekly_condensations z ostatnich 4 tygodni
     INSERT do weekly_plans

  3. AKTUALIZACJA AMFITEATRU
     Wywołaj amphitheater-update sub-workflow
       z tekstem nowej kondensacji

  4. KONDENSACJA MIESIĘCZNA (warunkowo)
     Jeśli dziś jest ostatnia sobota miesiąca:
       Pobierz weekly_condensations z bieżącego miesiąca
       Claude kondensuje → monthly_condensations (INSERT)

  5. KONDENSACJA ROCZNA (warunkowo)
     Jeśli dziś jest ostatnia sobota roku:
       Pobierz monthly_condensations z bieżącego roku
       Claude kondensuje → yearly_condensations (INSERT)
```

**Step 2: Sprawdzenie "ostatnia sobota miesiąca"**

Code node:
```javascript
const now = new Date();
const nextWeek = new Date(now);
nextWeek.setDate(now.getDate() + 7);
const isLastSaturdayOfMonth = nextWeek.getMonth() !== now.getMonth();
const isLastSaturdayOfYear = nextWeek.getFullYear() !== now.getFullYear();
return [{ json: { isLastSaturdayOfMonth, isLastSaturdayOfYear } }];
```

**Step 3: Wyślij do n8n, zapisz JSON**

```bash
git add workflows/weekly-processing.json
git commit -m "feat: add weekly-processing workflow"
```

---

## Task 9: Workflow — weekly-summary

**Files:**
- Create: `workflows/weekly-summary.json`

**Step 1: Logika workflow**

Trigger: Schedule (niedziela 08:00, `0 8 * * 0`)

```
Dla każdego aktywnego użytkownika:

  Pobierz:
    - weekly_condensations: ostatnia (bieżący tydzień)
    - weekly_plans: poprzedni tydzień (do wykrywania niespójności)
    - amphitheater: aktualny cel + wartości
    - weekly_plans: nowy (wygenerowany w sobotę)

  Claude generuje wiadomość niedzielną zawierającą:
    1. Podsumowanie tygodnia (wzorce energii, zachowania)
    2. Wykryte niespójności (co planowałeś vs co się wydarzyło)
    3. Plan na nadchodzący tydzień (z weekly_plans)

  Wyślij wiadomość na Telegram (Markdown formatting)
```

**Step 2: Przykładowy format wiadomości**

```
📊 *Podsumowanie tygodnia*

*Co się wydarzyło:*
[kondensacja]

⚠️ *Zauważone niespójności:*
[lista niespójności między planem a rzeczywistością]

🎯 *Plan na nadchodzący tydzień:*
[plan wygenerowany w sobotę]
```

**Step 3: Wyślij do n8n, zapisz JSON**

```bash
git add workflows/weekly-summary.json
git commit -m "feat: add weekly-summary workflow"
```

---

## Task 10: Workflow — export

**Files:**
- Create: `workflows/export.json`

**Step 1: Logika workflow**

Trigger: Telegram wiadomość `/export`

```
Pobierz wszystkie dane użytkownika:
  - onboarding_profile
  - journal_entries (bez embeddingów — za duże)
  - weekly_condensations
  - monthly_condensations
  - yearly_condensations
  - amphitheater (wszystkie, włącznie z historią celów)
  - weekly_plans

Złóż w jeden obiekt JSON
Wyślij jako plik .json przez Telegram (sendDocument)
```

**Step 2: Wyłącz embeddingi z eksportu**

Code node — usuwa pole `embedding` z każdego rekordu przed eksportem (za duże, bezużyteczne poza systemem).

**Step 3: Wyślij do n8n, zapisz JSON**

```bash
git add workflows/export.json
git commit -m "feat: add export workflow"
```

---

## Task 11: Telegram Router

**Files:**
- Create: `workflows/telegram-router.json`

**Cel:** Jeden webhook Telegram → routing do odpowiednich workflow po komendzie lub typie wiadomości.

**Step 1: Logika routera**

```
Telegram Trigger (jeden webhook dla całego bota)
  ↓
Switch node (po treści wiadomości):
  /start    → Execute Workflow: onboarding
  /goal     → Execute Workflow: goal-change
  /export   → Execute Workflow: export
  voice     → Execute Workflow: journal-entry
  text      → Execute Workflow: journal-entry
  default   → ignoruj lub "Nie rozumiem komendy"
```

**Step 2: Identyfikacja użytkownika**

Każde wywołanie sub-workflow przekazuje `telegram_id` z wiadomości Telegram. Sub-workflow sam robi lookup `user_id` przez `telegram_id`.

**Step 3: Wyślij do n8n, zapisz JSON**

```bash
git add workflows/telegram-router.json
git commit -m "feat: add telegram-router workflow"
```

---

## Task 12: n8n Chat Page (web interface)

**Step 1: Skonfiguruj journal-entry do obsługi Chat Trigger**

W `journal-entry` workflow dodaj drugi trigger: `n8n Chat Trigger` (obok Telegram Trigger).

Identyfikacja użytkownika przez web: użyj stałego `user_id` w konfiguracji Chat Trigger (single-user na razie) lub przekaż jako metadata.

**Step 2: Aktywuj workflow**

Wszystkie workflow aktywuj w n8n UI (toggle Active).

**Step 3: Ustaw webhook Telegram**

```bash
curl "https://api.telegram.org/bot<TOKEN>/setWebhook?url=https://n8nnauka.bieda.it/webhook/<webhook-id>"
```

Webhook ID znajdziesz w konfiguracji Telegram Trigger w telegram-router.

**Step 4: Test end-to-end**

1. Wyślij `/start` na Telegram → sprawdź czy onboarding startuje
2. Wyślij testowy wpis → sprawdź czy jest w `journal_entries` w Supabase
3. Sprawdź czy przychodzi pytanie pogłębiające
4. Wyślij `/export` → sprawdź czy przychodzi plik JSON

**Step 5: Commit końcowy**

```bash
git add workflows/
git commit -m "feat: complete tech journaling system"
```

---

## Struktura plików po implementacji

```
techjournaling/
├── CLAUDE.md
├── docs/
│   └── plans/
│       ├── 2026-03-13-techjournaling-design.md
│       └── 2026-03-13-techjournaling-plan.md
├── supabase/
│   └── migrations/
│       └── 001_initial_schema.sql
└── workflows/
    ├── telegram-router.json
    ├── onboarding.json
    ├── journal-entry.json
    ├── goal-change.json
    ├── weekly-processing.json
    ├── weekly-summary.json
    ├── export.json
    ├── memory-retrieval.json
    └── amphitheater-update.json
```

---

## Uwagi implementacyjne

- **Zawsze** zapisuj JSON lokalnie w `workflows/` przed wysłaniem do n8n przez MCP
- Po każdej zmianie w n8n przez MCP — zaktualizuj lokalny plik JSON
- Credentials nigdy nie trafiają do plików JSON (używaj nazw credential z n8n)
- Sub-workflow `memory-retrieval` i `amphitheater-update` implementuj **przed** głównymi workflow
- Testuj każdy workflow osobno przed integracją z telegram-router
