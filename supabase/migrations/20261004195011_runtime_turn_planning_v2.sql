alter table private.client_runtime_sessions
  add column if not exists next_retry_at timestamptz not null default now();

create or replace function private.resolve_runtime_duel_turn_v2(
  p_character_id uuid,
  p_duel_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  base_choice jsonb;
  a public.pvp_duel_states%rowtype;
  t public.pvp_duel_states%rowtype;
  physical_score integer:=1;
  magic_score integer:=1;
  free_score integer:=1;
  resistance integer:=0;
  target_physical integer:=1;
  target_magic integer:=1;
  target_threat integer:=1;
  actor_gain integer:=0;
  target_gain integer:=0;
  actor_extra boolean:=false;
  target_extra boolean:=false;
  incoming_actions integer:=1;
  incoming_burst integer:=1;
  protection integer:=0;
  incoming_after_protection integer:=1;
  missing_hp integer:=0;
  lifesteal_heal integer:=0;
  heal_spell record;
  heal_value integer:=0;
  heal_cost integer:=0;
  guard_spell record;
  shield_percent integer:=0;
  shield_value integer:=0;
  opponent_heal record;
  opponent_heal_value integer:=0;
  opponent_can_heal boolean:=false;
  vuln_spell record;
  vuln_direct integer:=0;
  vuln_expected_bonus integer:=0;
  vuln_sequence integer:=0;
  plain_sequence integer:=0;
  target_vuln integer:=0;
  self_reduction integer:=0;
  hp_percent integer:=100;
  mana_reserve integer:=0;
  settings public.character_autobattle_settings;
begin
  base_choice:=private.resolve_client_duel_turn(p_character_id,p_duel_id);

  select * into a
  from public.pvp_duel_states
  where duel_id=p_duel_id and character_id=p_character_id;

  select * into t
  from public.pvp_duel_states
  where duel_id=p_duel_id and character_id<>p_character_id
  limit 1;

  if a.character_id is null or t.character_id is null then
    return base_choice;
  end if;

  if a.bow_draw_pending then
    return base_choice;
  end if;

  settings:=private.ensure_character_autobattle_settings(p_character_id);
  mana_reserve:=floor(a.mana_max*greatest(0,coalesce(settings.mana_reserve_percent,20))/100.0)::integer;
  hp_percent:=floor(a.hp_current*100.0/greatest(1,a.hp_max))::integer;

  physical_score:=greatest(1,private.damage_after_armor(a.physical_power,greatest(0,t.physical_defense)));
  resistance:=private.damage_resistance_percent(t.damage_resistances,a.weapon_damage_type);
  physical_score:=greatest(1,round(
    physical_score
    *(100+a.all_damage_bonus_percent+a.physical_damage_bonus_percent
      +private.character_damage_bonus(p_character_id,a.weapon_damage_type))/100.0
    *(100-resistance)/100.0
    *private.character_expected_critical_multiplier(p_character_id,'physical')
  )::integer);

  if t.hp_current*100<=greatest(1,t.hp_max)*30 then
    physical_score:=greatest(1,round(
      physical_score*(100+a.damage_vs_wounded_percent)/100.0
      *(100-t.low_hp_damage_reduction_percent)/100.0
    )::integer);
  end if;

  magic_score:=greatest(1,private.damage_after_armor(a.magic_power,greatest(0,t.magic_defense)));
  resistance:=private.damage_resistance_percent(t.damage_resistances,a.magic_damage_type);
  magic_score:=greatest(1,round(
    magic_score
    *(100+a.all_damage_bonus_percent+a.magic_damage_bonus_percent
      +private.character_damage_bonus(p_character_id,a.magic_damage_type))/100.0
    *(100-resistance)/100.0
    *private.character_expected_critical_multiplier(p_character_id,'magic')
  )::integer);

  select least(60,coalesce(sum(potency),0))::integer
  into self_reduction
  from public.pvp_duel_status_effects
  where duel_id=p_duel_id
    and target_character_id=p_character_id
    and remaining_turns>0
    and effect_type in ('chill','weaken');

  if self_reduction>0 then
    physical_score:=greatest(1,round(physical_score*(100-self_reduction)/100.0)::integer);
    magic_score:=greatest(1,round(magic_score*(100-self_reduction)/100.0)::integer);
  end if;

  select least(75,coalesce(sum(potency),0))::integer
  into target_vuln
  from public.pvp_duel_status_effects
  where duel_id=p_duel_id
    and target_character_id=t.character_id
    and remaining_turns>0
    and effect_type='vulnerable';

  if target_vuln>0 then
    physical_score:=greatest(1,round(physical_score*(100+target_vuln)/100.0)::integer);
    magic_score:=greatest(1,round(magic_score*(100+target_vuln)/100.0)::integer);
  end if;

  free_score:=greatest(physical_score,magic_score);

  target_physical:=greatest(1,private.damage_after_armor(t.physical_power,greatest(0,a.physical_defense)));
  resistance:=private.damage_resistance_percent(a.damage_resistances,t.weapon_damage_type);
  target_physical:=greatest(1,round(
    target_physical
    *(100+t.all_damage_bonus_percent+t.physical_damage_bonus_percent)/100.0
    *(100-resistance)/100.0
  )::integer);

  target_magic:=greatest(1,private.damage_after_armor(t.magic_power,greatest(0,a.magic_defense)));
  resistance:=private.damage_resistance_percent(a.damage_resistances,t.magic_damage_type);
  target_magic:=greatest(1,round(
    target_magic
    *(100+t.all_damage_bonus_percent+t.magic_damage_bonus_percent)/100.0
    *(100-resistance)/100.0
  )::integer);

  target_threat:=greatest(target_physical,target_magic);

  actor_gain:=private.initiative_tempo_gain(a.initiative,t.initiative);
  target_gain:=private.initiative_tempo_gain(t.initiative,a.initiative);
  actor_extra:=coalesce(a.initiative_meter,0)+actor_gain>=100;
  target_extra:=coalesce(t.initiative_meter,0)+target_gain>=100;
  incoming_actions:=1+case when target_extra then 1 else 0 end;
  incoming_burst:=target_threat*incoming_actions;

  protection:=greatest(
    coalesce(a.guard_spell_percent,0),
    coalesce(a.reflect_percent,0),
    case when coalesce(a.guard_stance_active,false) then coalesce(a.guard_reduction_percent,0) else 0 end
  );
  incoming_after_protection:=greatest(
    1,
    round(target_threat*(100-least(90,protection))/100.0)::integer
      +target_threat*(incoming_actions-1)
  );

  missing_hp:=greatest(0,a.hp_max-a.hp_current);
  lifesteal_heal:=least(
    missing_hp,
    greatest(0,round(physical_score*greatest(0,a.lifesteal_percent)/100.0)::integer)
  );

  select sd.id,sd.name,
         private.character_effective_spell_mana_cost(p_character_id,sd.id) effective_cost,
         least(
           missing_hp,
           greatest(1,round(
             private.concentrated_spell_direct_value(
               p_character_id,
               sd.id,
               round(private.character_pvp_healing_power(p_character_id)*sd.power_multiplier)::integer+sd.flat_power
             )
             *(100+private.character_religion_modifier_number(p_character_id,'healing_spell_bonus'))/100.0
           )::integer)
         ) expected_heal
  into heal_spell
  from public.character_combat_spells ccs
  join public.spell_definitions sd on sd.id=ccs.spell_id
  where ccs.character_id=p_character_id
    and sd.enabled
    and sd.spell_kind='heal'
    and private.character_effective_spell_mana_cost(p_character_id,sd.id)<=a.mana_current
  order by expected_heal desc,effective_cost
  limit 1;

  if heal_spell.id is not null then
    heal_value:=coalesce(heal_spell.expected_heal,0);
    heal_cost:=coalesce(heal_spell.effective_cost,0);
  end if;

  select sd.id,sd.name,sd.slug,
         private.character_effective_spell_mana_cost(p_character_id,sd.id) effective_cost,
         case
           when sd.slug='mirror_barrier' then least(90,greatest(0,sd.support_value))
           else least(85,greatest(55,round(
             private.concentrated_spell_percent_value(p_character_id,sd.id,sd.support_value)
             *(100+private.character_religion_modifier_number(p_character_id,'shield_spell_bonus'))/100.0
           )::integer))
         end shield_pct
  into guard_spell
  from public.character_combat_spells ccs
  join public.spell_definitions sd on sd.id=ccs.spell_id
  where ccs.character_id=p_character_id
    and sd.enabled
    and sd.spell_kind='guard'
    and private.character_effective_spell_mana_cost(p_character_id,sd.id)<=a.mana_current
  order by shield_pct desc,effective_cost
  limit 1;

  if guard_spell.id is not null then
    shield_percent:=coalesce(guard_spell.shield_pct,0);
    shield_value:=greatest(0,round(target_threat*shield_percent/100.0)::integer);
  end if;

  select sd.id,sd.name,
         private.character_effective_spell_mana_cost(t.character_id,sd.id) effective_cost,
         greatest(1,round(
           private.concentrated_spell_direct_value(
             t.character_id,
             sd.id,
             round(private.character_pvp_healing_power(t.character_id)*sd.power_multiplier)::integer+sd.flat_power
           )
           *(100+private.character_religion_modifier_number(t.character_id,'healing_spell_bonus'))/100.0
         )::integer) expected_heal
  into opponent_heal
  from public.character_combat_spells ccs
  join public.spell_definitions sd on sd.id=ccs.spell_id
  where ccs.character_id=t.character_id
    and sd.enabled
    and sd.spell_kind='heal'
    and private.character_effective_spell_mana_cost(t.character_id,sd.id)<=t.mana_current
  order by expected_heal desc,effective_cost
  limit 1;

  if opponent_heal.id is not null then
    opponent_heal_value:=least(greatest(0,t.hp_max-t.hp_current),coalesce(opponent_heal.expected_heal,0));
    opponent_can_heal:=opponent_heal_value>0 and t.hp_current*100<=t.hp_max*68;
  end if;

  if t.hp_current<=physical_score and physical_score>=magic_score then
    return jsonb_build_object('action','physical','label','Физическая атака','reason','v2_lethal');
  elsif t.hp_current<=magic_score then
    return jsonb_build_object('action','magic','label','Врождённая магия','reason','v2_lethal');
  end if;

  if actor_extra and base_choice->>'action'='guard' then
    if guard_spell.id is not null
       and a.mana_current-guard_spell.effective_cost>=greatest(0,mana_reserve-5)
       and incoming_burst>=a.hp_current
    then
      return jsonb_build_object(
        'action','spell','spell_id',guard_spell.id,
        'label',guard_spell.name,'reason','v2_extra_action_persistent_shield'
      );
    end if;

    if physical_score>=magic_score then
      return jsonb_build_object('action','physical','label','Физическая атака','reason','v2_guard_would_expire');
    end if;
    return jsonb_build_object('action','magic','label','Врождённая магия','reason','v2_guard_would_expire');
  end if;

  if base_choice->>'action'='spell'
     and nullif(base_choice->>'spell_id','') is not null
     and heal_spell.id is not null
     and nullif(base_choice->>'spell_id','')::uuid=heal_spell.id
     and lifesteal_heal>0
     and a.hp_current+lifesteal_heal>incoming_after_protection
     and physical_score>=ceil(heal_value*0.95)::integer
  then
    return jsonb_build_object('action','physical','label','Физическая атака','reason','v2_lifesteal_tempo');
  end if;

  if t.hp_current>free_score
     and protection<=0
     and incoming_burst>=a.hp_current
  then
    if guard_spell.id is not null
       and shield_value>=heal_value
       and a.mana_current-guard_spell.effective_cost>=greatest(0,mana_reserve-5)
    then
      return jsonb_build_object(
        'action','spell','spell_id',guard_spell.id,
        'label',guard_spell.name,'reason','v2_survival_shield'
      );
    elsif heal_spell.id is not null
       and heal_value>0
       and (a.mana_current-heal_cost>=greatest(0,mana_reserve-5) or incoming_burst>=a.hp_current)
    then
      return jsonb_build_object(
        'action','spell','spell_id',heal_spell.id,
        'label',heal_spell.name,'reason','v2_survival_heal'
      );
    end if;
  end if;

  if actor_extra
     and opponent_can_heal
     and t.hp_current<=physical_score*2
     and physical_score>=magic_score
  then
    return jsonb_build_object('action','physical','label','Физическая атака','reason','v2_burst_before_heal');
  end if;

  select sd.id,sd.name,sd.damage_type,sd.power_multiplier,sd.flat_power,
         sd.status_effect_chance,sd.status_effect_potency,
         private.character_effective_spell_mana_cost(p_character_id,sd.id) effective_cost
  into vuln_spell
  from public.character_combat_spells ccs
  join public.spell_definitions sd on sd.id=ccs.spell_id
  where ccs.character_id=p_character_id
    and sd.enabled
    and sd.spell_kind='damage'
    and sd.status_effect_type='vulnerable'
    and private.character_effective_spell_mana_cost(p_character_id,sd.id)<=a.mana_current
  order by sd.status_effect_potency desc,sd.status_effect_chance desc,effective_cost
  limit 1;

  if vuln_spell.id is not null and target_vuln<=0 then
    vuln_direct:=greatest(1,private.damage_after_armor(
      private.concentrated_spell_direct_value(
        p_character_id,
        vuln_spell.id,
        round(a.magic_power*vuln_spell.power_multiplier)::integer+vuln_spell.flat_power
      ),
      greatest(0,t.magic_defense)*0.85
    ));
    resistance:=private.damage_resistance_percent(t.damage_resistances,vuln_spell.damage_type);
    vuln_direct:=greatest(1,round(
      vuln_direct
      *(100+a.all_damage_bonus_percent+a.magic_damage_bonus_percent
        +private.character_damage_bonus(p_character_id,vuln_spell.damage_type)
        +private.character_spell_family_damage_bonus_percent(p_character_id,vuln_spell.id))/100.0
      *(100-resistance)/100.0
      *private.character_expected_critical_multiplier(p_character_id,'magic')
    )::integer);

    vuln_expected_bonus:=round(
      physical_score
      *vuln_spell.status_effect_potency/100.0
      *vuln_spell.status_effect_chance/100.0
    )::integer;

    plain_sequence:=physical_score*2;
    vuln_sequence:=vuln_direct+physical_score+vuln_expected_bonus;

    if actor_extra
       and a.mana_current-vuln_spell.effective_cost>=mana_reserve
       and vuln_sequence>=ceil(plain_sequence*1.06)::integer
    then
      return jsonb_build_object(
        'action','spell','spell_id',vuln_spell.id,
        'label',vuln_spell.name,'reason','v2_setup_into_extra_action'
      );
    end if;
  end if;

  if protection>0
     and incoming_after_protection<a.hp_current
     and base_choice->>'action' in ('guard','spell')
     and physical_score>=magic_score
     and (hp_percent>=42 or lifesteal_heal>0)
  then
    if not (
      base_choice->>'action'='spell'
      and heal_spell.id is not null
      and nullif(base_choice->>'spell_id','')::uuid=heal_spell.id
      and a.hp_current<=incoming_after_protection+10
    ) then
      return jsonb_build_object('action','physical','label','Физическая атака','reason','v2_existing_protection');
    end if;
  end if;

  if (select round from public.pvp_duels where id=p_duel_id)>=24
     and base_choice->>'action' in ('guard','spell')
     and a.hp_current>incoming_burst
     and physical_score>=magic_score
  then
    if base_choice->>'action'='guard'
       or (heal_spell.id is not null and nullif(base_choice->>'spell_id','')::uuid=heal_spell.id and hp_percent>48)
    then
      return jsonb_build_object('action','physical','label','Физическая атака','reason','v2_anti_stall');
    end if;
  end if;

  return base_choice;
end;
$$;

create or replace function private.resolve_runtime_party_turn_v2(
  p_character_id uuid,
  p_encounter_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  base_choice jsonb;
  ce public.party_combat_encounters%rowtype;
  ms public.party_combat_member_states%rowtype;
  st record;
  physical_score integer:=1;
  magic_score integer:=1;
  resistance integer:=0;
  tempo_gain integer:=0;
  immediate_extra boolean:=false;
  guard_spell record;
  settings public.character_autobattle_settings;
  reserve integer:=0;
begin
  base_choice:=private.resolve_client_party_turn(p_character_id,p_encounter_id);

  select * into ce from public.party_combat_encounters where id=p_encounter_id;
  select * into ms from public.party_combat_member_states
  where encounter_id=p_encounter_id and character_id=p_character_id;
  select * into st from private.get_character_combat_stats(p_character_id);

  if ce.id is null or ms.character_id is null then
    return base_choice;
  end if;

  if base_choice->>'action'='skip' or ms.bow_draw_pending then
    return base_choice;
  end if;

  settings:=private.ensure_character_autobattle_settings(p_character_id);
  reserve:=floor(ms.mana_max*greatest(0,coalesce(settings.mana_reserve_percent,20))/100.0)::integer;

  physical_score:=greatest(1,private.damage_after_armor(st.physical_power,ce.enemy_defense));
  resistance:=private.damage_resistance_percent(ce.enemy_resistances,st.weapon_damage_type);
  physical_score:=greatest(1,round(
    physical_score
    *(100+st.all_damage_bonus_percent+st.physical_damage_bonus_percent
      +private.character_damage_bonus(p_character_id,st.weapon_damage_type))/100.0
    *(100-resistance)/100.0
    *private.character_expected_critical_multiplier(p_character_id,'physical')
  )::integer);

  magic_score:=greatest(1,private.damage_after_armor(st.magic_power,ce.enemy_defense*0.85));
  resistance:=private.damage_resistance_percent(ce.enemy_resistances,st.magic_damage_type);
  magic_score:=greatest(1,round(
    magic_score
    *(100+st.all_damage_bonus_percent+st.magic_damage_bonus_percent
      +private.character_damage_bonus(p_character_id,st.magic_damage_type))/100.0
    *(100-resistance)/100.0
    *private.character_expected_critical_multiplier(p_character_id,'magic')
  )::integer);

  if ce.enemy_hp_current<=physical_score and physical_score>=magic_score then
    return jsonb_build_object('action','physical','label','Физическая атака','reason','v2_lethal');
  elsif ce.enemy_hp_current<=magic_score then
    return jsonb_build_object('action','magic','label','Врождённая магия','reason','v2_lethal');
  end if;

  tempo_gain:=private.initiative_tempo_gain(st.initiative,ce.enemy_initiative);
  immediate_extra:=coalesce(ms.initiative_meter,0)+tempo_gain>=100;

  if immediate_extra and base_choice->>'action'='guard' then
    select sd.id,sd.name,
           private.character_effective_spell_mana_cost(p_character_id,sd.id) effective_cost,
           case when sd.slug='mirror_barrier'
             then least(90,greatest(0,sd.support_value))
             else least(85,greatest(55,round(
               private.concentrated_spell_percent_value(p_character_id,sd.id,sd.support_value)
               *(100+private.character_religion_modifier_number(p_character_id,'shield_spell_bonus'))/100.0
             )::integer))
           end shield_pct
    into guard_spell
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=p_character_id
      and sd.enabled
      and sd.spell_kind='guard'
      and private.character_effective_spell_mana_cost(p_character_id,sd.id)<=ms.mana_current
    order by shield_pct desc,effective_cost
    limit 1;

    if guard_spell.id is not null
       and ms.mana_current-guard_spell.effective_cost>=greatest(0,reserve-5)
    then
      return jsonb_build_object(
        'action','spell','spell_id',guard_spell.id,'target_id',p_character_id,
        'label',guard_spell.name,'reason','v2_extra_action_persistent_shield'
      );
    end if;

    if physical_score>=magic_score then
      return jsonb_build_object('action','physical','label','Физическая атака','reason','v2_guard_would_expire');
    end if;
    return jsonb_build_object('action','magic','label','Врождённая магия','reason','v2_guard_would_expire');
  end if;

  if immediate_extra
     and ce.enemy_hp_current<=greatest(physical_score,magic_score)*2
     and base_choice->>'action'='spell'
  then
    if physical_score>=magic_score then
      return jsonb_build_object('action','physical','label','Физическая атака','reason','v2_two_action_finish');
    end if;
    return jsonb_build_object('action','magic','label','Врождённая магия','reason','v2_two_action_finish');
  end if;

  return base_choice;
end;
$$;

create or replace function public.sync_client_duel_turn(
  p_character_id uuid,
  p_duel_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  caller uuid:=auth.uid();
  choice jsonb;
  result jsonb;
  distance text;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;
  if not exists(
    select 1 from private.client_runtime_flags f
    where f.character_id=p_character_id
      and f.flag_key='turn_mode_v1'
      and f.enabled
  ) then raise exception 'FEATURE_UNAVAILABLE'; end if;

  choice:=private.resolve_runtime_duel_turn_v2(p_character_id,p_duel_id);

  distance:=choice->>'distance';
  if distance in ('close','medium','far') then
    perform public.set_pvp_bow_distance(p_duel_id,distance);
  end if;

  if choice->>'action'='spell' then
    result:=public.perform_pvp_duel_action(
      p_duel_id,'spell',(choice->>'spell_id')::uuid
    );
  elsif choice->>'action' in ('physical','magic','guard','bow_draw') then
    result:=public.perform_pvp_duel_action(
      p_duel_id,choice->>'action',null
    );
  else
    result:=public.perform_pvp_duel_action(p_duel_id,'physical',null);
  end if;

  return jsonb_build_object('state',result);
end;
$$;

create or replace function public.sync_client_party_turn(
  p_character_id uuid,
  p_encounter_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  caller uuid:=auth.uid();
  choice jsonb;
  result jsonb;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;
  if not exists(
    select 1 from private.client_runtime_flags f
    where f.character_id=p_character_id
      and f.flag_key='turn_mode_v1'
      and f.enabled
  ) then raise exception 'FEATURE_UNAVAILABLE'; end if;

  choice:=private.resolve_runtime_party_turn_v2(p_character_id,p_encounter_id);

  if choice->>'action'='skip' then
    result:=public.skip_party_stunned_turn(p_character_id,p_encounter_id);
  elsif choice->>'action'='spell' then
    result:=public.cast_party_character_spell(
      p_character_id,p_encounter_id,(choice->>'spell_id')::uuid,
      case when nullif(choice->>'target_id','') is null then null
           else (choice->>'target_id')::uuid end
    );
  elsif choice->>'action' in ('physical','magic','guard','bow_draw') then
    result:=public.perform_party_combat_action(
      p_character_id,p_encounter_id,choice->>'action'
    );
  else
    result:=public.perform_party_combat_action(
      p_character_id,p_encounter_id,'physical'
    );
  end if;

  return jsonb_build_object('result',result);
end;
$$;

create or replace function private.process_client_runtime_sessions()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  rec record;
  owner_id uuid;
  encounter_id uuid;
  processed integer:=0;
  acted integer:=0;
  failures integer:=0;
  err text;
  action_count integer:=0;
  still_turn boolean:=false;
  retry_seconds integer:=1;
begin
  if not pg_try_advisory_xact_lock(hashtextextended('veira_client_runtime_worker',0)) then
    return jsonb_build_object('locked',true,'processed',0,'acted',0,'failures',0);
  end if;

  delete from private.client_runtime_sessions s
  where not exists(
    select 1 from private.client_runtime_flags f
    where f.character_id=s.character_id
      and f.flag_key='turn_mode_v1'
      and f.enabled
  );

  for rec in
    select s.character_id,s.scope,s.scope_id,s.error_count,c.owner_user_id
    from private.client_runtime_sessions s
    join public.characters c on c.id=s.character_id
    where s.next_retry_at<=now()
    order by s.created_at
  loop
    processed:=processed+1;
    owner_id:=rec.owner_user_id;
    action_count:=0;

    begin
      perform set_config('request.jwt.claim.sub',owner_id::text,true);

      if rec.scope='duel' then
        if not exists(
          select 1 from public.pvp_duels d
          where d.id=rec.scope_id
            and d.status='active'
            and rec.character_id in (d.challenger_character_id,d.opponent_character_id)
        ) then
          delete from private.client_runtime_sessions
          where character_id=rec.character_id and scope=rec.scope and scope_id=rec.scope_id;
          continue;
        end if;

        loop
          select exists(
            select 1 from public.pvp_duels d
            where d.id=rec.scope_id
              and d.status='active'
              and d.current_turn_character_id=rec.character_id
          ) into still_turn;

          exit when not still_turn or action_count>=3;
          perform public.sync_client_duel_turn(rec.character_id,rec.scope_id);
          action_count:=action_count+1;
          acted:=acted+1;
        end loop;

      elsif rec.scope='party' then
        if not exists(
          select 1
          from public.party_dungeon_runs r
          join public.party_dungeon_run_members m on m.run_id=r.id
          where r.id=rec.scope_id
            and r.status='active'
            and m.character_id=rec.character_id
        ) then
          delete from private.client_runtime_sessions
          where character_id=rec.character_id and scope=rec.scope and scope_id=rec.scope_id;
          continue;
        end if;

        loop
          select ce.id
          into encounter_id
          from public.party_combat_encounters ce
          where ce.run_id=rec.scope_id
            and ce.status='active'
          order by ce.created_at desc
          limit 1;

          exit when encounter_id is null or action_count>=3;
          exit when private.party_next_actor_id(encounter_id)<>rec.character_id;

          perform public.sync_client_party_turn(rec.character_id,encounter_id);
          action_count:=action_count+1;
          acted:=acted+1;
        end loop;
      end if;

      update private.client_runtime_sessions
      set last_action_at=case when action_count>0 then now() else last_action_at end,
          updated_at=now(),
          error_count=0,
          last_error=null,
          last_error_at=null,
          next_retry_at=now()
      where character_id=rec.character_id and scope=rec.scope and scope_id=rec.scope_id;

    exception when others then
      err:=sqlerrm;

      if err like '%NOT_YOUR_TURN%'
         or err like '%PARTY_NOT_YOUR_TURN%'
         or err like '%DUEL_NOT_ACTIVE%'
         or err like '%PARTY_COMBAT_NOT_ACTIVE%'
         or err like '%PARTY_ACTION_ALREADY_USED_THIS_ROUND%'
      then
        update private.client_runtime_sessions
        set next_retry_at=now()+interval '1 second',updated_at=now()
        where character_id=rec.character_id and scope=rec.scope and scope_id=rec.scope_id;
      elsif err like '%FEATURE_UNAVAILABLE%'
         or err like '%CHARACTER_NOT_OWNED%'
      then
        delete from private.client_runtime_sessions
        where character_id=rec.character_id and scope=rec.scope and scope_id=rec.scope_id;
      else
        failures:=failures+1;
        retry_seconds:=least(30,greatest(1,(power(2,least(5,coalesce(rec.error_count,0))))::integer));

        update private.client_runtime_sessions
        set error_count=least(32767,error_count+1),
            last_error=left(err,500),
            last_error_at=now(),
            next_retry_at=now()+make_interval(secs=>retry_seconds),
            updated_at=now()
        where character_id=rec.character_id and scope=rec.scope and scope_id=rec.scope_id;
      end if;
    end;
  end loop;

  return jsonb_build_object(
    'locked',false,
    'processed',processed,
    'acted',acted,
    'failures',failures
  );
end;
$$;
