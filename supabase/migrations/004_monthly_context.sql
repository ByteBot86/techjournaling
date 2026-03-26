alter table users
  add column if not exists pending_monthly_context jsonb default null;
