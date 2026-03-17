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

> **Schemat wektorowy:** tabele z embeddingami używają formatu n8n-native (`text`, `metadata jsonb`, `embedding vector`) dla natywnej integracji z n8n Supabase Vector Store node. Dane relacyjne (user_id, daty, kategorie) trzymane są w kolumnie `metadata`.

```sql
users
  id (uuid), telegram_id (bigint), user_login (text, unique), created_at

onboarding_profile          -- jednorazowy, niezmienny (bez embeddingu)
  id, user_id, gender, values_raw, completed_at

onboarding_sessions         -- stan wieloturowego dialogu
  user_id (PK), state, collected_data (jsonb), updated_at

journal_entries             -- pamięć krótkoterminowa (n8n-native)
  id, user_id (FK), text, metadata {week_start}, embedding (vector), created_at

weekly_condensations        -- pamięć średnioterminowa (n8n-native)
  id, user_id (FK), text, metadata {week_start}, embedding (vector), created_at

monthly_condensations       -- kondensacja miesięczna (n8n-native)
  id, user_id (FK), text, metadata {month}, embedding (vector), created_at

yearly_condensations        -- kondensacja roczna (n8n-native)
  id, user_id (FK), text, metadata {year}, embedding (vector), created_at

amphitheater                -- pamięć długoterminowa (n8n-native)
  id, user_id (FK), text, metadata {category, superseded_at}, embedding (vector), created_at
  superseded_at=null → aktualny rekord

weekly_plans                -- plany na następny tydzień (n8n-native)
  id, user_id (FK), text, metadata {week_start}, embedding (vector), created_at
```

**Zasada:** n8n Supabase Vector Store node wymaga kolumn `text + metadata + embedding`. `user_id` jako dedykowana kolumna z FK do `users` — filtrowanie przez `user_id = ?`, nie przez jsonb.

**Historia celów:** nowy cel = nowy rekord w `amphitheater` + `metadata.superseded_at = now()` na poprzednim. Aktualny cel = `metadata->>'category' = 'goal' AND metadata->>'superseded_at' IS NULL`.

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
