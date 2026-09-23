-- Mirror Barrier: early self-only reflection spell, plus Arcane Ward rebalance.

alter table public.combat_encounters
  add column if not exists player_reflect_percent smallint not null default 0
  check (player_reflect_percent between 0 and 90);

alter table public.party_combat_member_states
  add column if not exists reflect_percent smallint not null default 0
  check (reflect_percent between 0 and 90);

alter table public.pvp_duel_states
  add column if not exists reflect_percent integer not null default 0
  check (reflect_percent between 0 and 90);

update public.spell_definitions
set support_value=80,
    description='Создаёт плотный магический барьер, который уменьшает следующий входящий удар на 80%.',
    updated_at=now()
where slug='arcane_ward';

insert into public.spell_definitions(
  slug,name,description,enabled,spell_kind,damage_type,mana_cost,required_level,
  power_multiplier,flat_power,status_effect_type,status_effect_chance,status_effect_turns,status_effect_potency,
  support_effect_type,support_value,support_turns
)
values(
  'mirror_barrier',
  'Зеркальный барьер',
  'Окутывает заклинателя зеркальной магией. Следующий прямой удар по нему отражает 65% фактического урона обратно во врага, а заклинатель получает оставшиеся 35%. Работает только на самого заклинателя, не отражает урон со временем и исчезает после срабатывания.',
  true,'guard',null,26,2,0,0,null,0,0,0,'guard',65,1
)
on conflict(slug) do update set
  name=excluded.name,
  description=excluded.description,
  enabled=excluded.enabled,
  spell_kind=excluded.spell_kind,
  damage_type=excluded.damage_type,
  mana_cost=excluded.mana_cost,
  required_level=excluded.required_level,
  power_multiplier=excluded.power_multiplier,
  flat_power=excluded.flat_power,
  status_effect_type=excluded.status_effect_type,
  status_effect_chance=excluded.status_effect_chance,
  status_effect_turns=excluded.status_effect_turns,
  status_effect_potency=excluded.status_effect_potency,
  support_effect_type=excluded.support_effect_type,
  support_value=excluded.support_value,
  support_turns=excluded.support_turns,
  updated_at=now();

insert into public.spell_magic_families(spell_id,family_slug)
select s.id,f.slug
from public.spell_definitions s
cross join (values ('arcane'),('protective')) as f(slug)
where s.slug='mirror_barrier'
on conflict do nothing;

insert into public.item_definitions(
  slug,name,description,category,rarity,stackable,max_stack,
  stat_modifiers,effects,base_value,required_level,shop_tier,shop_price,shop_enabled,
  scroll_spell_id,scroll_mode,shop_sector_id
)
select
  'learn_scroll_mirror_barrier',
  'Свиток изучения: Зеркальный барьер',
  'Одноразовый свиток. Позволяет навсегда изучить заклинание «Зеркальный барьер».',
  'consumable','uncommon',true,99,
  '{}'::jsonb,'[]'::jsonb,80,2,2,180,true,
  s.id,'learn',170
from public.spell_definitions s
where s.slug='mirror_barrier'
on conflict(slug) do update set
  name=excluded.name,
  description=excluded.description,
  rarity=excluded.rarity,
  required_level=excluded.required_level,
  shop_tier=excluded.shop_tier,
  shop_price=excluded.shop_price,
  shop_enabled=excluded.shop_enabled,
  scroll_spell_id=excluded.scroll_spell_id,
  scroll_mode=excluded.scroll_mode,
  shop_sector_id=excluded.shop_sector_id,
  updated_at=now();

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
    if spell.spell_kind not in ('damage','heal','summon') then raise exception 'SPELL_NOT_COMBAT_USABLE'; end if;
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
$function$;

CREATE OR REPLACE FUNCTION public.cast_party_character_spell(p_character_id uuid, p_encounter_id uuid, p_spell_id uuid, p_target_character_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid:=auth.uid();
  encounter public.party_combat_encounters;
  run_row public.party_dungeon_runs;
  actor_state public.party_combat_member_states;
  target_state public.party_combat_member_states;
  stats record;
  target_stats record;
  spell public.spell_definitions;
  actor_name text;
  target_name text;
  target_id uuid;
  variance integer:=0;
  raw_damage integer:=0;
  dealt_damage integer:=0;
  resistance integer:=0;
  type_bonus integer:=0;
  total_bonus integer:=0;
  buff_bonus integer:=0;
  actor_reduction integer:=0;
  enemy_vulnerable integer:=0;
  heal_amount integer:=0;
  lifesteal_heal integer:=0;
  mana_gain integer:=0;
  guard_value integer:=0;
  actor_mana_after integer:=0;
  status_applied boolean:=false;
  critical_hit boolean:=false;
  cleansed_count integer:=0;
  action_message text:='';
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller_id
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
    select 1 from public.party_dungeon_run_members prm
    where prm.run_id=run_row.id and prm.character_id=p_character_id
  ) then raise exception 'NOT_PARTY_DUNGEON_MEMBER'; end if;

  if p_character_id=any(encounter.acted_character_ids) then
    raise exception 'PARTY_ACTION_ALREADY_USED_THIS_ROUND';
  end if;

  select * into actor_state
  from public.party_combat_member_states
  where encounter_id=encounter.id and character_id=p_character_id
  for update;

  if actor_state.character_id is null then raise exception 'PARTY_MEMBER_STATE_NOT_FOUND'; end if;
  if actor_state.downed then raise exception 'PARTY_MEMBER_DOWNED'; end if;
  if private.party_status_stunned(encounter.id,'member',p_character_id) then
    raise exception 'PARTY_MEMBER_STUNNED';
  end if;

  perform private.assert_party_action_turn(encounter.id,p_character_id);

  select s.* into spell
  from public.character_spells cs
  join public.spell_definitions s on s.id=cs.spell_id
  where cs.character_id=p_character_id
    and cs.spell_id=p_spell_id
    and s.enabled=true;

  if spell.id is null then raise exception 'SPELL_NOT_LEARNED'; end if;
  if not private.character_spell_equipped(p_character_id,p_spell_id) then
    raise exception 'SPELL_NOT_IN_LOADOUT';
  end if;
  if spell.spell_kind not in ('damage','heal','guard','cleanse','buff','taunt','summon') then
    raise exception 'PARTY_SPELL_NOT_SUPPORTED';
  end if;

  select * into stats
  from private.get_character_combat_stats(p_character_id);

  update public.party_combat_member_states
  set katana_rhythm_stacks=0,
      katana_rhythm_target_id=null,
      updated_at=now()
  where encounter_id=encounter.id
    and character_id=p_character_id;

  if stats.level<spell.required_level then raise exception 'LEVEL_TOO_LOW'; end if;
  if actor_state.mana_current<private.character_effective_spell_mana_cost(p_character_id,spell.id) then raise exception 'NOT_ENOUGH_MANA'; end if;

  select c.name into actor_name
  from public.characters c
  where c.id=p_character_id;

  actor_mana_after:=actor_state.mana_current-private.character_effective_spell_mana_cost(p_character_id,spell.id);

  if spell.spell_kind='damage' then
    variance:=private.combat_damage_variance(stats.luck);

    raw_damage:=private.concentrated_spell_direct_value(
      p_character_id,
      spell.id,
      greatest(
        1,
        private.damage_after_armor(
          round(stats.magic_power*spell.power_multiplier)::integer
          +spell.flat_power
          +variance,
          encounter.enemy_defense*0.65
        )
      )
    );

    actor_reduction:=private.party_status_reduction(encounter.id,'member',p_character_id);
    if actor_reduction>0 then
      raw_damage:=greatest(1,round(raw_damage*(100-actor_reduction)/100.0)::integer);
    end if;

    total_bonus:=coalesce(stats.all_damage_bonus_percent,0)+private.race_party_damage_bonus(p_character_id)
      +coalesce(stats.magic_damage_bonus_percent,0)
      +private.character_spell_family_damage_bonus_percent(p_character_id,spell.id);

    type_bonus:=private.character_damage_bonus(p_character_id,spell.damage_type);
    total_bonus:=total_bonus+type_bonus;

    if actor_state.damage_bonus_hits>0 and actor_state.damage_bonus_percent>0 then
      buff_bonus:=actor_state.damage_bonus_percent;
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

    raw_damage:=greatest(1,round(raw_damage*(100+total_bonus)/100.0)::integer);
    resistance:=private.damage_resistance_percent(encounter.enemy_resistances,spell.damage_type);
    dealt_damage:=greatest(1,round(raw_damage*(100-resistance)/100.0)::integer);

    enemy_vulnerable:=private.party_status_vulnerability(encounter.id,'enemy',null);
    if enemy_vulnerable>0 then
      dealt_damage:=greatest(1,round(dealt_damage*(100+enemy_vulnerable)/100.0)::integer);
    end if;

    critical_hit:=private.roll_character_critical(p_character_id);
    if critical_hit then
      dealt_damage:=private.apply_critical_damage(
        dealt_damage,'magic',true,false
      );
    end if;

    dealt_damage:=least(dealt_damage,encounter.enemy_hp_current);

    update public.party_combat_encounters
    set enemy_hp_current=greatest(0,enemy_hp_current-dealt_damage)
    where id=encounter.id;

    if encounter.enemy_hp_current-dealt_damage>0
       and spell.status_effect_type is not null
       and spell.status_effect_chance>0
       and floor(random()*100)::integer<spell.status_effect_chance
    then
      perform private.apply_party_combat_status_effect(
        encounter.id,'enemy',null,spell.status_effect_type,
        private.concentrated_spell_status_potency(
          p_character_id,spell.id,spell.status_effect_type,spell.status_effect_potency
        ),spell.status_effect_turns,
        p_character_id,spell.name
      );
      status_applied:=true;
    end if;

    if coalesce(stats.lifesteal_percent,0)>0 and dealt_damage>0 then
      lifesteal_heal:=least(
        actor_state.hp_max-actor_state.hp_current,
        floor(dealt_damage*stats.lifesteal_percent/100.0)::integer
      );
    end if;

    if coalesce(stats.mana_on_hit,0)>0 and dealt_damage>0 then
      mana_gain:=least(actor_state.mana_max-actor_mana_after,stats.mana_on_hit);
    end if;

    update public.party_combat_member_states
    set hp_current=least(hp_max,hp_current+lifesteal_heal),
        mana_current=least(mana_max,actor_mana_after+mana_gain),
        damage_bonus_hits=case
          when buff_bonus>0 then greatest(0,damage_bonus_hits-1)
          else damage_bonus_hits
        end,
        damage_bonus_percent=case
          when buff_bonus>0 and damage_bonus_hits<=1 then 0
          else damage_bonus_percent
        end,
        updated_at=now()
    where encounter_id=encounter.id and character_id=p_character_id
    returning * into actor_state;

    update public.character_progress
    set hp_current=private.character_effective_hp_to_base(p_character_id,actor_state.hp_current),
        mana_current=actor_state.mana_current,
        hp_regen_anchor_at=now(),
        mana_regen_anchor_at=now(),
        updated_at=now()
    where character_id=p_character_id;

    action_message:=actor_name||' применяет «'||spell.name||'» и наносит '
      ||dealt_damage||' '||private.damage_type_label(spell.damage_type)||' урона.'
      ||' Мана: -'||private.character_effective_spell_mana_cost(p_character_id,spell.id)||'.'
      ||case when type_bonus>0 then ' Бонус типа: +'||type_bonus||'%.' else '' end
      ||case when actor_reduction>0 then ' Ослабление: -'||actor_reduction||'%.' else '' end
      ||case when enemy_vulnerable>0 then ' Уязвимость врага: +'||enemy_vulnerable||'%.' else '' end
      ||case when critical_hit then ' Критический магический удар ×1.4.' else '' end
      ||case when buff_bonus>0 then ' Боевой фокус: +'||buff_bonus||'%.' else '' end
      ||case when resistance>0 then ' Сопротивление врага: '||resistance||'%.' when resistance<0 then ' Уязвимость врага: +'||abs(resistance)||'%.' else '' end
      ||case when status_applied then ' Наложен эффект «'||private.combat_effect_label(spell.status_effect_type)||'».' else '' end
      ||case when lifesteal_heal>0 then ' Вампиризм: +'||lifesteal_heal||' HP.' else '' end
      ||case when mana_gain>0 then ' Возвращено '||mana_gain||' маны.' else '' end;

  elsif spell.spell_kind='summon' then
    action_message:=actor_name||' призывает «'
      ||private.create_combat_summon('party',encounter.id,p_character_id,spell.id,encounter.round)
      ||'». Мана: -'||private.character_effective_spell_mana_cost(p_character_id,spell.id)||'.';

    update public.party_combat_member_states
    set mana_current=actor_mana_after,updated_at=now()
    where encounter_id=encounter.id and character_id=p_character_id;

    update public.character_progress
    set mana_current=actor_mana_after,mana_regen_anchor_at=now(),updated_at=now()
    where character_id=p_character_id;

  else
    target_id:=coalesce(p_target_character_id,p_character_id);

    if spell.slug='mirror_barrier' and target_id<>p_character_id then
      raise exception 'SPELL_SELF_ONLY';
    end if;

    if not exists(
      select 1 from public.party_dungeon_run_members prm
      where prm.run_id=run_row.id and prm.character_id=target_id
    ) then raise exception 'INVALID_PARTY_SPELL_TARGET'; end if;

    if exists(
      select 1 from public.party_dungeon_run_members prm
      where prm.run_id=run_row.id and prm.character_id=target_id and prm.lost
    ) then raise exception 'PARTY_TARGET_LOST'; end if;

    select * into target_state
    from public.party_combat_member_states
    where encounter_id=encounter.id and character_id=target_id
    for update;

    if target_state.character_id is null then raise exception 'PARTY_MEMBER_STATE_NOT_FOUND'; end if;
    if target_state.downed and spell.spell_kind<>'heal' then raise exception 'PARTY_TARGET_DOWNED'; end if;

    select c.name into target_name from public.characters c where c.id=target_id;

    if spell.spell_kind='heal' then
      if target_state.hp_current>=target_state.hp_max and not target_state.downed then
        raise exception 'ALREADY_FULL_HEALTH';
      end if;

      heal_amount:=least(
        target_state.hp_max-target_state.hp_current,
        greatest(
          1,
          private.concentrated_spell_direct_value(
            p_character_id,
            spell.id,
            round(stats.magic_power*spell.power_multiplier)::integer+spell.flat_power
          )
        )
      );

      heal_amount:=least(
        target_state.hp_max-target_state.hp_current,
        greatest(
          1,
          round(
            heal_amount
            *(100+private.character_religion_modifier_number(p_character_id,'healing_spell_bonus'))
            /100.0
          )::integer
        )
      );

      update public.party_combat_member_states
      set hp_current=least(hp_max,hp_current+heal_amount),
          downed=false,
          updated_at=now()
      where encounter_id=encounter.id and character_id=target_id
      returning * into target_state;

      update public.party_dungeon_run_members
      set dead=false,dead_at=null
      where run_id=run_row.id and character_id=target_id and not lost;

      update public.character_progress
      set hp_current=private.character_effective_hp_to_base(target_id,target_state.hp_current),
          hp_regen_anchor_at=now(),
          updated_at=now()
      where character_id=target_id;

      action_message:=actor_name||' применяет «'||spell.name||'» на '
        ||target_name||' и восстанавливает '||heal_amount||' HP.'
        ||case when target_state.hp_current-heal_amount<=1 then ' Союзник возвращается в бой.' else '' end
        ||' Мана: -'||private.character_effective_spell_mana_cost(p_character_id,spell.id)||'.';

    elsif spell.spell_kind='guard' then
      if spell.slug='mirror_barrier' then
        update public.party_combat_member_states
        set reflect_percent=least(90,greatest(0,spell.support_value)),
            guard_percent=0,
            updated_at=now()
        where encounter_id=encounter.id and character_id=p_character_id;

        action_message:=actor_name||' применяет «'||spell.name
          ||'» на себя. Следующий прямой удар отразит '
          ||least(90,greatest(0,spell.support_value))
          ||'% урона обратно во врага. Мана: -'
          ||private.character_effective_spell_mana_cost(p_character_id,spell.id)||'.';
      else
        guard_value:=least(
          85,
          greatest(
            target_state.guard_percent,
            round(
              private.concentrated_spell_percent_value(p_character_id,spell.id,spell.support_value)
              *(100+private.character_religion_modifier_number(p_character_id,'shield_spell_bonus'))
              /100.0
            )::integer
          )
        );

        update public.party_combat_member_states
        set guard_percent=guard_value,
            reflect_percent=0,
            updated_at=now()
        where encounter_id=encounter.id and character_id=target_id;

        action_message:=actor_name||' накладывает «'||spell.name||'» на '
          ||target_name||'. Следующий удар будет уменьшен на '
          ||guard_value||'%. Мана: -'||private.character_effective_spell_mana_cost(p_character_id,spell.id)||'.';
      end if;

    elsif spell.spell_kind='taunt' then
      update public.party_combat_member_states
      set taunt_chance=greatest(taunt_chance,spell.support_value),
          updated_at=now()
      where encounter_id=encounter.id and character_id=target_id;

      action_message:=actor_name||' применяет «'||spell.name||'» на '
        ||target_name||'. До конца битвы или пока союзник не погибнет, '
        ||'противник выбирает его целью с шансом '||spell.support_value||'%. Мана: -'||private.character_effective_spell_mana_cost(p_character_id,spell.id)||'.';

    elsif spell.spell_kind='cleanse' then
      delete from public.party_combat_status_effects
      where encounter_id=encounter.id
        and target_type='member'
        and target_character_id=target_id;
      get diagnostics cleansed_count = row_count;

      action_message:=actor_name||' применяет «'||spell.name||'» на '
        ||target_name||': снято негативных эффектов — '||cleansed_count||'.'
        ||' Мана: -'||private.character_effective_spell_mana_cost(p_character_id,spell.id)||'.';

    else
      update public.party_combat_member_states
      set damage_bonus_percent=greatest(
            damage_bonus_percent,
            least(100,private.concentrated_spell_percent_value(p_character_id,spell.id,spell.support_value))
          ),
          damage_bonus_hits=greatest(damage_bonus_hits,spell.support_turns),
          updated_at=now()
      where encounter_id=encounter.id and character_id=target_id;

      action_message:=actor_name||' применяет «'||spell.name||'» на '
        ||target_name||': +'||least(100,private.concentrated_spell_percent_value(p_character_id,spell.id,spell.support_value))||'% к прямому урону на '
        ||spell.support_turns||' атаки. Мана: -'||private.character_effective_spell_mana_cost(p_character_id,spell.id)||'.';
    end if;

    update public.party_combat_member_states
    set mana_current=actor_mana_after,updated_at=now()
    where encounter_id=encounter.id and character_id=p_character_id;

    update public.character_progress
    set mana_current=actor_mana_after,
        mana_regen_anchor_at=now(),
        updated_at=now()
    where character_id=p_character_id;
  end if;

  insert into public.party_combat_turns(
    encounter_id,round,actor_type,actor_character_id,target_character_id,
    action_type,damage,message
  )
  values(
    encounter.id,encounter.round,'player',p_character_id,
    case when spell.spell_kind in ('damage','summon') then null else target_id end,
    'spell_'||spell.slug,dealt_damage,action_message
  );

  perform private.resolve_party_summon_action(encounter.id,p_character_id,encounter.round);
  return private.advance_party_combat_round(encounter.id,p_character_id);
end;
$function$;

CREATE OR REPLACE FUNCTION private.advance_party_combat_round(p_encounter_id uuid, p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  encounter public.party_combat_encounters;
  event_row public.event_boss_events;
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
         (not ms.downed and not coalesce(prm.lost,false))
  into actor_meter,actor_can_gain_tempo
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
    if guard_value>0 and enemy_damage>0 then
      enemy_damage:=greatest(
        1,
        ceil(enemy_damage*(100-guard_value)/100.0)::integer
      );
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
      case when target_dodged
        then encounter.enemy_name||' атакует '||target_name||', но цель уклоняется.'
        else encounter.enemy_name||' атакует '||target_name||' и наносит '
          ||enemy_damage||' '||private.damage_type_label(encounter.enemy_damage_type)||' урона.'
      end
      ||case when enemy_reduction>0 then ' Ослабление врага: -'||enemy_reduction||'%.' else '' end
      ||case when target_vulnerable>0 then ' Уязвимость цели: +'||target_vulnerable||'%.' else '' end
      ||case when guard_value>0 then ' Защита уменьшила удар на '||guard_value||'%.' else '' end
      ||case when reflected_damage>0 then ' Зеркальный барьер отражает '||reflected_damage||' урона обратно во врага.' else '' end
      ||case when incoming_reduction>0 then ' Благословение жертвы уменьшило урон на '||incoming_reduction||'%.' else '' end
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
      event_row.name||' готовит тяжёлую особую атаку. На следующем ходу врага защита особенно важна.'
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
  reflected_damage integer:=0;
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
  tempo_gain integer:=0;
  tempo_total integer:=0;
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
        if spell.slug='mirror_barrier' then
          actor.reflect_percent:=least(90,greatest(0,spell.support_value));
          actor.guard_reduction_percent:=0;
          message_text:=coalesce(actor_name,'Персонаж')||' использует «'||spell.name
            ||'». Следующий прямой удар отразит '||actor.reflect_percent
            ||'% урона обратно в атакующего. Мана: -'
            ||private.character_effective_spell_mana_cost(actor_id,spell.id)||'.';
        else
          actor.reflect_percent:=0;
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
        end if;
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

      if target.reflect_percent>0 and damage_value>0 then
        reflected_damage:=greatest(0,floor(damage_value*target.reflect_percent/100.0)::integer);
        damage_value:=greatest(0,damage_value-reflected_damage);
        actor.hp_current:=greatest(0,actor.hp_current-reflected_damage);
        target.reflect_percent:=0;
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
        ||case when reflected_damage>0 then ' Зеркальный барьер отражает '||reflected_damage||' урона обратно в атакующего.' else '' end
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
        reflect_percent=actor.reflect_percent,
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
        reflect_percent=target.reflect_percent,
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

  if actor.hp_current<=0 then
    perform private.finish_pvp_duel(d.id,target_id,'reflection');
    return public.get_pvp_duel(d.id);
  end if;

  if target.hp_current<=0 then
    perform private.finish_pvp_duel(d.id,actor_id,'knockout');
    return public.get_pvp_duel(d.id);
  end if;

  if not stunned then
    tempo_gain:=private.initiative_tempo_gain(actor.initiative,target.initiative);
    tempo_total:=coalesce(actor.initiative_meter,0)+tempo_gain;
  else
    tempo_gain:=0;
    tempo_total:=coalesce(actor.initiative_meter,0);
  end if;

  if not stunned and tempo_total>=100 then
    update public.pvp_duel_states
    set initiative_meter=least(99,tempo_total-100),
        updated_at=now()
    where duel_id=d.id and character_id=actor_id;

    update public.pvp_duels
    set current_turn_character_id=actor_id,
        round=round+1,
        turn_started_at=now(),
        updated_at=now()
    where id=d.id;

    insert into public.pvp_duel_turns(
      duel_id,round,actor_character_id,action_type,damage,healing,message
    )
    values(
      d.id,d.round+1,null,'initiative_extra_action',0,0,
      coalesce(actor_name,'Персонаж')||
      ' за счёт высокой инициативы продвигается по шкале действий и получает ещё одно полное действие.'
    );
  else
    if tempo_gain>0 then
      update public.pvp_duel_states
      set initiative_meter=least(99,tempo_total),
          updated_at=now()
      where duel_id=d.id and character_id=actor_id;
    end if;

    update public.pvp_duels
    set current_turn_character_id=target_id,
        round=round+1,
        turn_started_at=now(),
        updated_at=now()
    where id=d.id;
  end if;

  return public.get_pvp_duel(d.id);
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
$function$;
