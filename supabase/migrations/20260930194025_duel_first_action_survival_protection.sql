-- Ensure every duel participant gets at least one meaningful decision before direct damage can finish them.
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
  startup_protection_active boolean:=false;
  startup_floor_hp integer:=0;
  startup_prevented_damage integer:=0;
  actor_startup_protection_active boolean:=false;
  actor_startup_floor_hp integer:=0;
  actor_startup_prevented_damage integer:=0;
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

  startup_protection_active:=not exists(
    select 1
    from public.pvp_duel_turns pdt
    where pdt.duel_id=d.id
      and pdt.actor_character_id=target_id
      and pdt.action_type not in ('bloodshed_tick','status_tick','stunned')
  );
  startup_floor_hp:=case
    when startup_protection_active then greatest(1,ceil(target.hp_max*0.25)::integer)
    else 0
  end;

  actor_startup_protection_active:=not exists(
    select 1
    from public.pvp_duel_turns pdt
    where pdt.duel_id=d.id
      and pdt.actor_character_id=actor_id
      and pdt.action_type not in ('bloodshed_tick','status_tick','stunned')
  );
  actor_startup_floor_hp:=case
    when actor_startup_protection_active then greatest(1,ceil(actor.hp_max*0.25)::integer)
    else 0
  end;

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
    if actor_startup_protection_active and bloodshed_tick>0 then
      actor_startup_prevented_damage:=greatest(
        0,
        bloodshed_tick-greatest(0,actor.hp_current-actor_startup_floor_hp)
      );
      bloodshed_tick:=least(
        bloodshed_tick,
        greatest(0,actor.hp_current-actor_startup_floor_hp)
      );
    end if;
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
      ||case when actor_startup_prevented_damage>0
        then ' Стартовая защита дуэли предотвращает ещё '||actor_startup_prevented_damage||' урона до первого осмысленного действия.'
        else '' end
    );
    actor_startup_prevented_damage:=0;

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
    if actor_startup_protection_active and actor_dot>0 then
      actor_startup_prevented_damage:=greatest(
        0,
        actor_dot-greatest(0,actor.hp_current-actor_startup_floor_hp)
      );
      actor_dot:=least(
        actor_dot,
        greatest(0,actor.hp_current-actor_startup_floor_hp)
      );
    end if;
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
      ||case when actor_startup_prevented_damage>0
        then ' Стартовая защита дуэли предотвращает ещё '||actor_startup_prevented_damage||' урона до первого осмысленного действия.'
        else '' end
    );
    actor_startup_prevented_damage:=0;

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
        raw_damage:=private.ensure_spell_stronger_than_innate(
          raw_damage,
          greatest(
            1,
            private.damage_after_armor(
              actor.magic_power+variance,
              target.magic_defense
            )
          ),
          10
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

      if startup_protection_active and damage_value>0 then
        startup_prevented_damage:=startup_prevented_damage
          +greatest(0,damage_value-greatest(0,target.hp_current-startup_floor_hp));
        damage_value:=least(
          damage_value,
          greatest(0,target.hp_current-startup_floor_hp)
        );
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
              if startup_protection_active and echo_single_damage>0 then
                startup_prevented_damage:=startup_prevented_damage
                  +greatest(0,echo_single_damage-greatest(0,target.hp_current-startup_floor_hp));
                echo_single_damage:=least(
                  echo_single_damage,
                  greatest(0,target.hp_current-startup_floor_hp)
                );
              end if;
              if echo_single_damage<=0 then
                exit;
              end if;
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
        if startup_protection_active and white_fang_rupture_damage>0 then
          startup_prevented_damage:=startup_prevented_damage
            +greatest(0,white_fang_rupture_damage-greatest(0,target.hp_current-startup_floor_hp));
          white_fang_rupture_damage:=least(
            white_fang_rupture_damage,
            greatest(0,target.hp_current-startup_floor_hp)
          );
        end if;
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

    if startup_prevented_damage>0 then
      message_text:=coalesce(message_text,'')
        ||' Стартовая защита дуэли удерживает цель минимум на 25% HP до её первого осмысленного действия; предотвращено '
        ||startup_prevented_damage||' урона.';
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
$function$
;

revoke all on function public.perform_pvp_duel_action(uuid,text,uuid) from public,anon;
grant execute on function public.perform_pvp_duel_action(uuid,text,uuid) to authenticated;
