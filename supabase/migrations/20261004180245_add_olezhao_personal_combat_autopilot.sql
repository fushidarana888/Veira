-- Personal combat autopilot for Olezhao Gonzalez only.
-- Public entry points verify auth.uid() owns the hard-coded character.
-- Irreversible actions (surrender, escape, sacrifice scroll) are intentionally absent.

CREATE OR REPLACE FUNCTION private.olezhao_pvp_autopilot_choice(p_duel_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  cid constant uuid:='c5caef7c-33c3-4799-8445-2cbf1448b6bc'::uuid;
  d public.pvp_duels%rowtype;
  a public.pvp_duel_states%rowtype;
  t public.pvp_duel_states%rowtype;
  hp_percent integer:=100;
  reserve integer:=0;
  physical_score integer:=0;
  magic_score integer:=0;
  target_physical integer:=0;
  target_magic integer:=0;
  target_threat integer:=0;
  resistance integer:=0;
  heal_spell record;
  guard_spell record;
  vuln_spell record;
  damage_spell record;
  damage_spell_score integer:=0;
  free_score integer:=0;
  mana_cost integer:=0;
  settings public.character_autobattle_settings;
begin
  select * into d from public.pvp_duels where id=p_duel_id;
  if d.id is null or d.status<>'active' then raise exception 'DUEL_NOT_ACTIVE'; end if;
  if d.current_turn_character_id<>cid then raise exception 'NOT_YOUR_TURN'; end if;

  select * into a from public.pvp_duel_states where duel_id=p_duel_id and character_id=cid;
  select * into t from public.pvp_duel_states
  where duel_id=p_duel_id and character_id<>cid
  limit 1;

  if a.character_id is null or t.character_id is null then raise exception 'DUEL_NOT_FOUND'; end if;

  settings:=private.ensure_character_autobattle_settings(cid);
  hp_percent:=floor(a.hp_current*100.0/greatest(1,a.hp_max))::integer;
  reserve:=floor(a.mana_max*greatest(0,coalesce(settings.mana_reserve_percent,20))/100.0)::integer;

  if a.bow_draw_pending then
    return jsonb_build_object('action','physical','label','Выпустить подготовленный выстрел');
  end if;

  physical_score:=greatest(
    1,
    private.damage_after_armor(a.physical_power,greatest(0,t.physical_defense))
  );
  resistance:=private.damage_resistance_percent(t.damage_resistances,a.weapon_damage_type);
  physical_score:=greatest(1,round(
    physical_score
    *(100+a.all_damage_bonus_percent+a.physical_damage_bonus_percent
      +private.character_damage_bonus(cid,a.weapon_damage_type))/100.0
    *(100-resistance)/100.0
  )::integer);
  if t.hp_current*100<=greatest(1,t.hp_max)*30 then
    physical_score:=greatest(1,round(
      physical_score*(100+a.damage_vs_wounded_percent)/100.0
      *(100-t.low_hp_damage_reduction_percent)/100.0
    )::integer);
  end if;
  physical_score:=greatest(1,round(
    physical_score*private.character_expected_critical_multiplier(cid,'physical')
  )::integer);

  magic_score:=greatest(
    1,
    private.damage_after_armor(a.magic_power,greatest(0,t.magic_defense))
  );
  resistance:=private.damage_resistance_percent(t.damage_resistances,a.magic_damage_type);
  magic_score:=greatest(1,round(
    magic_score
    *(100+a.all_damage_bonus_percent+a.magic_damage_bonus_percent
      +private.character_damage_bonus(cid,a.magic_damage_type))/100.0
    *(100-resistance)/100.0
  )::integer);
  magic_score:=greatest(1,round(
    magic_score*private.character_expected_critical_multiplier(cid,'magic')
  )::integer);

  target_physical:=greatest(
    1,
    private.damage_after_armor(t.physical_power,greatest(0,a.physical_defense))
  );
  resistance:=private.damage_resistance_percent(a.damage_resistances,t.weapon_damage_type);
  target_physical:=greatest(1,round(
    target_physical
    *(100+t.all_damage_bonus_percent+t.physical_damage_bonus_percent)/100.0
    *(100-resistance)/100.0
  )::integer);

  target_magic:=greatest(
    1,
    private.damage_after_armor(t.magic_power,greatest(0,a.magic_defense))
  );
  resistance:=private.damage_resistance_percent(a.damage_resistances,t.magic_damage_type);
  target_magic:=greatest(1,round(
    target_magic
    *(100+t.all_damage_bonus_percent+t.magic_damage_bonus_percent)/100.0
    *(100-resistance)/100.0
  )::integer);
  target_threat:=greatest(target_physical,target_magic);
  free_score:=greatest(physical_score,magic_score);

  -- An already prepared counter should be cashed out immediately.
  if coalesce(a.counter_blocked_damage,0)>0 then
    return jsonb_build_object(
      'action','physical','label','Контратака',
      'reason','prepared_counter'
    );
  end if;

  -- Cheaply consume an enemy stance instead of feeding it a full physical hit.
  if coalesce(t.guard_stance_active,false)
     and a.mana_current>reserve
  then
    select sd.*,
           private.character_effective_spell_mana_cost(cid,sd.id) as effective_cost
    into vuln_spell
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=cid
      and sd.enabled
      and sd.spell_kind='damage'
      and sd.status_effect_type='vulnerable'
      and private.character_effective_spell_mana_cost(cid,sd.id)<=a.mana_current
    order by private.character_effective_spell_mana_cost(cid,sd.id),sd.required_level desc
    limit 1;

    if vuln_spell.id is not null
       and a.mana_current-vuln_spell.effective_cost>=reserve
    then
      return jsonb_build_object(
        'action','spell','spell_id',vuln_spell.id,
        'label',vuln_spell.name,'reason','break_guard_cheaply'
      );
    end if;
  end if;

  -- Heal when the next serious exchange is dangerous, but do not waste a turn
  -- if a free hit is likely to finish the duel.
  if hp_percent<=45
     and t.hp_current>free_score
  then
    select sd.*,
           private.character_effective_spell_mana_cost(cid,sd.id) as effective_cost
    into heal_spell
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=cid
      and sd.enabled
      and sd.spell_kind='heal'
      and private.character_effective_spell_mana_cost(cid,sd.id)<=a.mana_current
    order by private.autobattle_heal_score(
      cid,sd.id,a.magic_power,greatest(0,a.hp_max-a.hp_current),hp_percent
    ) desc
    limit 1;

    if heal_spell.id is not null
       and (
         a.mana_current-heal_spell.effective_cost>=reserve
         or target_threat>=a.hp_current
       )
    then
      return jsonb_build_object(
        'action','spell','spell_id',heal_spell.id,
        'label',heal_spell.name,'reason','low_hp'
      );
    end if;
  end if;

  -- Magical shield if a bad exchange is coming. It may survive our later turn,
  -- unlike ordinary stance.
  if coalesce(a.guard_spell_percent,0)<=0
     and coalesce(a.reflect_percent,0)<=0
     and t.hp_current>free_score
     and (
       target_threat>=ceil(a.hp_current*0.42)::integer
       or hp_percent<=58
     )
  then
    select sd.*,
           private.character_effective_spell_mana_cost(cid,sd.id) as effective_cost
    into guard_spell
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=cid
      and sd.enabled
      and sd.spell_kind='guard'
      and private.character_effective_spell_mana_cost(cid,sd.id)<=a.mana_current
    order by
      case when sd.slug='mirror_barrier' and target_threat>=ceil(a.hp_current*0.45)::integer then 0 else 1 end,
      private.concentrated_spell_percent_value(cid,sd.id,sd.support_value) desc,
      private.character_effective_spell_mana_cost(cid,sd.id)
    limit 1;

    if guard_spell.id is not null
       and a.mana_current-guard_spell.effective_cost>=reserve
    then
      return jsonb_build_object(
        'action','spell','spell_id',guard_spell.id,
        'label',guard_spell.name,'reason','dangerous_exchange'
      );
    end if;
  end if;

  -- Ordinary guard is a last-resort tempo action.
  if hp_percent<=34
     and not coalesce(a.guard_stance_active,false)
     and t.hp_current>free_score
  then
    return jsonb_build_object('action','guard','label','Защитная стойка','reason','critical_hp');
  end if;

  -- Consider equipped damage spells, but require them to beat the free attack
  -- by a useful margin. This prevents Rune of Exposure from being spammed.
  select q.*
  into damage_spell
  from (
    select
      sd.id,sd.name,
      private.character_effective_spell_mana_cost(cid,sd.id) as effective_cost,
      greatest(1,round(
        greatest(
          1,
          private.damage_after_armor(
            round(a.magic_power*sd.power_multiplier)::integer+sd.flat_power,
            greatest(0,t.magic_defense)*0.85
          )
        )
        *(100+a.all_damage_bonus_percent+a.magic_damage_bonus_percent
          +private.character_damage_bonus(cid,sd.damage_type)
          +private.character_spell_family_damage_bonus_percent(cid,sd.id))/100.0
        *(100-private.damage_resistance_percent(t.damage_resistances,sd.damage_type))/100.0
        *private.character_expected_critical_multiplier(cid,'magic')
      )::integer)
      +case
        when sd.status_effect_type='stun'
          then round(target_threat*sd.status_effect_chance/100.0)::integer
        when sd.status_effect_type='vulnerable'
          then round(free_score*sd.status_effect_potency/100.0
            *sd.status_effect_chance/100.0)::integer
        else 0
      end as score
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=cid
      and sd.enabled
      and sd.spell_kind='damage'
      and private.character_effective_spell_mana_cost(cid,sd.id)<=a.mana_current
  ) q
  where a.mana_current-q.effective_cost>=reserve
  order by q.score desc,q.effective_cost
  limit 1;

  if damage_spell.id is not null
     and damage_spell.score>=ceil(free_score*1.18)::integer
  then
    return jsonb_build_object(
      'action','spell','spell_id',damage_spell.id,
      'label',damage_spell.name,'reason','best_damage_line'
    );
  end if;

  if physical_score>=magic_score then
    if private.character_weapon_family(cid)='long_bow'
       and not a.bow_draw_pending
       and hp_percent>40
       and target_threat<a.hp_current
    then
      return jsonb_build_object('action','bow_draw','label','Полный натяг','reason','long_bow');
    end if;
    return jsonb_build_object('action','physical','label','Физическая атака','reason','best_free_hit');
  end if;

  return jsonb_build_object('action','magic','label','Врождённая магия','reason','best_free_hit');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.olezhao_pvp_autopilot_step(p_duel_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  cid constant uuid:='c5caef7c-33c3-4799-8445-2cbf1448b6bc'::uuid;
  caller uuid:=auth.uid();
  choice jsonb;
  result jsonb;
  distance text;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters
    where id=cid and owner_user_id=caller
  ) then raise exception 'AUTOPILOT_NOT_AVAILABLE'; end if;

  choice:=private.olezhao_pvp_autopilot_choice(p_duel_id);

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

  return jsonb_build_object('choice',choice,'state',result);
end;
$function$
;

CREATE OR REPLACE FUNCTION private.olezhao_party_autopilot_choice(p_encounter_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  cid constant uuid:='c5caef7c-33c3-4799-8445-2cbf1448b6bc'::uuid;
  ce public.party_combat_encounters%rowtype;
  ms public.party_combat_member_states%rowtype;
  st record;
  settings public.character_autobattle_settings;
  hp_percent integer:=100;
  reserve integer:=0;
  allow_physical boolean:=true;
  allow_magic boolean:=false;
  allow_spells boolean:=false;
  support_enabled boolean:=false;
  heal_threshold integer:=0;
  cleanse_min integer:=0;
  shield_special boolean:=false;
  buff_enabled boolean:=false;
  guard_mode text:='never';
  guard_hp integer:=0;
  guard_every integer:=0;
  guard_due boolean:=false;
  severity integer:=0;
  physical_score integer:=-1;
  magic_score integer:=-1;
  free_score integer:=1;
  resistance integer:=0;
  heal_spell record;
  cleanse_spell record;
  guard_spell record;
  buff_spell record;
  damage_spell record;
  family text;
begin
  select * into ce from public.party_combat_encounters where id=p_encounter_id;
  if ce.id is null or ce.status<>'active' then raise exception 'PARTY_COMBAT_NOT_ACTIVE'; end if;
  if private.party_next_actor_id(p_encounter_id)<>cid then raise exception 'PARTY_NOT_YOUR_TURN'; end if;

  select * into ms
  from public.party_combat_member_states
  where encounter_id=p_encounter_id and character_id=cid;

  if ms.character_id is null or ms.downed then raise exception 'PARTY_MEMBER_DOWNED'; end if;

  if exists(
    select 1
    from public.party_combat_status_effects
    where encounter_id=p_encounter_id
      and target_type='member'
      and target_character_id=cid
      and effect_type='stun'
      and remaining_turns>0
  ) then
    return jsonb_build_object('action','skip','label','Пропуск хода · оглушение');
  end if;

  if ms.bow_draw_pending then
    return jsonb_build_object('action','physical','label','Выпустить подготовленный выстрел');
  end if;

  select * into st from private.get_character_combat_stats(cid);
  settings:=private.ensure_character_autobattle_settings(cid);
  family:=private.character_weapon_family(cid);

  hp_percent:=floor(ms.hp_current*100.0/greatest(1,ms.hp_max))::integer;
  reserve:=floor(ms.mana_max*greatest(0,coalesce(settings.mana_reserve_percent,20))/100.0)::integer;

  if ce.is_boss then
    allow_physical:=settings.boss_allow_physical;
    allow_magic:=settings.boss_allow_magic;
    allow_spells:=settings.boss_allow_spells and settings.use_learned_spells;
    support_enabled:=settings.boss_support_enabled;
    heal_threshold:=settings.boss_heal_hp_percent;
    cleanse_min:=settings.boss_cleanse_min_debuffs;
    shield_special:=settings.boss_shield_special;
    buff_enabled:=settings.boss_buff_enabled;
    guard_mode:=settings.boss_guard_mode;
    guard_hp:=settings.boss_guard_hp_percent;
    guard_every:=settings.boss_guard_every_n;
  else
    allow_physical:=settings.normal_allow_physical;
    allow_magic:=settings.normal_allow_magic;
    allow_spells:=settings.normal_allow_spells and settings.use_learned_spells;
    support_enabled:=settings.normal_support_enabled;
    heal_threshold:=settings.normal_heal_hp_percent;
    cleanse_min:=settings.normal_cleanse_min_debuffs;
    shield_special:=settings.normal_shield_special;
    buff_enabled:=settings.normal_buff_enabled;
    guard_mode:=settings.normal_guard_mode;
    guard_hp:=settings.normal_guard_hp_percent;
    guard_every:=settings.normal_guard_every_n;
  end if;

  select coalesce(sum(case effect_type
    when 'stun' then 4
    when 'vulnerable' then 3
    when 'weaken' then 2
    when 'chill' then 2
    else 1 end),0)::integer
  into severity
  from public.party_combat_status_effects
  where encounter_id=p_encounter_id
    and target_type='member'
    and target_character_id=cid
    and remaining_turns>0;

  if allow_spells and support_enabled and cleanse_min>0 and severity>=cleanse_min then
    select sd.*,private.character_effective_spell_mana_cost(cid,sd.id) effective_cost
    into cleanse_spell
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=cid
      and sd.enabled and sd.spell_kind='cleanse'
      and private.character_effective_spell_mana_cost(cid,sd.id)<=ms.mana_current
      and ms.mana_current-private.character_effective_spell_mana_cost(cid,sd.id)>=reserve
    order by private.character_effective_spell_mana_cost(cid,sd.id)
    limit 1;
    if cleanse_spell.id is not null then
      return jsonb_build_object(
        'action','spell','spell_id',cleanse_spell.id,'target_id',cid,
        'label',cleanse_spell.name,'reason','cleanse'
      );
    end if;
  end if;

  if allow_spells and support_enabled and heal_threshold>0
     and hp_percent<=heal_threshold
  then
    select sd.*,private.character_effective_spell_mana_cost(cid,sd.id) effective_cost
    into heal_spell
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=cid
      and sd.enabled and sd.spell_kind='heal'
      and private.character_effective_spell_mana_cost(cid,sd.id)<=ms.mana_current
      and ms.mana_current-private.character_effective_spell_mana_cost(cid,sd.id)>=reserve
    order by private.autobattle_heal_score(
      cid,sd.id,st.magic_power,greatest(0,ms.hp_max-ms.hp_current),hp_percent
    ) desc
    limit 1;
    if heal_spell.id is not null then
      return jsonb_build_object(
        'action','spell','spell_id',heal_spell.id,'target_id',cid,
        'label',heal_spell.name,'reason','low_hp'
      );
    end if;
  end if;

  guard_due:=coalesce((ce.enemy_ai_state->>'danger_pending')::boolean,false);
  if not guard_due then
    guard_due:=case guard_mode
      when 'low_hp' then hp_percent<=guard_hp
      when 'interval' then guard_every>0 and ce.round>0 and mod(ce.round,guard_every)=0
      when 'low_hp_or_interval' then hp_percent<=guard_hp
        or (guard_every>0 and ce.round>0 and mod(ce.round,guard_every)=0)
      else false
    end;
  end if;

  if allow_spells and support_enabled and shield_special and guard_due
     and coalesce(ms.guard_spell_percent,0)<=0 and coalesce(ms.reflect_percent,0)<=0
  then
    select sd.*,private.character_effective_spell_mana_cost(cid,sd.id) effective_cost
    into guard_spell
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=cid
      and sd.enabled and sd.spell_kind='guard'
      and private.character_effective_spell_mana_cost(cid,sd.id)<=ms.mana_current
      and ms.mana_current-private.character_effective_spell_mana_cost(cid,sd.id)>=reserve
    order by
      case when sd.slug='mirror_barrier' then 0 else 1 end,
      private.concentrated_spell_percent_value(cid,sd.id,sd.support_value) desc,
      private.character_effective_spell_mana_cost(cid,sd.id)
    limit 1;
    if guard_spell.id is not null then
      return jsonb_build_object(
        'action','spell','spell_id',guard_spell.id,'target_id',cid,
        'label',guard_spell.name,'reason','danger_window'
      );
    end if;
  end if;

  if guard_due
     and coalesce(ms.guard_percent,0)<=0
     and coalesce(ms.reflect_percent,0)<=0
  then
    return jsonb_build_object('action','guard','label','Защитная стойка','reason','configured_guard');
  end if;

  if allow_spells and support_enabled and buff_enabled
     and coalesce(ms.damage_bonus_hits,0)<=0
  then
    select sd.*,private.character_effective_spell_mana_cost(cid,sd.id) effective_cost
    into buff_spell
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=cid
      and sd.enabled and sd.spell_kind='buff'
      and private.character_effective_spell_mana_cost(cid,sd.id)<=ms.mana_current
      and ms.mana_current-private.character_effective_spell_mana_cost(cid,sd.id)>=reserve
    order by
      private.concentrated_spell_percent_value(cid,sd.id,sd.support_value)
        *greatest(1,sd.support_turns) desc,
      private.character_effective_spell_mana_cost(cid,sd.id)
    limit 1;
    if buff_spell.id is not null and ce.enemy_hp_current*100>greatest(1,ce.enemy_hp_max)*40 then
      return jsonb_build_object(
        'action','spell','spell_id',buff_spell.id,'target_id',cid,
        'label',buff_spell.name,'reason','buff_opening'
      );
    end if;
  end if;

  if allow_physical then
    physical_score:=greatest(1,private.damage_after_armor(st.physical_power,ce.enemy_defense));
    resistance:=private.damage_resistance_percent(ce.enemy_resistances,st.weapon_damage_type);
    physical_score:=greatest(1,round(
      physical_score
      *(100+st.all_damage_bonus_percent+st.physical_damage_bonus_percent
        +private.character_damage_bonus(cid,st.weapon_damage_type))/100.0
      *(100-resistance)/100.0
      *private.character_expected_critical_multiplier(cid,'physical')
    )::integer);
  end if;

  if allow_magic then
    magic_score:=greatest(1,private.damage_after_armor(st.magic_power,ce.enemy_defense*0.85));
    resistance:=private.damage_resistance_percent(ce.enemy_resistances,st.magic_damage_type);
    magic_score:=greatest(1,round(
      magic_score
      *(100+st.all_damage_bonus_percent+st.magic_damage_bonus_percent
        +private.character_damage_bonus(cid,st.magic_damage_type))/100.0
      *(100-resistance)/100.0
      *private.character_expected_critical_multiplier(cid,'magic')
    )::integer);
  end if;

  free_score:=greatest(physical_score,magic_score,1);

  if allow_spells then
    select q.* into damage_spell
    from (
      select
        sd.id,sd.name,
        private.character_effective_spell_mana_cost(cid,sd.id) effective_cost,
        greatest(1,round(
          greatest(1,private.damage_after_armor(
            round(st.magic_power*sd.power_multiplier)::integer+sd.flat_power,
            ce.enemy_defense*0.85
          ))
          *(100+st.all_damage_bonus_percent+st.magic_damage_bonus_percent
            +private.character_damage_bonus(cid,sd.damage_type)
            +private.character_spell_family_damage_bonus_percent(cid,sd.id))/100.0
          *(100-private.damage_resistance_percent(ce.enemy_resistances,sd.damage_type))/100.0
          *private.character_expected_critical_multiplier(cid,'magic')
        )::integer)
        +case
          when sd.status_effect_type='stun'
            then round(ce.enemy_attack*sd.status_effect_chance/100.0)::integer
          when sd.status_effect_type='vulnerable'
            then round(free_score*sd.status_effect_potency/100.0
              *sd.status_effect_chance/100.0)::integer
          else 0
        end as score,
        coalesce(
          case when ce.is_boss then rule.boss_priority else rule.normal_priority end,
          100
        ) priority
      from public.character_combat_spells ccs
      join public.spell_definitions sd on sd.id=ccs.spell_id
      left join public.character_autobattle_spell_rules rule
        on rule.character_id=cid and rule.spell_id=sd.id
      where ccs.character_id=cid
        and sd.enabled and sd.spell_kind='damage'
        and private.character_effective_spell_mana_cost(cid,sd.id)<=ms.mana_current
        and ms.mana_current-private.character_effective_spell_mana_cost(cid,sd.id)>=reserve
        and (
          rule.character_id is null
          or case when ce.is_boss then rule.boss_enabled else rule.normal_enabled end
        )
    ) q
    order by round(q.score*greatest(0.8,least(1.2,1.10-(q.priority-1)*0.002))) desc,
             q.effective_cost
    limit 1;
  end if;

  if damage_spell.id is not null
     and damage_spell.score>=ceil(free_score*1.10)::integer
  then
    return jsonb_build_object(
      'action','spell','spell_id',damage_spell.id,'target_id',null,
      'label',damage_spell.name,'reason','best_damage_line'
    );
  end if;

  if physical_score>=magic_score and physical_score>0 then
    if family='long_bow' and hp_percent>40 then
      return jsonb_build_object('action','bow_draw','label','Полный натяг','reason','long_bow');
    end if;
    return jsonb_build_object('action','physical','label','Физическая атака','reason','best_free_hit');
  elsif magic_score>0 then
    return jsonb_build_object('action','magic','label','Врождённая магия','reason','best_free_hit');
  end if;

  return jsonb_build_object('action','physical','label','Физическая атака','reason','fallback');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.olezhao_party_autopilot_step(p_encounter_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  cid constant uuid:='c5caef7c-33c3-4799-8445-2cbf1448b6bc'::uuid;
  caller uuid:=auth.uid();
  choice jsonb;
  result jsonb;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters
    where id=cid and owner_user_id=caller
  ) then raise exception 'AUTOPILOT_NOT_AVAILABLE'; end if;

  choice:=private.olezhao_party_autopilot_choice(p_encounter_id);

  if choice->>'action'='skip' then
    result:=public.skip_party_stunned_turn(cid,p_encounter_id);
  elsif choice->>'action'='spell' then
    result:=public.cast_party_character_spell(
      cid,p_encounter_id,(choice->>'spell_id')::uuid,
      case when nullif(choice->>'target_id','') is null then null
           else (choice->>'target_id')::uuid end
    );
  elsif choice->>'action' in ('physical','magic','guard','bow_draw') then
    result:=public.perform_party_combat_action(
      cid,p_encounter_id,choice->>'action'
    );
  else
    result:=public.perform_party_combat_action(cid,p_encounter_id,'physical');
  end if;

  return jsonb_build_object('choice',choice,'result',result);
end;
$function$
;

revoke all on function public.olezhao_pvp_autopilot_step(uuid) from public, anon;
grant execute on function public.olezhao_pvp_autopilot_step(uuid) to authenticated;

revoke all on function public.olezhao_party_autopilot_step(uuid) from public, anon;
grant execute on function public.olezhao_party_autopilot_step(uuid) to authenticated;
