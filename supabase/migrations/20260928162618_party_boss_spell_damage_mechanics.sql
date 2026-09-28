-- Synced from live Supabase migration 20260928162618 (party_boss_spell_damage_mechanics)

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
  boss_state jsonb:='{}'::jsonb;
  boss_bonus integer:=0;
  boss_stored integer:=0;
  boss_types jsonb:='[]'::jsonb;
  boss_types_count integer:=0;
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
  boss_state:=coalesce(actor_state.boss_item_state,'{}'::jsonb);
  if private.party_status_stunned(encounter.id,'member',p_character_id) then
    raise exception 'PARTY_MEMBER_STUNNED';
  end if;

  perform private.assert_party_action_turn(encounter.id,p_character_id);

  select s.* into spell
  from public.spell_definitions s
  where s.id=p_spell_id
    and s.enabled=true
    and (
      exists(
        select 1 from public.character_spells cs
        where cs.character_id=p_character_id and cs.spell_id=s.id
      )
      or private.character_spell_equipped(p_character_id,s.id)
    );

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

    if private.character_has_equipped_effect(p_character_id,'spell_role_alternation')
       and boss_state->>'white_silence_role'='support'
    then
      boss_bonus:=greatest(0,private.character_equipped_effect_number(
        p_character_id,'spell_role_alternation','damage_bonus_percent',18
      )::integer);
      raw_damage:=greatest(1,round(raw_damage*(100+boss_bonus)/100.0)::integer);
    end if;

    if private.character_has_equipped_effect(p_character_id,'mana_charge_burst') then
      boss_stored:=greatest(0,coalesce((boss_state->>'storm_charge')::integer,0));
      if boss_stored>=private.character_equipped_effect_number(
        p_character_id,'mana_charge_burst','mana_threshold',60
      )::integer then
        boss_bonus:=greatest(0,private.character_equipped_effect_number(
          p_character_id,'mana_charge_burst','burst_percent',35
        )::integer);
        raw_damage:=greatest(1,round(raw_damage*(100+boss_bonus)/100.0)::integer);
        boss_stored:=0;
      end if;
      boss_stored:=boss_stored+private.character_effective_spell_mana_cost(p_character_id,spell.id);
      boss_state:=jsonb_set(boss_state,'{storm_charge}',to_jsonb(boss_stored),true);
    end if;

    if private.character_has_equipped_effect(p_character_id,'tri_element_constellation') then
      if coalesce((boss_state->>'aster_ready')::boolean,false) then
        boss_bonus:=greatest(0,private.character_equipped_effect_number(
          p_character_id,'tri_element_constellation','next_spell_bonus_percent',25
        )::integer);
        raw_damage:=greatest(1,round(raw_damage*(100+boss_bonus)/100.0)::integer);
        actor_mana_after:=least(
          actor_state.mana_max,
          actor_mana_after+round(
            private.character_effective_spell_mana_cost(p_character_id,spell.id)
            *private.character_equipped_effect_number(
              p_character_id,'tri_element_constellation','mana_refund_percent',25
            )/100.0
          )::integer
        );
        boss_state:=jsonb_set(boss_state,'{aster_ready}','false'::jsonb,true);
        boss_state:=jsonb_set(boss_state,'{aster_types}','[]'::jsonb,true);
      else
        boss_types:=coalesce(boss_state->'aster_types','[]'::jsonb);
        select coalesce(jsonb_agg(to_jsonb(x) order by x),'[]'::jsonb),count(*)::integer
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
          p_character_id,'tri_element_constellation','required_distinct_types',3
        )::integer) then
          boss_state:=jsonb_set(boss_state,'{aster_ready}','true'::jsonb,true);
        end if;
      end if;
    end if;

    if private.character_has_equipped_effect(p_character_id,'spell_role_alternation') then
      boss_state:=jsonb_set(boss_state,'{white_silence_role}',to_jsonb('damage'::text),true);
    end if;

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
        boss_item_state=boss_state,
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
$function$

