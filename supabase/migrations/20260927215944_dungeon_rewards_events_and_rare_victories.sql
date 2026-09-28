-- Synced from live Supabase migration 20260927215944 (dungeon_rewards_events_and_rare_victories)

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
  created_event uuid;
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

  if run_row.modifier_slug is not null then
    actual_reward_exp:=greatest(
      0,
      round(actual_reward_exp*(100+private.dungeon_modifier_value(run_row.modifier_slug,'reward_xp_percent'))/100.0)::integer
    );
    actual_reward_gold:=greatest(
      1,
      round(actual_reward_gold*(100+private.dungeon_modifier_value(run_row.modifier_slug,'reward_gold_percent'))/100.0)::integer
    );
  end if;

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

  if encounter.is_boss and exists(
    select 1 from public.enemy_templates et
    where et.id=encounter.enemy_template_id and et.is_rare_variant
  ) then
    perform private.record_discovery(
      encounter.character_id,
      'rare_boss_victory',
      (select slug from public.enemy_templates where id=encounter.enemy_template_id),
      'Побеждён: '||encounter.enemy_name,
      'Редкий хранитель подземелья был побеждён.',
      jsonb_build_object('sector_id',encounter.sector_id,'run_id',run_row.id)
    );
  end if;

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

    created_event:=private.maybe_create_dungeon_event(run_row.id,cleared_rooms);

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      encounter.id,p_round,'system','room_victory',0,p_player_hp,0,
      'Зал '||cleared_rooms||' очищен. Впереди ещё '
      ||(run_row.total_rooms-cleared_rooms)||'.'
      ||case
        when created_event is not null
        then ' Между залами произошло событие — выбери решение в «Приключениях».'
        else ''
      end
    );
  end if;

  delete from public.combat_status_effects where encounter_id=encounter.id;
  return encounter;
end;
$function$;
