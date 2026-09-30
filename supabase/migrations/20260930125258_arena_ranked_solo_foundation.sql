create table if not exists public.arena_seasons (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  created_at timestamptz not null default now(),
  constraint arena_seasons_window_check check (ends_at > starts_at)
);

create table if not exists public.arena_rank_definitions (
  slug text primary key,
  name text not null,
  min_mmr integer not null unique,
  sort_order smallint not null unique,
  milestone_gold integer not null default 0 check (milestone_gold >= 0),
  season_gold integer not null default 0 check (season_gold >= 0)
);

insert into public.arena_rank_definitions(slug,name,min_mmr,sort_order,milestone_gold,season_gold)
values
  ('iron','Железо',0,1,40,80),
  ('bronze','Бронза',900,2,60,120),
  ('silver','Серебро',1100,3,90,180),
  ('gold','Золото',1300,4,130,260),
  ('platinum','Платина',1500,5,180,360),
  ('mythril','Мифрил',1750,6,250,500),
  ('stellar','Звёздный',2050,7,350,700),
  ('legend','Легенда',2400,8,500,1000)
on conflict (slug) do update
set name=excluded.name,
    min_mmr=excluded.min_mmr,
    sort_order=excluded.sort_order,
    milestone_gold=excluded.milestone_gold,
    season_gold=excluded.season_gold;

create table if not exists public.arena_character_ratings (
  season_id uuid not null references public.arena_seasons(id) on delete cascade,
  character_id uuid not null references public.characters(id) on delete cascade,
  mode text not null,
  mmr integer not null default 1000 check (mmr between 0 and 5000),
  peak_mmr integer not null default 1000 check (peak_mmr between 0 and 5000),
  matches integer not null default 0 check (matches >= 0),
  wins integer not null default 0 check (wins >= 0),
  losses integer not null default 0 check (losses >= 0),
  draws integer not null default 0 check (draws >= 0),
  last_match_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (season_id, character_id, mode),
  constraint arena_character_ratings_mode_check check (mode in ('solo','party'))
);

create table if not exists public.arena_guild_ratings (
  season_id uuid not null references public.arena_seasons(id) on delete cascade,
  guild_id uuid not null references public.guilds(id) on delete cascade,
  mmr integer not null default 1000 check (mmr between 0 and 5000),
  peak_mmr integer not null default 1000 check (peak_mmr between 0 and 5000),
  matches integer not null default 0 check (matches >= 0),
  wins integer not null default 0 check (wins >= 0),
  losses integer not null default 0 check (losses >= 0),
  draws integer not null default 0 check (draws >= 0),
  last_match_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (season_id, guild_id)
);

create table if not exists public.arena_matches (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.arena_seasons(id) on delete cascade,
  mode text not null default 'solo',
  challenger_character_id uuid references public.characters(id) on delete set null,
  opponent_character_id uuid references public.characters(id) on delete set null,
  winner_character_id uuid references public.characters(id) on delete set null,
  challenger_mmr_before integer not null,
  challenger_mmr_after integer not null,
  opponent_mmr_before integer not null,
  opponent_mmr_after integer not null,
  challenger_rank_before text not null,
  challenger_rank_after text not null,
  opponent_rank_before text not null,
  opponent_rank_after text not null,
  rounds integer not null default 0,
  challenger_final_hp integer not null default 0,
  opponent_final_hp integer not null default 0,
  combat_log jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  constraint arena_matches_mode_check check (mode in ('solo','party','guild'))
);

create index if not exists arena_matches_challenger_created_idx
  on public.arena_matches(challenger_character_id, created_at desc);
create index if not exists arena_matches_opponent_created_idx
  on public.arena_matches(opponent_character_id, created_at desc);
create index if not exists arena_character_ratings_solo_mmr_idx
  on public.arena_character_ratings(season_id, mode, mmr desc)
  where mode='solo';

create table if not exists public.arena_rank_achievements (
  season_id uuid not null references public.arena_seasons(id) on delete cascade,
  character_id uuid not null references public.characters(id) on delete cascade,
  mode text not null,
  rank_slug text not null references public.arena_rank_definitions(slug),
  reward_gold integer not null default 0,
  reached_at timestamptz not null default now(),
  primary key (season_id, character_id, mode, rank_slug),
  constraint arena_rank_achievements_mode_check check (mode in ('solo','party'))
);

create table if not exists public.arena_season_reward_claims (
  season_id uuid not null references public.arena_seasons(id) on delete cascade,
  character_id uuid not null references public.characters(id) on delete cascade,
  mode text not null,
  rank_slug text not null references public.arena_rank_definitions(slug),
  reward_gold integer not null default 0,
  claimed_at timestamptz not null default now(),
  primary key (season_id, character_id, mode),
  constraint arena_season_reward_claims_mode_check check (mode in ('solo','party'))
);

alter table public.arena_seasons enable row level security;
alter table public.arena_rank_definitions enable row level security;
alter table public.arena_character_ratings enable row level security;
alter table public.arena_guild_ratings enable row level security;
alter table public.arena_matches enable row level security;
alter table public.arena_rank_achievements enable row level security;
alter table public.arena_season_reward_claims enable row level security;

revoke all on table public.arena_seasons from anon, authenticated;
revoke all on table public.arena_rank_definitions from anon, authenticated;
revoke all on table public.arena_character_ratings from anon, authenticated;
revoke all on table public.arena_guild_ratings from anon, authenticated;
revoke all on table public.arena_matches from anon, authenticated;
revoke all on table public.arena_rank_achievements from anon, authenticated;
revoke all on table public.arena_season_reward_claims from anon, authenticated;

insert into public.arena_seasons(slug,name,starts_at,ends_at)
values(
  'season-1-awakening',
  'Сезон I · Пробуждение',
  '2026-09-30 00:00:00+03'::timestamptz,
  '2026-11-16 00:00:00+03'::timestamptz
)
on conflict (slug) do update
set name=excluded.name,
    starts_at=excluded.starts_at,
    ends_at=excluded.ends_at;

create or replace function private.arena_rank_for_mmr(p_mmr integer, p_matches integer)
returns text
language sql
stable
security definer
set search_path = pg_catalog, public, private
as $$
  select case
    when coalesce(p_matches,0) < 5 then 'calibration'
    else coalesce(
      (
        select d.slug
        from public.arena_rank_definitions d
        where d.min_mmr <= greatest(0,coalesce(p_mmr,0))
        order by d.min_mmr desc
        limit 1
      ),
      'iron'
    )
  end
$$;

create or replace function private.arena_rank_name(p_slug text)
returns text
language sql
stable
security definer
set search_path = pg_catalog, public, private
as $$
  select case
    when p_slug='calibration' then 'Калибровка'
    else coalesce((select name from public.arena_rank_definitions where slug=p_slug),'Железо')
  end
$$;

create or replace function private.arena_choose_action(
  p_actor_id uuid,
  p_actor_stats jsonb,
  p_actor_hp integer,
  p_actor_hp_max integer,
  p_actor_mana integer,
  p_actor_mana_max integer,
  p_actor_action_count integer,
  p_actor_guard_active boolean,
  p_target_stats jsonb,
  p_target_hp integer,
  p_target_hp_max integer
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  settings public.character_autobattle_settings;
  hp_percent numeric;
  target_resistances jsonb := coalesce(p_target_stats->'damage_resistances','{}'::jsonb);
  physical_damage integer := -1;
  magic_damage integer := -1;
  spell_damage integer := -1;
  spell_cost integer := 0;
  spell_id uuid;
  spell_name text;
  heal_id uuid;
  heal_name text;
  heal_cost integer := 0;
  heal_value integer := 0;
  guard_due boolean := false;
  best_action text := 'physical';
  best_damage integer := 1;
  variance integer := 0;
  resist integer := 0;
  actor_all_bonus integer := coalesce((p_actor_stats->>'all_damage_bonus_percent')::integer,0);
  actor_physical_bonus integer := coalesce((p_actor_stats->>'physical_damage_bonus_percent')::integer,0);
  actor_magic_bonus integer := coalesce((p_actor_stats->>'magic_damage_bonus_percent')::integer,0);
  actor_wounded_bonus integer := coalesce((p_actor_stats->>'damage_vs_wounded_percent')::integer,0);
  target_low_hp_reduction integer := coalesce((p_target_stats->>'low_hp_damage_reduction_percent')::integer,0);
  actor_magic_power integer := greatest(1,coalesce((p_actor_stats->>'magic_power')::integer,1));
  actor_physical_power integer := greatest(1,coalesce((p_actor_stats->>'physical_power')::integer,1));
  target_physical_defense integer := greatest(0,coalesce((p_target_stats->>'defense')::integer,0));
  target_magic_defense integer := greatest(0,round(
    (
      coalesce((p_target_stats->>'level')::integer,1)
      + coalesce((p_target_stats->>'vitality')::integer,0)
      + coalesce((p_target_stats->>'intellect')::integer,0)
    )
  )::integer);
  weapon_type text := coalesce(p_actor_stats->>'weapon_damage_type','blunt');
  magic_type text := coalesce(p_actor_stats->>'magic_damage_type','fire');
  s record;
  raw integer;
begin
  select * into settings
  from public.character_autobattle_settings
  where character_id=p_actor_id;

  if settings.character_id is null then
    settings.strategy := 'balanced';
    settings.mana_reserve_percent := 25;
    settings.normal_allow_physical := true;
    settings.normal_allow_magic := true;
    settings.normal_allow_spells := true;
    settings.normal_guard_mode := 'low_hp';
    settings.normal_guard_hp_percent := 25;
    settings.normal_guard_every_n := 0;
    settings.normal_support_enabled := true;
    settings.normal_heal_hp_percent := 45;
  end if;

  hp_percent := case when p_actor_hp_max>0 then p_actor_hp*100.0/p_actor_hp_max else 100 end;

  if coalesce(settings.normal_support_enabled,true)
     and coalesce(settings.normal_allow_spells,true)
     and hp_percent <= coalesce(settings.normal_heal_hp_percent,45)
  then
    select sd.id,sd.name,private.character_effective_spell_mana_cost(p_actor_id,sd.id),
           private.concentrated_spell_direct_value(
             p_actor_id,
             sd.id,
             greatest(1,round(actor_magic_power*sd.power_multiplier)::integer+sd.flat_power)
           )
    into heal_id,heal_name,heal_cost,heal_value
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=p_actor_id
      and sd.enabled=true
      and sd.spell_kind='heal'
      and private.character_effective_spell_mana_cost(p_actor_id,sd.id) <= p_actor_mana
    order by (
      round(actor_magic_power*sd.power_multiplier)::integer+sd.flat_power
    ) desc
    limit 1;

    if heal_id is not null and heal_value>0 then
      return jsonb_build_object(
        'action','heal','label',heal_name,'value',least(p_actor_hp_max-p_actor_hp,heal_value),
        'mana_cost',heal_cost
      );
    end if;
  end if;

  guard_due := case coalesce(settings.normal_guard_mode,'low_hp')
    when 'never' then false
    when 'low_hp' then hp_percent <= coalesce(settings.normal_guard_hp_percent,25)
    when 'interval' then coalesce(settings.normal_guard_every_n,0)>0
      and p_actor_action_count>0
      and mod(p_actor_action_count,settings.normal_guard_every_n)=0
    when 'low_hp_or_interval' then
      hp_percent <= coalesce(settings.normal_guard_hp_percent,25)
      or (
        coalesce(settings.normal_guard_every_n,0)>0
        and p_actor_action_count>0
        and mod(p_actor_action_count,settings.normal_guard_every_n)=0
      )
    else false
  end;

  if guard_due and not p_actor_guard_active then
    return jsonb_build_object(
      'action','guard','label','Защита',
      'value',least(80,55+coalesce((p_actor_stats->>'guard_boost_percent')::integer,0)),
      'mana_cost',0
    );
  end if;

  variance := private.combat_damage_variance(coalesce((p_actor_stats->>'luck')::integer,0));

  if coalesce(settings.normal_allow_physical,true) then
    physical_damage := private.weapon_family_physical_raw_damage(
      p_actor_id,
      actor_physical_power,
      target_physical_defense,
      p_target_hp_max,
      variance
    );
    physical_damage := greatest(1,round(
      physical_damage*(100+actor_all_bonus+actor_physical_bonus)/100.0
    )::integer);
    resist := private.damage_resistance_percent(target_resistances,weapon_type);
    physical_damage := greatest(1,round(physical_damage*(100-resist)/100.0)::integer);
    if p_target_hp*2 <= p_target_hp_max then
      physical_damage := greatest(1,round(physical_damage*(100+actor_wounded_bonus)/100.0)::integer);
      physical_damage := greatest(1,round(physical_damage*(100-target_low_hp_reduction)/100.0)::integer);
    end if;
  end if;

  if coalesce(settings.normal_allow_magic,true) then
    magic_damage := greatest(
      1,
      private.damage_after_armor(actor_magic_power+variance,target_magic_defense)
    );
    magic_damage := greatest(1,round(
      magic_damage*(100+actor_all_bonus+actor_magic_bonus)/100.0
    )::integer);
    resist := private.damage_resistance_percent(target_resistances,magic_type);
    magic_damage := greatest(1,round(magic_damage*(100-resist)/100.0)::integer);
    if p_target_hp*2 <= p_target_hp_max then
      magic_damage := greatest(1,round(magic_damage*(100+actor_wounded_bonus)/100.0)::integer);
      magic_damage := greatest(1,round(magic_damage*(100-target_low_hp_reduction)/100.0)::integer);
    end if;
  end if;

  if coalesce(settings.normal_allow_spells,true) then
    for s in
      select sd.*
      from public.character_combat_spells ccs
      join public.spell_definitions sd on sd.id=ccs.spell_id
      where ccs.character_id=p_actor_id
        and sd.enabled=true
        and sd.spell_kind='damage'
        and private.character_effective_spell_mana_cost(p_actor_id,sd.id) <= p_actor_mana
        and (
          p_actor_mana_max<=0
          or p_actor_mana-private.character_effective_spell_mana_cost(p_actor_id,sd.id)
             >= floor(p_actor_mana_max*coalesce(settings.mana_reserve_percent,25)/100.0)
          or coalesce(settings.strategy,'balanced')='aggressive'
        )
    loop
      raw := private.concentrated_spell_direct_value(
        p_actor_id,
        s.id,
        greatest(
          1,
          private.damage_after_armor(
            round(actor_magic_power*s.power_multiplier)::integer+s.flat_power+variance,
            target_magic_defense*0.65
          )
        )
      );
      raw := private.ensure_spell_stronger_than_innate(
        raw,
        greatest(1,private.damage_after_armor(actor_magic_power+variance,target_magic_defense)),
        10
      );
      raw := greatest(1,round(
        raw*(
          100+actor_all_bonus+actor_magic_bonus+
          private.character_spell_family_damage_bonus_percent(p_actor_id,s.id)
        )/100.0
      )::integer);
      resist := private.damage_resistance_percent(target_resistances,s.damage_type);
      raw := greatest(1,round(raw*(100-resist)/100.0)::integer);
      if p_target_hp*2 <= p_target_hp_max then
        raw := greatest(1,round(raw*(100+actor_wounded_bonus)/100.0)::integer);
        raw := greatest(1,round(raw*(100-target_low_hp_reduction)/100.0)::integer);
      end if;

      if raw>spell_damage then
        spell_damage:=raw;
        spell_id:=s.id;
        spell_name:=s.name;
        spell_cost:=private.character_effective_spell_mana_cost(p_actor_id,s.id);
      end if;
    end loop;
  end if;

  best_damage:=greatest(physical_damage,magic_damage,spell_damage,1);
  if spell_damage=best_damage and spell_id is not null then
    best_action:='spell';
    return jsonb_build_object(
      'action',best_action,'label',spell_name,'value',best_damage,'mana_cost',spell_cost,'spell_id',spell_id
    );
  elsif magic_damage=best_damage and magic_damage>=0 then
    best_action:='magic';
  else
    best_action:='physical';
  end if;

  return jsonb_build_object(
    'action',best_action,
    'label',case when best_action='magic' then 'Врождённая магия' else 'Физическая атака' end,
    'value',best_damage,
    'mana_cost',0
  );
end;
$$;

create or replace function private.arena_simulate_solo(
  p_challenger_id uuid,
  p_opponent_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  a record;
  b record;
  a_json jsonb;
  b_json jsonb;
  a_name text;
  b_name text;
  a_hp integer;
  b_hp integer;
  a_mana integer;
  b_mana integer;
  a_guard integer:=0;
  b_guard integer:=0;
  a_actions integer:=0;
  b_actions integer:=0;
  a_time numeric;
  b_time numeric;
  action jsonb;
  action_type text;
  action_label text;
  value integer;
  mana_cost integer;
  actual integer;
  heal integer;
  actor_lifesteal integer;
  actor_mana_on_hit integer;
  total_actions integer:=0;
  log_data jsonb:='[]'::jsonb;
  winner uuid:=null;
  a_ratio numeric;
  b_ratio numeric;
begin
  select * into a from private.get_character_combat_stats(p_challenger_id);
  select * into b from private.get_character_combat_stats(p_opponent_id);
  if a.level is null or b.level is null then raise exception 'ARENA_COMBAT_STATS_NOT_FOUND'; end if;

  select name into a_name from public.characters where id=p_challenger_id;
  select name into b_name from public.characters where id=p_opponent_id;

  a_json:=to_jsonb(a);
  b_json:=to_jsonb(b);
  a_hp:=greatest(1,a.hp_max);
  b_hp:=greatest(1,b.hp_max);
  a_mana:=greatest(0,a.mana_max);
  b_mana:=greatest(0,b.mana_max);

  a_time:=1000.0/greatest(1,a.initiative) * (0.97+random()*0.06);
  b_time:=1000.0/greatest(1,b.initiative) * (0.97+random()*0.06);

  while a_hp>0 and b_hp>0 and total_actions<80 loop
    total_actions:=total_actions+1;

    if a_time<=b_time then
      action:=private.arena_choose_action(
        p_challenger_id,a_json,a_hp,a.hp_max,a_mana,a.mana_max,a_actions,a_guard>0,
        b_json,b_hp,b.hp_max
      );
      action_type:=action->>'action';
      action_label:=coalesce(action->>'label',action_type);
      value:=greatest(0,coalesce((action->>'value')::integer,0));
      mana_cost:=greatest(0,coalesce((action->>'mana_cost')::integer,0));
      a_mana:=greatest(0,a_mana-mana_cost);

      if action_type='guard' then
        a_guard:=value;
        actual:=0;
        heal:=0;
      elsif action_type='heal' then
        heal:=least(a.hp_max-a_hp,value);
        a_hp:=least(a.hp_max,a_hp+heal);
        actual:=0;
      else
        actual:=value;
        if b_guard>0 then
          actual:=greatest(1,round(actual*(100-b_guard)/100.0)::integer);
          b_guard:=0;
        end if;
        actual:=least(b_hp,actual);
        b_hp:=greatest(0,b_hp-actual);
        actor_lifesteal:=least(50,greatest(0,a.lifesteal_percent));
        if actor_lifesteal>0 and actual>0 then
          a_hp:=least(a.hp_max,a_hp+greatest(1,floor(actual*actor_lifesteal/100.0)::integer));
        end if;
        actor_mana_on_hit:=greatest(0,a.mana_on_hit);
        if actor_mana_on_hit>0 and actual>0 then
          a_mana:=least(a.mana_max,a_mana+actor_mana_on_hit);
        end if;
        heal:=0;
      end if;

      a_actions:=a_actions+1;
      a_time:=a_time+1000.0/greatest(1,a.initiative);
      log_data:=log_data||jsonb_build_array(jsonb_build_object(
        'turn',total_actions,'actor_id',p_challenger_id,'actor_name',a_name,
        'action',action_type,'label',action_label,'damage',actual,'healing',heal,
        'actor_hp',a_hp,'actor_mana',a_mana,'target_hp',b_hp
      ));
    else
      action:=private.arena_choose_action(
        p_opponent_id,b_json,b_hp,b.hp_max,b_mana,b.mana_max,b_actions,b_guard>0,
        a_json,a_hp,a.hp_max
      );
      action_type:=action->>'action';
      action_label:=coalesce(action->>'label',action_type);
      value:=greatest(0,coalesce((action->>'value')::integer,0));
      mana_cost:=greatest(0,coalesce((action->>'mana_cost')::integer,0));
      b_mana:=greatest(0,b_mana-mana_cost);

      if action_type='guard' then
        b_guard:=value;
        actual:=0;
        heal:=0;
      elsif action_type='heal' then
        heal:=least(b.hp_max-b_hp,value);
        b_hp:=least(b.hp_max,b_hp+heal);
        actual:=0;
      else
        actual:=value;
        if a_guard>0 then
          actual:=greatest(1,round(actual*(100-a_guard)/100.0)::integer);
          a_guard:=0;
        end if;
        actual:=least(a_hp,actual);
        a_hp:=greatest(0,a_hp-actual);
        actor_lifesteal:=least(50,greatest(0,b.lifesteal_percent));
        if actor_lifesteal>0 and actual>0 then
          b_hp:=least(b.hp_max,b_hp+greatest(1,floor(actual*actor_lifesteal/100.0)::integer));
        end if;
        actor_mana_on_hit:=greatest(0,b.mana_on_hit);
        if actor_mana_on_hit>0 and actual>0 then
          b_mana:=least(b.mana_max,b_mana+actor_mana_on_hit);
        end if;
        heal:=0;
      end if;

      b_actions:=b_actions+1;
      b_time:=b_time+1000.0/greatest(1,b.initiative);
      log_data:=log_data||jsonb_build_array(jsonb_build_object(
        'turn',total_actions,'actor_id',p_opponent_id,'actor_name',b_name,
        'action',action_type,'label',action_label,'damage',actual,'healing',heal,
        'actor_hp',b_hp,'actor_mana',b_mana,'target_hp',a_hp
      ));
    end if;
  end loop;

  if a_hp<=0 and b_hp>0 then
    winner:=p_opponent_id;
  elsif b_hp<=0 and a_hp>0 then
    winner:=p_challenger_id;
  elsif a_hp<=0 and b_hp<=0 then
    winner:=null;
  else
    a_ratio:=a_hp::numeric/greatest(1,a.hp_max);
    b_ratio:=b_hp::numeric/greatest(1,b.hp_max);
    if a_ratio>b_ratio+0.01 then winner:=p_challenger_id;
    elsif b_ratio>a_ratio+0.01 then winner:=p_opponent_id;
    else winner:=null;
    end if;
  end if;

  return jsonb_build_object(
    'winner_character_id',winner,
    'rounds',total_actions,
    'challenger_final_hp',a_hp,
    'challenger_hp_max',a.hp_max,
    'opponent_final_hp',b_hp,
    'opponent_hp_max',b.hp_max,
    'log',log_data
  );
end;
$$;

create or replace function private.arena_grant_rank_rewards(
  p_season_id uuid,
  p_character_id uuid,
  p_mode text,
  p_old_mmr integer,
  p_old_matches integer,
  p_new_mmr integer,
  p_new_matches integer
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  old_slug text;
  new_slug text;
  old_order integer:=0;
  new_order integer:=0;
  r record;
  inserted_count integer;
  total_reward integer:=0;
begin
  if p_new_matches<5 then return 0; end if;

  old_slug:=private.arena_rank_for_mmr(p_old_mmr,p_old_matches);
  new_slug:=private.arena_rank_for_mmr(p_new_mmr,p_new_matches);

  select sort_order into new_order from public.arena_rank_definitions where slug=new_slug;
  if old_slug<>'calibration' then
    select sort_order into old_order from public.arena_rank_definitions where slug=old_slug;
  end if;

  if coalesce(new_order,0)<=coalesce(old_order,0) then return 0; end if;

  for r in
    select *
    from public.arena_rank_definitions
    where sort_order<=new_order
      and (
        (old_slug='calibration' and slug=new_slug)
        or (old_slug<>'calibration' and sort_order>old_order)
      )
    order by sort_order
  loop
    insert into public.arena_rank_achievements(
      season_id,character_id,mode,rank_slug,reward_gold
    )
    values(p_season_id,p_character_id,p_mode,r.slug,r.milestone_gold)
    on conflict do nothing;
    get diagnostics inserted_count = row_count;
    if inserted_count>0 then
      total_reward:=total_reward+r.milestone_gold;
    end if;
  end loop;

  if total_reward>0 then
    update public.character_progress
    set gold=gold+total_reward,updated_at=now()
    where character_id=p_character_id;
  end if;

  return total_reward;
end;
$$;

create or replace function public.get_arena_overview(p_character_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  caller_id uuid:=auth.uid();
  season public.arena_seasons;
  result jsonb;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters
    where id=p_character_id and owner_user_id=caller_id
  ) then raise exception 'CHARACTER_NOT_FOUND'; end if;

  select * into season
  from public.arena_seasons
  where starts_at<=now() and ends_at>now()
  order by starts_at desc
  limit 1;

  if season.id is null then
    select * into season from public.arena_seasons order by starts_at desc limit 1;
  end if;

  if season.id is null then
    return jsonb_build_object('season',null,'solo',null,'party',null,'history','[]'::jsonb,'leaderboard','[]'::jsonb);
  end if;

  insert into public.arena_character_ratings(season_id,character_id,mode)
  values(season.id,p_character_id,'solo'),(season.id,p_character_id,'party')
  on conflict do nothing;

  select jsonb_build_object(
    'season',jsonb_build_object(
      'id',season.id,'slug',season.slug,'name',season.name,
      'starts_at',season.starts_at,'ends_at',season.ends_at,
      'active',(season.starts_at<=now() and season.ends_at>now())
    ),
    'solo',(
      select jsonb_build_object(
        'mmr',r.mmr,'peak_mmr',r.peak_mmr,'matches',r.matches,'wins',r.wins,'losses',r.losses,'draws',r.draws,
        'rank_slug',private.arena_rank_for_mmr(r.mmr,r.matches),
        'rank_name',private.arena_rank_name(private.arena_rank_for_mmr(r.mmr,r.matches)),
        'placement_remaining',greatest(0,5-r.matches),
        'season_reward_gold',case
          when r.matches<5 then 0
          else coalesce((select season_gold from public.arena_rank_definitions where slug=private.arena_rank_for_mmr(r.peak_mmr,5)),0)
        end,
        'next_rank',(
          select jsonb_build_object('slug',d.slug,'name',d.name,'min_mmr',d.min_mmr)
          from public.arena_rank_definitions d
          where d.min_mmr>r.mmr
          order by d.min_mmr
          limit 1
        )
      )
      from public.arena_character_ratings r
      where r.season_id=season.id and r.character_id=p_character_id and r.mode='solo'
    ),
    'party',(
      select jsonb_build_object(
        'mmr',r.mmr,'peak_mmr',r.peak_mmr,'matches',r.matches,'wins',r.wins,'losses',r.losses,'draws',r.draws,
        'rank_slug',private.arena_rank_for_mmr(r.mmr,r.matches),
        'rank_name',private.arena_rank_name(private.arena_rank_for_mmr(r.mmr,r.matches)),
        'placement_remaining',greatest(0,5-r.matches),
        'enabled',false
      )
      from public.arena_character_ratings r
      where r.season_id=season.id and r.character_id=p_character_id and r.mode='party'
    ),
    'ranks',coalesce((
      select jsonb_agg(jsonb_build_object(
        'slug',d.slug,'name',d.name,'min_mmr',d.min_mmr,'milestone_gold',d.milestone_gold,'season_gold',d.season_gold
      ) order by d.sort_order)
      from public.arena_rank_definitions d
    ),'[]'::jsonb),
    'history',coalesce((
      select jsonb_agg(x.obj order by x.created_at desc)
      from (
        select m.created_at,jsonb_build_object(
          'id',m.id,'created_at',m.created_at,'winner_character_id',m.winner_character_id,
          'opponent_id',case when m.challenger_character_id=p_character_id then m.opponent_character_id else m.challenger_character_id end,
          'opponent_name',case when m.challenger_character_id=p_character_id then oc.name else cc.name end,
          'result',case
            when m.winner_character_id is null then 'draw'
            when m.winner_character_id=p_character_id then 'win'
            else 'loss'
          end,
          'mmr_before',case when m.challenger_character_id=p_character_id then m.challenger_mmr_before else m.opponent_mmr_before end,
          'mmr_after',case when m.challenger_character_id=p_character_id then m.challenger_mmr_after else m.opponent_mmr_after end,
          'rounds',m.rounds
        ) obj
        from public.arena_matches m
        left join public.characters cc on cc.id=m.challenger_character_id
        left join public.characters oc on oc.id=m.opponent_character_id
        where m.season_id=season.id and m.mode='solo'
          and p_character_id in (m.challenger_character_id,m.opponent_character_id)
        order by m.created_at desc
        limit 12
      ) x
    ),'[]'::jsonb),
    'leaderboard',coalesce((
      select jsonb_agg(x.obj order by x.mmr desc,x.wins desc,x.name)
      from (
        select r.mmr,r.wins,c.name,jsonb_build_object(
          'character_id',c.id,'name',c.name,'level',cp.level,
          'mmr',r.mmr,'matches',r.matches,'wins',r.wins,
          'rank_slug',private.arena_rank_for_mmr(r.mmr,r.matches),
          'rank_name',private.arena_rank_name(private.arena_rank_for_mmr(r.mmr,r.matches))
        ) obj
        from public.arena_character_ratings r
        join public.characters c on c.id=r.character_id
        join public.character_progress cp on cp.character_id=c.id
        where r.season_id=season.id and r.mode='solo'
        order by r.mmr desc,r.wins desc,c.name
        limit 20
      ) x
    ),'[]'::jsonb)
  ) into result;

  return result;
end;
$$;

create or replace function public.play_solo_arena_match(p_character_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  caller_id uuid:=auth.uid();
  season public.arena_seasons;
  self_rating public.arena_character_ratings;
  opp_rating public.arena_character_ratings;
  opponent_id uuid;
  simulation jsonb;
  winner_id uuid;
  self_score numeric;
  opp_score numeric;
  expected_self numeric;
  k_factor integer;
  self_new integer;
  opp_new integer;
  self_rank_before text;
  opp_rank_before text;
  self_rank_after text;
  opp_rank_after text;
  self_reward integer:=0;
  opp_reward integer:=0;
  match_id uuid;
  recent_cutoff timestamptz:=now()-interval '10 minutes';
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters
    where id=p_character_id and owner_user_id=caller_id
  ) then raise exception 'CHARACTER_NOT_FOUND'; end if;

  select * into season
  from public.arena_seasons
  where starts_at<=now() and ends_at>now()
  order by starts_at desc
  limit 1;
  if season.id is null then raise exception 'ARENA_SEASON_INACTIVE'; end if;

  insert into public.arena_character_ratings(season_id,character_id,mode)
  select season.id,c.id,m.mode
  from public.characters c
  join public.profiles p on p.user_id=c.owner_user_id and p.account_type='player'
  cross join (values('solo'::text),('party'::text)) m(mode)
  on conflict do nothing;

  select * into self_rating
  from public.arena_character_ratings
  where season_id=season.id and character_id=p_character_id and mode='solo';

  if self_rating.last_match_at is not null and self_rating.last_match_at>now()-interval '2 seconds' then
    raise exception 'ARENA_COOLDOWN';
  end if;

  select r.character_id into opponent_id
  from public.arena_character_ratings r
  join public.characters c on c.id=r.character_id
  join public.characters me on me.id=p_character_id
  join public.character_progress cp on cp.character_id=c.id
  join public.character_progress mycp on mycp.character_id=p_character_id
  where r.season_id=season.id
    and r.mode='solo'
    and r.character_id<>p_character_id
    and c.owner_user_id<>me.owner_user_id
  order by
    case when exists(
      select 1
      from public.arena_matches m
      where m.season_id=season.id and m.mode='solo'
        and m.created_at>recent_cutoff
        and (
          (m.challenger_character_id=p_character_id and m.opponent_character_id=r.character_id)
          or (m.opponent_character_id=p_character_id and m.challenger_character_id=r.character_id)
        )
    ) then 1 else 0 end,
    abs(r.mmr-self_rating.mmr),
    abs(cp.level-mycp.level),
    random()
  limit 1;

  if opponent_id is null then raise exception 'NO_ARENA_OPPONENT'; end if;

  perform pg_advisory_xact_lock(hashtextextended('arena:'||least(p_character_id::text,opponent_id::text),0));
  perform pg_advisory_xact_lock(hashtextextended('arena:'||greatest(p_character_id::text,opponent_id::text),0));

  select * into self_rating
  from public.arena_character_ratings
  where season_id=season.id and character_id=p_character_id and mode='solo'
  for update;

  select * into opp_rating
  from public.arena_character_ratings
  where season_id=season.id and character_id=opponent_id and mode='solo'
  for update;

  simulation:=private.arena_simulate_solo(p_character_id,opponent_id);
  winner_id:=nullif(simulation->>'winner_character_id','')::uuid;

  if winner_id is null then
    self_score:=0.5; opp_score:=0.5;
  elsif winner_id=p_character_id then
    self_score:=1; opp_score:=0;
  else
    self_score:=0; opp_score:=1;
  end if;

  expected_self:=1.0/(1.0+power(10.0,(opp_rating.mmr-self_rating.mmr)/400.0));
  k_factor:=case when self_rating.matches<10 or opp_rating.matches<10 then 48 else 32 end;

  self_new:=greatest(0,least(5000,round(self_rating.mmr+k_factor*(self_score-expected_self))::integer));
  opp_new:=greatest(0,least(5000,round(opp_rating.mmr+k_factor*(opp_score-(1.0-expected_self)))::integer));

  self_rank_before:=private.arena_rank_for_mmr(self_rating.mmr,self_rating.matches);
  opp_rank_before:=private.arena_rank_for_mmr(opp_rating.mmr,opp_rating.matches);
  self_rank_after:=private.arena_rank_for_mmr(self_new,self_rating.matches+1);
  opp_rank_after:=private.arena_rank_for_mmr(opp_new,opp_rating.matches+1);

  update public.arena_character_ratings
  set mmr=self_new,
      peak_mmr=greatest(peak_mmr,self_new),
      matches=matches+1,
      wins=wins+case when self_score=1 then 1 else 0 end,
      losses=losses+case when self_score=0 then 1 else 0 end,
      draws=draws+case when self_score=0.5 then 1 else 0 end,
      last_match_at=now(),
      updated_at=now()
  where season_id=season.id and character_id=p_character_id and mode='solo';

  update public.arena_character_ratings
  set mmr=opp_new,
      peak_mmr=greatest(peak_mmr,opp_new),
      matches=matches+1,
      wins=wins+case when opp_score=1 then 1 else 0 end,
      losses=losses+case when opp_score=0 then 1 else 0 end,
      draws=draws+case when opp_score=0.5 then 1 else 0 end,
      last_match_at=now(),
      updated_at=now()
  where season_id=season.id and character_id=opponent_id and mode='solo';

  self_reward:=private.arena_grant_rank_rewards(
    season.id,p_character_id,'solo',self_rating.mmr,self_rating.matches,self_new,self_rating.matches+1
  );
  opp_reward:=private.arena_grant_rank_rewards(
    season.id,opponent_id,'solo',opp_rating.mmr,opp_rating.matches,opp_new,opp_rating.matches+1
  );

  insert into public.arena_matches(
    season_id,mode,challenger_character_id,opponent_character_id,winner_character_id,
    challenger_mmr_before,challenger_mmr_after,opponent_mmr_before,opponent_mmr_after,
    challenger_rank_before,challenger_rank_after,opponent_rank_before,opponent_rank_after,
    rounds,challenger_final_hp,opponent_final_hp,combat_log
  )
  values(
    season.id,'solo',p_character_id,opponent_id,winner_id,
    self_rating.mmr,self_new,opp_rating.mmr,opp_new,
    self_rank_before,self_rank_after,opp_rank_before,opp_rank_after,
    coalesce((simulation->>'rounds')::integer,0),
    coalesce((simulation->>'challenger_final_hp')::integer,0),
    coalesce((simulation->>'opponent_final_hp')::integer,0),
    coalesce(simulation->'log','[]'::jsonb)
  )
  returning id into match_id;

  return jsonb_build_object(
    'match_id',match_id,
    'season_id',season.id,
    'winner_character_id',winner_id,
    'result',case when winner_id is null then 'draw' when winner_id=p_character_id then 'win' else 'loss' end,
    'opponent',(
      select jsonb_build_object('character_id',c.id,'name',c.name,'level',cp.level,'avatar_url',c.avatar_url)
      from public.characters c join public.character_progress cp on cp.character_id=c.id
      where c.id=opponent_id
    ),
    'mmr_before',self_rating.mmr,
    'mmr_after',self_new,
    'mmr_delta',self_new-self_rating.mmr,
    'rank_before',self_rank_before,
    'rank_after',self_rank_after,
    'rank_name',private.arena_rank_name(self_rank_after),
    'rank_reward_gold',self_reward,
    'rounds',coalesce((simulation->>'rounds')::integer,0),
    'challenger_final_hp',coalesce((simulation->>'challenger_final_hp')::integer,0),
    'challenger_hp_max',coalesce((simulation->>'challenger_hp_max')::integer,1),
    'opponent_final_hp',coalesce((simulation->>'opponent_final_hp')::integer,0),
    'opponent_hp_max',coalesce((simulation->>'opponent_hp_max')::integer,1),
    'log',coalesce(simulation->'log','[]'::jsonb)
  );
end;
$$;

create or replace function public.claim_arena_season_reward(
  p_character_id uuid,
  p_season_id uuid,
  p_mode text default 'solo'
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  caller_id uuid:=auth.uid();
  season public.arena_seasons;
  rating public.arena_character_ratings;
  rank_slug text;
  reward integer;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_mode not in ('solo','party') then raise exception 'INVALID_ARENA_MODE'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id)
    then raise exception 'CHARACTER_NOT_FOUND'; end if;

  select * into season from public.arena_seasons where id=p_season_id;
  if season.id is null then raise exception 'ARENA_SEASON_NOT_FOUND'; end if;
  if season.ends_at>now() then raise exception 'ARENA_SEASON_NOT_FINISHED'; end if;

  select * into rating
  from public.arena_character_ratings
  where season_id=p_season_id and character_id=p_character_id and mode=p_mode
  for update;

  if rating.character_id is null or rating.matches<5 then raise exception 'ARENA_NOT_CALIBRATED'; end if;
  if exists(
    select 1 from public.arena_season_reward_claims
    where season_id=p_season_id and character_id=p_character_id and mode=p_mode
  ) then raise exception 'ARENA_SEASON_REWARD_ALREADY_CLAIMED'; end if;

  rank_slug:=private.arena_rank_for_mmr(rating.peak_mmr,5);
  select season_gold into reward from public.arena_rank_definitions where slug=rank_slug;
  reward:=coalesce(reward,0);

  insert into public.arena_season_reward_claims(season_id,character_id,mode,rank_slug,reward_gold)
  values(p_season_id,p_character_id,p_mode,rank_slug,reward);

  if reward>0 then
    update public.character_progress set gold=gold+reward,updated_at=now() where character_id=p_character_id;
  end if;

  return jsonb_build_object(
    'rank_slug',rank_slug,'rank_name',private.arena_rank_name(rank_slug),'reward_gold',reward
  );
end;
$$;

revoke all on function public.get_arena_overview(uuid) from public, anon;
revoke all on function public.play_solo_arena_match(uuid) from public, anon;
revoke all on function public.claim_arena_season_reward(uuid,uuid,text) from public, anon;
grant execute on function public.get_arena_overview(uuid) to authenticated;
grant execute on function public.play_solo_arena_match(uuid) to authenticated;
grant execute on function public.claim_arena_season_reward(uuid,uuid,text) to authenticated;

revoke all on function private.arena_rank_for_mmr(integer,integer) from public, anon, authenticated;
revoke all on function private.arena_rank_name(text) from public, anon, authenticated;
revoke all on function private.arena_choose_action(uuid,jsonb,integer,integer,integer,integer,integer,boolean,jsonb,integer,integer) from public, anon, authenticated;
revoke all on function private.arena_simulate_solo(uuid,uuid) from public, anon, authenticated;
revoke all on function private.arena_grant_rank_rewards(uuid,uuid,text,integer,integer,integer,integer) from public, anon, authenticated;

insert into public.arena_character_ratings(season_id,character_id,mode)
select s.id,c.id,m.mode
from public.arena_seasons s
join public.characters c on true
join public.profiles p on p.user_id=c.owner_user_id and p.account_type='player'
cross join (values('solo'::text),('party'::text)) m(mode)
where s.slug='season-1-awakening'
on conflict do nothing;
