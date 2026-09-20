CREATE OR REPLACE FUNCTION private.dungeon_base_gold(p_danger integer)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog'
AS $function$
  select case
    when greatest(0,least(10,coalesce(p_danger,0)))=0 then 12
    else
      18
      + greatest(0,least(10,coalesce(p_danger,0)))*16
      + (
        case
          when greatest(0,least(10,coalesce(p_danger,0)))<=2 then 2
          when greatest(0,least(10,coalesce(p_danger,0)))<=4 then 3
          when greatest(0,least(10,coalesce(p_danger,0)))<=6 then 4
          when greatest(0,least(10,coalesce(p_danger,0)))<=8 then 5
          else 6
        end
      )*5
  end;
$function$;

CREATE OR REPLACE FUNCTION private.dungeon_repeat_gold_multiplier_percent(p_character_id uuid, p_sector_id smallint, p_exclude_solo_run uuid DEFAULT NULL::uuid, p_exclude_party_run uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select case private.dungeon_recent_clear_count(
    p_character_id,p_sector_id,p_exclude_solo_run,p_exclude_party_run
  )
    when 0 then 100
    when 1 then 75
    when 2 then 55
    when 3 then 40
    when 4 then 30
    when 5 then 20
    when 6 then 15
    when 7 then 10
    else 5
  end;
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

  reward_gold_value:=private.scaled_dungeon_gold(
    danger,character_level,private.dungeon_base_gold(danger)
  );

  if danger = 0 then
    reward_exp_value := private.dungeon_zero_experience(character_level);
  else
    reward_exp_value := 50 + danger * 45 + room_count * 18;
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

  reward_gold_value:=private.dungeon_base_gold(danger);
  if danger=0 then
    reward_exp_value:=15;
  else
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
        then ' Глобальная угроза полностью устранена.'
          ||case
            when coalesce((event_reward->>'global_bonus_recipients')::integer,0)>0
            then ' Всем участникам с засчитанным вкладом дополнительно выдано 50 золота и 150 опыта.'
            else ''
          end
        else '' end
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
    private.dungeon_base_gold(dungeon_danger)
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
  event_global_resolved boolean:=false;
  event_global_bonus_recipients integer:=0;
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
      event_global_resolved:=event_global_resolved
        or coalesce((event_reward->>'global_resolved')::boolean,false);
      event_global_bonus_recipients:=event_global_bonus_recipients
        +coalesce((event_reward->>'global_bonus_recipients')::integer,0);
    end loop;

    insert into public.party_combat_turns(
      encounter_id,round,actor_type,action_type,damage,message
    ) values(
      encounter.id,encounter.round,'system','event_boss_victory',0,
      case
        when event_global_resolved
        then 'Захваченный сектор полностью освобождён. Каждый новый вклад получает личную награду; всем участникам с засчитанным вкладом дополнительно выдано 50 золота и 150 опыта.'
          ||case when event_global_bonus_recipients>0
            then ' Дополнительную награду получили участников: '||event_global_bonus_recipients||'.'
            else '' end
        else 'Временная угроза побеждена. Вклад каждого участника учитывается отдельно; повторный вклад одного и того же персонажа не засчитывается.'
      end 
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
        private.dungeon_base_gold(dungeon_danger)
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
          'Подземелье 0 уровня зачищено. Базовая награда — 12 золота; опыт зависит от уровня персонажа: LVL 1 = 15, LVL 2 = 11, LVL 3 = 6, LVL 4 = 2, LVL 5+ = 1. Повторные зачистки снижают золото.'
        else
          'Подземелье зачищено всей группой. Награда каждого участника масштабируется по уровню и сложности; повторные зачистки постепенно снижают золото до 5% базовой награды.'
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

revoke all on function private.dungeon_base_gold(integer) from public,anon,authenticated;
revoke all on function private.dungeon_repeat_gold_multiplier_percent(uuid,smallint,uuid,uuid) from public,anon,authenticated;
