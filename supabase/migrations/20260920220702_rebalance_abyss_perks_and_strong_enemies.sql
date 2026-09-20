alter table public.enemy_templates
  add column if not exists is_strong_enemy boolean not null default false;

update public.enemy_templates
set is_strong_enemy=true
where is_boss=true
  and is_strong_enemy=false;

update public.religion_level_perks
set title=v.title, description=v.description, modifiers=v.modifiers::jsonb
from (values
  (1,'Воля взять','+3 к Силе.','{"strength":3}'),
  (2,'Первая цена','Вампиризм +2%.','{"lifesteal":2}'),
  (3,'Цена плоти','Максимум HP -3%, Удача +1.','{"max_hp_percent":-3,"luck":1}'),
  (4,'Жажда силы','Весь прямой урон +4%.','{"all_damage_bonus":4}'),
  (5,'Охота на сильных','Урон по сильным противникам +10%.','{"strong_enemy_damage_bonus":10}'),
  (6,'Хищная поступь','+3 к Ловкости.','{"agility":3}'),
  (7,'Плата разумом','Максимум HP -3%, Интеллект +1.','{"max_hp_percent":-3,"intellect":1}'),
  (8,'Снять цепи','Ещё +4% всего прямого урона.','{"all_damage_bonus":4}'),
  (9,'Жажда крови','Получаемый урон +5%, вампиризм +3%.','{"incoming_damage_taken_percent":5,"lifesteal":3}')
) as v(level,title,description,modifiers)
where religion_level_perks.religion_slug='abyss'
  and religion_level_perks.level=v.level;

CREATE OR REPLACE FUNCTION private.combat_encounter_is_strong(p_encounter_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  select coalesce(
    ce.is_boss
    or coalesce(et.is_strong_enemy,false)
    or dr.event_boss_id is not null,
    false
  )
  from public.combat_encounters ce
  left join public.enemy_templates et on et.id=ce.enemy_template_id
  left join public.dungeon_runs dr on dr.id=ce.dungeon_run_id
  where ce.id=p_encounter_id;
$function$;

CREATE OR REPLACE FUNCTION private.party_combat_encounter_is_strong(p_encounter_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  select coalesce(
    ce.is_boss
    or coalesce(et.is_strong_enemy,false)
    or pr.event_boss_id is not null,
    false
  )
  from public.party_combat_encounters ce
  left join public.enemy_templates et on et.id=ce.enemy_template_id
  left join public.party_dungeon_runs pr on pr.id=ce.run_id
  where ce.id=p_encounter_id;
$function$;

CREATE OR REPLACE FUNCTION public.gm_set_enemy_strong_status(p_enemy_id uuid, p_is_strong_enemy boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
begin
  if not private.is_gm(auth.uid()) then raise exception 'GM_REQUIRED'; end if;

  update public.enemy_templates
  set is_strong_enemy=coalesce(p_is_strong_enemy,false),
      updated_at=now()
  where id=p_enemy_id;

  if not found then raise exception 'ENEMY_TEMPLATE_NOT_FOUND'; end if;

  insert into public.gm_audit_log(actor_user_id,action,target_type,target_id,details)
  values(
    auth.uid(),'enemy_template.strong_status','enemy_template',p_enemy_id::text,
    jsonb_build_object('is_strong_enemy',coalesce(p_is_strong_enemy,false))
  );
end;
$function$;

CREATE OR REPLACE FUNCTION private.character_religion_modifiers(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
with state as (
  select cr.current_religion_slug religion_slug,
         private.religion_level(coalesce(cp.faith_points,0)) religion_level
  from public.character_religions cr
  left join public.character_religion_progress cp
    on cp.character_id=cr.character_id and cp.religion_slug=cr.current_religion_slug
  where cr.character_id=p_character_id and cr.current_religion_slug is not null
), perks as (
  select p.modifiers
  from state s join public.religion_level_perks p
    on p.religion_slug=s.religion_slug and p.level<=s.religion_level
)
select jsonb_build_object(
  'strength',coalesce(sum(case when jsonb_typeof(modifiers->'strength')='number' then (modifiers->>'strength')::int else 0 end),0),
  'agility',coalesce(sum(case when jsonb_typeof(modifiers->'agility')='number' then (modifiers->>'agility')::int else 0 end),0),
  'intellect',coalesce(sum(case when jsonb_typeof(modifiers->'intellect')='number' then (modifiers->>'intellect')::int else 0 end),0),
  'vitality',coalesce(sum(case when jsonb_typeof(modifiers->'vitality')='number' then (modifiers->>'vitality')::int else 0 end),0),
  'luck',coalesce(sum(case when jsonb_typeof(modifiers->'luck')='number' then (modifiers->>'luck')::int else 0 end),0),
  'lifesteal',coalesce(sum(case when jsonb_typeof(modifiers->'lifesteal')='number' then (modifiers->>'lifesteal')::int else 0 end),0),
  'mana_on_hit',coalesce(sum(case when jsonb_typeof(modifiers->'mana_on_hit')='number' then (modifiers->>'mana_on_hit')::int else 0 end),0),
  'guard_boost',coalesce(sum(case when jsonb_typeof(modifiers->'guard_boost')='number' then (modifiers->>'guard_boost')::int else 0 end),0),
  'evasion_chance',coalesce(sum(case when jsonb_typeof(modifiers->'evasion_chance')='number' then (modifiers->>'evasion_chance')::int else 0 end),0),
  'healing_spell_bonus',coalesce(sum(case when jsonb_typeof(modifiers->'healing_spell_bonus')='number' then (modifiers->>'healing_spell_bonus')::int else 0 end),0),
  'shield_spell_bonus',coalesce(sum(case when jsonb_typeof(modifiers->'shield_spell_bonus')='number' then (modifiers->>'shield_spell_bonus')::int else 0 end),0),
  'magic_defense_percent',coalesce(sum(case when jsonb_typeof(modifiers->'magic_defense_percent')='number' then (modifiers->>'magic_defense_percent')::int else 0 end),0),
  'spell_mana_cost_reduction_percent',coalesce(sum(case when jsonb_typeof(modifiers->'spell_mana_cost_reduction_percent')='number' then (modifiers->>'spell_mana_cost_reduction_percent')::int else 0 end),0),
  'low_hp_50_damage_reduction',coalesce(sum(case when jsonb_typeof(modifiers->'low_hp_50_damage_reduction')='number' then (modifiers->>'low_hp_50_damage_reduction')::int else 0 end),0),
  'exploration_speed_percent',coalesce(sum(case when jsonb_typeof(modifiers->'exploration_speed_percent')='number' then (modifiers->>'exploration_speed_percent')::int else 0 end),0),
  'max_hp_percent',coalesce(sum(case when jsonb_typeof(modifiers->'max_hp_percent')='number' then (modifiers->>'max_hp_percent')::int else 0 end),0),
  'incoming_damage_taken_percent',coalesce(sum(case when jsonb_typeof(modifiers->'incoming_damage_taken_percent')='number' then (modifiers->>'incoming_damage_taken_percent')::int else 0 end),0),
  'strong_enemy_damage_bonus',coalesce(sum(case when jsonb_typeof(modifiers->'strong_enemy_damage_bonus')='number' then (modifiers->>'strong_enemy_damage_bonus')::int else 0 end),0),
  'shop_discount_percent',coalesce(sum(case when jsonb_typeof(modifiers->'shop_discount_percent')='number' then (modifiers->>'shop_discount_percent')::int else 0 end),0),
  'all_damage_bonus',coalesce(sum(case when jsonb_typeof(modifiers->'all_damage_bonus')='number' then (modifiers->>'all_damage_bonus')::int else 0 end),0),
  'physical_damage_bonus',coalesce(sum(case when jsonb_typeof(modifiers->'physical_damage_bonus')='number' then (modifiers->>'physical_damage_bonus')::int else 0 end),0),
  'magic_damage_bonus',coalesce(sum(case when jsonb_typeof(modifiers->'magic_damage_bonus')='number' then (modifiers->>'magic_damage_bonus')::int else 0 end),0),
  'low_hp_damage_reduction',coalesce(sum(case when jsonb_typeof(modifiers->'low_hp_damage_reduction')='number' then (modifiers->>'low_hp_damage_reduction')::int else 0 end),0),
  'boss_damage_bonus',coalesce(sum(case when jsonb_typeof(modifiers->'boss_damage_bonus')='number' then (modifiers->>'boss_damage_bonus')::int else 0 end),0),
  'resistances',jsonb_build_object(
    'slashing',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'slashing')='number' then (modifiers->'resistances'->>'slashing')::int else 0 end),0),
    'piercing',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'piercing')='number' then (modifiers->'resistances'->>'piercing')::int else 0 end),0),
    'blunt',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'blunt')='number' then (modifiers->'resistances'->>'blunt')::int else 0 end),0),
    'fire',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'fire')='number' then (modifiers->'resistances'->>'fire')::int else 0 end),0),
    'water',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'water')='number' then (modifiers->'resistances'->>'water')::int else 0 end),0),
    'earth',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'earth')='number' then (modifiers->'resistances'->>'earth')::int else 0 end),0),
    'air',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'air')='number' then (modifiers->'resistances'->>'air')::int else 0 end),0),
    'lightning',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'lightning')='number' then (modifiers->'resistances'->>'lightning')::int else 0 end),0),
    'ice',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'ice')='number' then (modifiers->'resistances'->>'ice')::int else 0 end),0),
    'arcane',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'arcane')='number' then (modifiers->'resistances'->>'arcane')::int else 0 end),0),
    'star',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'star')='number' then (modifiers->'resistances'->>'star')::int else 0 end),0),
    'gravity',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'gravity')='number' then (modifiers->'resistances'->>'gravity')::int else 0 end),0),
    'moon',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'moon')='number' then (modifiers->'resistances'->>'moon')::int else 0 end),0)
  )
) from perks;
$function$;

CREATE OR REPLACE FUNCTION private.character_max_hp_percent(p_character_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  select greatest(
    -80,
    least(
      200,
      coalesce((
        select sum(
          case
            when jsonb_typeof(idf.stat_modifiers->'max_hp_percent')='number'
              then (idf.stat_modifiers->>'max_hp_percent')::numeric::integer
            else 0
          end
        )::integer
        from public.character_equipment ce
        join public.character_items ci on ci.id=ce.character_item_id
        join public.item_definitions idf on idf.id=ci.item_definition_id
        where ce.character_id=p_character_id
      ),0)
      +private.character_religion_modifier_number(p_character_id,'max_hp_percent')
    )
  );
$function$;

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

    if bow_family in ('short_bow','long_bow') then
      bow_release:=encounter.player_bow_draw_pending;
      if bow_family='long_bow' and not bow_release then
        raise exception 'BOW_REQUIRES_FULL_DRAW';
      end if;

      bow_multiplier:=private.bow_distance_multiplier(encounter.player_bow_distance)
        * case when bow_release then 1.60 else 1.00 end;
      bow_effective_defense:=case
        when bow_release then floor(encounter.enemy_defense*(100-bow_penetration)/100.0)::integer
        else encounter.enemy_defense
      end;

      raw_damage:=greatest(
        1,
        round(stats.physical_power*bow_multiplier)::integer-bow_effective_defense+variance
      );
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
        encounter.enemy_defense,
        encounter.enemy_hp_max,
        variance
      );
    end if;

    base_physical_damage:=raw_damage;

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
    raw_damage:=greatest(1,stats.magic_power-floor(encounter.enemy_defense*0.8)::integer+variance);

  elsif p_mode='guard' then
    guard_active:=true;
    action_type_value:='guard';
    player_message:='Персонаж занимает защитную позицию.';

  elsif p_mode in ('support_spell','support_scroll') then
    if p_mode='support_spell' then
      select s.* into spell
      from public.character_spells cs
      join public.spell_definitions s on s.id=cs.spell_id
      where cs.character_id=encounter.character_id
        and cs.spell_id=p_spell_id
        and s.enabled=true;

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
      player_message:=action_label||' создаёт магический щит: -'||support_guard_percent||'% следующего входящего удара.'
        ||case when mana_cost>0 then ' Мана: -'||mana_cost||'.' else '' end;
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

      player_reduction:=0;
      player_vulnerable:=0;
      player_message:=action_label||' снимает негативные эффекты: '||cleansed_count||'.'
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

    if p_mode='support_scroll' then
      if scroll_item.quantity<=1 then
        delete from public.character_items where id=scroll_item.id;
      else
        update public.character_items set quantity=quantity-1 where id=scroll_item.id;
      end if;
    end if;

  elsif p_mode='learned_spell' then
    select s.* into spell
    from public.character_spells cs
    join public.spell_definitions s on s.id=cs.spell_id
    where cs.character_id=encounter.character_id
      and cs.spell_id=p_spell_id
      and s.enabled=true;

    if spell.id is null then raise exception 'SPELL_NOT_LEARNED'; end if;
    if spell.spell_kind not in ('damage','heal') then raise exception 'SPELL_NOT_COMBAT_USABLE'; end if;
    if stats.level<spell.required_level then raise exception 'LEVEL_TOO_LOW'; end if;
    mana_cost:=private.character_effective_spell_mana_cost(encounter.character_id,spell.id);
      if stats.mana_current<mana_cost then raise exception 'NOT_ENOUGH_MANA'; end if;

    player_mana_after:=stats.mana_current-mana_cost;
    action_label:=spell.name;
    action_type_value:='spell_'||spell.slug;

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
      player_message:=spell.name||' восстанавливает '||player_heal||' HP. Мана: -'||mana_cost||'.';
    else
      player_damage_type:=spell.damage_type;
      variance:=private.combat_damage_variance(stats.luck);
      raw_damage:=private.concentrated_spell_direct_value(
        encounter.character_id,
        spell.id,
        greatest(
          1,
          round(stats.magic_power*spell.power_multiplier)::integer
          + spell.flat_power
          - floor(encounter.enemy_defense*0.65)::integer
          + variance
        )
      );

      apply_effect_type:=spell.status_effect_type;
      apply_effect_chance:=spell.status_effect_chance;
      apply_effect_turns:=spell.status_effect_turns;
      apply_effect_potency:=private.concentrated_spell_status_potency(
        encounter.character_id,spell.id,spell.status_effect_type,spell.status_effect_potency
      );
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
          round(stats.magic_power*spell.power_multiplier)::integer
          + spell.flat_power
          - floor(encounter.enemy_defense*0.65)::integer
          + variance
        )
      );

      apply_effect_type:=spell.status_effect_type;
      apply_effect_chance:=spell.status_effect_chance;
      apply_effect_turns:=spell.status_effect_turns;
      apply_effect_potency:=private.concentrated_spell_status_potency(
        encounter.character_id,spell.id,spell.status_effect_type,spell.status_effect_potency
      );
    end if;

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
    select least(75,coalesce(sum(potency) filter(where effect_type='vulnerable'),0))::integer
      into enemy_vulnerable
    from public.combat_status_effects
    where encounter_id=encounter.id and target='enemy';

    if p_mode='physical' then
      type_damage_bonus:=private.character_damage_bonus(encounter.character_id,player_damage_type);
      raw_damage:=greatest(1,round(raw_damage*(100+stats.all_damage_bonus_percent+stats.physical_damage_bonus_percent+type_damage_bonus)/100.0)::integer);
      if encounter.player_counter_bonus_percent>0 then
        raw_damage:=greatest(1,round(raw_damage*(100+encounter.player_counter_bonus_percent)/100.0)::integer);
      end if;
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
            12,
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

    if p_mode='physical' and encounter.player_counter_bonus_percent>0 then
      player_message:=player_message||' Контратака: +'||encounter.player_counter_bonus_percent||'%.';
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

  if enemy_hp_after<=0 then
    return private.finish_combat_victory(
      encounter.id,next_round,player_hp_after,player_mana_after
    );
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

  player_hp_before_enemy:=player_hp_after;

  if enemy_stunned then
    if encounter.enemy_special_charging then
      enemy_message:=encounter.enemy_name||' теряет подготовку «'||encounter.enemy_special_name||'» из-за оглушения.';
      update public.combat_encounters
      set enemy_special_charging=false,enemy_special_started_round=null
      where id=encounter.id;
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
        and mod(next_round,encounter.enemy_special_every_n)=encounter.enemy_special_every_n-1
  then
    special_charge_started:=true;
    update public.combat_encounters
    set enemy_special_charging=true,enemy_special_started_round=next_round
    where id=encounter.id;

    enemy_message:=case
      when btrim(encounter.enemy_special_telegraph_text)<>'' then encounter.enemy_special_telegraph_text
      else encounter.enemy_name||' начинает готовить «'||encounter.enemy_special_name||'». Эффект сработает на следующем ходу.'
    end;

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      encounter.id,next_round,'enemy','special_charge',0,player_hp_after,enemy_hp_after,enemy_message
    );

  else
    special_attack_active:=encounter.enemy_special_charging;

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
          round(enemy_attack_effective*encounter.enemy_special_damage_multiplier)::integer
            -floor(player_defense_value*0.55)::integer+variance
        );
      else
        raw_damage:=greatest(
          1,
          enemy_attack_effective-floor(player_defense_value*0.55)::integer+variance
        );
      end if;

      raw_damage:=greatest(1,round(raw_damage*(100-enemy_reduction)/100.0)::integer);

      resistance:=private.damage_resistance_percent(stats.damage_resistances,enemy_action_damage_type);
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
         and floor(random()*100)::integer
           <least(75,bow_dodge+private.character_religion_modifier_number(encounter.character_id,'evasion_chance'))
      then
        player_dodged:=true;
        enemy_damage:=0;
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
          counter_bonus:=least(
            50,
            25+floor(blocked_damage*100.0/greatest(1,stats.hp_max))::integer
          );
          update public.combat_encounters
          set player_counter_bonus_percent=greatest(player_counter_bonus_percent,counter_bonus),
              player_counter_blocked_damage=greatest(player_counter_blocked_damage,blocked_damage)
          where id=encounter.id;
        end if;
      end if;

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
        ||case when guard_active then ' Защита смягчает удар.' else '' end;

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
              round(enemy_attack_effective*rage_dash_damage_percent/100.0)::integer
                -floor(player_defense_value*0.10)::integer
            );
            rage_dash_damage:=greatest(
              1,
              round(rage_dash_damage*(100-resistance)/100.0*(100+player_vulnerable)/100.0)::integer
            );

            rage_dash_dodged:=false;
            if floor(random()*100)::integer
               <least(75,bow_dodge+private.character_religion_modifier_number(encounter.character_id,'evasion_chance'))
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
      update public.combat_encounters
      set enemy_special_charging=false,enemy_special_started_round=null
      where id=encounter.id;
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
$function$;

CREATE OR REPLACE FUNCTION private.advance_party_combat_round(p_encounter_id uuid, p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  encounter public.party_combat_encounters;
  event_row public.event_boss_events;
  event_special boolean:=false;
  event_phase_bonus integer:=0;
  event_special_multiplier numeric:=1.0;
  target_state public.party_combat_member_states;
  target_stats record;
  next_acted uuid[];
  active_count integer:=0;
  acted_count integer:=0;
  target_id uuid;
  target_name text;
  target_defense integer:=0;
  variance integer:=0;
  raw_damage integer:=0;
  resistance integer:=0;
  enemy_damage integer:=0;
  hp_after integer:=0;
  guard_value integer:=0;
  target_downed boolean:=false;
  all_downed boolean:=false;
  enemy_stunned boolean:=false;
  enemy_reduction integer:=0;
  target_vulnerable integer:=0;
  tick_result jsonb;
  enemy_acted boolean:=false;
  taunt_chance_value integer:=0;
  incoming_reduction integer:=0;
  bloodshed_tick integer:=0;
  target_bow_family text;
  target_bow_dodge integer:=0;
  target_dodged boolean:=false;
begin
  select * into encounter
  from public.party_combat_encounters
  where id=p_encounter_id
  for update;

  if encounter.id is null then raise exception 'PARTY_COMBAT_NOT_FOUND'; end if;
  if encounter.status<>'active' then raise exception 'PARTY_COMBAT_NOT_ACTIVE'; end if;

  select ebe.* into event_row
  from public.party_dungeon_runs pdr
  join public.event_boss_events ebe on ebe.id=pdr.event_boss_id
  where pdr.id=encounter.run_id;

  if event_row.id is not null then
    event_special:=event_row.special_every_n>=2 and mod(encounter.round,event_row.special_every_n)=0;
    event_special_multiplier:=case when event_special then event_row.special_damage_multiplier else 1.0 end;
    event_phase_bonus:=case
      when event_row.phase2_hp_percent>0
       and encounter.enemy_hp_max>0
       and encounter.enemy_hp_current*100<=encounter.enemy_hp_max*event_row.phase2_hp_percent
      then event_row.phase2_attack_bonus_percent
      else 0
    end;
  end if;

  if encounter.enemy_hp_current<=0 then
    perform private.finish_party_combat_victory(encounter.id);
    return jsonb_build_object(
      'status','victory',
      'run_status',(select status from public.party_dungeon_runs where id=encounter.run_id),
      'enemy_hp_current',0
    );
  end if;

  if p_character_id=any(encounter.acted_character_ids) then
    raise exception 'PARTY_ACTION_ALREADY_USED_THIS_ROUND';
  end if;

  next_acted:=array_append(encounter.acted_character_ids,p_character_id);

  update public.party_combat_encounters
  set acted_character_ids=next_acted
  where id=encounter.id;

  select count(*) into active_count
  from public.party_combat_member_states
  where encounter_id=encounter.id
    and not downed;

  select count(*) into acted_count
  from public.party_combat_member_states
  where encounter_id=encounter.id
    and not downed
    and character_id=any(next_acted);

  if active_count=0 or acted_count<active_count then
    return jsonb_build_object(
      'status','active',
      'enemy_hp_current',encounter.enemy_hp_current,
      'enemy_acted',false,
      'round',encounter.round
    );
  end if;

  if encounter.enemy_bloodshed_stacks>0 then
    bloodshed_tick:=private.bloodshed_damage(encounter.enemy_hp_current,encounter.enemy_bloodshed_stacks);

    update public.party_combat_encounters
    set enemy_hp_current=greatest(0,enemy_hp_current-bloodshed_tick),
        enemy_bloodshed_stacks=0
    where id=encounter.id
    returning * into encounter;

    insert into public.party_combat_turns(
      encounter_id,round,actor_type,action_type,damage,message
    )
    values(
      encounter.id,encounter.round,'system','bloodshed_tick',bloodshed_tick,
      'Кровопролитие срабатывает в начале хода врага и наносит '||bloodshed_tick||' урона.'
    );

    if encounter.enemy_hp_current<=0 then
      perform private.finish_party_combat_victory(encounter.id);
      return jsonb_build_object(
        'status','victory',
        'run_status',(select status from public.party_dungeon_runs where id=encounter.run_id),
        'enemy_hp_current',0
      );
    end if;
  end if;

  enemy_stunned:=private.party_status_stunned(encounter.id,'enemy',null);

  if enemy_stunned then
    insert into public.party_combat_turns(
      encounter_id,round,actor_type,action_type,damage,message
    )
    values(
      encounter.id,encounter.round,'system','enemy_stunned',0,
      encounter.enemy_name||' оглушён и пропускает свою атаку.'
    );
  else
    select coalesce(max(taunt_chance),0) into taunt_chance_value
    from public.party_combat_member_states
    where encounter_id=encounter.id and not downed;

    if taunt_chance_value>0 and floor(random()*100)::integer<taunt_chance_value then
      select character_id into target_id
      from public.party_combat_member_states
      where encounter_id=encounter.id and not downed and taunt_chance>0
      order by random() limit 1;
    else
      select character_id into target_id
      from public.party_combat_member_states
      where encounter_id=encounter.id and not downed and taunt_chance=0
      order by random() limit 1;
      if target_id is null then
        select character_id into target_id
        from public.party_combat_member_states
        where encounter_id=encounter.id and not downed
        order by random() limit 1;
      end if;
    end if;

    select * into target_state
    from public.party_combat_member_states
    where encounter_id=encounter.id
      and character_id=target_id
    for update;

    select * into target_stats
    from private.get_character_combat_stats(target_id);

    target_defense:=case
      when encounter.enemy_damage_type in ('slashing','piercing','blunt')
        then private.character_physical_defense(target_stats.level,target_stats.vitality,target_stats.agility)
      else private.character_magic_defense(target_stats.level,target_stats.vitality,target_stats.intellect)
    end;
    target_defense:=greatest(
      0,
      round(
        target_defense
        *(
          100
          +private.character_defense_percent(target_id)
          +case
            when encounter.enemy_damage_type in ('slashing','piercing','blunt') then 0
            else private.character_religion_modifier_number(target_id,'magic_defense_percent')
          end
        )
        /100.0
      )::integer
    );

    variance:=private.combat_damage_variance(0);
    enemy_reduction:=private.party_status_reduction(encounter.id,'enemy',null);
    target_vulnerable:=private.party_status_vulnerability(encounter.id,'member',target_id);

    raw_damage:=greatest(
      1,
      round(encounter.enemy_attack
        *(100+event_phase_bonus)/100.0
        *event_special_multiplier)::integer
        -floor(target_defense*0.55)::integer+variance
    );

    if enemy_reduction>0 then
      raw_damage:=greatest(1,round(raw_damage*(100-enemy_reduction)/100.0)::integer);
    end if;

    resistance:=private.damage_resistance_percent(
      target_stats.damage_resistances,
      encounter.enemy_damage_type
    );

    enemy_damage:=greatest(
      1,
      round(raw_damage*(100-resistance)/100.0)::integer
    );

    if target_vulnerable>0 then
      enemy_damage:=greatest(
        1,
        round(enemy_damage*(100+target_vulnerable)/100.0)::integer
      );
    end if;

    if coalesce(target_stats.low_hp_damage_reduction_percent,0)>0
       and target_state.hp_max>0
       and target_state.hp_current*100<=target_state.hp_max*30
    then
      enemy_damage:=greatest(
        1,
        round(enemy_damage*(100-target_stats.low_hp_damage_reduction_percent)/100.0)::integer
      );
    end if;

    if target_state.hp_max>0
       and target_state.hp_current*100<=target_state.hp_max*50
       and private.character_religion_modifier_number(target_id,'low_hp_50_damage_reduction')>0
    then
      enemy_damage:=greatest(
        1,
        round(
          enemy_damage
          *(100-private.character_religion_modifier_number(target_id,'low_hp_50_damage_reduction'))
          /100.0
        )::integer
      );
    end if;

    if enemy_damage>0
       and private.character_religion_modifier_number(target_id,'incoming_damage_taken_percent')>0
    then
      enemy_damage:=greatest(
        1,
        round(
          enemy_damage
          *(100+private.character_religion_modifier_number(target_id,'incoming_damage_taken_percent'))
          /100.0
        )::integer
      );
    end if;

    target_bow_family:=private.character_weapon_family(target_id);
    target_bow_dodge:=private.bow_dodge_chance(target_state.bow_distance);
    if enemy_damage>0
       and floor(random()*100)::integer
         <least(75,target_bow_dodge+private.character_religion_modifier_number(target_id,'evasion_chance'))
    then
      target_dodged:=true;
      enemy_damage:=0;
    end if;

    guard_value:=target_state.guard_percent;
    if guard_value>0 and enemy_damage>0 then
      enemy_damage:=greatest(
        1,
        ceil(enemy_damage*(100-guard_value)/100.0)::integer
      );
    end if;

    incoming_reduction:=case
      when target_state.incoming_damage_reduction_rounds>0
        then target_state.incoming_damage_reduction_percent
      else 0
    end;
    if incoming_reduction>0 then
      enemy_damage:=greatest(
        1,
        ceil(enemy_damage*(100-incoming_reduction)/100.0)::integer
      );
    end if;

    target_downed:=target_state.hp_current-enemy_damage<=0;
    hp_after:=greatest(1,target_state.hp_current-enemy_damage);

    update public.party_combat_member_states
    set hp_current=hp_after,
        downed=target_downed,
        guard_percent=0,
        taunt_chance=case when target_downed then 0 else taunt_chance end,
        updated_at=now()
    where encounter_id=encounter.id
      and character_id=target_id;

    update public.party_dungeon_run_members
    set dead=case when target_downed then true else dead end,
        dead_at=case when target_downed then coalesce(dead_at,now()) else dead_at end
    where run_id=encounter.run_id and character_id=target_id;

    update public.character_progress
    set hp_current=private.character_effective_hp_to_base(target_id,hp_after),
        hp_regen_anchor_at=now(),
        mana_regen_anchor_at=now(),
        updated_at=now()
    where character_id=target_id;

    select c.name into target_name
    from public.characters c
    where c.id=target_id;

    insert into public.party_combat_turns(
      encounter_id,round,actor_type,target_character_id,
      action_type,damage,message
    )
    values(
      encounter.id,encounter.round,'enemy',target_id,
      'attack_'||encounter.enemy_damage_type,enemy_damage,
      case when target_dodged
        then encounter.enemy_name||' атакует '||target_name||', но цель уклоняется.'
        else encounter.enemy_name||' атакует '||target_name||' и наносит '
          ||enemy_damage||' '||private.damage_type_label(encounter.enemy_damage_type)||' урона.'
      end
      ||case when enemy_reduction>0 then ' Ослабление врага: -'||enemy_reduction||'%.' else '' end
      ||case when target_vulnerable>0 then ' Уязвимость цели: +'||target_vulnerable||'%.' else '' end
      ||case when guard_value>0 then ' Защита уменьшила удар на '||guard_value||'%.' else '' end
      ||case when incoming_reduction>0 then ' Благословение жертвы уменьшило урон на '||incoming_reduction||'%.' else '' end
      ||case when resistance>0 then ' Сопротивление: '||resistance||'%.' when resistance<0 then ' Уязвимость: +'||abs(resistance)||'%.' else '' end
      ||case when target_downed then ' '||target_name||' выведен из строя.' else '' end
    );

    enemy_acted:=true;

    select coalesce(bool_and(downed),false) into all_downed
    from public.party_combat_member_states
    where encounter_id=encounter.id;

    if all_downed then
      perform private.finish_party_combat_defeat(encounter.id);
      return jsonb_build_object('status','defeat','run_status','abandoned');
    end if;
  end if;

  tick_result:=private.tick_party_combat_statuses(encounter.id);

  if coalesce(tick_result->>'status','active')<>'active' then
    return tick_result;
  end if;

  if enemy_acted
     and enemy_damage>0
     and encounter.enemy_on_hit_effect_type is not null
     and encounter.enemy_on_hit_effect_chance>0
     and floor(random()*100)::integer<encounter.enemy_on_hit_effect_chance
  then
    perform private.apply_party_combat_status_effect(
      encounter.id,'member',target_id,
      encounter.enemy_on_hit_effect_type,
      encounter.enemy_on_hit_effect_potency,
      encounter.enemy_on_hit_effect_turns,
      null,encounter.enemy_name
    );

    insert into public.party_combat_turns(
      encounter_id,round,actor_type,target_character_id,
      action_type,damage,message
    )
    values(
      encounter.id,encounter.round,'system',target_id,
      'status_apply',0,
      encounter.enemy_name||' накладывает на '||target_name||' эффект «'
      ||private.combat_effect_label(encounter.enemy_on_hit_effect_type)||'».'
    );
  end if;

  update public.party_combat_member_states
  set incoming_damage_reduction_percent=case
        when incoming_damage_reduction_rounds<=1 then 0
        else incoming_damage_reduction_percent
      end,
      incoming_damage_reduction_rounds=greatest(0,incoming_damage_reduction_rounds-1),
      updated_at=now()
  where encounter_id=encounter.id
    and incoming_damage_reduction_rounds>0;

  if event_row.id is not null
     and event_row.special_every_n>=2
     and mod(encounter.round+1,event_row.special_every_n)=0
  then
    insert into public.party_combat_turns(
      encounter_id,round,actor_type,action_type,damage,message
    ) values(
      encounter.id,encounter.round,'system','event_boss_telegraph',0,
      event_row.name||' готовит тяжёлую особую атаку. На следующем ходу врага защита особенно важна.'
    );
  end if;

  update public.party_combat_encounters
  set round=round+1,
      acted_character_ids='{}'::uuid[]
  where id=encounter.id;

  return jsonb_build_object(
    'status','active',
    'enemy_hp_current',(select enemy_hp_current from public.party_combat_encounters where id=encounter.id),
    'enemy_acted',enemy_acted,
    'enemy_stunned',enemy_stunned,
    'round',encounter.round+1
  );
end;
$function$;

CREATE OR REPLACE FUNCTION private.tick_party_combat_statuses(p_encounter_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  encounter public.party_combat_encounters;
  member_state public.party_combat_member_states;
  stats record;
  enemy_dot integer:=0;
  member_dot integer:=0;
  hp_after integer:=0;
  became_downed boolean:=false;
  all_downed boolean:=false;
  incoming_reduction integer:=0;
begin
  select * into encounter
  from public.party_combat_encounters
  where id=p_encounter_id
  for update;

  if encounter.id is null then raise exception 'PARTY_COMBAT_NOT_FOUND'; end if;
  if encounter.status<>'active' then
    return jsonb_build_object('status',encounter.status);
  end if;

  select coalesce(sum(
    private.status_tick_damage_with_crit(effect_type,potency,encounter.enemy_resistances,source_character_id,false)
  ),0)::integer
  into enemy_dot
  from public.party_combat_status_effects
  where encounter_id=encounter.id
    and target_type='enemy'
    and effect_type in ('burn','bleed','poison');

  if enemy_dot>0 then
    update public.party_combat_encounters
    set enemy_hp_current=greatest(0,enemy_hp_current-enemy_dot)
    where id=encounter.id
    returning * into encounter;

    insert into public.party_combat_turns(
      encounter_id,round,actor_type,action_type,damage,message
    )
    values(
      encounter.id,encounter.round,'system','status_tick',enemy_dot,
      'Ожог, кровотечение или яд наносят противнику '
      ||enemy_dot||' дополнительного урона.'
    );
  end if;

  for member_state in
    select *
    from public.party_combat_member_states
    where encounter_id=encounter.id
      and not downed
    order by character_id
    for update
  loop
    select * into stats
    from private.get_character_combat_stats(member_state.character_id);

    select coalesce(sum(
      private.status_tick_damage_with_crit(effect_type,potency,stats.damage_resistances,source_character_id,false)
    ),0)::integer
    into member_dot
    from public.party_combat_status_effects
    where encounter_id=encounter.id
      and target_type='member'
      and target_character_id=member_state.character_id
      and effect_type in ('burn','bleed','poison');

    if member_dot>0 then
      incoming_reduction:=case
        when member_state.incoming_damage_reduction_rounds>0
          then member_state.incoming_damage_reduction_percent
        else 0
      end;
      if incoming_reduction>0 then
        member_dot:=greatest(1,ceil(member_dot*(100-incoming_reduction)/100.0)::integer);
      end if;
      if private.character_religion_modifier_number(member_state.character_id,'incoming_damage_taken_percent')>0 then
        member_dot:=greatest(
          1,
          round(
            member_dot
            *(100+private.character_religion_modifier_number(member_state.character_id,'incoming_damage_taken_percent'))
            /100.0
          )::integer
        );
      end if;
      became_downed:=member_state.hp_current-member_dot<=0;
      hp_after:=greatest(1,member_state.hp_current-member_dot);

      update public.party_combat_member_states
      set hp_current=hp_after,
          downed=became_downed,
          taunt_chance=case when became_downed then 0 else taunt_chance end,
          updated_at=now()
      where encounter_id=encounter.id
        and character_id=member_state.character_id;

      update public.party_dungeon_run_members
      set dead=case when became_downed then true else dead end,
          dead_at=case when became_downed then coalesce(dead_at,now()) else dead_at end
      where run_id=encounter.run_id and character_id=member_state.character_id;

      update public.character_progress
      set hp_current=private.character_effective_hp_to_base(member_state.character_id,hp_after),
          hp_regen_anchor_at=now(),
          updated_at=now()
      where character_id=member_state.character_id;

      insert into public.party_combat_turns(
        encounter_id,round,actor_type,target_character_id,
        action_type,damage,message
      )
      values(
        encounter.id,encounter.round,'system',member_state.character_id,
        'status_tick',member_dot,
        (select name from public.characters where id=member_state.character_id)
        ||' получает '||member_dot||' урона от негативных эффектов.'
        ||case when incoming_reduction>0 then ' Благословение жертвы уменьшило полученный урон на '||incoming_reduction||'%.' else '' end
        ||case when became_downed then ' Персонаж погиб в этой битве.' else '' end
      );
    end if;
  end loop;

  delete from public.party_combat_status_effects
  where encounter_id=encounter.id
    and remaining_turns<=1;

  update public.party_combat_status_effects
  set remaining_turns=remaining_turns-1,
      updated_at=now()
  where encounter_id=encounter.id
    and remaining_turns>1;

  select * into encounter
  from public.party_combat_encounters
  where id=p_encounter_id;

  if encounter.enemy_hp_current<=0 then
    perform private.finish_party_combat_victory(encounter.id);
    return jsonb_build_object(
      'status','victory',
      'run_status',(select status from public.party_dungeon_runs where id=encounter.run_id)
    );
  end if;

  select coalesce(bool_and(downed),false) into all_downed
  from public.party_combat_member_states
  where encounter_id=encounter.id;

  if all_downed then
    perform private.finish_party_combat_defeat(encounter.id);
    return jsonb_build_object('status','defeat','run_status','abandoned');
  end if;

  return jsonb_build_object('status','active');
end;
$function$;

CREATE OR REPLACE FUNCTION public.perform_party_combat_action(p_character_id uuid, p_encounter_id uuid, p_action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid:=auth.uid();
  encounter public.party_combat_encounters;
  run_row public.party_dungeon_runs;
  member_state public.party_combat_member_states;
  stats record;
  actor_name text;
  damage_type text;
  raw_damage integer:=0;
  dealt_damage integer:=0;
  variance integer:=0;
  resistance integer:=0;
  type_bonus integer:=0;
  total_bonus integer:=0;
  buff_bonus integer:=0;
  actor_reduction integer:=0;
  enemy_vulnerable integer:=0;
  heal_amount integer:=0;
  mana_gain integer:=0;
  guard_value integer:=0;
  action_message text;
  base_physical_damage integer:=0;
  first_strike_multiplier numeric:=1.0;
  first_bonus_multiplier numeric:=1.0;
  first_physical_strike_active boolean:=false;
  katana_rhythm_bonus integer:=0;
  action_type_value text:=p_action;
  bow_family text;
  bow_release boolean:=false;
  bow_multiplier numeric:=1.0;
  bow_penetration integer:=0;
  bow_effective_defense integer:=0;
  bloodshed_chance integer:=0;
  echo_chance integer:=0;
  echo_extra_rolls integer:=0;
  echo_extra_hits integer:=0;
  echo_hit_damage integer:=0;
  echo_damage integer:=0;
  total_physical_hits integer:=1;
  bloodshed_procs integer:=0;
  weapon_stun_proc boolean:=false;
  hit_index integer:=0;
  critical_hit boolean:=false;
  critical_hits integer:=0;
  greatsword_crit_bonus integer:=0;
  echo_single_damage integer:=0;
  white_fang_active boolean:=false;
  white_fang_rupture record;
  white_fang_rupture_damage integer:=0;
  white_fang_target_hp integer:=0;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_action not in ('physical','bow_draw','magic','guard') then
    raise exception 'INVALID_PARTY_COMBAT_ACTION';
  end if;

  if not exists(
    select 1
    from public.characters c
    where c.id=p_character_id
      and c.owner_user_id=caller_id
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
    select 1
    from public.party_dungeon_run_members prm
    where prm.run_id=run_row.id
      and prm.character_id=p_character_id
  ) then raise exception 'NOT_PARTY_DUNGEON_MEMBER'; end if;

  if p_character_id=any(encounter.acted_character_ids) then
    raise exception 'PARTY_ACTION_ALREADY_USED_THIS_ROUND';
  end if;

  select * into member_state
  from public.party_combat_member_states
  where encounter_id=encounter.id
    and character_id=p_character_id
  for update;

  if member_state.character_id is null then raise exception 'PARTY_MEMBER_STATE_NOT_FOUND'; end if;
  if member_state.downed then raise exception 'PARTY_MEMBER_DOWNED'; end if;
  if private.party_status_stunned(encounter.id,'member',p_character_id) then
    raise exception 'PARTY_MEMBER_STUNNED';
  end if;

  select * into stats
  from private.get_character_combat_stats(p_character_id);

  select c.name into actor_name
  from public.characters c
  where c.id=p_character_id;

  bow_family:=private.character_weapon_family(p_character_id);
  bow_penetration:=private.character_bow_penetration(p_character_id);
  bloodshed_chance:=private.character_bloodshed_chance(p_character_id);
  echo_chance:=private.character_echo_strike_chance(p_character_id);
  white_fang_active:=private.character_has_white_fang(p_character_id);

  if p_action<>'physical' or bow_family<>'katana' then
    member_state.katana_rhythm_stacks:=0;
    update public.party_combat_member_states
    set katana_rhythm_stacks=0,updated_at=now()
    where encounter_id=encounter.id and character_id=p_character_id;
  end if;

  if member_state.bow_draw_pending and p_action<>'physical' then
    raise exception 'BOW_FULL_DRAW_LOCKED';
  end if;

  if p_action='bow_draw' then
    if bow_family not in ('short_bow','long_bow') then raise exception 'BOW_NOT_EQUIPPED'; end if;
    if member_state.bow_draw_pending then raise exception 'BOW_ALREADY_DRAWING'; end if;
    member_state.bow_draw_pending:=true;
    update public.party_combat_member_states
    set bow_draw_pending=true,updated_at=now()
    where encounter_id=encounter.id and character_id=p_character_id;
    action_type_value:='bow_draw';
    action_message:=actor_name||' полностью натягивает тетиву. Следующий ход автоматически выпускает стрелу; дистанция зафиксирована.';

  elsif p_action='guard' then
    guard_value:=least(80,greatest(55,55+coalesce(stats.guard_boost_percent,0)));

    update public.party_combat_member_states
    set guard_percent=greatest(guard_percent,guard_value),
        updated_at=now()
    where encounter_id=encounter.id
      and character_id=p_character_id;

    action_message:=actor_name
      ||' занимает защитную стойку. Следующий удар по нему будет уменьшен на '
      ||guard_value||'%.';
  else
    damage_type:=case
      when p_action='physical' then stats.weapon_damage_type
      else stats.magic_damage_type
    end;

    variance:=case when p_action='physical' then private.weapon_family_damage_variance(bow_family,stats.luck) else private.combat_damage_variance(stats.luck) end;

    if p_action='physical' then
      if bow_family in ('short_bow','long_bow') then
        bow_release:=member_state.bow_draw_pending;
        if bow_family='long_bow' and not bow_release then
          raise exception 'BOW_REQUIRES_FULL_DRAW';
        end if;

        bow_multiplier:=private.bow_distance_multiplier(member_state.bow_distance)
          * case when bow_release then 1.60 else 1.00 end;
        bow_effective_defense:=case
          when bow_release then floor(encounter.enemy_defense*(100-bow_penetration)/100.0)::integer
          else encounter.enemy_defense
        end;
        raw_damage:=greatest(
          1,
          round(stats.physical_power*bow_multiplier)::integer-bow_effective_defense+variance
        );
        action_type_value:=case when bow_release then 'bow_full_release' else 'bow_fast' end;

        if bow_release then
          member_state.bow_draw_pending:=false;
          update public.party_combat_member_states
          set bow_draw_pending=false,updated_at=now()
          where encounter_id=encounter.id and character_id=p_character_id;
        end if;
      else
        raw_damage:=private.weapon_family_physical_raw_damage(
          p_character_id,
          stats.physical_power,
          encounter.enemy_defense,
          encounter.enemy_hp_max,
          variance
        );
      end if;
      total_bonus:=coalesce(stats.all_damage_bonus_percent,0)+private.race_party_damage_bonus(p_character_id)
        +coalesce(stats.physical_damage_bonus_percent,0);
    else
      raw_damage:=greatest(
        1,
        stats.magic_power-floor(encounter.enemy_defense*0.65)::integer+variance
      );
      total_bonus:=coalesce(stats.all_damage_bonus_percent,0)+private.race_party_damage_bonus(p_character_id)
        +coalesce(stats.magic_damage_bonus_percent,0);
    end if;

    actor_reduction:=private.party_status_reduction(
      encounter.id,'member',p_character_id
    );
    if actor_reduction>0 then
      raw_damage:=greatest(
        1,
        round(raw_damage*(100-actor_reduction)/100.0)::integer
      );
    end if;

    if p_action='physical' then
      base_physical_damage:=raw_damage;
    end if;

    type_bonus:=private.character_damage_bonus(p_character_id,damage_type);
    total_bonus:=total_bonus+type_bonus;

    if member_state.damage_bonus_hits>0
       and member_state.damage_bonus_percent>0
    then
      buff_bonus:=member_state.damage_bonus_percent;
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

    raw_damage:=greatest(
      1,
      round(raw_damage*(100+total_bonus)/100.0)::integer
    );

    if p_action='physical' and not exists(
      select 1 from public.party_combat_turns pct
      where pct.encounter_id=encounter.id
        and pct.actor_type='player'
        and pct.actor_character_id=p_character_id
        and pct.action_type='physical'
    ) then
      first_strike_multiplier:=private.character_first_physical_strike_multiplier(p_character_id);
      first_bonus_multiplier:=private.character_first_physical_bonus_damage_multiplier(p_character_id);
      if first_strike_multiplier>1.0 or first_bonus_multiplier>1.0 then
        raw_damage:=private.apply_first_physical_strike_multiplier(
          base_physical_damage,
          raw_damage,
          first_strike_multiplier,
          first_bonus_multiplier
        );
        first_physical_strike_active:=true;
      end if;
    end if;

    if p_action='physical' and bow_family='katana' then
      katana_rhythm_bonus:=private.katana_rhythm_bonus_percent(
        member_state.katana_rhythm_stacks
      );
      if katana_rhythm_bonus>0 then
        raw_damage:=greatest(
          1,
          round(raw_damage*(100+katana_rhythm_bonus)/100.0)::integer
        );
      end if;
    end if;

    resistance:=private.damage_resistance_percent(
      encounter.enemy_resistances,
      damage_type
    );
    if p_action='physical' then
      resistance:=private.weapon_family_adjust_resistance(
        bow_family,damage_type,resistance
      );
    end if;
    dealt_damage:=greatest(
      1,
      round(raw_damage*(100-resistance)/100.0)::integer
    );

    enemy_vulnerable:=private.party_status_vulnerability(
      encounter.id,'enemy',null
    );
    if enemy_vulnerable>0 then
      dealt_damage:=greatest(
        1,
        round(dealt_damage*(100+enemy_vulnerable)/100.0)::integer
      );
    end if;

    if p_action='physical' and bow_family='dagger' then
      echo_hit_damage:=dealt_damage;
    end if;

    critical_hit:=false;
    greatsword_crit_bonus:=0;
    if dealt_damage>0 and p_action in ('physical','magic') then
      if p_action='physical' and bow_family='greatsword' then
        greatsword_crit_bonus:=private.greatsword_crit_bonus_percent(
          member_state.greatsword_crit_stacks
        );
        critical_hit:=private.roll_character_critical_with_bonus(
          p_character_id,
          greatsword_crit_bonus
        );
      else
        critical_hit:=private.roll_character_critical(p_character_id);
      end if;

      if critical_hit then
        dealt_damage:=private.apply_critical_damage(
          dealt_damage,
          case when p_action='physical' then 'physical' else 'magic' end,
          true,
          false
        );
        critical_hits:=critical_hits+1;
      end if;

      if p_action='physical' and bow_family='greatsword' then
        member_state.greatsword_crit_stacks:=case
          when critical_hit then 0
          else least(12,member_state.greatsword_crit_stacks+1)
        end;
      end if;
    end if;

    dealt_damage:=least(dealt_damage,encounter.enemy_hp_current);

    if p_action='physical'
       and bow_family='dagger'
       and dealt_damage>0
       and echo_chance>0
       and encounter.enemy_hp_current>dealt_damage
    then
      echo_extra_rolls:=private.roll_echo_strike_extra_hits(echo_chance,50);
      if echo_extra_rolls>0 and echo_hit_damage>0 then
        for hit_index in 1..echo_extra_rolls loop
          exit when encounter.enemy_hp_current<=dealt_damage+echo_damage;
          echo_single_damage:=echo_hit_damage;
          if private.roll_character_critical(p_character_id) then
            echo_single_damage:=private.apply_critical_damage(
              echo_single_damage,'physical',true,false
            );
            critical_hits:=critical_hits+1;
          end if;
          echo_single_damage:=least(
            echo_single_damage,
            greatest(0,encounter.enemy_hp_current-dealt_damage-echo_damage)
          );
          if echo_single_damage<=0 then exit; end if;
          echo_damage:=echo_damage+echo_single_damage;
          echo_extra_hits:=echo_extra_hits+1;
        end loop;
        dealt_damage:=dealt_damage+echo_damage;
        total_physical_hits:=1+echo_extra_hits;
      end if;
    end if;

    update public.party_combat_encounters
    set enemy_hp_current=greatest(0,enemy_hp_current-dealt_damage)
    where id=encounter.id;

    weapon_stun_proc:=false;
    if p_action='physical'
       and dealt_damage>0
       and encounter.enemy_hp_current-dealt_damage>0
       and floor(random()*100)::integer<private.weapon_family_stun_chance(p_character_id,true)
    then
      weapon_stun_proc:=true;
      perform private.apply_party_combat_status_effect(
        encounter.id,'enemy',null,'stun',0,1,p_character_id,'Оглушающий удар'
      );
    end if;

    if p_action='physical' and dealt_damage>0 and bloodshed_chance>0 then
      for hit_index in 1..greatest(1,total_physical_hits) loop
        if floor(random()*100)::integer<bloodshed_chance then
          bloodshed_procs:=bloodshed_procs+1;
        end if;
      end loop;
      if bloodshed_procs>0 then
        encounter.enemy_bloodshed_stacks:=encounter.enemy_bloodshed_stacks+bloodshed_procs;
        update public.party_combat_encounters
        set enemy_bloodshed_stacks=encounter.enemy_bloodshed_stacks
        where id=encounter.id;
      end if;
    end if;

    if coalesce(stats.lifesteal_percent,0)>0 and dealt_damage>0 then
      heal_amount:=least(
        member_state.hp_max-member_state.hp_current,
        floor(dealt_damage*stats.lifesteal_percent/100.0)::integer
      );
    end if;

    if coalesce(stats.mana_on_hit,0)>0 and dealt_damage>0 then
      mana_gain:=least(
        member_state.mana_max-member_state.mana_current,
        stats.mana_on_hit*case when p_action='physical' then greatest(1,total_physical_hits) else 1 end
      );
    end if;

    update public.party_combat_member_states
    set hp_current=least(hp_max,hp_current+heal_amount),
        mana_current=least(mana_max,mana_current+mana_gain),
        damage_bonus_hits=case
          when buff_bonus>0 then greatest(0,damage_bonus_hits-1)
          else damage_bonus_hits
        end,
        damage_bonus_percent=case
          when buff_bonus>0 and damage_bonus_hits<=1 then 0
          else damage_bonus_percent
        end,
        katana_rhythm_stacks=case
          when p_action='physical' and bow_family='katana'
            then least(5,katana_rhythm_stacks+1)
          else 0
        end,
        greatsword_crit_stacks=case
          when p_action='physical' and bow_family='greatsword'
            then member_state.greatsword_crit_stacks
          when bow_family<>'greatsword' then 0
          else greatsword_crit_stacks
        end,
        updated_at=now()
    where encounter_id=encounter.id
      and character_id=p_character_id
    returning * into member_state;

    if heal_amount>0 or mana_gain>0 then
      update public.character_progress
      set hp_current=private.character_effective_hp_to_base(p_character_id,member_state.hp_current),
          mana_current=member_state.mana_current,
          hp_regen_anchor_at=now(),
          mana_regen_anchor_at=now(),
          updated_at=now()
      where character_id=p_character_id;
    end if;

    action_message:=actor_name
      ||case
        when p_action='physical' and bow_family in ('short_bow','long_bow') and bow_release then ' выпускает стрелу после полного натяга'
        when p_action='physical' and bow_family in ('short_bow','long_bow') then ' делает быстрый выстрел'
        when p_action='physical' then ' атакует физически'
        else ' использует врождённую магию'
      end
      ||' и наносит '||dealt_damage||' '
      ||private.damage_type_label(damage_type)||' урона.'
      ||case when type_bonus>0 then ' Бонус типа: +'||type_bonus||'%.' else '' end
      ||case when buff_bonus>0 then ' Боевой фокус: +'||buff_bonus||'%.' else '' end
      ||case when actor_reduction>0 then ' Ослабление: -'||actor_reduction||'%.' else '' end
      ||case when enemy_vulnerable>0 then ' Уязвимость врага: +'||enemy_vulnerable||'%.' else '' end
      ||case
        when resistance>0 then ' Сопротивление врага: '||resistance||'%.'
        when resistance<0 then ' Уязвимость врага: +'||abs(resistance)||'%.'
        else ''
      end
      ||case when heal_amount>0 then ' Вампиризм: +'||heal_amount||' HP.' else '' end
      ||case when mana_gain>0 then ' Восстановлено '||mana_gain||' маны.' else '' end
      ||case when first_physical_strike_active then ' Первый удар катаны: база ×'||trim(to_char(first_strike_multiplier,'FM9990.0'))||', бонусная часть ×'||trim(to_char(first_bonus_multiplier,'FM9990.0'))||'.' else '' end
      ||case when katana_rhythm_bonus>0 then ' Нарастающий ритм: +'||katana_rhythm_bonus||'% урона.' else '' end
      ||case when critical_hits>0 then ' Критических попаданий: '||critical_hits||'.' else '' end
      ||case when echo_extra_hits>0 then ' Эхо ударов: +'||echo_extra_hits||' доп. удар(а/ов), +'||echo_damage||' урона.' else '' end
      ||case when p_action='physical' and encounter.enemy_bloodshed_stacks>0
        then ' Кровопролитие на цели: '||encounter.enemy_bloodshed_stacks||' стак(а/ов).'
        else '' end
      ||case when weapon_stun_proc then ' Оглушение: враг пропустит следующий ход.' else '' end;
  end if;

  if p_action='physical'
     and white_fang_active
     and dealt_damage>0
  then
    select enemy_hp_current
    into white_fang_target_hp
    from public.party_combat_encounters
    where id=encounter.id;

    if white_fang_target_hp>0 then
      if member_state.white_fang_wounds>=3 then
        select * into white_fang_rupture
        from private.white_fang_rupture_roll(p_character_id,encounter.enemy_hp_max);

        white_fang_rupture_damage:=least(
          greatest(0,white_fang_rupture.final_damage),
          white_fang_target_hp
        );

        update public.party_combat_encounters
        set enemy_hp_current=greatest(0,enemy_hp_current-white_fang_rupture_damage)
        where id=encounter.id;

        member_state.white_fang_wounds:=0;
        update public.party_combat_member_states
        set white_fang_wounds=0,updated_at=now()
        where encounter_id=encounter.id and character_id=p_character_id;

        dealt_damage:=dealt_damage+white_fang_rupture_damage;
        action_message:=coalesce(action_message,'')
          ||' Разрыв наносит '||white_fang_rupture_damage||' урона'
          ||case when white_fang_rupture.critical then ' (крит ×1.5).' else '.' end;
      else
        member_state.white_fang_wounds:=least(3,member_state.white_fang_wounds+1);

        update public.party_combat_member_states
        set white_fang_wounds=member_state.white_fang_wounds,updated_at=now()
        where encounter_id=encounter.id and character_id=p_character_id;

        action_message:=coalesce(action_message,'')
          ||' Рваные раны: '||member_state.white_fang_wounds||'/3.';
      end if;
    end if;
  end if;

  insert into public.party_combat_turns(
    encounter_id,round,actor_type,actor_character_id,
    action_type,damage,message
  )
  values(
    encounter.id,encounter.round,'player',p_character_id,
    action_type_value,dealt_damage,action_message
  );

  return private.advance_party_combat_round(encounter.id,p_character_id);
end;
$function$;

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
  if private.party_status_stunned(encounter.id,'member',p_character_id) then
    raise exception 'PARTY_MEMBER_STUNNED';
  end if;

  select s.* into spell
  from public.character_spells cs
  join public.spell_definitions s on s.id=cs.spell_id
  where cs.character_id=p_character_id
    and cs.spell_id=p_spell_id
    and s.enabled=true;

  if spell.id is null then raise exception 'SPELL_NOT_LEARNED'; end if;
  if not private.character_spell_equipped(p_character_id,p_spell_id) then
    raise exception 'SPELL_NOT_IN_LOADOUT';
  end if;
  if spell.spell_kind not in ('damage','heal','guard','cleanse','buff','taunt') then
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
        round(stats.magic_power*spell.power_multiplier)::integer
        +spell.flat_power
        -floor(encounter.enemy_defense*0.65)::integer
        +variance
      )
    );

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

  else
    target_id:=coalesce(p_target_character_id,p_character_id);

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
      set guard_percent=guard_value,updated_at=now()
      where encounter_id=encounter.id and character_id=target_id;

      action_message:=actor_name||' накладывает «'||spell.name||'» на '
        ||target_name||'. Следующий удар будет уменьшен на '
        ||guard_value||'%. Мана: -'||private.character_effective_spell_mana_cost(p_character_id,spell.id)||'.';

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
    case when spell.spell_kind='damage' then null else target_id end,
    'spell_'||spell.slug,dealt_damage,action_message
  );

  return private.advance_party_combat_round(encounter.id,p_character_id);
end;
$function$;

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
    );

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
    );

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
          round(actor.physical_power*bow_multiplier)::integer-bow_effective_defense+variance
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
      raw_damage:=greatest(1,actor.magic_power-target.magic_defense+variance);
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
            round(actor.magic_power*spell.power_multiplier)::integer
              + spell.flat_power
              - floor(target.magic_defense*0.65)::integer
              + variance
          )
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
           <least(75,target_bow_dodge+private.character_religion_modifier_number(target_id,'evasion_chance'))
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
            else least(12,actor.greatsword_crit_stacks+1)
          end;
        end if;
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

  if target.hp_current<=0 then
    perform private.finish_pvp_duel(d.id,actor_id,'knockout');
    return public.get_pvp_duel(d.id);
  end if;

  update public.pvp_duels
  set current_turn_character_id=target_id,
      round=round+1,
      turn_started_at=now(),
      updated_at=now()
  where id=d.id;

  return public.get_pvp_duel(d.id);
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

    select count(*)::integer into player_debuff_count
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
        and hp_percent<=guard_hp;
    end if;

    if not style_mode
       and (encounter.player_counter_bonus_percent<=0 or not allow_physical)
       and not guard_due
       and guard_mode in ('interval','low_hp_or_interval')
       and guard_every>0
       and ((encounter.round+1)%guard_every)=0
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
                  round(stats.magic_power*s.power_multiplier)::integer+s.flat_power
                    -floor(encounter.enemy_defense*0.65)::integer
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
            stats.magic_power-floor(encounter.enemy_defense*0.8)::integer,
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
          case
            when encounter.is_boss then coalesce(rule.boss_priority,100)
            else coalesce(rule.normal_priority,100)
          end asc,
          private.autobattle_estimated_damage(
            private.concentrated_spell_direct_value(
              encounter.character_id,s.id,
              greatest(
                1,
                round(stats.magic_power*s.power_multiplier)::integer+s.flat_power
                  -floor(encounter.enemy_defense*0.65)::integer
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

      -- A configured spell has priority over basic actions.
      if chosen_spell_id is not null then
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

revoke all on function private.combat_encounter_is_strong(uuid) from public, anon, authenticated;
revoke all on function private.party_combat_encounter_is_strong(uuid) from public, anon, authenticated;
revoke all on function public.gm_set_enemy_strong_status(uuid,boolean) from public, anon;
grant execute on function public.gm_set_enemy_strong_status(uuid,boolean) to authenticated;
