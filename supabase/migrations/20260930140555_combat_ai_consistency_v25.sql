-- Combat AI consistency v2.5.
-- Finalizes shared settings behavior, bow-distance dodge ownership and PvE
-- mana conservation when a free action already finishes the target.

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

  target_threat:=private.arena_estimate_immediate_threat(
    p_target_id,p_target_stats,p_target_state,p_actor_stats,p_actor_state
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
     and settings.use_learned_spells
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
     and settings.use_learned_spells
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

    if (family='long_bow' and target_threat<hp)
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
    elsif family='long_bow' and target_threat>=hp then
      -- Do not spend the last action preparing a shot that cannot be released.
      physical_score:=-1;
      free_score:=greatest(magic_score,1);
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
$function$

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
      if support_heal_hp>0 and hp_percent<=support_heal_hp then
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
        (encounter.player_counter_bonus_percent<=0 or not allow_physical)
        and guard_mode in ('low_hp','low_hp_or_interval')
        and hp_percent<=guard_hp
        and encounter.enemy_hp_current*100>greatest(1,encounter.enemy_hp_max)*8;
    end if;

    if not style_mode
       and (encounter.player_counter_bonus_percent<=0 or not allow_physical)
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
    elsif encounter.player_counter_bonus_percent>0 and allow_physical then
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
                    encounter.enemy_defense*0.65
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
                  encounter.enemy_defense*0.65
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

      -- Smart spell gate: configured priority influences close choices, but never forces obvious mana waste.
      if chosen_spell_id is not null
         and best_free_score < encounter.enemy_hp_current
         and private.autobattle_damage_spell_score(
          encounter.id,chosen_spell_id,
          coalesce((select case when encounter.is_boss then rule.boss_priority else rule.normal_priority end
                    from public.character_autobattle_spell_rules rule
                    where rule.character_id=encounter.character_id and rule.spell_id=chosen_spell_id),100)
        ) >= ceil(best_free_score*case coalesce(settings.strategy,'balanced')
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

revoke all on function private.arena_choose_action_v2(uuid,jsonb,jsonb,uuid,jsonb,jsonb)
  from public, anon, authenticated;
revoke all on function private.arena_execute_action_v2(uuid,jsonb,jsonb,uuid,jsonb,jsonb,jsonb)
  from public, anon, authenticated;
revoke all on function private.run_combat_autobattle_internal(uuid,integer)
  from public, anon, authenticated;
