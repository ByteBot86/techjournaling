# Tech AI Journaling — Design Document

**Date:** 2026-03-13
**Status:** Approved

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
| STT (transkrypcja głosu) | Whisper (OpenAI) |
| Embeddingi | text-embedding-3-small (OpenAI) |
| Interfejs mobilny | Telegram bot |
| Interfejs webowy | n8n Chat page |

---

## Model danych (Supabase)

```sql
users
  id, telegram_id, created_at

onboarding_profile          -- jednorazowy, niezmienny
  id, user_id, gender, values_raw, completed_at

journal_entries             -- pamięć krótkoterminowa
  id, user_id, content, embedding (vector), created_at

weekly_condensations        -- pamięć średnioterminowa
  id, user_id, week_start, content, embedding (vector), created_at

monthly_condensations       -- kondensacja miesięczna
  id, user_id, month, content, embedding (vector), created_at

yearly_condensations        -- kondensacja roczna
  id, user_id, year, content, embedding (vector), created_at

amphitheater                -- pamięć długoterminowa (Amfiteatr wiedzy)
  id, user_id, category (values|goal|insight|person|project),
  content, embedding (vector), created_at,
  superseded_at (null = aktualny rekord)

weekly_plans                -- plany na następny tydzień
  id, user_id, week_start, plan_content, embedding (vector), created_at
```

**Zasada:** text + embedding w jednej tabeli (pgvector, prostsze zapytania n8n).

**Historia celów:** nowy cel = nowy rekord w `amphitheater` + `superseded_at = now()` na poprzednim. Aktualny cel = `category = 'goal' AND superseded_at IS NULL`.

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

## Architektura workflow n8n (Podejście B — modularne)

### 1. `onboarding`
- **Trigger:** `/start` (Telegram) — jednorazowy (jeśli profil istnieje → ignoruj)
- **Logika:** wywiad wartości życiowych → podstawowe info (płeć itp.) → definicja jednego głównego celu
- **Zapisuje:** `onboarding_profile`, `amphitheater` (values + goal)

### 2. `journal-entry`
- **Trigger:** wiadomość tekstowa lub głosowa (Telegram + n8n Chat)
- **Logika:** głos → Whisper → tekst → embed → `memory-retrieval` → Claude dobiera personę → jedno pytanie pogłębiające
- **Zapisuje:** `journal_entries`

### 3. `weekly-processing` *(cron: sobota 23:00)*
- **Logika:**
  - `journal_entries` z tygodnia → Claude kondensuje → `weekly_condensations`
  - Generuje plan na następny tydzień → `weekly_plans`
  - `amphitheater-update` (sub-workflow) aktualizuje amfiteatr
  - Warunkowo (koniec miesiąca): `weekly_condensations` → `monthly_condensations`
  - Warunkowo (koniec roku): `monthly_condensations` → `yearly_condensations`

### 4. `weekly-summary` *(cron: niedziela 08:00)*
- **Logika:** `weekly_condensations` + `weekly_plans` (poprzedni tydzień) + `amphitheater` → Claude generuje podsumowanie + wykrywa niespójności (plan vs rzeczywistość) + plan na nadchodzący tydzień → wysyła Telegram

### 5. `amphitheater-update` *(sub-workflow)*
- Wywoływany przez `weekly-processing`
- Wyciąga ponadczasowe insights z kondensacji → aktualizuje `amphitheater`

### 6. `memory-retrieval` *(sub-workflow)*
- Wywoływany przez `journal-entry` i `weekly-summary`
- Semantic search na odpowiedniej tabeli w zależności od kontekstu
- Zwraca relevantny kontekst dla Claude'a

### 7. `export`
- **Trigger:** `/export` (Telegram)
- **Logika:** pobiera wszystkie dane użytkownika → JSON
- **Zwraca:** plik JSON na Telegram

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

| Persona | Framework | Kiedy aktywowana |
|---|---|---|
| **Strateg** | Strategic thinking | cele, kariera, decyzje długoterminowe |
| **Coach CBT** | Kognitywno-behawioralna | negatywne myśli, blokady, przekonania |
| **Trener mentalny** | Mental performance | motywacja, energia, koncentracja |
| **Analityk** | Productivity / systems | procesy, nawyki, efektywność |

Każda persona: jedno precyzyjne pytanie pogłębiające, nigdy gotowe odpowiedzi.
Każda persona zawsze ma dostęp do: aktualnego celu + wartości + relevantnych wpisów z RAG.

---

## Przepływ użytkownika

### Onboarding (jednorazowo)
```
/start → wywiad wartości → podstawowe info → definicja celu → profil gotowy
```

### Codzienny wpis
```
wiadomość (tekst lub głos)
  → [głos] Whisper transkrybuje
  → zapisz wpis + embed
  → memory-retrieval (kontekst)
  → Claude klasyfikuje → dobiera personę
  → jedno pytanie pogłębiające
  → [opcjonalnie] użytkownik odpowiada
```

### Niedzielny rytm
```
Sob 23:00  weekly-processing:
           kondensacja tygodnia + plan na następny tydzień
           + warunkowo: monthly/yearly condensation

Nie 08:00  weekly-summary:
           podsumowanie wzorców + niespójności + plan → Telegram
```

---

## Ograniczenia (świadome decyzje)

- Brak integracji z kalendarzem, Notion, zewnętrznymi notatkami
- Brak funkcjonalności multi-user od strony frontendu (rejestracja kont)
- Interfejs webowy: tylko n8n Chat page (bez custom UI)
