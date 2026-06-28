-- Hands-Off email capture: subscribers table
-- Run in the Supabase SQL editor (or `supabase db push`).
-- All writes happen via the email-capture Worker using the SERVICE ROLE key,
-- which bypasses RLS. RLS is enabled with NO public policies so the anon key
-- (and anything that ever leaks into the desktop app) cannot read or write.

create extension if not exists "pgcrypto";

create table if not exists public.subscribers (
  id                 uuid primary key default gen_random_uuid(),
  email              text not null,
  confirmation_token uuid not null default gen_random_uuid(),
  confirmed          boolean not null default false,
  source             text,                       -- e.g. 'desktop', 'landing'
  created_at         timestamptz not null default now(),
  confirmed_at       timestamptz
);

-- Case-insensitive uniqueness so Alex@x.com and alex@x.com don't both land.
create unique index if not exists subscribers_email_key
  on public.subscribers (lower(email));

create index if not exists subscribers_token_idx
  on public.subscribers (confirmation_token);

alter table public.subscribers enable row level security;
-- Intentionally no policies: only the service role (Worker) may touch this table.
