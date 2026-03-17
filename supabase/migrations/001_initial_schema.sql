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
