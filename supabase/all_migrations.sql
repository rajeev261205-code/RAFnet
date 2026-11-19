-- 001_soc_schema.sql
-- RAFNet schema — run in Supabase SQL editor (or supabase db push).
-- Enables RLS on every user table; owner-only access; models/experiments read-only.

-- profiles ---------------------------------------------------------------
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  role text default 'analyst',
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- analysis_results -------------------------------------------------------
create table if not exists analysis_results (
  id uuid primary key,
  user_id uuid references profiles(id) on delete set null,
  audio_name text,
  prediction text check (prediction in ('REAL','UNCERTAIN','SYNTHETIC')),
  confidence float check (confidence >= 0 and confidence <= 1),
  risk_score int check (risk_score >= 0 and risk_score <= 100),
  risk_level text check (risk_level in ('LOW','MEDIUM','HIGH','CRITICAL')),
  model_id text,
  processing_time_ms float,
  duration_seconds float,
  probs jsonb default '{}'::jsonb,
  gateway jsonb default '{}'::jsonb,
  mock boolean default false,
  created_at timestamptz default now()
);
create index if not exists idx_analysis_user_created on analysis_results (user_id, created_at desc);
create index if not exists idx_analysis_risk on analysis_results (risk_level, created_at desc);

-- calls ----------------------------------------------------------------
create table if not exists calls (
  id uuid primary key,
  user_id uuid references profiles(id) on delete set null,
  caller text,
  receiver text,
  duration_seconds float,
  status text,
  risk_score int,
  detection_result_id uuid references analysis_results(id) on delete set null,
  created_at timestamptz default now()
);

-- threats ---------------------------------------------------------------
create table if not exists threats (
  id uuid primary key,
  user_id uuid references profiles(id) on delete set null,
  analysis_id uuid references analysis_results(id) on delete cascade,
  threat_type text,
  severity text check (severity in ('LOW','MEDIUM','HIGH','CRITICAL')),
  confidence float,
  status text default 'open',
  details jsonb default '{}'::jsonb,
  created_at timestamptz default now()
);
create index if not exists idx_threats_severity on threats (severity, created_at desc);

-- models ----------------------------------------------------------------
create table if not exists models (
  id text primary key,
  name text,
  version text,
  framework text,
  description text,
  status text,
  metadata jsonb default '{}'::jsonb,
  created_at timestamptz default now()
);

-- experiments ------------------------------------------------------------
create table if not exists experiments (
  id uuid primary key default gen_random_uuid(),
  model_id text references models(id) on delete set null,
  name text,
  metrics jsonb default '{}'::jsonb,
  configuration jsonb default '{}'::jsonb,
  notes text,
  created_at timestamptz default now()
);

-- analysis_events ---------------------------------------------------------
create table if not exists analysis_events (
  id uuid primary key default gen_random_uuid(),
  analysis_id uuid references analysis_results(id) on delete cascade,
  event_type text,
  payload jsonb default '{}'::jsonb,
  created_at timestamptz default now()
);

-- RLS --------------------------------------------------------------------
alter table profiles enable row level security;
alter table analysis_results enable row level security;
alter table calls enable row level security;
alter table threats enable row level security;
alter table models enable row level security;
alter table experiments enable row level security;
alter table analysis_events enable row level security;

-- profiles: owner read/write
drop policy if exists "profiles owner" on profiles;
create policy "profiles owner" on profiles for all using (auth.uid() = id) with check (auth.uid() = id);

-- analysis_results: owner read/write
drop policy if exists "analysis owner" on analysis_results;
create policy "analysis owner" on analysis_results for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- calls: owner read/write
drop policy if exists "calls owner" on calls;
create policy "calls owner" on calls for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- threats: owner read/write
drop policy if exists "threats owner" on threats;
create policy "threats owner" on threats for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- analysis_events: owner via parent analysis
drop policy if exists "events via analysis owner" on analysis_events;
create policy "events via analysis owner" on analysis_events for all using (
  exists (select 1 from analysis_results a where a.id = analysis_events.analysis_id and a.user_id = auth.uid())
) with check (
  exists (select 1 from analysis_results a where a.id = analysis_events.analysis_id and a.user_id = auth.uid())
);

-- models / experiments: read-only to authenticated users (service role writes)
drop policy if exists "models readable" on models;
create policy "models readable" on models for select using (auth.role() = 'authenticated');
drop policy if exists "experiments readable" on experiments;
create policy "experiments readable" on experiments for select using (auth.role() = 'authenticated');

-- Seed: one model row reflecting the REAL supplied model (metadata only)
insert into models (id, name, version, framework, description, status, metadata)
values (
  'rafnet-1.0.0-phase19', 'RAFNet', '1.0.0-phase19', 'PyTorch + scikit-learn',
  'WavLM + Handcrafted -> Gateway1 -> Classical/Quantum -> Gateway2 -> Calibration -> DecisionGate. Synthetic-only training; see AI_MODEL_SPEC.md.',
  'experimental',
  '{"sample_rate": 16000, "tau_low": 0.361, "tau_high": 0.861}'::jsonb
) on conflict (id) do nothing;

-- 002_soc_verdict_columns.sql
-- RAFNet migration 002 — verdict/layers/reasons on analysis_results.
-- 001 only stored scalar + probs/gateway columns; the app-level record also
-- carries the fused verdict, detection layers, and risk reasons. Without these
-- columns production inserts either 400 (unknown columns) or silently drop
-- the data. Run after 001 in the Supabase SQL editor.
alter table analysis_results add column if not exists verdict jsonb default null;
alter table analysis_results add column if not exists layers jsonb default '[]'::jsonb;
alter table analysis_results add column if not exists reasons jsonb default '[]'::jsonb;

-- 003_soc_input_columns.sql
-- RAFNet migration 003 — upload provenance on analysis_results.
-- Layer 3 treats lossy uploads (mp3/aac/m4a/ogg) differently from lossless
-- audio and live-mic PCM: codec-cutoff evidence is excluded for lossy input.
-- These columns preserve that provenance per row. Run after 002.
alter table analysis_results add column if not exists input_codec text default null;
alter table analysis_results add column if not exists input_lossy boolean default false;

-- 004_soc_profile_bootstrap.sql
-- Ensure every Supabase Auth user has a `profiles` row.
--
-- `analysis_results.user_id`, `calls.user_id`, and `threats.user_id` all
-- reference `profiles(id)`. Supabase does not create profile rows
-- automatically, so without this trigger an authenticated insert can fail the
-- foreign key even though the JWT is valid. Existing users are backfilled
-- below; new users are handled by the trigger.

create or replace function public.rafnet_handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, new.raw_user_meta_data->>'full_name')
  on conflict (id) do nothing;
  return new;
end;
$$;

revoke all on function public.rafnet_handle_new_user() from public;

drop trigger if exists rafnet_on_auth_user_created on auth.users;
create trigger rafnet_on_auth_user_created
after insert on auth.users
for each row execute function public.rafnet_handle_new_user();

insert into public.profiles (id, display_name)
select u.id, u.raw_user_meta_data->>'full_name'
from auth.users u
on conflict (id) do nothing;

-- 005_soc_user_data_cascade.sql
-- Account deletion must not turn a user's private rows into anonymous rows.
--
-- The original schema used `on delete set null` for the owner columns. Since
-- the backend treats `user_id is null` as the anonymous principal, deleting an
-- Auth user would make their analyses/calls/threats readable by any anonymous
-- caller. Cascade instead: deleting the profile removes that user's rows.

alter table public.analysis_results
  drop constraint if exists analysis_results_user_id_fkey,
  add constraint analysis_results_user_id_fkey
    foreign key (user_id) references public.profiles(id) on delete cascade;

alter table public.calls
  drop constraint if exists calls_user_id_fkey,
  add constraint calls_user_id_fkey
    foreign key (user_id) references public.profiles(id) on delete cascade;

alter table public.threats
  drop constraint if exists threats_user_id_fkey,
  add constraint threats_user_id_fkey
    foreign key (user_id) references public.profiles(id) on delete cascade;
