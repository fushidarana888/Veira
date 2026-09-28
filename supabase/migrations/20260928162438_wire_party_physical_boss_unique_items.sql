-- Synced from live Supabase migration 20260928162438 (wire_party_physical_boss_unique_items)

CREATE OR REPLACE FUNCTION public.perform_party_combat_action(p_character_id uuid, p_encounter_id uuid, p_action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid:=auth.uid();
  encounter public.party_combat_encounters;
  run_row public.party_dungeon_runs;
  member_state public.party_combat_member_states;
  stats record;
  actor_name text;
  damage_type text;
  raw_damage integer:=0;
  dealt_damage integer:=0;
  variance integer:=0;
  resistance integer:=0;
  type_bonus integer:=0;
  total_bonus integer:=0;
  buff_bonus integer:=0;
  actor_reduction integer:=0;
  enemy_vulnerable integer:=0;
  heal_amount integer:=0;
  mana_gain integer:=0;
  guard_value integer:=0;
  action_message text;
  base_physical_damage integer:=0;
  first_strike_multiplier numeric:=1.0;
  first_bonus_multiplier numeric:=1.0;
  first_physical_strike_active boolean:=false;
  katana_rhythm_bonus integer:=0;
  action_type_value text:=p_action;
  bow_family text;
  bow_release boolean:=false;
  bow_multiplier numeric:=1.0;
  bow_penetration integer:=0;
  bow_effective_defense integer:=0;
  bloodshed_chance integer:=0;
  echo_chance integer:=0;
  echo_extra_rolls integer:=0;
  echo_extra_hits integer:=0;
  echo_hit_damage integer:=0;
  echo_damage integer:=0;
  total_physical_hits integer:=1;
  bloodshed_procs integer:=0;
  weapon_stun_proc boolean:=false;
  hit_index integer:=0;
  critical_hit boolean:=false;
  critical_hits integer:=0;
  greatsword_crit_bonus integer:=0;
  echo_single_damage integer:=0;
  white_fang_active boolean:=false;
  white_fang_rupture record;
  white_fang_rupture_damage integer:=0;
  white_fang_target_hp integer:=0;
  boss_state jsonb:='{}'::jsonb;
  boss_penetration integer:=0;
  boss_bonus integer:=0;
  boss_stored integer:=0;
  boss_stack integer:=0;
  boss_extra integer:=0;
  boss_type text;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_action not in ('physical','bow_draw','magic','guard') then
    raise exception 'INVALID_PARTY_COMBAT_ACTION';
  end if;

  if not exists(
    select 1
    from public.characters c
    where c.id=p_character_id
      and c.owner_user_id=caller_id
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select * into encounter
  from public.party_combat_encounters
  where id=p_encounter_id
  for update;

  if encounter.id is null then raise exception 'PARTY_COMBAT_NOT_FOUND'; end if;
  if encounter.status<>'active' then raise exception 'PARTY_COMBAT_NOT_ACTIVE'; end if;

  select * into run_row
  from public.party_dungeon_runs
  where id=encounter.run_id;

  if run_row.id is null or run_row.status<>'active' then
    raise exception 'PARTY_DUNGEON_RUN_NOT_ACTIVE';
  end if;

  if not exists(
    select 1
    from public.party_dungeon_run_members prm
    where prm.run_id=run_row.id
      and prm.character_id=p_character_id
  ) then raise exception 'NOT_PARTY_DUNGEON_MEMBER'; end if;

  if p_character_id=any(encounter.acted_character_ids) then
    raise exception 'PARTY_ACTION_ALREADY_USED_THIS_ROUND';
  end if;

  select * into member_state
  from public.party_combat_member_states
  where encounter_id=encounter.id
    and character_id=p_character_id
  for update;

  if member_state.character_id is null then raise exception 'PARTY_MEMBER_STATE_NOT_FOUND'; end if;
  if member_state.downed then raise exception 'PARTY_MEMBER_DOWNED'; end if;

  boss_state:=coalesce(member_state.boss_item_state,'{}'::jsonb);
  if private.character_has_equipped_effect(p_character_id,'untouched_tempo')
     and coalesce((boss_state->>'rhythm_clean')::boolean,false)
  then
    boss_bonus:=greatest(0,private.character_equipped_effect_number(p_character_id,'untouched_tempo','initiative_meter_bonus',18)::integer);
    member_state.initiative_meter:=least(99,member_state.initiative_meter+boss_bonus);
    boss_state:=jsonb_set(boss_state,'{rhythm_clean}','false'::jsonb,true);
    update public.party_combat_member_states
    set initiative_meter=member_state.initiative_meter,boss_item_state=boss_state,updated_at=now()
    where encounter_id=encounter.id and character_id=p_character_id;
  end if;
  if private.party_status_stunned(encounter.id,'member',p_character_id) then
    raise exception 'PARTY_MEMBER_STUNNED';
  end if;

  perform private.assert_party_action_turn(encounter.id,p_character_id);

  select * into stats
  from private.get_character_combat_stats(p_character_id);

  select c.name into actor_name
  from public.characters c
  where c.id=p_character_id;

  bow_family:=private.character_weapon_family(p_character_id);
  bow_penetration:=private.character_bow_penetration(p_character_id);
  bloodshed_chance:=private.character_bloodshed_chance(p_character_id);
  echo_chance:=private.character_echo_strike_chance(p_character_id);
  white_fang_active:=private.character_has_white_fang(p_character_id);

  if p_action<>'physical' or bow_family<>'katana' then
    member_state.katana_rhythm_stacks:=0;
    update public.party_combat_member_states
    set katana_rhythm_stacks=0,updated_at=now()
    where encounter_id=encounter.id and character_id=p_character_id;
  end if;

  if member_state.bow_draw_pending and p_action<>'physical' then
    raise exception 'BOW_FULL_DRAW_LOCKED';
  end if;

  if p_action='bow_draw' then
    if bow_family not in ('short_bow','long_bow') then raise exception 'BOW_NOT_EQUIPPED'; end if;
    if member_state.bow_draw_pending then raise exception 'BOW_ALREADY_DRAWING'; end if;
    member_state.bow_draw_pending:=true;
    update public.party_combat_member_states
    set bow_draw_pending=true,updated_at=now()
    where encounter_id=encounter.id and character_id=p_character_id;
    action_type_value:='bow_draw';
    action_message:=actor_name||' полностью натягивает тетиву. Следующий ход автоматически выпускает стрелу; дистанция зафиксирована.';

  elsif p_action='guard' then
    guard_value:=least(80,greatest(55,55+coalesce(stats.guard_boost_percent,0)));

    update public.party_combat_member_states
    set guard_percent=greatest(guard_percent,guard_value),
        updated_at=now()
    where encounter_id=encounter.id
      and character_id=p_character_id;

    action_message:=actor_name
      ||' занимает защитную стойку. Следующий удар по нему будет уменьшен на '
      ||guard_value||'%.';
  else
    damage_type:=case
      when p_action='physical' then stats.weapon_damage_type
      else stats.magic_damage_type
    end;

    variance:=case when p_action='physical' then private.weapon_family_damage_variance(bow_family,stats.luck) else private.combat_damage_variance(stats.luck) end;

    if p_action='physical'
       and private.character_has_equipped_effect(p_character_id,'dodge_counter')
       and coalesce((boss_state->>'dodge_counter_ready')::boolean,false)
    then
      boss_penetration:=greatest(0,least(90,private.character_equipped_effect_number(p_character_id,'dodge_counter','next_attack_armor_penetration_percent',45)::integer));
      boss_state:=jsonb_set(boss_state,'{dodge_counter_ready}','false'::jsonb,true);
      update public.party_combat_member_states set boss_item_state=boss_state,updated_at=now()
      where encounter_id=encounter.id and character_id=p_character_id;
    end if;

    if p_action='physical' then
      if bow_family in ('short_bow','long_bow') then
        bow_release:=member_state.bow_draw_pending;
        if bow_family='long_bow' and not bow_release then
          raise exception 'BOW_REQUIRES_FULL_DRAW';
        end if;

        bow_multiplier:=private.bow_distance_multiplier(member_state.bow_distance)
          * case when bow_release then 1.60 else 1.00 end;
        boss_bonus:=0;
        if private.character_has_equipped_effect(p_character_id,'bow_alternation')
           and bow_release
           and coalesce((boss_state->>'crystal_crack')::boolean,false)
        then
          boss_bonus:=greatest(0,private.character_equipped_effect_number(p_character_id,'bow_alternation','bonus_armor_penetration_percent',30)::integer);
        end if;
        bow_effective_defense:=case
          when bow_release or boss_penetration>0
            then floor(encounter.enemy_defense*(100-least(95,bow_penetration+boss_penetration+boss_bonus))/100.0)::integer
          else encounter.enemy_defense
        end;
        raw_damage:=greatest(1,private.damage_after_armor(round(stats.physical_power*bow_multiplier)::integer+variance,bow_effective_defense));
        if private.character_has_equipped_effect(p_character_id,'bow_alternation') then
          if bow_release and coalesce((boss_state->>'crystal_crack')::boolean,false) then
            boss_bonus:=greatest(0,private.character_equipped_effect_number(p_character_id,'bow_alternation','crack_bonus_percent',35)::integer);
            raw_damage:=greatest(1,round(raw_damage*(100+boss_bonus)/100.0)::integer);
            boss_state:=jsonb_set(boss_state,'{crystal_crack}','false'::jsonb,true);
          elsif not bow_release then
            boss_state:=jsonb_set(boss_state,'{crystal_crack}','true'::jsonb,true);
          end if;
          update public.party_combat_member_states set boss_item_state=boss_state,updated_at=now()
          where encounter_id=encounter.id and character_id=p_character_id;
        end if;
        action_type_value:=case when bow_release then 'bow_full_release' else 'bow_fast' end;

        if bow_release then
          member_state.bow_draw_pending:=false;
          update public.party_combat_member_states
          set bow_draw_pending=false,updated_at=now()
          where encounter_id=encounter.id and character_id=p_character_id;
        end if;
      else
        raw_damage:=private.weapon_family_physical_raw_damage(
          p_character_id,
          stats.physical_power,
          floor(encounter.enemy_defense*(100-boss_penetration)/100.0)::integer,
          encounter.enemy_hp_max,
          variance
        );
      end if;
      if private.character_has_equipped_effect(p_character_id,'initiative_gap_bonus') then
        boss_bonus:=least(
          private.character_equipped_effect_number(p_character_id,'initiative_gap_bonus','max_bonus_percent',20)::integer,
          greatest(0,floor((stats.initiative-encounter.enemy_initiative)/greatest(1,private.character_equipped_effect_number(p_character_id,'initiative_gap_bonus','initiative_per_percent',3)))::integer)
        );
        if boss_bonus>0 then raw_damage:=greatest(1,round(raw_damage*(100+boss_bonus)/100.0)::integer); end if;
      end if;
      if private.character_has_equipped_effect(p_character_id,'guard_store') then
        boss_stored:=greatest(0,coalesce((boss_state->>'guard_store')::integer,0));
        if boss_stored>0 then
          raw_damage:=raw_damage+boss_stored;
          boss_state:=jsonb_set(boss_state,'{guard_store}','0'::jsonb,true);
          update public.party_combat_member_states set boss_item_state=boss_state,updated_at=now()
          where encounter_id=encounter.id and character_id=p_character_id;
        end if;
      end if;
      total_bonus:=coalesce(stats.all_damage_bonus_percent,0)+private.race_party_damage_bonus(p_character_id)
        +coalesce(stats.physical_damage_bonus_percent,0);
    else
      raw_damage:=greatest(
        1,
        private.damage_after_armor(
          stats.magic_power+variance,
          encounter.enemy_defense*0.65
        )
      );
      total_bonus:=coalesce(stats.all_damage_bonus_percent,0)+private.race_party_damage_bonus(p_character_id)
        +coalesce(stats.magic_damage_bonus_percent,0);
    end if;

    actor_reduction:=private.party_status_reduction(
      encounter.id,'member',p_character_id
    );
    if actor_reduction>0 then
      raw_damage:=greatest(
        1,
        round(raw_damage*(100-actor_reduction)/100.0)::integer
      );
    end if;

    if p_action='physical' then
      base_physical_damage:=raw_damage;
    end if;

    type_bonus:=private.character_damage_bonus(p_character_id,damage_type);
    total_bonus:=total_bonus+type_bonus;

    if member_state.damage_bonus_hits>0
       and member_state.damage_bonus_percent>0
    then
      buff_bonus:=member_state.damage_bonus_percent;
      total_bonus:=total_bonus+buff_bonus;
    end if;

    if private.party_combat_encounter_is_strong(encounter.id) then
      total_bonus:=total_bonus
        +private.character_religion_modifier_number(p_character_id,'strong_enemy_damage_bonus');
    end if;

    if encounter.is_boss then
      total_bonus:=total_bonus+coalesce(stats.boss_damage_bonus_percent,0);
    end if;

    if encounter.enemy_hp_max>0
       and encounter.enemy_hp_current*100<=encounter.enemy_hp_max*50
    then
      total_bonus:=total_bonus+coalesce(stats.damage_vs_wounded_percent,0);
    end if;

    raw_damage:=greatest(
      1,
      round(raw_damage*(100+total_bonus)/100.0)::integer
    );

    if p_action='physical' and not exists(
      select 1 from public.party_combat_turns pct
      where pct.encounter_id=encounter.id
        and pct.actor_type='player'
        and pct.actor_character_id=p_character_id
        and pct.action_type='physical'
    ) then
      first_strike_multiplier:=private.character_first_physical_strike_multiplier(p_character_id);
      first_bonus_multiplier:=private.character_first_physical_bonus_damage_multiplier(p_character_id);
      if first_strike_multiplier>1.0 or first_bonus_multiplier>1.0 then
        raw_damage:=private.apply_first_physical_strike_multiplier(
          base_physical_damage,
          raw_damage,
          first_strike_multiplier,
          first_bonus_multiplier
        );
        first_physical_strike_active:=true;
      end if;
    end if;

    if p_action='physical' and bow_family='katana' then
      katana_rhythm_bonus:=private.katana_rhythm_bonus_percent(
        member_state.katana_rhythm_stacks
      );
      if katana_rhythm_bonus>0 then
        raw_damage:=greatest(
          1,
          round(raw_damage*(100+katana_rhythm_bonus)/100.0)::integer
        );
      end if;
    end if;

    resistance:=private.damage_resistance_percent(
      encounter.enemy_resistances,
      damage_type
    );
    if p_action='physical' then
      resistance:=private.weapon_family_adjust_resistance(
        bow_family,damage_type,resistance
      );
    end if;
    dealt_damage:=greatest(
      1,
      round(raw_damage*(100-resistance)/100.0)::integer
    );

    if p_action='physical' and private.character_has_equipped_effect(p_character_id,'block_resonance') then
      boss_stack:=greatest(0,coalesce((boss_state->>'black_bell_resonance')::integer,0));
      if boss_stack>0 then
        boss_bonus:=greatest(1,private.character_equipped_effect_number(p_character_id,'block_resonance','armor_break_percent_per_stack',8)::integer)*boss_stack;
        perform private.apply_party_combat_status_effect(encounter.id,'enemy',null,'vulnerable',least(50,boss_bonus),
          greatest(1,private.character_equipped_effect_number(p_character_id,'block_resonance','break_turns',2)::integer),
          p_character_id,'Молот Чёрного Звона');
        boss_state:=jsonb_set(boss_state,'{black_bell_resonance}','0'::jsonb,true);
        update public.party_combat_member_states set boss_item_state=boss_state,updated_at=now()
        where encounter_id=encounter.id and character_id=p_character_id;
      end if;
    end if;

    if p_action='physical' and private.character_has_equipped_effect(p_character_id,'special_revenge_element') then
      boss_type:=nullif(boss_state->>'revenge_type','');
      if boss_type is not null then
        boss_bonus:=greatest(0,private.character_equipped_effect_number(p_character_id,'special_revenge_element','echo_percent',30)::integer);
        boss_extra:=greatest(0,round(dealt_damage*boss_bonus/100.0*(100-private.damage_resistance_percent(encounter.enemy_resistances,boss_type))/100.0)::integer);
        dealt_damage:=dealt_damage+boss_extra;
        boss_state:=boss_state-'revenge_type';
        update public.party_combat_member_states set boss_item_state=boss_state,updated_at=now()
        where encounter_id=encounter.id and character_id=p_character_id;
      end if;
    end if;

    enemy_vulnerable:=private.party_status_vulnerability(
      encounter.id,'enemy',null
    );
    if enemy_vulnerable>0 then
      dealt_damage:=greatest(
        1,
        round(dealt_damage*(100+enemy_vulnerable)/100.0)::integer
      );
    end if;

    if p_action='physical' and bow_family='dagger' then
      echo_hit_damage:=dealt_damage;
    end if;

    critical_hit:=false;
    greatsword_crit_bonus:=0;
    if dealt_damage>0 and p_action in ('physical','magic') then
      if p_action='physical' and bow_family='greatsword' then
        greatsword_crit_bonus:=private.greatsword_crit_bonus_percent(
          member_state.greatsword_crit_stacks
        );
        critical_hit:=private.roll_character_critical_with_bonus(
          p_character_id,
          greatsword_crit_bonus
        );
      else
        critical_hit:=private.roll_character_critical(p_character_id);
      end if;

      if critical_hit then
        dealt_damage:=private.apply_critical_damage(
          dealt_damage,
          case when p_action='physical' then 'physical' else 'magic' end,
          true,
          false
        );
        critical_hits:=critical_hits+1;
      end if;

      if p_action='physical' and bow_family='greatsword' then
        member_state.greatsword_crit_stacks:=case
          when critical_hit then 0
          else least(5,member_state.greatsword_crit_stacks+1)
        end;
      end if;
    end if;

    dealt_damage:=least(dealt_damage,encounter.enemy_hp_current);

    if p_action='physical'
       and bow_family='dagger'
       and dealt_damage>0
       and echo_chance>0
       and encounter.enemy_hp_current>dealt_damage
    then
      echo_extra_rolls:=private.roll_echo_strike_extra_hits(echo_chance,50);
      if echo_extra_rolls>0 and echo_hit_damage>0 then
        for hit_index in 1..echo_extra_rolls loop
          exit when encounter.enemy_hp_current<=dealt_damage+echo_damage;
          echo_single_damage:=echo_hit_damage;
          if private.roll_character_critical(p_character_id) then
            echo_single_damage:=private.apply_critical_damage(
              echo_single_damage,'physical',true,false
            );
            critical_hits:=critical_hits+1;
          end if;
          echo_single_damage:=least(
            echo_single_damage,
            greatest(0,encounter.enemy_hp_current-dealt_damage-echo_damage)
          );
          if echo_single_damage<=0 then exit; end if;
          echo_damage:=echo_damage+echo_single_damage;
          echo_extra_hits:=echo_extra_hits+1;
        end loop;
        dealt_damage:=dealt_damage+echo_damage;
        total_physical_hits:=1+echo_extra_hits;
      end if;
    end if;

    update public.party_combat_encounters
    set enemy_hp_current=greatest(0,enemy_hp_current-dealt_damage)
    where id=encounter.id;

    weapon_stun_proc:=false;
    if p_action='physical'
       and dealt_damage>0
       and encounter.enemy_hp_current-dealt_damage>0
       and floor(random()*100)::integer<private.weapon_family_stun_chance(p_character_id,true)
    then
      weapon_stun_proc:=true;
      perform private.apply_party_combat_status_effect(
        encounter.id,'enemy',null,'stun',0,1,p_character_id,'Оглушающий удар'
      );
    end if;

    if p_action='physical' and dealt_damage>0 and bloodshed_chance>0 then
      for hit_index in 1..greatest(1,total_physical_hits) loop
        if floor(random()*100)::integer<bloodshed_chance then
          bloodshed_procs:=bloodshed_procs+1;
        end if;
      end loop;
      if bloodshed_procs>0 then
        encounter.enemy_bloodshed_stacks:=encounter.enemy_bloodshed_stacks+bloodshed_procs;
        update public.party_combat_encounters
        set enemy_bloodshed_stacks=encounter.enemy_bloodshed_stacks
        where id=encounter.id;
      end if;
    end if;

    if coalesce(stats.lifesteal_percent,0)>0 and dealt_damage>0 then
      heal_amount:=least(
        member_state.hp_max-member_state.hp_current,
        floor(dealt_damage*stats.lifesteal_percent/100.0)::integer
      );
    end if;

    if coalesce(stats.mana_on_hit,0)>0 and dealt_damage>0 then
      mana_gain:=least(
        member_state.mana_max-member_state.mana_current,
        stats.mana_on_hit*case when p_action='physical' then greatest(1,total_physical_hits) else 1 end
      );
    end if;

    update public.party_combat_member_states
    set hp_current=least(hp_max,hp_current+heal_amount),
        mana_current=least(mana_max,mana_current+mana_gain),
        damage_bonus_hits=case
          when buff_bonus>0 then greatest(0,damage_bonus_hits-1)
          else damage_bonus_hits
        end,
        damage_bonus_percent=case
          when buff_bonus>0 and damage_bonus_hits<=1 then 0
          else damage_bonus_percent
        end,
        katana_rhythm_stacks=case
          when p_action='physical' and bow_family='katana'
            then least(5,katana_rhythm_stacks+1)
          else 0
        end,
        greatsword_crit_stacks=case
          when p_action='physical' and bow_family='greatsword'
            then member_state.greatsword_crit_stacks
          when bow_family<>'greatsword' then 0
          else greatsword_crit_stacks
        end,
        updated_at=now()
    where encounter_id=encounter.id
      and character_id=p_character_id
    returning * into member_state;

    if heal_amount>0 or mana_gain>0 then
      update public.character_progress
      set hp_current=private.character_effective_hp_to_base(p_character_id,member_state.hp_current),
          mana_current=member_state.mana_current,
          hp_regen_anchor_at=now(),
          mana_regen_anchor_at=now(),
          updated_at=now()
      where character_id=p_character_id;
    end if;

    action_message:=actor_name
      ||case
        when p_action='physical' and bow_family in ('short_bow','long_bow') and bow_release then ' выпускает стрелу после полного натяга'
        when p_action='physical' and bow_family in ('short_bow','long_bow') then ' делает быстрый выстрел'
        when p_action='physical' then ' атакует физически'
        else ' использует врождённую магию'
      end
      ||' и наносит '||dealt_damage||' '
      ||private.damage_type_label(damage_type)||' урона.'
      ||case when type_bonus>0 then ' Бонус типа: +'||type_bonus||'%.' else '' end
      ||case when buff_bonus>0 then ' Боевой фокус: +'||buff_bonus||'%.' else '' end
      ||case when actor_reduction>0 then ' Ослабление: -'||actor_reduction||'%.' else '' end
      ||case when enemy_vulnerable>0 then ' Уязвимость врага: +'||enemy_vulnerable||'%.' else '' end
      ||case
        when resistance>0 then ' Сопротивление врага: '||resistance||'%.'
        when resistance<0 then ' Уязвимость врага: +'||abs(resistance)||'%.'
        else ''
      end
      ||case when heal_amount>0 then ' Вампиризм: +'||heal_amount||' HP.' else '' end
      ||case when mana_gain>0 then ' Восстановлено '||mana_gain||' маны.' else '' end
      ||case when first_physical_strike_active then ' Первый удар катаны: база ×'||trim(to_char(first_strike_multiplier,'FM9990.0'))||', бонусная часть ×'||trim(to_char(first_bonus_multiplier,'FM9990.0'))||'.' else '' end
      ||case when katana_rhythm_bonus>0 then ' Нарастающий ритм: +'||katana_rhythm_bonus||'% урона.' else '' end
      ||case when critical_hits>0 then ' Критических попаданий: '||critical_hits||'.' else '' end
      ||case when echo_extra_hits>0 then ' Эхо ударов: +'||echo_extra_hits||' доп. удар(а/ов), +'||echo_damage||' урона.' else '' end
      ||case when p_action='physical' and encounter.enemy_bloodshed_stacks>0
        then ' Кровопролитие на цели: '||encounter.enemy_bloodshed_stacks||' стак(а/ов).'
        else '' end
      ||case when weapon_stun_proc then ' Оглушение: враг пропустит следующий ход.' else '' end;
  end if;

  if p_action='physical'
     and white_fang_active
     and dealt_damage>0
  then
    select enemy_hp_current
    into white_fang_target_hp
    from public.party_combat_encounters
    where id=encounter.id;

    if white_fang_target_hp>0 then
      if member_state.white_fang_wounds>=3 then
        select * into white_fang_rupture
        from private.white_fang_rupture_roll(p_character_id,encounter.enemy_hp_max);

        white_fang_rupture_damage:=least(
          greatest(0,white_fang_rupture.final_damage),
          white_fang_target_hp
        );

        update public.party_combat_encounters
        set enemy_hp_current=greatest(0,enemy_hp_current-white_fang_rupture_damage)
        where id=encounter.id;

        member_state.white_fang_wounds:=0;
        update public.party_combat_member_states
        set white_fang_wounds=0,updated_at=now()
        where encounter_id=encounter.id and character_id=p_character_id;

        dealt_damage:=dealt_damage+white_fang_rupture_damage;
        action_message:=coalesce(action_message,'')
          ||' Разрыв наносит '||white_fang_rupture_damage||' урона'
          ||case when white_fang_rupture.critical then ' (крит ×1.5).' else '.' end;
      else
        member_state.white_fang_wounds:=least(3,member_state.white_fang_wounds+1);

        update public.party_combat_member_states
        set white_fang_wounds=member_state.white_fang_wounds,updated_at=now()
        where encounter_id=encounter.id and character_id=p_character_id;

        action_message:=coalesce(action_message,'')
          ||' Рваные раны: '||member_state.white_fang_wounds||'/3.';
      end if;
    end if;
  end if;

  insert into public.party_combat_turns(
    encounter_id,round,actor_type,actor_character_id,
    action_type,damage,message
  )
  values(
    encounter.id,encounter.round,'player',p_character_id,
    action_type_value,dealt_damage,action_message
  );

  perform private.resolve_party_summon_action(encounter.id,p_character_id,encounter.round);
  return private.advance_party_combat_round(encounter.id,p_character_id);
end;
$function$

