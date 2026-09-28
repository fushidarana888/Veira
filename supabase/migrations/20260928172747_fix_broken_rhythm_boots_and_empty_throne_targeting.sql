-- Synced from live Supabase migration 20260928172747 (fix_broken_rhythm_boots_and_empty_throne_targeting)

CREATE OR REPLACE FUNCTION private.advance_party_combat_round(p_encounter_id uuid, p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  encounter public.party_combat_encounters;
  event_row public.event_boss_events;
  event_template public.enemy_templates;
  event_special boolean:=false;
  event_phase_bonus integer:=0;
  event_special_multiplier numeric:=1.0;
  target_state public.party_combat_member_states;
  target_stats record;
  next_acted uuid[];
  active_count integer:=0;
  acted_count integer:=0;
  target_id uuid;
  target_name text;
  target_defense integer:=0;
  variance integer:=0;
  raw_damage integer:=0;
  resistance integer:=0;
  enemy_damage integer:=0;
  reflected_damage integer:=0;
  hp_after integer:=0;
  guard_value integer:=0;
  target_downed boolean:=false;
  all_downed boolean:=false;
  enemy_stunned boolean:=false;
  enemy_reduction integer:=0;
  target_vulnerable integer:=0;
  tick_result jsonb;
  enemy_acted boolean:=false;
  taunt_chance_value integer:=0;
  incoming_reduction integer:=0;
  bloodshed_tick integer:=0;
  target_bow_family text;
  target_bow_dodge integer:=0;
  target_dodged boolean:=false;
  actor_stats record;
  actor_meter integer:=0;
  tempo_gain integer:=0;
  tempo_total integer:=0;
  actor_can_gain_tempo boolean:=false;
  last_actor_action text;
  boss_state jsonb:='{}'::jsonb;
  boss_bonus integer:=0;
  boss_stack integer:=0;
  boss_stored integer:=0;
  boss_shield integer:=0;
  boss_absorb integer:=0;
  boss_blocked integer:=0;
  enemy_damage_before_guard integer:=0;
  redirect_character_id uuid;
  redirect_amount integer:=0;
  redirect_hp integer:=0;
  redirect_name text;
begin
  select * into encounter
  from public.party_combat_encounters
  where id=p_encounter_id
  for update;

  if encounter.id is null then raise exception 'PARTY_COMBAT_NOT_FOUND'; end if;
  if encounter.status<>'active' then raise exception 'PARTY_COMBAT_NOT_ACTIVE'; end if;

  select ebe.* into event_row
  from public.party_dungeon_runs pdr
  join public.event_boss_events ebe on ebe.id=pdr.event_boss_id
  where pdr.id=encounter.run_id;

  if event_row.id is not null then
    select et.* into event_template
    from public.enemy_templates et
    where et.id=event_row.enemy_template_id;


    event_special:=event_row.special_every_n>=2 and mod(encounter.round,event_row.special_every_n)=0;
    event_special_multiplier:=case when event_special then event_row.special_damage_multiplier else 1.0 end;
    event_phase_bonus:=case
      when event_row.phase2_hp_percent>0
       and encounter.enemy_hp_max>0
       and encounter.enemy_hp_current*100<=encounter.enemy_hp_max*event_row.phase2_hp_percent
      then event_row.phase2_attack_bonus_percent
      else 0
    end;
  end if;

  if encounter.enemy_hp_current<=0 then
    perform private.finish_party_combat_victory(encounter.id);
    return jsonb_build_object(
      'status','victory',
      'run_status',(select status from public.party_dungeon_runs where id=encounter.run_id),
      'enemy_hp_current',0
    );
  end if;

  select * into actor_stats
  from private.get_character_combat_stats(p_character_id);

  select coalesce(ms.initiative_meter,0),
         (not ms.downed and not coalesce(prm.lost,false)),
         coalesce(ms.boss_item_state,'{}'::jsonb)
  into actor_meter,actor_can_gain_tempo,boss_state
  from public.party_combat_member_states ms
  left join public.party_dungeon_run_members prm
    on prm.run_id=encounter.run_id
   and prm.character_id=ms.character_id
  where ms.encounter_id=encounter.id
    and ms.character_id=p_character_id
  for update of ms;

  select pct.action_type
  into last_actor_action
  from public.party_combat_turns pct
  where pct.encounter_id=encounter.id
    and pct.actor_character_id=p_character_id
  order by pct.id desc
  limit 1;

  if actor_can_gain_tempo
     and private.character_has_equipped_effect(p_character_id,'untouched_tempo')
     and coalesce((boss_state->>'rhythm_clean')::boolean,false)
  then
    boss_bonus:=greatest(0,private.character_equipped_effect_number(
      p_character_id,'untouched_tempo','initiative_meter_bonus',18
    )::integer);
    actor_meter:=least(99,actor_meter+boss_bonus);
    boss_state:=jsonb_set(boss_state,'{rhythm_clean}','false'::jsonb,true);
    update public.party_combat_member_states
    set initiative_meter=actor_meter,boss_item_state=boss_state,updated_at=now()
    where encounter_id=encounter.id and character_id=p_character_id;
  end if;

  if actor_can_gain_tempo
     and coalesce(last_actor_action,'') not in ('stunned','scroll_last_sacrifice')
  then
    tempo_gain:=private.initiative_tempo_gain(actor_stats.initiative,encounter.enemy_initiative);
    tempo_total:=coalesce(actor_meter,0)+tempo_gain;

    if tempo_total>=100 then
      update public.party_combat_member_states
      set initiative_meter=least(99,tempo_total-100),
          updated_at=now()
      where encounter_id=encounter.id
        and character_id=p_character_id;

      insert into public.party_combat_turns(
        encounter_id,round,actor_type,actor_character_id,action_type,damage,message
      )
      values(
        encounter.id,encounter.round,'system',p_character_id,
        'initiative_extra_action',0,
        'Высокая инициатива продвигает героя по шкале действий: доступно ещё одно полное действие до хода противника.'
      );

      return jsonb_build_object(
        'status','active',
        'enemy_hp_current',encounter.enemy_hp_current,
        'enemy_acted',false,
        'round',encounter.round,
        'extra_action',true,
        'initiative_meter',least(99,tempo_total-100)
      );
    elsif tempo_gain>0 then
      update public.party_combat_member_states
      set initiative_meter=least(99,tempo_total),
          updated_at=now()
      where encounter_id=encounter.id
        and character_id=p_character_id;
    end if;
  end if;

  if p_character_id=any(encounter.acted_character_ids) then
    raise exception 'PARTY_ACTION_ALREADY_USED_THIS_ROUND';
  end if;

  next_acted:=array_append(encounter.acted_character_ids,p_character_id);

  update public.party_combat_encounters
  set acted_character_ids=next_acted
  where id=encounter.id;

  select count(*) into active_count
  from public.party_combat_member_states
  where encounter_id=encounter.id
    and not downed;

  select count(*) into acted_count
  from public.party_combat_member_states
  where encounter_id=encounter.id
    and not downed
    and character_id=any(next_acted);

  if active_count=0 or acted_count<active_count then
    return jsonb_build_object(
      'status','active',
      'enemy_hp_current',encounter.enemy_hp_current,
      'enemy_acted',false,
      'round',encounter.round
    );
  end if;

  update public.party_combat_member_states ms
  set boss_item_state=jsonb_set(coalesce(ms.boss_item_state,'{}'::jsonb),'{rhythm_clean}','true'::jsonb,true),
      updated_at=now()
  where ms.encounter_id=encounter.id
    and not ms.downed
    and exists(
      select 1
      from public.character_equipment ce
      join public.character_items ci on ci.id=ce.character_item_id
      join public.item_definitions i on i.id=ci.item_definition_id
      where ce.character_id=ms.character_id
        and i.unique_effect_type='untouched_tempo'
    );

  if encounter.enemy_bloodshed_stacks>0 then
    bloodshed_tick:=private.bloodshed_damage(encounter.enemy_hp_current,encounter.enemy_bloodshed_stacks);

    update public.party_combat_encounters
    set enemy_hp_current=greatest(0,enemy_hp_current-bloodshed_tick),
        enemy_bloodshed_stacks=0
    where id=encounter.id
    returning * into encounter;

    insert into public.party_combat_turns(
      encounter_id,round,actor_type,action_type,damage,message
    )
    values(
      encounter.id,encounter.round,'system','bloodshed_tick',bloodshed_tick,
      'Кровопролитие срабатывает в начале хода врага и наносит '||bloodshed_tick||' урона.'
    );

    if encounter.enemy_hp_current<=0 then
      perform private.finish_party_combat_victory(encounter.id);
      return jsonb_build_object(
        'status','victory',
        'run_status',(select status from public.party_dungeon_runs where id=encounter.run_id),
        'enemy_hp_current',0
      );
    end if;
  end if;

  enemy_stunned:=private.party_status_stunned(encounter.id,'enemy',null);

  if enemy_stunned then
    insert into public.party_combat_turns(
      encounter_id,round,actor_type,action_type,damage,message
    )
    values(
      encounter.id,encounter.round,'system','enemy_stunned',0,
      encounter.enemy_name||' оглушён и пропускает свою атаку.'
    );
  else
    select coalesce(max(taunt_chance),0) into taunt_chance_value
    from public.party_combat_member_states
    where encounter_id=encounter.id and not downed;

    if taunt_chance_value=0
       and private.try_party_enemy_attack_summon(
         encounter.id,encounter.round,event_phase_bonus,event_special_multiplier
       )
    then
      enemy_acted:=true;
      enemy_damage:=0;
      target_id:=null;
    else
    select coalesce(max(taunt_chance),0) into taunt_chance_value
    from public.party_combat_member_states
    where encounter_id=encounter.id and not downed;

    if taunt_chance_value>0 and floor(random()*100)::integer<taunt_chance_value then
      select character_id into target_id
      from public.party_combat_member_states
      where encounter_id=encounter.id and not downed and taunt_chance>0
      order by random() limit 1;
    else
      select character_id into target_id
      from public.party_combat_member_states
      where encounter_id=encounter.id and not downed and taunt_chance=0
      order by random() limit 1;
      if target_id is null then
        select character_id into target_id
        from public.party_combat_member_states
        where encounter_id=encounter.id and not downed
        order by random() limit 1;
      end if;
    end if;

    select * into target_state
    from public.party_combat_member_states
    where encounter_id=encounter.id
      and character_id=target_id
    for update;

    select * into target_stats
    from private.get_character_combat_stats(target_id);

    boss_state:=coalesce(target_state.boss_item_state,'{}'::jsonb);

    target_defense:=case
      when encounter.enemy_damage_type in ('slashing','piercing','blunt')
        then private.character_physical_defense(target_stats.level,target_stats.vitality,target_stats.agility)
      else private.character_magic_defense(target_stats.level,target_stats.vitality,target_stats.intellect)
    end;
    target_defense:=greatest(
      0,
      round(
        target_defense
        *(
          100
          +private.character_defense_percent(target_id)
          +case
            when encounter.enemy_damage_type in ('slashing','piercing','blunt') then 0
            else private.character_religion_modifier_number(target_id,'magic_defense_percent')
          end
        )
        /100.0
      )::integer
    );

    variance:=private.combat_damage_variance(0);
    enemy_reduction:=private.party_status_reduction(encounter.id,'enemy',null);
    target_vulnerable:=private.party_status_vulnerability(encounter.id,'member',target_id);

    raw_damage:=greatest(
      1,
      private.damage_after_armor(
        round(encounter.enemy_attack
          *(100+event_phase_bonus)/100.0
          *event_special_multiplier)::integer+variance,
        target_defense
      )
    );

    if enemy_reduction>0 then
      raw_damage:=greatest(1,round(raw_damage*(100-enemy_reduction)/100.0)::integer);
    end if;

    resistance:=private.damage_resistance_percent(
      target_stats.damage_resistances,
      encounter.enemy_damage_type
    );

    if private.character_has_equipped_effect(target_id,'adaptive_resist')
       and boss_state->>'adaptive_type'=encounter.enemy_damage_type
       and coalesce((boss_state->>'adaptive_rounds')::integer,0)>0
    then
      resistance:=least(
        75,
        resistance+private.character_equipped_effect_number(
          target_id,'adaptive_resist','resistance_bonus_percent',25
        )::integer
      );
    end if;

    enemy_damage:=greatest(
      1,
      round(raw_damage*(100-resistance)/100.0)::integer
    );

    if target_vulnerable>0 then
      enemy_damage:=greatest(
        1,
        round(enemy_damage*(100+target_vulnerable)/100.0)::integer
      );
    end if;

    if coalesce(target_stats.low_hp_damage_reduction_percent,0)>0
       and target_state.hp_max>0
       and target_state.hp_current*100<=target_state.hp_max*30
    then
      enemy_damage:=greatest(
        1,
        round(enemy_damage*(100-target_stats.low_hp_damage_reduction_percent)/100.0)::integer
      );
    end if;

    if target_state.hp_max>0
       and target_state.hp_current*100<=target_state.hp_max*50
       and private.character_religion_modifier_number(target_id,'low_hp_50_damage_reduction')>0
    then
      enemy_damage:=greatest(
        1,
        round(
          enemy_damage
          *(100-private.character_religion_modifier_number(target_id,'low_hp_50_damage_reduction'))
          /100.0
        )::integer
      );
    end if;

    if enemy_damage>0
       and private.character_religion_modifier_number(target_id,'incoming_damage_taken_percent')>0
    then
      enemy_damage:=greatest(
        1,
        round(
          enemy_damage
          *(100+private.character_religion_modifier_number(target_id,'incoming_damage_taken_percent'))
          /100.0
        )::integer
      );
    end if;

    if enemy_damage>0 and private.character_has_equipped_effect(target_id,'debuff_bark') then
      select least(
        private.character_equipped_effect_number(target_id,'debuff_bark','max_stacks',3)::integer,
        count(*)::integer
      )
      into boss_stack
      from public.party_combat_status_effects
      where encounter_id=encounter.id
        and target_type='member'
        and target_character_id=target_id;

      if boss_stack>0 then
        boss_bonus:=boss_stack*private.character_equipped_effect_number(
          target_id,'debuff_bark','defense_percent_per_debuff',6
        )::integer;
        enemy_damage:=greatest(1,round(enemy_damage*(100-least(60,boss_bonus))/100.0)::integer);
      end if;
    end if;

    target_bow_family:=private.character_weapon_family(target_id);
    target_bow_dodge:=private.bow_dodge_chance(target_state.bow_distance);
    if enemy_damage>0
       and floor(random()*100)::integer
         <least(75,target_bow_dodge
          +private.character_religion_modifier_number(target_id,'evasion_chance')
          +private.character_hidden_favor_evasion_bonus(target_id))
    then
      target_dodged:=true;
      enemy_damage:=0;
      if private.character_has_equipped_effect(target_id,'dodge_counter') then
        boss_state:=jsonb_set(boss_state,'{dodge_counter_ready}','true'::jsonb,true);
      end if;
      if private.character_has_equipped_effect(target_id,'untouched_tempo') then
        boss_state:=jsonb_set(boss_state,'{rhythm_clean}','true'::jsonb,true);
      end if;
      update public.party_combat_member_states
      set boss_item_state=boss_state,updated_at=now()
      where encounter_id=encounter.id and character_id=target_id;
    end if;

    if target_state.reflect_percent>0 and enemy_damage>0 then
      reflected_damage:=least(
        encounter.enemy_hp_current,
        greatest(0,floor(enemy_damage*target_state.reflect_percent/100.0)::integer)
      );
      enemy_damage:=greatest(0,enemy_damage-reflected_damage);

      update public.party_combat_encounters
      set enemy_hp_current=greatest(0,enemy_hp_current-reflected_damage)
      where id=encounter.id
      returning * into encounter;

      update public.party_combat_member_states
      set reflect_percent=0,updated_at=now()
      where encounter_id=encounter.id and character_id=target_id;

      target_state.reflect_percent:=0;
    end if;

    guard_value:=target_state.guard_percent;
    enemy_damage_before_guard:=enemy_damage;
    if guard_value>0 and enemy_damage>0 then
      enemy_damage:=greatest(
        1,
        ceil(enemy_damage*(100-guard_value)/100.0)::integer
      );
      boss_blocked:=greatest(0,enemy_damage_before_guard-enemy_damage);

      if boss_blocked>0 and private.character_has_equipped_effect(target_id,'guard_store') then
        boss_stored:=greatest(0,coalesce((boss_state->>'guard_store')::integer,0));
        boss_stored:=least(
          round(target_state.hp_max*private.character_equipped_effect_number(
            target_id,'guard_store','stored_damage_cap_max_hp_percent',25
          )/100.0)::integer,
          boss_stored+round(boss_blocked*private.character_equipped_effect_number(
            target_id,'guard_store','stored_damage_percent',40
          )/100.0)::integer
        );
        boss_state:=jsonb_set(boss_state,'{guard_store}',to_jsonb(boss_stored),true);
      end if;

      if boss_blocked>0 and private.character_has_equipped_effect(target_id,'block_resonance') then
        boss_stack:=least(
          private.character_equipped_effect_number(target_id,'block_resonance','max_stacks',3)::integer,
          greatest(0,coalesce((boss_state->>'black_bell_resonance')::integer,0))+1
        );
        boss_state:=jsonb_set(boss_state,'{black_bell_resonance}',to_jsonb(boss_stack),true);
      end if;

      update public.party_combat_member_states
      set boss_item_state=boss_state,updated_at=now()
      where encounter_id=encounter.id and character_id=target_id;
    end if;

    incoming_reduction:=case
      when target_state.incoming_damage_reduction_rounds>0
        then target_state.incoming_damage_reduction_percent
      else 0
    end;
    if incoming_reduction>0 then
      enemy_damage:=greatest(
        1,
        ceil(enemy_damage*(100-incoming_reduction)/100.0)::integer
      );
    end if;

    if enemy_damage>0
       and private.character_has_equipped_effect(target_id,'one_shot_cap')
       and coalesce((boss_state->>'zero_sphere_used')::boolean,false)=false
    then
      boss_bonus:=greatest(1,private.character_equipped_effect_number(
        target_id,'one_shot_cap','max_single_hit_max_hp_percent',35
      )::integer);
      if enemy_damage>round(target_state.hp_max*boss_bonus/100.0)::integer then
        enemy_damage:=greatest(1,round(target_state.hp_max*boss_bonus/100.0)::integer);
        boss_state:=jsonb_set(boss_state,'{zero_sphere_used}','true'::jsonb,true);
      end if;
    end if;

    boss_shield:=greatest(0,coalesce((boss_state->>'temp_shield')::integer,0));
    if boss_shield>0 and enemy_damage>0 then
      boss_absorb:=least(enemy_damage,boss_shield);
      enemy_damage:=enemy_damage-boss_absorb;
      boss_shield:=boss_shield-boss_absorb;
      boss_state:=jsonb_set(boss_state,'{temp_shield}',to_jsonb(boss_shield),true);
    end if;

    if private.character_has_equipped_effect(target_id,'adaptive_resist') then
      if enemy_damage>0
         and encounter.enemy_damage_type not in ('slashing','piercing','blunt')
         and enemy_damage*100>=target_state.hp_max*private.character_equipped_effect_number(
           target_id,'adaptive_resist','trigger_min_damage_percent',8
         )
      then
        boss_state:=jsonb_set(boss_state,'{adaptive_type}',to_jsonb(encounter.enemy_damage_type),true);
        boss_state:=jsonb_set(
          boss_state,'{adaptive_rounds}',
          to_jsonb(private.character_equipped_effect_number(
            target_id,'adaptive_resist','duration_rounds',3
          )::integer),true
        );
      elsif coalesce((boss_state->>'adaptive_rounds')::integer,0)>0 then
        boss_state:=jsonb_set(
          boss_state,'{adaptive_rounds}',
          to_jsonb(greatest(0,(boss_state->>'adaptive_rounds')::integer-1)),true
        );
      end if;
    end if;

    if event_special and enemy_damage>0
       and private.character_has_equipped_effect(target_id,'special_revenge_element')
    then
      boss_state:=jsonb_set(boss_state,'{revenge_type}',to_jsonb(encounter.enemy_damage_type),true);
    end if;

    if enemy_damage>0 and private.character_has_equipped_effect(target_id,'untouched_tempo') then
      boss_state:=jsonb_set(boss_state,'{rhythm_clean}','false'::jsonb,true);
    end if;

    if enemy_damage>0
       and not exists(
         select 1
         from public.party_combat_member_states wounded
         where wounded.encounter_id=encounter.id
           and not wounded.downed
           and wounded.character_id<>target_id
           and wounded.hp_current::numeric/greatest(1,wounded.hp_max)
             < target_state.hp_current::numeric/greatest(1,target_state.hp_max)
       )
    then
      select ms.character_id,ms.hp_current,c.name
      into redirect_character_id,redirect_hp,redirect_name
      from public.party_combat_member_states ms
      join public.characters c on c.id=ms.character_id
      where ms.encounter_id=encounter.id
        and ms.character_id<>target_id
        and not ms.downed
        and ms.guard_percent>0
        and private.character_has_equipped_effect(ms.character_id,'ally_damage_redirect')
      order by ms.hp_current desc
      limit 1;

      if redirect_character_id is not null and redirect_hp>1 then
        redirect_amount:=least(
          redirect_hp-1,
          greatest(0,round(enemy_damage*private.character_equipped_effect_number(
            redirect_character_id,'ally_damage_redirect','redirect_percent',25
          )/100.0)::integer)
        );
        if redirect_amount>0 then
          enemy_damage:=greatest(0,enemy_damage-redirect_amount);
          update public.party_combat_member_states
          set hp_current=greatest(1,hp_current-redirect_amount),updated_at=now()
          where encounter_id=encounter.id and character_id=redirect_character_id;
          update public.character_progress
          set hp_current=private.character_effective_hp_to_base(
                redirect_character_id,
                (select hp_current from public.party_combat_member_states
                 where encounter_id=encounter.id and character_id=redirect_character_id)
              ),
              hp_regen_anchor_at=now(),updated_at=now()
          where character_id=redirect_character_id;
        end if;
      end if;
    end if;

    update public.party_combat_member_states
    set boss_item_state=boss_state,updated_at=now()
    where encounter_id=encounter.id and character_id=target_id;

    target_downed:=target_state.hp_current-enemy_damage<=0;
    hp_after:=greatest(1,target_state.hp_current-enemy_damage);

    update public.party_combat_member_states
    set hp_current=hp_after,
        downed=target_downed,
        guard_percent=0,
        taunt_chance=case when target_downed then 0 else taunt_chance end,
        updated_at=now()
    where encounter_id=encounter.id
      and character_id=target_id;

    update public.party_dungeon_run_members
    set dead=case when target_downed then true else dead end,
        dead_at=case when target_downed then coalesce(dead_at,now()) else dead_at end
    where run_id=encounter.run_id and character_id=target_id;

    update public.character_progress
    set hp_current=private.character_effective_hp_to_base(target_id,hp_after),
        hp_regen_anchor_at=now(),
        mana_regen_anchor_at=now(),
        updated_at=now()
    where character_id=target_id;

    select c.name into target_name
    from public.characters c
    where c.id=target_id;

    insert into public.party_combat_turns(
      encounter_id,round,actor_type,target_character_id,
      action_type,damage,message
    )
    values(
      encounter.id,encounter.round,'enemy',target_id,
      'attack_'||encounter.enemy_damage_type,enemy_damage,
      case
        when target_dodged and event_special
          then encounter.enemy_name||' применяет «'
            ||coalesce(nullif(event_template.special_name,''),'особую атаку')
            ||'» против '||target_name||', но цель уклоняется.'
        when target_dodged
          then encounter.enemy_name||' атакует '||target_name||', но цель уклоняется.'
        when event_special
          then encounter.enemy_name||' применяет «'
            ||coalesce(nullif(event_template.special_name,''),'особую атаку')
            ||'» против '||target_name||' и наносит '
            ||enemy_damage||' '||private.damage_type_label(encounter.enemy_damage_type)||' урона.'
        else encounter.enemy_name||' атакует '||target_name||' и наносит '
          ||enemy_damage||' '||private.damage_type_label(encounter.enemy_damage_type)||' урона.'
      end
      ||case when enemy_reduction>0 then ' Ослабление врага: -'||enemy_reduction||'%.' else '' end
      ||case when target_vulnerable>0 then ' Уязвимость цели: +'||target_vulnerable||'%.' else '' end
      ||case when guard_value>0 then ' Защита уменьшила удар на '||guard_value||'%.' else '' end
      ||case when reflected_damage>0 then ' Зеркальный барьер отражает '||reflected_damage||' урона обратно во врага.' else '' end
      ||case when incoming_reduction>0 then ' Благословение жертвы уменьшило урон на '||incoming_reduction||'%.' else '' end
      ||case when boss_absorb>0 then ' Барьер поглощает '||boss_absorb||' урона.' else '' end
      ||case when redirect_amount>0 then ' Щит Пустого Трона перенаправляет '||redirect_amount||' урона на '||redirect_name||'.' else '' end
      ||case when resistance>0 then ' Сопротивление: '||resistance||'%.' when resistance<0 then ' Уязвимость: +'||abs(resistance)||'%.' else '' end
      ||case when target_downed then ' '||target_name||' выведен из строя.' else '' end
    );

    enemy_acted:=true;

    select coalesce(bool_and(downed),false) into all_downed
    from public.party_combat_member_states
    where encounter_id=encounter.id;

    if all_downed then
      perform private.finish_party_combat_defeat(encounter.id);
      return jsonb_build_object('status','defeat','run_status','abandoned');
    end if;
    end if;
  end if;

  tick_result:=private.tick_party_combat_statuses(encounter.id);

  if coalesce(tick_result->>'status','active')<>'active' then
    return tick_result;
  end if;

  if enemy_acted
     and enemy_damage>0
     and encounter.enemy_on_hit_effect_type is not null
     and encounter.enemy_on_hit_effect_chance>0
     and floor(random()*100)::integer<encounter.enemy_on_hit_effect_chance
  then
    perform private.apply_party_combat_status_effect(
      encounter.id,'member',target_id,
      encounter.enemy_on_hit_effect_type,
      encounter.enemy_on_hit_effect_potency,
      encounter.enemy_on_hit_effect_turns,
      null,encounter.enemy_name
    );

    insert into public.party_combat_turns(
      encounter_id,round,actor_type,target_character_id,
      action_type,damage,message
    )
    values(
      encounter.id,encounter.round,'system',target_id,
      'status_apply',0,
      encounter.enemy_name||' накладывает на '||target_name||' эффект «'
      ||private.combat_effect_label(encounter.enemy_on_hit_effect_type)||'».'
    );
  end if;

  if event_special
     and enemy_acted
     and enemy_damage>0
     and target_id is not null
     and event_template.special_effect_type is not null
     and coalesce(event_template.special_effect_chance,0)>0
     and floor(random()*100)::integer<event_template.special_effect_chance
  then
    perform private.apply_party_combat_status_effect(
      encounter.id,'member',target_id,
      event_template.special_effect_type,
      coalesce(event_template.special_effect_potency,0),
      greatest(1,coalesce(event_template.special_effect_turns,1)),
      null,
      coalesce(nullif(event_template.special_name,''),event_row.name)
    );

    insert into public.party_combat_turns(
      encounter_id,round,actor_type,target_character_id,
      action_type,damage,message
    )
    values(
      encounter.id,encounter.round,'system',target_id,
      'event_boss_special_status',0,
      coalesce(nullif(event_template.special_name,''),event_row.name)
      ||' накладывает на '||coalesce(target_name,'цель')||' эффект «'
      ||private.combat_effect_label(event_template.special_effect_type)||'».'
    );
  end if;

  update public.party_combat_member_states
  set incoming_damage_reduction_percent=case
        when incoming_damage_reduction_rounds<=1 then 0
        else incoming_damage_reduction_percent
      end,
      incoming_damage_reduction_rounds=greatest(0,incoming_damage_reduction_rounds-1),
      updated_at=now()
  where encounter_id=encounter.id
    and incoming_damage_reduction_rounds>0;

  if event_row.id is not null
     and event_row.special_every_n>=2
     and mod(encounter.round+1,event_row.special_every_n)=0
  then
    insert into public.party_combat_turns(
      encounter_id,round,actor_type,action_type,damage,message
    ) values(
      encounter.id,encounter.round,'system','event_boss_telegraph',0,
      event_row.name||' готовит «'
      ||coalesce(nullif(event_template.special_name,''),'особую атаку')
      ||'». На следующем ходу врага защита особенно важна.'
    );
  end if;

  update public.party_combat_encounters
  set round=round+1,
      acted_character_ids='{}'::uuid[]
  where id=encounter.id;

  return jsonb_build_object(
    'status','active',
    'enemy_hp_current',(select enemy_hp_current from public.party_combat_encounters where id=encounter.id),
    'enemy_acted',enemy_acted,
    'enemy_stunned',enemy_stunned,
    'round',encounter.round+1
  );
end;
$function$

