-- Synced from live Supabase migration 20260927220004 (party_modifier_rewards_and_rare_victories)

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

      if run_row.modifier_slug is not null then
        member_reward_exp:=greatest(
          0,
          round(member_reward_exp*(100+private.dungeon_modifier_value(run_row.modifier_slug,'reward_xp_percent'))/100.0)::integer
        );
        member_reward_gold:=greatest(
          1,
          round(member_reward_gold*(100+private.dungeon_modifier_value(run_row.modifier_slug,'reward_gold_percent'))/100.0)::integer
        );
      end if;

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

      if encounter.is_boss and exists(
        select 1 from public.enemy_templates et
        where et.id=encounter.enemy_template_id and et.is_rare_variant
      ) then
        perform private.record_discovery(
          member_row.character_id,
          'rare_boss_victory',
          (select slug from public.enemy_templates where id=encounter.enemy_template_id),
          'Побеждён: '||encounter.enemy_name,
          'Редкий хранитель подземелья был побеждён группой.',
          jsonb_build_object('sector_id',run_row.sector_id,'run_id',run_row.id,'party',true)
        );
      end if;

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
