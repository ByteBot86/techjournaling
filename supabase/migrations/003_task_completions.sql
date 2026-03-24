create table task_completions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  week_start date not null,
  completed jsonb default '[]',
  incomplete jsonb default '[]',
  created_at timestamptz default now()
);
create index on task_completions (user_id, week_start);
