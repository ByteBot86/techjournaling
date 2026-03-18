# Tech AI Journaling — Implementation Plan

**Status: ZAIMPLEMENTOWANY** ✅
**Ostatnia aktualizacja:** 2026-03-18

**Goal:** Zbudować system codziennego journalingu kariery z AI coachem, hierarchiczną pamięcią RAG i integracją Telegram, oparty na n8n + Supabase.

**Architecture:** 10 modularnych workflow n8n (2 sub-workflow + 8 głównych). Supabase jako baza danych z pgvector do embeddingów. Warunkowa strategia RAG dobiera źródło danych w zależności od horyzontu czasowego.

**Tech Stack:** n8n (MCP), Supabase (PostgreSQL + pgvector), Claude claude-sonnet-4-6, text-embedding-3-small (OpenAI), Telegram Bot API.

**Design doc:** `docs/plans/2026-03-13-techjournaling-design.md`

---

## Status implementacji

| Task | Opis | Status |
|---|---|---|
| 1 | Supabase: tabele i pgvector | ✅ |
| 2 | Supabase: credentials w n8n | ✅ |
| 3 | sub-workflow: memory-retrieval | ✅ |
| 4 | sub-workflow: amphitheater-update | ✅ |
| 5 | workflow: onboarding (/start) | ✅ |
| 6 | workflow: journal-entry | ✅ |
| 7 | workflow: goal-change (/goal) | ✅ |
| 8 | workflow: weekly-processing (cron sobota) | ✅ |
| 9 | workflow: weekly-summary (cron niedziela) | ✅ |
| 10 | workflow: export (/export) | ✅ |
| 11 | Telegram: router (jeden webhook → wiele workflow) | ✅ |
| 12 | workflow: daily-reminder (cron 18:00) | ✅ |

Każdy workflow zapisany jako JSON w `workflows/` i zsynchronizowany z n8n przez MCP.

---

## Struktura plików

```
techjournaling/
├── CLAUDE.md
├── docs/
│   └── plans/
│       ├── 2026-03-13-techjournaling-design.md
│       └── 2026-03-13-techjournaling-plan.md
└── workflows/
    ├── telegram-router.json       # ID: Oox536BxS2iDb2hr
    ├── onboarding.json            # ID: nID2ILhYiD84PTOg
    ├── journal-entry.json         # ID: Vq2fDuRskkipBhjv
    ├── goal-change.json           # ID: qofnkI9CXa6f8rxs
    ├── weekly-processing.json     # ID: hzia0ENsdZ42NWQX
    ├── weekly-summary.json        # ID: omOo8dkNsiACNDzW
    ├── export.json                # ID: 67aT3Lh0fcETCAaj
    ├── memory-retrieval.json      # ID: dvYPWkdlYGDSlFh2
    ├── amphitheater-update.json   # ID: rUuhiK2xClpGJJad
    └── daily-reminder.json        # ID: DNPBzlJZcBLWNXYC
```

---

## Task 1: Supabase — setup tabel i pgvector ✅

Schemat używa kolumny `content` (nie `text`) — wymaganie n8n Supabase Vector Store node.
Tabele wektorowe mają zarówno dedykowaną kolumnę `user_id uuid FK` jak i `user_id` w `metadata` jsonb.

Migracje zastosowane przez Supabase MCP. Funkcje RPC (`match_journal_entries`, `match_weekly_condensations` itd.) utworzone dla semantic search z filtrem po `user_id`.

---

## Task 2: Credentials w n8n ✅

| Nazwa w n8n | Typ | ID |
|---|---|---|
| Supabase account | Supabase | `394dwMdNdGqslv7H` |
| OpenAi account | OpenAI | `kkj14qnD4cBwY9wg` |
| Anthropic account | Anthropic | `rChZltTr5OEPo5JD` |
| mytechjournaling_bot | Telegram Bot | `EuttSLS9hr5ouKGr` |

---

## Task 3: Sub-workflow — memory-retrieval ✅

**Wejście:** `{ user_id, context_type, query_text }`

**Węzły:**
1. `Workflow Input`
2. `Prepare` — mapuje `context_type` → `{ table_name, query_name }`
3. `Supabase Vector Store` (load, `alwaysOutputData: true`) — semantic search top-5
4. `Collect Search Results` — zbiera wyniki (obsługuje 0 wyników)
5. `Fetch Amphitheater` (Supabase getAll, `alwaysOutputData: true`) — pobiera cały amfiteatr usera
6. `Format Context` — łączy wyniki w string `context`

**Zwraca:** `{ context: "..." }`

**Kluczowe:** `alwaysOutputData: true` na węzłach 3 i 5 — obsługuje pustą bazę danych (nowy użytkownik).

---

## Task 4: Sub-workflow — amphitheater-update ✅

**Wejście:** `{ user_id, weekly_condensation_text }`

**Węzły:**
1. `Workflow Input`
2. `Prepare Prompt` — buduje prompt dla Claude
3. `Extract Insights` (chainLlm) + `Anthropic Chat Model`
4. `Parse Insights` — parsuje JSON, zwraca items `{ pageContent, metadata: { category, user_id } }`
5. `Insert Amphitheater` (vectorStoreSupabase insert) ← `Default Data Loader` (ai_document) ← `OpenAI Embeddings` (ai_embedding)
6. `Collapse Output` — redukuje do 1 item `{ user_id }`
7. `Update User ID` — Supabase UPDATE `amphitheater` WHERE `user_id IS "null"`

**Default Data Loader:** `dataType: "json"`, `jsonMode: "expressionData"`, `jsonData: "={{ $json.pageContent }}"`, metadata: `category`

**Uwaga Supabase filter:** używa stringa `"null"` (nie JS `null`) w filtrze `is`.

---

## Task 5: Workflow — onboarding ✅

**Trigger:** `Execute Workflow Trigger` (wywoływany przez telegram-router)

**Węzły (21):**
1-5: `Workflow Input` → `Try Create User` → `Get User` → `Get Profile` → `Check State`
6-8: `Already Onboarded?` → `Send Already Done` | `Get Session`
9-12: `Build Context` → `Claude Conversation` + `Anthropic Chat Model` → `Parse Response`
13-14: `Delete Old Session` → `Is Complete?`
15-17: (complete) `Save Profile` → `Prepare Amphitheater` → `Update Amphitheater`
18-21: `Normalize Complete` → `Send Complete` | `Create Session` → `Send Response`

**Stany sesji:** `new` → `values` → `values_confirm` → `gender` → `goal` → `goal_confirm` → `complete`

**Kluczowe:** `Normalize Complete` (Code, `runOnceForAllItems`) między `Update Amphitheater` a `Send Complete` — zapobiega N wiadomościom gdy sub-workflow zwraca N items.

---

## Task 6: Workflow — journal-entry ✅

**Trigger:** `Execute Workflow Trigger`

**Węzły (13):**
1: `Workflow Input`
2: `Get Profile` (alwaysOutputData)
3: `Prepare Memory Query`
4: `Call Memory Retrieval` (executeWorkflow → dvYPWkdlYGDSlFh2)
5: `Prepare Journal Item` → `{ pageContent: message_text, metadata: { user_id, week_start } }`
6: `Save Journal Entry` (vectorStoreSupabase insert) ← `Default Data Loader` (ai_document) ← `OpenAI Embeddings`
7: `Build Prompt`
8-9: `Claude Coach` (chainLlm) + `Anthropic Chat Model`
10: `Extract Response`
11: `Send Response` (Telegram)

**Default Data Loader:** `jsonData: "={{ $json.pageContent }}"`, metadata: `user_id`, `week_start`

---

## Task 7: Workflow — goal-change ✅

**Trigger:** `Execute Workflow Trigger`

**Węzły (14):** wieloturowy dialog zbierający nowy cel SMART.
**Stany:** `goal_collecting` → `gc_confirm` → `complete`

---

## Task 8: Workflow — weekly-processing ✅

**Trigger:** Schedule (sobota 23:00)

**Logika:** dla każdego usera:
1. Kondensacja tygodnia → `weekly_condensations`
2. Plan na następny tydzień → `weekly_plans`
3. `amphitheater-update` (sub-workflow)
4. Warunkowo (ostatnia sobota miesiąca): kondensacja miesięczna → `monthly_condensations`
5. Warunkowo (ostatnia sobota roku): kondensacja roczna → `yearly_condensations`

---

## Task 9: Workflow — weekly-summary ✅

**Trigger:** Schedule (niedziela 08:00)

**Logika:** `weekly_condensations` + `weekly_plans` (poprzedni tydzień) + `amphitheater` → Claude generuje podsumowanie + niespójności + plan → Telegram

---

## Task 10: Workflow — export ✅

**Trigger:** `Execute Workflow Trigger`

**Logika:** pobierz wszystkie dane usera (bez embeddingów) → JSON → `sendDocument` Telegram

---

## Task 11: Telegram Router ✅

**Trigger:** Telegram Webhook

**Logika:**
1. `Extract Message` — wyciąga tekst, komendę, telegram_id
2. `Find User` — lookup w `users` po telegram_id
3. `Get Session` — sprawdza aktywną sesję (onboarding/goal-change)
4. `Set Route` — ustala efektywną komendę (uwzględnia sesję)
5. `Route Command` (Switch) → `/start`, `/goal`, `/export`, fallback
6. `/start` → `Create User` → `Get User` → `Set Start Input` → `Call Onboarding`
7. `/goal` → `Call Goal Change`
8. `/export` → `Call Export`
9. fallback → `Has User?` → `Call Journal Entry` | `Send No User`

---

## Task 12: Workflow — daily-reminder ✅

**Trigger:** Schedule (18:00 codziennie)

**Węzły (5):**
1. `Schedule Trigger` (18:00)
2. `Get Profiles` — pobiera wszystkich userów z `onboarding_profile`
3. `Get User` — pobiera `telegram_id` z `users` (alwaysOutputData)
4. `Build Message` — personalizuje wiadomość wartościami usera
5. `Send Reminder` — Telegram sendMessage

**Wiadomość:** przypomnienie o dziennym wpisie z wartościami usera jako kontekstem.
**Aktywacja:** ⏸ nieaktywny — aktywuj ręcznie po zakończeniu testów.

---

## Uwagi implementacyjne

- **Zawsze** zapisuj JSON lokalnie w `workflows/` przed wysłaniem do n8n przez MCP
- Po każdej zmianie w n8n przez MCP — zaktualizuj lokalny plik JSON
- Credentials nigdy nie trafiają do plików JSON (używaj nazw credential z n8n)
- Sub-workflow `memory-retrieval` i `amphitheater-update` muszą być zaimplementowane **przed** głównymi workflow
- Testuj każdy workflow osobno przed integracją z telegram-router
- Patrz design doc sekcja "Znane pułapki implementacyjne" przed modyfikacją workflow
