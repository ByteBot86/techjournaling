# Tech AI Journaling — Design Document

**Date:** 2026-03-13
**Updated:** 2026-03-18
**Status:** Implemented

---


## Overview

Aplikacja do rozwoju kariery dla osoby z technicznym wykształceniem. Codzienny dziennik wspierany przez AI, który pełni rolę coacha kariery — nie podaje gotowych odpowiedzi, lecz pogłębia refleksję użytkownika poprzez pytania. Backend w n8n, wzorzec RAG, baza danych Supabase.

---

## Użytkownicy

- **Teraz:** single-user (jeden użytkownik przez Telegram)
- **Architektura:** multi-user od początku (user_id w każdej tabeli, identyfikacja przez telegram_id)
- **Interfejs:** Telegram (primary) + n8n Chat page (web, prosty)

---

## Stack technologiczny

| Warstwa | Technologia |
|---|---|
| Backend / orchestracja | n8n |
| Baza danych + wektory | Supabase (PostgreSQL + pgvector) |
| LLM (dialog, analiza) | Claude claude-sonnet-4-6 |
| Embeddingi | text-embedding-3-small (OpenAI) |
| Interfejs mobilny | Telegram bot |

---

## Model danych (Supabase)

> **Schemat wektorowy:** tabele z embeddingami używają formatu n8n-native (`content`, `metadata jsonb`, `embedding vector`) dla natywnej integracji z n8n Supabase Vector Store node. Dane relacyjne (user_id, daty, kategorie) trzymane są w kolumnie `metadata` **oraz** jako dedykowana kolumna `user_id uuid FK` — do filtrowania RPC.

```sql
users
  id (uuid PK), telegram_id (bigint unique), created_at

onboarding_profile          -- jednorazowy, niezmienny (bez embeddingu)
  id, user_id (FK), gender, values_raw, completed_at

onboarding_sessions         -- stan wieloturowego dialogu
  user_id (PK FK), state, collected_data (jsonb), updated_at

journal_entries             -- pamięć krótkoterminowa (n8n-native)
  id, user_id (FK), content, metadata {user_id, week_start}, embedding (vector), created_at

weekly_condensations        -- pamięć średnioterminowa (n8n-native)
  id, user_id (FK), content, metadata {week_start}, embedding (vector), created_at

monthly_condensations       -- kondensacja miesięczna (n8n-native)
  id, user_id (FK), content, metadata {month}, embedding (vector), created_at

yearly_condensations        -- kondensacja roczna (n8n-native)
  id, user_id (FK), content, metadata {year}, embedding (vector), created_at

amphitheater                -- pamięć długoterminowa (n8n-native)
  id, user_id (FK), content, metadata {category, superseded_at}, embedding (vector), created_at
  superseded_at=null → aktualny rekord

weekly_plans                -- plany na następny tydzień (n8n-native)
  id, user_id (FK), content, metadata {week_start}, embedding (vector), created_at
```

**Ważne: kolumna `content`, nie `text`** — n8n Supabase Vector Store node używa `content` jako nazwy kolumny na tekst dokumentu.

**Historia celów:** nowy cel = nowy rekord w `amphitheater` + `metadata.superseded_at = now()` na poprzednim. Aktualny cel = `metadata->>'category' = 'goal' AND metadata->>'superseded_at' IS NULL`.

---

## Wzorzec wstawiania do Vector Store (krytyczny)

Każdy workflow który wstawia dane do Supabase Vector Store **musi** używać `Default Data Loader` podpiętego przez port `ai_document`:

```
Prepare Item (Code)
  ↓ main
Save to Vector Store ← Default Data Loader (ai_document)
                     ← OpenAI Embeddings (ai_embedding)
```

**Konfiguracja Default Data Loader:**
- **Type of Data:** JSON
- **Mode:** Load Specific Data
- **Data:** `={{ $json.pageContent }}` → trafia do kolumny `content`
- **Metadata:** pola z `$json.metadata.*` → trafia do kolumny `metadata` (jsonb)

**Prepare Item** musi zwracać format `{ pageContent: "...", metadata: { ... } }`.

Bez tego — Vector Store traktuje cały item jako blob i rozbija każdą wartość JSON na osobny rekord.

---

## Warunkowa strategia RAG

| Kontekst | Źródło danych |
|---|---|
| Codzienny dialog | `journal_entries` ostatnie 7-14 dni (semantic) + `amphitheater` aktualny |
| Podsumowanie tygodnia | `journal_entries` z danego tygodnia (date filter) + `amphitheater` |
| Podsumowanie miesiąca | `weekly_condensations` z danego miesiąca + `amphitheater` |
| Podsumowanie roku | `monthly_condensations` z danego roku + `amphitheater` |
| Since inception | `yearly_condensations` + `amphitheater` |

`amphitheater` zawsze wchodzi w całości — jest mały i stanowi "fundament" użytkownika.

---

## Architektura workflow n8n

### Workflow IDs (n8n live)

| Workflow | ID | Status |
|---|---|---|
| `[TJ] telegram-router` | `Oox536BxS2iDb2hr` | ✅ aktywny |
| `[TJ] onboarding` | `nID2ILhYiD84PTOg` | ✅ aktywny |
| `[TJ] journal-entry` | `Vq2fDuRskkipBhjv` | ✅ aktywny |
| `[TJ] goal-change` | `qofnkI9CXa6f8rxs` | ✅ aktywny |
| `[TJ] export` | `67aT3Lh0fcETCAaj` | ✅ aktywny |
| `[TJ] memory-retrieval` | `dvYPWkdlYGDSlFh2` | ✅ aktywny |
| `[TJ] amphitheater-update` | `rUuhiK2xClpGJJad` | ✅ aktywny |
| `[TJ] weekly-processing` | `hzia0ENsdZ42NWQX` | ⏸ nieaktywny |
| `[TJ] weekly-summary` | `omOo8dkNsiACNDzW` | ⏸ nieaktywny |
| `[TJ] monthly-summary` | `FITh9SsNlSZgsDZY` | ⏸ nieaktywny |
| `[TJ] daily-reminder` | `DNPBzlJZcBLWNXYC` | ⏸ nieaktywny |

---

### 1. `telegram-router`
- **Trigger:** Telegram Webhook (jeden dla całego bota)
- **Logika:** wyciąga komendę i telegram_id → lookup user w Supabase → lookup session → Set Route (uwzględnia aktywną sesję onboarding/goal-change) → Switch na komendę
- **Routing:**
  - `/start` → utwórz usera (jeśli nowy) → `onboarding`
  - `/goal` → `goal-change`
  - `/export` → `export`
  - brak komendy + user istnieje → `journal-entry`
  - brak komendy + brak usera → wyślij info o `/start`

### 2. `onboarding`
- **Trigger:** `Execute Workflow Trigger` (wywoływany przez telegram-router)
- **Logika:** wieloturowy dialog przez Supabase `onboarding_sessions` → wartości → płeć → cel SMART → zapis do `onboarding_profile` + `amphitheater-update`
- **Stany sesji:** `new` → `values` → `values_confirm` → `gender` → `goal` → `goal_confirm` → `complete`
- **Ważne:** po wywołaniu `amphitheater-update` wynik normalizowany przez `Normalize Complete` node (zapobiega N wiadomościom Telegram)

### 3. `journal-entry`
- **Trigger:** `Execute Workflow Trigger` (wywoływany przez telegram-router)
- **Logika:** pobierz profil → `memory-retrieval` → zapisz wpis do `journal_entries` (przez Default Data Loader) → zbuduj prompt → Claude dobiera personę → jedno pytanie pogłębiające → Telegram
- **Zapisuje:** `journal_entries`

### 4. `goal-change`
- **Trigger:** `Execute Workflow Trigger`
- **Logika:** wieloturowy dialog (stany: `goal_collecting` → `gc_confirm`) → nowy cel SMART → zapis do `amphitheater`

### 5. `weekly-processing` *(cron: sobota 23:00)*
- **Logika:** dla każdego usera: kondensacja tygodnia → `weekly_condensations` + plan → `weekly_plans` + `amphitheater-update` + warunkowo monthly/yearly condensation

### 6. `weekly-summary` *(cron: niedziela 08:00)*
- **Logika:** `weekly_condensations` + `weekly_plans` + `amphitheater` → Claude generuje podsumowanie + niespójności + plan → wysyła Telegram

### 7. `daily-reminder` *(cron: 18:00 codziennie)*
- **Logika:** pobierz wszystkich userów z `onboarding_profile` → dla każdego wyślij personalizowane przypomnienie na Telegram
- **Wiadomość:** przypomnienie o dziennym wpisie + wartości użytkownika

### 8. `memory-retrieval` *(sub-workflow)*
- **Wejście:** `{ user_id, context_type, query_text }`
- **Logika:** mapuje `context_type` na tabelę i funkcję RPC → semantic search → pobiera `amphitheater` → `Format Context`
- **Zwraca:** `{ context: "skonkatenowany tekst" }`
- **Ważne:** `Supabase Vector Store` i `Fetch Amphitheater` mają `alwaysOutputData: true` — obsługują pustą bazę

### 9. `amphitheater-update` *(sub-workflow)*
- **Wejście:** `{ user_id, weekly_condensation_text }`
- **Logika:** Claude wyciąga insights → Parse Insights (format `pageContent + metadata`) → Insert przez Default Data Loader → Collapse Output (1 item) → Update User ID (filter `user_id IS NULL`)
- **Ważne:** filter Supabase używa stringa `"null"`, nie JS `null`

### 10. `export`
- **Trigger:** `Execute Workflow Trigger`
- **Logika:** pobierz wszystkie dane usera → JSON bez embeddingów → wyślij jako plik przez Telegram

---

## Komendy Telegram

| Komenda | Opis |
|---|---|
| `/start` | Jednorazowy onboarding (wartości, profil, pierwszy cel) |
| `/goal` | Zmiana głównego celu (historia zachowana) |
| `/export` | Pobierz wszystkie dane jako JSON |

---

## Persony AI (Przewodnicy)

Claude dobiera personę automatycznie na podstawie klasyfikacji treści wpisu.

| Persona | Kiedy aktywowana |
|---|---|
| **Strateg** | cele, kariera, decyzje długoterminowe |
| **Coach CBT** | negatywne myśli, blokady, przekonania |
| **Trener mentalny** | motywacja, energia, koncentracja |
| **Analityk** | procesy, nawyki, efektywność |

Każda persona: jedno precyzyjne pytanie pogłębiające, nigdy gotowe odpowiedzi.

---

## Znane pułapki implementacyjne

### 1. Default Data Loader — tryb JSON vs Binary
- **Problem:** Loader w trybie binary/blob traktuje cały item JSON jako tekst i rozbija każdą wartość na osobny rekord
- **Fix:** `dataType: "json"`, `jsonMode: "expressionData"`, `jsonData: "={{ $json.pageContent }}"`

### 2. executeWorkflow zwraca N items
- **Problem:** jeśli sub-workflow zwraca N items (np. 5 insertów), kolejny node (Telegram) wykona się N razy
- **Fix:** po każdym `executeWorkflow` dodaj `Normalize Complete` / `Collapse Output` (Code node, `runOnceForAllItems`) przed Telegram send

### 3. Supabase filter IS NULL
- **Problem:** `keyValue: null` (JS null) generuje `user_id=is.` zamiast `user_id=is.null`
- **Fix:** używaj stringa `"null"` jako wartości filtra

### 4. Pusta baza danych przy pierwszym uruchomieniu
- **Problem:** `vectorStoreSupabase` w trybie load zwraca 0 items → downstream nodes się nie wykonują
- **Fix:** `alwaysOutputData: true` na Vector Store i Supabase nodes w `memory-retrieval`

---

## Ograniczenia (świadome decyzje)

- Brak transkrypcji głosu (Whisper) — tylko tekst
- Brak integracji z kalendarzem, Notion, zewnętrznymi notatkami
- Brak funkcjonalności multi-user od strony frontendu (rejestracja kont)
- Interfejs webowy: tylko Telegram (chat page usunięty z scope)
