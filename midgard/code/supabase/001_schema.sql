-- =============================================================================
-- MidgardSurvivors - server-authoritative persistence (reference schema)
-- Target: the Supabase project the game already uses for leaderboard/cloud RPCs.
--
-- Principles
--   * The client NEVER writes a table directly. RLS gives clients read access to
--     their own rows only; every write goes through the `api` Edge Function,
--     which runs with the service role after validating the request.
--   * Every progression change is an append-only ledger row, so any balance can
--     be recomputed, audited and rolled back.
--   * Runs are tickets issued by the server. Rewards and leaderboard rows are
--     produced only by `finish`, never by a client call.
-- =============================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- accounts --
-- One row per auth.users row. Guests use Supabase anonymous sign-in and can be
-- upgraded to a named account later (same id, progress kept).
create table public.accounts (
  id              uuid primary key references auth.users(id) on delete cascade,
  name            text unique check (name ~ '^[A-Za-z0-9_.-]{3,20}$'),
  legacy_player_id text unique,              -- old Save.setting('player_id'), for migration
  legacy_cloud_user text,                    -- old cloud_user, for migration
  created_at      timestamptz not null default now(),
  trust           smallint    not null default 0,   -- raised by reviewed clean podium runs
  banned_until    timestamptz,
  ban_reason      text,
  shadow          boolean     not null default false -- hidden from public boards
);

-- --------------------------------------------------------------- profiles --
-- The authoritative meta-progression (the old Save.data minus device settings).
-- `rev` increments on every mutation; clients send it back as `if_rev` so stale
-- caches cannot overwrite newer state.
create table public.profiles (
  account_id  uuid primary key references public.accounts(id) on delete cascade,
  data        jsonb       not null,
  rev         bigint      not null default 1,
  schema_ver  int         not null default 1,
  origin      text        not null default 'fresh'
              check (origin in ('fresh','legacy_verified','legacy_quarantined')),
  updated_at  timestamptz not null default now()
);

-- Device-only preferences stay client-side, but a whitelisted copy can be stored
-- so they follow the account (mirrors CloudSave.DEVICE_KEYS).
create table public.prefs (
  account_id uuid primary key references public.accounts(id) on delete cascade,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- ----------------------------------------------------------------- ledger --
-- Append-only. Every zeny/card/item/xp change lands here with its cause.
create table public.ledger (
  id          bigint generated always as identity primary key,
  account_id  uuid not null references public.accounts(id) on delete cascade,
  at          timestamptz not null default now(),
  source      text not null check (source in ('run','action','daily','admin','migration','refund')),
  ref         text,                -- run id, action idempotency key, admin ticket...
  delta       jsonb not null,      -- e.g. {"zeny": 12345, "cards": {"hornet_card": 1}}
  profile_rev bigint not null      -- profiles.rev after applying
);
create index ledger_account_at on public.ledger (account_id, at desc);

-- -------------------------------------------------------------- devices --
create table public.devices (
  account_id uuid not null references public.accounts(id) on delete cascade,
  device_id  text not null check (length(device_id) between 16 and 64),
  platform   text,
  first_seen timestamptz not null default now(),
  last_seen  timestamptz not null default now(),
  primary key (account_id, device_id)
);
create index devices_by_device on public.devices (device_id);

-- ------------------------------------------------------------------ runs --
create type public.run_status as enum
  ('active','suspended','finished','expired','rejected');

create table public.runs (
  id             uuid primary key default gen_random_uuid(),
  account_id     uuid not null references public.accounts(id) on delete cascade,
  idem_key       text not null,             -- client-generated, makes /runs retry-safe
  mode           text not null,             -- stage | endless | tower | festival | coop
  class_id       text not null,
  stage_id       text not null,
  danger         int  not null default 1,
  party_id       uuid,                      -- shared by every member of a co-op run
  seed           bigint not null,           -- server-chosen RNG seed
  client_version text not null,
  loadout        jsonb not null,            -- server copy of gear/cards/pet/pacts at start
  status         public.run_status not null default 'active',
  ranked         boolean not null default true,
  started_at     timestamptz not null default now(),
  last_cp_at     timestamptz,
  finished_at    timestamptz,
  result         jsonb,
  rewards        jsonb,
  flags          text[] not null default '{}',
  unique (account_id, idem_key)
);
create index runs_account_started on public.runs (account_id, started_at desc);
create index runs_active on public.runs (status) where status in ('active','suspended');

-- Per-run server secret used to derive loot tickets (phase 6). Kept in its own
-- table with RLS on and no policy at all, so only the service role can read it.
create table public.run_secrets (
  run_id   uuid primary key references public.runs(id) on delete cascade,
  loot_key bytea not null default gen_random_bytes(32)
);

-- Heartbeat checkpoints (one row per batch item). `server_at` is the only clock
-- the validator trusts; `t` is the game clock the client reports.
create table public.run_checkpoints (
  run_id    uuid not null references public.runs(id) on delete cascade,
  seq       int  not null,
  t         real not null,
  server_at timestamptz not null default now(),
  payload   jsonb not null,
  primary key (run_id, seq)
);

-- Mid-run snapshot (replaces the plain-text user://profile.run file).
create table public.run_snapshots (
  run_id     uuid primary key references public.runs(id) on delete cascade,
  hash       text  not null,               -- sha256 of the snapshot text
  data       bytea not null,               -- gzip of the snapshot
  updated_at timestamptz not null default now()
);

-- ------------------------------------------------------------ leaderboard --
create table public.board_entries (
  board       text not null,               -- e.g. 'festival', 'festival_party', 'tower', 'stage:<id>'
  season      int  not null,
  account_id  uuid not null references public.accounts(id) on delete cascade,
  class_id    text not null,
  score       numeric not null,
  run_id      uuid not null references public.runs(id) on delete cascade,
  look        jsonb,
  verified    text not null default 'auto' check (verified in ('auto','reviewed','pending_review')),
  at          timestamptz not null default now(),
  primary key (board, season, account_id, class_id)
);
create index board_rank on public.board_entries (board, season, score desc);

-- ------------------------------------------------------------- integrity --
create table public.flags (
  id         bigint generated always as identity primary key,
  account_id uuid not null references public.accounts(id) on delete cascade,
  run_id     uuid references public.runs(id) on delete cascade,
  rule       text not null,                -- e.g. 'kill-rate-impossible'
  severity   text not null check (severity in ('info','review','reject','ban')),
  details    jsonb not null default '{}'::jsonb,
  at         timestamptz not null default now(),
  verdict    text check (verdict in ('confirmed','cleared')),
  reviewed_by uuid
);
create index flags_open on public.flags (at desc) where verdict is null;

-- Idempotency for profile actions (shop, refine, fuse, claim...).
create table public.action_keys (
  account_id uuid not null references public.accounts(id) on delete cascade,
  key        text not null,
  response   jsonb not null,
  at         timestamptz not null default now(),
  primary key (account_id, key)
);

-- =================================================================== RLS ==
alter table public.accounts        enable row level security;
alter table public.profiles        enable row level security;
alter table public.prefs           enable row level security;
alter table public.ledger          enable row level security;
alter table public.devices         enable row level security;
alter table public.runs            enable row level security;
alter table public.run_secrets     enable row level security;
alter table public.run_checkpoints enable row level security;
alter table public.run_snapshots   enable row level security;
alter table public.board_entries   enable row level security;
alter table public.flags           enable row level security;
alter table public.action_keys     enable row level security;

-- Read-own policies. There are deliberately NO insert/update/delete policies:
-- with RLS on and no write policy, anon/authenticated roles cannot write at all.
create policy "own account"  on public.accounts  for select using (id = auth.uid());
create policy "own profile"  on public.profiles  for select using (account_id = auth.uid());
create policy "own prefs"    on public.prefs     for select using (account_id = auth.uid());
create policy "own ledger"   on public.ledger    for select using (account_id = auth.uid());
create policy "own runs"     on public.runs      for select using (account_id = auth.uid());

-- Public leaderboard view: hides shadow-banned accounts and pending reviews.
create view public.board_public with (security_invoker = false) as
  select e.board, e.season, a.name, e.class_id, e.score, e.look, e.at
  from public.board_entries e
  join public.accounts a on a.id = e.account_id
  where not a.shadow
    and (a.banned_until is null or a.banned_until < now())
    and e.verified <> 'pending_review';
grant select on public.board_public to anon, authenticated;

-- ==================================================== legacy RPC lockdown ==
-- Once clients >= the cutover version are mandatory, the old unauthenticated
-- RPCs (submit_record, submit_festival, submit_tower, cloud_put, rename_player,
-- ...) must stop accepting writes. Keep read-only ones for old clients.
-- revoke execute on function public.submit_record(jsonb)   from anon;
-- revoke execute on function public.submit_festival(jsonb) from anon;
-- revoke execute on function public.cloud_put(jsonb)       from anon;
