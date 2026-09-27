-- Synced from live Supabase migration 20260927212029 (require_final_boss_and_report_autobattle_boss)

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

    perform private.record_battle_reward('solo',run_row.id,encounter.character_id,0,0,'[]'::jsonb);

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

    perform private.record_battle_reward(
      'solo',run_row.id,encounter.character_id,
      coalesce((event_reward->>'gold')::integer,0),
      coalesce((event_reward->>'experience')::integer,0),
      private.event_reward_item_snapshot(event_reward)
    );

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

  if cleared_rooms>=run_row.total_rooms
     and (encounter.room_index<>run_row.total_rooms or not encounter.is_boss)
  then
    raise exception 'DUNGEON_FINAL_ROOM_REQUIRES_BOSS';
  end if;

  is_final_room:=cleared_rooms>=run_row.total_rooms
    and encounter.room_index=run_row.total_rooms
    and encounter.is_boss;

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

    perform private.record_battle_reward(
      'solo',run_row.id,encounter.character_id,actual_reward_gold,actual_reward_exp,'[]'::jsonb
    );

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
      perform private.record_battle_reward(
        'party',run_row.id,member_row.character_id,
        coalesce((event_reward->>'gold')::integer,0),
        coalesce((event_reward->>'experience')::integer,0),
        private.event_reward_item_snapshot(event_reward)
      );
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

  if cleared_rooms>=run_row.total_rooms
     and (encounter.room_index<>run_row.total_rooms or not encounter.is_boss)
  then
    raise exception 'PARTY_DUNGEON_FINAL_ROOM_REQUIRES_BOSS';
  end if;

  is_final:=cleared_rooms>=run_row.total_rooms
    and encounter.room_index=run_row.total_rooms
    and encounter.is_boss;

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

      perform private.record_battle_reward(
        'party',run_row.id,member_row.character_id,member_reward_gold,member_reward_exp,'[]'::jsonb
      );

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

CREATE OR REPLACE FUNCTION public.run_dungeon_autobattle(p_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
  run_row public.dungeon_runs;
  settings public.character_autobattle_settings;
  encounter public.combat_encounters;
  result jsonb;
  total_actions integer:=0;
  hp_percent integer:=100;
  next_room integer;
  next_is_boss boolean;
  boss_defeated boolean:=false;
  boss_name text:=null;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  select r.* into run_row
  from public.dungeon_runs r
  join public.characters c on c.id=r.character_id
  where r.id=p_run_id and c.owner_user_id=caller;

  if run_row.id is null then raise exception 'DUNGEON_RUN_NOT_FOUND'; end if;
  if run_row.status<>'active' then
    return jsonb_build_object(
      'status',run_row.status,
      'reason',run_row.status,
      'actions',0,
      'run_id',run_row.id
    );
  end if;

  settings:=private.ensure_character_autobattle_settings(run_row.character_id);

  loop
    select * into run_row
    from public.dungeon_runs
    where id=p_run_id;

    if run_row.status<>'active' then
      return jsonb_build_object(
        'status',run_row.status,
        'reason',run_row.status,
        'actions',total_actions,
        'rooms_cleared',run_row.rooms_cleared,
        'run_id',run_row.id,
        'boss_defeated',boss_defeated,
        'boss_name',boss_name
      );
    end if;

    select
      case when cp.hp_max<=0 then 0 else floor(cp.hp_current*100.0/cp.hp_max)::integer end
    into hp_percent
    from public.character_progress cp
    where cp.character_id=run_row.character_id;

    if hp_percent<=settings.stop_hp_percent and run_row.rooms_cleared>0 then
      return jsonb_build_object(
        'status','stopped',
        'reason','low_hp_between_rooms',
        'actions',total_actions,
        'rooms_cleared',run_row.rooms_cleared,
        'run_id',run_row.id,
        'hp_percent',hp_percent
      );
    end if;

    next_room:=run_row.rooms_cleared+1;
    next_is_boss:=next_room=run_row.total_rooms;

    if next_is_boss and not settings.include_boss then
      return jsonb_build_object(
        'status','stopped',
        'reason','boss_wait',
        'actions',total_actions,
        'rooms_cleared',run_row.rooms_cleared,
        'run_id',run_row.id
      );
    end if;

    select ce.* into encounter
    from public.combat_encounters ce
    where ce.dungeon_run_id=run_row.id and ce.status='active'
    order by ce.created_at desc
    limit 1;

    if encounter.id is null then
      encounter:=public.start_dungeon_combat(run_row.id);
    end if;

    result:=private.run_combat_autobattle_internal(
      encounter.id,
      least(80,greatest(1,240-total_actions))
    );

    total_actions:=total_actions+coalesce((result->>'actions')::integer,0);

    if coalesce(result->>'status','')='victory' and encounter.is_boss then
      boss_defeated:=true;
      boss_name:=encounter.enemy_name;
    end if;

    if coalesce(result->>'status','')<>'victory' then
      return result||jsonb_build_object(
        'actions',total_actions,
        'rooms_cleared',(
          select rooms_cleared from public.dungeon_runs where id=p_run_id
        ),
        'run_id',p_run_id
      );
    end if;

    if total_actions>=240 then
      return jsonb_build_object(
        'status','stopped',
        'reason','dungeon_action_limit',
        'actions',total_actions,
        'rooms_cleared',(
          select rooms_cleared from public.dungeon_runs where id=p_run_id
        ),
        'run_id',p_run_id
      );
    end if;

    encounter:=null;
  end loop;
end;
$function$;
