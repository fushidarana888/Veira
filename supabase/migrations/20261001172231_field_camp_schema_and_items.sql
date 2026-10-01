
alter table public.character_camps drop constraint if exists character_camps_specialization_check;
alter table public.character_camps alter column specialization set default 'base';
update public.character_camps set specialization='base';
alter table public.character_camps add constraint character_camps_specialization_check check (specialization='base');
alter table public.character_camps
  add column if not exists camp_level smallint not null default 1,
  add column if not exists access_mode text not null default 'private',
  add column if not exists camp_name text not null default 'Полевой лагерь';
alter table public.character_camps drop constraint if exists character_camps_level_check;
alter table public.character_camps add constraint character_camps_level_check check (camp_level between 1 and 3);
alter table public.character_camps drop constraint if exists character_camps_access_mode_check;
alter table public.character_camps add constraint character_camps_access_mode_check check (access_mode in ('private','party','open'));
update public.character_camps set expires_at=greatest(expires_at,now()+interval '5 days'),updated_at=now();

create table if not exists public.camp_modules (
  camp_owner_character_id uuid not null references public.character_camps(character_id) on delete cascade,
  module_type text not null,
  built_at timestamptz not null default now(),
  primary key(camp_owner_character_id,module_type),
  check(module_type in ('scout_post','hunting_table','training_yard','trading_post','field_kitchen'))
);
alter table public.camp_modules enable row level security;
revoke all on table public.camp_modules from public,anon,authenticated;
grant all on table public.camp_modules to service_role;

create table if not exists public.camp_actions (
  id uuid primary key default gen_random_uuid(),
  actor_character_id uuid not null references public.characters(id) on delete cascade,
  camp_owner_character_id uuid not null references public.character_camps(character_id) on delete cascade,
  action_type text not null check(action_type in ('rest','scout')),
  target_sector_id smallint references public.map_sectors(id) on delete set null,
  started_at timestamptz not null default now(),
  ends_at timestamptz not null,
  status text not null default 'active' check(status in ('active','completed','cancelled')),
  result jsonb not null default '{}'::jsonb,
  completed_at timestamptz,
  check(ends_at>started_at)
);
create unique index if not exists camp_actions_one_active_actor_idx on public.camp_actions(actor_character_id) where status='active';
create index if not exists camp_actions_owner_idx on public.camp_actions(camp_owner_character_id,status);
alter table public.camp_actions enable row level security;
revoke all on table public.camp_actions from public,anon,authenticated;
grant all on table public.camp_actions to service_role;

create table if not exists public.camp_scout_reports (
  id uuid primary key default gen_random_uuid(),
  character_id uuid not null references public.characters(id) on delete cascade,
  camp_owner_character_id uuid references public.characters(id) on delete set null,
  sector_id smallint not null references public.map_sectors(id) on delete cascade,
  terrain_type text not null,
  content_hint text not null,
  danger_level smallint not null default 0,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now()+interval '24 hours')
);
create index if not exists camp_scout_reports_character_idx on public.camp_scout_reports(character_id,expires_at desc);
alter table public.camp_scout_reports enable row level security;
revoke all on table public.camp_scout_reports from public,anon,authenticated;
grant all on table public.camp_scout_reports to service_role;

create table if not exists public.character_camp_preparations (
  character_id uuid primary key references public.characters(id) on delete cascade,
  camp_owner_character_id uuid references public.characters(id) on delete set null,
  preparation_type text not null check(preparation_type in ('physical','magic','fortify')),
  prepared_at timestamptz not null default now(),
  expires_at timestamptz not null
);
alter table public.character_camp_preparations enable row level security;
revoke all on table public.character_camp_preparations from public,anon,authenticated;
grant all on table public.character_camp_preparations to service_role;

alter table public.item_definitions add column if not exists trade_policy text not null default 'tradeable';
alter table public.item_definitions drop constraint if exists item_definitions_trade_policy_check;
alter table public.item_definitions add constraint item_definitions_trade_policy_check check(trade_policy in ('tradeable','bind_on_equip','bound'));
alter table public.character_items add column if not exists bound_to_character_id uuid references public.characters(id) on delete set null;

create table if not exists public.camp_storage_items (
  id uuid primary key default gen_random_uuid(),
  camp_owner_character_id uuid not null references public.character_camps(character_id) on delete cascade,
  item_definition_id uuid not null references public.item_definitions(id) on delete cascade,
  quantity integer not null check(quantity>0),
  durability_current integer,
  durability_max integer,
  custom_name text,
  metadata jsonb not null default '{}'::jsonb,
  enhancement_level smallint not null default 0,
  awakening_level smallint not null default 0,
  lineage_id uuid not null,
  bound_to_character_id uuid references public.characters(id) on delete set null,
  stored_at timestamptz not null default now()
);
create index if not exists camp_storage_owner_idx on public.camp_storage_items(camp_owner_character_id,stored_at);
alter table public.camp_storage_items enable row level security;
revoke all on table public.camp_storage_items from public,anon,authenticated;
grant all on table public.camp_storage_items to service_role;

create table if not exists public.camp_trade_offers (
  id uuid primary key default gen_random_uuid(),
  camp_owner_character_id uuid not null references public.character_camps(character_id) on delete cascade,
  offered_by_character_id uuid not null references public.characters(id) on delete cascade,
  sector_id smallint not null references public.map_sectors(id) on delete cascade,
  offered_item_definition_id uuid not null references public.item_definitions(id) on delete cascade,
  offered_quantity integer not null check(offered_quantity>0),
  offered_durability_current integer,
  offered_durability_max integer,
  offered_custom_name text,
  offered_metadata jsonb not null default '{}'::jsonb,
  offered_enhancement_level smallint not null default 0,
  offered_awakening_level smallint not null default 0,
  offered_lineage_id uuid not null,
  requested_item_definition_id uuid not null references public.item_definitions(id) on delete cascade,
  requested_quantity integer not null check(requested_quantity>0),
  status text not null default 'open' check(status in ('open','accepted','cancelled','expired')),
  accepted_by_character_id uuid references public.characters(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  accepted_at timestamptz
);
create index if not exists camp_trade_offers_camp_idx on public.camp_trade_offers(camp_owner_character_id,status,expires_at);
create index if not exists camp_trade_offers_seller_idx on public.camp_trade_offers(offered_by_character_id,status);
alter table public.camp_trade_offers enable row level security;
revoke all on table public.camp_trade_offers from public,anon,authenticated;
grant all on table public.camp_trade_offers to service_role;

create table if not exists public.camp_event_claims (
  character_id uuid not null references public.characters(id) on delete cascade,
  event_date date not null,
  event_kind text not null,
  claimed_at timestamptz not null default now(),
  primary key(character_id,event_date)
);
alter table public.camp_event_claims enable row level security;
revoke all on table public.camp_event_claims from public,anon,authenticated;
grant all on table public.camp_event_claims to service_role;

insert into public.item_definitions(slug,name,description,category,rarity,stackable,max_stack,base_value,required_level,shop_enabled,effects,trade_policy) values
('field_timber','Полевой лес','Брусья, жерди и сухая древесина для обустройства временного лагеря.','material','common',true,999,3,1,false,'[]'::jsonb,'tradeable'),
('field_fiber','Прочное волокно','Верёвки и грубое волокно для палаток, навесов и лагерных построек.','material','common',true,999,3,1,false,'[]'::jsonb,'tradeable'),
('camp_stew','Полевое рагу','Горячая лагерная еда из свежей добычи и трав. Восстанавливает 60 ОЗ и 40 маны.','consumable','common',true,99,20,1,false,'[{"type":"heal_hp","amount":60},{"type":"restore_mana","amount":40}]'::jsonb,'tradeable')
on conflict(slug) do update set name=excluded.name,description=excluded.description,category=excluded.category,rarity=excluded.rarity,stackable=excluded.stackable,max_stack=excluded.max_stack,effects=excluded.effects,trade_policy=excluded.trade_policy;

update public.item_definitions
set trade_policy=case
  when rarity::text='unique' then 'bound'
  when religion_origin_slug is not null then 'bound'
  when category::text='quest' then 'bound'
  when slug in ('treasure_map_faded','treasure_map_royal','white_wolf_tooth') then 'bound'
  when id in (select e.reward_material_item_id from public.event_boss_events e where e.reward_material_item_id is not null) then 'bound'
  when category::text in ('weapon','armor','accessory') and rarity::text in ('rare','epic','legendary') then 'bind_on_equip'
  else 'tradeable'
end;

alter table private.hunting_attempts add column if not exists finishes_at timestamptz, add column if not exists focus_type text not null default 'general';
alter table private.hunting_attempts drop constraint if exists hunting_attempts_result_kind_check;
alter table private.hunting_attempts add constraint hunting_attempts_result_kind_check check(result_kind in ('pending','resource','nothing','tracks','monster'));
alter table private.hunting_attempts drop constraint if exists hunting_attempts_status_check;
alter table private.hunting_attempts add constraint hunting_attempts_status_check check(status in ('active','resolved','combat','victory','defeat','escaped','cancelled'));
alter table private.hunting_attempts drop constraint if exists hunting_attempts_focus_type_check;
alter table private.hunting_attempts add constraint hunting_attempts_focus_type_check check(focus_type in ('general','meat','hide','herbs','supplies'));

alter table private.hunting_loot_pool add column if not exists resource_type text not null default 'general';
alter table private.hunting_loot_pool drop constraint if exists hunting_loot_pool_resource_type_check;
alter table private.hunting_loot_pool add constraint hunting_loot_pool_resource_type_check check(resource_type in ('meat','hide','herbs','supplies','general'));

update private.hunting_loot_pool hp
set resource_type=case
  when d.slug in ('hunt_forest_meat','hunt_plains_meat','hunt_swamp_meat','hunt_desert_meat','hunt_mountain_meat','hunt_tundra_meat','hunt_coast_fish','hunt_river_fish') then 'meat'
  when d.slug in ('hunt_forest_hide','hunt_plains_hide','hunt_swamp_hide','hunt_desert_scales','hunt_mountain_hide','hunt_tundra_pelt','hunt_coast_shell') then 'hide'
  else 'herbs'
end
from public.item_definitions d where d.id=hp.item_definition_id;

insert into private.hunting_loot_pool(terrain_type,item_definition_id,weight,min_quantity,max_quantity,resource_type)
select terrain,d.id,22,1,2,'supplies'
from unnest(array['plains','forest','swamp','desert','mountains','tundra','coast','riverlands']) terrain
cross join public.item_definitions d where d.slug='field_timber'
on conflict(terrain_type,item_definition_id) do update set weight=excluded.weight,min_quantity=excluded.min_quantity,max_quantity=excluded.max_quantity,resource_type='supplies';

insert into private.hunting_loot_pool(terrain_type,item_definition_id,weight,min_quantity,max_quantity,resource_type)
select terrain,d.id,18,1,2,'supplies'
from unnest(array['plains','forest','swamp','desert','mountains','tundra','coast','riverlands']) terrain
cross join public.item_definitions d where d.slug='field_fiber'
on conflict(terrain_type,item_definition_id) do update set weight=excluded.weight,min_quantity=excluded.min_quantity,max_quantity=excluded.max_quantity,resource_type='supplies';

drop trigger if exists hunter_camp_after_hunting_attempt on private.hunting_attempts;

