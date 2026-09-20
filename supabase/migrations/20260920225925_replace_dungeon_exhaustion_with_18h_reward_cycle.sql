create table if not exists private.dungeon_reward_cycles(
  character_id uuid not null references public.characters(id) on delete cascade,
  sector_id smallint not null references public.sector_details(sector_id) on delete cascade,
  cycle_started_at timestamptz not null,
  cycle_ends_at timestamptz not null,
  attempts integer not null default 0 check(attempts>=0),
  updated_at timestamptz not null default now(),
  primary key(character_id,sector_id)
);

revoke all on table private.dungeon_reward_cycles from public,anon,authenticated;

alter table public.dungeon_runs
  add column if not exists reward_exhausted boolean not null default false,
  add column if not exists reward_attempt_number integer,
  add column if not exists reward_cycle_ends_at timestamptz;

alter table public.party_dungeon_run_members
  add column if not exists reward_attempt_number integer,
  add column if not exists reward_cycle_ends_at timestamptz;


CREATE OR REPLACE FUNCTION private.consume_dungeon_reward_attempt(p_character_id uuid, p_sector_id smallint)
 RETURNS TABLE(attempt_number integer, reward_exhausted boolean, cycle_ends_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  row_cycle private.dungeon_reward_cycles;
  now_at timestamptz:=now();
begin
  insert into private.dungeon_reward_cycles(
    character_id,sector_id,cycle_started_at,cycle_ends_at,attempts,updated_at
  )
  values(p_character_id,p_sector_id,now_at,now_at+interval '18 hours',0,now_at)
  on conflict(character_id,sector_id) do nothing;

  select * into row_cycle
  from private.dungeon_reward_cycles
  where character_id=p_character_id and sector_id=p_sector_id
  for update;

  if row_cycle.cycle_ends_at<=now_at then
    update private.dungeon_reward_cycles
    set cycle_started_at=now_at,
        cycle_ends_at=now_at+interval '18 hours',
        attempts=0,
        updated_at=now_at
    where character_id=p_character_id and sector_id=p_sector_id
    returning * into row_cycle;
  end if;

  attempt_number:=row_cycle.attempts+1;
  reward_exhausted:=attempt_number>25;
  cycle_ends_at:=row_cycle.cycle_ends_at;

  update private.dungeon_reward_cycles
  set attempts=attempt_number,updated_at=now_at
  where character_id=p_character_id and sector_id=p_sector_id;

  return next;
end;
$function$;

CREATE OR REPLACE FUNCTION private.dungeon_recent_clear_count(p_character_id uuid, p_sector_id smallint, p_exclude_solo_run uuid DEFAULT NULL::uuid, p_exclude_party_run uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with cutoff as (
    select coalesce((
      select c.cycle_started_at
      from private.dungeon_reward_cycles c
      where c.character_id=p_character_id
        and c.sector_id=p_sector_id
        and c.cycle_ends_at>now()
      limit 1
    ),now()) as since_at
  )
  select count(*)::integer
  from (
    select r.id
    from public.dungeon_runs r
    cross join cutoff
    where r.character_id=p_character_id
      and r.sector_id=p_sector_id
      and r.status='completed'
      and r.event_boss_id is null
      and r.ended_at >= cutoff.since_at
      and (p_exclude_solo_run is null or r.id<>p_exclude_solo_run)

    union all

    select pr.id
    from public.party_dungeon_runs pr
    join public.party_dungeon_run_members prm on prm.run_id=pr.id
    cross join cutoff
    where prm.character_id=p_character_id
      and pr.sector_id=p_sector_id
      and pr.status='completed'
      and pr.event_boss_id is null
      and pr.ended_at >= cutoff.since_at
      and (p_exclude_party_run is null or pr.id<>p_exclude_party_run)
  ) recent;
$function$;

CREATE OR REPLACE FUNCTION public.start_dungeon_run(p_character_id uuid, p_sector_id smallint)
 RETURNS dungeon_runs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid := auth.uid();
  created_run public.dungeon_runs;
  sector_info public.sector_details;
  danger integer;
  room_count integer;
  reward_gold_value integer;
  reward_exp_value integer;
  character_level integer:=1;
  reward_exhausted_value boolean:=false;
  reward_attempt_number_value integer:=1;
  reward_cycle_ends_at_value timestamptz;
begin
  if caller_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.characters c
    where c.id = p_character_id
      and c.owner_user_id = caller_id
  ) then
    raise exception 'CHARACTER_NOT_OWNED';
  end if;

  perform private.complete_expired_sector_expeditions(p_character_id);
  perform private.complete_expired_site_actions(p_character_id);

  select details.*
    into sector_info
  from public.character_sector_discoveries d
  join public.sector_details details on details.sector_id = d.sector_id
  where d.character_id = p_character_id
    and d.sector_id = p_sector_id
    and details.content_type = 'dungeon';

  if sector_info.sector_id is null then
    raise exception 'DUNGEON_NOT_DISCOVERED';
  end if;

  if not exists (
    select 1
    from public.character_sector_site_progress p
    where p.character_id = p_character_id
      and p.sector_id = p_sector_id
      and p.site_type = 'dungeon'
      and p.status in ('scouted','cleared')
  ) then
    raise exception 'DUNGEON_NOT_SCOUTED';
  end if;

  if exists (
    select 1
    from public.sector_expeditions e
    where e.character_id = p_character_id
      and e.status in ('active','awaiting_event')
  ) then
    raise exception 'EXPEDITION_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.sector_site_actions a
    where a.character_id = p_character_id
      and a.status = 'active'
  ) then
    raise exception 'SITE_ACTION_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.dungeon_runs r
    where r.character_id = p_character_id
      and r.status = 'active'
  ) then
    raise exception 'DUNGEON_RUN_ALREADY_ACTIVE';
  end if;

  select a.attempt_number,a.reward_exhausted,a.cycle_ends_at
  into reward_attempt_number_value,reward_exhausted_value,reward_cycle_ends_at_value
  from private.consume_dungeon_reward_attempt(p_character_id,p_sector_id) a;

  danger := greatest(0, least(10, coalesce(sector_info.danger_level, 0)));

  select coalesce(cp.level,1) into character_level
  from public.character_progress cp
  where cp.character_id=p_character_id;

  room_count := case
    when danger = 0 then 1
    when danger <= 2 then 2
    when danger <= 4 then 3
    when danger <= 6 then 4
    when danger <= 8 then 5
    else 6
  end;

  -- 0/10 is intentionally a recovery/fallback farm: tiny XP, useful emergency gold.
  if danger = 0 then
    reward_gold_value := 40;
    reward_exp_value := private.dungeon_zero_experience(character_level);
  else
    reward_gold_value := 40 + danger * 25 + room_count * 12;
    reward_exp_value := 50 + danger * 45 + room_count * 18;
  end if;

  if danger>0 then
    reward_gold_value:=private.scaled_dungeon_gold(danger,character_level,reward_gold_value);
    reward_exp_value:=private.scaled_dungeon_xp(danger,character_level,reward_exp_value);
  end if;

  reward_gold_value:=greatest(
    1,
    round(reward_gold_value
      *private.dungeon_repeat_gold_multiplier_percent(p_character_id,p_sector_id)
      /100.0
    )::integer
  );
  reward_exp_value:=greatest(
    0,
    round(reward_exp_value
      *private.dungeon_repeat_xp_multiplier_percent(p_character_id,p_sector_id)
      /100.0
    )::integer
  );

  if reward_exhausted_value then
    reward_gold_value:=0;
    reward_exp_value:=0;
  end if;

  insert into public.dungeon_runs (
    character_id,
    sector_id,
    status,
    current_stage,
    rooms_cleared,
    total_rooms,
    reward_gold,
    reward_experience,
    reward_exhausted,
    reward_attempt_number,
    reward_cycle_ends_at
  )
  values (
    p_character_id,
    p_sector_id,
    'active',
    'entrance',
    0,
    room_count,
    reward_gold_value,
    reward_exp_value,
    reward_exhausted_value,
    reward_attempt_number_value,
    reward_cycle_ends_at_value
  )
  returning * into created_run;

  return created_run;
end;
$function$;

CREATE OR REPLACE FUNCTION public.start_party_dungeon_run(p_character_id uuid, p_sector_id smallint)
 RETURNS party_dungeon_runs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid:=auth.uid();
  party_row public.parties;
  sector_info public.sector_details;
  created_run public.party_dungeon_runs;
  member_row public.party_members;
  party_size integer;
  danger integer;
  room_count integer;
  reward_gold_value integer;
  reward_exp_value integer;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id
      and c.owner_user_id=caller_id
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select p.* into party_row
  from public.parties p
  join public.party_members pm on pm.party_id=p.id
  where pm.character_id=p_character_id
    and p.status='active'
  for update of p;

  if party_row.id is null then raise exception 'PARTY_NOT_FOUND'; end if;
  if party_row.leader_character_id<>p_character_id then raise exception 'PARTY_LEADER_REQUIRED'; end if;

  select count(*) into party_size
  from public.party_members
  where party_id=party_row.id;

  if party_size<2 then raise exception 'PARTY_NEEDS_TWO_MEMBERS'; end if;
  if party_size>4 then raise exception 'PARTY_TOO_LARGE'; end if;

  if exists(
    select 1 from public.party_dungeon_runs
    where party_id=party_row.id
      and status='active'
  ) then raise exception 'PARTY_DUNGEON_ALREADY_ACTIVE'; end if;

  if not private.party_common_dungeon_access(party_row.id,p_sector_id) then
    raise exception 'PARTY_DUNGEON_NOT_AVAILABLE_TO_ALL';
  end if;

  select * into sector_info
  from public.sector_details
  where sector_id=p_sector_id
    and content_type='dungeon';

  if sector_info.sector_id is null then raise exception 'DUNGEON_NOT_FOUND'; end if;

  for member_row in
    select *
    from public.party_members
    where party_id=party_row.id
    order by (character_id=party_row.leader_character_id) desc,joined_at,character_id
  loop
    if private.character_blocked_for_party_dungeon(member_row.character_id) then
      raise exception 'PARTY_MEMBER_BUSY:%',member_row.character_id;
    end if;

    perform private.apply_passive_hp_regen(member_row.character_id);
    perform private.apply_passive_mana_regen(member_row.character_id);
  end loop;

  danger:=greatest(0,least(10,coalesce(sector_info.danger_level,0)));

  room_count:=case
    when danger=0 then 1
    when danger<=2 then 2
    when danger<=4 then 3
    when danger<=6 then 4
    when danger<=8 then 5
    else 6
  end;

  if danger=0 then
    reward_gold_value:=40;
    reward_exp_value:=15;
  else
    reward_gold_value:=40+danger*25+room_count*12;
    reward_exp_value:=50+danger*45+room_count*18;
  end if;

  insert into public.party_dungeon_runs(
    party_id,leader_character_id,sector_id,status,current_stage,
    rooms_cleared,total_rooms,reward_gold,reward_experience,member_count
  )
  values(
    party_row.id,p_character_id,p_sector_id,'active','entrance',
    0,room_count,reward_gold_value,reward_exp_value,party_size
  )
  returning * into created_run;

  insert into public.party_dungeon_run_members(
    run_id,character_id,joined_order,reward_exhausted,reward_attempt_number,reward_cycle_ends_at
  )
  select
    created_run.id,
    pm.character_id,
    row_number() over(
      order by (pm.character_id=party_row.leader_character_id) desc,pm.joined_at,pm.character_id
    )::smallint,
    cycle.reward_exhausted,
    cycle.attempt_number,
    cycle.cycle_ends_at
  from public.party_members pm
  cross join lateral private.consume_dungeon_reward_attempt(pm.character_id,p_sector_id) cycle
  where pm.party_id=party_row.id;

  return created_run;
end;
$function$;

CREATE OR REPLACE FUNCTION private.roll_combat_loot(p_encounter_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  encounter public.combat_encounters;
  sd public.sector_details;
  entry public.loot_pool_entries;
  qty integer;
  drops_count integer:=0;
begin
  select * into encounter
  from public.combat_encounters
  where id=p_encounter_id
  for update;

  if encounter.id is null then raise exception 'COMBAT_NOT_FOUND'; end if;
  if encounter.loot_rolled then return 0; end if;
  if encounter.status<>'victory' then raise exception 'COMBAT_NOT_VICTORY'; end if;

  if exists(
    select 1
    from public.dungeon_runs r
    where r.id=encounter.dungeon_run_id
      and coalesce(r.reward_exhausted,false)
  ) then
    update public.combat_encounters
    set loot_rolled=true
    where id=encounter.id;
    return 0;
  end if;

  select * into sd
  from public.sector_details
  where sector_id=encounter.sector_id;

  for entry in
    select l.*
    from public.loot_pool_entries l
    where l.enabled=true
      and (l.source_type='enemy' or (encounter.is_boss and l.source_type='boss'))
      and sd.danger_level between l.min_danger and l.max_danger
      and (
        sd.danger_level<>0
        or exists(
          select 1
          from public.item_definitions zero_item
          where zero_item.id=l.item_definition_id
            and zero_item.rarity='common'
            and zero_item.required_level<=1
        )
      )
      and (l.enemy_template_id is null or l.enemy_template_id=encounter.enemy_template_id)
      and (l.terrain_type is null or l.terrain_type=sd.terrain_type)
    order by
      (l.enemy_template_id is not null) desc,
      (l.terrain_type is not null) desc,
      l.created_at
  loop
    if private.character_can_receive_loot_item(encounter.character_id,entry.item_definition_id)
       and private.roll_dungeon_quality_loot(
         encounter.character_id,
         entry.item_definition_id,
         entry.chance_percent
       ) then
      qty:=entry.min_quantity
        + floor(random()*(entry.max_quantity-entry.min_quantity+1))::integer;

      perform private.grant_character_item(
        encounter.character_id,
        entry.item_definition_id,
        qty,
        jsonb_build_object(
          'source','loot',
          'dungeon_run_id',encounter.dungeon_run_id,
          'combat_encounter_id',encounter.id
        )
      );

      insert into public.loot_drops(
        character_id,dungeon_run_id,combat_encounter_id,source_type,
        item_definition_id,quantity
      )
      values(
        encounter.character_id,encounter.dungeon_run_id,encounter.id,
        case when encounter.is_boss then 'boss' else 'enemy' end,
        entry.item_definition_id,qty
      );

      drops_count:=drops_count+1;
    end if;
  end loop;

  update public.combat_encounters
  set loot_rolled=true
  where id=encounter.id;

  return drops_count;
end;
$function$;

CREATE OR REPLACE FUNCTION private.roll_dungeon_completion_loot(p_run_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  run_row public.dungeon_runs;
  sd public.sector_details;
  entry public.loot_pool_entries;
  qty integer;
  drops_count integer:=0;
  favor_reroll_available boolean:=false;
  drop_success boolean:=false;
begin
  select * into run_row
  from public.dungeon_runs
  where id=p_run_id
  for update;

  if run_row.id is null then raise exception 'DUNGEON_RUN_NOT_FOUND'; end if;
  if run_row.loot_rolled then return 0; end if;
  if run_row.status<>'completed' then raise exception 'DUNGEON_NOT_COMPLETED'; end if;

  if coalesce(run_row.reward_exhausted,false) then
    update public.dungeon_runs set loot_rolled=true where id=run_row.id;
    return 0;
  end if;

  select * into sd
  from public.sector_details
  where sector_id=run_row.sector_id;

  favor_reroll_available:=private.character_current_favor(run_row.character_id)>=100;

  for entry in
    select l.*
    from public.loot_pool_entries l
    where l.enabled=true
      and l.source_type='dungeon'
      and sd.danger_level between l.min_danger and l.max_danger
      and (
        sd.danger_level<>0
        or exists(
          select 1
          from public.item_definitions zero_item
          where zero_item.id=l.item_definition_id
            and zero_item.rarity='common'
            and zero_item.required_level<=1
        )
      )
      and (l.sector_id is null or l.sector_id=run_row.sector_id)
      and (l.terrain_type is null or l.terrain_type=sd.terrain_type)
    order by
      coalesce((
        select private.item_rarity_rank(i.rarity)
        from public.item_definitions i
        where i.id=l.item_definition_id
      ),0) desc,
      (l.sector_id is not null) desc,
      (l.terrain_type is not null) desc,
      l.created_at
  loop
    drop_success:=false;

    if private.character_can_receive_loot_item(run_row.character_id,entry.item_definition_id) then
      drop_success:=private.roll_dungeon_quality_loot(
        run_row.character_id,
        entry.item_definition_id,
        entry.chance_percent
      );

      if not drop_success
         and favor_reroll_available
         and private.is_quality_dungeon_gear(entry.item_definition_id)
      then
        favor_reroll_available:=false;
        drop_success:=private.roll_dungeon_quality_loot(
          run_row.character_id,
          entry.item_definition_id,
          entry.chance_percent
        );
      end if;
    end if;

    if drop_success then
      qty:=entry.min_quantity
        + floor(random()*(entry.max_quantity-entry.min_quantity+1))::integer;

      perform private.grant_character_item(
        run_row.character_id,
        entry.item_definition_id,
        qty,
        jsonb_build_object(
          'source','dungeon_completion',
          'dungeon_run_id',run_row.id,
          'sector_id',run_row.sector_id
        )
      );

      insert into public.loot_drops(
        character_id,dungeon_run_id,combat_encounter_id,source_type,
        item_definition_id,quantity
      )
      values(
        run_row.character_id,run_row.id,null,'dungeon',
        entry.item_definition_id,qty
      );

      drops_count:=drops_count+1;
    end if;
  end loop;

  update public.dungeon_runs
  set loot_rolled=true
  where id=run_row.id;

  return drops_count;
end;
$function$;

CREATE OR REPLACE FUNCTION private.finish_combat_victory(p_encounter_id uuid, p_round integer, p_player_hp integer, p_player_mana integer)
 RETURNS combat_encounters
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  encounter public.combat_encounters;
  run_row public.dungeon_runs;
  cleared_rooms integer;
  is_final_room boolean;
  room_drop_count integer:=0;
  chest_drop_count integer:=0;
  dungeon_danger integer:=0;
  character_level integer:=1;
  actual_reward_exp integer:=0;
  actual_reward_gold integer:=0;
  event_reward jsonb;
  spirit_trophy text;
begin
  select * into encounter
  from public.combat_encounters
  where id=p_encounter_id
  for update;

  if encounter.id is null then raise exception 'COMBAT_NOT_FOUND'; end if;

  if encounter.death_spirit_id is not null then
    spirit_trophy:=private.resolve_death_spirit_victory(encounter.death_spirit_id,encounter.character_id);
    update public.character_progress
    set hp_regen_anchor_at=now(),mana_regen_anchor_at=now(),updated_at=now()
    where character_id=encounter.character_id;
    update public.combat_encounters
    set status='victory',round=p_round,enemy_hp_current=0,
        player_hp_current=p_player_hp,player_mana_current=p_player_mana,
        ended_at=coalesce(ended_at,now())
    where id=encounter.id returning * into encounter;
    insert into public.combat_turns(encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message)
    values(encounter.id,p_round,'system','death_spirit_victory',0,p_player_hp,0,
      case when spirit_trophy is null
        then 'Дух рассеян. У него не было удерживаемого снаряжения.'
        else 'Дух рассеян. Получено снаряжение: '||spirit_trophy||'.' end);
    delete from public.combat_status_effects where encounter_id=encounter.id;
    return encounter;
  end if;

  select * into run_row
  from public.dungeon_runs
  where id=encounter.dungeon_run_id
  for update;

  if run_row.hunting_attempt_id is not null then
    update public.combat_encounters
    set status='victory',round=p_round,enemy_hp_current=0,
        player_hp_current=p_player_hp,player_mana_current=p_player_mana,
        ended_at=coalesce(ended_at,now())
    where id=encounter.id
    returning * into encounter;

    update public.dungeon_runs
    set status='completed',current_stage='hunting_victory',rooms_cleared=1,
        reward_gold=0,reward_experience=0,ended_at=coalesce(ended_at,now())
    where id=run_row.id;

    update private.hunting_attempts
    set status='victory',resolved_at=now()
    where id=run_row.hunting_attempt_id;

    update public.character_progress
    set hp_regen_anchor_at=now(),mana_regen_anchor_at=now(),updated_at=now()
    where character_id=encounter.character_id;

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    ) values(
      encounter.id,p_round,'system','hunting_victory',0,p_player_hp,0,
      'Сильный монстр повержен. Давление охоты в регионе не сбрасывается: при 6/6 следующая охота снова приведёт к сильному монстру.'
    );

    delete from public.combat_status_effects where encounter_id=encounter.id;
    return encounter;
  end if;

  if run_row.event_boss_id is not null then
    update public.combat_encounters
    set status='victory',round=p_round,enemy_hp_current=0,
        player_hp_current=p_player_hp,player_mana_current=p_player_mana,
        ended_at=coalesce(ended_at,now())
    where id=encounter.id
    returning * into encounter;

    event_reward:=private.grant_event_boss_victory(run_row.event_boss_id,encounter.character_id);

    update public.dungeon_runs
    set status='completed',current_stage='event_boss_victory',rooms_cleared=1,
        reward_gold=coalesce((event_reward->>'gold')::integer,0),
        reward_experience=coalesce((event_reward->>'experience')::integer,0),
        ended_at=coalesce(ended_at,now())
    where id=run_row.id;

    update public.character_progress
    set hp_regen_anchor_at=now(),mana_regen_anchor_at=now()
    where character_id=encounter.character_id;

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    ) values(
      encounter.id,p_round,'system','event_boss_victory',0,p_player_hp,0,
      'Событие завершено победой. Награда: '||(event_reward->>'gold')||' золота и '||(event_reward->>'experience')||' опыта.'
      ||case when coalesce((event_reward->>'special_reward_awarded')::boolean,false)
        then ' Получена особая награда.' else '' end
      ||case when coalesce((event_reward->>'global_resolved')::boolean,false)
        then ' Глобальная угроза полностью устранена.' else '' end
    );

    delete from public.combat_status_effects where encounter_id=encounter.id;
    return encounter;
  end if;

  select greatest(0,least(10,coalesce(sd.danger_level,0))) into dungeon_danger
  from public.sector_details sd
  where sd.sector_id=run_row.sector_id;

  select coalesce(cp.level,1) into character_level
  from public.character_progress cp
  where cp.character_id=encounter.character_id;

  actual_reward_exp:=private.scaled_dungeon_xp(
    dungeon_danger,
    character_level,
    case
      when dungeon_danger=0 then 15
      else 50+dungeon_danger*45+
        (case
          when dungeon_danger<=2 then 2
          when dungeon_danger<=4 then 3
          when dungeon_danger<=6 then 4
          when dungeon_danger<=8 then 5
          else 6
        end)*18
    end
  );

  actual_reward_gold:=private.scaled_dungeon_gold(
    dungeon_danger,
    character_level,
    case
      when dungeon_danger=0 then 40
      else 40+dungeon_danger*25+
        (case
          when dungeon_danger<=2 then 2
          when dungeon_danger<=4 then 3
          when dungeon_danger<=6 then 4
          when dungeon_danger<=8 then 5
          else 6
        end)*12
    end
  );

  actual_reward_exp:=greatest(
    0,
    round(actual_reward_exp
      *private.dungeon_repeat_xp_multiplier_percent(
        encounter.character_id,run_row.sector_id,run_row.id,null
      )/100.0
    )::integer
  );
  actual_reward_gold:=greatest(
    1,
    round(actual_reward_gold
      *private.dungeon_repeat_gold_multiplier_percent(
        encounter.character_id,run_row.sector_id,run_row.id,null
      )/100.0
    )::integer
  );

  if coalesce(run_row.reward_exhausted,false) then
    actual_reward_exp:=0;
    actual_reward_gold:=0;
  end if;

  update public.combat_encounters
  set status='victory',round=p_round,enemy_hp_current=0,
      player_hp_current=p_player_hp,
      player_mana_current=p_player_mana,
      ended_at=coalesce(ended_at,now())
  where id=encounter.id
  returning * into encounter;

  room_drop_count:=private.roll_combat_loot(encounter.id);

  if room_drop_count>0 then
    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      encounter.id,p_round,'system','loot',0,p_player_hp,0,
      'После боя найдено предметов: '||room_drop_count||'. Они добавлены в инвентарь.'
    );
  end if;

  update public.character_progress
  set hp_regen_anchor_at=now(),mana_regen_anchor_at=now()
  where character_id=encounter.character_id;

  cleared_rooms:=greatest(run_row.rooms_cleared,encounter.room_index);
  is_final_room:=cleared_rooms>=run_row.total_rooms;

  if is_final_room then
    update public.dungeon_runs
    set status='completed',current_stage='cleared',
        rooms_cleared=cleared_rooms,
        reward_gold=actual_reward_gold,
        reward_experience=actual_reward_exp,
        ended_at=coalesce(ended_at,now())
    where id=encounter.dungeon_run_id;

    update public.character_progress
    set gold=gold+actual_reward_gold,
        experience=experience+actual_reward_exp,
        updated_at=now()
    where character_id=encounter.character_id;

    insert into public.character_sector_site_progress(
      character_id,sector_id,site_type,status,first_interacted_at,completed_at,updated_at
    )
    values(
      encounter.character_id,encounter.sector_id,'dungeon','cleared',
      run_row.started_at,now(),now()
    )
    on conflict(character_id,sector_id) do update
    set site_type='dungeon',status='cleared',completed_at=now(),updated_at=now();

    chest_drop_count:=private.roll_dungeon_completion_loot(run_row.id);

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      encounter.id,p_round,'system','dungeon_victory',0,p_player_hp,0,
      case
        when coalesce(run_row.reward_exhausted,false)
        then 'Противник повержен. Подземелье зачищено. Лимит наград этого 18-часового цикла исчерпан: опыт, золото и лут не выдаются.'
        else 'Противник повержен. Подземелье зачищено. Награда: '
          ||actual_reward_gold||' золота и '||actual_reward_exp||' опыта.'
          ||case
            when chest_drop_count>0
            then ' В финальном тайнике найдено предметов: '||chest_drop_count||'.'
            else ''
          end
      end
    );
  else
    update public.dungeon_runs
    set current_stage='room_'||(cleared_rooms+1)||'_ready',
        rooms_cleared=cleared_rooms
    where id=encounter.dungeon_run_id;

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      encounter.id,p_round,'system','room_victory',0,p_player_hp,0,
      'Зал '||cleared_rooms||' очищен. Впереди ещё '
      ||(run_row.total_rooms-cleared_rooms)||'.'
    );
  end if;

  delete from public.combat_status_effects where encounter_id=encounter.id;
  return encounter;
end;
$function$;

CREATE OR REPLACE FUNCTION private.finish_party_combat_victory(p_encounter_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  encounter public.party_combat_encounters;
  run_row public.party_dungeon_runs;
  member_row public.party_dungeon_run_members;
  cleared_rooms integer;
  is_final boolean;
  room_drops integer:=0;
  chest_drops integer:=0;
  member_level integer:=1;
  member_reward_exp integer:=0;
  member_reward_gold integer:=0;
  dungeon_danger integer:=0;
  event_reward jsonb;
begin
  select * into encounter
  from public.party_combat_encounters
  where id=p_encounter_id
  for update;

  if encounter.id is null then raise exception 'PARTY_COMBAT_NOT_FOUND'; end if;

  select * into run_row
  from public.party_dungeon_runs
  where id=encounter.run_id
  for update;

  if run_row.event_boss_id is not null then
    update public.party_combat_encounters
    set status='victory',enemy_hp_current=0,ended_at=coalesce(ended_at,now())
    where id=encounter.id;

    update public.party_dungeon_runs
    set status='completed',current_stage='event_boss_victory',rooms_cleared=1,
        ended_at=coalesce(ended_at,now())
    where id=run_row.id;

    for member_row in
      select * from public.party_dungeon_run_members
      where run_id=run_row.id
      order by joined_order
    loop
      event_reward:=private.grant_event_boss_victory(run_row.event_boss_id,member_row.character_id);
    end loop;

    insert into public.party_combat_turns(
      encounter_id,round,actor_type,action_type,damage,message
    ) values(
      encounter.id,encounter.round,'system','event_boss_victory',0,
      'Временная угроза побеждена. Вклад каждого участника учитывается отдельно; повторный вклад одного и того же персонажа не засчитывается.' 
    );
    return;
  end if;

  select greatest(0,least(10,coalesce(sd.danger_level,0))) into dungeon_danger
  from public.sector_details sd
  where sd.sector_id=run_row.sector_id;

  update public.party_combat_encounters
  set status='victory',
      enemy_hp_current=0,
      ended_at=coalesce(ended_at,now())
  where id=encounter.id;

  room_drops:=private.roll_party_combat_loot(encounter.id);

  cleared_rooms:=greatest(run_row.rooms_cleared,encounter.room_index);
  is_final:=cleared_rooms>=run_row.total_rooms;

  if is_final then
    update public.party_dungeon_runs
    set status='completed',
        current_stage='cleared',
        rooms_cleared=cleared_rooms,
        ended_at=coalesce(ended_at,now())
    where id=run_row.id;

    for member_row in
      select *
      from public.party_dungeon_run_members
      where run_id=run_row.id
      order by joined_order
    loop
      select coalesce(cp.level,1) into member_level
      from public.character_progress cp
      where cp.character_id=member_row.character_id;

      member_reward_exp:=private.scaled_dungeon_xp(
        dungeon_danger,
        member_level,
        case
          when dungeon_danger=0 then 15
          else 50+dungeon_danger*45+
            (case
              when dungeon_danger<=2 then 2
              when dungeon_danger<=4 then 3
              when dungeon_danger<=6 then 4
              when dungeon_danger<=8 then 5
              else 6
            end)*18
        end
      );

      member_reward_gold:=private.scaled_dungeon_gold(
        dungeon_danger,
        member_level,
        case
          when dungeon_danger=0 then 40
          else 40+dungeon_danger*25+
            (case
              when dungeon_danger<=2 then 2
              when dungeon_danger<=4 then 3
              when dungeon_danger<=6 then 4
              when dungeon_danger<=8 then 5
              else 6
            end)*12
        end
      );

      member_reward_exp:=greatest(
        0,
        round(member_reward_exp
          *private.dungeon_repeat_xp_multiplier_percent(
            member_row.character_id,run_row.sector_id,null,run_row.id
          )/100.0
        )::integer
      );
      member_reward_gold:=greatest(
        1,
        round(member_reward_gold
          *private.dungeon_repeat_gold_multiplier_percent(
            member_row.character_id,run_row.sector_id,null,run_row.id
          )/100.0
        )::integer
      );

      if coalesce(member_row.reward_exhausted,false) then
        member_reward_exp:=0;
        member_reward_gold:=0;
      end if;

      update public.character_progress
      set gold=gold+member_reward_gold,
          experience=experience+member_reward_exp,
          hp_regen_anchor_at=now(),
          mana_regen_anchor_at=now(),
          updated_at=now()
      where character_id=member_row.character_id;

      insert into public.character_sector_site_progress(
        character_id,sector_id,site_type,status,
        first_interacted_at,completed_at,updated_at
      )
      values(
        member_row.character_id,run_row.sector_id,'dungeon','cleared',
        run_row.started_at,now(),now()
      )
      on conflict(character_id,sector_id) do update
      set site_type='dungeon',
          status='cleared',
          completed_at=now(),
          updated_at=now();
    end loop;

    chest_drops:=private.roll_party_dungeon_completion_loot(run_row.id);

    insert into public.party_combat_turns(
      encounter_id,round,actor_type,action_type,damage,message
    )
    values(
      encounter.id,encounter.round,'system','dungeon_victory',0,
      case
        when dungeon_danger=0 then
          'Подземелье 0 уровня зачищено. Каждый участник получает 40 золота; опыт зависит от уровня персонажа: LVL 1 = 15, LVL 2 = 11, LVL 3 = 6, LVL 4 = 2, LVL 5+ = 1.'
        else
          'Подземелье зачищено всей группой. Награда каждого участника масштабируется по его уровню относительно сложности данжа; минимум — 35% золота и 5% опыта.'
      end
      ||case
        when exists(
          select 1 from public.party_dungeon_run_members x
          where x.run_id=run_row.id and coalesce(x.reward_exhausted,false)
        )
        then ' Участники, превысившие 25 попыток в текущем 18-часовом цикле, не получают опыт, золото и личный лут.'
        else ''
      end
      ||case when chest_drops>0 then ' В финальном тайнике выпало предметов: '||chest_drops||'.' else '' end
    );
  else
    update public.party_dungeon_runs
    set current_stage='room_'||(cleared_rooms+1)||'_ready',
        rooms_cleared=cleared_rooms
    where id=run_row.id;

    insert into public.party_combat_turns(
      encounter_id,round,actor_type,action_type,damage,message
    )
    values(
      encounter.id,encounter.round,'system','room_victory',0,
      'Зал '||cleared_rooms||' очищен группой. Впереди ещё '
      ||(run_row.total_rooms-cleared_rooms)||'.'
      ||case when room_drops>0 then ' Личная добыча уже добавлена в инвентари.' else '' end
    );
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_character_adventures_v4(p_character_id uuid)
 RETURNS TABLE(sector_id smallint, title text, content_type text, site_status text, active_run_id uuid, run_status text, run_stage text, run_started_at timestamp with time zone, run_rooms_cleared integer, run_total_rooms integer, run_reward_gold integer, run_reward_experience integer, run_escape_attempt_stage integer, is_event_boss boolean, run_reward_exhausted boolean, run_reward_attempt_number integer, run_reward_cycle_ends_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  if not private.is_gm(caller)
     and not exists(
       select 1 from public.characters c
       where c.id=p_character_id and c.owner_user_id=caller
     )
  then raise exception 'CHARACTER_NOT_OWNED'; end if;

  perform private.complete_expired_sector_expeditions(p_character_id);
  perform private.complete_expired_site_actions(p_character_id);

  return query
  with normal_sites as (
    select
      d.sector_id,
      coalesce(sd.title,'Сектор '||s.grid_col||':'||s.grid_row)::text title,
      sd.content_type::text content_type,
      p.status::text site_status,
      r.id active_run_id,
      r.status::text run_status,
      r.current_stage::text run_stage,
      r.started_at run_started_at,
      r.rooms_cleared run_rooms_cleared,
      r.total_rooms run_total_rooms,
      r.reward_gold run_reward_gold,
      r.reward_experience run_reward_experience,
      r.escape_attempt_stage run_escape_attempt_stage,
      false is_event_boss,
      coalesce(r.reward_exhausted,false) run_reward_exhausted,
      r.reward_attempt_number run_reward_attempt_number,
      r.reward_cycle_ends_at run_reward_cycle_ends_at,
      d.discovered_at sort_at,
      case when r.status='active' then 0 else 1 end sort_active
    from public.character_sector_discoveries d
    join public.map_sectors s on s.id=d.sector_id
    join public.sector_details sd on sd.sector_id=d.sector_id
    left join public.character_sector_site_progress p
      on p.character_id=d.character_id and p.sector_id=d.sector_id
    left join lateral(
      select dr.*
      from public.dungeon_runs dr
      where dr.character_id=d.character_id
        and dr.sector_id=d.sector_id
        and dr.event_boss_id is null
        and dr.hunting_attempt_id is null
      order by (dr.status='active') desc,dr.created_at desc
      limit 1
    ) r on true
    where d.character_id=p_character_id
      and sd.content_type in ('ruins','dungeon')
  ),
  latest_hunt as (
    select
      dr.sector_id,
      ('Охота · '||coalesce(ce.enemy_name,'сильный монстр'))::text title,
      'hunting'::text content_type,
      dr.status::text site_status,
      dr.id active_run_id,
      dr.status::text run_status,
      dr.current_stage::text run_stage,
      dr.started_at run_started_at,
      dr.rooms_cleared run_rooms_cleared,
      dr.total_rooms run_total_rooms,
      0::integer run_reward_gold,
      0::integer run_reward_experience,
      null::integer run_escape_attempt_stage,
      false is_event_boss,
      false run_reward_exhausted,
      null::integer run_reward_attempt_number,
      null::timestamptz run_reward_cycle_ends_at,
      dr.created_at sort_at,
      case when dr.status='active' then 0 else 1 end sort_active
    from public.dungeon_runs dr
    left join lateral(
      select ce2.*
      from public.combat_encounters ce2
      where ce2.dungeon_run_id=dr.id
      order by ce2.created_at desc
      limit 1
    ) ce on true
    where dr.character_id=p_character_id
      and dr.hunting_attempt_id is not null
    order by (dr.status='active') desc,dr.created_at desc
    limit 1
  ),
  latest_event as (
    select
      (-1)::smallint sector_id,
      e.name::text title,
      'event_boss'::text content_type,
      dr.status::text site_status,
      dr.id active_run_id,
      dr.status::text run_status,
      dr.current_stage::text run_stage,
      dr.started_at run_started_at,
      dr.rooms_cleared run_rooms_cleared,
      dr.total_rooms run_total_rooms,
      dr.reward_gold run_reward_gold,
      dr.reward_experience run_reward_experience,
      null::integer run_escape_attempt_stage,
      true is_event_boss,
      false run_reward_exhausted,
      null::integer run_reward_attempt_number,
      null::timestamptz run_reward_cycle_ends_at,
      dr.created_at sort_at,
      case when dr.status='active' then 0 else 1 end sort_active
    from public.dungeon_runs dr
    join public.event_boss_events e on e.id=dr.event_boss_id
    where dr.character_id=p_character_id
      and dr.event_boss_id is not null
    order by (dr.status='active') desc,dr.created_at desc
    limit 1
  )
  select
    x.sector_id,x.title,x.content_type,x.site_status,x.active_run_id,x.run_status,
    x.run_stage,x.run_started_at,x.run_rooms_cleared,x.run_total_rooms,
    x.run_reward_gold,x.run_reward_experience,x.run_escape_attempt_stage,x.is_event_boss,
    x.run_reward_exhausted,x.run_reward_attempt_number,x.run_reward_cycle_ends_at
  from (
    select * from normal_sites
    union all
    select * from latest_hunt
    union all
    select * from latest_event
  ) x
  order by x.sort_active,x.sort_at desc;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_party_dungeon_state(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid:=auth.uid();
  v_run_id uuid;
  v_encounter_id uuid;
  result jsonb;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id
      and c.owner_user_id=caller_id
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select pr.id into v_run_id
  from public.party_dungeon_runs pr
  join public.party_dungeon_run_members prm on prm.run_id=pr.id
  where prm.character_id=p_character_id
  order by (pr.status='active') desc,pr.created_at desc
  limit 1;

  if v_run_id is null then
    return jsonb_build_object(
      'run',null,
      'encounter',null,
      'members','[]'::jsonb,
      'statuses','[]'::jsonb,
      'turns','[]'::jsonb,
      'loot','[]'::jsonb,
      'sacrifice_scroll_count',coalesce((
        select sum(ci.quantity)::integer
        from public.character_items ci
        join public.item_definitions idf on idf.id=ci.item_definition_id
        where ci.character_id=p_character_id
          and idf.slug='combat_scroll_last_sacrifice'
      ),0)
    );
  end if;

  select ce.id into v_encounter_id
  from public.party_combat_encounters ce
  where ce.run_id=v_run_id
  order by (ce.status='active') desc,ce.room_index desc,ce.created_at desc
  limit 1;

  select jsonb_build_object(
    'sacrifice_scroll_count',coalesce((
      select sum(ci.quantity)::integer
      from public.character_items ci
      join public.item_definitions idf on idf.id=ci.item_definition_id
      where ci.character_id=p_character_id
        and idf.slug='combat_scroll_last_sacrifice'
    ),0),
    'run',(
      select jsonb_build_object(
        'id',pr.id,
        'party_id',pr.party_id,
        'leader_character_id',pr.leader_character_id,
        'sector_id',pr.sector_id,
        'title',coalesce((select ebe.name from public.event_boss_events ebe where ebe.id=pr.event_boss_id),coalesce(sd.title,'Подземелье')),
        'is_event_boss',pr.event_boss_id is not null,
        'event_boss_id',pr.event_boss_id,
        'danger_level',sd.danger_level,
        'status',pr.status,
        'current_stage',pr.current_stage,
        'rooms_cleared',pr.rooms_cleared,
        'total_rooms',pr.total_rooms,
        'reward_gold',pr.reward_gold,
        'reward_experience',pr.reward_experience,
        'member_count',pr.member_count,
        'escape_attempt_stage',pr.escape_attempt_stage,
        'started_at',pr.started_at,
        'sacrifice_scroll_used',pr.sacrifice_scroll_used
      )
      from public.party_dungeon_runs pr
      join public.sector_details sd on sd.sector_id=pr.sector_id
      where pr.id=v_run_id
    ),
    'encounter',case when v_encounter_id is null then null else (
      select jsonb_build_object(
        'id',ce.id,
        'room_index',ce.room_index,
        'is_boss',ce.is_boss,
        'status',ce.status,
        'round',ce.round,
        'enemy_name',ce.enemy_name,
        'enemy_level',ce.enemy_level,
        'enemy_hp_current',ce.enemy_hp_current,
        'enemy_hp_max',ce.enemy_hp_max,
        'enemy_attack',ce.enemy_attack,
        'enemy_defense',ce.enemy_defense,
        'enemy_damage_type',ce.enemy_damage_type,
        'enemy_bloodshed_stacks',ce.enemy_bloodshed_stacks,
        'acted_character_ids',to_jsonb(ce.acted_character_ids),
        'created_at',ce.created_at,
        'ended_at',ce.ended_at
      )
      from public.party_combat_encounters ce
      where ce.id=v_encounter_id
    ) end,
    'members',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'character_id',c.id,
          'name',c.name,
          'display_name',pf.display_name,
          'race',c.race,
          'level',cp.level,
          'hp_current',case when prm.lost then 0 when prm.dead and ms.character_id is null then 1 else coalesce(ms.hp_current,cp.hp_current) end,
          'hp_max',coalesce(ms.hp_max,cp.hp_max),
          'mana_current',coalesce(ms.mana_current,cp.mana_current),
          'mana_max',coalesce(ms.mana_max,cp.mana_max),
          'downed',case when prm.lost then true else coalesce(ms.downed,prm.dead) end,
          'dead',prm.dead,
          'lost',prm.lost,
          'lost_reason',prm.lost_reason,
          'incoming_damage_reduction_percent',coalesce(ms.incoming_damage_reduction_percent,0),
          'incoming_damage_reduction_rounds',coalesce(ms.incoming_damage_reduction_rounds,0),
          'guard_percent',coalesce(ms.guard_percent,0),
          'damage_bonus_percent',coalesce(ms.damage_bonus_percent,0),
          'damage_bonus_hits',coalesce(ms.damage_bonus_hits,0),
          'taunt_chance',coalesce(ms.taunt_chance,0),
          'bow_distance',coalesce(ms.bow_distance,'medium'),
          'bow_draw_pending',coalesce(ms.bow_draw_pending,false),
          'acted',case
            when ce.id is null then false
            else c.id=any(ce.acted_character_ids)
          end,
          'is_leader',(c.id=pr.leader_character_id),
          'joined_order',prm.joined_order,
          'reward_exhausted',coalesce(prm.reward_exhausted,false),
          'reward_attempt_number',prm.reward_attempt_number,
          'reward_cycle_ends_at',prm.reward_cycle_ends_at
        )
        order by prm.joined_order
      )
      from public.party_dungeon_run_members prm
      join public.party_dungeon_runs pr on pr.id=prm.run_id
      join public.characters c on c.id=prm.character_id
      join public.profiles pf on pf.user_id=c.owner_user_id
      join public.character_progress cp on cp.character_id=c.id
      left join public.party_combat_encounters ce on ce.id=v_encounter_id
      left join public.party_combat_member_states ms
        on ms.encounter_id=ce.id
       and ms.character_id=c.id
      where prm.run_id=v_run_id
    ),'[]'::jsonb),
    'statuses',case when v_encounter_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',se.id,
        'target_type',se.target_type,
        'target_character_id',se.target_character_id,
        'effect_type',se.effect_type,
        'potency',se.potency,
        'remaining_turns',se.remaining_turns,
        'source',se.source
      ) order by se.id)
      from public.party_combat_status_effects se
      where se.encounter_id=v_encounter_id
    ),'[]'::jsonb) end,
    'turns',case when v_encounter_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(to_jsonb(x) order by x.id desc)
      from (
        select
          t.id,t.round,t.actor_type,t.actor_character_id,t.target_character_id,
          t.action_type,t.damage,t.message,t.created_at
        from public.party_combat_turns t
        where t.encounter_id=v_encounter_id
        order by t.id desc
        limit 30
      ) x
    ),'[]'::jsonb) end,
    'loot',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',pl.id,
          'source_type',pl.source_type,
          'item_definition_id',pl.item_definition_id,
          'item_name',idf.name,
          'rarity',idf.rarity::text,
          'quantity',pl.quantity,
          'created_at',pl.created_at
        )
        order by pl.created_at desc
      )
      from public.party_loot_drops pl
      join public.item_definitions idf on idf.id=pl.item_definition_id
      where pl.run_id=v_run_id
        and pl.character_id=p_character_id
    ),'[]'::jsonb)
  ) into result;

  return result;
end;
$function$;


revoke all on function private.consume_dungeon_reward_attempt(uuid,smallint) from public,anon,authenticated;
revoke all on function public.get_character_adventures_v4(uuid) from public,anon;
grant execute on function public.get_character_adventures_v4(uuid) to authenticated;

drop function if exists private.active_dungeon_exhaustion_until(uuid,smallint);
drop function if exists private.arm_dungeon_exhaustion_if_needed(uuid,smallint);
drop function if exists private.dungeon_attempt_count_24h(uuid,smallint);
drop table if exists private.dungeon_exhaustion_locks;
