-- Synced from live Supabase migration 20260928185339 (adaptive_solo_charge_window)

CREATE OR REPLACE FUNCTION private.perform_combat_action_internal(p_encounter_id uuid, p_mode text, p_spell_id uuid DEFAULT NULL::uuid, p_character_item_id uuid DEFAULT NULL::uuid)
 RETURNS combat_encounters
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid:=auth.uid();
  encounter public.combat_encounters;
  run_row public.dungeon_runs;
  stats record;
  spell public.spell_definitions;
  scroll_item public.character_items;
  scroll_def public.item_definitions;
  next_round integer;
  player_damage integer:=0;
  enemy_damage integer:=0;
  enemy_damage_before_guard integer:=0;
  reflected_damage integer:=0;
  player_defense_value integer:=0;
  blocked_damage integer:=0;
  counter_bonus integer:=0;
  raw_damage integer:=0;
  resistance integer:=0;
  enemy_hp_after integer;
  player_hp_after integer;
  player_mana_after integer;
  mana_cost integer:=0;
  guard_active boolean:=false;
  player_stunned boolean:=false;
  enemy_stunned boolean:=false;
  player_reduction integer:=0;
  enemy_reduction integer:=0;
  player_vulnerable integer:=0;
  enemy_vulnerable integer:=0;
  player_dot integer:=0;
  enemy_dot integer:=0;
  unique_heal integer:=0;
  unique_mana integer:=0;
  variance integer;
  player_message text;
  enemy_message text;
  player_damage_type text;
  action_label text;
  action_type_value text;
  apply_effect_type text;
  apply_effect_chance integer:=0;
  apply_effect_turns integer:=0;
  apply_effect_potency integer:=0;
  player_heal integer:=0;
  player_mana_restore integer:=0;
  player_support_action boolean:=false;
  combat_item public.character_items;
  combat_item_def public.item_definitions;
  combat_item_heal integer:=0;
  combat_item_mana integer:=0;
  enemy_action_damage_type text;
  player_hp_before_enemy integer:=0;
  special_attack_active boolean:=false;
  special_charge_started boolean:=false;
  enemy_guard_blocked integer:=0;
  enemy_attack_effective integer:=0;
  tempo_gain integer:=0;
  tempo_total integer:=0;
  enemy_heal integer:=0;
  phase_triggered boolean:=false;
  phase_message text;
  support_guard_percent integer:=0;
  empower_used integer:=0;
  cleansed_count integer:=0;
  type_damage_bonus integer:=0;
  base_physical_damage integer:=0;
  effective_base_physical_damage integer:=0;
  first_strike_multiplier numeric:=1.0;
  first_bonus_multiplier numeric:=1.0;
  first_physical_strike_active boolean:=false;
  katana_rhythm_bonus integer:=0;
  bow_family text;
  bow_release boolean:=false;
  bow_multiplier numeric:=1.0;
  bow_penetration integer:=0;
  bow_effective_defense integer:=0;
  bloodshed_chance integer:=0;
  bloodshed_tick integer:=0;
  echo_chance integer:=0;
  echo_extra_rolls integer:=0;
  echo_extra_hits integer:=0;
  echo_hit_damage integer:=0;
  echo_damage integer:=0;
  total_physical_hits integer:=1;
  bloodshed_procs integer:=0;
  hit_index integer:=0;
  critical_hit boolean:=false;
  critical_hits integer:=0;
  greatsword_crit_bonus integer:=0;
  echo_single_damage integer:=0;
  bow_dodge integer:=0;
  player_dodged boolean:=false;
  white_fang_active boolean:=false;
  white_fang_rupture record;
  white_fang_rupture_damage integer:=0;
  event_mechanics jsonb:='{}'::jsonb;
  wound_rupture_enabled boolean:=false;
  wound_max_stacks integer:=3;
  wound_rupture_percent integer:=0;
  rage_hunt_enabled boolean:=false;
  rage_self_damage_percent integer:=0;
  rage_dash_damage_percent integer:=0;
  rage_dash_chance integer:=0;
  rage_self_damage integer:=0;
  rage_dash_damage integer:=0;
  rage_dash_dodged boolean:=false;
  enemy_rupture_damage integer:=0;
  enemy_bonus_damage_total integer:=0;
  boss_state jsonb:='{}'::jsonb;
  boss_penetration integer:=0;
  boss_bonus integer:=0;
  boss_stored integer:=0;
  boss_stack integer:=0;
  boss_extra integer:=0;
  boss_shield integer:=0;
  boss_absorb integer:=0;
  boss_overheal integer:=0;
  boss_intended_heal integer:=0;
  boss_type text;
  boss_types jsonb:='[]'::jsonb;
  boss_types_count integer:=0;
  adaptive_enabled boolean:=false;
  adaptive_ai_state jsonb:='{}'::jsonb;
  adaptive_delay_used boolean:=false;
  adaptive_delay_chance integer:=0;
  adaptive_defensive_delay_chance integer:=0;
  adaptive_break_threshold integer:=0;
  adaptive_break_reduction integer:=0;
  adaptive_charge_hp integer:=0;
  adaptive_damage_since_charge integer:=0;
  adaptive_special_multiplier numeric:=1.0;
  adaptive_defensive_response boolean:=false;
  adaptive_next_charge_round integer:=0;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;

  if p_mode not in ('physical','bow_draw','magic','guard','learned_spell','scroll_cast','support_spell','support_scroll','combat_item') then
    raise exception 'INVALID_COMBAT_ACTION';
  end if;

  select ce.* into encounter
  from public.combat_encounters ce
  join public.characters c on c.id=ce.character_id
  where ce.id=p_encounter_id and c.owner_user_id=caller_id
  for update of ce;

  if encounter.id is null then raise exception 'COMBAT_NOT_FOUND'; end if;
  if encounter.status<>'active' then raise exception 'COMBAT_NOT_ACTIVE'; end if;

  if p_mode in ('learned_spell','support_spell')
     and not private.character_spell_equipped(encounter.character_id,p_spell_id)
  then
    raise exception 'SPELL_NOT_IN_LOADOUT';
  end if;

  if encounter.death_spirit_id is null then
    select * into run_row
    from public.dungeon_runs
    where id=encounter.dungeon_run_id
    for update;
    if run_row.status<>'active' then raise exception 'DUNGEON_RUN_NOT_ACTIVE'; end if;
  else
    perform private.expire_death_spirits();
    if not exists(
      select 1 from private.death_spirits ds
      where ds.id=encounter.death_spirit_id and ds.status='active' and ds.expires_at>now()
    ) then raise exception 'DEATH_SPIRIT_NOT_ACTIVE'; end if;
  end if;

  perform private.apply_passive_hp_regen(encounter.character_id);
  perform private.apply_passive_mana_regen(encounter.character_id);
  select * into stats from private.get_character_combat_stats(encounter.character_id);

  if stats.level is null then raise exception 'CHARACTER_PROGRESS_NOT_FOUND'; end if;

  boss_state:=coalesce(encounter.boss_item_state,'{}'::jsonb);

  if private.character_has_equipped_effect(encounter.character_id,'untouched_tempo')
     and coalesce((boss_state->>'rhythm_clean')::boolean,false)
  then
    boss_bonus:=greatest(0,private.character_equipped_effect_number(
      encounter.character_id,'untouched_tempo','initiative_meter_bonus',18
    )::integer);
    encounter.player_initiative_meter:=least(99,encounter.player_initiative_meter+boss_bonus);
    boss_state:=jsonb_set(boss_state,'{rhythm_clean}','false'::jsonb,true);
    update public.combat_encounters
    set player_initiative_meter=encounter.player_initiative_meter,
        boss_item_state=boss_state
    where id=encounter.id;
  end if;

  if run_row.event_boss_id is not null then
    select coalesce(e.mechanics,'{}'::jsonb)
    into event_mechanics
    from public.event_boss_events e
    where e.id=run_row.event_boss_id;
  end if;

  wound_rupture_enabled:=coalesce((event_mechanics#>>'{wound_rupture,enabled}')::boolean,false);
  wound_max_stacks:=greatest(1,coalesce((event_mechanics#>>'{wound_rupture,max_stacks}')::integer,3));
  wound_rupture_percent:=greatest(0,coalesce((event_mechanics#>>'{wound_rupture,rupture_max_hp_percent}')::integer,0));
  rage_hunt_enabled:=coalesce((event_mechanics#>>'{rage_hunt,enabled}')::boolean,false);
  rage_self_damage_percent:=greatest(0,coalesce((event_mechanics#>>'{rage_hunt,self_damage_max_hp_percent}')::integer,0));
  rage_dash_damage_percent:=greatest(0,coalesce((event_mechanics#>>'{rage_hunt,dash_damage_percent}')::integer,0));

  adaptive_enabled:=coalesce((event_mechanics#>>'{adaptive_telegraph,enabled}')::boolean,false);
  adaptive_delay_chance:=greatest(0,least(95,coalesce((event_mechanics#>>'{adaptive_telegraph,delay_chance_percent}')::integer,30)));
  adaptive_defensive_delay_chance:=greatest(adaptive_delay_chance,least(98,coalesce((event_mechanics#>>'{adaptive_telegraph,defensive_delay_chance_percent}')::integer,70)));
  adaptive_break_threshold:=greatest(0,coalesce((event_mechanics#>>'{adaptive_telegraph,break_threshold_max_hp_percent}')::integer,0));
  adaptive_break_reduction:=greatest(0,least(80,coalesce((event_mechanics#>>'{adaptive_telegraph,break_special_reduction_percent}')::integer,0)));
  adaptive_ai_state:=coalesce(encounter.enemy_ai_state,'{}'::jsonb);

  bow_family:=private.character_weapon_family(encounter.character_id);
  bow_penetration:=private.character_bow_penetration(encounter.character_id);
  bloodshed_chance:=private.character_bloodshed_chance(encounter.character_id);
  echo_chance:=private.character_echo_strike_chance(encounter.character_id);
  white_fang_active:=private.character_has_white_fang(encounter.character_id);
  bow_dodge:=private.bow_dodge_chance(encounter.player_bow_distance);

  if encounter.player_bow_draw_pending and not player_stunned and p_mode<>'physical' then
    raise exception 'BOW_FULL_DRAW_LOCKED';
  end if;

  next_round:=encounter.round+1;
  player_mana_after:=stats.mana_current;
  player_hp_after:=stats.hp_current;
  enemy_hp_after:=encounter.enemy_hp_current;

  select
    exists(select 1 from public.combat_status_effects where encounter_id=encounter.id and target='player' and effect_type='stun'),
    least(60,coalesce(sum(potency) filter(where effect_type in ('chill','weaken')),0))::integer,
    least(75,coalesce(sum(potency) filter(where effect_type='vulnerable'),0))::integer
  into player_stunned,player_reduction,player_vulnerable
  from public.combat_status_effects
  where encounter_id=encounter.id and target='player';

  if player_stunned or p_mode<>'physical' or bow_family<>'katana' then
    encounter.player_katana_rhythm_stacks:=0;
    update public.combat_encounters
    set player_katana_rhythm_stacks=0
    where id=encounter.id;
  end if;

  if not player_stunned then
    perform private.record_manual_combat_decision(encounter.id,p_mode,p_spell_id);
  end if;

  if player_stunned then
    action_type_value:='stunned';
    player_message:='Персонаж оглушён и пропускает действие.';
  elsif p_mode='physical' then
    player_damage_type:=stats.weapon_damage_type;
    variance:=private.weapon_family_damage_variance(bow_family,stats.luck);

    if private.character_has_equipped_effect(encounter.character_id,'dodge_counter')
       and coalesce((boss_state->>'dodge_counter_ready')::boolean,false)
    then
      boss_penetration:=greatest(0,least(90,
        private.character_equipped_effect_number(
          encounter.character_id,'dodge_counter','next_attack_armor_penetration_percent',45
        )::integer
      ));
      boss_state:=jsonb_set(boss_state,'{dodge_counter_ready}','false'::jsonb,true);
      update public.combat_encounters set boss_item_state=boss_state where id=encounter.id;
    end if;

    if bow_family in ('short_bow','long_bow') then
      bow_release:=encounter.player_bow_draw_pending;
      if bow_family='long_bow' and not bow_release then
        raise exception 'BOW_REQUIRES_FULL_DRAW';
      end if;

      bow_multiplier:=private.bow_distance_multiplier(encounter.player_bow_distance)
        * case when bow_release then 1.60 else 1.00 end;
      boss_bonus:=0;
      if private.character_has_equipped_effect(encounter.character_id,'bow_alternation')
         and bow_release
         and coalesce((boss_state->>'crystal_crack')::boolean,false)
      then
        boss_bonus:=greatest(0,private.character_equipped_effect_number(
          encounter.character_id,'bow_alternation','bonus_armor_penetration_percent',30
        )::integer);
      end if;

      bow_effective_defense:=case
        when bow_release or boss_penetration>0
          then floor(encounter.enemy_defense*(100-least(95,bow_penetration+boss_penetration+boss_bonus))/100.0)::integer
        else encounter.enemy_defense
      end;

      raw_damage:=greatest(
        1,
        private.damage_after_armor(
          round(stats.physical_power*bow_multiplier)::integer+variance,
          bow_effective_defense
        )
      );

      if private.character_has_equipped_effect(encounter.character_id,'bow_alternation') then
        if bow_release and coalesce((boss_state->>'crystal_crack')::boolean,false) then
          boss_bonus:=greatest(0,private.character_equipped_effect_number(
            encounter.character_id,'bow_alternation','crack_bonus_percent',35
          )::integer);
          raw_damage:=greatest(1,round(raw_damage*(100+boss_bonus)/100.0)::integer);
          boss_state:=jsonb_set(boss_state,'{crystal_crack}','false'::jsonb,true);
        elsif not bow_release then
          boss_state:=jsonb_set(boss_state,'{crystal_crack}','true'::jsonb,true);
        end if;
        update public.combat_encounters set boss_item_state=boss_state where id=encounter.id;
      end if;

      action_label:=case when bow_release then 'Полный выстрел' else 'Быстрый выстрел' end;
      action_type_value:=case when bow_release then 'bow_full_release' else 'bow_fast' end;

      if bow_release then
        encounter.player_bow_draw_pending:=false;
        update public.combat_encounters
        set player_bow_draw_pending=false
        where id=encounter.id;
      end if;
    else
      action_label:='Физическая атака';
      action_type_value:='physical';
      raw_damage:=private.weapon_family_physical_raw_damage(
        encounter.character_id,
        stats.physical_power,
        floor(encounter.enemy_defense*(100-boss_penetration)/100.0)::integer,
        encounter.enemy_hp_max,
        variance
      );
    end if;

    base_physical_damage:=raw_damage;

    if private.character_has_equipped_effect(encounter.character_id,'initiative_gap_bonus') then
      boss_bonus:=least(
        private.character_equipped_effect_number(encounter.character_id,'initiative_gap_bonus','max_bonus_percent',20)::integer,
        greatest(
          0,
          floor(
            (stats.initiative-encounter.enemy_initiative)
            /greatest(1,private.character_equipped_effect_number(
              encounter.character_id,'initiative_gap_bonus','initiative_per_percent',3
            ))
          )::integer
        )
      );
      if boss_bonus>0 then
        raw_damage:=greatest(1,round(raw_damage*(100+boss_bonus)/100.0)::integer);
      end if;
    end if;

    if private.character_has_equipped_effect(encounter.character_id,'guard_store') then
      boss_stored:=greatest(0,coalesce((boss_state->>'guard_store')::integer,0));
      if boss_stored>0 then
        raw_damage:=raw_damage+boss_stored;
        boss_state:=jsonb_set(boss_state,'{guard_store}','0'::jsonb,true);
        update public.combat_encounters set boss_item_state=boss_state where id=encounter.id;
      end if;
    end if;

  elsif p_mode='bow_draw' then
    if bow_family not in ('short_bow','long_bow') then raise exception 'BOW_NOT_EQUIPPED'; end if;
    if encounter.player_bow_draw_pending then raise exception 'BOW_ALREADY_DRAWING'; end if;
    encounter.player_bow_draw_pending:=true;
    update public.combat_encounters
    set player_bow_draw_pending=true
    where id=encounter.id;
    player_support_action:=true;
    action_type_value:='bow_draw';
    action_label:='Полный натяг';
    player_message:='Персонаж полностью натягивает тетиву. Следующий ход автоматически выпускает стрелу; дистанция зафиксирована.';

  elsif p_mode='magic' then
    player_damage_type:=stats.magic_damage_type;
    action_label:='Врождённая магическая атака';
    action_type_value:='magic';
    variance:=private.combat_damage_variance(stats.luck);
    raw_damage:=greatest(
      1,
      private.damage_after_armor(
        stats.magic_power+variance,
        encounter.enemy_defense*0.80
      )
    );

  elsif p_mode='guard' then
    guard_active:=true;
    action_type_value:='guard';
    player_message:='Персонаж занимает защитную позицию.';

  elsif p_mode in ('support_spell','support_scroll') then
    if p_mode='support_spell' then
      select s.* into spell
      from public.spell_definitions s
      where s.id=p_spell_id
        and s.enabled=true
        and (
          exists(
            select 1 from public.character_spells cs
            where cs.character_id=encounter.character_id and cs.spell_id=s.id
          )
          or private.character_spell_equipped(encounter.character_id,s.id)
        );

      if spell.id is null then raise exception 'SPELL_NOT_LEARNED'; end if;
      if stats.level<spell.required_level then raise exception 'LEVEL_TOO_LOW'; end if;
      mana_cost:=private.character_effective_spell_mana_cost(encounter.character_id,spell.id);
      if stats.mana_current<mana_cost then raise exception 'NOT_ENOUGH_MANA'; end if;
      player_mana_after:=stats.mana_current-mana_cost;
      action_label:=spell.name;
      action_type_value:='spell_'||spell.slug;
    else
      select ci.* into scroll_item
      from public.character_items ci
      where ci.id=p_character_item_id and ci.character_id=encounter.character_id
      for update;

      if scroll_item.id is null then raise exception 'SCROLL_NOT_AVAILABLE'; end if;

      select d.* into scroll_def
      from public.item_definitions d
      where d.id=scroll_item.item_definition_id
        and d.scroll_mode='cast'
        and d.scroll_spell_id is not null;

      if scroll_def.id is null then raise exception 'ITEM_IS_NOT_COMBAT_SCROLL'; end if;

      select * into spell
      from public.spell_definitions
      where id=scroll_def.scroll_spell_id and enabled=true;

      if spell.id is null then raise exception 'SPELL_NOT_AVAILABLE'; end if;
      action_label:='Свиток: '||spell.name;
      action_type_value:='scroll_'||spell.slug;
    end if;

    if spell.spell_kind not in ('guard','cleanse','buff') then raise exception 'SPELL_NOT_COMBAT_USABLE'; end if;
    player_support_action:=true;

    if spell.spell_kind='guard' then
      if spell.slug='mirror_barrier' then
        encounter.player_reflect_percent:=least(90,greatest(0,spell.support_value));
        update public.combat_encounters
        set player_reflect_percent=encounter.player_reflect_percent
        where id=encounter.id;
        guard_active:=false;
        support_guard_percent:=0;
        player_message:=action_label||' окружает заклинателя зеркальным барьером: следующий прямой удар отразит '
          ||encounter.player_reflect_percent||'% урона обратно во врага.'
          ||case when mana_cost>0 then ' Мана: -'||mana_cost||'.' else '' end;
      else
        encounter.player_reflect_percent:=0;
        update public.combat_encounters
        set player_reflect_percent=0
        where id=encounter.id;
        guard_active:=true;
        support_guard_percent:=least(
          85,
          greatest(
            55,
            round(
              (case
                when p_mode='support_spell'
                  then private.concentrated_spell_percent_value(encounter.character_id,spell.id,spell.support_value)
                else spell.support_value
              end)
              *(100+private.character_religion_modifier_number(encounter.character_id,'shield_spell_bonus'))
              /100.0
            )::integer
          )
        );
        if p_mode='support_spell'
           and private.character_has_equipped_effect(encounter.character_id,'spell_role_alternation')
           and boss_state->>'white_silence_role'='damage'
        then
          support_guard_percent:=least(
            85,
            round(support_guard_percent*(100+private.character_equipped_effect_number(
              encounter.character_id,'spell_role_alternation','support_bonus_percent',20
            ))/100.0)::integer
          );
        end if;
        player_message:=action_label||' создаёт магический щит: -'||support_guard_percent||'% следующего входящего удара.'
          ||case when mana_cost>0 then ' Мана: -'||mana_cost||'.' else '' end;
      end if;
    elsif spell.spell_kind='cleanse' then
      delete from public.combat_status_effects
      where encounter_id=encounter.id and target='player';
      get diagnostics cleansed_count = row_count;

      if encounter.player_wound_stacks>0 then
        cleansed_count:=cleansed_count+1;
        encounter.player_wound_stacks:=0;
        update public.combat_encounters
        set player_wound_stacks=0
        where id=encounter.id;
      end if;

      if cleansed_count>0
         and private.character_has_equipped_effect(encounter.character_id,'debuff_bark')
      then
        boss_extra:=least(
          stats.hp_max-player_hp_after,
          round(stats.hp_max*private.character_equipped_effect_number(
            encounter.character_id,'debuff_bark','cleanse_heal_max_hp_percent',6
          )/100.0)::integer
        );
        if boss_extra>0 then
          player_hp_after:=least(stats.hp_max,player_hp_after+boss_extra);
        end if;
      end if;

      player_reduction:=0;
      player_vulnerable:=0;
      player_message:=action_label||' снимает негативные эффекты: '||cleansed_count||'.'
        ||case when boss_extra>0 then ' Живая кора возвращает '||boss_extra||' HP.' else '' end
        ||case when mana_cost>0 then ' Мана: -'||mana_cost||'.' else '' end;
    else
      encounter.player_spell_damage_bonus_percent:=greatest(
        encounter.player_spell_damage_bonus_percent,
        least(
          100,
          case
            when p_mode='support_spell'
              then private.concentrated_spell_percent_value(encounter.character_id,spell.id,spell.support_value)
            else spell.support_value
          end
        )
      );
      encounter.player_spell_damage_bonus_hits:=greatest(encounter.player_spell_damage_bonus_hits,spell.support_turns);
      update public.combat_encounters
      set player_spell_damage_bonus_percent=encounter.player_spell_damage_bonus_percent,
          player_spell_damage_bonus_hits=encounter.player_spell_damage_bonus_hits
      where id=encounter.id;
      player_message:=action_label||' усиливает прямой урон на '||encounter.player_spell_damage_bonus_percent
        ||'% на следующие '||encounter.player_spell_damage_bonus_hits||' атак.'
        ||case when mana_cost>0 then ' Мана: -'||mana_cost||'.' else '' end;
    end if;

    if p_mode='support_spell'
       and private.character_has_equipped_effect(encounter.character_id,'spell_role_alternation')
    then
      boss_state:=jsonb_set(boss_state,'{white_silence_role}',to_jsonb('support'::text),true);
      update public.combat_encounters set boss_item_state=boss_state where id=encounter.id;
    end if;

    if p_mode='support_spell'
       and mana_cost>0
       and private.character_has_equipped_effect(encounter.character_id,'mana_charge_burst')
    then
      boss_stored:=greatest(0,coalesce((boss_state->>'storm_charge')::integer,0))+mana_cost;
      boss_state:=jsonb_set(boss_state,'{storm_charge}',to_jsonb(boss_stored),true);
      update public.combat_encounters set boss_item_state=boss_state where id=encounter.id;
    end if;

    if p_mode='support_scroll' then
      perform private.log_active_battle_consumable(encounter.character_id,scroll_item.item_definition_id,1,'combat_scroll');
    if scroll_item.quantity<=1 then
        delete from public.character_items where id=scroll_item.id;
      else
        update public.character_items set quantity=quantity-1 where id=scroll_item.id;
      end if;
    end if;

  elsif p_mode='learned_spell' then
    select s.* into spell
    from public.spell_definitions s
    where s.id=p_spell_id
      and s.enabled=true
      and (
        exists(
          select 1 from public.character_spells cs
          where cs.character_id=encounter.character_id and cs.spell_id=s.id
        )
        or private.character_spell_equipped(encounter.character_id,s.id)
      );

    if spell.id is null then raise exception 'SPELL_NOT_LEARNED'; end if;
    if spell.spell_kind not in ('damage','heal','summon') then raise exception 'SPELL_NOT_COMBAT_USABLE'; end if;
    if stats.level<spell.required_level then raise exception 'LEVEL_TOO_LOW'; end if;
    mana_cost:=private.character_effective_spell_mana_cost(encounter.character_id,spell.id);
      if stats.mana_current<mana_cost then raise exception 'NOT_ENOUGH_MANA'; end if;

    player_mana_after:=stats.mana_current-mana_cost;
    action_label:=spell.name;
    action_type_value:='spell_'||spell.slug;

    if spell.spell_kind='heal' then
      if stats.hp_current>=stats.hp_max
         and not private.character_has_equipped_effect(encounter.character_id,'overheal_barrier')
      then raise exception 'ALREADY_FULL_HEALTH'; end if;

      player_support_action:=true;
      boss_intended_heal:=greatest(
        1,
        private.concentrated_spell_direct_value(
          encounter.character_id,
          spell.id,
          round(stats.magic_power*spell.power_multiplier)::integer+spell.flat_power
        )
      );
      boss_intended_heal:=greatest(
        1,
        round(
          boss_intended_heal
          *(100+private.character_religion_modifier_number(encounter.character_id,'healing_spell_bonus'))
          /100.0
        )::integer
      );

      if private.character_has_equipped_effect(encounter.character_id,'spell_role_alternation')
         and boss_state->>'white_silence_role'='damage'
      then
        boss_bonus:=greatest(0,private.character_equipped_effect_number(
          encounter.character_id,'spell_role_alternation','support_bonus_percent',20
        )::integer);
        boss_intended_heal:=greatest(1,round(boss_intended_heal*(100+boss_bonus)/100.0)::integer);
      end if;

      player_heal:=least(greatest(0,stats.hp_max-stats.hp_current),boss_intended_heal);
      boss_overheal:=greatest(0,boss_intended_heal-player_heal);
      player_hp_after:=least(stats.hp_max,stats.hp_current+player_heal);

      if boss_overheal>0
         and private.character_has_equipped_effect(encounter.character_id,'overheal_barrier')
      then
        boss_bonus:=greatest(0,private.character_equipped_effect_number(
          encounter.character_id,'overheal_barrier','barrier_from_overheal_percent',50
        )::integer);
        boss_shield:=least(
          round(stats.hp_max*private.character_equipped_effect_number(
            encounter.character_id,'overheal_barrier','barrier_cap_max_hp_percent',15
          )/100.0)::integer,
          greatest(0,coalesce((boss_state->>'temp_shield')::integer,0))
            +round(boss_overheal*boss_bonus/100.0)::integer
        );
        boss_state:=jsonb_set(boss_state,'{temp_shield}',to_jsonb(boss_shield),true);
      end if;

      if private.character_has_equipped_effect(encounter.character_id,'spell_role_alternation') then
        boss_state:=jsonb_set(boss_state,'{white_silence_role}',to_jsonb('support'::text),true);
      end if;
      update public.combat_encounters set boss_item_state=boss_state where id=encounter.id;

      player_message:=spell.name||' восстанавливает '||player_heal||' HP. Мана: -'||mana_cost||'.'
        ||case when boss_shield>0 then ' Избыточное лечение создаёт барьер '||boss_shield||'.' else '' end;
    elsif spell.spell_kind='summon' then
      player_support_action:=true;
      player_message:='Призвано существо «'
        ||private.create_combat_summon('solo',encounter.id,encounter.character_id,spell.id,next_round)
        ||'». Мана: -'||mana_cost||'.';
    else
      player_damage_type:=spell.damage_type;
      variance:=private.combat_damage_variance(stats.luck);
      raw_damage:=private.concentrated_spell_direct_value(
        encounter.character_id,
        spell.id,
        greatest(
          1,
          private.damage_after_armor(
            round(stats.magic_power*spell.power_multiplier)::integer
            + spell.flat_power
            + variance,
            encounter.enemy_defense*0.65
          )
        )
      );

      if private.character_has_equipped_effect(encounter.character_id,'spell_role_alternation')
         and boss_state->>'white_silence_role'='support'
      then
        boss_bonus:=greatest(0,private.character_equipped_effect_number(
          encounter.character_id,'spell_role_alternation','damage_bonus_percent',18
        )::integer);
        raw_damage:=greatest(1,round(raw_damage*(100+boss_bonus)/100.0)::integer);
      end if;

      if private.character_has_equipped_effect(encounter.character_id,'mana_charge_burst') then
        boss_stored:=greatest(0,coalesce((boss_state->>'storm_charge')::integer,0));
        if boss_stored>=private.character_equipped_effect_number(
          encounter.character_id,'mana_charge_burst','mana_threshold',60
        )::integer then
          boss_bonus:=greatest(0,private.character_equipped_effect_number(
            encounter.character_id,'mana_charge_burst','burst_percent',35
          )::integer);
          raw_damage:=greatest(1,round(raw_damage*(100+boss_bonus)/100.0)::integer);
          boss_stored:=0;
        end if;
        boss_stored:=boss_stored+mana_cost;
        boss_state:=jsonb_set(boss_state,'{storm_charge}',to_jsonb(boss_stored),true);
      end if;

      if private.character_has_equipped_effect(encounter.character_id,'tri_element_constellation') then
        if coalesce((boss_state->>'aster_ready')::boolean,false) then
          boss_bonus:=greatest(0,private.character_equipped_effect_number(
            encounter.character_id,'tri_element_constellation','next_spell_bonus_percent',25
          )::integer);
          raw_damage:=greatest(1,round(raw_damage*(100+boss_bonus)/100.0)::integer);
          player_mana_after:=least(
            stats.mana_max,
            player_mana_after+round(
              mana_cost*private.character_equipped_effect_number(
                encounter.character_id,'tri_element_constellation','mana_refund_percent',25
              )/100.0
            )::integer
          );
          update public.character_progress
          set mana_current=player_mana_after,mana_regen_anchor_at=now(),updated_at=now()
          where character_id=encounter.character_id;
          boss_state:=jsonb_set(boss_state,'{aster_ready}','false'::jsonb,true);
          boss_state:=jsonb_set(boss_state,'{aster_types}','[]'::jsonb,true);
        else
          boss_types:=coalesce(boss_state->'aster_types','[]'::jsonb);
          select coalesce(jsonb_agg(x order by x),'[]'::jsonb),count(*)::integer
          into boss_types,boss_types_count
          from (
            select distinct value::text as x
            from (
              select jsonb_array_elements_text(boss_types) value
              union all select spell.damage_type
            ) t
          ) u;
          boss_state:=jsonb_set(boss_state,'{aster_types}',boss_types,true);
          if boss_types_count>=greatest(2,private.character_equipped_effect_number(
            encounter.character_id,'tri_element_constellation','required_distinct_types',3
          )::integer) then
            boss_state:=jsonb_set(boss_state,'{aster_ready}','true'::jsonb,true);
          end if;
        end if;
      end if;

      if private.character_has_equipped_effect(encounter.character_id,'spell_role_alternation') then
        boss_state:=jsonb_set(boss_state,'{white_silence_role}',to_jsonb('damage'::text),true);
      end if;
      update public.combat_encounters set boss_item_state=boss_state where id=encounter.id;

      apply_effect_type:=spell.status_effect_type;
      apply_effect_chance:=spell.status_effect_chance;
      apply_effect_turns:=spell.status_effect_turns;
      apply_effect_potency:=private.concentrated_spell_status_potency(
        encounter.character_id,spell.id,spell.status_effect_type,spell.status_effect_potency
      );
    end if;

    if spell.spell_kind in ('heal','summon')
       and mana_cost>0
       and private.character_has_equipped_effect(encounter.character_id,'mana_charge_burst')
    then
      boss_stored:=greatest(0,coalesce((boss_state->>'storm_charge')::integer,0))+mana_cost;
      boss_state:=jsonb_set(boss_state,'{storm_charge}',to_jsonb(boss_stored),true);
      update public.combat_encounters set boss_item_state=boss_state where id=encounter.id;
    end if;

  elsif p_mode='scroll_cast' then
    select ci.* into scroll_item
    from public.character_items ci
    where ci.id=p_character_item_id and ci.character_id=encounter.character_id
    for update;

    if scroll_item.id is null then raise exception 'SCROLL_NOT_AVAILABLE'; end if;

    select d.* into scroll_def
    from public.item_definitions d
    where d.id=scroll_item.item_definition_id
      and d.scroll_mode='cast'
      and d.scroll_spell_id is not null;

    if scroll_def.id is null then raise exception 'ITEM_IS_NOT_COMBAT_SCROLL'; end if;

    select * into spell
    from public.spell_definitions
    where id=scroll_def.scroll_spell_id and enabled=true;

    if spell.id is null then raise exception 'SPELL_NOT_AVAILABLE'; end if;
    if spell.spell_kind not in ('damage','heal') then raise exception 'SPELL_NOT_COMBAT_USABLE'; end if;

    action_label:='Свиток: '||spell.name;
    action_type_value:='scroll_'||spell.slug;

    if spell.spell_kind='heal' then
      if stats.hp_current>=stats.hp_max then raise exception 'ALREADY_FULL_HEALTH'; end if;
      player_support_action:=true;
      player_heal:=least(
        stats.hp_max-stats.hp_current,
        greatest(
          1,
          private.concentrated_spell_direct_value(
            encounter.character_id,
            spell.id,
            round(stats.magic_power*spell.power_multiplier)::integer+spell.flat_power
          )
        )
      );
      player_heal:=least(
        stats.hp_max-stats.hp_current,
        greatest(
          1,
          round(
            player_heal
            *(100+private.character_religion_modifier_number(encounter.character_id,'healing_spell_bonus'))
            /100.0
          )::integer
        )
      );
      player_hp_after:=least(stats.hp_max,stats.hp_current+player_heal);
      player_message:=action_label||' восстанавливает '||player_heal||' HP.';
    else
      player_damage_type:=spell.damage_type;
      variance:=private.combat_damage_variance(stats.luck);
      raw_damage:=private.concentrated_spell_direct_value(
        encounter.character_id,
        spell.id,
        greatest(
          1,
          private.damage_after_armor(
            round(stats.magic_power*spell.power_multiplier)::integer
            + spell.flat_power
            + variance,
            encounter.enemy_defense*0.65
          )
        )
      );

      apply_effect_type:=spell.status_effect_type;
      apply_effect_chance:=spell.status_effect_chance;
      apply_effect_turns:=spell.status_effect_turns;
      apply_effect_potency:=private.concentrated_spell_status_potency(
        encounter.character_id,spell.id,spell.status_effect_type,spell.status_effect_potency
      );
    end if;

    perform private.log_active_battle_consumable(encounter.character_id,scroll_item.item_definition_id,1,'combat_scroll');
    if scroll_item.quantity<=1 then
      delete from public.character_items where id=scroll_item.id;
    else
      update public.character_items set quantity=quantity-1 where id=scroll_item.id;
    end if;

  else
    select ci.* into combat_item
    from public.character_items ci
    where ci.id=p_character_item_id and ci.character_id=encounter.character_id
    for update;

    if combat_item.id is null then raise exception 'ITEM_NOT_AVAILABLE'; end if;

    select d.* into combat_item_def
    from public.item_definitions d
    where d.id=combat_item.item_definition_id
      and d.category='consumable'
      and d.scroll_mode is null;

    if combat_item_def.id is null then raise exception 'ITEM_IS_NOT_COMBAT_CONSUMABLE'; end if;
    if stats.level<combat_item_def.required_level then raise exception 'LEVEL_TOO_LOW'; end if;

    select
      coalesce(sum(case when e->>'type'='heal_hp' then greatest(0,(e->>'amount')::integer) else 0 end),0)::integer,
      coalesce(sum(case when e->>'type'='restore_mana' then greatest(0,(e->>'amount')::integer) else 0 end),0)::integer
    into combat_item_heal,combat_item_mana
    from jsonb_array_elements(coalesce(combat_item_def.effects,'[]'::jsonb)) e;

    if combat_item_heal<=0 and combat_item_mana<=0 then
      raise exception 'ITEM_IS_NOT_COMBAT_CONSUMABLE';
    end if;

    player_heal:=least(greatest(0,stats.hp_max-stats.hp_current),combat_item_heal);
    player_mana_restore:=least(greatest(0,stats.mana_max-stats.mana_current),combat_item_mana);

    if player_heal<=0 and player_mana_restore<=0 then
      raise exception 'ALREADY_FULL_RESOURCES';
    end if;

    player_support_action:=true;
    player_hp_after:=least(stats.hp_max,stats.hp_current+player_heal);
    player_mana_after:=least(stats.mana_max,stats.mana_current+player_mana_restore);
    action_label:=combat_item_def.name;
    action_type_value:='item_'||combat_item_def.slug;
    player_message:='Использован предмет «'||combat_item_def.name||'».'
      ||case when player_heal>0 then ' Восстановлено '||player_heal||' HP.' else '' end
      ||case when player_mana_restore>0 then ' Восстановлено '||player_mana_restore||' маны.' else '' end;

    perform private.log_active_battle_consumable(encounter.character_id,combat_item.item_definition_id,1,'combat_item');
    if combat_item.quantity<=1 then
      delete from public.character_items where id=combat_item.id;
    else
      update public.character_items set quantity=quantity-1 where id=combat_item.id;
    end if;
  end if;

  if player_support_action and not player_stunned then
    update public.character_progress
    set hp_current=private.character_effective_hp_to_base(encounter.character_id,player_hp_after),
        mana_current=player_mana_after,
        hp_regen_anchor_at=now(),
        mana_regen_anchor_at=now(),
        updated_at=now()
    where character_id=encounter.character_id;
  elsif mana_cost>0 and not player_stunned then
    update public.character_progress
    set mana_current=player_mana_after,mana_regen_anchor_at=now(),updated_at=now()
    where character_id=encounter.character_id;
  end if;

  if not guard_active and not player_stunned and not player_support_action then
    if p_mode='physical'
       and private.character_has_equipped_effect(encounter.character_id,'block_resonance')
    then
      boss_stack:=greatest(0,coalesce((boss_state->>'black_bell_resonance')::integer,0));
      if boss_stack>0 then
        boss_bonus:=greatest(1,private.character_equipped_effect_number(
          encounter.character_id,'block_resonance','armor_break_percent_per_stack',8
        )::integer)*boss_stack;
        perform private.apply_combat_status_effect(
          encounter.id,'enemy','vulnerable',least(50,boss_bonus),
          greatest(1,private.character_equipped_effect_number(
            encounter.character_id,'block_resonance','break_turns',2
          )::integer),
          'Молот Чёрного Звона'
        );
        boss_state:=jsonb_set(boss_state,'{black_bell_resonance}','0'::jsonb,true);
        update public.combat_encounters set boss_item_state=boss_state where id=encounter.id;
      end if;
    end if;

    select least(75,coalesce(sum(potency) filter(where effect_type='vulnerable'),0))::integer
      into enemy_vulnerable
    from public.combat_status_effects
    where encounter_id=encounter.id and target='enemy';

    if p_mode='physical' then
      type_damage_bonus:=private.character_damage_bonus(encounter.character_id,player_damage_type);
      raw_damage:=greatest(1,round(raw_damage*(100+stats.all_damage_bonus_percent+stats.physical_damage_bonus_percent+type_damage_bonus)/100.0)::integer);
      if encounter.player_counter_bonus_percent>0 then
        raw_damage:=greatest(1,round(raw_damage*(100+encounter.player_counter_bonus_percent)/100.0)::integer);
      end if;
    elsif p_mode in ('magic','learned_spell','scroll_cast') then
      type_damage_bonus:=private.character_damage_bonus(encounter.character_id,player_damage_type);
      raw_damage:=greatest(
        1,
        round(
          raw_damage
          *(
            100
            +stats.all_damage_bonus_percent
            +stats.magic_damage_bonus_percent
            +type_damage_bonus
            +case
              when p_mode in ('learned_spell','scroll_cast') and spell.id is not null
                then private.character_spell_family_damage_bonus_percent(encounter.character_id,spell.id)
              else 0
            end
          )
          /100.0
        )::integer
      );
    end if;

    if encounter.player_spell_damage_bonus_percent>0 and encounter.player_spell_damage_bonus_hits>0 then
      empower_used:=encounter.player_spell_damage_bonus_percent;
      raw_damage:=greatest(1,round(raw_damage*(100+empower_used)/100.0)::integer);
      encounter.player_spell_damage_bonus_hits:=greatest(0,encounter.player_spell_damage_bonus_hits-1);
      if encounter.player_spell_damage_bonus_hits=0 then
        encounter.player_spell_damage_bonus_percent:=0;
      end if;
      update public.combat_encounters
      set player_spell_damage_bonus_percent=encounter.player_spell_damage_bonus_percent,
          player_spell_damage_bonus_hits=encounter.player_spell_damage_bonus_hits
      where id=encounter.id;
    end if;

    if private.combat_encounter_is_strong(encounter.id) or encounter.is_boss then
      raw_damage:=greatest(
        1,
        round(
          raw_damage
          *(
            100
            +case
              when private.combat_encounter_is_strong(encounter.id)
                then private.character_religion_modifier_number(encounter.character_id,'strong_enemy_damage_bonus')
              else 0
            end
            +case when encounter.is_boss then stats.boss_damage_bonus_percent else 0 end
          )
          /100.0
        )::integer
      );
    end if;

    resistance:=private.damage_resistance_percent(encounter.enemy_resistances,player_damage_type);
    if p_mode='physical' then
      resistance:=private.weapon_family_adjust_resistance(bow_family,player_damage_type,resistance);
    end if;
    raw_damage:=greatest(1,round(raw_damage*(100-player_reduction)/100.0)::integer);

    if stats.damage_vs_wounded_percent>0
       and encounter.enemy_hp_max>0
       and encounter.enemy_hp_current*100<=encounter.enemy_hp_max*30
    then
      raw_damage:=greatest(1,round(raw_damage*(100+stats.damage_vs_wounded_percent)/100.0)::integer);
    end if;

    if p_mode='physical' and not exists(
      select 1 from public.combat_turns ct
      where ct.encounter_id=encounter.id
        and ct.actor='player'
        and ct.action_type='physical'
    ) then
      first_strike_multiplier:=private.character_first_physical_strike_multiplier(encounter.character_id);
      first_bonus_multiplier:=private.character_first_physical_bonus_damage_multiplier(encounter.character_id);
      if first_strike_multiplier>1.0 or first_bonus_multiplier>1.0 then
        effective_base_physical_damage:=greatest(
          1,
          round(base_physical_damage*(100-player_reduction)/100.0)::integer
        );
        raw_damage:=private.apply_first_physical_strike_multiplier(
          effective_base_physical_damage,
          raw_damage,
          first_strike_multiplier,
          first_bonus_multiplier
        );
        first_physical_strike_active:=true;
      end if;
    end if;

    if p_mode='physical' and bow_family='katana' then
      katana_rhythm_bonus:=private.katana_rhythm_bonus_percent(
        encounter.player_katana_rhythm_stacks
      );
      if katana_rhythm_bonus>0 then
        raw_damage:=greatest(
          1,
          round(raw_damage*(100+katana_rhythm_bonus)/100.0)::integer
        );
      end if;
    end if;

    player_damage:=greatest(
      1,
      round(raw_damage*(100-resistance)/100.0*(100+enemy_vulnerable)/100.0)::integer
    );

    if p_mode='physical'
       and private.character_has_equipped_effect(encounter.character_id,'special_revenge_element')
    then
      boss_type:=nullif(boss_state->>'revenge_type','');
      if boss_type is not null then
        boss_bonus:=greatest(0,private.character_equipped_effect_number(
          encounter.character_id,'special_revenge_element','echo_percent',30
        )::integer);
        boss_extra:=greatest(
          0,
          round(
            player_damage*boss_bonus/100.0
            *(100-private.damage_resistance_percent(encounter.enemy_resistances,boss_type))/100.0
          )::integer
        );
        player_damage:=player_damage+boss_extra;
        boss_state:=boss_state-'revenge_type';
        update public.combat_encounters set boss_item_state=boss_state where id=encounter.id;
      end if;
    end if;

    if p_mode='physical' and bow_family='dagger' then
      echo_hit_damage:=player_damage;
    end if;

    if encounter.enemy_guard_hits>0 and encounter.enemy_guard_percent>0 then
      enemy_guard_blocked:=greatest(
        0,
        player_damage-greatest(1,ceil(player_damage*(100-encounter.enemy_guard_percent)/100.0)::integer)
      );
      player_damage:=greatest(1,player_damage-enemy_guard_blocked);

      update public.combat_encounters
      set enemy_guard_hits=greatest(0,enemy_guard_hits-1),
          enemy_guard_percent=case when enemy_guard_hits<=1 then 0 else enemy_guard_percent end
      where id=encounter.id;
    end if;

    critical_hit:=false;
    greatsword_crit_bonus:=0;
    if player_damage>0
       and p_mode in ('physical','magic','learned_spell','scroll_cast')
    then
      if p_mode='physical' and bow_family='greatsword' then
        greatsword_crit_bonus:=private.greatsword_crit_bonus_percent(
          encounter.player_greatsword_crit_stacks
        );
        critical_hit:=private.roll_character_critical_with_bonus(
          encounter.character_id,
          greatsword_crit_bonus
        );
      else
        critical_hit:=private.roll_character_critical(encounter.character_id);
      end if;

      if critical_hit then
        player_damage:=private.apply_critical_damage(
          player_damage,
          case when p_mode='physical' then 'physical' else 'magic' end,
          true,
          false
        );
        critical_hits:=critical_hits+1;
      end if;

      if p_mode='physical' and bow_family='greatsword' then
        if critical_hit then
          encounter.player_greatsword_crit_stacks:=0;
        else
          encounter.player_greatsword_crit_stacks:=least(
            5,
            encounter.player_greatsword_crit_stacks+1
          );
        end if;

        update public.combat_encounters
        set player_greatsword_crit_stacks=encounter.player_greatsword_crit_stacks
        where id=encounter.id;
      end if;
    end if;

    if p_mode='physical'
       and bow_family='dagger'
       and player_damage>0
       and echo_chance>0
       and encounter.enemy_hp_current>player_damage
    then
      echo_extra_rolls:=private.roll_echo_strike_extra_hits(echo_chance,50);
      if echo_extra_rolls>0 and echo_hit_damage>0 then
        for hit_index in 1..echo_extra_rolls loop
          exit when encounter.enemy_hp_current<=player_damage+echo_damage;
          echo_single_damage:=echo_hit_damage;
          if private.roll_character_critical(encounter.character_id) then
            echo_single_damage:=private.apply_critical_damage(
              echo_single_damage,'physical',true,false
            );
            critical_hits:=critical_hits+1;
          end if;
          echo_single_damage:=least(
            echo_single_damage,
            greatest(0,encounter.enemy_hp_current-player_damage-echo_damage)
          );
          if echo_single_damage<=0 then exit; end if;
          echo_damage:=echo_damage+echo_single_damage;
          echo_extra_hits:=echo_extra_hits+1;
        end loop;
        player_damage:=player_damage+echo_damage;
        total_physical_hits:=1+echo_extra_hits;
      end if;
    end if;

    player_message:=action_label||' ('||private.damage_type_label(player_damage_type)||') наносит '
      ||player_damage||' урона.'
      ||case when type_damage_bonus>0 then ' Бонус типа урона: +'||type_damage_bonus||'%.' else '' end
      ||case when player_reduction>0 then ' Ослабление: -'||player_reduction||'% силы.' else '' end
      ||case when mana_cost>0 then ' Мана: -'||mana_cost||'.' else '' end
      ||case
        when resistance>0 then ' Сопротивление врага: '||resistance||'%.'
        when resistance<0 then ' Уязвимость врага: +'||abs(resistance)||'% урона.'
        else ''
      end
      ||case when enemy_guard_blocked>0 then ' Защитная стойка врага поглощает '||enemy_guard_blocked||' урона.' else '' end
      ||case when empower_used>0 then ' Магическое усиление: +'||empower_used||'%.' else '' end
      ||case when first_physical_strike_active then ' Первый удар катаны: база ×'||trim(to_char(first_strike_multiplier,'FM9990.0'))||', бонусная часть ×'||trim(to_char(first_bonus_multiplier,'FM9990.0'))||'.' else '' end
      ||case when katana_rhythm_bonus>0 then ' Нарастающий ритм: +'||katana_rhythm_bonus||'% урона.' else '' end
      ||case when critical_hits>0 then ' Критических попаданий: '||critical_hits||'.' else '' end
      ||case when echo_extra_hits>0 then ' Эхо ударов: +'||echo_extra_hits||' доп. удар(а/ов), +'||echo_damage||' урона.' else '' end;

    if p_mode='physical' and bow_family='katana' and not player_stunned then
      encounter.player_katana_rhythm_stacks:=least(
        5,
        encounter.player_katana_rhythm_stacks+1
      );
      update public.combat_encounters
      set player_katana_rhythm_stacks=encounter.player_katana_rhythm_stacks
      where id=encounter.id;
    end if;

    if p_mode='physical' and encounter.player_counter_bonus_percent>0 then
      player_message:=player_message||' Контратака: +'||encounter.player_counter_bonus_percent||'%.';
      update public.combat_encounters
      set player_counter_bonus_percent=0,
          player_counter_blocked_damage=0
      where id=encounter.id;
    end if;

    enemy_hp_after:=greatest(0,enemy_hp_after-player_damage);

    if p_mode='physical'
       and player_damage>0
       and enemy_hp_after>0
       and floor(random()*100)::integer<private.weapon_family_stun_chance(encounter.character_id,false)
    then
      perform private.apply_combat_status_effect(
        encounter.id,'enemy','stun',0,1,'Оглушающий удар'
      );
      player_message:=player_message||' Оглушение: враг пропустит следующий ход.';
    end if;

    if p_mode='physical' and player_damage>0 and bloodshed_chance>0 then
      for hit_index in 1..greatest(1,total_physical_hits) loop
        if floor(random()*100)::integer<bloodshed_chance then
          bloodshed_procs:=bloodshed_procs+1;
        end if;
      end loop;
      if bloodshed_procs>0 then
        encounter.enemy_bloodshed_stacks:=encounter.enemy_bloodshed_stacks+bloodshed_procs;
        update public.combat_encounters
        set enemy_bloodshed_stacks=encounter.enemy_bloodshed_stacks
        where id=encounter.id;
        player_message:=player_message||' Кровопролитие: +'||bloodshed_procs||' стак(а/ов) ('||encounter.enemy_bloodshed_stacks||').';
      end if;
    end if;

    if player_damage>0 and stats.lifesteal_percent>0 then
      unique_heal:=greatest(0,floor(player_damage*stats.lifesteal_percent/100.0)::integer);
      if unique_heal>0 then
        player_hp_after:=least(stats.hp_max,player_hp_after+unique_heal);
        stats.hp_current:=player_hp_after;
        update public.character_progress
        set hp_current=private.character_effective_hp_to_base(encounter.character_id,player_hp_after),hp_regen_anchor_at=now(),updated_at=now()
        where character_id=encounter.character_id;
        player_message:=player_message||' Восстановлено '||unique_heal||' HP.';
      end if;
    end if;

    if player_damage>0 and stats.mana_on_hit>0 then
      unique_mana:=least(
        stats.mana_max-player_mana_after,
        stats.mana_on_hit*case when p_mode='physical' then greatest(1,total_physical_hits) else 1 end
      );
      if unique_mana>0 then
        player_mana_after:=player_mana_after+unique_mana;
        stats.mana_current:=player_mana_after;
        update public.character_progress
        set mana_current=player_mana_after,mana_regen_anchor_at=now(),updated_at=now()
        where character_id=encounter.character_id;
        player_message:=player_message||' Восстановлено '||unique_mana||' маны.';
      end if;
    end if;
  end if;

  if p_mode='physical'
     and white_fang_active
     and player_damage>0
     and enemy_hp_after>0
  then
    if encounter.white_fang_wounds>=3 then
      select * into white_fang_rupture
      from private.white_fang_rupture_roll(encounter.character_id,encounter.enemy_hp_max);

      white_fang_rupture_damage:=least(greatest(0,white_fang_rupture.final_damage),enemy_hp_after);
      enemy_hp_after:=greatest(0,enemy_hp_after-white_fang_rupture_damage);
      encounter.white_fang_wounds:=0;

      update public.combat_encounters
      set white_fang_wounds=0
      where id=encounter.id;

      player_damage:=player_damage+white_fang_rupture_damage;
      player_message:=coalesce(player_message,'')
        ||' Разрыв наносит '||white_fang_rupture_damage||' урона'
        ||case when white_fang_rupture.critical then ' (крит ×1.5).' else '.' end;
    else
      encounter.white_fang_wounds:=least(3,encounter.white_fang_wounds+1);

      update public.combat_encounters
      set white_fang_wounds=encounter.white_fang_wounds
      where id=encounter.id;

      player_message:=coalesce(player_message,'')
        ||' Рваные раны: '||encounter.white_fang_wounds||'/3.';
    end if;
  end if;

  insert into public.combat_turns(
    encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
  )
  values(
    encounter.id,next_round,'player',action_type_value,
    player_damage,player_hp_after,enemy_hp_after,player_message
  );

  -- Persist the player's action before summons or an initiative extra-action can
  -- read/return the encounter. Without this, non-lethal damage existed only in
  -- local PL/pgSQL variables and could be overwritten by the stored old HP.
  update public.combat_encounters
  set enemy_hp_current=enemy_hp_after,
      player_hp_current=player_hp_after,
      player_hp_max=stats.hp_max,
      player_mana_current=player_mana_after,
      player_mana_max=stats.mana_max,
      player_physical_damage_type=stats.weapon_damage_type,
      player_magic_damage_type=stats.magic_damage_type
  where id=encounter.id;

  if enemy_hp_after>0 then
    perform private.resolve_solo_summon_action(encounter.id,next_round);
    select enemy_hp_current into enemy_hp_after
    from public.combat_encounters
    where id=encounter.id;
  end if;

  if enemy_hp_after<=0 then
    return private.finish_combat_victory(
      encounter.id,next_round,player_hp_after,player_mana_after
    );
  end if;

  if not player_stunned then
    tempo_gain:=private.initiative_tempo_gain(stats.initiative,encounter.enemy_initiative);
    tempo_total:=coalesce(encounter.player_initiative_meter,0)+tempo_gain;

    if tempo_total>=100 then
      update public.combat_encounters
      set player_initiative_meter=least(99,tempo_total-100)
      where id=encounter.id;

      insert into public.combat_turns(
        encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
      )
      values(
        encounter.id,next_round,'system','initiative_extra_action',0,
        player_hp_after,enemy_hp_after,
        'Высокая инициатива продвигает персонажа по шкале действий: доступно ещё одно полное действие до хода противника.'
      );

      select * into encounter
      from public.combat_encounters
      where id=encounter.id;

      return encounter;
    elsif tempo_gain>0 then
      update public.combat_encounters
      set player_initiative_meter=least(99,tempo_total)
      where id=encounter.id;
      encounter.player_initiative_meter:=least(99,tempo_total);
    end if;
  end if;

  if encounter.enemy_bloodshed_stacks>0 then
    bloodshed_tick:=private.bloodshed_damage(enemy_hp_after,encounter.enemy_bloodshed_stacks);
    enemy_hp_after:=greatest(0,enemy_hp_after-bloodshed_tick);

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      encounter.id,next_round,'system','bloodshed_tick',bloodshed_tick,player_hp_after,enemy_hp_after,
      'Кровопролитие: '||encounter.enemy_bloodshed_stacks||' стак(а/ов) наносят '||bloodshed_tick||' урона в начале хода противника.'
    );

    update public.combat_encounters
    set enemy_hp_current=enemy_hp_after,enemy_bloodshed_stacks=0
    where id=encounter.id;
    encounter.enemy_bloodshed_stacks:=0;

    if enemy_hp_after<=0 then
      return private.finish_combat_victory(
        encounter.id,next_round,player_hp_after,player_mana_after
      );
    end if;
  end if;

  if encounter.enemy_phase=1
     and encounter.enemy_phase2_hp_percent>0
     and encounter.enemy_hp_max>0
     and enemy_hp_after*100<=encounter.enemy_hp_max*encounter.enemy_phase2_hp_percent
  then
    phase_triggered:=true;
    encounter.enemy_phase:=2;
    if rage_hunt_enabled then
      encounter.enemy_rage_hunt_stacks:=1;
    end if;
    encounter.enemy_attack:=greatest(
      1,
      round(encounter.enemy_attack*(100+encounter.enemy_phase2_attack_bonus_percent)/100.0)::integer
    );
    encounter.enemy_defense:=greatest(
      0,
      round(encounter.enemy_defense*(100+encounter.enemy_phase2_defense_bonus_percent)/100.0)::integer
    );

    if encounter.enemy_phase2_special_every_n>=2 then
      encounter.enemy_special_every_n:=encounter.enemy_phase2_special_every_n;
    end if;

    update public.combat_encounters
    set enemy_phase=2,
        enemy_rage_hunt_stacks=encounter.enemy_rage_hunt_stacks,
        enemy_attack=encounter.enemy_attack,
        enemy_defense=encounter.enemy_defense,
        enemy_special_every_n=encounter.enemy_special_every_n
    where id=encounter.id;

    phase_message:=case
      when btrim(encounter.enemy_phase2_name)<>'' then encounter.enemy_name||': «'||encounter.enemy_phase2_name||'».'
      else encounter.enemy_name||' переходит во вторую фазу.'
    end
      ||case when encounter.enemy_phase2_attack_bonus_percent>0 then ' Атака +'||encounter.enemy_phase2_attack_bonus_percent||'%.' else '' end
      ||case when encounter.enemy_phase2_defense_bonus_percent>0 then ' Защита +'||encounter.enemy_phase2_defense_bonus_percent||'%.' else '' end
      ||case when encounter.enemy_phase2_special_every_n>=2 then ' Особая способность теперь каждые '||encounter.enemy_phase2_special_every_n||' х.' else '' end
      ||case when rage_hunt_enabled then
        ' Яростная охота: каждый обычный удар отнимает у зверя '
        ||rage_self_damage_percent||'% его макс. ОЗ, а шанс слабого Рывка растёт до 4 стаков.'
        else '' end;

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      encounter.id,next_round,'system','boss_phase',0,player_hp_after,enemy_hp_after,phase_message
    );
  end if;

  if not player_stunned
     and apply_effect_type is not null
     and apply_effect_chance>0
     and floor(random()*100)::integer < apply_effect_chance
  then
    perform private.apply_combat_status_effect(
      encounter.id,'enemy',apply_effect_type,apply_effect_potency,
      apply_effect_turns,coalesce(action_label,'Заклинание')
    );

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      encounter.id,next_round,'system','status_apply',0,player_hp_after,enemy_hp_after,
      'На противника наложен эффект «'||private.combat_effect_label(apply_effect_type)
      ||'» на '||apply_effect_turns||' х.'
    );
  end if;

  select
    exists(select 1 from public.combat_status_effects where encounter_id=encounter.id and target='enemy' and effect_type='stun'),
    least(60,coalesce(sum(potency) filter(where effect_type in ('chill','weaken')),0))::integer
  into enemy_stunned,enemy_reduction
  from public.combat_status_effects
  where encounter_id=encounter.id and target='enemy';

  if private.character_has_equipped_effect(encounter.character_id,'untouched_tempo') then
    boss_state:=jsonb_set(boss_state,'{rhythm_clean}','true'::jsonb,true);
    update public.combat_encounters
    set boss_item_state=boss_state
    where id=encounter.id;
  end if;

  player_hp_before_enemy:=player_hp_after;

  if enemy_stunned then
    if encounter.enemy_special_charging then
      enemy_message:=encounter.enemy_name||' теряет подготовку «'||encounter.enemy_special_name||'» из-за оглушения.';
      update public.combat_encounters
      set enemy_special_charging=false,enemy_special_started_round=null
      where id=encounter.id;
      insert into public.combat_turns(
        encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
      )
      values(
        encounter.id,next_round,'enemy','special_interrupted',0,player_hp_after,enemy_hp_after,enemy_message
      );
    else
      enemy_message:=encounter.enemy_name||' оглушён и пропускает атаку.';
      insert into public.combat_turns(
        encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
      )
      values(
        encounter.id,next_round,'enemy','stunned',0,player_hp_after,enemy_hp_after,enemy_message
      );
    end if;

  elsif not encounter.enemy_special_charging
        and encounter.enemy_special_every_n>=2
        and btrim(encounter.enemy_special_name)<>''
        and (
          (encounter.enemy_special_kind='attack' and encounter.enemy_special_damage_multiplier>0)
          or encounter.enemy_special_kind in ('heal','guard','enrage','cleanse')
        )
        and (
          (
            not adaptive_enabled
            and mod(next_round,encounter.enemy_special_every_n)=encounter.enemy_special_every_n-1
          )
          or (
            adaptive_enabled
            and (
              (
                adaptive_ai_state ? 'next_charge_round'
                and next_round>=coalesce((adaptive_ai_state->>'next_charge_round')::integer,next_round)
              )
              or (
                not (adaptive_ai_state ? 'next_charge_round')
                and mod(next_round,encounter.enemy_special_every_n)=encounter.enemy_special_every_n-1
              )
            )
          )
        )
  then
    special_charge_started:=true;
    if adaptive_enabled then
      adaptive_ai_state:=jsonb_set(adaptive_ai_state,'{danger_pending}','true'::jsonb,true);
      adaptive_ai_state:=jsonb_set(adaptive_ai_state,'{delay_used}','false'::jsonb,true);
      adaptive_ai_state:=jsonb_set(adaptive_ai_state,'{charge_hp}',to_jsonb(enemy_hp_after),true);
      adaptive_ai_state:=adaptive_ai_state-'next_charge_round';

      update public.combat_encounters
      set enemy_special_charging=true,
          enemy_special_started_round=next_round,
          enemy_ai_state=adaptive_ai_state
      where id=encounter.id;

      enemy_message:=encounter.enemy_name||' входит в опасный ритм. «'
        ||encounter.enemy_special_name
        ||'» может сорваться в одно из ближайших двух действий. Точный момент неясен.';
    else
      update public.combat_encounters
      set enemy_special_charging=true,enemy_special_started_round=next_round
      where id=encounter.id;

      enemy_message:=case
        when btrim(encounter.enemy_special_telegraph_text)<>'' then encounter.enemy_special_telegraph_text
        else encounter.enemy_name||' начинает готовить «'||encounter.enemy_special_name||'». Эффект сработает на следующем ходу.'
      end;
    end if;

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      encounter.id,next_round,'enemy','special_charge',0,player_hp_after,enemy_hp_after,enemy_message
    );

  else
    special_attack_active:=encounter.enemy_special_charging;

    if special_attack_active and encounter.enemy_special_kind='heal' then
      enemy_heal:=least(
        encounter.enemy_hp_max-enemy_hp_after,
        greatest(1,ceil(encounter.enemy_hp_max*encounter.enemy_special_value/100.0)::integer)
      );
      enemy_hp_after:=least(encounter.enemy_hp_max,enemy_hp_after+enemy_heal);

      enemy_message:=case
        when btrim(encounter.enemy_special_attack_text)<>'' then encounter.enemy_special_attack_text
        else encounter.enemy_name||' применяет «'||encounter.enemy_special_name||'».'
      end||' Восстановлено '||enemy_heal||' HP.';

      insert into public.combat_turns(
        encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
      )
      values(
        encounter.id,next_round,'enemy','special_heal',0,player_hp_after,enemy_hp_after,enemy_message
      );

    elsif special_attack_active and encounter.enemy_special_kind='guard' then
      update public.combat_encounters
      set enemy_guard_percent=greatest(enemy_guard_percent,encounter.enemy_special_value),
          enemy_guard_hits=greatest(enemy_guard_hits,1)
      where id=encounter.id;

      enemy_message:=case
        when btrim(encounter.enemy_special_attack_text)<>'' then encounter.enemy_special_attack_text
        else encounter.enemy_name||' применяет «'||encounter.enemy_special_name||'».'
      end||' Следующая полученная атака будет уменьшена на '||encounter.enemy_special_value||'%.';

      insert into public.combat_turns(
        encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
      )
      values(
        encounter.id,next_round,'enemy','special_guard',0,player_hp_after,enemy_hp_after,enemy_message
      );

    elsif special_attack_active and encounter.enemy_special_kind='enrage' then
      update public.combat_encounters
      set enemy_attack_bonus_percent=greatest(enemy_attack_bonus_percent,encounter.enemy_special_value)
      where id=encounter.id;

      encounter.enemy_attack_bonus_percent:=greatest(
        encounter.enemy_attack_bonus_percent,encounter.enemy_special_value
      );

      enemy_message:=case
        when btrim(encounter.enemy_special_attack_text)<>'' then encounter.enemy_special_attack_text
        else encounter.enemy_name||' применяет «'||encounter.enemy_special_name||'».'
      end||' Сила обычных и особых атак повышена на '||encounter.enemy_special_value||'% до конца боя.';

      insert into public.combat_turns(
        encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
      )
      values(
        encounter.id,next_round,'enemy','special_enrage',0,player_hp_after,enemy_hp_after,enemy_message
      );

    elsif special_attack_active and encounter.enemy_special_kind='cleanse' then
      delete from public.combat_status_effects
      where encounter_id=encounter.id
        and target='enemy';

      enemy_message:=case
        when btrim(encounter.enemy_special_attack_text)<>'' then encounter.enemy_special_attack_text
        else encounter.enemy_name||' применяет «'||encounter.enemy_special_name||'».'
      end||' Все негативные эффекты сняты.';

      insert into public.combat_turns(
        encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
      )
      values(
        encounter.id,next_round,'enemy','special_cleanse',0,player_hp_after,enemy_hp_after,enemy_message
      );

    else
      if private.try_solo_enemy_attack_summon(encounter.id,next_round,special_attack_active) then
        enemy_damage:=0;
      else
      enemy_action_damage_type:=case
        when special_attack_active then coalesce(encounter.enemy_special_damage_type,encounter.enemy_damage_type)
        else encounter.enemy_damage_type
      end;

      variance:=private.combat_damage_variance(0);
      player_defense_value:=case
        when enemy_action_damage_type in ('slashing','piercing','blunt') then
          private.character_physical_defense(stats.level,stats.vitality,stats.agility)
        else private.character_magic_defense(stats.level,stats.vitality,stats.intellect)
      end;
      player_defense_value:=greatest(
        0,
        round(
          player_defense_value
          *(
            100
            +private.character_defense_percent(encounter.character_id)
            +case
              when enemy_action_damage_type in ('slashing','piercing','blunt') then 0
              else private.character_religion_modifier_number(encounter.character_id,'magic_defense_percent')
            end
          )
          /100.0
        )::integer
      );
      enemy_attack_effective:=greatest(
        1,
        round(encounter.enemy_attack*(100+encounter.enemy_attack_bonus_percent)/100.0)::integer
      );

      if special_attack_active then
        raw_damage:=greatest(
          1,
          private.damage_after_armor(
            round(enemy_attack_effective*encounter.enemy_special_damage_multiplier)::integer+variance,
            player_defense_value
          )
        );
      else
        raw_damage:=greatest(
          1,
          private.damage_after_armor(
            enemy_attack_effective+variance,
            player_defense_value
          )
        );
      end if;

      raw_damage:=greatest(1,round(raw_damage*(100-enemy_reduction)/100.0)::integer);

      resistance:=private.damage_resistance_percent(stats.damage_resistances,enemy_action_damage_type);

      if private.character_has_equipped_effect(encounter.character_id,'adaptive_resist')
         and boss_state->>'adaptive_type'=enemy_action_damage_type
         and coalesce((boss_state->>'adaptive_rounds')::integer,0)>0
      then
        resistance:=least(
          75,
          resistance+private.character_equipped_effect_number(
            encounter.character_id,'adaptive_resist','resistance_bonus_percent',25
          )::integer
        );
      end if;

      enemy_damage:=greatest(
        1,
        round(raw_damage*(100-resistance)/100.0*(100+player_vulnerable)/100.0)::integer
      );

      if stats.low_hp_damage_reduction_percent>0
         and stats.hp_max>0
         and player_hp_after*100<=stats.hp_max*30
      then
        enemy_damage:=greatest(1,round(enemy_damage*(100-stats.low_hp_damage_reduction_percent)/100.0)::integer);
      end if;

      if stats.hp_max>0
         and player_hp_after*100<=stats.hp_max*50
         and private.character_religion_modifier_number(encounter.character_id,'low_hp_50_damage_reduction')>0
      then
        enemy_damage:=greatest(
          1,
          round(
            enemy_damage
            *(100-private.character_religion_modifier_number(encounter.character_id,'low_hp_50_damage_reduction'))
            /100.0
          )::integer
        );
      end if;

      if enemy_damage>0
         and private.character_religion_modifier_number(encounter.character_id,'incoming_damage_taken_percent')>0
      then
        enemy_damage:=greatest(
          1,
          round(
            enemy_damage
            *(100+private.character_religion_modifier_number(encounter.character_id,'incoming_damage_taken_percent'))
            /100.0
          )::integer
        );
      end if;

      if enemy_damage>0
         and private.character_has_equipped_effect(encounter.character_id,'debuff_bark')
      then
        select least(
          private.character_equipped_effect_number(encounter.character_id,'debuff_bark','max_stacks',3)::integer,
          count(*)::integer
        )
        into boss_stack
        from public.combat_status_effects
        where encounter_id=encounter.id and target='player';

        if boss_stack>0 then
          boss_bonus:=boss_stack*private.character_equipped_effect_number(
            encounter.character_id,'debuff_bark','defense_percent_per_debuff',6
          )::integer;
          enemy_damage:=greatest(1,round(enemy_damage*(100-least(60,boss_bonus))/100.0)::integer);
        end if;
      end if;

      if enemy_damage>0
         and floor(random()*100)::integer
           <least(75,bow_dodge
            +private.character_religion_modifier_number(encounter.character_id,'evasion_chance')
            +private.character_hidden_favor_evasion_bonus(encounter.character_id))
      then
        player_dodged:=true;
        enemy_damage:=0;

        if private.character_has_equipped_effect(encounter.character_id,'dodge_counter') then
          boss_state:=jsonb_set(boss_state,'{dodge_counter_ready}','true'::jsonb,true);
        end if;
        if private.character_has_equipped_effect(encounter.character_id,'untouched_tempo') then
          boss_state:=jsonb_set(boss_state,'{rhythm_clean}','true'::jsonb,true);
        end if;
        update public.combat_encounters set boss_item_state=boss_state where id=encounter.id;
      end if;

      if encounter.player_reflect_percent>0 and enemy_damage>0 then
        reflected_damage:=least(
          enemy_hp_after,
          greatest(0,floor(enemy_damage*encounter.player_reflect_percent/100.0)::integer)
        );
        enemy_damage:=greatest(0,enemy_damage-reflected_damage);
        enemy_hp_after:=greatest(0,enemy_hp_after-reflected_damage);
        encounter.player_reflect_percent:=0;
        update public.combat_encounters
        set player_reflect_percent=0,
            enemy_hp_current=enemy_hp_after
        where id=encounter.id;
      end if;

      enemy_damage_before_guard:=enemy_damage;

      if guard_active and enemy_damage>0 then
        if support_guard_percent>0 then
          enemy_damage:=greatest(
            1,
            ceil(enemy_damage*greatest(0.15,(100-least(85,support_guard_percent))/100.0))::integer
          );
        else
          enemy_damage:=greatest(
            1,
            ceil(enemy_damage*greatest(0.20,(45-stats.guard_boost_percent)/100.0))::integer
          );
        end if;
      end if;

      if guard_active and enemy_damage>0 then
        blocked_damage:=greatest(0,enemy_damage_before_guard-enemy_damage);
        if blocked_damage>0 then
          counter_bonus:=least(
            50,
            25+floor(blocked_damage*100.0/greatest(1,stats.hp_max))::integer
          );
          if private.character_has_equipped_effect(encounter.character_id,'guard_store') then
            boss_stored:=greatest(0,coalesce((boss_state->>'guard_store')::integer,0));
            boss_stored:=least(
              round(stats.hp_max*private.character_equipped_effect_number(
                encounter.character_id,'guard_store','stored_damage_cap_max_hp_percent',25
              )/100.0)::integer,
              boss_stored+round(blocked_damage*private.character_equipped_effect_number(
                encounter.character_id,'guard_store','stored_damage_percent',40
              )/100.0)::integer
            );
            boss_state:=jsonb_set(boss_state,'{guard_store}',to_jsonb(boss_stored),true);
          end if;

          if private.character_has_equipped_effect(encounter.character_id,'block_resonance') then
            boss_stack:=least(
              private.character_equipped_effect_number(
                encounter.character_id,'block_resonance','max_stacks',3
              )::integer,
              greatest(0,coalesce((boss_state->>'black_bell_resonance')::integer,0))+1
            );
            boss_state:=jsonb_set(boss_state,'{black_bell_resonance}',to_jsonb(boss_stack),true);
          end if;

          update public.combat_encounters
          set player_counter_bonus_percent=greatest(player_counter_bonus_percent,counter_bonus),
              player_counter_blocked_damage=greatest(player_counter_blocked_damage,blocked_damage),
              boss_item_state=boss_state
          where id=encounter.id;
        end if;
      end if;

      if enemy_damage>0
         and private.character_has_equipped_effect(encounter.character_id,'one_shot_cap')
         and coalesce((boss_state->>'zero_sphere_used')::boolean,false)=false
      then
        boss_bonus:=greatest(1,private.character_equipped_effect_number(
          encounter.character_id,'one_shot_cap','max_single_hit_max_hp_percent',35
        )::integer);
        if enemy_damage>round(stats.hp_max*boss_bonus/100.0)::integer then
          enemy_damage:=greatest(1,round(stats.hp_max*boss_bonus/100.0)::integer);
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

      if private.character_has_equipped_effect(encounter.character_id,'adaptive_resist') then
        if enemy_damage>0
           and enemy_action_damage_type not in ('slashing','piercing','blunt')
           and enemy_damage*100>=stats.hp_max*private.character_equipped_effect_number(
             encounter.character_id,'adaptive_resist','trigger_min_damage_percent',8
           )
        then
          boss_state:=jsonb_set(boss_state,'{adaptive_type}',to_jsonb(enemy_action_damage_type),true);
          boss_state:=jsonb_set(
            boss_state,'{adaptive_rounds}',
            to_jsonb(private.character_equipped_effect_number(
              encounter.character_id,'adaptive_resist','duration_rounds',3
            )::integer),true
          );
        elsif coalesce((boss_state->>'adaptive_rounds')::integer,0)>0 then
          boss_state:=jsonb_set(
            boss_state,'{adaptive_rounds}',
            to_jsonb(greatest(0,(boss_state->>'adaptive_rounds')::integer-1)),true
          );
        end if;
      end if;

      if special_attack_active
         and enemy_damage>0
         and private.character_has_equipped_effect(encounter.character_id,'special_revenge_element')
      then
        boss_state:=jsonb_set(boss_state,'{revenge_type}',to_jsonb(enemy_action_damage_type),true);
      end if;

      if enemy_damage>0
         and private.character_has_equipped_effect(encounter.character_id,'untouched_tempo')
      then
        boss_state:=jsonb_set(boss_state,'{rhythm_clean}','false'::jsonb,true);
      end if;

      update public.combat_encounters set boss_item_state=boss_state where id=encounter.id;

      player_hp_after:=greatest(1,player_hp_after-enemy_damage);

      update public.character_progress
      set hp_current=private.character_effective_hp_to_base(encounter.character_id,player_hp_after),
          hp_regen_anchor_at=now(),
          mana_regen_anchor_at=now(),
          updated_at=now()
      where character_id=encounter.character_id;

      enemy_message:=case
        when player_dodged then encounter.enemy_name||' атакует, но персонаж уклоняется.'
        when special_attack_active and btrim(encounter.enemy_special_attack_text)<>'' then encounter.enemy_special_attack_text
        when special_attack_active then encounter.enemy_name||' применяет «'||encounter.enemy_special_name||'».'
        else encounter.enemy_name||' атакует.'
      end
        ||case when player_dodged then '' else ' Нанесено '||enemy_damage||' '||private.damage_type_label(enemy_action_damage_type)||' урона.' end
        ||case when encounter.enemy_attack_bonus_percent>0 then ' Усиление атаки: +'||encounter.enemy_attack_bonus_percent||'%.' else '' end
        ||case when enemy_reduction>0 then ' Эффект ослабляет атаку на '||enemy_reduction||'%.' else '' end
        ||case
          when resistance>0 then ' Сопротивление брони: '||resistance||'%.'
          when resistance<0 then ' Уязвимость брони: +'||abs(resistance)||'% урона.'
          else ''
        end
        ||case when guard_active then ' Защита смягчает удар.' else '' end
        ||case when reflected_damage>0 then ' Зеркальный барьер отражает '||reflected_damage||' урона обратно во врага.' else '' end;

      if guard_active and blocked_damage>0 then
        enemy_message:=enemy_message||' Заблокировано '||blocked_damage
          ||' урона. Подготовлена физическая контратака +'||counter_bonus||'%.';
      end if;

      insert into public.combat_turns(
        encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
      )
      values(
        encounter.id,next_round,'enemy',
        case when special_attack_active then 'special_attack' else 'attack_'||enemy_action_damage_type end,
        enemy_damage,player_hp_after,enemy_hp_after,enemy_message
      );
      end if;
    end if;

    if not special_attack_active then
      if enemy_damage>0 and wound_rupture_enabled then
        if encounter.player_wound_stacks>=wound_max_stacks then
          enemy_rupture_damage:=greatest(
            1,
            ceil(stats.hp_max*wound_rupture_percent/100.0)::integer
          );
          enemy_rupture_damage:=greatest(
            1,
            round(
              enemy_rupture_damage
              *(100+private.character_religion_modifier_number(encounter.character_id,'incoming_damage_taken_percent'))
              /100.0
            )::integer
          );
          encounter.player_wound_stacks:=0;
          player_hp_after:=greatest(1,player_hp_after-enemy_rupture_damage);
          enemy_bonus_damage_total:=enemy_bonus_damage_total+enemy_rupture_damage;

          update public.combat_encounters
          set player_wound_stacks=0
          where id=encounter.id;

          insert into public.combat_turns(
            encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
          )
          values(
            encounter.id,next_round,'system','enemy_rupture',
            enemy_rupture_damage,player_hp_after,enemy_hp_after,
            'Разрыв: накопленные Ранения раскрываются и наносят '
            ||enemy_rupture_damage||' урона ('
            ||wound_rupture_percent||'% макс. ОЗ). Физическая защита и блок не влияют на Разрыв.'
          );
        else
          encounter.player_wound_stacks:=least(wound_max_stacks,encounter.player_wound_stacks+1);

          update public.combat_encounters
          set player_wound_stacks=encounter.player_wound_stacks
          where id=encounter.id;

          insert into public.combat_turns(
            encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
          )
          values(
            encounter.id,next_round,'system','wound_stack',0,player_hp_after,enemy_hp_after,
            'Ранения: '||encounter.player_wound_stacks||'/'||wound_max_stacks
            ||case when encounter.player_wound_stacks>=wound_max_stacks
              then '. Следующая успешная атака может вызвать Разрыв.'
              else '.' end
          );
        end if;
      end if;

      if rage_hunt_enabled and encounter.enemy_phase=2 then
        rage_self_damage:=greatest(
          1,
          ceil(encounter.enemy_hp_max*rage_self_damage_percent/100.0)::integer
        );
        rage_self_damage:=least(rage_self_damage,enemy_hp_after);
        enemy_hp_after:=greatest(0,enemy_hp_after-rage_self_damage);

        insert into public.combat_turns(
          encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
        )
        values(
          encounter.id,next_round,'system','rage_self_damage',
          rage_self_damage,player_hp_after,enemy_hp_after,
          encounter.enemy_name||' в Яростной охоте сжигает '
          ||rage_self_damage||' собственного ОЗ ('||rage_self_damage_percent||'% макс. ОЗ).'
        );

        if enemy_hp_after>0 then
          rage_dash_chance:=case least(4,greatest(1,encounter.enemy_rage_hunt_stacks))
            when 1 then coalesce((event_mechanics#>>'{rage_hunt,dash_chance_1}')::integer,20)
            when 2 then coalesce((event_mechanics#>>'{rage_hunt,dash_chance_2}')::integer,35)
            when 3 then coalesce((event_mechanics#>>'{rage_hunt,dash_chance_3}')::integer,50)
            else coalesce((event_mechanics#>>'{rage_hunt,dash_chance_4}')::integer,70)
          end;

          if floor(random()*100)::integer<greatest(0,least(100,rage_dash_chance)) then
            rage_dash_damage:=greatest(
              1,
              private.damage_after_armor(
                round(enemy_attack_effective*rage_dash_damage_percent/100.0)::integer,
                player_defense_value*0.10
              )
            );
            rage_dash_damage:=greatest(
              1,
              round(rage_dash_damage*(100-resistance)/100.0*(100+player_vulnerable)/100.0)::integer
            );

            rage_dash_dodged:=false;
            if floor(random()*100)::integer
               <least(75,bow_dodge
            +private.character_religion_modifier_number(encounter.character_id,'evasion_chance')
            +private.character_hidden_favor_evasion_bonus(encounter.character_id))
            then
              rage_dash_dodged:=true;
              rage_dash_damage:=0;
            end if;

            if guard_active and rage_dash_damage>0 then
              if support_guard_percent>0 then
                rage_dash_damage:=greatest(
                  1,
                  ceil(rage_dash_damage*greatest(
                    0.15,
                    (100-least(85,support_guard_percent))/100.0
                  ))::integer
                );
              else
                rage_dash_damage:=greatest(
                  1,
                  ceil(rage_dash_damage*greatest(0.20,(45-stats.guard_boost_percent)/100.0))::integer
                );
              end if;
            end if;

            if rage_dash_damage>0 then
              rage_dash_damage:=greatest(
                1,
                round(
                  rage_dash_damage
                  *(100+private.character_religion_modifier_number(encounter.character_id,'incoming_damage_taken_percent'))
                  /100.0
                )::integer
              );
              player_hp_after:=greatest(1,player_hp_after-rage_dash_damage);
              enemy_bonus_damage_total:=enemy_bonus_damage_total+rage_dash_damage;
            end if;

            insert into public.combat_turns(
              encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
            )
            values(
              encounter.id,next_round,'enemy','rage_dash',
              rage_dash_damage,player_hp_after,enemy_hp_after,
              case when rage_dash_dodged
                then encounter.enemy_name||' делает Рывок, но персонаж уклоняется.'
                else encounter.enemy_name||' делает быстрый Рывок и наносит '
                  ||rage_dash_damage||' урона. Рывок не накладывает Ранение.'
              end
            );

            if rage_dash_damage>0
               and wound_rupture_enabled
               and encounter.player_wound_stacks>=wound_max_stacks
            then
              enemy_rupture_damage:=greatest(
            1,
            ceil(stats.hp_max*wound_rupture_percent/100.0)::integer
          );
          enemy_rupture_damage:=greatest(
            1,
            round(
              enemy_rupture_damage
              *(100+private.character_religion_modifier_number(encounter.character_id,'incoming_damage_taken_percent'))
              /100.0
            )::integer
          );
              encounter.player_wound_stacks:=0;
              player_hp_after:=greatest(1,player_hp_after-enemy_rupture_damage);
              enemy_bonus_damage_total:=enemy_bonus_damage_total+enemy_rupture_damage;

              update public.combat_encounters
              set player_wound_stacks=0
              where id=encounter.id;

              insert into public.combat_turns(
                encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
              )
              values(
                encounter.id,next_round,'system','enemy_rupture',
                enemy_rupture_damage,player_hp_after,enemy_hp_after,
                'Рывок раскрывает 3 Ранения. Разрыв наносит '
                ||enemy_rupture_damage||' урона ('
                ||wound_rupture_percent||'% макс. ОЗ), игнорируя физическую защиту и блок.'
              );
            end if;
          end if;

          encounter.enemy_rage_hunt_stacks:=least(4,greatest(1,encounter.enemy_rage_hunt_stacks)+1);
          update public.combat_encounters
          set enemy_rage_hunt_stacks=encounter.enemy_rage_hunt_stacks
          where id=encounter.id;
        end if;
      end if;

      if enemy_bonus_damage_total>0 then
        update public.character_progress
        set hp_current=private.character_effective_hp_to_base(encounter.character_id,player_hp_after),
            hp_regen_anchor_at=now(),
            mana_regen_anchor_at=now(),
            updated_at=now()
        where character_id=encounter.character_id;
      end if;
    end if;

    if special_attack_active then
      update public.combat_encounters
      set enemy_special_charging=false,enemy_special_started_round=null
      where id=encounter.id;
    end if;
  end if;

  -- End-of-round DOT ticks. Spell effects applied this round can tick immediately.
  select coalesce(sum(
    private.status_tick_damage_with_crit(effect_type,potency,encounter.enemy_resistances,source_character_id,false)
  ),0)::integer
  into enemy_dot
  from public.combat_status_effects
  where encounter_id=encounter.id
    and target='enemy'
    and effect_type in ('burn','bleed','poison');

  select coalesce(sum(
    private.status_tick_damage_with_crit(effect_type,potency,stats.damage_resistances,source_character_id,false)
  ),0)::integer
  into player_dot
  from public.combat_status_effects
  where encounter_id=encounter.id
    and target='player'
    and effect_type in ('burn','bleed','poison');

  if enemy_dot>0 then
    enemy_hp_after:=greatest(0,enemy_hp_after-enemy_dot);
    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      encounter.id,next_round,'system','status_tick',enemy_dot,player_hp_after,enemy_hp_after,
      'Эффекты наносят противнику '||enemy_dot||' дополнительного урона.'
    );
  end if;

  if player_dot>0 then
    player_dot:=greatest(
      1,
      round(
        player_dot
        *(100+private.character_religion_modifier_number(encounter.character_id,'incoming_damage_taken_percent'))
        /100.0
      )::integer
    );
    player_hp_after:=greatest(1,player_hp_after-player_dot);
    update public.character_progress
    set hp_current=private.character_effective_hp_to_base(encounter.character_id,player_hp_after),hp_regen_anchor_at=now(),updated_at=now()
    where character_id=encounter.character_id;

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      encounter.id,next_round,'system','status_tick',player_dot,player_hp_after,enemy_hp_after,
      'Негативные эффекты наносят персонажу '||player_dot||' урона.'
    );
  end if;

  -- Existing statuses lose one turn at the end of the round.
  update public.combat_status_effects
  set remaining_turns=remaining_turns-1,updated_at=now()
  where encounter_id=encounter.id;

  delete from public.combat_status_effects
  where encounter_id=encounter.id and remaining_turns<=0;

  if enemy_hp_after<=0 then
    return private.finish_combat_victory(
      encounter.id,next_round,player_hp_after,player_mana_after
    );
  end if;

  if player_hp_before_enemy-enemy_damage-enemy_bonus_damage_total-player_dot<=0 then
    return private.finish_combat_defeat(
      encounter.id,next_round,enemy_hp_after,player_mana_after
    );
  end if;

  -- Enemy status effects are applied after duration ticking, so they start next player turn.
  if special_attack_active
     and enemy_damage>0
     and encounter.enemy_special_kind='attack'
     and encounter.enemy_special_effect_type is not null
     and encounter.enemy_special_effect_chance>0
     and floor(random()*100)::integer < encounter.enemy_special_effect_chance
  then
    perform private.apply_combat_status_effect(
      encounter.id,'player',encounter.enemy_special_effect_type,
      encounter.enemy_special_effect_potency,encounter.enemy_special_effect_turns,
      coalesce(nullif(encounter.enemy_special_name,''),encounter.enemy_name)
    );

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      encounter.id,next_round,'system','status_apply',0,player_hp_after,enemy_hp_after,
      'Особая атака накладывает эффект «'
      ||private.combat_effect_label(encounter.enemy_special_effect_type)||'».'
    );

  elsif not enemy_stunned
     and enemy_damage>0
     and not special_charge_started
     and not special_attack_active
     and encounter.enemy_on_hit_effect_type is not null
     and encounter.enemy_on_hit_effect_chance>0
     and floor(random()*100)::integer < encounter.enemy_on_hit_effect_chance
  then
    perform private.apply_combat_status_effect(
      encounter.id,'player',encounter.enemy_on_hit_effect_type,
      encounter.enemy_on_hit_effect_potency,encounter.enemy_on_hit_effect_turns,
      encounter.enemy_name
    );

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      encounter.id,next_round,'system','status_apply',0,player_hp_after,enemy_hp_after,
      encounter.enemy_name||' накладывает эффект «'
      ||private.combat_effect_label(encounter.enemy_on_hit_effect_type)||'».'
    );
  end if;

  update public.combat_encounters
  set round=next_round,
      enemy_hp_current=enemy_hp_after,
      player_hp_current=player_hp_after,
      player_hp_max=stats.hp_max,
      player_mana_current=player_mana_after,
      player_mana_max=stats.mana_max,
      player_physical_damage_type=stats.weapon_damage_type,
      player_magic_damage_type=stats.magic_damage_type
  where id=encounter.id
  returning * into encounter;

  return encounter;
end;
$function$

