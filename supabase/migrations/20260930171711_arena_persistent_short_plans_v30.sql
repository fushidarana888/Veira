-- Arena AI v3.0: persistent 2–3 action plan memory.
-- Keeps combo intent across turns without recursive simulation.
-- Survival, cleanse and emergency defense are still allowed to interrupt a plan.
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
  immediate_free_score integer:=1;
  target_threat integer:=1;
  incoming_actions integer:=greatest(0,least(3,coalesce((p_actor_state->>'incoming_actions_before_next')::integer,1)));
  burst_threat integer:=1;
  guarded_burst integer:=0;
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
  target_settings public.character_autobattle_settings;
  target_family text:=private.character_weapon_family(p_target_id);
  target_physical_threat integer:=0;
  target_magic_threat integer:=0;
  target_prefers_physical boolean:=false;
  physical_plan_score integer:=-1;
  magic_plan_score integer:=-1;
  best_plan_score integer:=1;
  future_combo_bonus integer:=0;
  survival_discount numeric:=1.0;
  katana_stacks integer:=greatest(0,coalesce((p_actor_state->>'katana_stacks')::integer,0));
  greatsword_stacks integer:=greatest(0,coalesce((p_actor_state->>'greatsword_stacks')::integer,0));
  white_fang_wounds integer:=greatest(0,coalesce((p_actor_state->>'white_fang_wounds')::integer,0));
  blocked_estimate integer:=0;
  counter_percent_estimate integer:=0;
  guard_plan_score integer:=0;
  proactive_guard boolean:=false;
  buff_percent integer:=0;
  buff_turns integer:=0;
  buff_gain integer:=0;
  buff_threshold numeric:=0.85;
  best_spell_plan text;
  active_plan text:=coalesce(p_actor_state->>'plan_key','');
  plan_remaining integer:=greatest(0,least(3,coalesce((p_actor_state->>'plan_remaining')::integer,0)));
  plan_inertia numeric:=1.0;
begin
  settings:=private.ensure_character_autobattle_settings(p_actor_id);
  target_settings:=private.ensure_character_autobattle_settings(p_target_id);
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
      'distance',chosen_distance,'full_draw_release',true,
      'plan','Завершить план · полный выстрел'
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
  immediate_free_score:=greatest(
    case when family='long_bow' then -1 else physical_damage end,
    magic_damage,
    1
  );

  target_threat:=private.arena_estimate_immediate_threat(
    p_target_id,p_target_stats,p_target_state,p_actor_stats,p_actor_state
  );
  burst_threat:=target_threat*incoming_actions;

  survival_discount:=case
    when incoming_actions<=0 then 1.00
    when burst_threat<hp*0.45 then 0.92
    when burst_threat<hp*0.75 then 0.78
    when burst_threat<hp then 0.60
    else 0.25
  end;

  physical_plan_score:=physical_score;
  magic_plan_score:=magic_score;
  future_combo_bonus:=0;

  if physical_score>0 and family='katana' then
    future_combo_bonus:=future_combo_bonus
      +round(
        physical_damage
        *greatest(0,
          private.katana_rhythm_bonus_percent(least(5,katana_stacks+1))
          -private.katana_rhythm_bonus_percent(katana_stacks)
        )/100.0*0.78
      )::integer
      +round(
        physical_damage
        *greatest(0,
          private.katana_rhythm_bonus_percent(least(5,katana_stacks+2))
          -private.katana_rhythm_bonus_percent(least(5,katana_stacks+1))
        )/100.0*0.48
      )::integer;
  elsif physical_score>0 and family='greatsword' then
    future_combo_bonus:=future_combo_bonus
      +round(
        physical_damage
        *greatest(0,
          private.greatsword_crit_bonus_percent(least(5,greatsword_stacks+1))
          -private.greatsword_crit_bonus_percent(greatsword_stacks)
        )/100.0*0.50*0.78
      )::integer
      +round(
        physical_damage
        *greatest(0,
          private.greatsword_crit_bonus_percent(least(5,greatsword_stacks+2))
          -private.greatsword_crit_bonus_percent(least(5,greatsword_stacks+1))
        )/100.0*0.50*0.48
      )::integer;
  end if;

  if physical_score>0 and private.character_has_white_fang(p_actor_id) then
    if white_fang_wounds=2 then
      future_combo_bonus:=future_combo_bonus+round(target_hp_max*0.10*0.78)::integer;
    elsif white_fang_wounds=1 then
      future_combo_bonus:=future_combo_bonus+round(target_hp_max*0.10*0.48)::integer;
    end if;
  end if;

  if physical_plan_score>0 then
    physical_plan_score:=physical_plan_score+round(future_combo_bonus*survival_discount)::integer;
  end if;

  -- Short plan memory: keep a useful 2–3 action line coherent, but only as a
  -- score bonus. Survival checks below can always break the plan.
  if plan_remaining>0 then
    if active_plan='counterstrike'
       and coalesce((p_actor_state->>'counter_bonus')::integer,0)>0
       and physical_plan_score>0
    then
      physical_plan_score:=round(physical_plan_score*1.35)::integer;
    elsif active_plan='buff_chain'
       and coalesce((p_actor_state->>'buff_hits')::integer,0)>0
    then
      if physical_plan_score>0 then physical_plan_score:=round(physical_plan_score*1.14)::integer; end if;
      if magic_plan_score>0 then magic_plan_score:=round(magic_plan_score*1.14)::integer; end if;
    elsif active_plan='vulnerable_chain'
       and private.arena_has_effect(p_target_state->'effects','vulnerable')
    then
      if physical_plan_score>0 then physical_plan_score:=round(physical_plan_score*1.16)::integer; end if;
      if magic_plan_score>0 then magic_plan_score:=round(magic_plan_score*1.16)::integer; end if;
    elsif active_plan='tempo_window' then
      if physical_plan_score>0 then physical_plan_score:=round(physical_plan_score*1.12)::integer; end if;
      if magic_plan_score>0 then magic_plan_score:=round(magic_plan_score*1.12)::integer; end if;
    elsif active_plan='pressure_chain' then
      if physical_plan_score>0 then physical_plan_score:=round(physical_plan_score*1.08)::integer; end if;
      if magic_plan_score>0 then magic_plan_score:=round(magic_plan_score*1.08)::integer; end if;
    elsif active_plan='rhythm_chain' and family='katana' and physical_plan_score>0 then
      physical_plan_score:=round(physical_plan_score*1.15)::integer;
    elsif active_plan='greatsword_chain' and family='greatsword' and physical_plan_score>0 then
      physical_plan_score:=round(physical_plan_score*1.12)::integer;
    elsif active_plan='wound_chain'
       and private.character_has_white_fang(p_actor_id)
       and physical_plan_score>0
    then
      physical_plan_score:=round(physical_plan_score*1.20)::integer;
    end if;
  end if;

  best_plan_score:=greatest(physical_plan_score,magic_plan_score,1);

  if coalesce(target_settings.normal_allow_physical,true) then
    if target_family='long_bow'
       and not coalesce((p_target_state->>'bow_draw_pending')::boolean,false)
    then
      target_physical_threat:=0;
    else
      target_physical_threat:=greatest(0,private.arena_estimate_physical_damage(
        p_target_id,p_target_stats,p_target_state,p_actor_stats,p_actor_state,
        target_family in ('short_bow','long_bow')
          and coalesce((p_target_state->>'bow_draw_pending')::boolean,false)
      ));
    end if;
  end if;

  if coalesce(target_settings.normal_allow_magic,true) then
    target_magic_threat:=greatest(0,private.arena_estimate_magic_damage(
      p_target_id,p_target_stats,p_target_state,p_actor_stats,p_actor_state
    ));
  end if;

  target_prefers_physical:=
    target_physical_threat>0
    and target_physical_threat>=ceil(target_magic_threat*1.10)::integer
    and target_physical_threat>=ceil(target_threat*0.72)::integer;

  if settings.normal_support_enabled
     and settings.use_learned_spells
     and settings.normal_allow_spells
     and settings.normal_cleanse_min_debuffs>0
     and severity>=settings.normal_cleanse_min_debuffs
     and target_hp>immediate_free_score
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
       or hp<=ceil(burst_threat*1.15)::integer
     )
     and target_hp>immediate_free_score
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
        or hp<=ceil(burst_threat*1.02)::integer
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

  -- Reactive guarding is for lethal pressure; configured guard modes remain authoritative.
  guard_due:=guard_due or (
    burst_threat>=hp
    and target_hp>immediate_free_score
  );
  guard_due:=guard_due and coalesce((p_actor_state->>'guard_streak')::integer,0)=0;

  guard_value:=least(80,55+coalesce((p_actor_stats->>'guard_boost_percent')::integer,0));
  if target_prefers_physical
     and incoming_actions>0
     and settings.normal_allow_physical
     and family not in ('short_bow','long_bow')
     and coalesce((p_actor_state->>'guard')::integer,0)<=0
     and coalesce((p_actor_state->>'reflect')::integer,0)<=0
     and target_hp>immediate_free_score
  then
    blocked_estimate:=round(target_physical_threat*guard_value/100.0)::integer;
    counter_percent_estimate:=least(35,greatest(5,round(guard_value*0.45)::integer));
    guard_plan_score:=round(
      blocked_estimate
        *case when hp_percent<=45 then 1.15 when hp_percent<=65 then 0.85 else 0.55 end
      +greatest(0,physical_damage)*counter_percent_estimate/100.0*0.78
    )::integer;

    proactive_guard:=case coalesce(settings.strategy,'balanced')
      when 'conservative' then guard_plan_score>=ceil(best_plan_score*0.58)::integer
      when 'aggressive' then hp_percent<=45 and guard_plan_score>=ceil(best_plan_score*0.80)::integer
      else (
        (hp_percent<=65 and guard_plan_score>=ceil(best_plan_score*0.66)::integer)
        or guard_plan_score>=ceil(best_plan_score*0.94)::integer
      )
    end;
    guard_due:=guard_due or proactive_guard;
  end if;

  if settings.normal_support_enabled
     and settings.use_learned_spells
     and settings.normal_shield_special
     and settings.normal_allow_spells
     and guard_due
     and target_hp>immediate_free_score
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
      guarded_burst:=case
        when incoming_actions<=0 then 0
        when guard_spell.slug='mirror_barrier' then burst_threat
        else ceil(target_threat*(100-guard_value)/100.0)::integer
          +target_threat*greatest(0,incoming_actions-1)
      end;
      guard_survives:=guarded_burst<hp;

      if guard_survives then
        return jsonb_build_object(
          'action','guard_spell','label',guard_spell.name,'spell_id',guard_spell.id,
          'value',guard_value,'reflect',guard_spell.slug='mirror_barrier',
          'mana_cost',private.character_effective_spell_mana_cost(p_actor_id,guard_spell.id),
          'plan',case
            when guard_spell.slug='mirror_barrier' then 'Отражение → наказать сильную атаку'
            when proactive_guard then 'Блок → усиленная контратака'
            else 'Пережить опасный размен'
          end
        );
      end if;
    end if;
  end if;

  guard_value:=least(80,55+coalesce((p_actor_stats->>'guard_boost_percent')::integer,0));
  guarded_burst:=case
    when incoming_actions<=0 then 0
    else ceil(target_threat*(100-guard_value)/100.0)::integer
      +target_threat*greatest(0,incoming_actions-1)
  end;
  guard_survives:=guarded_burst<hp;

  if guard_due
     and guard_survives
     and coalesce((p_actor_state->>'guard')::integer,0)<=0
     and coalesce((p_actor_state->>'reflect')::integer,0)<=0
     and target_hp>immediate_free_score
  then
    return jsonb_build_object(
      'action','guard','label','Защита','value',guard_value,'mana_cost',0,
      'plan',case when proactive_guard
        then 'Блок → усиленная контратака'
        else 'Пережить опасный размен'
      end
    );
  end if;

  if settings.normal_support_enabled
     and settings.use_learned_spells
     and settings.normal_buff_enabled
     and settings.normal_allow_spells
     and coalesce((p_actor_state->>'buff_hits')::integer,0)<=0
     and target_hp*100>target_hp_max*35
     and burst_threat<hp
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

    if buff_spell.id is not null then
      buff_percent:=least(100,private.concentrated_spell_percent_value(
        p_actor_id,buff_spell.id,buff_spell.support_value
      ));
      buff_turns:=least(3,greatest(1,buff_spell.support_turns));
      buff_gain:=round(
        greatest(1,free_score)*buff_percent/100.0
        *(1.0
          +case when buff_turns>=2 then 0.72 else 0 end
          +case when buff_turns>=3 then 0.48 else 0 end)
        *survival_discount
      )::integer;
      buff_threshold:=case coalesce(settings.strategy,'balanced')
        when 'aggressive' then 1.05
        when 'conservative' then 0.72
        else 0.85
      end;

      if buff_gain>=ceil(greatest(1,free_score)*buff_threshold)::integer
         and target_hp>ceil(greatest(1,free_score)*(1.55+0.35*buff_turns))::integer
      then
        return jsonb_build_object(
          'action','buff','label',buff_spell.name,'spell_id',buff_spell.id,
          'value',buff_percent,'turns',greatest(1,buff_spell.support_turns),
          'mana_cost',private.character_effective_spell_mana_cost(p_actor_id,buff_spell.id),
          'plan','Шаг 1/'||(least(3,buff_turns)+1)||' · Бафф → серия атак'
        );
      end if;
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
    physical_plan_score:=physical_score;
    free_score:=greatest(physical_score,magic_score,1);
    immediate_free_score:=greatest(
      case when family='long_bow' then -1 else fast_damage end,magic_damage,1
    );
    best_plan_score:=greatest(physical_plan_score,magic_plan_score,1);

    if (family='long_bow' and burst_threat<hp)
       or (
         hp_percent>45
         and target_hp>fast_damage
         and full_score>=ceil(fast_score*1.55)::integer
         and burst_threat<hp
       )
    then
      bow_should_draw:=true;
      physical_damage:=full_damage;
      -- Full draw consumes setup + release, so compare it to alternatives by per-action value.
      physical_score:=greatest(1,round(full_score*0.55)::integer);
      physical_plan_score:=greatest(1,round(full_score*survival_discount*0.78)::integer);
      free_score:=greatest(physical_score,magic_score,1);
      best_plan_score:=greatest(physical_plan_score,magic_plan_score,1);
    elsif family='long_bow' and burst_threat>=hp then
      -- Do not spend the last action preparing a shot that cannot be released.
      physical_score:=-1;
      physical_plan_score:=-1;
      free_score:=greatest(magic_score,1);
      best_plan_score:=greatest(magic_plan_score,1);
    end if;
  end if;

  -- Guaranteed free finishers outrank support, mana spending and setup.
  if target_hp<=immediate_free_score then
    if family<>'long_bow'
       and physical_damage>=target_hp
       and physical_score>=magic_score
       and settings.normal_allow_physical
    then
      return jsonb_build_object(
        'action','physical',
        'label',case when family='short_bow' then 'Быстрый выстрел' else 'Физическая атака' end,
        'value',greatest(1,physical_damage),'mana_cost',0,'crit_kind','physical',
        'distance',chosen_distance,'full_draw_release',false,
        'plan','Гарантированное добивание'
      );
    elsif magic_damage>=target_hp and settings.normal_allow_magic then
      return jsonb_build_object(
        'action','magic','label','Врождённая магия','value',magic_damage,
        'mana_cost',0,'crit_kind','magic','plan','Гарантированное добивание'
      );
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
          *(1.0
            +case when spell.status_effect_turns>=2 then 0.72 else 0 end
            +case when spell.status_effect_turns>=3 then 0.48 else 0 end)
          *spell.status_effect_chance/100.0
        )::integer;
      elsif spell.status_effect_type='stun' then
        status_utility:=round(
          target_threat
          *(1.0+case when spell.status_effect_turns>=2 then 0.55 else 0 end)
          *(1.0+case when incoming_actions>0 then 0.18 else 0 end)
          *spell.status_effect_chance/100.0
        )::integer;
      elsif spell.status_effect_type in ('weaken','chill') then
        status_utility:=round(
          greatest(target_threat,burst_threat)
          *spell.status_effect_potency/100.0
          *(1.0
            +case when spell.status_effect_turns>=2 then 0.65 else 0 end
            +case when spell.status_effect_turns>=3 then 0.40 else 0 end)
          *spell.status_effect_chance/100.0
        )::integer;
      elsif spell.status_effect_type='vulnerable' then
        status_utility:=round(
          greatest(raw,best_plan_score)
          *spell.status_effect_potency/100.0
          *(0.82+case when spell.status_effect_turns>=2 then 0.52 else 0 end)
          *spell.status_effect_chance/100.0
          *survival_discount
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
      if plan_remaining>0 then
        if active_plan='buff_chain' and coalesce((p_actor_state->>'buff_hits')::integer,0)>0 then
          score:=round(score*1.14)::integer;
        elsif active_plan='vulnerable_chain'
          and private.arena_has_effect(p_target_state->'effects','vulnerable')
        then
          score:=round(score*1.16)::integer;
        elsif active_plan='tempo_window' then
          score:=round(score*1.12)::integer;
        elsif active_plan='pressure_chain' then
          score:=round(score*1.08)::integer;
        end if;
      end if;

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
        best_spell_plan:=case
          when plan_remaining>0 and active_plan='buff_chain' then 'Продолжить план · усиленная атака'
          when plan_remaining>0 and active_plan='vulnerable_chain' then 'Продолжить план · удар по уязвимости'
          when plan_remaining>0 and active_plan='tempo_window' then 'Продолжить план · использовать окно темпа'
          when plan_remaining>0 and active_plan='pressure_chain' then 'Продолжить план · давление после ослабления'
          when spell.status_effect_type='vulnerable' then 'Уязвимость → усиленные атаки'
          when spell.status_effect_type='stun' then 'Контроль темпа → окно для атаки'
          when spell.status_effect_type in ('weaken','chill') then 'Ослабление → пережить размен'
          when spell.status_effect_type in ('burn','bleed','poison') then 'Урон по времени → добивание'
          else 'Сильнейшая линия на горизонте'
        end;
      end if;
    end loop;
  end if;

  strategy_threshold:=case settings.strategy
    when 'aggressive' then 0.90
    when 'conservative' then 1.22
    else 1.08
  end;

  if best_spell_id is not null
     and target_hp>immediate_free_score
     and (best_spell_damage>=target_hp or best_spell_score>=ceil(best_plan_score*strategy_threshold)::integer)
  then
    return jsonb_build_object(
      'action','spell','label',best_spell_name,'spell_id',best_spell_id,
      'value',best_spell_damage,'score',best_spell_score,'mana_cost',best_spell_cost,
      'crit_kind','magic','status_type',best_spell_status_type,
      'status_chance',best_spell_status_chance,'status_turns',best_spell_status_turns,
      'status_potency',best_spell_status_potency,'plan',best_spell_plan
    );
  end if;

  if bow_should_draw and physical_plan_score>=magic_plan_score then
    return jsonb_build_object(
      'action','bow_draw','label','Полный натяг','value',0,'mana_cost',0,
      'distance',chosen_distance,'planned_damage',full_damage,
      'plan','Полный натяг → пробивающий выстрел'
    );
  end if;

  if magic_plan_score>physical_plan_score and settings.normal_allow_magic then
    best_action:='magic';
    return jsonb_build_object(
      'action','magic','label','Врождённая магия','value',magic_damage,
      'mana_cost',0,'crit_kind','magic',
      'plan',case
        when plan_remaining>0 and active_plan='buff_chain' then 'Продолжить план · усиленная магия'
        when plan_remaining>0 and active_plan='vulnerable_chain' then 'Продолжить план · магия по уязвимости'
        when plan_remaining>0 and active_plan='tempo_window' then 'Продолжить план · использовать окно темпа'
        when plan_remaining>0 and active_plan='pressure_chain' then 'Продолжить план · давление после ослабления'
        else 'Лучший урон на горизонте'
      end
    );
  end if;

  -- If the player intentionally disabled every offensive family, respect it.
  if physical_score<0 and magic_score<0 and best_spell_id is null then
    return jsonb_build_object(
      'action','guard','label','Защита',
      'value',least(80,55+coalesce((p_actor_stats->>'guard_boost_percent')::integer,0)),
      'mana_cost',0
    );
  end if;

  -- Long bow fallback: if no immediate magic/spell alternative exists, drawing is still its only physical option.
  if family='long_bow' and settings.normal_allow_physical then
    return jsonb_build_object(
      'action','bow_draw','label','Полный натяг','value',0,'mana_cost',0,
      'distance',chosen_distance,'planned_damage',full_damage,
      'plan','Полный натяг → пробивающий выстрел'
    );
  end if;

  return jsonb_build_object(
    'action','physical',
    'label',case when family in ('short_bow','long_bow') then 'Быстрый выстрел' else 'Физическая атака' end,
    'value',greatest(1,physical_damage),'mana_cost',0,'crit_kind','physical',
    'distance',chosen_distance,'full_draw_release',false,
    'plan',case
      when plan_remaining>0 and active_plan='counterstrike'
        and coalesce((p_actor_state->>'counter_bonus')::integer,0)>0 then 'Шаг 2/2 · усиленная контратака'
      when plan_remaining>0 and active_plan='buff_chain' then 'Продолжить план · усиленная атака'
      when plan_remaining>0 and active_plan='vulnerable_chain' then 'Продолжить план · удар по уязвимости'
      when plan_remaining>0 and active_plan='tempo_window' then 'Продолжить план · использовать окно темпа'
      when plan_remaining>0 and active_plan='pressure_chain' then 'Продолжить план · давление после ослабления'
      when plan_remaining>0 and active_plan='rhythm_chain' then 'Продолжить план · нарастить ритм катаны'
      when plan_remaining>0 and active_plan='greatsword_chain' then 'Продолжить план · накопить крит'
      when plan_remaining>0 and active_plan='wound_chain' then 'Продолжить план · подготовить Разрыв'
      when family='katana' and katana_stacks<5 then 'Нарастить ритм катаны'
      when family='greatsword' and greatsword_stacks<5 then 'Накопить шанс критического удара'
      when private.character_has_white_fang(p_actor_id) and white_fang_wounds in (1,2) then 'Подготовить Разрыв'
      else 'Лучший урон на горизонте'
    end
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.arena_execute_action_v2(p_actor_id uuid, p_actor_stats jsonb, p_actor_state jsonb, p_target_id uuid, p_target_stats jsonb, p_target_state jsonb, p_action jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  actor_state jsonb:=p_actor_state;
  target_state jsonb:=p_target_state;
  action_type text:=coalesce(p_action->>'action','physical');
  value integer:=greatest(0,coalesce((p_action->>'value')::integer,0));
  mana_cost integer:=greatest(0,coalesce((p_action->>'mana_cost')::integer,0));
  actor_hp integer:=greatest(0,coalesce((actor_state->>'hp')::integer,0));
  actor_hp_max integer:=greatest(1,coalesce((actor_state->>'hp_max')::integer,1));
  actor_mana integer:=greatest(0,coalesce((actor_state->>'mana')::integer,0));
  actor_mana_max integer:=greatest(0,coalesce((actor_state->>'mana_max')::integer,0));
  target_hp integer:=greatest(0,coalesce((target_state->>'hp')::integer,0));
  actual integer:=0;
  healing integer:=0;
  before_guard integer:=0;
  blocked integer:=0;
  reflected integer:=0;
  family text:=private.character_weapon_family(p_actor_id);
  critical boolean:=false;
  extra_hits integer:=0;
  extra_damage integer:=0;
  extra_single integer:=0;
  i integer:=0;
  bloodshed_procs integer:=0;
  rupture record;
  rupture_damage integer:=0;
  target_dodge integer:=0;
  status_applied boolean:=false;
  total_hits integer:=1;
  current_plan text:=coalesce(actor_state->>'plan_key','');
  current_plan_remaining integer:=greatest(0,least(3,coalesce((actor_state->>'plan_remaining')::integer,0)));
  next_plan text:='';
  next_plan_remaining integer:=0;
  status_type text:=coalesce(p_action->>'status_type','');
begin
  actor_mana:=greatest(0,actor_mana-mana_cost);
  actor_state:=jsonb_set(actor_state,'{mana}',to_jsonb(actor_mana),true);

  if action_type='guard' then
    actor_state:=jsonb_set(actor_state,'{guard}',to_jsonb(value),true);
    actor_state:=jsonb_set(actor_state,'{guard_streak}',to_jsonb(coalesce((actor_state->>'guard_streak')::integer,0)+1),true);
  elsif action_type='guard_spell' then
    actor_state:=jsonb_set(actor_state,'{guard_streak}',to_jsonb(coalesce((actor_state->>'guard_streak')::integer,0)+1),true);
    if coalesce((p_action->>'reflect')::boolean,false) then
      actor_state:=jsonb_set(actor_state,'{reflect}',to_jsonb(value),true);
      actor_state:=jsonb_set(actor_state,'{guard}','0'::jsonb,true);
    else
      actor_state:=jsonb_set(actor_state,'{guard}',to_jsonb(value),true);
      actor_state:=jsonb_set(actor_state,'{reflect}','0'::jsonb,true);
    end if;
  elsif action_type='heal' then
    actor_state:=jsonb_set(actor_state,'{guard_streak}','0'::jsonb,true);
    healing:=least(actor_hp_max-actor_hp,value);
    actor_hp:=least(actor_hp_max,actor_hp+healing);
    actor_state:=jsonb_set(actor_state,'{hp}',to_jsonb(actor_hp),true);
  elsif action_type='cleanse' then
    actor_state:=jsonb_set(actor_state,'{guard_streak}','0'::jsonb,true);
    actor_state:=jsonb_set(actor_state,'{effects}','{}'::jsonb,true);
  elsif action_type='buff' then
    actor_state:=jsonb_set(actor_state,'{guard_streak}','0'::jsonb,true);
    actor_state:=jsonb_set(actor_state,'{buff_percent}',to_jsonb(value),true);
    actor_state:=jsonb_set(actor_state,'{buff_hits}',to_jsonb(greatest(1,coalesce((p_action->>'turns')::integer,1))),true);
  elsif action_type='bow_draw' then
    actor_state:=jsonb_set(actor_state,'{guard_streak}','0'::jsonb,true);
    actor_state:=jsonb_set(actor_state,'{bow_draw_pending}','true'::jsonb,true);
    if p_action->>'distance' in ('close','medium','far') then
      actor_state:=jsonb_set(actor_state,'{bow_distance}',to_jsonb(p_action->>'distance'),true);
    end if;
  else
    actor_state:=jsonb_set(actor_state,'{guard_streak}','0'::jsonb,true);
    if p_action->>'distance' in ('close','medium','far') then
      actor_state:=jsonb_set(actor_state,'{bow_distance}',to_jsonb(p_action->>'distance'),true);
    end if;

    actual:=value;
    target_dodge:=case
      when action_type='physical'
       and private.character_weapon_family(p_target_id) in ('short_bow','long_bow')
      then private.bow_dodge_chance(coalesce(target_state->>'bow_distance','medium'))
      else 0 end;

    if target_dodge>0 and floor(random()*100)::integer<target_dodge then
      actual:=0;
    end if;

    if actual>0 then
      if coalesce(p_action->>'crit_kind','')='physical' and family='greatsword' then
        critical:=private.roll_character_critical_with_bonus(
          p_actor_id,
          private.greatsword_crit_bonus_percent(coalesce((actor_state->>'greatsword_stacks')::integer,0))
        );
      elsif p_action->>'crit_kind' in ('physical','magic') then
        critical:=private.roll_character_critical(p_actor_id);
      end if;

      if critical then
        actual:=private.apply_critical_damage(
          actual,coalesce(p_action->>'crit_kind','magic'),true,false
        );
      end if;

      before_guard:=actual;
      if coalesce((target_state->>'guard')::integer,0)>0 then
        actual:=greatest(
          1,
          round(actual*(100-coalesce((target_state->>'guard')::integer,0))/100.0)::integer
        );
        blocked:=greatest(0,before_guard-actual);
        target_state:=jsonb_set(target_state,'{guard}','0'::jsonb,true);
        if action_type='physical' and blocked>0 then
          target_state:=jsonb_set(
            target_state,'{counter_bonus}',
            to_jsonb(least(35,greatest(5,round(blocked*100.0/greatest(1,before_guard)*0.45)::integer))),
            true
          );
        end if;
      end if;

      actual:=least(target_hp,actual);
      target_hp:=greatest(0,target_hp-actual);

      if coalesce((target_state->>'reflect')::integer,0)>0 and actual>0 then
        reflected:=least(
          actor_hp,
          greatest(1,round(actual*coalesce((target_state->>'reflect')::integer,0)/100.0)::integer)
        );
        actor_hp:=greatest(0,actor_hp-reflected);
        target_state:=jsonb_set(target_state,'{reflect}','0'::jsonb,true);
      end if;

      if action_type='physical' and family='dagger' and actual>0 and target_hp>0 then
        extra_hits:=private.roll_echo_strike_extra_hits(
          private.character_echo_strike_chance(p_actor_id),50
        );
        if extra_hits>0 then
          for i in 1..extra_hits loop
            exit when target_hp<=0;
            extra_single:=value;
            if private.roll_character_critical(p_actor_id) then
              extra_single:=private.apply_critical_damage(extra_single,'physical',true,false);
            end if;
            extra_single:=least(target_hp,greatest(1,extra_single));
            target_hp:=greatest(0,target_hp-extra_single);
            extra_damage:=extra_damage+extra_single;
          end loop;
          actual:=actual+extra_damage;
          total_hits:=1+extra_hits;
        end if;
      end if;

      if action_type='physical' and actual>0 and target_hp>0 then
        if floor(random()*100)::integer<private.weapon_family_stun_chance(p_actor_id,false) then
          target_state:=jsonb_set(
            target_state,'{effects}',
            private.arena_apply_effect(target_state->'effects','stun',1,0),
            true
          );
        end if;

        if private.character_bloodshed_chance(p_actor_id)>0 then
          for i in 1..greatest(1,total_hits) loop
            if floor(random()*100)::integer<private.character_bloodshed_chance(p_actor_id) then
              bloodshed_procs:=bloodshed_procs+1;
            end if;
          end loop;
          if bloodshed_procs>0 then
            target_state:=jsonb_set(
              target_state,'{bloodshed_stacks}',
              to_jsonb(coalesce((target_state->>'bloodshed_stacks')::integer,0)+bloodshed_procs),
              true
            );
          end if;
        end if;

        if private.character_has_white_fang(p_actor_id) then
          if coalesce((actor_state->>'white_fang_wounds')::integer,0)>=3 then
            select * into rupture from private.white_fang_rupture_roll(
              p_actor_id,greatest(1,coalesce((target_state->>'hp_max')::integer,1))
            );
            rupture_damage:=least(target_hp,greatest(0,rupture.final_damage));
            target_hp:=greatest(0,target_hp-rupture_damage);
            actual:=actual+rupture_damage;
            actor_state:=jsonb_set(actor_state,'{white_fang_wounds}','0'::jsonb,true);
          else
            actor_state:=jsonb_set(
              actor_state,'{white_fang_wounds}',
              to_jsonb(least(3,coalesce((actor_state->>'white_fang_wounds')::integer,0)+1)),
              true
            );
          end if;
        end if;
      end if;

      if action_type='spell'
         and p_action->>'status_type' is not null
         and coalesce((p_action->>'status_chance')::integer,0)>0
         and target_hp>0
         and floor(random()*100)::integer<coalesce((p_action->>'status_chance')::integer,0)
      then
        target_state:=jsonb_set(
          target_state,'{effects}',
          private.arena_apply_effect(
            target_state->'effects',p_action->>'status_type',
            greatest(1,coalesce((p_action->>'status_turns')::integer,1)),
            greatest(0,coalesce((p_action->>'status_potency')::integer,0))
          ),
          true
        );
        status_applied:=true;
      end if;

      target_state:=jsonb_set(target_state,'{hp}',to_jsonb(target_hp),true);
      actor_state:=jsonb_set(actor_state,'{hp}',to_jsonb(actor_hp),true);

      if actual>0 and coalesce((p_actor_stats->>'lifesteal_percent')::integer,0)>0 and actor_hp>0 then
        healing:=greatest(
          0,
          least(
            actor_hp_max-actor_hp,
            floor(actual*coalesce((p_actor_stats->>'lifesteal_percent')::integer,0)/100.0)::integer
          )
        );
        actor_hp:=least(actor_hp_max,actor_hp+healing);
        actor_state:=jsonb_set(actor_state,'{hp}',to_jsonb(actor_hp),true);
      end if;

      if actual>0 and coalesce((p_actor_stats->>'mana_on_hit')::integer,0)>0 then
        actor_mana:=least(
          actor_mana_max,
          actor_mana+coalesce((p_actor_stats->>'mana_on_hit')::integer,0)*greatest(1,total_hits)
        );
        actor_state:=jsonb_set(actor_state,'{mana}',to_jsonb(actor_mana),true);
      end if;

      if coalesce((actor_state->>'buff_hits')::integer,0)>0 then
        actor_state:=jsonb_set(
          actor_state,'{buff_hits}',
          to_jsonb(greatest(0,coalesce((actor_state->>'buff_hits')::integer,0)-1)),true
        );
        if coalesce((actor_state->>'buff_hits')::integer,0)<=0 then
          actor_state:=jsonb_set(actor_state,'{buff_percent}','0'::jsonb,true);
        end if;
      end if;

      if action_type='physical' and family='katana' then
        actor_state:=jsonb_set(
          actor_state,'{katana_stacks}',
          to_jsonb(least(5,coalesce((actor_state->>'katana_stacks')::integer,0)+1)),true
        );
      else
        actor_state:=jsonb_set(actor_state,'{katana_stacks}','0'::jsonb,true);
      end if;

      if action_type='physical' and family='greatsword' then
        actor_state:=jsonb_set(
          actor_state,'{greatsword_stacks}',
          to_jsonb(case when critical then 0 else least(5,coalesce((actor_state->>'greatsword_stacks')::integer,0)+1) end),
          true
        );
      end if;

      if action_type='physical' and coalesce((actor_state->>'counter_bonus')::integer,0)>0 then
        actor_state:=jsonb_set(actor_state,'{counter_bonus}','0'::jsonb,true);
      end if;

      if coalesce((p_action->>'full_draw_release')::boolean,false) then
        actor_state:=jsonb_set(actor_state,'{bow_draw_pending}','false'::jsonb,true);
      end if;
    end if;
  end if;

  -- Advance short plan memory. Emergency/support actions intentionally cancel
  -- an old line; setup actions can start a fresh 2–3 action plan.
  if action_type='buff' then
    next_plan:='buff_chain';
    next_plan_remaining:=least(3,greatest(1,coalesce((p_action->>'turns')::integer,1)));
  elsif action_type='bow_draw' then
    next_plan:='bow_release';
    next_plan_remaining:=1;
  elsif action_type in ('guard','guard_spell')
        and coalesce(p_action->>'plan','') like 'Блок →%' then
    next_plan:='counterstrike';
    next_plan_remaining:=1;
  elsif action_type='spell' and status_applied and status_type='vulnerable' then
    next_plan:='vulnerable_chain';
    next_plan_remaining:=least(2,greatest(1,coalesce((p_action->>'status_turns')::integer,1)));
  elsif action_type='spell' and status_applied and status_type='stun' then
    next_plan:='tempo_window';
    next_plan_remaining:=1;
  elsif action_type='spell' and status_applied and status_type in ('weaken','chill') then
    next_plan:='pressure_chain';
    next_plan_remaining:=least(2,greatest(1,coalesce((p_action->>'status_turns')::integer,1)));
  elsif action_type='physical' and target_hp>0 then
    if current_plan in ('counterstrike','buff_chain','vulnerable_chain','tempo_window','pressure_chain',
                        'rhythm_chain','greatsword_chain','wound_chain')
       and current_plan_remaining>1
    then
      next_plan:=current_plan;
      next_plan_remaining:=current_plan_remaining-1;
    elsif family='katana' and coalesce((actor_state->>'katana_stacks')::integer,0)>0 then
      next_plan:='rhythm_chain';
      next_plan_remaining:=2;
    elsif family='greatsword' and coalesce((actor_state->>'greatsword_stacks')::integer,0)>0 then
      next_plan:='greatsword_chain';
      next_plan_remaining:=2;
    elsif private.character_has_white_fang(p_actor_id)
       and coalesce((actor_state->>'white_fang_wounds')::integer,0)>0
    then
      next_plan:='wound_chain';
      next_plan_remaining:=least(3,greatest(1,4-coalesce((actor_state->>'white_fang_wounds')::integer,0)));
    end if;
  elsif action_type in ('magic','spell') and target_hp>0
        and current_plan in ('buff_chain','vulnerable_chain','tempo_window','pressure_chain')
        and current_plan_remaining>1
  then
    next_plan:=current_plan;
    next_plan_remaining:=current_plan_remaining-1;
  end if;

  if next_plan_remaining>0 then
    actor_state:=jsonb_set(actor_state,'{plan_key}',to_jsonb(next_plan),true);
    actor_state:=jsonb_set(actor_state,'{plan_remaining}',to_jsonb(next_plan_remaining),true);
  else
    actor_state:=jsonb_set(actor_state,'{plan_key}',to_jsonb(''::text),true);
    actor_state:=jsonb_set(actor_state,'{plan_remaining}','0'::jsonb,true);
  end if;

  actor_state:=jsonb_set(
    actor_state,'{actions}',
    to_jsonb(coalesce((actor_state->>'actions')::integer,0)+1),true
  );

  return jsonb_build_object(
    'actor_state',actor_state,'target_state',target_state,
    'damage',actual,'healing',healing,'blocked',blocked,'reflected',reflected,
    'critical',critical,'extra_hits',extra_hits,'status_applied',status_applied
  );
end;
$function$
;

revoke all on function private.arena_choose_action_v2(uuid,jsonb,jsonb,uuid,jsonb,jsonb)
  from public, anon, authenticated;
revoke all on function private.arena_execute_action_v2(uuid,jsonb,jsonb,uuid,jsonb,jsonb,jsonb)
  from public, anon, authenticated;
