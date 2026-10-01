
create table if not exists public.character_camps (
  character_id uuid primary key references public.characters(id) on delete cascade,
  sector_id smallint not null references public.map_sectors(id) on delete cascade,
  specialization text not null check (specialization in ('scout','hunter','war','trader')),
  placed_at timestamptz not null default now(),
  expires_at timestamptz not null,
  updated_at timestamptz not null default now(),
  check (expires_at > placed_at)
);

alter table public.character_camps enable row level security;
revoke all on table public.character_camps from public, anon, authenticated;
grant all on table public.character_camps to service_role;

create table if not exists public.character_exploration_milestones (
  character_id uuid not null references public.characters(id) on delete cascade,
  milestone smallint not null check (milestone in (25,50,100,175,250)),
  reward_slug text not null,
  claimed_at timestamptz not null default now(),
  primary key (character_id, milestone)
);

alter table public.character_exploration_milestones enable row level security;
revoke all on table public.character_exploration_milestones from public, anon, authenticated;
grant all on table public.character_exploration_milestones to service_role;

create or replace function private.active_camp_specialization(p_character_id uuid)
returns text
language sql
stable
security definer
set search_path to 'pg_catalog','public','private'
as $$
  select c.specialization
  from public.character_camps c
  where c.character_id=p_character_id
    and c.expires_at>now()
  limit 1;
$$;

create or replace function private.character_cartography_speed_percent(p_character_id uuid)
returns integer
language sql
stable
security definer
set search_path to 'pg_catalog','public','private'
as $$
  with x as (
    select count(*)::integer as discovered
    from public.character_sector_discoveries d
    where d.character_id=p_character_id
  )
  select case
    when discovered>=250 then 18
    when discovered>=175 then 15
    when discovered>=100 then 12
    when discovered>=50 then 8
    when discovered>=25 then 5
    else 0
  end
  from x;
$$;

create or replace function private.character_exploration_speed_percent(p_character_id uuid)
returns integer
language sql
stable
security definer
set search_path to 'pg_catalog','public','private'
as $$
  select greatest(
    -75,
    least(
      300,
      private.character_religion_modifier_number(p_character_id,'exploration_speed_percent')
      + private.character_equipment_exploration_speed_percent(p_character_id)
      + private.character_cartography_speed_percent(p_character_id)
      + case when private.active_camp_specialization(p_character_id)='scout' then 10 else 0 end
    )
  );
$$;

create or replace function private.character_defense_percent(p_character_id uuid)
returns integer
language sql
stable
security definer
set search_path to 'pg_catalog','public','private'
as $$
  select greatest(
    -75,
    least(
      100,
      coalesce((
        select sum(
          case
            when jsonb_typeof(idf.stat_modifiers->'defense_percent')='number'
              then (idf.stat_modifiers->>'defense_percent')::numeric::integer
            else 0
          end
        )
        from public.character_equipment ce
        join public.character_items ci on ci.id=ce.character_item_id
        join public.item_definitions idf on idf.id=ci.item_definition_id
        where ce.character_id=p_character_id
      ),0)::integer
      + case when private.active_camp_specialization(p_character_id)='war' then 8 else 0 end
    )
  );
$$;

create or replace function private.current_wandering_merchant_offers(p_character_id uuid)
returns table(item_definition_id uuid, offer_price integer)
language sql
stable
security definer
set search_path to 'pg_catalog','public','private'
as $$
  select
    c.item_definition_id,
    greatest(
      1,
      round(
        c.offer_price
        * case when private.active_camp_specialization(p_character_id)='trader' then 0.90 else 1.00 end
      )::integer
    ) as offer_price
  from public.wandering_merchant_catalog c
  join public.character_progress cp
    on cp.character_id=p_character_id
  where c.enabled
    and cp.level between c.min_level and c.max_level
  order by
    (
      -ln(
        (
          ((pg_catalog.hashtextextended(
            current_date::text||':'||p_character_id::text||':'||c.item_definition_id::text,
            0
          ) & 2147483647)::numeric + 1)
          / 2147483649.0
        )
      )
      / greatest(c.weight,1)
    ),
    c.item_definition_id
  limit 4;
$$;

create or replace function public.place_character_camp(
  p_character_id uuid,
  p_sector_id smallint,
  p_specialization text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  caller_id uuid:=auth.uid();
  sector_row public.sector_details;
  progress_row public.character_progress;
  active_row public.character_camps;
  price integer;
  expires_value timestamptz;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller_id
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  if p_specialization not in ('scout','hunter','war','trader') then
    raise exception 'INVALID_CAMP_SPECIALIZATION';
  end if;

  if not exists(
    select 1 from public.character_sector_discoveries d
    where d.character_id=p_character_id and d.sector_id=p_sector_id
  ) then raise exception 'CAMP_SECTOR_NOT_DISCOVERED'; end if;

  select * into sector_row
  from public.sector_details sd
  where sd.sector_id=p_sector_id;

  if sector_row.sector_id is null
     or coalesce(sector_row.content_type,'unassigned')<>'wilderness'
     or coalesce(sector_row.terrain_type,'')='sea'
  then
    raise exception 'CAMP_REQUIRES_WILDERNESS';
  end if;

  perform private.complete_expired_sector_expeditions(p_character_id);
  perform private.complete_expired_site_actions(p_character_id);

  if exists(
    select 1 from public.sector_expeditions e
    where e.character_id=p_character_id and e.status in ('active','awaiting_event')
  ) then raise exception 'EXPEDITION_ALREADY_ACTIVE'; end if;

  if exists(
    select 1 from public.sector_site_actions a
    where a.character_id=p_character_id and a.status='active'
  ) then raise exception 'SITE_ACTION_ALREADY_ACTIVE'; end if;

  if exists(
    select 1 from public.dungeon_runs r
    where r.character_id=p_character_id and r.status='active'
  ) then raise exception 'DUNGEON_RUN_ALREADY_ACTIVE'; end if;

  if exists(
    select 1 from public.combat_encounters ce
    where ce.character_id=p_character_id and ce.status='active'
  ) then raise exception 'COMBAT_ALREADY_ACTIVE'; end if;

  if exists(
    select 1
    from public.party_dungeon_runs pr
    join public.party_dungeon_run_members prm on prm.run_id=pr.id
    where prm.character_id=p_character_id and pr.status='active'
  ) then raise exception 'PARTY_DUNGEON_ACTIVE'; end if;

  select * into active_row
  from public.character_camps c
  where c.character_id=p_character_id and c.expires_at>now()
  for update;

  price:=case when active_row.character_id is null then 80 else 120 end;

  select * into progress_row
  from public.character_progress cp
  where cp.character_id=p_character_id
  for update;

  if progress_row.character_id is null then raise exception 'CHARACTER_PROGRESS_NOT_FOUND'; end if;
  if progress_row.gold<price then raise exception 'NOT_ENOUGH_GOLD'; end if;

  update public.character_progress
  set gold=gold-price,updated_at=now()
  where character_id=p_character_id;

  expires_value:=now()+interval '48 hours';

  insert into public.character_camps(
    character_id,sector_id,specialization,placed_at,expires_at,updated_at
  )
  values(
    p_character_id,p_sector_id,p_specialization,now(),expires_value,now()
  )
  on conflict(character_id) do update
    set sector_id=excluded.sector_id,
        specialization=excluded.specialization,
        placed_at=excluded.placed_at,
        expires_at=excluded.expires_at,
        updated_at=now();

  return jsonb_build_object(
    'character_id',p_character_id,
    'sector_id',p_sector_id,
    'specialization',p_specialization,
    'price',price,
    'expires_at',expires_value
  );
end;
$$;

create or replace function public.remove_character_camp(p_character_id uuid)
returns boolean
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  caller_id uuid:=auth.uid();
  removed boolean:=false;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller_id
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  delete from public.character_camps
  where character_id=p_character_id;
  removed:=found;
  return removed;
end;
$$;

create or replace function private.reward_exploration_milestones(p_character_id uuid)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  discovered_count integer:=0;
  milestone_row record;
  claimed_value smallint;
  reward_name text;
  granted_count integer:=0;
begin
  select count(*)::integer into discovered_count
  from public.character_sector_discoveries d
  where d.character_id=p_character_id;

  for milestone_row in
    select *
    from (values
      (25::smallint,'smithing_scrap_beta'::text,3::integer),
      (50::smallint,'treasure_map_faded'::text,1::integer),
      (100::smallint,'ancient_coin_cache'::text,2::integer),
      (175::smallint,'treasure_map_royal'::text,1::integer),
      (250::smallint,'ancient_relic_fragment_beta'::text,1::integer)
    ) as m(milestone,reward_slug,reward_quantity)
    where m.milestone<=discovered_count
    order by m.milestone
  loop
    claimed_value:=null;

    insert into public.character_exploration_milestones(
      character_id,milestone,reward_slug
    )
    values(
      p_character_id,milestone_row.milestone,milestone_row.reward_slug
    )
    on conflict(character_id,milestone) do nothing
    returning milestone into claimed_value;

    if claimed_value is not null then
      perform private.grant_item_slug(
        p_character_id,
        milestone_row.reward_slug,
        milestone_row.reward_quantity
      );

      select d.name into reward_name
      from public.item_definitions d
      where d.slug=milestone_row.reward_slug;

      perform private.record_discovery(
        p_character_id,
        'cartography',
        'milestone_'||milestone_row.milestone::text,
        'Веха картографа: '||milestone_row.milestone::text,
        'Исследовано '||milestone_row.milestone::text||' секторов. Награда: '
          ||coalesce(reward_name,milestone_row.reward_slug)
          ||case when milestone_row.reward_quantity>1 then ' ×'||milestone_row.reward_quantity::text else '' end||'.',
        jsonb_build_object(
          'milestone',milestone_row.milestone,
          'reward_slug',milestone_row.reward_slug,
          'reward_quantity',milestone_row.reward_quantity
        )
      );
      granted_count:=granted_count+1;
    end if;
  end loop;

  return granted_count;
end;
$$;

create or replace function private.exploration_milestone_after_discovery()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
begin
  perform private.reward_exploration_milestones(new.character_id);
  return new;
end;
$$;

drop trigger if exists exploration_milestone_after_discovery on public.character_sector_discoveries;
create trigger exploration_milestone_after_discovery
after insert on public.character_sector_discoveries
for each row execute function private.exploration_milestone_after_discovery();

create or replace function private.hunter_camp_after_hunting_attempt()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  reward_slug text;
begin
  if new.result_kind='resource'
     and new.status='resolved'
     and new.item_definition_id is not null
     and private.active_camp_specialization(new.character_id)='hunter'
  then
    select d.slug into reward_slug
    from public.item_definitions d
    where d.id=new.item_definition_id;

    if reward_slug is not null then
      perform private.grant_item_slug(new.character_id,reward_slug,1);
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists hunter_camp_after_hunting_attempt on private.hunting_attempts;
create trigger hunter_camp_after_hunting_attempt
after insert on private.hunting_attempts
for each row execute function private.hunter_camp_after_hunting_attempt();

create or replace function public.get_character_world_markers(p_character_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  caller_id uuid:=auth.uid();
  merchant_sector smallint;
  marker_data jsonb:='[]'::jsonb;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id
      and (c.owner_user_id=caller_id or private.is_gm(caller_id))
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  merchant_sector:=private.current_wandering_merchant_sector(p_character_id);

  select coalesce(jsonb_agg(x.payload order by x.priority,x.kind,x.id),'[]'::jsonb)
  into marker_data
  from (
    select
      10 as priority,
      'treasure'::text as kind,
      h.id::text as id,
      jsonb_build_object(
        'id',h.id::text,
        'kind','treasure',
        'sector_id',h.target_sector_id,
        'title','Карта сокровищ',
        'detail',coalesce(h.target_name,'Отмеченный сектор')
      ) as payload
    from public.character_treasure_hunts h
    where h.character_id=p_character_id and h.status='active'

    union all

    select
      20,'camp',c.character_id::text,
      jsonb_build_object(
        'id',c.character_id::text,
        'kind','camp',
        'sector_id',c.sector_id,
        'title','Лагерь',
        'detail',case c.specialization
          when 'scout' then 'Разведывательный'
          when 'hunter' then 'Охотничий'
          when 'war' then 'Военный'
          else 'Торговый'
        end,
        'ends_at',c.expires_at
      )
    from public.character_camps c
    where c.character_id=p_character_id and c.expires_at>now()

    union all

    select
      30,'merchant','daily',
      jsonb_build_object(
        'id','daily',
        'kind','merchant',
        'sector_id',merchant_sector,
        'title','Странствующий торговец',
        'detail','Сегодняшняя стоянка'
      )
    where merchant_sector is not null

    union all

    select
      40,'quest',q.id::text,
      jsonb_build_object(
        'id',q.id::text,
        'kind','quest',
        'sector_id',d.sector_id,
        'title',d.title,
        'detail','Активное поручение'
      )
    from public.character_settlement_quests q
    join public.settlement_quest_definitions d on d.id=q.quest_definition_id
    where q.character_id=p_character_id and q.status='active'
  ) x;

  return marker_data;
end;
$$;

create or replace function public.get_character_activity_journal(p_character_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  caller_id uuid:=auth.uid();
  lvl integer:=1;
  discovered_count integer:=0;
  cartography_bonus integer:=0;
  next_milestone integer:=null;
  merchant_sector smallint;
  entries_data jsonb:='[]'::jsonb;
  blocker_data jsonb:='null'::jsonb;
  camp_data jsonb:='null'::jsonb;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id
      and (c.owner_user_id=caller_id or private.is_gm(caller_id))
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  perform private.complete_expired_sector_expeditions(p_character_id);
  perform private.complete_expired_site_actions(p_character_id);
  perform private.expire_death_spirits();

  select coalesce(cp.level,1) into lvl
  from public.character_progress cp
  where cp.character_id=p_character_id;

  select count(*)::integer into discovered_count
  from public.character_sector_discoveries d
  where d.character_id=p_character_id;

  cartography_bonus:=private.character_cartography_speed_percent(p_character_id);

  select min(v) into next_milestone
  from unnest(array[25,50,100,175,250]) v
  where v>discovered_count;

  merchant_sector:=private.current_wandering_merchant_sector(p_character_id);

  select jsonb_build_object(
    'sector_id',c.sector_id,
    'specialization',c.specialization,
    'placed_at',c.placed_at,
    'expires_at',c.expires_at,
    'bonus',case c.specialization
      when 'scout' then '+10% к скорости исследований'
      when 'hunter' then '+1 ресурс при удачной охоте'
      when 'war' then '+8% физической защиты'
      else '-10% к ценам странствующего торговца'
    end
  )
  into camp_data
  from public.character_camps c
  where c.character_id=p_character_id and c.expires_at>now();

  select coalesce(
    (
      select jsonb_build_object(
        'kind','combat',
        'title','Идёт бой',
        'detail',ce.enemy_name,
        'sector_id',ce.sector_id,
        'ends_at',null
      )
      from public.combat_encounters ce
      where ce.character_id=p_character_id and ce.status='active'
      order by ce.created_at desc
      limit 1
    ),
    (
      select jsonb_build_object(
        'kind','party_dungeon',
        'title','Идёт групповое прохождение',
        'detail','Сначала заверши или покинь текущее приключение группы.',
        'sector_id',pr.sector_id,
        'ends_at',null
      )
      from public.party_dungeon_runs pr
      join public.party_dungeon_run_members prm on prm.run_id=pr.id
      where prm.character_id=p_character_id and pr.status='active'
      order by pr.created_at desc
      limit 1
    ),
    (
      select jsonb_build_object(
        'kind','dungeon',
        'title','Идёт прохождение',
        'detail','Сначала заверши текущее подземелье или охоту.',
        'sector_id',dr.sector_id,
        'ends_at',null
      )
      from public.dungeon_runs dr
      where dr.character_id=p_character_id and dr.status='active'
      order by dr.created_at desc
      limit 1
    ),
    (
      select jsonb_build_object(
        'kind',case when e.treasure_hunt_id is null then 'expedition' else 'treasure_expedition' end,
        'title',case when e.treasure_hunt_id is null then 'Идёт экспедиция' else 'Поход к тайнику' end,
        'detail','Дождись возвращения экспедиции.',
        'sector_id',e.sector_id,
        'ends_at',e.ends_at
      )
      from public.sector_expeditions e
      where e.character_id=p_character_id and e.status in ('active','awaiting_event')
      order by e.started_at desc
      limit 1
    ),
    (
      select jsonb_build_object(
        'kind','site_action',
        'title','Идёт исследование места',
        'detail','Дождись завершения текущего действия.',
        'sector_id',a.sector_id,
        'ends_at',a.ends_at
      )
      from public.sector_site_actions a
      where a.character_id=p_character_id and a.status='active'
      order by a.started_at desc
      limit 1
    ),
    'null'::jsonb
  )
  into blocker_data;

  with journal_rows as (
    select
      10 as priority,
      'treasure'::text as kind,
      h.id::text as id,
      'Карта сокровищ'::text as title,
      coalesce(h.target_name,'Отмеченный сектор')::text as objective,
      case when h.reward_tier>=2
        then 'Редкий тайник: монеты, опыт, материалы и шанс особой вещи'
        else 'Тайник: опыт, материалы и шанс особой вещи'
      end::text as reward_hint,
      h.target_sector_id as sector_id,
      null::timestamptz as ends_at,
      0::integer as progress_current,
      1::integer as progress_target,
      'active'::text as status,
      'Доберись до отмеченного сектора и заверши поход по карте.'::text as action_hint
    from public.character_treasure_hunts h
    where h.character_id=p_character_id and h.status='active'

    union all

    select
      20,'expedition',e.id::text,
      case when e.treasure_hunt_id is null then 'Экспедиция' else 'Поход к тайнику' end,
      coalesce(sd.title,'Сектор #'||e.sector_id::text),
      'Результат откроется после возвращения.',
      e.sector_id,e.ends_at,0,1,e.status,
      case when e.ends_at>now() then 'Экспедиция в пути.' else 'Обнови карту, чтобы завершить экспедицию.' end
    from public.sector_expeditions e
    left join public.sector_details sd on sd.sector_id=e.sector_id
    where e.character_id=p_character_id and e.status in ('active','awaiting_event')

    union all

    select
      30,'dungeon',dr.id::text,
      case when dr.hunting_attempt_id is not null then 'Охота: сильный противник' else 'Подземелье' end,
      coalesce(sd.title,'Сектор #'||dr.sector_id::text),
      case when dr.reward_exhausted then 'Цикл наград истощён.' else 'Золото, опыт и добыча за прохождение.' end,
      dr.sector_id,null::timestamptz,dr.rooms_cleared,dr.total_rooms,dr.status,
      'Продолжи прохождение во вкладке «Бои».'
    from public.dungeon_runs dr
    left join public.sector_details sd on sd.sector_id=dr.sector_id
    where dr.character_id=p_character_id and dr.status='active'

    union all

    select
      40,'settlement_quest',q.id::text,d.title,d.description,
      d.reward_gold::text||' золота · '||d.reward_experience::text||' опыта'
        ||case when coalesce(d.reward_reputation,0)>0 then ' · +'||d.reward_reputation::text||' репутации' else '' end,
      d.sector_id,null::timestamptz,
      least(d.objective_target,coalesce(private.settlement_quest_progress(q.id),0)),
      d.objective_target,q.status,
      'Выполни условие поручения и вернись за наградой.'
    from public.character_settlement_quests q
    join public.settlement_quest_definitions d on d.id=q.quest_definition_id
    where q.character_id=p_character_id and q.status='active'

    union all

    select
      50,'religion_oath',q.id::text,d.name,d.description,
      '+'||d.faith_reward::text||' веры'
        ||case when d.favor_reward<>0 then ' · '||case when d.favor_reward>0 then '+' else '' end||d.favor_reward::text||' благосклонности' else '' end,
      null::smallint,null::timestamptz,
      least(d.target_count,q.progress_count),d.target_count,q.status,
      'Следуй условиям клятвы; нарушение может дать штраф.'
    from public.character_religion_oaths q
    join public.religion_oath_definitions d on d.id=q.oath_definition_id
    where q.character_id=p_character_id and q.status='active'

    union all

    select
      60,'death_spirit',ds.id::text,
      'Вернуть потерянное снаряжение',
      coalesce(idf.name,'Неизвестная вещь'),
      'Победа над своим духом вернёт удерживаемый предмет.',
      ds.sector_id,ds.expires_at,0,1,ds.status,
      'Найди дух на карте до истечения времени.'
    from private.death_spirits ds
    left join public.character_items ci on ci.death_spirit_id=ds.id
    left join public.item_definitions idf on idf.id=ci.item_definition_id
    where ds.owner_character_id=p_character_id
      and ds.status='active'
      and ds.expires_at>now()

    union all

    select
      70,'camp',c.character_id::text,
      case c.specialization
        when 'scout' then 'Разведывательный лагерь'
        when 'hunter' then 'Охотничий лагерь'
        when 'war' then 'Военный лагерь'
        else 'Торговый лагерь'
      end,
      'Лагерь действует 48 часов и даёт специализацию.',
      case c.specialization
        when 'scout' then '+10% скорость исследований'
        when 'hunter' then '+1 ресурс при удачной охоте'
        when 'war' then '+8% физическая защита'
        else '-10% цены странствующего торговца'
      end,
      c.sector_id,c.expires_at,0,1,'active',
      'Можно оставить лагерь до истечения срока или перенести за золото.'
    from public.character_camps c
    where c.character_id=p_character_id and c.expires_at>now()

    union all

    select
      80,'merchant','daily',
      'Странствующий торговец',
      coalesce(sd.title,'Сектор #'||merchant_sector::text),
      'Сегодня доступны 4 персональных предложения; купить можно до 2.',
      merchant_sector,(current_date+1)::timestamptz,0,2,'active',
      'Посмотри предложения в «Живом мире».'
    from public.map_sectors ms
    left join public.sector_details sd on sd.sector_id=ms.id
    where ms.id=merchant_sector

    union all

    select
      90,'rumor',r.slug,
      r.title,r.body,
      'Слух может указывать на событие или изменение мира.',
      null::smallint,r.ends_at,0,1,'active',
      'Следи за картой и событиями мира.'
    from (
      select wr.*
      from public.world_rumors wr
      where wr.enabled
        and wr.min_level<=lvl
        and (wr.starts_at is null or now()>=wr.starts_at)
        and (wr.ends_at is null or now()<wr.ends_at)
      order by
        (
          -ln(
            (
              ((pg_catalog.hashtextextended(
                current_date::text||':'||p_character_id::text||':'||wr.slug,0
              ) & 2147483647)::numeric+1)
              /2147483649.0
            )
          )
          /greatest(wr.weight,1)
        )
      limit 3
    ) r
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',j.id,
        'kind',j.kind,
        'title',j.title,
        'objective',j.objective,
        'reward_hint',j.reward_hint,
        'sector_id',j.sector_id,
        'ends_at',j.ends_at,
        'progress_current',j.progress_current,
        'progress_target',j.progress_target,
        'status',j.status,
        'action_hint',j.action_hint
      )
      order by j.priority,j.kind,j.id
    ),
    '[]'::jsonb
  )
  into entries_data
  from journal_rows j;

  return jsonb_build_object(
    'blocker',blocker_data,
    'entries',entries_data,
    'camp',camp_data,
    'exploration',jsonb_build_object(
      'discovered_count',discovered_count,
      'total_sectors',300,
      'next_milestone',next_milestone,
      'cartography_speed_percent',cartography_bonus,
      'next_reward',case next_milestone
        when 25 then 'Кузнечный лом ×3'
        when 50 then 'Выцветшая карта сокровищ'
        when 100 then 'Связка древних монет ×2'
        when 175 then 'Карта с золотой печатью'
        when 250 then 'Осколок древней реликвии'
        else null
      end
    )
  );
end;
$$;

create or replace function public.gm_get_character_runtime_state(p_character_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  caller_id uuid:=auth.uid();
  character_name text;
  state_data jsonb;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.is_gm(caller_id) then raise exception 'GM_REQUIRED'; end if;

  select c.name into character_name
  from public.characters c
  where c.id=p_character_id;

  if character_name is null then raise exception 'CHARACTER_NOT_FOUND'; end if;

  state_data:=jsonb_build_object(
    'character_id',p_character_id,
    'character_name',character_name,
    'journal',public.get_character_activity_journal(p_character_id),
    'progress',(
      select jsonb_build_object(
        'level',cp.level,
        'hp_current',cp.hp_current,
        'hp_max',cp.hp_max,
        'mana_current',cp.mana_current,
        'mana_max',cp.mana_max,
        'gold',cp.gold,
        'unspent_stat_points',cp.unspent_stat_points
      )
      from public.character_progress cp
      where cp.character_id=p_character_id
    ),
    'active',jsonb_build_object(
      'sector_expeditions',(
        select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at desc),'[]'::jsonb)
        from public.sector_expeditions e
        where e.character_id=p_character_id and e.status in ('active','awaiting_event')
      ),
      'site_actions',(
        select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at desc),'[]'::jsonb)
        from public.sector_site_actions a
        where a.character_id=p_character_id and a.status='active'
      ),
      'dungeon_runs',(
        select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc),'[]'::jsonb)
        from public.dungeon_runs r
        where r.character_id=p_character_id and r.status='active'
      ),
      'combat_encounters',(
        select coalesce(jsonb_agg(jsonb_build_object(
          'id',ce.id,'sector_id',ce.sector_id,'enemy_name',ce.enemy_name,
          'round',ce.round,'created_at',ce.created_at
        ) order by ce.created_at desc),'[]'::jsonb)
        from public.combat_encounters ce
        where ce.character_id=p_character_id and ce.status='active'
      ),
      'party_runs',(
        select coalesce(jsonb_agg(jsonb_build_object(
          'id',pr.id,'sector_id',pr.sector_id,'stage',pr.current_stage,
          'rooms_cleared',pr.rooms_cleared,'total_rooms',pr.total_rooms
        ) order by pr.created_at desc),'[]'::jsonb)
        from public.party_dungeon_runs pr
        join public.party_dungeon_run_members prm on prm.run_id=pr.id
        where prm.character_id=p_character_id and pr.status='active'
      )
    )
  );

  return state_data;
end;
$$;

revoke all on function public.place_character_camp(uuid,smallint,text) from public, anon;
revoke all on function public.remove_character_camp(uuid) from public, anon;
revoke all on function public.get_character_world_markers(uuid) from public, anon;
revoke all on function public.get_character_activity_journal(uuid) from public, anon;
revoke all on function public.gm_get_character_runtime_state(uuid) from public, anon;

grant execute on function public.place_character_camp(uuid,smallint,text) to authenticated,service_role;
grant execute on function public.remove_character_camp(uuid) to authenticated,service_role;
grant execute on function public.get_character_world_markers(uuid) to authenticated,service_role;
grant execute on function public.get_character_activity_journal(uuid) to authenticated,service_role;
grant execute on function public.gm_get_character_runtime_state(uuid) to authenticated,service_role;

revoke all on function private.active_camp_specialization(uuid) from public,anon,authenticated;
revoke all on function private.character_cartography_speed_percent(uuid) from public,anon,authenticated;
revoke all on function private.reward_exploration_milestones(uuid) from public,anon,authenticated;
revoke all on function private.exploration_milestone_after_discovery() from public,anon,authenticated;
revoke all on function private.hunter_camp_after_hunting_attempt() from public,anon,authenticated;

do $$
declare
  cid uuid;
begin
  for cid in select c.id from public.characters c loop
    perform private.reward_exploration_milestones(cid);
  end loop;
end;
$$;

