-- Smart autobattle AI v2.
-- Consolidated definitions matching the live migration: rational spell use,
-- heal efficiency, weighted cleanse severity and anti-waste guard decisions.

CREATE OR REPLACE FUNCTION private.autobattle_heal_score(p_character_id uuid, p_spell_id uuid, p_magic_power integer, p_missing_hp integer, p_hp_percent integer)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  s public.spell_definitions;
  heal_value integer:=0;
  cost integer:=0;
  effective_heal integer:=0;
begin
  select * into s from public.spell_definitions where id=p_spell_id and enabled=true;
  if s.id is null or s.spell_kind<>'heal' then return 0; end if;

  cost:=greatest(1,private.character_effective_spell_mana_cost(p_character_id,s.id));
  heal_value:=greatest(
    1,
    private.concentrated_spell_direct_value(
      p_character_id,
      s.id,
      round(greatest(1,p_magic_power)*s.power_multiplier)::integer+s.flat_power
    )
  );
  heal_value:=greatest(
    1,
    round(
      heal_value
      *(100+private.character_religion_modifier_number(p_character_id,'healing_spell_bonus'))
      /100.0
    )::integer
  );
  effective_heal:=least(greatest(0,p_missing_hp),heal_value);

  if effective_heal<=0 then return 0; end if;

  -- At critical health raw survival is worth more than mana efficiency.
  if coalesce(p_hp_percent,100)<=20 then
    return effective_heal*2.0 + effective_heal::numeric/cost;
  end if;

  return effective_heal::numeric/cost*100.0 + effective_heal*0.15;
end;
$function$;

CREATE OR REPLACE FUNCTION private.autobattle_damage_spell_score(p_encounter_id uuid, p_spell_id uuid, p_priority integer DEFAULT 100)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  e public.combat_encounters;
  s public.spell_definitions;
  stats record;
  settings public.character_autobattle_settings;
  direct_damage integer:=0;
  status_utility integer:=0;
  total_bonus integer:=0;
  resistance integer:=0;
  player_reduction integer:=0;
  enemy_vulnerable integer:=0;
  mana_cost integer:=0;
  priority_mult numeric:=1.0;
  mana_penalty numeric:=0;
  same_effect_active boolean:=false;
  tick_damage integer:=0;
  strong_bonus integer:=0;
begin
  select * into e from public.combat_encounters where id=p_encounter_id;
  if e.id is null then return 0; end if;

  select * into s from public.spell_definitions
  where id=p_spell_id and enabled=true and spell_kind='damage';
  if s.id is null then return 0; end if;

  select * into stats from private.get_character_combat_stats(e.character_id);
  if stats.level is null then return 0; end if;

  settings:=private.ensure_character_autobattle_settings(e.character_id);
  mana_cost:=greatest(0,private.character_effective_spell_mana_cost(e.character_id,s.id));

  select
    least(60,coalesce(sum(potency) filter(where effect_type in ('chill','weaken')),0))::integer
  into player_reduction
  from public.combat_status_effects
  where encounter_id=e.id and target='player';

  select
    least(75,coalesce(sum(potency) filter(where effect_type='vulnerable'),0))::integer
  into enemy_vulnerable
  from public.combat_status_effects
  where encounter_id=e.id and target='enemy';

  direct_damage:=private.concentrated_spell_direct_value(
    e.character_id,
    s.id,
    greatest(
      1,
      private.damage_after_armor(
        round(stats.magic_power*s.power_multiplier)::integer+s.flat_power,
        e.enemy_defense*0.65
      )
    )
  );
  direct_damage:=private.ensure_spell_stronger_than_innate(
    direct_damage,
    greatest(1,private.damage_after_armor(stats.magic_power,e.enemy_defense*0.80)),
    10
  );

  total_bonus:=coalesce(stats.all_damage_bonus_percent,0)
    +coalesce(stats.magic_damage_bonus_percent,0)
    +private.character_damage_bonus(e.character_id,s.damage_type)
    +private.character_spell_family_damage_bonus_percent(e.character_id,s.id)
    +case when e.is_boss then coalesce(stats.boss_damage_bonus_percent,0) else 0 end;

  if private.combat_encounter_is_strong(e.id) then
    strong_bonus:=private.character_religion_modifier_number(e.character_id,'strong_enemy_damage_bonus');
    total_bonus:=total_bonus+strong_bonus;
  end if;

  direct_damage:=greatest(1,round(direct_damage*(100+total_bonus)/100.0)::integer);
  direct_damage:=greatest(1,round(direct_damage*(100-player_reduction)/100.0)::integer);
  direct_damage:=greatest(1,round(direct_damage*(100+enemy_vulnerable)/100.0)::integer);

  if stats.damage_vs_wounded_percent>0
     and e.enemy_hp_max>0
     and e.enemy_hp_current*100<=e.enemy_hp_max*30
  then
    direct_damage:=greatest(
      1,
      round(direct_damage*(100+stats.damage_vs_wounded_percent)/100.0)::integer
    );
  end if;

  if e.player_spell_damage_bonus_percent>0 and e.player_spell_damage_bonus_hits>0 then
    direct_damage:=greatest(
      1,
      round(direct_damage*(100+e.player_spell_damage_bonus_percent)/100.0)::integer
    );
  end if;

  resistance:=private.damage_resistance_percent(e.enemy_resistances,s.damage_type);
  direct_damage:=greatest(1,round(direct_damage*(100-resistance)/100.0)::integer);
  direct_damage:=greatest(
    1,
    round(
      direct_damage
      *private.character_expected_critical_multiplier(e.character_id,'magic')
    )::integer
  );

  if s.status_effect_type is not null
     and coalesce(s.status_effect_chance,0)>0
     and coalesce(s.status_effect_turns,0)>0
  then
    same_effect_active:=exists(
      select 1
      from public.combat_status_effects cse
      where cse.encounter_id=e.id
        and cse.target='enemy'
        and cse.effect_type=s.status_effect_type
    );

    if s.status_effect_type in ('burn','bleed','poison') then
      tick_damage:=private.status_tick_damage(
        s.status_effect_type,
        greatest(1,s.status_effect_potency),
        e.enemy_resistances
      );
      status_utility:=round(
        tick_damage
        *least(3,greatest(1,s.status_effect_turns))
        *greatest(0,least(100,s.status_effect_chance))/100.0
      )::integer;
    elsif s.status_effect_type='stun' then
      status_utility:=round(
        greatest(6,e.enemy_attack*0.75)
        *greatest(0,least(100,s.status_effect_chance))/100.0
      )::integer;
    elsif s.status_effect_type in ('weaken','chill') then
      status_utility:=round(
        greatest(4,e.enemy_attack)
        *greatest(0,s.status_effect_potency)/100.0
        *least(3,greatest(1,s.status_effect_turns))
        *greatest(0,least(100,s.status_effect_chance))/100.0
      )::integer;
    elsif s.status_effect_type='vulnerable' then
      status_utility:=round(
        direct_damage
        *greatest(0,s.status_effect_potency)/100.0
        *least(2,greatest(1,s.status_effect_turns))
        *greatest(0,least(100,s.status_effect_chance))/100.0
      )::integer;
    end if;

    if same_effect_active then
      status_utility:=round(status_utility*0.35)::integer;
    end if;
  end if;

  priority_mult:=greatest(
    0.80,
    least(1.20,1.10-(greatest(1,least(999,coalesce(p_priority,100)))-1)*0.002)
  );

  mana_penalty:=mana_cost*case coalesce(settings.strategy,'balanced')
    when 'conservative' then 0.16
    when 'aggressive' then 0.03
    else 0.08
  end;

  return greatest(
    1,
    round((direct_damage+status_utility)*priority_mult-mana_penalty)::integer
  );
end;
$function$;

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
      if chosen_spell_id is not null and (
        private.autobattle_damage_spell_score(
          encounter.id,chosen_spell_id,
          coalesce((select case when encounter.is_boss then rule.boss_priority else rule.normal_priority end
                    from public.character_autobattle_spell_rules rule
                    where rule.character_id=encounter.character_id and rule.spell_id=chosen_spell_id),100)
        ) >= encounter.enemy_hp_current
        or private.autobattle_damage_spell_score(
          encounter.id,chosen_spell_id,
          coalesce((select case when encounter.is_boss then rule.boss_priority else rule.normal_priority end
                    from public.character_autobattle_spell_rules rule
                    where rule.character_id=encounter.character_id and rule.spell_id=chosen_spell_id),100)
        ) >= ceil(best_free_score*case coalesce(settings.strategy,'balanced')
          when 'aggressive' then 0.90
          when 'conservative' then 1.22
          else 1.08 end)::integer
      ) then
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
$function$;

revoke all on function private.autobattle_heal_score(uuid,uuid,integer,integer,integer)
  from public, anon, authenticated;
revoke all on function private.autobattle_damage_spell_score(uuid,uuid,integer)
  from public, anon, authenticated;
revoke all on function private.run_combat_autobattle_internal(uuid,integer)
  from public, anon, authenticated;
