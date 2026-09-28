-- Synced from live Supabase migration 20260928202819 (modernize_event_boss_party_state_and_messages)

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
        'event_boss',case when pr.event_boss_id is null then null else (
          select jsonb_build_object(
            'boss_kind',ebe.boss_kind,
            'name',ebe.name,
            'description',ebe.description,
            'recommended_level',ebe.recommended_level,
            'ends_at',ebe.ends_at,
            'special_every_n',ebe.special_every_n,
            'phase2_hp_percent',ebe.phase2_hp_percent,
            'special_name',coalesce(et.special_name,'Особый приём'),
            'phase2_name',coalesce(et.phase2_name,'Вторая фаза'),
            'reward_material_name',rm.name,
            'reward_material_quantity',ebe.reward_material_quantity,
            'first_reward_gold',ebe.first_reward_gold,
            'first_reward_experience',ebe.first_reward_experience,
            'repeat_reward_gold',ebe.repeat_reward_gold,
            'repeat_reward_experience',ebe.repeat_reward_experience
          )
          from public.event_boss_events ebe
          left join public.enemy_templates et on et.id=ebe.enemy_template_id
          left join public.item_definitions rm on rm.id=ebe.reward_material_item_id
          where ebe.id=pr.event_boss_id
        ) end,
        'danger_level',sd.danger_level,
        'modifier',case when pr.modifier_slug is null then null else (
          select jsonb_build_object(
            'slug',m.slug,
            'name',m.name,
            'description',m.description,
            'theme',m.theme,
            'enemy_hp_percent',m.enemy_hp_percent,
            'enemy_attack_percent',m.enemy_attack_percent,
            'enemy_defense_percent',m.enemy_defense_percent,
            'reward_gold_percent',m.reward_gold_percent,
            'reward_xp_percent',m.reward_xp_percent
          )
          from public.dungeon_modifier_definitions m
          where m.slug=pr.modifier_slug
        ) end,
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
        'is_rare_variant',exists(
          select 1 from public.enemy_templates et
          where et.id=ce.enemy_template_id and et.is_rare_variant
        ),
        'status',ce.status,
        'round',ce.round,
        'enemy_name',ce.enemy_name,
        'enemy_level',ce.enemy_level,
        'enemy_hp_current',ce.enemy_hp_current,
        'enemy_hp_max',ce.enemy_hp_max,
        'enemy_attack',ce.enemy_attack,
        'enemy_defense',ce.enemy_defense,
        'enemy_initiative',ce.enemy_initiative,
        'enemy_damage_type',ce.enemy_damage_type,
        'enemy_resistances',ce.enemy_resistances,
        'enemy_danger_pending',coalesce((ce.enemy_ai_state->>'danger_pending')::boolean,false),
        'enemy_bloodshed_stacks',ce.enemy_bloodshed_stacks,
        'acted_character_ids',to_jsonb(ce.acted_character_ids),
        'next_actor_character_id',private.party_next_actor_id(ce.id),
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
          'initiative',combat_stats.initiative,
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
          'reflect_percent',coalesce(ms.reflect_percent,0),
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
          'initiative_meter',coalesce(ms.initiative_meter,0),
          'reward_exhausted',coalesce(prm.reward_exhausted,false),
          'reward_attempt_number',prm.reward_attempt_number,
          'reward_cycle_ends_at',prm.reward_cycle_ends_at
        )
        order by combat_stats.initiative desc, prm.joined_order
      )
      from public.party_dungeon_run_members prm
      join public.party_dungeon_runs pr on pr.id=prm.run_id
      join public.characters c on c.id=prm.character_id
      join public.profiles pf on pf.user_id=c.owner_user_id
      join public.character_progress cp on cp.character_id=c.id
      cross join lateral private.get_character_combat_stats(c.id) combat_stats
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
$function$
;

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
        else 'Босс «'||coalesce((select ebe.name from public.event_boss_events ebe where ebe.id=run_row.event_boss_id),encounter.enemy_name)||'» повержен. Личная награда каждого участника рассчитана отдельно; повторный вклад одного и того же персонажа не засчитывается.'
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
$function$
;

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
      'Босс «'||coalesce((select ebe.name from public.event_boss_events ebe where ebe.id=run_row.event_boss_id),encounter.enemy_name)||'» повержен. Награда: '||(event_reward->>'gold')||' золота и '||(event_reward->>'experience')||' опыта.'
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

  if encounter.is_elite_room and not coalesce(run_row.reward_exhausted,false) then
    perform private.grant_character_item(
      encounter.character_id,
      (select id from public.item_definitions where slug='ancient_coin_cache'),
      1,
      jsonb_build_object(
        'source','elite_room',
        'dungeon_run_id',run_row.id,
        'combat_encounter_id',encounter.id
      )
    );

    insert into public.loot_drops(
      character_id,dungeon_run_id,combat_encounter_id,source_type,item_definition_id,quantity
    )
    select
      encounter.character_id,run_row.id,encounter.id,'enemy',i.id,1
    from public.item_definitions i
    where i.slug='ancient_coin_cache';

    room_drop_count:=room_drop_count+1;

    perform private.record_discovery(
      encounter.character_id,
      'elite_room',
      'elite_room_'||encounter.id::text,
      'Опасная комната',
      'Ты принял вызов запечатанной арены и победил усиленного противника.',
      jsonb_build_object('run_id',run_row.id,'sector_id',encounter.sector_id)
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
$function$
;

CREATE OR REPLACE FUNCTION public.start_event_boss(p_character_id uuid, p_event_id uuid, p_mode text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
  event_row public.event_boss_events;
  template public.enemy_templates;
  stats record;
  solo_run public.dungeon_runs;
  solo_encounter public.combat_encounters;
  party_row public.parties;
  party_run public.party_dungeon_runs;
  party_encounter_id uuid;
  member_row public.party_members;
  run_member public.party_dungeon_run_members;
  party_size integer:=0;
  enemy_hp integer;
  enemy_attack integer;
  enemy_defense integer;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_mode not in ('solo','party') then raise exception 'INVALID_EVENT_BOSS_MODE'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select * into event_row
  from public.event_boss_events
  where id=p_event_id
    and enabled=true
    and now()>=starts_at
    and now()<ends_at
  for update;

  if event_row.id is null then raise exception 'EVENT_BOSS_NOT_ACTIVE'; end if;

  if event_row.boss_kind='sector_incursion' then
    event_row.solo_hp:=greatest(1,ceil(event_row.solo_hp*1.15)::integer);
    event_row.solo_attack:=greatest(1,ceil(event_row.solo_attack*1.08)::integer);
    event_row.solo_defense:=greatest(0,ceil(event_row.solo_defense*1.10)::integer);
    event_row.solo_initiative:=greatest(0,ceil(event_row.solo_initiative*1.05)::integer);
  end if;

  if p_mode='party'
     and lower(coalesce(event_row.mechanics->>'party_disabled','false')) in ('true','1','yes')
  then
    raise exception 'EVENT_BOSS_PARTY_DISABLED';
  end if;

  if event_row.sector_id is not null
     and not exists(
       select 1
       from public.character_sector_discoveries d
       where d.character_id=p_character_id
         and d.sector_id=event_row.sector_id
     )
  then
    raise exception 'EVENT_BOSS_SECTOR_NOT_DISCOVERED';
  end if;

  if p_mode='solo'
     and event_row.max_victories_per_character is not null
     and event_row.boss_kind<>'world_enemy'
     and coalesce((
       select c.victories
       from public.event_boss_completions c
       where c.event_id=event_row.id
         and c.character_id=p_character_id
     ),0) >= event_row.max_victories_per_character
  then
    raise exception 'EVENT_BOSS_CHARACTER_LIMIT_REACHED';
  end if;

  select * into template
  from public.enemy_templates
  where id=event_row.enemy_template_id;

  if template.id is null then raise exception 'EVENT_BOSS_TEMPLATE_NOT_FOUND'; end if;

  if p_mode='solo' then
    if private.character_blocked_for_event_boss(p_character_id) then
      raise exception 'CHARACTER_BUSY';
    end if;

    perform private.apply_passive_hp_regen(p_character_id);
    perform private.apply_passive_mana_regen(p_character_id);

    select * into stats
    from private.get_character_combat_stats(p_character_id);

    if stats.level is null then raise exception 'CHARACTER_PROGRESS_NOT_FOUND'; end if;
    if stats.hp_current<=0 then raise exception 'CHARACTER_HAS_NO_HP'; end if;

    insert into public.dungeon_runs(
      character_id,sector_id,status,current_stage,rooms_cleared,total_rooms,
      reward_gold,reward_experience,event_boss_id
    )
    values(
      p_character_id,coalesce(event_row.sector_id,131::smallint),'active','event_boss_combat',0,1,0,0,event_row.id
    )
    returning * into solo_run;

    insert into public.combat_encounters(
      dungeon_run_id,character_id,sector_id,status,round,room_index,is_boss,
      enemy_template_id,enemy_name,enemy_level,enemy_hp_current,enemy_hp_max,
      enemy_attack,enemy_defense,enemy_initiative,enemy_damage_type,enemy_resistances,
      enemy_on_hit_effect_type,enemy_on_hit_effect_chance,
      enemy_on_hit_effect_turns,enemy_on_hit_effect_potency,
      enemy_special_name,enemy_special_damage_multiplier,enemy_special_every_n,
      enemy_special_damage_type,enemy_special_effect_type,enemy_special_effect_chance,
      enemy_special_effect_turns,enemy_special_effect_potency,
      enemy_special_telegraph_text,enemy_special_attack_text,
      enemy_special_kind,enemy_special_value,
      enemy_phase2_hp_percent,enemy_phase2_name,
      enemy_phase2_attack_bonus_percent,enemy_phase2_defense_bonus_percent,
      enemy_phase2_special_every_n,enemy_abilities,enemy_ai_state,
      player_physical_damage_type,player_magic_damage_type,
      player_hp_current,player_hp_max,player_mana_current,player_mana_max
    )
    values(
      solo_run.id,p_character_id,coalesce(event_row.sector_id,131::smallint),'active',0,1,true,
      template.id,event_row.name,event_row.solo_enemy_level,event_row.solo_hp,event_row.solo_hp,
      event_row.solo_attack,event_row.solo_defense,event_row.solo_initiative,
      template.attack_damage_type,template.damage_resistances,
      template.on_hit_effect_type,template.on_hit_effect_chance,
      template.on_hit_effect_turns,template.on_hit_effect_potency,
      template.special_name,template.special_damage_multiplier,template.special_every_n,
      template.special_damage_type,template.special_effect_type,template.special_effect_chance,
      template.special_effect_turns,template.special_effect_potency,
      template.special_telegraph_text,template.special_attack_text,
      template.special_kind,template.special_value,
      template.phase2_hp_percent,template.phase2_name,
      template.phase2_attack_bonus_percent,template.phase2_defense_bonus_percent,
      template.phase2_special_every_n,template.abilities,'{}'::jsonb,
      stats.weapon_damage_type,stats.magic_damage_type,
      stats.hp_current,stats.hp_max,stats.mana_current,stats.mana_max
    )
    returning * into solo_encounter;

    update public.character_progress
    set hp_regen_anchor_at=now(),mana_regen_anchor_at=now()
    where character_id=p_character_id;

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      solo_encounter.id,0,'system','event_boss_start',0,
      stats.hp_current,event_row.solo_hp,
      case
        when event_row.boss_kind='sector_incursion'
          then 'Захваченный сектор: '||event_row.name||'. '
        when event_row.boss_kind='world_enemy'
          then 'Сильный враг: '||event_row.name||'. '
        else 'Временная угроза: '||event_row.name||'. '
      end
      ||'Рекомендуемый уровень: '||event_row.recommended_level||'.'
    );

    return jsonb_build_object(
      'mode','solo',
      'event_id',event_row.id,
      'run_id',solo_run.id,
      'encounter_id',solo_encounter.id
    );
  end if;

  select p.* into party_row
  from public.parties p
  join public.party_members pm on pm.party_id=p.id
  where pm.character_id=p_character_id
    and p.status='active'
  for update of p;

  if party_row.id is null then raise exception 'PARTY_NOT_FOUND'; end if;
  if party_row.leader_character_id<>p_character_id then raise exception 'PARTY_LEADER_REQUIRED'; end if;

  select count(*)::integer into party_size
  from public.party_members
  where party_id=party_row.id;

  if party_size<2 then raise exception 'PARTY_NEEDS_TWO_MEMBERS'; end if;
  if party_size>4 then raise exception 'PARTY_TOO_LARGE'; end if;

  if exists(
    select 1 from public.party_dungeon_runs
    where party_id=party_row.id and status='active'
  ) then raise exception 'PARTY_DUNGEON_ALREADY_ACTIVE'; end if;

  for member_row in
    select pm.*
    from public.party_members pm
    where pm.party_id=party_row.id
    order by (pm.character_id=party_row.leader_character_id) desc,pm.joined_at,pm.character_id
  loop
    if event_row.sector_id is not null
       and not exists(
         select 1 from public.character_sector_discoveries d
         where d.character_id=member_row.character_id
           and d.sector_id=event_row.sector_id
       )
    then
      raise exception 'PARTY_MEMBER_SECTOR_NOT_DISCOVERED:%',member_row.character_id;
    end if;

    if private.character_blocked_for_event_boss(member_row.character_id) then
      raise exception 'PARTY_MEMBER_BUSY:%',member_row.character_id;
    end if;
    perform private.apply_passive_hp_regen(member_row.character_id);
    perform private.apply_passive_mana_regen(member_row.character_id);
  end loop;

  enemy_hp:=greatest(
    1,
    round(event_row.solo_hp*(1+event_row.party_hp_per_extra*(party_size-1)))::integer
  );
  enemy_attack:=greatest(
    1,
    round(event_row.solo_attack*(1+event_row.party_attack_per_extra*(party_size-1)))::integer
  );
  enemy_defense:=greatest(
    0,
    round(event_row.solo_defense*(1+event_row.party_defense_per_extra*(party_size-1)))::integer
  );

  insert into public.party_dungeon_runs(
    party_id,leader_character_id,sector_id,status,current_stage,rooms_cleared,total_rooms,
    reward_gold,reward_experience,member_count,event_boss_id
  )
  values(
    party_row.id,p_character_id,coalesce(event_row.sector_id,131::smallint),'active','event_boss_combat',
    0,1,0,0,party_size,event_row.id
  )
  returning * into party_run;

  insert into public.party_dungeon_run_members(run_id,character_id,joined_order)
  select
    party_run.id,
    pm.character_id,
    row_number() over(
      order by (pm.character_id=party_row.leader_character_id) desc,pm.joined_at,pm.character_id
    )::smallint
  from public.party_members pm
  where pm.party_id=party_row.id;

  insert into public.party_combat_encounters(
    run_id,room_index,is_boss,status,round,
    enemy_template_id,enemy_name,enemy_level,
    enemy_hp_current,enemy_hp_max,enemy_attack,enemy_defense,enemy_initiative,
    enemy_damage_type,enemy_resistances,
    enemy_on_hit_effect_type,enemy_on_hit_effect_chance,
    enemy_on_hit_effect_turns,enemy_on_hit_effect_potency
  )
  values(
    party_run.id,1,true,'active',1,
    template.id,event_row.name,event_row.solo_enemy_level,
    enemy_hp,enemy_hp,enemy_attack,enemy_defense,event_row.solo_initiative,
    template.attack_damage_type,template.damage_resistances,
    template.on_hit_effect_type,template.on_hit_effect_chance,
    template.on_hit_effect_turns,template.on_hit_effect_potency
  )
  returning id into party_encounter_id;

  for run_member in
    select *
    from public.party_dungeon_run_members
    where run_id=party_run.id
    order by joined_order
  loop
    select * into stats
    from private.get_character_combat_stats(run_member.character_id);

    if stats.level is null then raise exception 'CHARACTER_PROGRESS_NOT_FOUND'; end if;
    if stats.hp_current<=0 then raise exception 'PARTY_MEMBER_HAS_NO_HP:%',run_member.character_id; end if;

    insert into public.party_combat_member_states(
      encounter_id,character_id,hp_current,hp_max,mana_current,mana_max,
      downed,guard_percent,taunt_chance
    )
    values(
      party_encounter_id,run_member.character_id,
      stats.hp_current,stats.hp_max,stats.mana_current,stats.mana_max,
      false,0,private.character_taunt_chance(run_member.character_id)
    );

    update public.character_progress
    set hp_regen_anchor_at=now(),mana_regen_anchor_at=now()
    where character_id=run_member.character_id;
  end loop;

  insert into public.party_combat_turns(
    encounter_id,round,actor_type,action_type,damage,message
  )
  values(
    party_encounter_id,1,'system','event_boss_start',0,
    case
      when event_row.boss_kind='sector_incursion'
        then 'Группа начинает зачистку захваченного сектора: '||event_row.name||'. '
      else 'Группа вступает в бой с боссом «'||event_row.name||'». '
    end
    ||'У каждого участника по одному действию за раунд.'
  );

  return jsonb_build_object(
    'mode','party',
    'event_id',event_row.id,
    'run_id',party_run.id,
    'encounter_id',party_encounter_id,
    'party_size',party_size,
    'enemy_hp',enemy_hp,
    'enemy_attack',enemy_attack,
    'enemy_defense',enemy_defense
  );
end;
$function$
;
