
alter table public.spell_definitions drop constraint if exists spell_definitions_spell_kind_check;
alter table public.spell_definitions
  add constraint spell_definitions_spell_kind_check
  check (spell_kind = any(array['damage','heal','guard','cleanse','buff','taunt','sacrifice','summon']));

alter table public.spell_definitions drop constraint if exists spell_definitions_check;
alter table public.spell_definitions
  add constraint spell_definitions_check
  check (
    (spell_kind='damage' and damage_type is not null and support_effect_type is null)
    or (spell_kind='heal' and damage_type is null and support_effect_type is null)
    or (spell_kind='guard' and damage_type is null and support_effect_type='guard')
    or (spell_kind='cleanse' and damage_type is null and support_effect_type='cleanse')
    or (spell_kind='buff' and damage_type is null and support_effect_type='empower')
    or (spell_kind='taunt' and damage_type is null and support_effect_type='taunt')
    or (spell_kind='sacrifice' and damage_type is null and support_effect_type='sacrifice')
    or (spell_kind='summon' and damage_type is null and support_effect_type is null)
  );

create table if not exists private.summon_definitions(
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check(slug ~ '^[a-z0-9_]+$'),
  name text not null,
  description text not null default '',
  role text not null check(role in ('damage','tank','support')),
  hp_base integer not null check(hp_base>=1),
  hp_per_level numeric not null default 0 check(hp_per_level>=0),
  hp_per_vitality numeric not null default 0 check(hp_per_vitality>=0),
  hp_per_intellect numeric not null default 0 check(hp_per_intellect>=0),
  attack_base integer not null check(attack_base>=1),
  attack_per_level numeric not null default 0 check(attack_per_level>=0),
  attack_intellect_scale numeric not null default 0 check(attack_intellect_scale>=0),
  physical_armor_base integer not null default 0 check(physical_armor_base>=0),
  physical_armor_per_vitality numeric not null default 0 check(physical_armor_per_vitality>=0),
  magic_armor_base integer not null default 0 check(magic_armor_base>=0),
  magic_armor_per_intellect numeric not null default 0 check(magic_armor_per_intellect>=0),
  damage_type text not null check(damage_type in ('slashing','piercing','blunt','fire','water','earth','air','lightning','ice','arcane','star','gravity','moon')),
  solo_target_chance smallint not null default 20 check(solo_target_chance between 0 and 90),
  party_target_weight smallint not null default 40 check(party_target_weight between 1 and 200),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists private.combat_summons(
  id uuid primary key default gen_random_uuid(),
  context_type text not null check(context_type in ('solo','party')),
  encounter_id uuid not null,
  owner_character_id uuid not null references public.characters(id) on delete cascade,
  summon_definition_id uuid not null references private.summon_definitions(id) on delete restrict,
  status text not null default 'active' check(status in ('active','dead','dismissed')),
  hp_current integer not null check(hp_current>=0),
  hp_max integer not null check(hp_max>=1),
  attack integer not null check(attack>=1),
  physical_armor integer not null default 0 check(physical_armor>=0),
  magic_armor integer not null default 0 check(magic_armor>=0),
  damage_type text not null,
  solo_target_chance smallint not null,
  party_target_weight smallint not null,
  target_type text not null default 'encounter_enemy'
    check(target_type in ('encounter_enemy','enemy_instance')),
  target_id uuid,
  summoned_round integer not null default 0,
  created_at timestamptz not null default now(),
  died_at timestamptz
);

create unique index if not exists combat_summons_one_active_owner_idx
  on private.combat_summons(context_type,encounter_id,owner_character_id)
  where status='active';
create index if not exists combat_summons_encounter_idx
  on private.combat_summons(context_type,encounter_id,status);
create index if not exists combat_summons_owner_idx
  on private.combat_summons(owner_character_id,created_at desc);

insert into private.summon_definitions(
  slug,name,description,role,
  hp_base,hp_per_level,hp_per_vitality,hp_per_intellect,
  attack_base,attack_per_level,attack_intellect_scale,
  physical_armor_base,physical_armor_per_vitality,
  magic_armor_base,magic_armor_per_intellect,
  damage_type,solo_target_chance,party_target_weight
) values
('forest_wolf','Лесной волк','Быстрый зверь для постоянного физического давления. Живучесть средняя, враги иногда переключаются на него.','damage',45,5,4,0,8,2,0.70,10,0.35,6,0.20,'slashing',25,45),
('guardian_bear','Медведь-хранитель','Тяжёлый защитный призыв. Наносит меньше урона, зато имеет много ОЗ и чаще принимает атаки на себя.','tank',100,8,7,0,6,1.6,0.45,25,1.20,10,0.25,'blunt',55,130),
('forest_spirit','Дух леса','Магический дух поддержки и урона. Сильнее масштабируется от интеллекта и устойчив к магическим атакам.','support',55,4,3,3,12,2,1.10,8,0.25,20,1.20,'arcane',20,30)
on conflict(slug) do update set
  name=excluded.name,description=excluded.description,role=excluded.role,
  hp_base=excluded.hp_base,hp_per_level=excluded.hp_per_level,
  hp_per_vitality=excluded.hp_per_vitality,hp_per_intellect=excluded.hp_per_intellect,
  attack_base=excluded.attack_base,attack_per_level=excluded.attack_per_level,
  attack_intellect_scale=excluded.attack_intellect_scale,
  physical_armor_base=excluded.physical_armor_base,
  physical_armor_per_vitality=excluded.physical_armor_per_vitality,
  magic_armor_base=excluded.magic_armor_base,
  magic_armor_per_intellect=excluded.magic_armor_per_intellect,
  damage_type=excluded.damage_type,solo_target_chance=excluded.solo_target_chance,
  party_target_weight=excluded.party_target_weight,updated_at=now();

insert into public.magic_families(slug,name,kind,description,enabled,is_system,sort_order)
values
('nature','Природная','school','Магия живой природы, зверей, растений и природных духов.',true,true,130),
('summoning','Призыв','function','Создание временных союзных существ, которые сражаются рядом с заклинателем.',true,true,260)
on conflict(slug) do update set
 name=excluded.name,kind=excluded.kind,description=excluded.description,
 enabled=true,is_system=true,sort_order=excluded.sort_order,updated_at=now();

insert into public.spell_definitions(
 slug,name,description,enabled,spell_kind,damage_type,mana_cost,required_level,
 power_multiplier,flat_power,status_effect_type,status_effect_chance,status_effect_turns,status_effect_potency,
 support_effect_type,support_value,support_turns
) values
('summon_forest_wolf','Призыв лесного волка','Призывает лесного волка до конца боя. Волк действует после хозяина и может принимать атаки противника на себя.',true,'summon',null,35,3,0,0,null,0,0,0,null,0,0),
('summon_guardian_bear','Призыв медведя-хранителя','Призывает медведя-хранителя до конца боя. Он значительно живучее других призывов и чаще становится целью врага.',true,'summon',null,50,5,0,0,null,0,0,0,null,0,0),
('summon_forest_spirit','Призыв духа леса','Призывает духа леса до конца боя. Дух наносит магический урон и лучше масштабируется от интеллекта.',true,'summon',null,55,7,0,0,null,0,0,0,null,0,0)
on conflict(slug) do update set
 name=excluded.name,description=excluded.description,enabled=true,spell_kind='summon',
 damage_type=null,mana_cost=excluded.mana_cost,required_level=excluded.required_level,
 power_multiplier=0,flat_power=0,status_effect_type=null,status_effect_chance=0,
 status_effect_turns=0,status_effect_potency=0,support_effect_type=null,support_value=0,
 support_turns=0,updated_at=now();

insert into public.spell_magic_families(spell_id,family_slug)
select s.id,f.slug
from public.spell_definitions s
cross join (values('nature'),('summoning')) f(slug)
where s.slug in ('summon_forest_wolf','summon_guardian_bear','summon_forest_spirit')
on conflict do nothing;

insert into public.item_definitions(
  slug,name,description,category,rarity,stackable,max_stack,required_level,
  shop_tier,shop_price,shop_enabled,shop_sector_id,scroll_mode,scroll_spell_id
)
select
  x.slug,x.name,x.description,'consumable'::item_category,x.rarity::item_rarity,
  true,20,x.required_level,x.shop_tier,x.shop_price,true,x.shop_sector_id,'learn',s.id
from (
  values
  ('learn_scroll_summon_forest_wolf','Свиток изучения: Призыв лесного волка','Одноразовый свиток. Навсегда обучает призыву лесного волка.','uncommon',3,3,320,228),
  ('learn_scroll_summon_guardian_bear','Свиток изучения: Призыв медведя-хранителя','Редкий свиток. Навсегда обучает призыву медведя-хранителя.','rare',5,4,520,230),
  ('learn_scroll_summon_forest_spirit','Свиток изучения: Призыв духа леса','Редкий свиток. Навсегда обучает призыву духа леса.','rare',7,5,720,177)
) x(slug,name,description,rarity,required_level,shop_tier,shop_price,shop_sector_id)
join public.spell_definitions s on s.slug=replace(x.slug,'learn_scroll_','')
on conflict(slug) do update set
 name=excluded.name,description=excluded.description,rarity=excluded.rarity,
 required_level=excluded.required_level,shop_tier=excluded.shop_tier,
 shop_price=excluded.shop_price,shop_enabled=true,shop_sector_id=excluded.shop_sector_id,
 scroll_mode='learn',scroll_spell_id=excluded.scroll_spell_id,updated_at=now();

create or replace function private.summon_slug_for_spell(p_spell_slug text)
returns text language sql immutable set search_path to 'pg_catalog'
as $$
  select case p_spell_slug
    when 'summon_forest_wolf' then 'forest_wolf'
    when 'summon_guardian_bear' then 'guardian_bear'
    when 'summon_forest_spirit' then 'forest_spirit'
    else null
  end
$$;

create or replace function private.create_combat_summon(
  p_context_type text,p_encounter_id uuid,p_character_id uuid,p_spell_id uuid,p_round integer
) returns text
language plpgsql security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  spell_row public.spell_definitions;
  def private.summon_definitions;
  stats record;
  summon_slug text;
  max_hp integer;
  attack_value integer;
  phys_armor integer;
  magic_armor integer;
begin
  if p_context_type not in ('solo','party') then raise exception 'INVALID_SUMMON_CONTEXT'; end if;
  select * into spell_row from public.spell_definitions where id=p_spell_id and enabled;
  if spell_row.id is null or spell_row.spell_kind<>'summon' then raise exception 'SPELL_IS_NOT_SUMMON'; end if;
  summon_slug:=private.summon_slug_for_spell(spell_row.slug);
  if summon_slug is null then raise exception 'SUMMON_DEFINITION_NOT_FOUND'; end if;
  select * into def from private.summon_definitions where slug=summon_slug;
  if def.id is null then raise exception 'SUMMON_DEFINITION_NOT_FOUND'; end if;
  select * into stats from private.get_character_combat_stats(p_character_id);
  if stats.level is null then raise exception 'CHARACTER_PROGRESS_NOT_FOUND'; end if;

  max_hp:=greatest(1,round(def.hp_base+def.hp_per_level*stats.level+def.hp_per_vitality*stats.vitality+def.hp_per_intellect*stats.intellect)::integer);
  attack_value:=greatest(1,round(def.attack_base+def.attack_per_level*stats.level+def.attack_intellect_scale*stats.intellect)::integer);
  phys_armor:=greatest(0,round(def.physical_armor_base+def.physical_armor_per_vitality*stats.vitality)::integer);
  magic_armor:=greatest(0,round(def.magic_armor_base+def.magic_armor_per_intellect*stats.intellect)::integer);

  update private.combat_summons
  set status='dismissed',died_at=now()
  where context_type=p_context_type and encounter_id=p_encounter_id
    and owner_character_id=p_character_id and status='active';

  insert into private.combat_summons(
    context_type,encounter_id,owner_character_id,summon_definition_id,status,
    hp_current,hp_max,attack,physical_armor,magic_armor,damage_type,
    solo_target_chance,party_target_weight,target_type,target_id,summoned_round
  ) values(
    p_context_type,p_encounter_id,p_character_id,def.id,'active',
    max_hp,max_hp,attack_value,phys_armor,magic_armor,def.damage_type,
    def.solo_target_chance,def.party_target_weight,'encounter_enemy',null,greatest(0,coalesce(p_round,0))
  );
  return def.name;
end;
$$;

create or replace function private.resolve_solo_summon_action(p_encounter_id uuid,p_round integer)
returns integer language plpgsql security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  encounter public.combat_encounters; summon private.combat_summons; def private.summon_definitions;
  damage integer:=0; armor numeric:=0; resistance integer:=0; enemy_hp_before integer:=0;
begin
  select * into encounter from public.combat_encounters where id=p_encounter_id for update;
  if encounter.id is null or encounter.status<>'active' or encounter.enemy_hp_current<=0 then return 0; end if;
  select cs.* into summon from private.combat_summons cs
  where cs.context_type='solo' and cs.encounter_id=encounter.id
    and cs.owner_character_id=encounter.character_id and cs.status='active'
    and cs.summoned_round<coalesce(p_round,0)
  order by cs.created_at desc limit 1 for update;
  if summon.id is null then return 0; end if;
  if summon.target_type<>'encounter_enemy' or summon.target_id is not null then return 0; end if;
  select * into def from private.summon_definitions where id=summon.summon_definition_id;
  enemy_hp_before:=encounter.enemy_hp_current;
  armor:=case when summon.damage_type in ('slashing','piercing','blunt') then encounter.enemy_defense else encounter.enemy_defense*0.75 end;
  damage:=greatest(1,private.damage_after_armor(summon.attack+private.combat_damage_variance(0),armor));
  resistance:=private.damage_resistance_percent(encounter.enemy_resistances,summon.damage_type);
  damage:=greatest(1,round(damage*(100-resistance)/100.0)::integer);
  damage:=least(damage,enemy_hp_before);
  update public.combat_encounters set enemy_hp_current=greatest(0,enemy_hp_current-damage) where id=encounter.id;
  insert into public.combat_turns(encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message)
  values(encounter.id,p_round,'system','summon_attack',damage,encounter.player_hp_current,greatest(0,enemy_hp_before-damage),
    def.name||' атакует выбранную цель «'||encounter.enemy_name||'» и наносит '||damage||' '||private.damage_type_label(summon.damage_type)||' урона.');
  return damage;
end;
$$;

create or replace function private.resolve_party_summon_action(p_encounter_id uuid,p_owner_character_id uuid,p_round integer)
returns integer language plpgsql security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  encounter public.party_combat_encounters; summon private.combat_summons; def private.summon_definitions;
  damage integer:=0; armor numeric:=0; resistance integer:=0; enemy_hp_before integer:=0;
begin
  select * into encounter from public.party_combat_encounters where id=p_encounter_id for update;
  if encounter.id is null or encounter.status<>'active' or encounter.enemy_hp_current<=0 then return 0; end if;
  select cs.* into summon from private.combat_summons cs
  where cs.context_type='party' and cs.encounter_id=encounter.id
    and cs.owner_character_id=p_owner_character_id and cs.status='active'
    and cs.summoned_round<coalesce(p_round,0)
  order by cs.created_at desc limit 1 for update;
  if summon.id is null then return 0; end if;
  if summon.target_type<>'encounter_enemy' or summon.target_id is not null then return 0; end if;
  select * into def from private.summon_definitions where id=summon.summon_definition_id;
  enemy_hp_before:=encounter.enemy_hp_current;
  armor:=case when summon.damage_type in ('slashing','piercing','blunt') then encounter.enemy_defense else encounter.enemy_defense*0.75 end;
  damage:=greatest(1,private.damage_after_armor(summon.attack+private.combat_damage_variance(0),armor));
  resistance:=private.damage_resistance_percent(encounter.enemy_resistances,summon.damage_type);
  damage:=greatest(1,round(damage*(100-resistance)/100.0)::integer);
  damage:=least(damage,enemy_hp_before);
  update public.party_combat_encounters set enemy_hp_current=greatest(0,enemy_hp_current-damage) where id=encounter.id;
  insert into public.party_combat_turns(encounter_id,round,actor_type,actor_character_id,action_type,damage,message)
  values(encounter.id,p_round,'system',p_owner_character_id,'summon_attack',damage,
    def.name||' атакует выбранную цель «'||encounter.enemy_name||'» и наносит '||damage||' '||private.damage_type_label(summon.damage_type)||' урона.');
  return damage;
end;
$$;

create or replace function private.try_solo_enemy_attack_summon(p_encounter_id uuid,p_round integer,p_special_attack boolean)
returns boolean language plpgsql security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  encounter public.combat_encounters; summon private.combat_summons; def private.summon_definitions;
  hit_type text; armor numeric; attack_value integer; damage integer; hp_after integer;
begin
  select * into encounter from public.combat_encounters where id=p_encounter_id for update;
  if encounter.id is null or encounter.status<>'active' then return false; end if;
  select cs.* into summon from private.combat_summons cs
  where cs.context_type='solo' and cs.encounter_id=encounter.id
    and cs.owner_character_id=encounter.character_id and cs.status='active'
  order by cs.created_at desc limit 1 for update;
  if summon.id is null or floor(random()*100)::integer>=summon.solo_target_chance then return false; end if;
  select * into def from private.summon_definitions where id=summon.summon_definition_id;
  hit_type:=case when p_special_attack then coalesce(encounter.enemy_special_damage_type,encounter.enemy_damage_type) else encounter.enemy_damage_type end;
  armor:=case when hit_type in ('slashing','piercing','blunt') then summon.physical_armor else summon.magic_armor end;
  attack_value:=greatest(1,round(encounter.enemy_attack*(100+encounter.enemy_attack_bonus_percent)/100.0 * case when p_special_attack then encounter.enemy_special_damage_multiplier else 1.0 end)::integer);
  damage:=greatest(1,private.damage_after_armor(attack_value+private.combat_damage_variance(0),armor));
  damage:=least(damage,summon.hp_current);
  hp_after:=greatest(0,summon.hp_current-damage);
  update private.combat_summons set hp_current=hp_after,status=case when hp_after<=0 then 'dead' else 'active' end,
    died_at=case when hp_after<=0 then now() else died_at end where id=summon.id;
  insert into public.combat_turns(encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message)
  values(encounter.id,p_round,'enemy','attack_summon',damage,encounter.player_hp_current,encounter.enemy_hp_current,
    encounter.enemy_name||' переключается на '||def.name||' и наносит '||damage||' урона.'||case when hp_after<=0 then ' '||def.name||' погибает.' else '' end);
  return true;
end;
$$;

create or replace function private.try_party_enemy_attack_summon(p_encounter_id uuid,p_round integer,p_event_phase_bonus integer,p_special_multiplier numeric)
returns boolean language plpgsql security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  encounter public.party_combat_encounters; summon private.combat_summons; def private.summon_definitions;
  alive_members integer:=0; summon_weight integer:=0; total_weight integer:=0;
  hit_type text; armor numeric; attack_value integer; damage integer; hp_after integer;
begin
  select * into encounter from public.party_combat_encounters where id=p_encounter_id for update;
  if encounter.id is null or encounter.status<>'active' then return false; end if;
  select count(*) into alive_members from public.party_combat_member_states where encounter_id=encounter.id and not downed;
  select coalesce(sum(party_target_weight),0)::integer into summon_weight from private.combat_summons
    where context_type='party' and encounter_id=encounter.id and status='active';
  if summon_weight<=0 then return false; end if;
  total_weight:=greatest(1,alive_members*100+summon_weight);
  if floor(random()*total_weight)::integer>=summon_weight then return false; end if;
  select cs.* into summon from private.combat_summons cs
    where cs.context_type='party' and cs.encounter_id=encounter.id and cs.status='active'
    order by (-ln(greatest(random(),0.000001))/greatest(1,cs.party_target_weight)) asc limit 1 for update;
  if summon.id is null then return false; end if;
  select * into def from private.summon_definitions where id=summon.summon_definition_id;
  hit_type:=encounter.enemy_damage_type;
  armor:=case when hit_type in ('slashing','piercing','blunt') then summon.physical_armor else summon.magic_armor end;
  attack_value:=greatest(1,round(encounter.enemy_attack*(100+coalesce(p_event_phase_bonus,0))/100.0 * coalesce(p_special_multiplier,1.0))::integer);
  damage:=greatest(1,private.damage_after_armor(attack_value+private.combat_damage_variance(0),armor));
  damage:=least(damage,summon.hp_current);
  hp_after:=greatest(0,summon.hp_current-damage);
  update private.combat_summons set hp_current=hp_after,status=case when hp_after<=0 then 'dead' else 'active' end,
    died_at=case when hp_after<=0 then now() else died_at end where id=summon.id;
  insert into public.party_combat_turns(encounter_id,round,actor_type,actor_character_id,action_type,damage,message)
  values(encounter.id,p_round,'enemy',summon.owner_character_id,'attack_summon',damage,
    encounter.enemy_name||' выбирает целью '||def.name||' и наносит '||damage||' урона.'||case when hp_after<=0 then ' '||def.name||' погибает.' else '' end);
  return true;
end;
$$;

create or replace function public.get_combat_summons(p_character_id uuid,p_context_type text,p_encounter_id uuid)
returns table(
  id uuid,owner_character_id uuid,owner_name text,summon_slug text,summon_name text,
  description text,role text,status text,hp_current integer,hp_max integer,
  attack integer,physical_armor integer,magic_armor integer,damage_type text,
  target_type text,target_id uuid,target_name text,created_at timestamptz,died_at timestamptz
)
language plpgsql security definer set search_path to 'pg_catalog','public','private'
as $$
declare caller_id uuid:=auth.uid();
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters c where c.id=p_character_id and c.owner_user_id=caller_id) then raise exception 'CHARACTER_NOT_OWNED'; end if;
  if p_context_type='solo' then
    if not exists(select 1 from public.combat_encounters ce where ce.id=p_encounter_id and ce.character_id=p_character_id) then raise exception 'COMBAT_NOT_FOUND'; end if;
  elsif p_context_type='party' then
    if not exists(select 1 from public.party_combat_encounters pce join public.party_dungeon_run_members prm on prm.run_id=pce.run_id where pce.id=p_encounter_id and prm.character_id=p_character_id) then raise exception 'PARTY_COMBAT_NOT_FOUND'; end if;
  else raise exception 'INVALID_SUMMON_CONTEXT'; end if;

  return query
  select cs.id,cs.owner_character_id,c.name,sd.slug,sd.name,sd.description,sd.role,
         cs.status,cs.hp_current,cs.hp_max,cs.attack,cs.physical_armor,cs.magic_armor,
         cs.damage_type,cs.target_type,cs.target_id,
         case
           when cs.target_type='encounter_enemy' and p_context_type='solo' then (select ce.enemy_name from public.combat_encounters ce where ce.id=p_encounter_id)
           when cs.target_type='encounter_enemy' and p_context_type='party' then (select pce.enemy_name from public.party_combat_encounters pce where pce.id=p_encounter_id)
           else 'Неизвестная цель'
         end,
         cs.created_at,cs.died_at
  from private.combat_summons cs
  join private.summon_definitions sd on sd.id=cs.summon_definition_id
  join public.characters c on c.id=cs.owner_character_id
  where cs.context_type=p_context_type and cs.encounter_id=p_encounter_id and cs.status<>'dismissed'
  order by c.name,cs.created_at;
end;
$$;

create or replace function public.set_combat_summon_target(
  p_character_id uuid,p_context_type text,p_encounter_id uuid,p_summon_id uuid,
  p_target_type text,p_target_id uuid default null
) returns void
language plpgsql security definer set search_path to 'pg_catalog','public','private'
as $$
declare caller_id uuid:=auth.uid();
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters c where c.id=p_character_id and c.owner_user_id=caller_id) then raise exception 'CHARACTER_NOT_OWNED'; end if;
  if not exists(select 1 from private.combat_summons cs where cs.id=p_summon_id and cs.context_type=p_context_type and cs.encounter_id=p_encounter_id and cs.owner_character_id=p_character_id and cs.status='active') then raise exception 'ACTIVE_SUMMON_NOT_FOUND'; end if;

  if p_target_type='encounter_enemy' then
    if p_target_id is not null then raise exception 'INVALID_SUMMON_TARGET'; end if;
    if p_context_type='solo' and not exists(select 1 from public.combat_encounters ce where ce.id=p_encounter_id and ce.status='active') then raise exception 'SUMMON_TARGET_NOT_AVAILABLE'; end if;
    if p_context_type='party' and not exists(select 1 from public.party_combat_encounters pce where pce.id=p_encounter_id and pce.status='active') then raise exception 'SUMMON_TARGET_NOT_AVAILABLE'; end if;
  elsif p_target_type='enemy_instance' then
    raise exception 'MULTI_ENEMY_TARGETS_NOT_ENABLED_YET';
  else
    raise exception 'INVALID_SUMMON_TARGET';
  end if;

  update private.combat_summons set target_type=p_target_type,target_id=p_target_id where id=p_summon_id;
end;
$$;

revoke all on function public.get_combat_summons(uuid,text,uuid) from public,anon;
grant execute on function public.get_combat_summons(uuid,text,uuid) to authenticated;
revoke all on function public.set_combat_summon_target(uuid,text,uuid,uuid,text,uuid) from public,anon;
grant execute on function public.set_combat_summon_target(uuid,text,uuid,uuid,text,uuid) to authenticated;
