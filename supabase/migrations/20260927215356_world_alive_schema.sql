-- Synced from live Supabase migration 20260927215356 (world_alive_schema)


alter table public.dungeon_runs add column if not exists modifier_slug text;
alter table public.party_dungeon_runs add column if not exists modifier_slug text;
alter table public.enemy_templates add column if not exists is_rare_variant boolean not null default false;

create table if not exists public.dungeon_modifier_definitions (
  slug text primary key,
  name text not null,
  description text not null default '',
  min_danger smallint not null default 0,
  max_danger smallint not null default 10,
  weight integer not null default 1 check(weight>0),
  enemy_hp_percent integer not null default 0,
  enemy_attack_percent integer not null default 0,
  enemy_defense_percent integer not null default 0,
  reward_gold_percent integer not null default 0,
  reward_xp_percent integer not null default 0,
  rare_boss_bonus_percent integer not null default 0,
  theme text not null default 'neutral',
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.dungeon_event_definitions (
  slug text primary key,
  name text not null,
  description text not null default '',
  min_danger smallint not null default 0,
  max_danger smallint not null default 10,
  weight integer not null default 1 check(weight>0),
  choices jsonb not null default '[]'::jsonb,
  auto_choice text not null,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.dungeon_run_events (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.dungeon_runs(id) on delete cascade,
  character_id uuid not null references public.characters(id) on delete cascade,
  room_index integer not null,
  event_slug text not null references public.dungeon_event_definitions(slug),
  status text not null default 'pending' check(status in ('pending','resolved')),
  choices jsonb not null default '[]'::jsonb,
  result_text text not null default '',
  selected_choice text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  unique(run_id,room_index)
);

create table if not exists public.character_discoveries (
  id uuid primary key default gen_random_uuid(),
  character_id uuid not null references public.characters(id) on delete cascade,
  category text not null,
  slug text not null,
  title text not null,
  description text not null default '',
  times_seen integer not null default 1,
  metadata jsonb not null default '{}'::jsonb,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique(character_id,category,slug)
);

create table if not exists public.character_treasure_hunts (
  id uuid primary key default gen_random_uuid(),
  character_id uuid not null references public.characters(id) on delete cascade,
  map_item_slug text not null,
  target_sector_id smallint not null references public.map_sectors(id),
  target_name text not null,
  reward_tier smallint not null default 1,
  status text not null default 'active' check(status in ('active','claimed','abandoned')),
  created_at timestamptz not null default now(),
  claimed_at timestamptz
);

create table if not exists public.wandering_merchant_catalog (
  item_definition_id uuid primary key references public.item_definitions(id) on delete cascade,
  min_level integer not null default 1,
  max_level integer not null default 99,
  offer_price integer not null check(offer_price>0),
  weight integer not null default 1,
  enabled boolean not null default true
);

create table if not exists public.wandering_merchant_purchases (
  character_id uuid not null references public.characters(id) on delete cascade,
  item_definition_id uuid not null references public.item_definitions(id) on delete cascade,
  rotation_date date not null,
  quantity integer not null default 1,
  created_at timestamptz not null default now(),
  primary key(character_id,item_definition_id,rotation_date)
);

create table if not exists public.world_rumors (
  slug text primary key,
  title text not null,
  body text not null,
  min_level integer not null default 1,
  enabled boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.dungeon_modifier_definitions enable row level security;
alter table public.dungeon_event_definitions enable row level security;
alter table public.dungeon_run_events enable row level security;
alter table public.character_discoveries enable row level security;
alter table public.character_treasure_hunts enable row level security;
alter table public.wandering_merchant_catalog enable row level security;
alter table public.wandering_merchant_purchases enable row level security;
alter table public.world_rumors enable row level security;

