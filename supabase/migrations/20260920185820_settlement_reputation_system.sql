-- Settlement reputation: long-form city progression tied to settlement quests.
alter table public.settlement_quest_definitions
  add column if not exists reward_reputation smallint not null default 5
    check (reward_reputation between 0 and 15);

alter table public.character_settlement_quests
  add column if not exists reputation_granted smallint not null default 0
    check (reputation_granted between 0 and 15);

create table if not exists public.settlement_reputation_configs (
  sector_id smallint primary key references public.map_sectors(id) on delete cascade,
  daily_cap smallint not null default 15 check (daily_cap between 1 and 100),
  level10_reward_item_id uuid references public.item_definitions(id) on delete set null,
  updated_at timestamptz not null default now()
);

create table if not exists public.character_settlement_reputations (
  character_id uuid not null references public.characters(id) on delete cascade,
  sector_id smallint not null references public.map_sectors(id) on delete cascade,
  reputation_points integer not null default 0 check (reputation_points >= 0),
  level10_reward_claimed boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(character_id, sector_id)
);

create table if not exists public.settlement_reputation_events (
  id bigint generated always as identity primary key,
  character_id uuid not null references public.characters(id) on delete cascade,
  sector_id smallint not null references public.map_sectors(id) on delete cascade,
  quest_assignment_id uuid references public.character_settlement_quests(id) on delete set null,
  source_type text not null default 'settlement_quest',
  points_requested smallint not null check (points_requested between 0 and 100),
  points_granted smallint not null check (points_granted between 0 and 100),
  created_at timestamptz not null default now()
);

create unique index if not exists settlement_reputation_events_assignment_unique
  on public.settlement_reputation_events(quest_assignment_id)
  where quest_assignment_id is not null;
create index if not exists settlement_reputation_events_daily_idx
  on public.settlement_reputation_events(character_id, sector_id, created_at desc);
create index if not exists character_settlement_reputations_sector_idx
  on public.character_settlement_reputations(sector_id, reputation_points desc);

alter table public.settlement_reputation_configs enable row level security;
alter table public.character_settlement_reputations enable row level security;
alter table public.settlement_reputation_events enable row level security;
revoke all on table public.settlement_reputation_configs from anon, authenticated;
revoke all on table public.character_settlement_reputations from anon, authenticated;
revoke all on table public.settlement_reputation_events from anon, authenticated;

create or replace function private.settlement_reputation_threshold(p_level integer)
returns integer language sql immutable strict set search_path='' as $$
  select case p_level
    when 1 then 0 when 2 then 100 when 3 then 250 when 4 then 450
    when 5 then 700 when 6 then 1000 when 7 then 1350 when 8 then 1750
    when 9 then 2200 else 2700 end;
$$;

create or replace function private.settlement_reputation_level(p_points integer)
returns smallint language sql immutable strict set search_path='' as $$
  select (case
    when p_points>=2700 then 10 when p_points>=2200 then 9 when p_points>=1750 then 8
    when p_points>=1350 then 7 when p_points>=1000 then 6 when p_points>=700 then 5
    when p_points>=450 then 4 when p_points>=250 then 3 when p_points>=100 then 2 else 1 end)::smallint;
$$;

create or replace function private.settlement_reputation_perks(p_level integer)
returns table(
  shop_discount_percent smallint,
  quest_gold_bonus_percent smallint,
  quest_experience_bonus_percent smallint,
  perk_text text
)
language sql immutable strict set search_path='' as $$
  select
    (case when p_level>=10 then 10 when p_level>=9 then 8 when p_level>=7 then 6 when p_level>=4 then 4 when p_level>=2 then 2 else 0 end)::smallint,
    (case when p_level>=10 then 10 when p_level>=9 then 9 when p_level>=6 then 6 when p_level>=3 then 3 else 0 end)::smallint,
    (case when p_level>=10 then 10 when p_level>=8 then 6 when p_level>=5 then 3 else 0 end)::smallint,
    case p_level
      when 1 then 'Ты здесь пока просто путешественник.'
      when 2 then 'Скидка 2% в магазине этого поселения.'
      when 3 then '+3% золота за поручения этого поселения.'
      when 4 then 'Скидка в магазине увеличена до 4%.'
      when 5 then '+3% опыта за поручения этого поселения.'
      when 6 then 'Бонус золота за поручения увеличен до 6%.'
      when 7 then 'Скидка в магазине увеличена до 6%.'
      when 8 then 'Бонус опыта за поручения увеличен до 6%.'
      when 9 then 'Скидка 8% и +9% золота за поручения.'
      else 'Максимальная репутация: скидка 10%, +10% золота и опыта, уникальная награда.'
    end;
$$;

revoke all on function private.settlement_reputation_threshold(integer) from public, anon, authenticated;
revoke all on function private.settlement_reputation_level(integer) from public, anon, authenticated;
revoke all on function private.settlement_reputation_perks(integer) from public, anon, authenticated;

create or replace function private.grant_settlement_reputation(
  p_character_id uuid,p_sector_id smallint,p_points smallint,p_assignment_id uuid
)
returns smallint language plpgsql security invoker
set search_path=pg_catalog,public,private as $$
declare
  cap smallint:=15;
  earned_today integer:=0;
  granted smallint:=0;
begin
  insert into public.character_settlement_reputations(character_id,sector_id)
  values(p_character_id,p_sector_id)
  on conflict(character_id,sector_id) do nothing;

  perform 1 from public.character_settlement_reputations r
  where r.character_id=p_character_id and r.sector_id=p_sector_id for update;

  select coalesce(c.daily_cap,15) into cap
  from public.settlement_reputation_configs c where c.sector_id=p_sector_id;
  cap:=coalesce(cap,15);

  select coalesce(sum(e.points_granted),0)::integer into earned_today
  from public.settlement_reputation_events e
  where e.character_id=p_character_id and e.sector_id=p_sector_id
    and e.created_at>=date_trunc('day',now());

  granted:=least(greatest(p_points,0),greatest(cap-earned_today,0))::smallint;

  insert into public.settlement_reputation_events(
    character_id,sector_id,quest_assignment_id,source_type,points_requested,points_granted
  )
  values(p_character_id,p_sector_id,p_assignment_id,'settlement_quest',greatest(p_points,0),granted)
  on conflict(quest_assignment_id) where quest_assignment_id is not null do nothing;

  if not found then return 0; end if;

  if granted>0 then
    update public.character_settlement_reputations
    set reputation_points=reputation_points+granted,updated_at=now()
    where character_id=p_character_id and sector_id=p_sector_id;
  end if;
  return granted;
end;
$$;
revoke all on function private.grant_settlement_reputation(uuid,smallint,smallint,uuid) from public, anon, authenticated;

create or replace function private.grant_level10_reputation_reward(
  p_character_id uuid,p_sector_id smallint
)
returns text language plpgsql security invoker
set search_path=pg_catalog,public,private as $$
declare
  rep public.character_settlement_reputations;
  reward public.item_definitions;
begin
  select * into rep from public.character_settlement_reputations
  where character_id=p_character_id and sector_id=p_sector_id for update;

  if rep.character_id is null
     or private.settlement_reputation_level(rep.reputation_points)<10
     or rep.level10_reward_claimed
  then return null; end if;

  select i.* into reward
  from public.settlement_reputation_configs c
  join public.item_definitions i on i.id=c.level10_reward_item_id
  where c.sector_id=p_sector_id;

  if reward.id is null then return null; end if;

  if reward.stackable then
    update public.character_items set quantity=quantity+1
    where id=(select ci.id from public.character_items ci
      where ci.character_id=p_character_id and ci.item_definition_id=reward.id and ci.custom_name is null
      order by ci.acquired_at limit 1);
    if not found then
      insert into public.character_items(character_id,item_definition_id,quantity)
      values(p_character_id,reward.id,1);
    end if;
  else
    insert into public.character_items(character_id,item_definition_id,quantity)
    values(p_character_id,reward.id,1);
  end if;

  update public.character_settlement_reputations
  set level10_reward_claimed=true,updated_at=now()
  where character_id=p_character_id and sector_id=p_sector_id;

  return reward.name;
end;
$$;
revoke all on function private.grant_level10_reputation_reward(uuid,smallint) from public, anon, authenticated;

insert into public.settlement_reputation_configs(sector_id)
select sector_id from public.sector_details where content_type='settlement'
on conflict(sector_id) do nothing;

insert into public.item_definitions(
  slug,name,description,category,rarity,equip_group,stackable,max_stack,
  stat_modifiers,effects,base_value,required_level,shop_tier,shop_price,shop_enabled,
  unique_property_name,unique_property_description
)
values
('varden_reputation_seal','Гербовый перстень Вардена',
 'Уникальный знак доверия Вардена. Его получают только те, кого город считает своим.',
 'accessory','unique','accessory',false,1,'{"vitality":3,"luck":3}'::jsonb,'[]'::jsonb,0,12,0,0,false,
 'Гражданин Вардена','Награда за максимальную репутацию Вардена.'),
('liaven_reputation_seal','Печать Лиавена',
 'Тонкая серебряная печать, которую в Лиавене вручают лишь самым надёжным союзникам города.',
 'accessory','unique','accessory',false,1,'{"agility":4,"luck":2}'::jsonb,'[]'::jsonb,0,12,0,0,false,
 'Доверие Лиавена','Награда за максимальную репутацию Лиавена.'),
('kharum_reputation_seal','Сердце Кхарума',
 'Тяжёлый каменный талисман из горной кузни Кхарума.',
 'accessory','unique','accessory',false,1,'{"strength":4,"vitality":3}'::jsonb,'[]'::jsonb,0,12,0,0,false,
 'Сердце гор','Награда за максимальную репутацию Кхарума.'),
('sahret_reputation_seal','Око Сахрета',
 'Золотой амулет пустынного города, отмечающий высшую степень доверия.',
 'accessory','unique','accessory',false,1,'{"intellect":4,"luck":3}'::jsonb,'[]'::jsonb,0,12,0,0,false,
 'Око пустыни','Награда за максимальную репутацию Сахрета.')
on conflict(slug) do update set
  name=excluded.name,description=excluded.description,stat_modifiers=excluded.stat_modifiers,
  required_level=excluded.required_level,unique_property_name=excluded.unique_property_name,
  unique_property_description=excluded.unique_property_description,updated_at=now();

update public.settlement_reputation_configs c
set level10_reward_item_id=i.id,updated_at=now()
from public.item_definitions i
where (c.sector_id=131 and i.slug='varden_reputation_seal')
   or (c.sector_id=170 and i.slug='liaven_reputation_seal')
   or (c.sector_id=177 and i.slug='kharum_reputation_seal')
   or (c.sector_id=230 and i.slug='sahret_reputation_seal');

create or replace function public.get_settlement_reputation(p_character_id uuid,p_sector_id smallint)
returns table(
  sector_id smallint,settlement_name text,reputation_points integer,reputation_level smallint,
  current_level_points integer,next_level_points integer,daily_earned integer,daily_cap smallint,
  daily_remaining integer,shop_discount_percent smallint,quest_gold_bonus_percent smallint,
  quest_experience_bonus_percent smallint,current_perk_text text,next_perk_text text,
  level10_reward_item_id uuid,level10_reward_item_name text,level10_reward_item_description text,
  level10_reward_claimed boolean
)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare caller uuid:=auth.uid(); pts integer:=0; lvl smallint:=1; cap smallint:=15; earned integer:=0;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters c where c.id=p_character_id and c.owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;
  if not exists(select 1 from public.character_sector_discoveries d where d.character_id=p_character_id and d.sector_id=p_sector_id)
    then raise exception 'SETTLEMENT_NOT_DISCOVERED'; end if;
  if not exists(select 1 from public.sector_details sd where sd.sector_id=p_sector_id and sd.content_type='settlement')
    then raise exception 'SECTOR_IS_NOT_SETTLEMENT'; end if;

  select coalesce(r.reputation_points,0) into pts
  from public.character_settlement_reputations r
  where r.character_id=p_character_id and r.sector_id=p_sector_id;
  pts:=coalesce(pts,0);
  lvl:=private.settlement_reputation_level(pts);

  select coalesce(c.daily_cap,15) into cap
  from public.settlement_reputation_configs c where c.sector_id=p_sector_id;
  cap:=coalesce(cap,15);

  select coalesce(sum(e.points_granted),0)::integer into earned
  from public.settlement_reputation_events e
  where e.character_id=p_character_id and e.sector_id=p_sector_id
    and e.created_at>=date_trunc('day',now());

  return query
  select p_sector_id,coalesce(sd.title,ms.location_name,'Поселение #'||p_sector_id::text),
    pts,lvl,private.settlement_reputation_threshold(lvl),
    case when lvl>=10 then 2700 else private.settlement_reputation_threshold(lvl+1) end,
    earned,cap,greatest(cap-earned,0),
    perks.shop_discount_percent,perks.quest_gold_bonus_percent,perks.quest_experience_bonus_percent,
    perks.perk_text,next_perks.perk_text,cfg.level10_reward_item_id,reward.name,reward.description,
    coalesce(rep.level10_reward_claimed,false)
  from public.sector_details sd
  join public.map_sectors ms on ms.id=sd.sector_id
  left join public.settlement_reputation_configs cfg on cfg.sector_id=sd.sector_id
  left join public.item_definitions reward on reward.id=cfg.level10_reward_item_id
  left join public.character_settlement_reputations rep
    on rep.character_id=p_character_id and rep.sector_id=sd.sector_id
  cross join lateral private.settlement_reputation_perks(lvl) perks
  cross join lateral private.settlement_reputation_perks(least(lvl+1,10)) next_perks
  where sd.sector_id=p_sector_id;
end;
$$;
revoke all on function public.get_settlement_reputation(uuid,smallint) from public, anon;
grant execute on function public.get_settlement_reputation(uuid,smallint) to authenticated;

create or replace function public.get_settlement_quests_v2(p_character_id uuid,p_sector_id smallint)
returns table(
  quest_id uuid,sector_id smallint,settlement_name text,title text,description text,theme text,
  objective_type text,objective_target integer,target_item_definition_id uuid,target_item_name text,
  reward_gold bigint,reward_experience bigint,reward_reputation smallint,min_level integer,
  repeatable boolean,cooldown_hours integer,enabled boolean,assignment_id uuid,assignment_status text,
  accepted_at timestamptz,progress integer,can_complete boolean,can_accept boolean,
  cooldown_remaining_seconds bigint,active_quest_count integer
)
language sql security definer set search_path='' as $$
  select q.quest_id,q.sector_id,q.settlement_name,q.title,q.description,q.theme,
    q.objective_type,q.objective_target,q.target_item_definition_id,q.target_item_name,
    q.reward_gold,q.reward_experience,d.reward_reputation,q.min_level,q.repeatable,q.cooldown_hours,
    q.enabled,q.assignment_id,q.assignment_status,q.accepted_at,q.progress,q.can_complete,q.can_accept,
    q.cooldown_remaining_seconds,q.active_quest_count
  from public.get_settlement_quests(p_character_id,p_sector_id) q
  join public.settlement_quest_definitions d on d.id=q.quest_id;
$$;
revoke all on function public.get_settlement_quests_v2(uuid,smallint) from public, anon;
grant execute on function public.get_settlement_quests_v2(uuid,smallint) to authenticated;

create or replace function public.gm_list_settlement_quests_v2()
returns table(
  quest_id uuid,sector_id smallint,settlement_name text,title text,description text,theme text,
  objective_type text,objective_target integer,target_item_definition_id uuid,target_item_name text,
  reward_gold bigint,reward_experience bigint,reward_reputation smallint,min_level integer,
  repeatable boolean,cooldown_hours integer,enabled boolean,sort_order integer,
  active_assignments bigint,total_completions bigint
)
language sql security definer set search_path='' as $$
  select q.quest_id,q.sector_id,q.settlement_name,q.title,q.description,q.theme,
    q.objective_type,q.objective_target,q.target_item_definition_id,q.target_item_name,
    q.reward_gold,q.reward_experience,d.reward_reputation,q.min_level,q.repeatable,q.cooldown_hours,
    q.enabled,q.sort_order,q.active_assignments,q.total_completions
  from public.gm_list_settlement_quests() q
  join public.settlement_quest_definitions d on d.id=q.quest_id;
$$;
revoke all on function public.gm_list_settlement_quests_v2() from public, anon;
grant execute on function public.gm_list_settlement_quests_v2() to authenticated;

create or replace function public.gm_save_settlement_quest_v2(
  p_id uuid,p_sector_id smallint,p_title text,p_description text,p_theme text,p_objective_type text,
  p_objective_target integer,p_target_item_definition_id uuid,p_reward_gold bigint,
  p_reward_experience bigint,p_reward_reputation smallint,p_min_level integer,p_repeatable boolean,
  p_cooldown_hours integer,p_enabled boolean,p_sort_order integer
)
returns uuid language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare saved_id uuid;
begin
  if not private.is_gm(auth.uid()) then raise exception 'GM_REQUIRED'; end if;
  if p_reward_reputation<0 or p_reward_reputation>15 then raise exception 'INVALID_REPUTATION_REWARD'; end if;

  saved_id:=public.gm_save_settlement_quest(
    p_id,p_sector_id,p_title,p_description,p_theme,p_objective_type,p_objective_target,
    p_target_item_definition_id,p_reward_gold,p_reward_experience,p_min_level,
    p_repeatable,p_cooldown_hours,p_enabled,p_sort_order
  );

  update public.settlement_quest_definitions set reward_reputation=p_reward_reputation where id=saved_id;
  return saved_id;
end;
$$;
revoke all on function public.gm_save_settlement_quest_v2(uuid,smallint,text,text,text,text,integer,uuid,bigint,bigint,smallint,integer,boolean,integer,boolean,integer) from public, anon;
grant execute on function public.gm_save_settlement_quest_v2(uuid,smallint,text,text,text,text,integer,uuid,bigint,bigint,smallint,integer,boolean,integer,boolean,integer) to authenticated;

create or replace function public.gm_list_settlement_reputation_configs()
returns table(
  sector_id smallint,settlement_name text,daily_cap smallint,
  level10_reward_item_id uuid,level10_reward_item_name text
)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
begin
  if not private.is_gm(auth.uid()) then raise exception 'GM_REQUIRED'; end if;
  return query
  select sd.sector_id,coalesce(sd.title,ms.location_name,'Поселение #'||sd.sector_id::text),
    coalesce(c.daily_cap,15)::smallint,c.level10_reward_item_id,i.name
  from public.sector_details sd
  join public.map_sectors ms on ms.id=sd.sector_id
  left join public.settlement_reputation_configs c on c.sector_id=sd.sector_id
  left join public.item_definitions i on i.id=c.level10_reward_item_id
  where sd.content_type='settlement'
  order by sd.sector_id;
end;
$$;
revoke all on function public.gm_list_settlement_reputation_configs() from public, anon;
grant execute on function public.gm_list_settlement_reputation_configs() to authenticated;

create or replace function public.gm_save_settlement_reputation_config(
  p_sector_id smallint,p_daily_cap smallint,p_level10_reward_item_id uuid
)
returns void language plpgsql security definer set search_path=pg_catalog,public,private as $$
begin
  if not private.is_gm(auth.uid()) then raise exception 'GM_REQUIRED'; end if;
  if not exists(select 1 from public.sector_details where sector_id=p_sector_id and content_type='settlement')
    then raise exception 'SECTOR_IS_NOT_SETTLEMENT'; end if;
  if p_daily_cap<1 or p_daily_cap>100 then raise exception 'INVALID_DAILY_CAP'; end if;
  if p_level10_reward_item_id is not null and not exists(select 1 from public.item_definitions where id=p_level10_reward_item_id)
    then raise exception 'ITEM_NOT_FOUND'; end if;

  insert into public.settlement_reputation_configs(sector_id,daily_cap,level10_reward_item_id)
  values(p_sector_id,p_daily_cap,p_level10_reward_item_id)
  on conflict(sector_id) do update set
    daily_cap=excluded.daily_cap,level10_reward_item_id=excluded.level10_reward_item_id,updated_at=now();

  insert into public.gm_audit_log(actor_user_id,action,target_type,target_id,details)
  values(auth.uid(),'settlement_reputation.config_update','map_sector',p_sector_id::text,
    jsonb_build_object('daily_cap',p_daily_cap,'level10_reward_item_id',p_level10_reward_item_id));
end;
$$;
revoke all on function public.gm_save_settlement_reputation_config(smallint,smallint,uuid) from public, anon;
grant execute on function public.gm_save_settlement_reputation_config(smallint,smallint,uuid) to authenticated;

create or replace function public.complete_settlement_quest(p_character_id uuid,p_assignment_id uuid)
returns table(reward_gold bigint,reward_experience bigint,new_level integer,remaining_experience bigint)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare
  caller uuid:=auth.uid();
  a public.character_settlement_quests;
  q public.settlement_quest_definitions;
  current_progress integer; remaining integer; stack_row record; take_amount integer;
  rep_points integer:=0; rep_level smallint:=1; gold_bonus smallint:=0; experience_bonus smallint:=0;
  actual_gold bigint:=0; actual_experience bigint:=0; rep_granted smallint:=0; reward_item_name text;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters c where c.id=p_character_id and c.owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select * into a from public.character_settlement_quests
  where id=p_assignment_id and character_id=p_character_id and status='active' for update;
  if a.id is null then raise exception 'ACTIVE_QUEST_NOT_FOUND'; end if;

  select * into q from public.settlement_quest_definitions where id=a.quest_definition_id;
  if q.id is null then raise exception 'QUEST_NOT_FOUND'; end if;

  current_progress:=private.settlement_quest_progress(a.id);
  if current_progress<q.objective_target then raise exception 'QUEST_NOT_COMPLETE'; end if;

  if q.objective_type='deliver_item' then
    remaining:=q.objective_target;
    for stack_row in
      select ci.id,ci.quantity from public.character_items ci
      where ci.character_id=p_character_id and ci.item_definition_id=q.target_item_definition_id
      order by ci.acquired_at,ci.id for update
    loop
      exit when remaining<=0;
      take_amount:=least(stack_row.quantity,remaining);
      if take_amount>=stack_row.quantity then
        delete from public.character_items where id=stack_row.id;
      else
        update public.character_items set quantity=quantity-take_amount where id=stack_row.id;
      end if;
      remaining:=remaining-take_amount;
    end loop;
    if remaining>0 then raise exception 'QUEST_ITEMS_MISSING'; end if;
  end if;

  select coalesce(r.reputation_points,0) into rep_points
  from public.character_settlement_reputations r
  where r.character_id=p_character_id and r.sector_id=q.sector_id;
  rep_points:=coalesce(rep_points,0);
  rep_level:=private.settlement_reputation_level(rep_points);

  select p.quest_gold_bonus_percent,p.quest_experience_bonus_percent
  into gold_bonus,experience_bonus
  from private.settlement_reputation_perks(rep_level) p;

  actual_gold:=floor(q.reward_gold*(100+coalesce(gold_bonus,0))/100.0)::bigint;
  actual_experience:=floor(q.reward_experience*(100+coalesce(experience_bonus,0))/100.0)::bigint;

  update public.character_progress
  set gold=gold+actual_gold,experience=experience+actual_experience
  where character_id=p_character_id;

  rep_granted:=private.grant_settlement_reputation(p_character_id,q.sector_id,q.reward_reputation,a.id);

  update public.character_settlement_quests
  set status='completed',completed_at=now(),reward_gold_granted=actual_gold,
      reward_experience_granted=actual_experience,reputation_granted=rep_granted
  where id=a.id;

  reward_item_name:=private.grant_level10_reputation_reward(p_character_id,q.sector_id);

  return query
  select actual_gold,actual_experience,cp.level,cp.experience
  from public.character_progress cp where cp.character_id=p_character_id;
end;
$$;
revoke all on function public.complete_settlement_quest(uuid,uuid) from public, anon;
grant execute on function public.complete_settlement_quest(uuid,uuid) to authenticated;

create or replace function public.get_settlement_shop(p_character_id uuid,p_sector_id smallint)
returns table(
  settlement_name text,settlement_level smallint,item_id uuid,slug text,item_name text,description text,
  category text,rarity text,equip_group text,stat_modifiers jsonb,damage_type text,damage_resistances jsonb,
  scroll_mode text,scroll_spell_id uuid,scroll_spell_name text,heal_amount integer,price bigint,
  required_level integer,shop_tier smallint,can_afford boolean,level_unlocked boolean
)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare
  caller uuid:=auth.uid(); current_level integer; current_gold bigint;
  settlement public.sector_details; rep_points integer:=0; rep_level smallint:=1; discount smallint:=0;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters c where c.id=p_character_id and c.owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;
  if not exists(select 1 from public.character_sector_discoveries d where d.character_id=p_character_id and d.sector_id=p_sector_id)
    then raise exception 'SETTLEMENT_NOT_DISCOVERED'; end if;

  select * into settlement from public.sector_details where sector_id=p_sector_id;
  if settlement.sector_id is null or settlement.content_type<>'settlement'
    then raise exception 'SECTOR_IS_NOT_SETTLEMENT'; end if;

  perform private.apply_passive_hp_regen(p_character_id);
  perform private.apply_passive_mana_regen(p_character_id);

  select cp.level,cp.gold into current_level,current_gold
  from public.character_progress cp where cp.character_id=p_character_id;

  select coalesce(r.reputation_points,0) into rep_points
  from public.character_settlement_reputations r
  where r.character_id=p_character_id and r.sector_id=p_sector_id;
  rep_points:=coalesce(rep_points,0);
  rep_level:=private.settlement_reputation_level(rep_points);
  select p.shop_discount_percent into discount from private.settlement_reputation_perks(rep_level) p;

  return query
  select coalesce(settlement.title,'Поселение'),settlement.settlement_level,
    d.id,d.slug,d.name,d.description,d.category::text,d.rarity::text,d.equip_group::text,
    d.stat_modifiers,d.damage_type,d.damage_resistances,d.scroll_mode,d.scroll_spell_id,s.name,
    coalesce((select (e->>'amount')::integer from jsonb_array_elements(d.effects)e where e->>'type'='heal_hp' limit 1),0),
    greatest(1,floor(d.shop_price*(100-coalesce(discount,0))/100.0)::bigint),
    d.required_level,d.shop_tier,
    current_gold>=greatest(1,floor(d.shop_price*(100-coalesce(discount,0))/100.0)::bigint),
    current_level>=d.required_level
  from public.item_definitions d
  left join public.spell_definitions s on s.id=d.scroll_spell_id
  where d.shop_enabled=true and d.shop_tier<=settlement.settlement_level
    and (d.shop_sector_id is null or d.shop_sector_id=p_sector_id)
  order by case d.category::text when 'consumable' then 0 when 'weapon' then 1 when 'armor' then 2 when 'accessory' then 3 else 4 end,
    d.shop_tier,d.shop_price,d.name;
end;
$$;

create or replace function public.buy_settlement_shop_item(
  p_character_id uuid,p_sector_id smallint,p_item_definition_id uuid,p_quantity integer default 1
)
returns void language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare
  caller uuid:=auth.uid(); cp public.character_progress; settlement public.sector_details;
  item public.item_definitions; total_price bigint; rep_points integer:=0; rep_level smallint:=1;
  discount smallint:=0; unit_price bigint:=0;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_quantity<1 or p_quantity>99 then raise exception 'INVALID_QUANTITY'; end if;
  if not exists(select 1 from public.characters c where c.id=p_character_id and c.owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  if exists(select 1 from public.dungeon_runs r where r.character_id=p_character_id and r.status='active')
    or exists(select 1 from public.sector_expeditions e where e.character_id=p_character_id and e.status in ('active','awaiting_event'))
    or exists(select 1 from public.sector_site_actions a where a.character_id=p_character_id and a.status='active')
  then raise exception 'CHARACTER_BUSY'; end if;

  if not exists(select 1 from public.character_sector_discoveries d where d.character_id=p_character_id and d.sector_id=p_sector_id)
    then raise exception 'SETTLEMENT_NOT_DISCOVERED'; end if;

  select * into settlement from public.sector_details where sector_id=p_sector_id;
  if settlement.sector_id is null or settlement.content_type<>'settlement'
    then raise exception 'SECTOR_IS_NOT_SETTLEMENT'; end if;

  select * into item from public.item_definitions d where d.id=p_item_definition_id and d.shop_enabled=true;
  if item.id is null then raise exception 'ITEM_NOT_FOR_SALE'; end if;
  if item.shop_sector_id is not null and item.shop_sector_id<>p_sector_id then raise exception 'ITEM_NOT_SOLD_HERE'; end if;
  if item.shop_tier>settlement.settlement_level then raise exception 'ITEM_NOT_SOLD_HERE'; end if;
  if not item.stackable and p_quantity<>1 then raise exception 'NONSTACKABLE_QUANTITY_MUST_BE_ONE'; end if;

  select * into cp from public.character_progress where character_id=p_character_id for update;
  if cp.level<item.required_level then raise exception 'LEVEL_TOO_LOW'; end if;

  select coalesce(r.reputation_points,0) into rep_points
  from public.character_settlement_reputations r
  where r.character_id=p_character_id and r.sector_id=p_sector_id;
  rep_points:=coalesce(rep_points,0);
  rep_level:=private.settlement_reputation_level(rep_points);
  select p.shop_discount_percent into discount from private.settlement_reputation_perks(rep_level) p;

  unit_price:=greatest(1,floor(item.shop_price*(100-coalesce(discount,0))/100.0)::bigint);
  total_price:=unit_price*p_quantity;
  if cp.gold<total_price then raise exception 'NOT_ENOUGH_GOLD'; end if;

  update public.character_progress set gold=gold-total_price,updated_at=now()
  where character_id=p_character_id;

  if item.stackable then
    update public.character_items set quantity=quantity+p_quantity
    where id=(select ci.id from public.character_items ci
      where ci.character_id=p_character_id and ci.item_definition_id=item.id and ci.custom_name is null
      order by ci.acquired_at limit 1);
    if not found then
      insert into public.character_items(character_id,item_definition_id,quantity)
      values(p_character_id,item.id,p_quantity);
    end if;
  else
    insert into public.character_items(character_id,item_definition_id,quantity)
    values(p_character_id,item.id,1);
  end if;
end;
$$;
revoke all on function public.buy_settlement_shop_item(uuid,smallint,uuid,integer) from public, anon;
grant execute on function public.buy_settlement_shop_item(uuid,smallint,uuid,integer) to authenticated;
