CREATE OR REPLACE FUNCTION private.critical_chance_from_luck(p_luck integer)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog'
AS $function$
  select least(75.0, greatest(0.0, 1.0 + greatest(0,coalesce(p_luck,0))*0.3));
$function$;

CREATE OR REPLACE FUNCTION private.character_critical_chance(p_character_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  select least(
    75.0,
    private.critical_chance_from_luck(s.luck)
      + private.race_trait_number(p_character_id,'critical_chance_bonus')
      + private.character_hidden_favor_crit_bonus(p_character_id)
  )
  from private.get_character_combat_stats(p_character_id) s;
$function$;

CREATE OR REPLACE FUNCTION private.roll_character_critical_with_bonus(p_character_id uuid, p_bonus_percent numeric)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  chance numeric:=0;
begin
  if p_character_id is null then
    return false;
  end if;

  chance:=least(
    75.0,
    greatest(
      0.0,
      coalesce(private.character_critical_chance(p_character_id),0)
      + greatest(0,coalesce(p_bonus_percent,0))
    )
  );

  return random()*100 < chance;
end;
$function$;

CREATE OR REPLACE FUNCTION private.greatsword_crit_bonus_percent(p_stacks integer)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog'
AS $function$
  select least(75,greatest(0,coalesce(p_stacks,0))*15);
$function$;

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

    if bow_family in ('short_bow','long_bow') then
      bow_release:=encounter.player_bow_draw_pending;
      if bow_family='long_bow' and not bow_release then
        raise exception 'BOW_REQUIRES_FULL_DRAW';
      end if;

      bow_multiplier:=private.bow_distance_multiplier(encounter.player_bow_distance)
        * case when bow_release then 1.60 else 1.00 end;
      bow_effective_defense:=case
        when bow_release then floor(encounter.enemy_defense*(100-bow_penetration)/100.0)::integer
        else encounter.enemy_defense
      end;

      raw_damage:=greatest(
        1,
        private.damage_after_armor(
          round(stats.physical_power*bow_multiplier)::integer+variance,
          bow_effective_defense
        )
      );
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
        encounter.enemy_defense,
        encounter.enemy_hp_max,
        variance
      );
    end if;

    base_physical_damage:=raw_damage;

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
      from public.character_spells cs
      join public.spell_definitions s on s.id=cs.spell_id
      where cs.character_id=encounter.character_id
        and cs.spell_id=p_spell_id
        and s.enabled=true;

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
      player_message:=action_label||' создаёт магический щит: -'||support_guard_percent||'% следующего входящего удара.'
        ||case when mana_cost>0 then ' Мана: -'||mana_cost||'.' else '' end;
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

      player_reduction:=0;
      player_vulnerable:=0;
      player_message:=action_label||' снимает негативные эффекты: '||cleansed_count||'.'
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
    from public.character_spells cs
    join public.spell_definitions s on s.id=cs.spell_id
    where cs.character_id=encounter.character_id
      and cs.spell_id=p_spell_id
      and s.enabled=true;

    if spell.id is null then raise exception 'SPELL_NOT_LEARNED'; end if;
    if spell.spell_kind not in ('damage','heal') then raise exception 'SPELL_NOT_COMBAT_USABLE'; end if;
    if stats.level<spell.required_level then raise exception 'LEVEL_TOO_LOW'; end if;
    mana_cost:=private.character_effective_spell_mana_cost(encounter.character_id,spell.id);
      if stats.mana_current<mana_cost then raise exception 'NOT_ENOUGH_MANA'; end if;

    player_mana_after:=stats.mana_current-mana_cost;
    action_label:=spell.name;
    action_type_value:='spell_'||spell.slug;

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
      player_message:=spell.name||' восстанавливает '||player_heal||' HP. Мана: -'||mana_cost||'.';
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

  if enemy_hp_after<=0 then
    return private.finish_combat_victory(
      encounter.id,next_round,player_hp_after,player_mana_after
    );
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
        and mod(next_round,encounter.enemy_special_every_n)=encounter.enemy_special_every_n-1
  then
    special_charge_started:=true;
    update public.combat_encounters
    set enemy_special_charging=true,enemy_special_started_round=next_round
    where id=encounter.id;

    enemy_message:=case
      when btrim(encounter.enemy_special_telegraph_text)<>'' then encounter.enemy_special_telegraph_text
      else encounter.enemy_name||' начинает готовить «'||encounter.enemy_special_name||'». Эффект сработает на следующем ходу.'
    end;

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
         and floor(random()*100)::integer
           <least(75,bow_dodge
            +private.character_religion_modifier_number(encounter.character_id,'evasion_chance')
            +private.character_hidden_favor_evasion_bonus(encounter.character_id))
      then
        player_dodged:=true;
        enemy_damage:=0;
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
          update public.combat_encounters
          set player_counter_bonus_percent=greatest(player_counter_bonus_percent,counter_bonus),
              player_counter_blocked_damage=greatest(player_counter_blocked_damage,blocked_damage)
          where id=encounter.id;
        end if;
      end if;

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
        ||case when guard_active then ' Защита смягчает удар.' else '' end;

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
$function$;

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
  if private.party_status_stunned(encounter.id,'member',p_character_id) then
    raise exception 'PARTY_MEMBER_STUNNED';
  end if;

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

    if p_action='physical' then
      if bow_family in ('short_bow','long_bow') then
        bow_release:=member_state.bow_draw_pending;
        if bow_family='long_bow' and not bow_release then
          raise exception 'BOW_REQUIRES_FULL_DRAW';
        end if;

        bow_multiplier:=private.bow_distance_multiplier(member_state.bow_distance)
          * case when bow_release then 1.60 else 1.00 end;
        bow_effective_defense:=case
          when bow_release then floor(encounter.enemy_defense*(100-bow_penetration)/100.0)::integer
          else encounter.enemy_defense
        end;
        raw_damage:=greatest(
          1,
          private.damage_after_armor(
            round(stats.physical_power*bow_multiplier)::integer+variance,
            bow_effective_defense
          )
        );
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
          encounter.enemy_defense,
          encounter.enemy_hp_max,
          variance
        );
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

  return private.advance_party_combat_round(encounter.id,p_character_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.perform_pvp_duel_action(p_duel_id uuid, p_action text, p_spell_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid:=auth.uid();
  d public.pvp_duels;
  actor public.pvp_duel_states;
  target public.pvp_duel_states;
  spell public.spell_definitions;
  actor_id uuid;
  target_id uuid;
  actor_name text;
  target_name text;
  action_type_value text;
  action_label text;
  message_text text;
  damage_type text;
  variance integer:=0;
  raw_damage integer:=0;
  damage_value integer:=0;
  heal_value integer:=0;
  resistance integer:=0;
  actor_reduction integer:=0;
  target_vulnerable integer:=0;
  actor_dot integer:=0;
  stunned boolean:=false;
  blocked integer:=0;
  counter_bonus integer:=0;
  lifesteal_heal integer:=0;
  mana_restore integer:=0;
  apply_effect_type text;
  apply_effect_chance integer:=0;
  apply_effect_turns integer:=0;
  apply_effect_potency integer:=0;
  guard_value integer:=0;
  empower_used integer:=0;
  cleanse_count integer:=0;
  type_damage_bonus integer:=0;
  base_physical_damage integer:=0;
  effective_base_physical_damage integer:=0;
  first_strike_multiplier numeric:=1.0;
  first_bonus_multiplier numeric:=1.0;
  first_physical_strike_active boolean:=false;
  katana_rhythm_bonus integer:=0;
  actor_bow_family text;
  target_bow_family text;
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
  echo_single_damage integer:=0;
  echo_damage integer:=0;
  echo_dodges integer:=0;
  total_physical_hits integer:=1;
  bloodshed_procs integer:=0;
  hit_index integer:=0;
  target_bow_dodge integer:=0;
  target_dodged boolean:=false;
  weapon_stun_proc boolean:=false;
  critical_hit boolean:=false;
  critical_hits integer:=0;
  greatsword_crit_bonus integer:=0;
  white_fang_active boolean:=false;
  white_fang_rupture record;
  white_fang_rupture_damage integer:=0;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_action not in ('physical','bow_draw','magic','guard','spell') then
    raise exception 'INVALID_DUEL_ACTION';
  end if;

  select * into d
  from public.pvp_duels
  where id=p_duel_id
  for update;

  if d.id is null then raise exception 'DUEL_NOT_FOUND'; end if;
  if d.status<>'active' then raise exception 'DUEL_NOT_ACTIVE'; end if;

  actor_id:=d.current_turn_character_id;
  if actor_id is null then raise exception 'DUEL_HAS_NO_TURN'; end if;

  if not exists(
    select 1 from public.characters
    where id=actor_id and owner_user_id=caller_id
  ) then raise exception 'NOT_YOUR_TURN'; end if;

  target_id:=case when actor_id=d.challenger_character_id
    then d.opponent_character_id else d.challenger_character_id end;

  select * into actor
  from public.pvp_duel_states
  where duel_id=d.id and character_id=actor_id
  for update;

  select * into target
  from public.pvp_duel_states
  where duel_id=d.id and character_id=target_id
  for update;

  if actor.character_id is null or target.character_id is null then
    raise exception 'DUEL_STATE_NOT_FOUND';
  end if;

  select name into actor_name from public.characters where id=actor_id;
  select name into target_name from public.characters where id=target_id;

  actor_bow_family:=private.character_weapon_family(actor_id);
  target_bow_family:=private.character_weapon_family(target_id);
  bow_penetration:=private.character_bow_penetration(actor_id);
  bloodshed_chance:=private.character_bloodshed_chance(actor_id);
  echo_chance:=private.character_echo_strike_chance(actor_id);
  white_fang_active:=private.character_has_white_fang(actor_id);
  target_bow_dodge:=private.bow_dodge_chance(target.bow_distance);

  if actor.bloodshed_stacks>0 then
    bloodshed_tick:=private.bloodshed_damage(actor.hp_current,actor.bloodshed_stacks);
    bloodshed_tick:=greatest(
      1,
      round(
        bloodshed_tick
        *(100+private.character_religion_modifier_number(actor_id,'incoming_damage_taken_percent'))
        /100.0
      )::integer
    );
    actor.hp_current:=greatest(0,actor.hp_current-bloodshed_tick);

    update public.pvp_duel_states
    set hp_current=actor.hp_current,bloodshed_stacks=0,updated_at=now()
    where duel_id=d.id and character_id=actor_id;
    actor.bloodshed_stacks:=0;

    insert into public.pvp_duel_turns(
      duel_id,round,actor_character_id,action_type,damage,message
    )
    values(
      d.id,d.round,actor_id,'bloodshed_tick',bloodshed_tick,
      'Кровопролитие срабатывает в начале хода '||coalesce(actor_name,'персонажа')||
      ' и наносит '||bloodshed_tick||' урона.'
    );

    if actor.hp_current<=0 then
      perform private.finish_pvp_duel(d.id,target_id,'bloodshed_knockout');
      return public.get_pvp_duel(d.id);
    end if;
  end if;

  select coalesce(sum(private.status_tick_damage_with_crit(effect_type,potency,actor.damage_resistances,source_character_id,false)),0)::integer
  into actor_dot
  from public.pvp_duel_status_effects
  where duel_id=d.id and target_character_id=actor_id
    and effect_type in ('burn','bleed','poison');

  if actor_dot>0 then
    actor_dot:=greatest(
      1,
      round(
        actor_dot
        *(100+private.character_religion_modifier_number(actor_id,'incoming_damage_taken_percent'))
        /100.0
      )::integer
    );
    actor.hp_current:=greatest(0,actor.hp_current-actor_dot);
    update public.pvp_duel_states
    set hp_current=actor.hp_current,updated_at=now()
    where duel_id=d.id and character_id=actor_id;

    insert into public.pvp_duel_turns(
      duel_id,round,actor_character_id,action_type,damage,message
    )
    values(
      d.id,d.round,actor_id,'status_tick',actor_dot,
      'Негативные эффекты наносят '||coalesce(actor_name,'персонажу')||' '||actor_dot||' урона.'
    );

    if actor.hp_current<=0 then
      perform private.finish_pvp_duel(d.id,target_id,'status_knockout');
      return public.get_pvp_duel(d.id);
    end if;
  end if;

  select
    exists(
      select 1 from public.pvp_duel_status_effects
      where duel_id=d.id and target_character_id=actor_id and effect_type='stun'
    ),
    least(60,coalesce(sum(potency) filter(where effect_type in ('chill','weaken')),0))::integer
  into stunned,actor_reduction
  from public.pvp_duel_status_effects
  where duel_id=d.id and target_character_id=actor_id;

  select least(75,coalesce(sum(potency) filter(where effect_type='vulnerable'),0))::integer
  into target_vulnerable
  from public.pvp_duel_status_effects
  where duel_id=d.id and target_character_id=target_id;

  if stunned or p_action<>'physical' or actor_bow_family<>'katana' then
    actor.katana_rhythm_stacks:=0;
    actor.katana_rhythm_target_id:=null;
  elsif actor.katana_rhythm_target_id is distinct from target_id then
    actor.katana_rhythm_stacks:=0;
    actor.katana_rhythm_target_id:=target_id;
  end if;

  if stunned then
    action_type_value:='stunned';
    message_text:=coalesce(actor_name,'Персонаж')||' оглушён и пропускает ход.';
  elsif actor.bow_draw_pending and p_action<>'physical' then
    raise exception 'BOW_FULL_DRAW_LOCKED';
  elsif p_action='bow_draw' then
    if actor_bow_family not in ('short_bow','long_bow') then raise exception 'BOW_NOT_EQUIPPED'; end if;
    if actor.bow_draw_pending then raise exception 'BOW_ALREADY_DRAWING'; end if;
    actor.bow_draw_pending:=true;
    update public.pvp_duel_states
    set bow_draw_pending=true,updated_at=now()
    where duel_id=d.id and character_id=actor_id;
    action_type_value:='bow_draw';
    message_text:=coalesce(actor_name,'Персонаж')||
      ' полностью натягивает тетиву. Следующий ход автоматически выпускает стрелу; дистанция зафиксирована.';
  elsif p_action='guard' then
    guard_value:=least(80,55+greatest(0,actor.guard_boost_percent));
    actor.guard_reduction_percent:=greatest(actor.guard_reduction_percent,guard_value);

    update public.pvp_duel_states
    set guard_reduction_percent=actor.guard_reduction_percent,updated_at=now()
    where duel_id=d.id and character_id=actor_id;

    action_type_value:='guard';
    message_text:=coalesce(actor_name,'Персонаж')||' занимает защитную позицию. Следующая атака будет ослаблена на '
      ||actor.guard_reduction_percent||'%.';
  else
    if p_action='physical' then
      damage_type:=actor.weapon_damage_type;
      variance:=private.weapon_family_damage_variance(actor_bow_family,actor.luck);

      if actor_bow_family in ('short_bow','long_bow') then
        bow_release:=actor.bow_draw_pending;
        if actor_bow_family='long_bow' and not bow_release then
          raise exception 'BOW_REQUIRES_FULL_DRAW';
        end if;

        bow_multiplier:=private.bow_distance_multiplier(actor.bow_distance)
          * case when bow_release then 1.60 else 1.00 end;
        bow_effective_defense:=case
          when bow_release then floor(target.physical_defense*(100-bow_penetration)/100.0)::integer
          else target.physical_defense
        end;
        raw_damage:=greatest(
          1,
          private.damage_after_armor(
            round(actor.physical_power*bow_multiplier)::integer+variance,
            bow_effective_defense
          )
        );
        action_type_value:=case when bow_release then 'bow_full_release' else 'bow_fast' end;
        action_label:=case when bow_release then 'Полный выстрел' else 'Быстрый выстрел' end;

        if bow_release then
          actor.bow_draw_pending:=false;
        end if;
      else
        action_type_value:='physical';
        action_label:='Физическая атака';
        raw_damage:=private.weapon_family_physical_raw_damage(
          actor_id,
          actor.physical_power,
          target.physical_defense,
          target.hp_max,
          variance
        );
      end if;
      base_physical_damage:=raw_damage;
      type_damage_bonus:=private.damage_bonus_percent(actor.damage_bonuses,damage_type);
      raw_damage:=greatest(1,round(raw_damage*(100+actor.all_damage_bonus_percent+actor.physical_damage_bonus_percent+type_damage_bonus)/100.0)::integer);

      if actor.counter_bonus_percent>0 then
        raw_damage:=greatest(1,round(raw_damage*(100+actor.counter_bonus_percent)/100.0)::integer);
        action_label:=action_label||' · контратака +'||actor.counter_bonus_percent||'%';
        actor.counter_bonus_percent:=0;
      end if;

    elsif p_action='magic' then
      action_type_value:='magic';
      action_label:='Врождённая магическая атака';
      damage_type:=actor.magic_damage_type;
      variance:=private.combat_damage_variance(actor.luck);
      raw_damage:=greatest(
        1,
        private.damage_after_armor(
          actor.magic_power+variance,
          target.magic_defense
        )
      );
      type_damage_bonus:=private.damage_bonus_percent(actor.damage_bonuses,damage_type);
      raw_damage:=greatest(1,round(raw_damage*(100+actor.all_damage_bonus_percent+actor.magic_damage_bonus_percent+type_damage_bonus)/100.0)::integer);

    else
      if p_spell_id is null then raise exception 'SPELL_REQUIRED'; end if;

      select s.* into spell
      from public.character_spells cs
      join public.spell_definitions s on s.id=cs.spell_id
      where cs.character_id=actor_id and cs.spell_id=p_spell_id and s.enabled=true;

      if spell.id is null then raise exception 'SPELL_NOT_LEARNED'; end if;
      if not private.character_spell_equipped(actor_id,p_spell_id) then
        raise exception 'SPELL_NOT_IN_LOADOUT';
      end if;
      if actor.level<spell.required_level then raise exception 'LEVEL_TOO_LOW'; end if;
      if actor.mana_current<private.character_effective_spell_mana_cost(actor_id,spell.id) then raise exception 'NOT_ENOUGH_MANA'; end if;
      if spell.spell_kind not in ('damage','heal','guard','cleanse','buff') then raise exception 'SPELL_NOT_COMBAT_USABLE'; end if;

      actor.mana_current:=actor.mana_current-private.character_effective_spell_mana_cost(actor_id,spell.id);
      action_type_value:='spell_'||spell.slug;
      action_label:=spell.name;

      if spell.spell_kind='heal' then
        if actor.hp_current>=actor.hp_max then raise exception 'ALREADY_FULL_HEALTH'; end if;

        heal_value:=least(
          actor.hp_max-actor.hp_current,
          greatest(
            1,
            private.concentrated_spell_direct_value(
              actor_id,
              spell.id,
              round(actor.magic_power*spell.power_multiplier)::integer+spell.flat_power
            )
          )
        );
        heal_value:=least(
          actor.hp_max-actor.hp_current,
          greatest(
            1,
            round(
              heal_value
              *(100+private.character_religion_modifier_number(actor_id,'healing_spell_bonus'))
              /100.0
            )::integer
          )
        );
        actor.hp_current:=least(actor.hp_max,actor.hp_current+heal_value);
        message_text:=coalesce(actor_name,'Персонаж')||' использует «'||spell.name||'» и восстанавливает '
          ||heal_value||' HP. Мана: -'||private.character_effective_spell_mana_cost(actor_id,spell.id)||'.';
      elsif spell.spell_kind='guard' then
        guard_value:=least(
          85,
          greatest(
            55,
            round(
              private.concentrated_spell_percent_value(actor_id,spell.id,spell.support_value)
              *(100+private.character_religion_modifier_number(actor_id,'shield_spell_bonus'))
              /100.0
            )::integer
          )
        );
        actor.guard_reduction_percent:=greatest(actor.guard_reduction_percent,guard_value);
        message_text:=coalesce(actor_name,'Персонаж')||' использует «'||spell.name
          ||'». Следующий полученный удар будет ослаблен на '||actor.guard_reduction_percent
          ||'%. Мана: -'||private.character_effective_spell_mana_cost(actor_id,spell.id)||'.';
      elsif spell.spell_kind='cleanse' then
        delete from public.pvp_duel_status_effects
        where duel_id=d.id and target_character_id=actor_id;
        get diagnostics cleanse_count = row_count;
        actor_reduction:=0;
        message_text:=coalesce(actor_name,'Персонаж')||' использует «'||spell.name
          ||'» и снимает негативные эффекты: '||cleanse_count||'. Мана: -'||private.character_effective_spell_mana_cost(actor_id,spell.id)||'.';
      elsif spell.spell_kind='buff' then
        actor.spell_damage_bonus_percent:=greatest(
          actor.spell_damage_bonus_percent,
          least(100,private.concentrated_spell_percent_value(actor_id,spell.id,spell.support_value))
        );
        actor.spell_damage_bonus_hits:=greatest(actor.spell_damage_bonus_hits,spell.support_turns);
        message_text:=coalesce(actor_name,'Персонаж')||' использует «'||spell.name
          ||'»: +'||actor.spell_damage_bonus_percent||'% прямого урона на следующие '
          ||actor.spell_damage_bonus_hits||' атак. Мана: -'||private.character_effective_spell_mana_cost(actor_id,spell.id)||'.';
      else
        damage_type:=spell.damage_type;
        variance:=private.combat_damage_variance(actor.luck);
        raw_damage:=private.concentrated_spell_direct_value(
          actor_id,
          spell.id,
          greatest(
            1,
            private.damage_after_armor(
              round(actor.magic_power*spell.power_multiplier)::integer
                + spell.flat_power
                + variance,
              target.magic_defense*0.65
            )
          )
        );
        type_damage_bonus:=private.damage_bonus_percent(actor.damage_bonuses,damage_type);
      raw_damage:=greatest(
        1,
        round(
          raw_damage
          *(
            100
            +actor.all_damage_bonus_percent
            +actor.magic_damage_bonus_percent
            +type_damage_bonus
            +private.character_spell_family_damage_bonus_percent(actor_id,spell.id)
          )
          /100.0
        )::integer
      );
        apply_effect_type:=spell.status_effect_type;
        apply_effect_chance:=spell.status_effect_chance;
        apply_effect_turns:=spell.status_effect_turns;
        apply_effect_potency:=private.concentrated_spell_status_potency(
          actor_id,spell.id,spell.status_effect_type,spell.status_effect_potency
        );
      end if;
    end if;

    if raw_damage>0 then
      if actor.spell_damage_bonus_percent>0 and actor.spell_damage_bonus_hits>0 then
        empower_used:=actor.spell_damage_bonus_percent;
        raw_damage:=greatest(1,round(raw_damage*(100+empower_used)/100.0)::integer);
        actor.spell_damage_bonus_hits:=greatest(0,actor.spell_damage_bonus_hits-1);
        if actor.spell_damage_bonus_hits=0 then actor.spell_damage_bonus_percent:=0; end if;
      end if;
      raw_damage:=greatest(1,round(raw_damage*(100-actor_reduction)/100.0)::integer);

      if target.hp_max>0
         and target.hp_current*100<=target.hp_max*30
         and actor.damage_vs_wounded_percent>0
      then
        raw_damage:=greatest(1,round(raw_damage*(100+actor.damage_vs_wounded_percent)/100.0)::integer);
      end if;

      if p_action='physical' and not exists(
        select 1 from public.pvp_duel_turns pdt
        where pdt.duel_id=d.id
          and pdt.actor_character_id=actor_id
          and pdt.action_type='physical'
      ) then
        first_strike_multiplier:=private.character_first_physical_strike_multiplier(actor_id);
        first_bonus_multiplier:=private.character_first_physical_bonus_damage_multiplier(actor_id);
        if first_strike_multiplier>1.0 or first_bonus_multiplier>1.0 then
          effective_base_physical_damage:=greatest(
            1,
            round(base_physical_damage*(100-actor_reduction)/100.0)::integer
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

      if p_action='physical' and actor_bow_family='katana' then
        katana_rhythm_bonus:=private.katana_rhythm_bonus_percent(
          actor.katana_rhythm_stacks
        );
        if katana_rhythm_bonus>0 then
          raw_damage:=greatest(
            1,
            round(raw_damage*(100+katana_rhythm_bonus)/100.0)::integer
          );
        end if;
      end if;

      resistance:=private.damage_resistance_percent(target.damage_resistances,damage_type);
      if p_action='physical' then
        resistance:=private.weapon_family_adjust_resistance(actor_bow_family,damage_type,resistance);
      end if;
      damage_value:=greatest(
        1,
        round(raw_damage*(100-resistance)/100.0*(100+target_vulnerable)/100.0)::integer
      );

      if target.hp_max>0
         and target.hp_current*100<=target.hp_max*30
         and target.low_hp_damage_reduction_percent>0
      then
        damage_value:=greatest(
          1,
          round(damage_value*(100-target.low_hp_damage_reduction_percent)/100.0)::integer
        );
      end if;

      if target.hp_max>0
         and target.hp_current*100<=target.hp_max*50
         and private.character_religion_modifier_number(target_id,'low_hp_50_damage_reduction')>0
      then
        damage_value:=greatest(
          1,
          round(
            damage_value
            *(100-private.character_religion_modifier_number(target_id,'low_hp_50_damage_reduction'))
            /100.0
          )::integer
        );
      end if;

      if damage_value>0
         and private.character_religion_modifier_number(target_id,'incoming_damage_taken_percent')>0
      then
        damage_value:=greatest(
          1,
          round(
            damage_value
            *(100+private.character_religion_modifier_number(target_id,'incoming_damage_taken_percent'))
            /100.0
          )::integer
        );
      end if;

      if p_action='physical' and actor_bow_family='dagger' then
        echo_hit_damage:=damage_value;
      end if;

      if damage_value>0
         and floor(random()*100)::integer
           <least(75,target_bow_dodge
            +private.character_religion_modifier_number(target_id,'evasion_chance')
            +private.character_hidden_favor_evasion_bonus(target_id))
      then
        target_dodged:=true;
        damage_value:=0;
      end if;

      if target.guard_reduction_percent>0 and damage_value>0 then
        blocked:=greatest(
          0,
          damage_value-greatest(1,ceil(damage_value*(100-target.guard_reduction_percent)/100.0)::integer)
        );
        damage_value:=greatest(1,damage_value-blocked);
        target.guard_reduction_percent:=0;

        if blocked>0 then
          counter_bonus:=least(
            50,
            25+floor(blocked*100.0/greatest(1,target.hp_max))::integer
          );
          target.counter_bonus_percent:=greatest(target.counter_bonus_percent,counter_bonus);
        end if;
      end if;

      critical_hit:=false;
      greatsword_crit_bonus:=0;
      if damage_value>0 and p_action in ('physical','magic','spell') then
        if p_action='physical' and actor_bow_family='greatsword' then
          greatsword_crit_bonus:=private.greatsword_crit_bonus_percent(
            actor.greatsword_crit_stacks
          );
          critical_hit:=private.roll_character_critical_with_bonus(
            actor_id,
            greatsword_crit_bonus
          );
        else
          critical_hit:=private.roll_character_critical(actor_id);
        end if;

        if critical_hit then
          damage_value:=private.apply_critical_damage(
            damage_value,
            case when p_action='physical' then 'physical' else 'magic' end,
            true,
            false
          );
          critical_hits:=critical_hits+1;
        end if;

        if p_action='physical' and actor_bow_family='greatsword' then
          actor.greatsword_crit_stacks:=case
            when critical_hit then 0
            else least(5,actor.greatsword_crit_stacks+1)
          end;
        end if;
      end if;

      target.hp_current:=greatest(0,target.hp_current-damage_value);

      if p_action='physical'
         and actor_bow_family='dagger'
         and damage_value>0
         and echo_chance>0
         and target.hp_current>0
      then
        echo_extra_rolls:=private.roll_echo_strike_extra_hits(echo_chance,50);
        if echo_extra_rolls>0 and echo_hit_damage>0 then
          for hit_index in 1..echo_extra_rolls loop
            exit when target.hp_current<=0;
            if target_bow_family in ('short_bow','long_bow')
               and floor(random()*100)::integer<target_bow_dodge
            then
              echo_dodges:=echo_dodges+1;
            else
              echo_single_damage:=echo_hit_damage;
              if private.roll_character_critical(actor_id) then
                echo_single_damage:=private.apply_critical_damage(
                  echo_single_damage,'physical',true,false
                );
                critical_hits:=critical_hits+1;
              end if;
              echo_single_damage:=least(echo_single_damage,target.hp_current);
              target.hp_current:=greatest(0,target.hp_current-echo_single_damage);
              echo_damage:=echo_damage+echo_single_damage;
              echo_extra_hits:=echo_extra_hits+1;
            end if;
          end loop;
          damage_value:=damage_value+echo_damage;
          total_physical_hits:=1+echo_extra_hits;
        end if;
      end if;

      weapon_stun_proc:=false;
      if p_action='physical'
         and damage_value>0
         and target.hp_current>0
         and floor(random()*100)::integer<private.weapon_family_stun_chance(actor_id,false)
      then
        weapon_stun_proc:=true;
        perform private.apply_pvp_status_effect(
          d.id,target_id,'stun',0,1,actor_id
        );
      end if;

      if p_action='physical' and damage_value>0 and bloodshed_chance>0 then
        for hit_index in 1..greatest(1,total_physical_hits) loop
          if floor(random()*100)::integer<bloodshed_chance then
            bloodshed_procs:=bloodshed_procs+1;
          end if;
        end loop;
        if bloodshed_procs>0 then
          target.bloodshed_stacks:=target.bloodshed_stacks+bloodshed_procs;
        end if;
      end if;

      if actor.lifesteal_percent>0 and damage_value>0 then
        lifesteal_heal:=least(
          actor.hp_max-actor.hp_current,
          greatest(0,floor(damage_value*actor.lifesteal_percent/100.0)::integer)
        );
        actor.hp_current:=least(actor.hp_max,actor.hp_current+lifesteal_heal);
      end if;

      if actor.mana_on_hit>0 and damage_value>0 then
        mana_restore:=least(
          actor.mana_max-actor.mana_current,
          actor.mana_on_hit*case when p_action='physical' then greatest(1,total_physical_hits) else 1 end
        );
        actor.mana_current:=least(actor.mana_max,actor.mana_current+mana_restore);
      end if;

      message_text:=case
        when target_dodged then coalesce(target_name,'Цель')||
          ' уклоняется от «'||coalesce(action_label,'атаки')||'» благодаря выбранной дистанции.'
        else coalesce(actor_name,'Персонаж')||' использует «'||action_label||'» и наносит '
          ||damage_value||' '||private.damage_type_label(damage_type)||' урона.'
      end
        ||case when type_damage_bonus>0 then ' Бонус типа урона: +'||type_damage_bonus||'%.' else '' end
        ||case when actor_reduction>0 then ' Ослабление атаки: -'||actor_reduction||'%.' else '' end
        ||case when resistance>0 then ' Сопротивление цели: '||resistance||'%.' when resistance<0 then ' Уязвимость цели: +'||abs(resistance)||'%.' else '' end
        ||case when blocked>0 then ' Защитой заблокировано '||blocked||' урона.' else '' end
        ||case when counter_bonus>0 then ' Подготовлена контратака +'||counter_bonus||'%.' else '' end
        ||case when lifesteal_heal>0 then ' Вампиризм: +'||lifesteal_heal||' HP.' else '' end
        ||case when mana_restore>0 then ' Восстановлено '||mana_restore||' маны.' else '' end
        ||case when empower_used>0 then ' Магическое усиление: +'||empower_used||'%.' else '' end
        ||case when p_action='spell' then ' Мана: -'||private.character_effective_spell_mana_cost(actor_id,spell.id)||'.' else '' end
        ||case when first_physical_strike_active then ' Первый удар катаны: база ×'||trim(to_char(first_strike_multiplier,'FM9990.0'))||', бонусная часть ×'||trim(to_char(first_bonus_multiplier,'FM9990.0'))||'.' else '' end
        ||case when katana_rhythm_bonus>0 then ' Нарастающий ритм: +'||katana_rhythm_bonus||'% урона.' else '' end
        ||case when critical_hits>0 then ' Критических попаданий: '||critical_hits||'.' else '' end
        ||case when echo_extra_hits>0 then ' Эхо ударов: +'||echo_extra_hits||' попаданий, +'||echo_damage||' урона.' else '' end
        ||case when echo_dodges>0 then ' От эхо-атак уклонено: '||echo_dodges||'.' else '' end
        ||case when p_action='physical' and target.bloodshed_stacks>0
          then ' Кровопролитие на цели: '||target.bloodshed_stacks||' стак(а/ов).'
          else '' end
        ||case when weapon_stun_proc then ' Оглушение: цель пропустит следующий ход.' else '' end;

      if damage_value>0
         and apply_effect_type is not null
         and apply_effect_chance>0
         and floor(random()*100)::integer<apply_effect_chance
      then
        perform private.apply_pvp_status_effect(
          d.id,target_id,apply_effect_type,apply_effect_potency,apply_effect_turns,actor_id
        );
        message_text:=message_text||' Наложен эффект «'||private.combat_effect_label(apply_effect_type)
          ||'» на '||apply_effect_turns||' х.';
      end if;
    end if;

    if not stunned
       and p_action='physical'
       and white_fang_active
       and damage_value>0
       and not target_dodged
       and target.hp_current>0
    then
      if actor.white_fang_wounds>=3 then
        select * into white_fang_rupture
        from private.white_fang_rupture_roll(actor_id,target.hp_max);

        white_fang_rupture_damage:=least(
          greatest(
            0,
            round(
              white_fang_rupture.final_damage
              *(100+private.character_religion_modifier_number(target_id,'incoming_damage_taken_percent'))
              /100.0
            )::integer
          ),
          target.hp_current
        );
        target.hp_current:=greatest(0,target.hp_current-white_fang_rupture_damage);
        actor.white_fang_wounds:=0;
        damage_value:=damage_value+white_fang_rupture_damage;

        message_text:=coalesce(message_text,'')
          ||' Разрыв наносит '||white_fang_rupture_damage||' урона'
          ||case when white_fang_rupture.critical then ' (крит ×1.5).' else '.' end;
      else
        actor.white_fang_wounds:=least(3,actor.white_fang_wounds+1);
        message_text:=coalesce(message_text,'')
          ||' Рваные раны: '||actor.white_fang_wounds||'/3.';
      end if;
    end if;

    update public.pvp_duel_states
    set hp_current=actor.hp_current,
        mana_current=actor.mana_current,
        guard_reduction_percent=actor.guard_reduction_percent,
        counter_bonus_percent=actor.counter_bonus_percent,
        spell_damage_bonus_percent=actor.spell_damage_bonus_percent,
        spell_damage_bonus_hits=actor.spell_damage_bonus_hits,
        bow_draw_pending=actor.bow_draw_pending,
        bloodshed_stacks=actor.bloodshed_stacks,
        white_fang_wounds=actor.white_fang_wounds,
        katana_rhythm_stacks=case
          when not stunned and p_action='physical' and actor_bow_family='katana'
            then least(5,actor.katana_rhythm_stacks+1)
          else 0
        end,
        katana_rhythm_target_id=case
          when not stunned and p_action='physical' and actor_bow_family='katana'
            then target_id
          else null
        end,
        greatsword_crit_stacks=case
          when p_action='physical' and actor_bow_family='greatsword' and not target_dodged
            then actor.greatsword_crit_stacks
          when actor_bow_family<>'greatsword' then 0
          else greatsword_crit_stacks
        end,
        updated_at=now()
    where duel_id=d.id and character_id=actor_id;

    update public.pvp_duel_states
    set hp_current=target.hp_current,
        mana_current=target.mana_current,
        guard_reduction_percent=target.guard_reduction_percent,
        counter_bonus_percent=target.counter_bonus_percent,
        bow_draw_pending=target.bow_draw_pending,
        bloodshed_stacks=target.bloodshed_stacks,
        updated_at=now()
    where duel_id=d.id and character_id=target_id;
  end if;

  insert into public.pvp_duel_turns(
    duel_id,round,actor_character_id,action_type,damage,healing,message
  )
  values(
    d.id,d.round,actor_id,action_type_value,damage_value,heal_value,coalesce(message_text,'')
  );

  update public.pvp_duel_status_effects
  set remaining_turns=remaining_turns-1,updated_at=now()
  where duel_id=d.id and target_character_id=actor_id;

  delete from public.pvp_duel_status_effects
  where duel_id=d.id and target_character_id=actor_id and remaining_turns<=0;

  if target.hp_current<=0 then
    perform private.finish_pvp_duel(d.id,actor_id,'knockout');
    return public.get_pvp_duel(d.id);
  end if;

  update public.pvp_duels
  set current_turn_character_id=target_id,
      round=round+1,
      turn_started_at=now(),
      updated_at=now()
  where id=d.id;

  return public.get_pvp_duel(d.id);
end;
$function$;

CREATE OR REPLACE FUNCTION private.get_game_guide_catalog_internal()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  caller uuid:=auth.uid();
begin
  if caller is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  return jsonb_build_object(
    'items',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',d.id,
          'slug',d.slug,
          'name',d.name,
          'description',d.description,
          'category',d.category::text,
          'rarity',d.rarity::text,
          'equip_group',case when d.equip_group is null then null else d.equip_group::text end,
          'stat_modifiers',coalesce(d.stat_modifiers,'{}'::jsonb),
          'required_level',d.required_level,
          'shop_tier',d.shop_tier,
          'shop_price',d.shop_price,
          'damage_type',d.damage_type,
          'damage_resistances',coalesce(d.damage_resistances,'{}'::jsonb),
          'damage_bonuses',coalesce(d.damage_bonuses,'{}'::jsonb),
          'weapon_base_damage',coalesce(d.weapon_base_damage,0),
          'weapon_scaling',d.weapon_scaling,
          'weapon_family',d.weapon_family,
          'bow_full_draw_armor_penetration_percent',coalesce(d.bow_full_draw_armor_penetration_percent,0),
          'bloodshed_chance_percent',coalesce(d.bloodshed_chance_percent,0),
          'echo_strike_chance_percent',coalesce(d.echo_strike_chance_percent,0),
          'unique_property_name',d.unique_property_name,
          'unique_property_description',coalesce(d.unique_property_description,''),
          'unique_effect_type',d.unique_effect_type,
          'unique_effect_value',coalesce(d.unique_effect_value,0)
        )
        order by
          case d.category::text when 'weapon' then 0 when 'armor' then 1 else 2 end,
          d.required_level,
          d.rarity::text,
          d.name
      )
      from public.item_definitions d
      where d.category::text in ('weapon','armor','accessory')
    ),'[]'::jsonb),
    'spells',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',s.id,
          'slug',s.slug,
          'name',s.name,
          'description',s.description,
          'spell_kind',s.spell_kind,
          'damage_type',s.damage_type,
          'mana_cost',s.mana_cost,
          'required_level',s.required_level,
          'power_multiplier',s.power_multiplier,
          'flat_power',s.flat_power,
          'status_effect_type',s.status_effect_type,
          'status_effect_chance',s.status_effect_chance,
          'status_effect_turns',s.status_effect_turns,
          'status_effect_potency',s.status_effect_potency,
          'support_effect_type',s.support_effect_type,
          'support_value',s.support_value,
          'support_turns',s.support_turns,
          'families',coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'slug',mf.slug,
                'name',mf.name,
                'kind',mf.kind
              )
              order by mf.kind,mf.sort_order,mf.name
            )
            from public.spell_magic_families smf
            join public.magic_families mf on mf.slug=smf.family_slug
            where smf.spell_id=s.id and mf.enabled=true
          ),'[]'::jsonb)
        )
        order by s.required_level,s.name
      )
      from public.spell_definitions s
      where s.enabled=true
    ),'[]'::jsonb),
    'magic_families',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'slug',mf.slug,
          'name',mf.name,
          'kind',mf.kind,
          'description',mf.description,
          'spell_count',(
            select count(*)::integer
            from public.spell_magic_families smf
            join public.spell_definitions sd on sd.id=smf.spell_id
            where smf.family_slug=mf.slug and sd.enabled=true
          )
        )
        order by
          case mf.kind when 'element' then 0 when 'school' then 1 else 2 end,
          mf.sort_order,mf.name
      )
      from public.magic_families mf
      where mf.enabled=true
    ),'[]'::jsonb),
    'races',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',r.id,
          'slug',r.slug,
          'name',r.name,
          'category',r.category,
          'description',r.description,
          'stat_modifiers',coalesce(r.stat_modifiers,'{}'::jsonb),
          'traits',coalesce(r.traits,'[]'::jsonb),
          'innate_magic_damage_type',r.innate_magic_damage_type,
          'hp_bonus',r.hp_bonus,
          'mana_bonus',r.mana_bonus,
          'hp_regen_per_hour',r.hp_regen_per_hour,
          'mana_regen_per_hour',r.mana_regen_per_hour,
          'damage_resistances',coalesce(r.damage_resistances,'{}'::jsonb),
          'passive_type',r.passive_type,
          'passive_value',r.passive_value,
          'passive_name',r.passive_name,
          'passive_description',r.passive_description
        )
        order by r.sort_order,r.name
      )
      from public.race_definitions r
      where r.playable=true
    ),'[]'::jsonb),
    'affixes',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',a.id,
          'slug',a.slug,
          'name',a.name,
          'description',a.description,
          'min_rarity_rank',a.min_rarity_rank,
          'max_rarity_rank',a.max_rarity_rank,
          'allowed_categories',a.allowed_categories,
          'allowed_equip_groups',a.allowed_equip_groups,
          'stat_modifiers',coalesce(a.stat_modifiers,'{}'::jsonb),
          'damage_resistances',coalesce(a.damage_resistances,'{}'::jsonb),
          'unique_effect_type',a.unique_effect_type,
          'unique_effect_value',coalesce(a.unique_effect_value,0)
        )
        order by a.min_rarity_rank,a.name
      )
      from public.equipment_affixes a
      where a.enabled=true
    ),'[]'::jsonb),
    'religions',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'slug',r.slug,
          'name',r.name,
          'short_motto',r.short_motto,
          'description',r.description,
          'praise_text',r.praise_text,
          'taboo_text',r.taboo_text,
          'faith_daily_cap',r.faith_daily_cap,
          'level10_reward_item_id',r.level10_reward_item_id,
          'level10_reward_item_name',reward.name,
          'perks',coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'level',p.level,
                'title',p.title,
                'description',p.description,
                'modifiers',coalesce(p.modifiers,'{}'::jsonb)
              )
              order by p.level
            )
            from public.religion_level_perks p
            where p.religion_slug=r.slug
          ),'[]'::jsonb),
          'oaths',coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'id',o.id,
                'slug',o.slug,
                'name',o.name,
                'description',o.description,
                'target_count',o.target_count,
                'faith_reward',o.faith_reward,
                'favor_reward',o.favor_reward,
                'failure_faith_penalty',o.failure_faith_penalty,
                'failure_favor_penalty',o.failure_favor_penalty
              )
              order by o.sort_order,o.name
            )
            from public.religion_oath_definitions o
            where o.religion_slug=r.slug and o.enabled=true
          ),'[]'::jsonb)
        )
        order by r.sort_order,r.name
      )
      from public.religion_definitions r
      left join public.item_definitions reward on reward.id=r.level10_reward_item_id
      where r.enabled=true
    ),'[]'::jsonb),
    'religion_level_thresholds',
    jsonb_build_array(
      jsonb_build_object('level',1,'faith',0),
      jsonb_build_object('level',2,'faith',100),
      jsonb_build_object('level',3,'faith',220),
      jsonb_build_object('level',4,'faith',380),
      jsonb_build_object('level',5,'faith',580),
      jsonb_build_object('level',6,'faith',820),
      jsonb_build_object('level',7,'faith',1100),
      jsonb_build_object('level',8,'faith',1420),
      jsonb_build_object('level',9,'faith',1780),
      jsonb_build_object('level',10,'faith',2200)
    ),
    'religion_rules',
    jsonb_build_object(
      'faith_max',2200,
      'ordinary_daily_cap',60,
      'oath_weekly_cap',100,
      'inactive_relic_penalty_percent',20
    ),
    'religion_faith_sources',
    jsonb_build_array(
      jsonb_build_object('religion_slug','path_of_light','kind','gain','title','Поручение защиты','faith',10,'favor',0,'description','Завершить поручение поселения с темой защиты.'),
      jsonb_build_object('religion_slug','path_of_light','kind','gain','title','Обычное поручение','faith',5,'favor',0,'description','Завершить общее поручение поселения. Другие темы дают +3 веры.'),
      jsonb_build_object('religion_slug','path_of_light','kind','gain','title','Поддерживающее действие','faith',2,'favor',0,'description','Применить в реальном бою лечение, щит, очищение, бафф или провокацию.'),
      jsonb_build_object('religion_slug','path_of_light','kind','gain','title','Защита','faith',1,'favor',0,'description','Использовать действие «Защита» в реальном бою.'),
      jsonb_build_object('religion_slug','path_of_light','kind','gain','title','Групповое подземелье','faith',10,'favor',1,'description','Завершить групповое подземелье живым участником группы.'),

      jsonb_build_object('religion_slug','old_roots','kind','gain','title','Природное поручение','faith',10,'favor',0,'description','Завершить поручение поселения с природной темой.'),
      jsonb_build_object('religion_slug','old_roots','kind','gain','title','Обычное поручение','faith',5,'favor',0,'description','Завершить общее поручение поселения. Другие темы дают +2 веры.'),
      jsonb_build_object('religion_slug','old_roots','kind','gain','title','Новый сектор дикой природы','faith',4,'favor',0,'description','Впервые открыть wilderness-сектор.'),
      jsonb_build_object('religion_slug','old_roots','kind','gain','title','Экспедиция в дикой природе','faith',10,'favor',0,'description','Полностью завершить экспедицию в wilderness-секторе.'),
      jsonb_build_object('religion_slug','old_roots','kind','penalty','title','Начало охоты','faith',-20,'favor',-10,'description','Охота нарушает табу Старых Корней уже в момент начала.'),
      jsonb_build_object('religion_slug','old_roots','kind','penalty','title','Убийство на охоте','faith',-30,'favor',-15,'description','Успешное убийство сильного монстра на охоте дополнительно усугубляет нарушение.'),

      jsonb_build_object('religion_slug','star_covenant','kind','gain','title','Исследовательское или магическое поручение','faith',10,'favor',0,'description','Завершить поручение поселения с темой research или arcane.'),
      jsonb_build_object('religion_slug','star_covenant','kind','gain','title','Обычное поручение','faith',5,'favor',0,'description','Завершить общее поручение поселения. Другие темы дают +2 веры.'),
      jsonb_build_object('religion_slug','star_covenant','kind','gain','title','Изучение заклинания','faith',15,'favor',1,'description','Навсегда изучить новое заклинание.'),
      jsonb_build_object('religion_slug','star_covenant','kind','gain','title','Применение магии','faith',2,'favor',0,'description','Использовать врождённую магию или изученное заклинание в реальном бою.'),
      jsonb_build_object('religion_slug','star_covenant','kind','gain','title','Новый сектор','faith',2,'favor',0,'description','Впервые открыть любой новый сектор мира.'),

      jsonb_build_object('religion_slug','abyss','kind','gain','title','Боевое поручение','faith',10,'favor',0,'description','Завершить поручение поселения с боевой темой.'),
      jsonb_build_object('religion_slug','abyss','kind','gain','title','Обычное поручение','faith',5,'favor',0,'description','Завершить общее поручение поселения. Другие темы дают +2 веры.'),
      jsonb_build_object('religion_slug','abyss','kind','gain','title','Обычное подземелье','faith',10,'favor',0,'description','Полностью зачистить обычное соло-подземелье.'),
      jsonb_build_object('religion_slug','abyss','kind','gain','title','Мировой event-босс','faith',15,'favor',2,'description','Победить активного event-босса.'),
      jsonb_build_object('religion_slug','abyss','kind','gain','title','Жертва Rare','faith',8,'favor',1,'description','Пожертвовать Бездне подходящий предмет редкости Rare.'),
      jsonb_build_object('religion_slug','abyss','kind','gain','title','Жертва Epic','faith',12,'favor',2,'description','Пожертвовать Бездне подходящий предмет редкости Epic.'),
      jsonb_build_object('religion_slug','abyss','kind','gain','title','Жертва Legendary','faith',18,'favor',3,'description','Пожертвовать Бездне подходящий предмет редкости Legendary.'),
      jsonb_build_object('religion_slug','abyss','kind','gain','title','Жертва Unique','faith',20,'favor',4,'description','Пожертвовать подходящий Unique-предмет. Уникальные материалы/ресурсы и религиозные реликвии жертвовать нельзя.')
    ),
    'mechanics',
    jsonb_build_object(
      'enhancement_percent_per_level',3,
      'enhancement_max',20,
      'awakening_max',5,
      'critical_cap_percent',75,
      'physical_critical_multiplier',1.5,
      'magic_critical_multiplier',1.4,
      'loot_quality_luck_relative_percent_per_point',1,
      'affix_slots',jsonb_build_object(
        'common',0,
        'uncommon',1,
        'rare',2,
        'epic',3,
        'unique',4,
        'legendary',5
      )
    )
  );
end;
$function$;