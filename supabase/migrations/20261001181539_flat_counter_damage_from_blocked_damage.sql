
alter table public.pvp_duel_states
  add column if not exists counter_blocked_damage integer not null default 0;

alter table public.pvp_duel_states
  drop constraint if exists pvp_duel_states_counter_blocked_damage_check;
alter table public.pvp_duel_states
  add constraint pvp_duel_states_counter_blocked_damage_check
  check(counter_blocked_damage>=0);

update public.pvp_duel_states
set counter_bonus_percent=0,
    counter_blocked_damage=0
where counter_bonus_percent<>0 or counter_blocked_damage<>0;

update public.combat_encounters
set player_counter_bonus_percent=0
where player_counter_bonus_percent<>0;

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
  counter_damage_estimate integer:=0;
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
    physical_score:=greatest(
      1,
      round(physical_damage*expected_crit)::integer
        +greatest(0,coalesce((p_actor_state->>'counter_bonus')::integer,0))
    );

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
    counter_damage_estimate:=greatest(1,round(blocked_estimate*0.50)::integer);
    guard_plan_score:=round(
      blocked_estimate
        *case when hp_percent<=45 then 1.15 when hp_percent<=65 then 0.85 else 0.55 end
      +counter_damage_estimate*0.78
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
            greatest(0,coalesce((p_target_stats->>'magic_defense')::integer,0))*0.85
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

CREATE OR REPLACE FUNCTION private.arena_estimate_physical_damage(p_actor_id uuid, p_actor_stats jsonb, p_actor_state jsonb, p_target_stats jsonb, p_target_state jsonb, p_full_draw boolean DEFAULT false)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  family text:=private.character_weapon_family(p_actor_id);
  weapon_type text:=coalesce(p_actor_stats->>'weapon_damage_type','blunt');
  distance text:=coalesce(p_actor_state->>'bow_distance','medium');
  actor_power integer:=greatest(1,coalesce((p_actor_stats->>'physical_power')::integer,1));
  target_def integer:=greatest(0,coalesce((p_target_stats->>'defense')::integer,0));
  target_hp integer:=greatest(0,coalesce((p_target_state->>'hp')::integer,0));
  target_hp_max integer:=greatest(1,coalesce((p_target_state->>'hp_max')::integer,1));
  raw integer:=0;
  resistance integer:=0;
  bonus integer:=0;
  reduction integer:=private.arena_effect_reduction(p_actor_state->'effects');
  vulnerable integer:=private.arena_effect_vulnerable(p_target_state->'effects');
  buff integer:=case when coalesce((p_actor_state->>'buff_hits')::integer,0)>0 then coalesce((p_actor_state->>'buff_percent')::integer,0) else 0 end;
  penetration integer:=0;
begin
  if family in ('short_bow','long_bow') then
    penetration:=case when p_full_draw then private.character_bow_penetration(p_actor_id) else 0 end;
    target_def:=floor(target_def*(100-penetration)/100.0)::integer;
    raw:=greatest(
      1,
      private.damage_after_armor(
        round(actor_power*private.bow_distance_multiplier(distance)
          *case when p_full_draw then 1.60 else 1.00 end)::integer,
        target_def
      )
    );
  else
    raw:=private.weapon_family_physical_raw_damage(
      p_actor_id,actor_power,target_def,target_hp_max,0
    );
  end if;

  bonus:=coalesce((p_actor_stats->>'all_damage_bonus_percent')::integer,0)
    +coalesce((p_actor_stats->>'physical_damage_bonus_percent')::integer,0)
    +private.character_damage_bonus(p_actor_id,weapon_type)
    +buff;

  raw:=greatest(1,round(raw*(100+bonus)/100.0)::integer);
  raw:=greatest(1,round(raw*(100-reduction)/100.0)::integer);
  raw:=greatest(1,round(raw*(100+vulnerable)/100.0)::integer);

  resistance:=private.weapon_family_adjust_resistance(
    family,weapon_type,
    private.damage_resistance_percent(
      coalesce(p_target_stats->'damage_resistances','{}'::jsonb),
      weapon_type
    )
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

  if family='katana' then
    raw:=greatest(
      1,
      round(raw*(100+private.katana_rhythm_bonus_percent(
        coalesce((p_actor_state->>'katana_stacks')::integer,0)
      ))/100.0)::integer
    );
  end if;

  -- This function returns actual pre-crit hit damage. Crit/procs are scored separately
  -- and rolled only once when the arena action is executed.
  return greatest(1,raw);
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

      if action_type='physical'
         and coalesce((actor_state->>'counter_bonus')::integer,0)>0
         and actual>0
      then
        actual:=actual+greatest(0,coalesce((actor_state->>'counter_bonus')::integer,0));
        actor_state:=jsonb_set(actor_state,'{counter_bonus}','0'::jsonb,true);
      end if;

      before_guard:=actual;
      if coalesce((target_state->>'guard')::integer,0)>0 then
        actual:=greatest(
          1,
          round(actual*(100-coalesce((target_state->>'guard')::integer,0))/100.0)::integer
        );
        blocked:=greatest(0,before_guard-actual);
        target_state:=jsonb_set(target_state,'{guard}','0'::jsonb,true);
        if blocked>0 then
          target_state:=jsonb_set(
            target_state,'{counter_bonus}',
            to_jsonb(greatest(
              coalesce((target_state->>'counter_bonus')::integer,0),
              greatest(1,round(blocked*0.50)::integer)
            )),
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
            encounter.enemy_defense*0.85
          )
        )
      );
      raw_damage:=private.ensure_spell_stronger_than_innate(
        raw_damage,
        greatest(
          1,
          private.damage_after_armor(
            stats.magic_power+variance,
            encounter.enemy_defense*0.80
          )
        ),
        10
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
            encounter.enemy_defense*0.85
          )
        )
      );
      raw_damage:=private.ensure_spell_stronger_than_innate(
        raw_damage,
        greatest(
          1,
          private.damage_after_armor(
            stats.magic_power+variance,
            encounter.enemy_defense*0.80
          )
        ),
        10
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

    if p_mode='physical' and encounter.player_counter_blocked_damage>0 then
      counter_bonus:=greatest(1,round(encounter.player_counter_blocked_damage*0.50)::integer);
      if enemy_guard_blocked>0 and encounter.enemy_guard_percent>0 then
        counter_bonus:=greatest(
          1,
          ceil(counter_bonus*(100-encounter.enemy_guard_percent)/100.0)::integer
        );
      end if;
      player_damage:=player_damage+counter_bonus;
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

    if p_mode='physical' and encounter.player_counter_blocked_damage>0 then
      player_message:=player_message
        ||' Контратака: +'||counter_bonus||' урона из '
        ||encounter.player_counter_blocked_damage||' заблокированных.';
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
      if adaptive_enabled then
        adaptive_ai_state:=coalesce(encounter.enemy_ai_state,'{}'::jsonb);
        adaptive_next_charge_round:=next_round+greatest(1,encounter.enemy_special_every_n-1);
        adaptive_ai_state:=jsonb_set(adaptive_ai_state,'{danger_pending}','false'::jsonb,true);
        adaptive_ai_state:=jsonb_set(adaptive_ai_state,'{delay_used}','false'::jsonb,true);
        adaptive_ai_state:=jsonb_set(adaptive_ai_state,'{next_charge_round}',to_jsonb(adaptive_next_charge_round),true);
        adaptive_ai_state:=adaptive_ai_state-'charge_hp';
        update public.combat_encounters
        set enemy_special_charging=false,
            enemy_special_started_round=null,
            enemy_ai_state=adaptive_ai_state
        where id=encounter.id;
      else
        update public.combat_encounters
        set enemy_special_charging=false,enemy_special_started_round=null
        where id=encounter.id;
      end if;
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
    adaptive_special_multiplier:=encounter.enemy_special_damage_multiplier;

    if special_attack_active and adaptive_enabled then
      adaptive_ai_state:=coalesce(encounter.enemy_ai_state,'{}'::jsonb);
      adaptive_delay_used:=coalesce((adaptive_ai_state->>'delay_used')::boolean,false);
      adaptive_defensive_response:=guard_active
        or support_guard_percent>0
        or encounter.player_reflect_percent>0;

      if adaptive_defensive_response then
        adaptive_delay_chance:=adaptive_defensive_delay_chance;
      end if;

      if not adaptive_delay_used
         and floor(random()*100)::integer<adaptive_delay_chance
      then
        special_attack_active:=false;
        adaptive_ai_state:=jsonb_set(adaptive_ai_state,'{delay_used}','true'::jsonb,true);
        update public.combat_encounters
        set enemy_ai_state=adaptive_ai_state
        where id=encounter.id;

        insert into public.combat_turns(
          encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
        )
        values(
          encounter.id,next_round,'system','special_delay',0,player_hp_after,enemy_hp_after,
          encounter.enemy_name||' удерживает опасный ритм и не раскрывает приём. '
          ||'Подготовка не исчезла: следующий момент уже опаснее.'
        );
      end if;
    end if;

    if special_attack_active and adaptive_enabled then
      adaptive_ai_state:=coalesce(encounter.enemy_ai_state,'{}'::jsonb);
      adaptive_charge_hp:=coalesce((adaptive_ai_state->>'charge_hp')::integer,enemy_hp_after);
      adaptive_damage_since_charge:=greatest(0,adaptive_charge_hp-enemy_hp_after);

      if adaptive_break_threshold>0
         and adaptive_damage_since_charge*100>=encounter.enemy_hp_max*adaptive_break_threshold
      then
        adaptive_special_multiplier:=encounter.enemy_special_damage_multiplier
          *(100-adaptive_break_reduction)/100.0;

        insert into public.combat_turns(
          encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
        )
        values(
          encounter.id,next_round,'system','special_disrupted',0,player_hp_after,enemy_hp_after,
          'Агрессивное давление сбивает часть подготовки «'||encounter.enemy_special_name
          ||'»: сила особого удара снижена на '||adaptive_break_reduction||'%.'
        );
      end if;
    end if;

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
            round(enemy_attack_effective*adaptive_special_multiplier)::integer+variance,
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
          counter_bonus:=greatest(1,round(blocked_damage*0.50)::integer);
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
          set player_counter_bonus_percent=0,
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
      if adaptive_enabled then
        select coalesce(ce.enemy_ai_state,'{}'::jsonb)
        into adaptive_ai_state
        from public.combat_encounters ce
        where ce.id=encounter.id;

        adaptive_next_charge_round:=next_round+greatest(1,encounter.enemy_special_every_n-1);
        adaptive_ai_state:=jsonb_set(adaptive_ai_state,'{danger_pending}','false'::jsonb,true);
        adaptive_ai_state:=jsonb_set(adaptive_ai_state,'{delay_used}','false'::jsonb,true);
        adaptive_ai_state:=jsonb_set(adaptive_ai_state,'{next_charge_round}',to_jsonb(adaptive_next_charge_round),true);
        adaptive_ai_state:=adaptive_ai_state-'charge_hp';

        update public.combat_encounters
        set enemy_special_charging=false,
            enemy_special_started_round=null,
            enemy_ai_state=adaptive_ai_state
        where id=encounter.id;
      else
        update public.combat_encounters
        set enemy_special_charging=false,enemy_special_started_round=null
        where id=encounter.id;
      end if;
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
;

CREATE OR REPLACE FUNCTION private.run_combat_autobattle_internal(p_encounter_id uuid, p_max_actions integer DEFAULT 80)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
  encounter public.combat_encounters;
  settings public.character_autobattle_settings;
  stats record;
  spell record;
  chosen_spell_id uuid;
  chosen_spell_name text;
  physical_score integer:=0;
  magic_score integer:=0;
  best_free_score integer:=0;
  reserve_mana integer:=0;
  hp_percent integer:=100;
  mode text;
  actions integer:=0;
  result public.combat_encounters;
  allow_physical boolean;
  allow_magic boolean;
  allow_spells boolean;
  guard_mode text;
  guard_hp integer;
  guard_every integer;
  guard_due boolean;
  support_enabled boolean;
  support_heal_hp integer;
  support_cleanse_min integer;
  support_shield_special boolean;
  support_buff_enabled boolean;
  support_spell_id uuid;
  support_spell_kind text;
  player_debuff_count integer:=0;
  style_mode boolean:=coalesce(current_setting('veira.style_autobattle',true),'')='1';
  style_profile public.character_combat_style_profiles%rowtype;
  style_total integer:=0;
  style_roll integer:=0;
  bow_family text;
  bow_decision jsonb;
  bow_action text;
  bow_distance text;
  physical_plan_score integer:=0;
  magic_plan_score integer:=0;
  best_plan_score integer:=0;
  future_combo_bonus integer:=0;
  planned_buff_id uuid;
  planned_buff_percent integer:=0;
  planned_buff_turns integer:=0;
  planned_buff_gain integer:=0;
  planned_buff_threshold numeric:=0.85;
begin
  perform set_config('veira.autobattle','1',true);
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_max_actions<1 or p_max_actions>120 then raise exception 'INVALID_AUTOBATTLE_ACTION_LIMIT'; end if;

  select ce.* into encounter
  from public.combat_encounters ce
  join public.characters c on c.id=ce.character_id
  where ce.id=p_encounter_id and c.owner_user_id=caller;

  if encounter.id is null then raise exception 'COMBAT_NOT_FOUND'; end if;

  settings:=private.ensure_character_autobattle_settings(encounter.character_id);

  if style_mode then
    select * into style_profile
    from public.character_combat_style_profiles
    where character_id=encounter.character_id
      and context=case when encounter.is_boss then 'boss' else 'normal' end;

    if (style_profile.character_id is null
        or style_profile.sample_battles<3
        or style_profile.sample_actions<12
        or style_profile.confidence_percent<50)
       and encounter.is_boss
    then
      select * into style_profile
      from public.character_combat_style_profiles
      where character_id=encounter.character_id and context='normal';
    end if;

    if style_profile.character_id is null
       or style_profile.sample_battles<3
       or style_profile.sample_actions<12
       or style_profile.confidence_percent<50
    then raise exception 'STYLE_PROFILE_NOT_READY'; end if;
  end if;

  if encounter.status<>'active' then
    return jsonb_build_object(
      'status',encounter.status,'reason',encounter.status,
      'actions',0,'encounter_id',encounter.id
    );
  end if;

  insert into public.combat_turns(
    encounter_id,round,actor,action_type,damage,
    player_hp_after,enemy_hp_after,message
  )
  values(
    encounter.id,encounter.round,'system','autobattle_start',0,
    encounter.player_hp_current,encounter.enemy_hp_current,
    case
      when style_mode then 'Автобой «Играть как я» использует изученный стиль персонажа.'
      when encounter.is_boss then 'Автобой включён по тактике для босса.'
      else 'Автобой включён по тактике для обычного боя.'
    end
  );

  loop
    select * into encounter
    from public.combat_encounters
    where id=p_encounter_id;

    exit when encounter.status<>'active';

    select * into stats
    from private.get_character_combat_stats(encounter.character_id);

    bow_family:=private.character_weapon_family(encounter.character_id);
    bow_decision:=null;
    bow_action:=null;
    bow_distance:=null;

    hp_percent:=case
      when stats.hp_max<=0 then 0
      else floor(stats.hp_current*100.0/stats.hp_max)::integer
    end;
    reserve_mana:=floor(
      stats.mana_max*
      (case when style_mode then style_profile.mana_reserve_percent else settings.mana_reserve_percent end)
      /100.0
    )::integer;

    if not style_mode
       and actions>0
       and hp_percent<=settings.stop_hp_percent
       and not (
         settings.use_learned_spells
         and case when encounter.is_boss
           then settings.boss_support_enabled and settings.boss_heal_hp_percent>0 and hp_percent<=settings.boss_heal_hp_percent
           else settings.normal_support_enabled and settings.normal_heal_hp_percent>0 and hp_percent<=settings.normal_heal_hp_percent
         end
         and exists(
           select 1
           from public.character_spells cs
           join public.spell_definitions s on s.id=cs.spell_id
           where cs.character_id=encounter.character_id
          and private.character_spell_equipped(encounter.character_id,cs.spell_id)
             and s.enabled=true
             and s.spell_kind='heal'
             and stats.level>=s.required_level
             and stats.mana_current>=private.character_effective_spell_mana_cost(encounter.character_id,s.id)
             and stats.mana_current-private.character_effective_spell_mana_cost(encounter.character_id,s.id)>=reserve_mana
         )
       )
    then
      insert into public.combat_turns(
        encounter_id,round,actor,action_type,damage,
        player_hp_after,enemy_hp_after,message
      )
      values(
        encounter.id,encounter.round,'system','autobattle_stop',0,
        stats.hp_current,encounter.enemy_hp_current,
        'Автобой остановлен: здоровье достигло '||hp_percent||
        '%, порог безопасности — '||settings.stop_hp_percent||'%.'
      );

      return jsonb_build_object(
        'status','stopped','reason','low_hp','actions',actions,
        'encounter_id',encounter.id,'player_hp',stats.hp_current,
        'player_hp_max',stats.hp_max,'player_mana',stats.mana_current,
        'player_mana_max',stats.mana_max
      );
    end if;

    if style_mode then
      allow_physical:=style_profile.physical_weight>0;
      allow_magic:=style_profile.magic_weight>0;
      allow_spells:=style_profile.damage_spell_weight>0;
      guard_mode:='never';
      guard_hp:=0;
      guard_every:=0;
      support_enabled:=true;
      support_heal_hp:=case when style_profile.heal_weight>0 then style_profile.heal_hp_percent else 0 end;
      support_cleanse_min:=case when style_profile.cleanse_weight>0 then style_profile.cleanse_min_debuffs else 0 end;
      support_shield_special:=style_profile.shield_weight>0 and style_profile.telegraph_guard_percent>=35;
      support_buff_enabled:=style_profile.buff_weight>0;
    elsif encounter.is_boss then
      allow_physical:=settings.boss_allow_physical;
      allow_magic:=settings.boss_allow_magic;
      allow_spells:=settings.boss_allow_spells and settings.use_learned_spells;
      guard_mode:=settings.boss_guard_mode;
      guard_hp:=settings.boss_guard_hp_percent;
      guard_every:=settings.boss_guard_every_n;
      support_enabled:=settings.boss_support_enabled;
      support_heal_hp:=settings.boss_heal_hp_percent;
      support_cleanse_min:=settings.boss_cleanse_min_debuffs;
      support_shield_special:=settings.boss_shield_special;
      support_buff_enabled:=settings.boss_buff_enabled;
    else
      allow_physical:=settings.normal_allow_physical;
      allow_magic:=settings.normal_allow_magic;
      allow_spells:=settings.normal_allow_spells and settings.use_learned_spells;
      guard_mode:=settings.normal_guard_mode;
      guard_hp:=settings.normal_guard_hp_percent;
      guard_every:=settings.normal_guard_every_n;
      support_enabled:=settings.normal_support_enabled;
      support_heal_hp:=settings.normal_heal_hp_percent;
      support_cleanse_min:=settings.normal_cleanse_min_debuffs;
      support_shield_special:=settings.normal_shield_special;
      support_buff_enabled:=settings.normal_buff_enabled;
    end if;

    support_spell_id:=null;
    support_spell_kind:=null;

    select coalesce(sum(case effect_type
      when 'stun' then 4
      when 'vulnerable' then 3
      when 'weaken' then 2
      when 'chill' then 2
      when 'burn' then 1
      when 'bleed' then 1
      when 'poison' then 1
      else 1 end),0)::integer into player_debuff_count
    from public.combat_status_effects
    where encounter_id=encounter.id and target='player';

    if (style_mode or settings.use_learned_spells) and support_enabled then
      if support_heal_hp>0
         and hp_percent<=support_heal_hp
         and encounter.enemy_hp_current*100>greatest(1,encounter.enemy_hp_max)*8
      then
        select s.id,s.spell_kind into support_spell_id,support_spell_kind
        from public.character_spells cs
        join public.spell_definitions s on s.id=cs.spell_id
        where cs.character_id=encounter.character_id
          and private.character_spell_equipped(encounter.character_id,cs.spell_id)
          and s.enabled=true
          and s.spell_kind='heal'
          and stats.level>=s.required_level
          and stats.mana_current>=private.character_effective_spell_mana_cost(encounter.character_id,s.id)
          and stats.mana_current-private.character_effective_spell_mana_cost(encounter.character_id,s.id)>=reserve_mana
        order by
          case when style_mode and s.id=style_profile.preferred_heal_spell_id then 0 else 1 end,
          private.autobattle_heal_score(
            encounter.character_id,s.id,stats.magic_power,
            greatest(0,stats.hp_max-stats.hp_current),hp_percent
          ) desc,
          private.concentrated_spell_direct_value(
            encounter.character_id,s.id,
            round(stats.magic_power*s.power_multiplier)::integer+s.flat_power
          ) desc,
          private.character_effective_spell_mana_cost(encounter.character_id,s.id) asc
        limit 1;
      end if;

      if support_spell_id is null
         and support_cleanse_min>0
         and player_debuff_count>=support_cleanse_min
         and encounter.enemy_hp_current*100>greatest(1,encounter.enemy_hp_max)*8
      then
        select s.id,s.spell_kind into support_spell_id,support_spell_kind
        from public.character_spells cs
        join public.spell_definitions s on s.id=cs.spell_id
        where cs.character_id=encounter.character_id
          and private.character_spell_equipped(encounter.character_id,cs.spell_id)
          and s.enabled=true
          and s.spell_kind='cleanse'
          and stats.level>=s.required_level
          and stats.mana_current>=private.character_effective_spell_mana_cost(encounter.character_id,s.id)
          and stats.mana_current-private.character_effective_spell_mana_cost(encounter.character_id,s.id)>=reserve_mana
        order by private.character_effective_spell_mana_cost(encounter.character_id,s.id) asc,s.required_level desc
        limit 1;
      end if;

      if support_spell_id is null
         and support_shield_special
         and encounter.enemy_special_charging
         and encounter.enemy_special_kind='attack'
      then
        select s.id,s.spell_kind into support_spell_id,support_spell_kind
        from public.character_spells cs
        join public.spell_definitions s on s.id=cs.spell_id
        where cs.character_id=encounter.character_id
          and private.character_spell_equipped(encounter.character_id,cs.spell_id)
          and s.enabled=true
          and s.spell_kind='guard'
          and stats.level>=s.required_level
          and stats.mana_current>=private.character_effective_spell_mana_cost(encounter.character_id,s.id)
          and stats.mana_current-private.character_effective_spell_mana_cost(encounter.character_id,s.id)>=reserve_mana
        order by private.concentrated_spell_percent_value(
          encounter.character_id,s.id,s.support_value
        ) desc,private.character_effective_spell_mana_cost(encounter.character_id,s.id) asc
        limit 1;
      end if;

      if support_spell_id is null
         and style_mode
         and support_buff_enabled
         and encounter.player_spell_damage_bonus_hits<=0
         and encounter.enemy_hp_max>0
         and encounter.enemy_hp_current*100>encounter.enemy_hp_max*30
      then
        select s.id,s.spell_kind into support_spell_id,support_spell_kind
        from public.character_spells cs
        join public.spell_definitions s on s.id=cs.spell_id
        where cs.character_id=encounter.character_id
          and private.character_spell_equipped(encounter.character_id,cs.spell_id)
          and s.enabled=true
          and s.spell_kind='buff'
          and stats.level>=s.required_level
          and stats.mana_current>=private.character_effective_spell_mana_cost(encounter.character_id,s.id)
          and stats.mana_current-private.character_effective_spell_mana_cost(encounter.character_id,s.id)>=reserve_mana
        order by (
          private.concentrated_spell_percent_value(encounter.character_id,s.id,s.support_value)
          *greatest(1,s.support_turns)
        ) desc,private.character_effective_spell_mana_cost(encounter.character_id,s.id) asc
        limit 1;
      end if;
    end if;

    if style_mode then
      guard_due:=encounter.enemy_special_charging
        and encounter.enemy_special_kind='attack'
        and style_profile.telegraph_guard_percent>0
        and floor(random()*100)::integer<style_profile.telegraph_guard_percent;
    else
      guard_due:=
        encounter.enemy_special_charging
        and encounter.enemy_special_kind='attack'
        and guard_mode<>'never';
    end if;

    if not style_mode and not guard_due then
      guard_due:=
        (encounter.player_counter_blocked_damage<=0 or not allow_physical)
        and guard_mode in ('low_hp','low_hp_or_interval')
        and hp_percent<=guard_hp
        and encounter.enemy_hp_current*100>greatest(1,encounter.enemy_hp_max)*8;
    end if;

    if not style_mode
       and (encounter.player_counter_blocked_damage<=0 or not allow_physical)
       and not guard_due
       and guard_mode in ('interval','low_hp_or_interval')
       and guard_every>0
       and ((encounter.round+1)%guard_every)=0
       and encounter.enemy_hp_current*100>greatest(1,encounter.enemy_hp_max)*8
    then
      guard_due:=true;
    end if;

    if encounter.player_bow_draw_pending
       and bow_family in ('short_bow','long_bow')
    then
      result:=private.perform_combat_action_internal(
        encounter.id,'physical',null,null
      );
      actions:=actions+1;
    elsif support_spell_id is not null then
      if bow_family in ('short_bow','long_bow') then
        update public.combat_encounters
        set player_bow_distance='far'
        where id=encounter.id and not player_bow_draw_pending;
        encounter.player_bow_distance:='far';
      end if;
      result:=private.perform_combat_action_internal(
        encounter.id,
        case when support_spell_kind='heal' then 'learned_spell' else 'support_spell' end,
        support_spell_id,null
      );
      actions:=actions+1;
    elsif encounter.player_counter_blocked_damage>0 and allow_physical then
      if bow_family in ('short_bow','long_bow') then
        bow_decision:=private.choose_bow_autobattle(encounter.id);
        bow_action:=coalesce(bow_decision->>'action','physical');
        bow_distance:=coalesce(bow_decision->>'distance',encounter.player_bow_distance);

        if not encounter.player_bow_draw_pending
           and bow_distance in ('close','medium','far')
           and bow_distance<>encounter.player_bow_distance
        then
          update public.combat_encounters
          set player_bow_distance=bow_distance
          where id=encounter.id;
        end if;

        result:=private.perform_combat_action_internal(
          encounter.id,bow_action,null,null
        );
      else
        result:=private.perform_combat_action_internal(
          encounter.id,'physical',null,null
        );
      end if;
      actions:=actions+1;
    elsif guard_due then
      if bow_family in ('short_bow','long_bow') then
        update public.combat_encounters
        set player_bow_distance='far'
        where id=encounter.id and not player_bow_draw_pending;
        encounter.player_bow_distance:='far';
      end if;
      result:=private.perform_combat_action_internal(
        encounter.id,'guard',null,null
      );
      actions:=actions+1;
    else
      physical_score:=0;
      magic_score:=0;
      best_free_score:=0;
      mode:=null;
      chosen_spell_id:=null;
      chosen_spell_name:=null;

      if style_mode then
        if style_profile.damage_spell_weight>0 then
          select s.id,s.name
          into chosen_spell_id,chosen_spell_name
          from public.character_spells cs
          join public.spell_definitions s on s.id=cs.spell_id
          where cs.character_id=encounter.character_id
          and private.character_spell_equipped(encounter.character_id,cs.spell_id)
            and s.enabled=true
            and s.spell_kind='damage'
            and s.damage_type is not null
            and stats.level>=s.required_level
            and stats.mana_current>=private.character_effective_spell_mana_cost(encounter.character_id,s.id)
            and stats.mana_current-private.character_effective_spell_mana_cost(encounter.character_id,s.id)>=reserve_mana
          order by
            case when s.id=style_profile.preferred_damage_spell_id then 0 else 1 end,
            private.autobattle_estimated_damage(
              private.concentrated_spell_direct_value(
                encounter.character_id,s.id,
                greatest(
                  1,
                  private.damage_after_armor(
                    round(stats.magic_power*s.power_multiplier)::integer+s.flat_power,
                    encounter.enemy_defense*0.85
                  )
                )
              ),
              private.damage_resistance_percent(encounter.enemy_resistances,s.damage_type),
              stats.all_damage_bonus_percent+stats.magic_damage_bonus_percent
                +private.character_spell_family_damage_bonus_percent(encounter.character_id,s.id)
                +case
                when private.combat_encounter_is_strong(encounter.id)
                  then private.character_religion_modifier_number(encounter.character_id,'strong_enemy_damage_bonus')
                else 0
              end
              +case when encounter.is_boss then stats.boss_damage_bonus_percent else 0 end
            )
            *private.character_expected_critical_multiplier(encounter.character_id,'magic') desc,
            private.character_effective_spell_mana_cost(encounter.character_id,s.id) asc
          limit 1;
        end if;

        style_total:=
          case when allow_physical then style_profile.physical_weight else 0 end
          +case when allow_magic then style_profile.magic_weight else 0 end
          +case when chosen_spell_id is not null then style_profile.damage_spell_weight else 0 end
          +style_profile.guard_weight;

        if style_total<=0 then
          mode:=case when allow_physical then 'physical' when allow_magic then 'magic' else 'guard' end;
        else
          style_roll:=floor(random()*style_total)::integer+1;
          if allow_physical and style_roll<=style_profile.physical_weight then
            mode:='physical';
          else
            style_roll:=style_roll-case when allow_physical then style_profile.physical_weight else 0 end;
            if allow_magic and style_roll<=style_profile.magic_weight then
              mode:='magic';
            else
              style_roll:=style_roll-case when allow_magic then style_profile.magic_weight else 0 end;
              if chosen_spell_id is not null and style_roll<=style_profile.damage_spell_weight then
                mode:='style_spell';
              else
                mode:='guard';
              end if;
            end if;
          end if;
        end if;

        if mode='physical' and bow_family in ('short_bow','long_bow') then
          bow_decision:=private.choose_bow_autobattle(encounter.id);
          bow_action:=coalesce(bow_decision->>'action','physical');
          bow_distance:=coalesce(bow_decision->>'distance',encounter.player_bow_distance);

          if not encounter.player_bow_draw_pending
             and bow_distance in ('close','medium','far')
             and bow_distance<>encounter.player_bow_distance
          then
            update public.combat_encounters
            set player_bow_distance=bow_distance
            where id=encounter.id;
          end if;

          result:=private.perform_combat_action_internal(encounter.id,bow_action,null,null);
        elsif mode='style_spell' and chosen_spell_id is not null then
          if bow_family in ('short_bow','long_bow') then
            update public.combat_encounters set player_bow_distance='far'
            where id=encounter.id and not player_bow_draw_pending;
            encounter.player_bow_distance:='far';
          end if;
          result:=private.perform_combat_action_internal(encounter.id,'learned_spell',chosen_spell_id,null);
        else
          if bow_family in ('short_bow','long_bow') then
            update public.combat_encounters set player_bow_distance='far'
            where id=encounter.id and not player_bow_draw_pending;
            encounter.player_bow_distance:='far';
          end if;
          result:=private.perform_combat_action_internal(encounter.id,coalesce(mode,'guard'),null,null);
        end if;
        actions:=actions+1;
      else

      if allow_physical then
        if bow_family in ('short_bow','long_bow') then
          bow_decision:=private.choose_bow_autobattle(encounter.id);
          physical_score:=greatest(1,coalesce((bow_decision->>'score')::integer,1));
        else
          physical_score:=round(
            private.autobattle_estimated_damage(
            case
              when bow_family='dagger' then
                round(
                  private.weapon_family_physical_raw_damage(
                    encounter.character_id,
                    stats.physical_power,
                    encounter.enemy_defense,
                    encounter.enemy_hp_max,
                    case when bow_family='blade' then 4 else 0 end
                  )
                  *100.0/greatest(5,100-private.character_echo_strike_chance(encounter.character_id))
                )::integer
              else private.weapon_family_physical_raw_damage(
                encounter.character_id,
                stats.physical_power,
                encounter.enemy_defense,
                encounter.enemy_hp_max,
                case when bow_family='blade' then 4 else 0 end
              )
            end,
            private.weapon_family_adjust_resistance(
              bow_family,
              stats.weapon_damage_type,
              private.damage_resistance_percent(
                encounter.enemy_resistances,stats.weapon_damage_type
              )
            ),
            stats.all_damage_bonus_percent+stats.physical_damage_bonus_percent
              +case
                when private.combat_encounter_is_strong(encounter.id)
                  then private.character_religion_modifier_number(encounter.character_id,'strong_enemy_damage_bonus')
                else 0
              end
              +case when encounter.is_boss then stats.boss_damage_bonus_percent else 0 end
            )
            *private.character_expected_critical_multiplier(encounter.character_id,'physical')
          )::integer;
        end if;
        mode:='physical';
        best_free_score:=physical_score;
      end if;

      if allow_magic then
        magic_score:=round(
          private.autobattle_estimated_damage(
            private.damage_after_armor(
              stats.magic_power,
              encounter.enemy_defense*0.80
            ),
            private.damage_resistance_percent(
              encounter.enemy_resistances,stats.magic_damage_type
            ),
            stats.all_damage_bonus_percent+stats.magic_damage_bonus_percent
              +case
                when private.combat_encounter_is_strong(encounter.id)
                  then private.character_religion_modifier_number(encounter.character_id,'strong_enemy_damage_bonus')
                else 0
              end
              +case when encounter.is_boss then stats.boss_damage_bonus_percent else 0 end
          )
          *private.character_expected_critical_multiplier(encounter.character_id,'magic')
        )::integer;

        if mode is null or magic_score>best_free_score then
          mode:='magic';
          best_free_score:=magic_score;
        end if;
      end if;

      physical_plan_score:=physical_score;
      magic_plan_score:=magic_score;
      future_combo_bonus:=0;

      if allow_physical and physical_score>0 and bow_family='katana' then
        future_combo_bonus:=future_combo_bonus
          +round(
            physical_score
            *greatest(0,
              private.katana_rhythm_bonus_percent(least(5,encounter.player_katana_rhythm_stacks+1))
              -private.katana_rhythm_bonus_percent(encounter.player_katana_rhythm_stacks)
            )/100.0*0.78
          )::integer
          +round(
            physical_score
            *greatest(0,
              private.katana_rhythm_bonus_percent(least(5,encounter.player_katana_rhythm_stacks+2))
              -private.katana_rhythm_bonus_percent(least(5,encounter.player_katana_rhythm_stacks+1))
            )/100.0*0.48
          )::integer;
      elsif allow_physical and physical_score>0 and bow_family='greatsword' then
        future_combo_bonus:=future_combo_bonus
          +round(
            physical_score
            *greatest(0,
              private.greatsword_crit_bonus_percent(least(5,encounter.player_greatsword_crit_stacks+1))
              -private.greatsword_crit_bonus_percent(encounter.player_greatsword_crit_stacks)
            )/100.0*0.50*0.78
          )::integer
          +round(
            physical_score
            *greatest(0,
              private.greatsword_crit_bonus_percent(least(5,encounter.player_greatsword_crit_stacks+2))
              -private.greatsword_crit_bonus_percent(least(5,encounter.player_greatsword_crit_stacks+1))
            )/100.0*0.50*0.48
          )::integer;
      end if;

      if allow_physical
         and physical_score>0
         and private.character_has_white_fang(encounter.character_id)
      then
        if encounter.white_fang_wounds=2 then
          future_combo_bonus:=future_combo_bonus+round(encounter.enemy_hp_max*0.10*0.78)::integer;
        elsif encounter.white_fang_wounds=1 then
          future_combo_bonus:=future_combo_bonus+round(encounter.enemy_hp_max*0.10*0.48)::integer;
        end if;
      end if;

      if physical_plan_score>0 then
        physical_plan_score:=physical_plan_score+future_combo_bonus;
      end if;
      best_plan_score:=greatest(physical_plan_score,magic_plan_score,best_free_score,1);

      if allow_physical and physical_plan_score>=magic_plan_score then
        mode:='physical';
      elsif allow_magic then
        mode:='magic';
      end if;

      planned_buff_id:=null;
      planned_buff_percent:=0;
      planned_buff_turns:=0;
      planned_buff_gain:=0;

      if settings.use_learned_spells
         and support_enabled
         and support_buff_enabled
         and encounter.player_spell_damage_bonus_hits<=0
         and encounter.enemy_hp_max>0
         and encounter.enemy_hp_current*100>encounter.enemy_hp_max*35
      then
        select s.id,
               private.concentrated_spell_percent_value(encounter.character_id,s.id,s.support_value),
               greatest(1,s.support_turns)
        into planned_buff_id,planned_buff_percent,planned_buff_turns
        from public.character_spells cs
        join public.spell_definitions s on s.id=cs.spell_id
        where cs.character_id=encounter.character_id
          and private.character_spell_equipped(encounter.character_id,cs.spell_id)
          and s.enabled=true
          and s.spell_kind='buff'
          and stats.level>=s.required_level
          and stats.mana_current>=private.character_effective_spell_mana_cost(encounter.character_id,s.id)
          and stats.mana_current-private.character_effective_spell_mana_cost(encounter.character_id,s.id)>=reserve_mana
        order by (
          private.concentrated_spell_percent_value(encounter.character_id,s.id,s.support_value)
          *greatest(1,s.support_turns)
        )::numeric/greatest(1,private.character_effective_spell_mana_cost(encounter.character_id,s.id)) desc
        limit 1;

        if planned_buff_id is not null then
          planned_buff_turns:=least(3,planned_buff_turns);
          planned_buff_gain:=round(
            greatest(1,best_free_score)*least(100,planned_buff_percent)/100.0
            *(1.0
              +case when planned_buff_turns>=2 then 0.72 else 0 end
              +case when planned_buff_turns>=3 then 0.48 else 0 end)
          )::integer;
          planned_buff_threshold:=case coalesce(settings.strategy,'balanced')
            when 'aggressive' then 1.05
            when 'conservative' then 0.72
            else 0.85
          end;

          if planned_buff_gain<ceil(greatest(1,best_plan_score)*planned_buff_threshold)::integer
             or encounter.enemy_hp_current<=ceil(greatest(1,best_free_score)*(1.55+0.35*planned_buff_turns))::integer
          then
            planned_buff_id:=null;
          end if;
        end if;
      end if;

      chosen_spell_id:=null;
      chosen_spell_name:=null;
      if allow_spells then
        select s.id,s.name
        into chosen_spell_id,chosen_spell_name
        from public.character_spells cs
        join public.spell_definitions s on s.id=cs.spell_id
        left join public.character_autobattle_spell_rules rule
          on rule.character_id=cs.character_id and rule.spell_id=cs.spell_id
        where cs.character_id=encounter.character_id
          and private.character_spell_equipped(encounter.character_id,cs.spell_id)
          and s.enabled=true
          and s.spell_kind='damage'
          and s.damage_type is not null
          and stats.level>=s.required_level
          and stats.mana_current>=private.character_effective_spell_mana_cost(encounter.character_id,s.id)
          and stats.mana_current-private.character_effective_spell_mana_cost(encounter.character_id,s.id)>=reserve_mana
          and case
            when encounter.is_boss then coalesce(rule.boss_enabled,true)
            else coalesce(rule.normal_enabled,true)
          end
        order by
          private.autobattle_damage_spell_score(
            encounter.id,s.id,
            case
              when encounter.is_boss then coalesce(rule.boss_priority,100)
              else coalesce(rule.normal_priority,100)
            end
          ) desc,
          case
            when encounter.is_boss then coalesce(rule.boss_priority,100)
            else coalesce(rule.normal_priority,100)
          end asc,
          private.autobattle_estimated_damage(
            private.concentrated_spell_direct_value(
              encounter.character_id,s.id,
              greatest(
                1,
                private.damage_after_armor(
                  round(stats.magic_power*s.power_multiplier)::integer+s.flat_power,
                  encounter.enemy_defense*0.85
                )
              )
            ),
            private.damage_resistance_percent(
              encounter.enemy_resistances,s.damage_type
            ),
            stats.all_damage_bonus_percent+stats.magic_damage_bonus_percent
              +private.character_spell_family_damage_bonus_percent(encounter.character_id,s.id)
              +case
                when private.combat_encounter_is_strong(encounter.id)
                  then private.character_religion_modifier_number(encounter.character_id,'strong_enemy_damage_bonus')
                else 0
              end
              +case when encounter.is_boss then stats.boss_damage_bonus_percent else 0 end
          )
          *private.character_expected_critical_multiplier(encounter.character_id,'magic') desc,
          private.character_effective_spell_mana_cost(encounter.character_id,s.id) asc
        limit 1;
      end if;

      -- Three-action horizon: buffs are chosen by projected return, then damage
      -- spells must beat the best current + weapon-combo line.
      if planned_buff_id is not null then
        if bow_family in ('short_bow','long_bow') then
          update public.combat_encounters set player_bow_distance='far'
          where id=encounter.id and not player_bow_draw_pending;
          encounter.player_bow_distance:='far';
        end if;
        result:=private.perform_combat_action_internal(
          encounter.id,'support_spell',planned_buff_id,null
        );
      elsif chosen_spell_id is not null
         and best_free_score < encounter.enemy_hp_current
         and private.autobattle_damage_spell_score(
          encounter.id,chosen_spell_id,
          coalesce((select case when encounter.is_boss then rule.boss_priority else rule.normal_priority end
                    from public.character_autobattle_spell_rules rule
                    where rule.character_id=encounter.character_id and rule.spell_id=chosen_spell_id),100)
        ) >= ceil(best_plan_score*case coalesce(settings.strategy,'balanced')
          when 'aggressive' then 0.90
          when 'conservative' then 1.22
          else 1.08 end)::integer
      then
        if bow_family in ('short_bow','long_bow') then
          update public.combat_encounters set player_bow_distance='far'
          where id=encounter.id and not player_bow_draw_pending;
          encounter.player_bow_distance:='far';
        end if;
        result:=private.perform_combat_action_internal(
          encounter.id,'learned_spell',chosen_spell_id,null
        );
      elsif mode is not null then
        if mode='physical' and bow_family in ('short_bow','long_bow') then
          bow_decision:=coalesce(bow_decision,private.choose_bow_autobattle(encounter.id));
          bow_action:=coalesce(bow_decision->>'action','physical');
          bow_distance:=coalesce(bow_decision->>'distance',encounter.player_bow_distance);

          if not encounter.player_bow_draw_pending
             and bow_distance in ('close','medium','far')
             and bow_distance<>encounter.player_bow_distance
          then
            update public.combat_encounters
            set player_bow_distance=bow_distance
            where id=encounter.id;
          end if;

          result:=private.perform_combat_action_internal(
            encounter.id,bow_action,null,null
          );
        else
          if bow_family in ('short_bow','long_bow') then
            update public.combat_encounters set player_bow_distance='far'
            where id=encounter.id and not player_bow_draw_pending;
            encounter.player_bow_distance:='far';
          end if;
          result:=private.perform_combat_action_internal(
            encounter.id,mode,null,null
          );
        end if;
      else
        -- A player may intentionally build a pure tank tactic.
        if bow_family in ('short_bow','long_bow') then
          update public.combat_encounters set player_bow_distance='far'
          where id=encounter.id and not player_bow_draw_pending;
          encounter.player_bow_distance:='far';
        end if;
        result:=private.perform_combat_action_internal(
          encounter.id,'guard',null,null
        );
      end if;

      actions:=actions+1;
      end if;
    end if;

    if result.status<>'active' then
      return jsonb_build_object(
        'status',result.status,'reason',result.status,'actions',actions,
        'encounter_id',result.id,'player_hp',result.player_hp_current,
        'player_hp_max',result.player_hp_max,'player_mana',result.player_mana_current,
        'player_mana_max',result.player_mana_max
      );
    end if;

    if actions>=p_max_actions then
      insert into public.combat_turns(
        encounter_id,round,actor,action_type,damage,
        player_hp_after,enemy_hp_after,message
      )
      values(
        result.id,result.round,'system','autobattle_stop',0,
        result.player_hp_current,result.enemy_hp_current,
        'Автобой остановлен по лимиту ходов. Управление возвращено игроку.'
      );

      return jsonb_build_object(
        'status','stopped','reason','action_limit','actions',actions,
        'encounter_id',result.id,'player_hp',result.player_hp_current,
        'player_hp_max',result.player_hp_max,'player_mana',result.player_mana_current,
        'player_mana_max',result.player_mana_max
      );
    end if;
  end loop;

  return jsonb_build_object(
    'status',encounter.status,'reason',encounter.status,
    'actions',actions,'encounter_id',encounter.id
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_pvp_duel(p_duel_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid := auth.uid();
  caller_character_id uuid;
  result jsonb;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;

  select c.id into caller_character_id
  from public.pvp_duels d
  join public.characters c
    on c.id in (d.challenger_character_id,d.opponent_character_id)
   and c.owner_user_id=caller_id
  where d.id=p_duel_id
  limit 1;

  if caller_character_id is null then raise exception 'DUEL_NOT_FOUND'; end if;

  select jsonb_build_object(
    'duel', jsonb_build_object(
      'id',d.id,'status',d.status,
      'challenger_character_id',d.challenger_character_id,
      'opponent_character_id',d.opponent_character_id,
      'winner_character_id',d.winner_character_id,
      'current_turn_character_id',d.current_turn_character_id,
      'round',d.round,'finish_reason',d.finish_reason,
      'created_at',d.created_at,'started_at',d.started_at,
      'ended_at',d.ended_at,'turn_started_at',d.turn_started_at
    ),
    'participants', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'character_id',s.character_id,'side',s.side,
          'name',c.name,'race',c.race,'avatar_url',c.avatar_url,
          'display_name',p.display_name,
          'level',s.level,
          'hp_current',s.hp_current,'hp_max',s.hp_max,
          'mana_current',s.mana_current,'mana_max',s.mana_max,
          'physical_power',s.physical_power,'magic_power',s.magic_power,
          'defense',s.defense,
          'physical_defense',s.physical_defense,
          'magic_defense',s.magic_defense,
          'initiative',s.initiative,'initiative_meter',s.initiative_meter,
          'weapon_damage_type',s.weapon_damage_type,
          'magic_damage_type',s.magic_damage_type,
          'guard_reduction_percent',s.guard_reduction_percent,
          'counter_bonus_percent',0,
          'counter_blocked_damage',s.counter_blocked_damage,
          'counter_bonus_damage',greatest(0,round(s.counter_blocked_damage*0.50)::integer),
          'spell_damage_bonus_percent',s.spell_damage_bonus_percent,
          'spell_damage_bonus_hits',s.spell_damage_bonus_hits,
          'bow_distance',s.bow_distance,
          'bow_draw_pending',s.bow_draw_pending,
          'bloodshed_stacks',s.bloodshed_stacks
        )
        order by case s.side when 'challenger' then 0 else 1 end
      )
      from public.pvp_duel_states s
      join public.characters c on c.id=s.character_id
      join public.profiles p on p.user_id=c.owner_user_id
      where s.duel_id=d.id
    ),'[]'::jsonb),
    'turns', coalesce((
      select jsonb_agg(to_jsonb(tq) order by tq.id)
      from (
        select t.id,t.round,t.actor_character_id,t.action_type,t.damage,t.healing,t.message,t.created_at,
               c.name as actor_name
        from public.pvp_duel_turns t
        left join public.characters c on c.id=t.actor_character_id
        where t.duel_id=d.id
        order by t.id desc
        limit 50
      ) tq
    ),'[]'::jsonb),
    'statuses', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',s.id,'target_character_id',s.target_character_id,
        'effect_type',s.effect_type,'potency',s.potency,
        'remaining_turns',s.remaining_turns,'source_character_id',s.source_character_id
      ) order by s.created_at)
      from public.pvp_duel_status_effects s
      where s.duel_id=d.id
    ),'[]'::jsonb)
  ) into result
  from public.pvp_duels d
  where d.id=p_duel_id;

  return result;
end;
$function$
;

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
  counter_damage_used integer:=0;
  counter_damage_prepared integer:=0;
  target_guard_percent integer:=0;
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

      if actor.counter_blocked_damage>0 then
        counter_damage_used:=greatest(1,round(actor.counter_blocked_damage*0.50)::integer);
        actor.counter_blocked_damage:=0;
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
              target.magic_defense*0.85
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
        target_guard_percent:=target.guard_reduction_percent;
        blocked:=greatest(
          0,
          damage_value-greatest(1,ceil(damage_value*(100-target.guard_reduction_percent)/100.0)::integer)
        );
        damage_value:=greatest(1,damage_value-blocked);
        target.guard_reduction_percent:=0;

        if blocked>0 then
          counter_damage_prepared:=greatest(1,round(blocked*0.50)::integer);
          target.counter_blocked_damage:=greatest(target.counter_blocked_damage,blocked);
          target.counter_bonus_percent:=0;
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

      if p_action='physical' and counter_damage_used>0 and damage_value>0 and not target_dodged then
        if target_guard_percent>0 then
          counter_damage_used:=greatest(
            1,
            ceil(counter_damage_used*(100-target_guard_percent)/100.0)::integer
          );
        end if;
        damage_value:=damage_value+counter_damage_used;
        action_label:=action_label||' · контратака +'||counter_damage_used||' урона';
      elsif target_dodged then
        counter_damage_used:=0;
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
        ||case when counter_damage_prepared>0
          then ' Подготовлена контратака: +'||counter_damage_prepared||' урона из '||blocked||' заблокированных.'
          else '' end
        ||case when counter_damage_used>0
          then ' Контратака добавляет '||counter_damage_used||' урона.'
          else '' end
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
        counter_bonus_percent=0,
        counter_blocked_damage=actor.counter_blocked_damage,
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
        counter_bonus_percent=0,
        counter_blocked_damage=target.counter_blocked_damage,
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

