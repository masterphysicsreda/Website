-- Biology Student Portal · database schema (Supabase / Postgres)
-- All tables live in the private "app" schema, which the public API cannot read.
-- The website talks to the database only through the portal_* functions below;
-- each one checks the caller's session token. Student data is NOT stored in this repository.

create extension if not exists pgcrypto with schema extensions;
create schema if not exists app;
revoke all on schema app from public, anon, authenticated;

create table if not exists app.users(
  id text primary key check (id ~ '^\d{10}$'),
  name text not null,
  grade text,
  is_teacher boolean not null default false,
  pin_hash text not null,                 -- bcrypt hash of the 6-digit PIN
  payload jsonb not null default '{}'::jsonb,
  failed int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists app.sessions(
  token uuid primary key default gen_random_uuid(),
  user_id text not null references app.users(id) on delete cascade,
  expires_at timestamptz not null default now() + interval '14 hours'
);
create index if not exists sessions_user_idx on app.sessions(user_id);
create table if not exists app.lesson_state(
  user_id text not null references app.users(id) on delete cascade,
  lesson text not null,
  state jsonb not null,
  summary jsonb,
  updated_at timestamptz not null default now(),
  primary key(user_id, lesson)
);
create index if not exists lesson_state_lesson_idx on app.lesson_state(lesson);
create table if not exists app.events(id text primary key, priv boolean not null default false, data jsonb not null, updated_at timestamptz not null default now());
create table if not exists app.notes(user_id text not null references app.users(id) on delete cascade, lesson text not null, data jsonb not null, updated_at timestamptz not null default now(), primary key(user_id, lesson));
create table if not exists app.ai_usage(user_id text not null references app.users(id) on delete cascade, day date not null default current_date, n int not null default 0, primary key(user_id, day));
create table if not exists app.settings(k text primary key, v jsonb not null);
alter table app.users enable row level security;
alter table app.sessions enable row level security;
alter table app.lesson_state enable row level security;
alter table app.events enable row level security;
alter table app.notes enable row level security;
alter table app.ai_usage enable row level security;
alter table app.settings enable row level security;
