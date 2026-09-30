-- Arena tactical AI v2.
-- Final consolidated v2 state: tactical support, status/control simulation,
-- bow logic, weapon-family mechanics and smarter resource decisions.

CREATE OR REPLACE FUNCTION private.arena_effect_severity(p_effects jsonb)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select coalesce(sum(
    case key
      when 'stun' then 4
      when 'vulnerable' then 3
      when 'weaken' then 2
      when 'chill' then 2
      when 'burn' then 1
      when 'bleed' then 1
      when 'poison' then 1
      else 1
    end
  ),0)::integer
  from jsonb_each(coalesce(p_effects,'{}'::jsonb))
  where coalesce((value->>'turns')::integer,0)>0
$function$

CREATE OR REPLACE FUNCTION private.arena_effect_reduction(p_effects jsonb)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select least(
    60,
    coalesce(sum(coalesce((value->>'potency')::integer,0))
      filter(where key in ('chill','weaken') and coalesce((value->>'turns')::integer,0)>0),0)
  )::integer
  from jsonb_each(coalesce(p_effects,'{}'::jsonb))
$function$

CREATE OR REPLACE FUNCTION private.arena_effect_vulnerable(p_effects jsonb)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select least(
    75,
    coalesce(sum(coalesce((value->>'potency')::integer,0))
      filter(where key='vulnerable' and coalesce((value->>'turns')::integer,0)>0),0)
  )::integer
  from jsonb_each(coalesce(p_effects,'{}'::jsonb))
$function$

CREATE OR REPLACE FUNCTION private.arena_has_effect(p_effects jsonb, p_effect_type text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select coalesce((coalesce(p_effects,'{}'::jsonb)->p_effect_type->>'turns')::integer,0)>0
$function$

CREATE OR REPLACE FUNCTION private.arena_apply_effect(p_effects jsonb, p_effect_type text, p_turns integer, p_potency integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
  effects jsonb:=coalesce(p_effects,'{}'::jsonb);
  old_turns integer:=coalesce((effects->p_effect_type->>'turns')::integer,0);
  old_potency integer:=coalesce((effects->p_effect_type->>'potency')::integer,0);
begin
  if p_effect_type is null or coalesce(p_turns,0)<=0 then return effects; end if;
  return jsonb_set(
    effects,
    array[p_effect_type],
    jsonb_build_object(
      'turns',greatest(old_turns,p_turns),
      'potency',greatest(old_potency,coalesce(p_potency,0))
    ),
    true
  );
end;
$function$

CREATE OR REPLACE FUNCTION private.arena_decay_effects(p_effects jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select coalesce(
    jsonb_object_agg(
      key,
      jsonb_build_object(
        'turns',greatest(0,(value->>'turns')::integer-1),
        'potency',coalesce((value->>'potency')::integer,0)
      )
    ) filter(where coalesce((value->>'turns')::integer,0)>1),
    '{}'::jsonb
  )
  from jsonb_each(coalesce(p_effects,'{}'::jsonb))
$function$

CREATE OR REPLACE FUNCTION private.arena_dot_damage(p_effects jsonb, p_target_resistances jsonb, p_source_character_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  e record;
  total integer:=0;
begin
  for e in
    select key effect_type,
           coalesce((value->>'potency')::integer,0) potency,
           coalesce((value->>'turns')::integer,0) turns
    from jsonb_each(coalesce(p_effects,'{}'::jsonb))
    where key in ('burn','bleed','poison')
      and coalesce((value->>'turns')::integer,0)>0
  loop
    total:=total+private.status_tick_damage_with_crit(
      e.effect_type,e.potency,coalesce(p_target_resistances,'{}'::jsonb),
      p_source_character_id,false
    );
  end loop;
  return greatest(0,total);
end;
$function$

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
    +buff
    +coalesce((p_actor_state->>'counter_bonus')::integer,0);

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

CREATE OR REPLACE FUNCTION private.arena_estimate_magic_damage(p_actor_id uuid, p_actor_stats jsonb, p_actor_state jsonb, p_target_stats jsonb, p_target_state jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  magic_type text:=coalesce(p_actor_stats->>'magic_damage_type','fire');
  actor_power integer:=greatest(1,coalesce((p_actor_stats->>'magic_power')::integer,1));
  target_def integer:=greatest(0,coalesce((p_target_stats->>'magic_defense')::integer,0));
  target_hp integer:=greatest(0,coalesce((p_target_state->>'hp')::integer,0));
  target_hp_max integer:=greatest(1,coalesce((p_target_state->>'hp_max')::integer,1));
  raw integer:=0;
  resistance integer:=0;
  bonus integer:=0;
  reduction integer:=private.arena_effect_reduction(p_actor_state->'effects');
  vulnerable integer:=private.arena_effect_vulnerable(p_target_state->'effects');
  buff integer:=case when coalesce((p_actor_state->>'buff_hits')::integer,0)>0 then coalesce((p_actor_state->>'buff_percent')::integer,0) else 0 end;
begin
  raw:=greatest(1,private.damage_after_armor(actor_power,target_def));
  bonus:=coalesce((p_actor_stats->>'all_damage_bonus_percent')::integer,0)
    +coalesce((p_actor_stats->>'magic_damage_bonus_percent')::integer,0)
    +private.character_damage_bonus(p_actor_id,magic_type)
    +buff;
  raw:=greatest(1,round(raw*(100+bonus)/100.0)::integer);
  raw:=greatest(1,round(raw*(100-reduction)/100.0)::integer);
  raw:=greatest(1,round(raw*(100+vulnerable)/100.0)::integer);
  resistance:=private.damage_resistance_percent(
    coalesce(p_target_stats->'damage_resistances','{}'::jsonb),magic_type
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

  return greatest(1,raw);
end;
$function$

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

  if settings.normal_support_enabled and settings.normal_allow_spells
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
      return jsonb_build_object(
        'action','bow_draw','label','Полный натяг','value',0,'mana_cost',0,
        'distance',chosen_distance,'planned_damage',full_damage
      );
    end if;
  end if;

  if settings.normal_allow_spells then
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

  if magic_score>physical_score and settings.normal_allow_magic then
    best_action:='magic';
    return jsonb_build_object(
      'action','magic','label','Врождённая магия','value',magic_damage,
      'mana_cost',0,'crit_kind','magic'
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
    target_dodge:=case when family is not null and action_type='physical'
      then private.bow_dodge_chance(coalesce(target_state->>'bow_distance','medium')) else 0 end;

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

CREATE OR REPLACE FUNCTION private.arena_simulate_solo(p_challenger_id uuid, p_opponent_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  a record;
  b record;
  a_json jsonb;
  b_json jsonb;
  a_state jsonb;
  b_state jsonb;
  a_name text;
  b_name text;
  a_magic_defense integer;
  b_magic_defense integer;
  a_time numeric;
  b_time numeric;
  action jsonb;
  executed jsonb;
  turn_start_damage integer:=0;
  bloodshed_damage integer:=0;
  total_actions integer:=0;
  log_data jsonb:='[]'::jsonb;
  winner uuid:=null;
  a_ratio numeric;
  b_ratio numeric;
  stunned boolean:=false;
begin
  select * into a from private.get_character_combat_stats(p_challenger_id);
  select * into b from private.get_character_combat_stats(p_opponent_id);
  if a.level is null or b.level is null then raise exception 'ARENA_COMBAT_STATS_NOT_FOUND'; end if;

  select name into a_name from public.characters where id=p_challenger_id;
  select name into b_name from public.characters where id=p_opponent_id;

  a_magic_defense:=greatest(0,round(
    private.character_magic_defense(a.level,a.vitality,a.intellect)
    *(100+private.character_defense_percent(p_challenger_id)
      +private.character_religion_modifier_number(p_challenger_id,'magic_defense_percent'))/100.0
  )::integer);
  b_magic_defense:=greatest(0,round(
    private.character_magic_defense(b.level,b.vitality,b.intellect)
    *(100+private.character_defense_percent(p_opponent_id)
      +private.character_religion_modifier_number(p_opponent_id,'magic_defense_percent'))/100.0
  )::integer);

  a_json:=to_jsonb(a)||jsonb_build_object('magic_defense',a_magic_defense);
  b_json:=to_jsonb(b)||jsonb_build_object('magic_defense',b_magic_defense);

  a_state:=jsonb_build_object(
    'hp',greatest(1,a.hp_max),'hp_max',greatest(1,a.hp_max),
    'mana',greatest(0,a.mana_max),'mana_max',greatest(0,a.mana_max),
    'actions',0,'guard',0,'reflect',0,'counter_bonus',0,'guard_streak',0,
    'buff_percent',0,'buff_hits',0,
    'bow_distance','medium','bow_draw_pending',false,
    'effects','{}'::jsonb,'bloodshed_stacks',0,
    'katana_stacks',0,'greatsword_stacks',0,'white_fang_wounds',0
  );
  b_state:=jsonb_build_object(
    'hp',greatest(1,b.hp_max),'hp_max',greatest(1,b.hp_max),
    'mana',greatest(0,b.mana_max),'mana_max',greatest(0,b.mana_max),
    'actions',0,'guard',0,'reflect',0,'counter_bonus',0,'guard_streak',0,
    'buff_percent',0,'buff_hits',0,
    'bow_distance','medium','bow_draw_pending',false,
    'effects','{}'::jsonb,'bloodshed_stacks',0,
    'katana_stacks',0,'greatsword_stacks',0,'white_fang_wounds',0
  );

  a_time:=1000.0/greatest(1,a.initiative)*(0.97+random()*0.06);
  b_time:=1000.0/greatest(1,b.initiative)*(0.97+random()*0.06);

  while coalesce((a_state->>'hp')::integer,0)>0
    and coalesce((b_state->>'hp')::integer,0)>0
    and total_actions<100
  loop
    total_actions:=total_actions+1;

    if a_time<=b_time then
      turn_start_damage:=private.arena_dot_damage(
        a_state->'effects',a_json->'damage_resistances',p_opponent_id
      );
      bloodshed_damage:=case when coalesce((a_state->>'bloodshed_stacks')::integer,0)>0
        then private.bloodshed_damage(
          greatest(1,(a_state->>'hp')::integer),
          (a_state->>'bloodshed_stacks')::integer
        ) else 0 end;
      turn_start_damage:=turn_start_damage+bloodshed_damage;
      if turn_start_damage>0 then
        a_state:=jsonb_set(
          a_state,'{hp}',
          to_jsonb(greatest(0,(a_state->>'hp')::integer-turn_start_damage)),true
        );
      end if;
      a_state:=jsonb_set(a_state,'{bloodshed_stacks}','0'::jsonb,true);

      if (a_state->>'hp')::integer<=0 then
        log_data:=log_data||jsonb_build_array(jsonb_build_object(
          'turn',total_actions,'actor_id',p_challenger_id,'actor_name',a_name,
          'action','status_tick','label','Негативные эффекты',
          'damage',turn_start_damage,'healing',0,
          'actor_hp',0,'actor_mana',(a_state->>'mana')::integer,
          'target_hp',(b_state->>'hp')::integer
        ));
        exit;
      end if;

      stunned:=private.arena_has_effect(a_state->'effects','stun');
      if stunned then
        a_state:=jsonb_set(
          a_state,'{actions}',to_jsonb((a_state->>'actions')::integer+1),true
        );
        a_state:=jsonb_set(
          a_state,'{effects}',private.arena_decay_effects(a_state->'effects'),true
        );
        a_time:=a_time+1000.0/greatest(1,a.initiative);
        log_data:=log_data||jsonb_build_array(jsonb_build_object(
          'turn',total_actions,'actor_id',p_challenger_id,'actor_name',a_name,
          'action','stunned','label','Оглушение',
          'damage',turn_start_damage,'healing',0,
          'actor_hp',(a_state->>'hp')::integer,'actor_mana',(a_state->>'mana')::integer,
          'target_hp',(b_state->>'hp')::integer
        ));
        continue;
      end if;

      action:=private.arena_choose_action_v2(
        p_challenger_id,a_json,a_state,p_opponent_id,b_json,b_state
      );
      executed:=private.arena_execute_action_v2(
        p_challenger_id,a_json,a_state,p_opponent_id,b_json,b_state,action
      );
      a_state:=executed->'actor_state';
      b_state:=executed->'target_state';
      a_state:=jsonb_set(
        a_state,'{effects}',private.arena_decay_effects(a_state->'effects'),true
      );
      a_time:=a_time+1000.0/greatest(1,a.initiative);

      log_data:=log_data||jsonb_build_array(jsonb_build_object(
        'turn',total_actions,'actor_id',p_challenger_id,'actor_name',a_name,
        'action',action->>'action','label',coalesce(action->>'label',action->>'action'),
        'damage',coalesce((executed->>'damage')::integer,0)+turn_start_damage,
        'healing',coalesce((executed->>'healing')::integer,0),
        'actor_hp',(a_state->>'hp')::integer,'actor_mana',(a_state->>'mana')::integer,
        'target_hp',(b_state->>'hp')::integer
      ));
    else
      turn_start_damage:=private.arena_dot_damage(
        b_state->'effects',b_json->'damage_resistances',p_challenger_id
      );
      bloodshed_damage:=case when coalesce((b_state->>'bloodshed_stacks')::integer,0)>0
        then private.bloodshed_damage(
          greatest(1,(b_state->>'hp')::integer),
          (b_state->>'bloodshed_stacks')::integer
        ) else 0 end;
      turn_start_damage:=turn_start_damage+bloodshed_damage;
      if turn_start_damage>0 then
        b_state:=jsonb_set(
          b_state,'{hp}',
          to_jsonb(greatest(0,(b_state->>'hp')::integer-turn_start_damage)),true
        );
      end if;
      b_state:=jsonb_set(b_state,'{bloodshed_stacks}','0'::jsonb,true);

      if (b_state->>'hp')::integer<=0 then
        log_data:=log_data||jsonb_build_array(jsonb_build_object(
          'turn',total_actions,'actor_id',p_opponent_id,'actor_name',b_name,
          'action','status_tick','label','Негативные эффекты',
          'damage',turn_start_damage,'healing',0,
          'actor_hp',0,'actor_mana',(b_state->>'mana')::integer,
          'target_hp',(a_state->>'hp')::integer
        ));
        exit;
      end if;

      stunned:=private.arena_has_effect(b_state->'effects','stun');
      if stunned then
        b_state:=jsonb_set(
          b_state,'{actions}',to_jsonb((b_state->>'actions')::integer+1),true
        );
        b_state:=jsonb_set(
          b_state,'{effects}',private.arena_decay_effects(b_state->'effects'),true
        );
        b_time:=b_time+1000.0/greatest(1,b.initiative);
        log_data:=log_data||jsonb_build_array(jsonb_build_object(
          'turn',total_actions,'actor_id',p_opponent_id,'actor_name',b_name,
          'action','stunned','label','Оглушение',
          'damage',turn_start_damage,'healing',0,
          'actor_hp',(b_state->>'hp')::integer,'actor_mana',(b_state->>'mana')::integer,
          'target_hp',(a_state->>'hp')::integer
        ));
        continue;
      end if;

      action:=private.arena_choose_action_v2(
        p_opponent_id,b_json,b_state,p_challenger_id,a_json,a_state
      );
      executed:=private.arena_execute_action_v2(
        p_opponent_id,b_json,b_state,p_challenger_id,a_json,a_state,action
      );
      b_state:=executed->'actor_state';
      a_state:=executed->'target_state';
      b_state:=jsonb_set(
        b_state,'{effects}',private.arena_decay_effects(b_state->'effects'),true
      );
      b_time:=b_time+1000.0/greatest(1,b.initiative);

      log_data:=log_data||jsonb_build_array(jsonb_build_object(
        'turn',total_actions,'actor_id',p_opponent_id,'actor_name',b_name,
        'action',action->>'action','label',coalesce(action->>'label',action->>'action'),
        'damage',coalesce((executed->>'damage')::integer,0)+turn_start_damage,
        'healing',coalesce((executed->>'healing')::integer,0),
        'actor_hp',(b_state->>'hp')::integer,'actor_mana',(b_state->>'mana')::integer,
        'target_hp',(a_state->>'hp')::integer
      ));
    end if;
  end loop;

  if (a_state->>'hp')::integer<=0 and (b_state->>'hp')::integer>0 then winner:=p_opponent_id;
  elsif (b_state->>'hp')::integer<=0 and (a_state->>'hp')::integer>0 then winner:=p_challenger_id;
  elsif (a_state->>'hp')::integer<=0 and (b_state->>'hp')::integer<=0 then winner:=null;
  else
    a_ratio:=(a_state->>'hp')::numeric/greatest(1,(a_state->>'hp_max')::integer);
    b_ratio:=(b_state->>'hp')::numeric/greatest(1,(b_state->>'hp_max')::integer);
    if a_ratio>b_ratio+0.01 then winner:=p_challenger_id;
    elsif b_ratio>a_ratio+0.01 then winner:=p_opponent_id;
    else winner:=null;
    end if;
  end if;

  return jsonb_build_object(
    'winner_character_id',winner,'rounds',total_actions,
    'challenger_final_hp',greatest(0,(a_state->>'hp')::integer),
    'challenger_hp_max',(a_state->>'hp_max')::integer,
    'opponent_final_hp',greatest(0,(b_state->>'hp')::integer),
    'opponent_hp_max',(b_state->>'hp_max')::integer,
    'log',log_data
  );
end;
$function$

revoke all on function private.arena_effect_severity(jsonb) from public, anon, authenticated;
revoke all on function private.arena_effect_reduction(jsonb) from public, anon, authenticated;
revoke all on function private.arena_effect_vulnerable(jsonb) from public, anon, authenticated;
revoke all on function private.arena_has_effect(jsonb,text) from public, anon, authenticated;
revoke all on function private.arena_apply_effect(jsonb,text,integer,integer) from public, anon, authenticated;
revoke all on function private.arena_decay_effects(jsonb) from public, anon, authenticated;
revoke all on function private.arena_dot_damage(jsonb,jsonb,uuid) from public, anon, authenticated;
revoke all on function private.arena_estimate_physical_damage(uuid,jsonb,jsonb,jsonb,jsonb,boolean) from public, anon, authenticated;
revoke all on function private.arena_estimate_magic_damage(uuid,jsonb,jsonb,jsonb,jsonb) from public, anon, authenticated;
revoke all on function private.arena_choose_action_v2(uuid,jsonb,jsonb,uuid,jsonb,jsonb) from public, anon, authenticated;
revoke all on function private.arena_execute_action_v2(uuid,jsonb,jsonb,uuid,jsonb,jsonb,jsonb) from public, anon, authenticated;
revoke all on function private.arena_simulate_solo(uuid,uuid) from public, anon, authenticated;
