-- Arena tactical AI v2.3.
-- Compares long-bow setup against immediate alternatives and respects the
-- global learned-spell toggle in Arena decisions.

CREATE OR REPLACE FUNCTION private.arena_choose_action_v2(p_actor_id uuid, p_actor_stats jsonb, p_actor_state jsonb, p_target_id uuid, p_target_stats jsonb, p_target_state jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  settings public.character_autobattle_settings;
  hp integer:=greatest(0,coalesce((p_actor_state->>'hp')::integer,0));
  hp_max integer:=greatest(1,coalesce((p_actor_state->>'hp_max')::integer,1));
  mana integer:=greatest(0,coalesce((p_actor_state->>'mana')::integer,0));
  mana_max integer:=greatest(0,coalesce((p_actor_state->>'mana_max')::integer,0));
  actions integer:=greatest(0,coalesce((p_actor_state->>'actions')::integer,0));
  hp_percent integer:=0;
  reserve_mana integer:=0;
  severity integer:=private.arena_effect_severity(p_actor_state->'effects');
  family text:=private.character_weapon_family(p_actor_id);
  physical_damage integer:=-1;
  physical_score integer:=-1;
  magic_damage integer:=-1;
  magic_score integer:=-1;
  fast_damage integer:=-1;
  fast_score integer:=-1;
  full_damage integer:=-1;
  full_score integer:=-1;
  bow_should_draw boolean:=false;
  free_score integer:=1;
  target_threat integer:=1;
  best_action text:='physical';
  chosen_distance text:=coalesce(p_actor_state->>'bow_distance','medium');
  spell record;
  rule public.character_autobattle_spell_rules%rowtype;
  best_spell_id uuid;
  best_spell_name text;
  best_spell_score integer:=-1;
  best_spell_damage integer:=0;
  best_spell_cost integer:=0;
  best_spell_status_type text;
  best_spell_status_chance integer:=0;
  best_spell_status_turns integer:=0;
  best_spell_status_potency integer:=0;
  raw integer:=0;
  score integer:=0;
  status_utility integer:=0;
  resistance integer:=0;
  reduction integer:=private.arena_effect_reduction(p_actor_state->'effects');
  vulnerable integer:=private.arena_effect_vulnerable(p_target_state->'effects');
  priority integer:=100;
  priority_mult numeric:=1.0;
  mana_penalty numeric:=0;
  target_effect_exists boolean:=false;
  heal_spell record;
  heal_cost integer:=0;
  heal_value integer:=0;
  cleanse_spell record;
  guard_spell record;
  buff_spell record;
  guard_due boolean:=false;
  guard_value integer:=0;
  guard_survives boolean:=false;
  strategy_threshold numeric:=1.08;
  target_hp integer:=greatest(0,coalesce((p_target_state->>'hp')::integer,0));
  target_hp_max integer:=greatest(1,coalesce((p_target_state->>'hp_max')::integer,1));
  actor_magic_power integer:=greatest(1,coalesce((p_actor_stats->>'magic_power')::integer,1));
  expected_crit numeric:=1.0;
  echo_chance integer:=0;
  bloodshed_expected integer:=0;
  stun_utility integer:=0;
begin
  settings:=private.ensure_character_autobattle_settings(p_actor_id);
  hp_percent:=floor(hp*100.0/hp_max)::integer;
  reserve_mana:=floor(mana_max*coalesce(settings.mana_reserve_percent,25)/100.0)::integer;

  if coalesce((p_actor_state->>'bow_draw_pending')::boolean,false)
     and family in ('short_bow','long_bow')
  then
    return jsonb_build_object(
      'action','physical','label','Полный выстрел',
      'value',private.arena_estimate_physical_damage(
        p_actor_id,p_actor_stats,p_actor_state,p_target_stats,p_target_state,true
      ),
      'mana_cost',0,'crit_kind','physical',
      'distance',chosen_distance,'full_draw_release',true
    );
  end if;

  if settings.normal_allow_physical then
    physical_damage:=private.arena_estimate_physical_damage(
      p_actor_id,p_actor_stats,p_actor_state,p_target_stats,p_target_state,false
    );
    expected_crit:=private.character_expected_critical_multiplier(p_actor_id,'physical');
    if family='greatsword' then
      expected_crit:=expected_crit+private.greatsword_crit_bonus_percent(
        coalesce((p_actor_state->>'greatsword_stacks')::integer,0)
      )/200.0;
    end if;
    physical_score:=greatest(1,round(physical_damage*expected_crit)::integer);

    if family='dagger' then
      echo_chance:=private.character_echo_strike_chance(p_actor_id);
      physical_score:=greatest(
        1,
        round(physical_score*(1.0+least(1.5,echo_chance*2.0/100.0)))::integer
      );
    end if;

    if private.character_bloodshed_chance(p_actor_id)>0 then
      bloodshed_expected:=round(
        private.bloodshed_damage(greatest(1,target_hp),1)
        *private.character_bloodshed_chance(p_actor_id)/100.0
      )::integer;
      physical_score:=physical_score+bloodshed_expected;
    end if;

    if private.character_has_white_fang(p_actor_id)
       and coalesce((p_actor_state->>'white_fang_wounds')::integer,0)>=3
    then
      physical_score:=physical_score+greatest(1,round(target_hp_max*0.10)::integer);
    end if;

    stun_utility:=round(
      greatest(0,private.weapon_family_stun_chance(p_actor_id,false))
      *greatest(1,coalesce((p_target_stats->>'physical_power')::integer,1))
      /100.0
    )::integer;
    physical_score:=physical_score+stun_utility;
  end if;

  if settings.normal_allow_magic then
    magic_damage:=private.arena_estimate_magic_damage(
      p_actor_id,p_actor_stats,p_actor_state,p_target_stats,p_target_state
    );
    magic_score:=greatest(
      1,
      round(magic_damage*private.character_expected_critical_multiplier(p_actor_id,'magic'))::integer
    );
  end if;

  free_score:=greatest(physical_score,magic_score,1);

  target_threat:=greatest(
    round(
      private.arena_estimate_physical_damage(
        p_target_id,p_target_stats,p_target_state,p_actor_stats,p_actor_state,false
      )*private.character_expected_critical_multiplier(p_target_id,'physical')
    )::integer,
    round(
      private.arena_estimate_magic_damage(
        p_target_id,p_target_stats,p_target_state,p_actor_stats,p_actor_state
      )*private.character_expected_critical_multiplier(p_target_id,'magic')
    )::integer,
    1
  );

  if settings.normal_support_enabled
     and settings.use_learned_spells
     and settings.normal_allow_spells
     and settings.normal_cleanse_min_debuffs>0
     and severity>=settings.normal_cleanse_min_debuffs
  then
    select sd.* into cleanse_spell
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=p_actor_id
      and private.character_spell_equipped(p_actor_id,sd.id)
      and sd.enabled=true and sd.spell_kind='cleanse'
      and private.character_effective_spell_mana_cost(p_actor_id,sd.id)<=mana
      and mana-private.character_effective_spell_mana_cost(p_actor_id,sd.id)>=reserve_mana
    order by private.character_effective_spell_mana_cost(p_actor_id,sd.id),sd.required_level desc
    limit 1;

    if cleanse_spell.id is not null then
      return jsonb_build_object(
        'action','cleanse','label',cleanse_spell.name,'spell_id',cleanse_spell.id,
        'value',0,'mana_cost',private.character_effective_spell_mana_cost(p_actor_id,cleanse_spell.id)
      );
    end if;
  end if;

  if settings.normal_support_enabled and settings.use_learned_spells and settings.normal_allow_spells
     and (
       (settings.normal_heal_hp_percent>0 and hp_percent<=settings.normal_heal_hp_percent)
       or hp<=ceil(target_threat*1.25)::integer
     )
  then
    select sd.* into heal_spell
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=p_actor_id
      and private.character_spell_equipped(p_actor_id,sd.id)
      and sd.enabled=true and sd.spell_kind='heal'
      and private.character_effective_spell_mana_cost(p_actor_id,sd.id)<=mana
      and (
        mana-private.character_effective_spell_mana_cost(p_actor_id,sd.id)>=reserve_mana
        or hp<=ceil(target_threat*1.05)::integer
      )
    order by private.autobattle_heal_score(
      p_actor_id,sd.id,actor_magic_power,greatest(0,hp_max-hp),hp_percent
    ) desc
    limit 1;

    if heal_spell.id is not null then
      heal_cost:=private.character_effective_spell_mana_cost(p_actor_id,heal_spell.id);
      heal_value:=greatest(
        1,
        private.concentrated_spell_direct_value(
          p_actor_id,heal_spell.id,
          round(actor_magic_power*heal_spell.power_multiplier)::integer+heal_spell.flat_power
        )
      );
      heal_value:=greatest(
        1,
        round(
          heal_value
          *(100+private.character_religion_modifier_number(p_actor_id,'healing_spell_bonus'))
          /100.0
        )::integer
      );
      return jsonb_build_object(
        'action','heal','label',heal_spell.name,'spell_id',heal_spell.id,
        'value',least(hp_max-hp,heal_value),'mana_cost',heal_cost
      );
    end if;
  end if;

  guard_due:=case settings.normal_guard_mode
    when 'low_hp' then hp_percent<=settings.normal_guard_hp_percent
    when 'interval' then settings.normal_guard_every_n>0 and actions>0 and mod(actions,settings.normal_guard_every_n)=0
    when 'low_hp_or_interval' then
      hp_percent<=settings.normal_guard_hp_percent
      or (settings.normal_guard_every_n>0 and actions>0 and mod(actions,settings.normal_guard_every_n)=0)
    else false
  end;

  guard_due:=guard_due or hp<=ceil(target_threat*1.15)::integer;
  guard_due:=guard_due and coalesce((p_actor_state->>'guard_streak')::integer,0)=0;

  if settings.normal_support_enabled
     and settings.normal_shield_special
     and settings.normal_allow_spells
     and guard_due
     and target_hp>free_score
  then
    select sd.* into guard_spell
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=p_actor_id
      and private.character_spell_equipped(p_actor_id,sd.id)
      and sd.enabled=true and sd.spell_kind='guard'
      and private.character_effective_spell_mana_cost(p_actor_id,sd.id)<=mana
      and mana-private.character_effective_spell_mana_cost(p_actor_id,sd.id)>=reserve_mana
    order by
      case when sd.slug='mirror_barrier' and target_threat<hp and target_threat>=hp*0.45 then 0 else 1 end,
      private.concentrated_spell_percent_value(p_actor_id,sd.id,sd.support_value) desc,
      private.character_effective_spell_mana_cost(p_actor_id,sd.id)
    limit 1;

    if guard_spell.id is not null then
      guard_value:=case when guard_spell.slug='mirror_barrier'
        then least(90,greatest(0,guard_spell.support_value))
        else least(85,greatest(55,private.concentrated_spell_percent_value(
          p_actor_id,guard_spell.id,guard_spell.support_value
        ))) end;
      guard_survives:=case when guard_spell.slug='mirror_barrier'
        then target_threat<hp
        else ceil(target_threat*(100-guard_value)/100.0)::integer<hp
      end;

      if guard_survives then
        return jsonb_build_object(
          'action','guard_spell','label',guard_spell.name,'spell_id',guard_spell.id,
          'value',guard_value,'reflect',guard_spell.slug='mirror_barrier',
          'mana_cost',private.character_effective_spell_mana_cost(p_actor_id,guard_spell.id)
        );
      end if;
    end if;
  end if;

  guard_value:=least(80,55+coalesce((p_actor_stats->>'guard_boost_percent')::integer,0));
  guard_survives:=ceil(target_threat*(100-guard_value)/100.0)::integer<hp;

  if guard_due
     and guard_survives
     and coalesce((p_actor_state->>'guard')::integer,0)<=0
     and coalesce((p_actor_state->>'reflect')::integer,0)<=0
     and target_hp>free_score
  then
    return jsonb_build_object(
      'action','guard','label','Защита','value',guard_value,'mana_cost',0
    );
  end if;

  if settings.normal_support_enabled
     and settings.normal_buff_enabled
     and settings.normal_allow_spells
     and coalesce((p_actor_state->>'buff_hits')::integer,0)<=0
     and target_hp*100>target_hp_max*35
  then
    select sd.* into buff_spell
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=p_actor_id
      and private.character_spell_equipped(p_actor_id,sd.id)
      and sd.enabled=true and sd.spell_kind='buff'
      and private.character_effective_spell_mana_cost(p_actor_id,sd.id)<=mana
      and mana-private.character_effective_spell_mana_cost(p_actor_id,sd.id)>=reserve_mana
    order by
      (
        private.concentrated_spell_percent_value(p_actor_id,sd.id,sd.support_value)
        *greatest(1,sd.support_turns)
      )::numeric/greatest(1,private.character_effective_spell_mana_cost(p_actor_id,sd.id)) desc
    limit 1;

    if buff_spell.id is not null and target_hp>ceil(free_score*2.2)::integer then
      return jsonb_build_object(
        'action','buff','label',buff_spell.name,'spell_id',buff_spell.id,
        'value',least(100,private.concentrated_spell_percent_value(
          p_actor_id,buff_spell.id,buff_spell.support_value
        )),
        'turns',greatest(1,buff_spell.support_turns),
        'mana_cost',private.character_effective_spell_mana_cost(p_actor_id,buff_spell.id)
      );
    end if;
  end if;

  if family in ('short_bow','long_bow') and settings.normal_allow_physical then
    if hp_percent<=35 then chosen_distance:='far';
    elsif target_hp<=physical_damage then chosen_distance:='close';
    else chosen_distance:='medium';
    end if;

    p_actor_state:=jsonb_set(p_actor_state,'{bow_distance}',to_jsonb(chosen_distance),true);
    fast_damage:=private.arena_estimate_physical_damage(
      p_actor_id,p_actor_stats,p_actor_state,p_target_stats,p_target_state,false
    );
    full_damage:=private.arena_estimate_physical_damage(
      p_actor_id,p_actor_stats,p_actor_state,p_target_stats,p_target_state,true
    );
    expected_crit:=private.character_expected_critical_multiplier(p_actor_id,'physical');
    fast_score:=round(fast_damage*expected_crit)::integer;
    full_score:=round(full_damage*expected_crit)::integer;
    physical_damage:=fast_damage;
    physical_score:=fast_score;
    free_score:=greatest(physical_score,magic_score,1);

    if family='long_bow'
       or (
         hp_percent>45
         and target_hp>fast_damage
         and full_score>=ceil(fast_score*1.55)::integer
         and target_threat<hp
       )
    then
      bow_should_draw:=true;
      physical_damage:=full_damage;
      -- Full draw consumes setup + release, so compare it to alternatives by per-action value.
      physical_score:=greatest(1,round(full_score*0.55)::integer);
      free_score:=greatest(physical_score,magic_score,1);
    end if;
  end if;

  if settings.use_learned_spells and settings.normal_allow_spells then
    for spell in
      select sd.*
      from public.character_combat_spells ccs
      join public.spell_definitions sd on sd.id=ccs.spell_id
      where ccs.character_id=p_actor_id
        and private.character_spell_equipped(p_actor_id,sd.id)
        and sd.enabled=true and sd.spell_kind='damage'
        and private.character_effective_spell_mana_cost(p_actor_id,sd.id)<=mana
    loop
      select * into rule
      from public.character_autobattle_spell_rules r
      where r.character_id=p_actor_id and r.spell_id=spell.id;

      if rule.character_id is not null and not rule.normal_enabled then continue; end if;

      priority:=coalesce(rule.normal_priority,100);
      if mana-private.character_effective_spell_mana_cost(p_actor_id,spell.id)<reserve_mana
         and target_hp>free_score
         and settings.strategy<>'aggressive'
      then continue; end if;

      raw:=private.concentrated_spell_direct_value(
        p_actor_id,spell.id,
        greatest(
          1,
          private.damage_after_armor(
            round(actor_magic_power*spell.power_multiplier)::integer+spell.flat_power,
            greatest(0,coalesce((p_target_stats->>'magic_defense')::integer,0))*0.65
          )
        )
      );
      raw:=private.ensure_spell_stronger_than_innate(
        raw,
        greatest(1,private.damage_after_armor(
          actor_magic_power,greatest(0,coalesce((p_target_stats->>'magic_defense')::integer,0))
        )),
        10
      );
      raw:=greatest(
        1,
        round(
          raw*(
            100
            +coalesce((p_actor_stats->>'all_damage_bonus_percent')::integer,0)
            +coalesce((p_actor_stats->>'magic_damage_bonus_percent')::integer,0)
            +private.character_damage_bonus(p_actor_id,spell.damage_type)
            +private.character_spell_family_damage_bonus_percent(p_actor_id,spell.id)
            +case when coalesce((p_actor_state->>'buff_hits')::integer,0)>0
              then coalesce((p_actor_state->>'buff_percent')::integer,0) else 0 end
          )/100.0
        )::integer
      );
      raw:=greatest(1,round(raw*(100-reduction)/100.0)::integer);
      raw:=greatest(1,round(raw*(100+vulnerable)/100.0)::integer);
      resistance:=private.damage_resistance_percent(
        coalesce(p_target_stats->'damage_resistances','{}'::jsonb),spell.damage_type
      );
      raw:=greatest(1,round(raw*(100-resistance)/100.0)::integer);

      if target_hp*100<=target_hp_max*30 then
        raw:=greatest(
          1,
          round(raw*(100+coalesce((p_actor_stats->>'damage_vs_wounded_percent')::integer,0))/100.0)::integer
        );
        raw:=greatest(
          1,
          round(raw*(100-coalesce((p_target_stats->>'low_hp_damage_reduction_percent')::integer,0))/100.0)::integer
        );
      end if;

      status_utility:=0;
      target_effect_exists:=private.arena_has_effect(p_target_state->'effects',spell.status_effect_type);
      if spell.status_effect_type in ('burn','bleed','poison') then
        status_utility:=round(
          private.status_tick_damage(
            spell.status_effect_type,greatest(1,spell.status_effect_potency),
            coalesce(p_target_stats->'damage_resistances','{}'::jsonb)
          )
          *least(3,greatest(1,spell.status_effect_turns))
          *spell.status_effect_chance/100.0
        )::integer;
      elsif spell.status_effect_type='stun' then
        status_utility:=round(target_threat*0.75*spell.status_effect_chance/100.0)::integer;
      elsif spell.status_effect_type in ('weaken','chill') then
        status_utility:=round(
          target_threat*spell.status_effect_potency/100.0
          *least(3,greatest(1,spell.status_effect_turns))
          *spell.status_effect_chance/100.0
        )::integer;
      elsif spell.status_effect_type='vulnerable' then
        status_utility:=round(
          greatest(raw,free_score)*spell.status_effect_potency/100.0
          *least(2,greatest(1,spell.status_effect_turns))
          *spell.status_effect_chance/100.0
        )::integer;
      end if;
      if target_effect_exists then status_utility:=round(status_utility*0.35)::integer; end if;

      priority_mult:=greatest(0.80,least(1.20,1.10-(priority-1)*0.002));
      mana_penalty:=private.character_effective_spell_mana_cost(p_actor_id,spell.id)
        *case settings.strategy when 'conservative' then 0.16 when 'aggressive' then 0.03 else 0.08 end;
      score:=greatest(
        1,
        round(
          (raw*private.character_expected_critical_multiplier(p_actor_id,'magic')+status_utility)
          *priority_mult-mana_penalty
        )::integer
      );

      if score>best_spell_score then
        best_spell_score:=score;
        best_spell_id:=spell.id;
        best_spell_name:=spell.name;
        best_spell_damage:=raw;
        best_spell_cost:=private.character_effective_spell_mana_cost(p_actor_id,spell.id);
        best_spell_status_type:=spell.status_effect_type;
        best_spell_status_chance:=spell.status_effect_chance;
        best_spell_status_turns:=spell.status_effect_turns;
        best_spell_status_potency:=spell.status_effect_potency;
      end if;
    end loop;
  end if;

  strategy_threshold:=case settings.strategy
    when 'aggressive' then 0.90
    when 'conservative' then 1.22
    else 1.08
  end;

  if best_spell_id is not null
     and (best_spell_damage>=target_hp or best_spell_score>=ceil(free_score*strategy_threshold)::integer)
  then
    return jsonb_build_object(
      'action','spell','label',best_spell_name,'spell_id',best_spell_id,
      'value',best_spell_damage,'score',best_spell_score,'mana_cost',best_spell_cost,
      'crit_kind','magic','status_type',best_spell_status_type,
      'status_chance',best_spell_status_chance,'status_turns',best_spell_status_turns,
      'status_potency',best_spell_status_potency
    );
  end if;

  if bow_should_draw and physical_score>=magic_score then
    return jsonb_build_object(
      'action','bow_draw','label','Полный натяг','value',0,'mana_cost',0,
      'distance',chosen_distance,'planned_damage',full_damage
    );
  end if;

  if magic_score>physical_score and settings.normal_allow_magic then
    best_action:='magic';
    return jsonb_build_object(
      'action','magic','label','Врождённая магия','value',magic_damage,
      'mana_cost',0,'crit_kind','magic'
    );
  end if;

  -- Long bow fallback: if no immediate magic/spell alternative exists, drawing is still its only physical option.
  if family='long_bow' then
    return jsonb_build_object(
      'action','bow_draw','label','Полный натяг','value',0,'mana_cost',0,
      'distance',chosen_distance,'planned_damage',full_damage
    );
  end if;

  return jsonb_build_object(
    'action','physical',
    'label',case when family in ('short_bow','long_bow') then 'Быстрый выстрел' else 'Физическая атака' end,
    'value',greatest(1,physical_damage),'mana_cost',0,'crit_kind','physical',
    'distance',chosen_distance,'full_draw_release',false
  );
end;
$function$;

revoke all on function private.arena_choose_action_v2(uuid,jsonb,jsonb,uuid,jsonb,jsonb)
  from public, anon, authenticated;
