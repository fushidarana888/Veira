insert into public.magic_families(slug,name,kind,description,is_system,sort_order)
values('moon','Лунная','school','Лунная энергия, свет луны, циклы ночи и связанная с ними магия.',true,115)
on conflict(slug) do update set
  name=excluded.name,
  kind=excluded.kind,
  description=excluded.description,
  enabled=true,
  is_system=true,
  sort_order=excluded.sort_order,
  updated_at=now();

alter table public.combat_encounters drop constraint if exists combat_encounters_enemy_damage_type_check;
alter table public.combat_encounters add constraint combat_encounters_enemy_damage_type_check
check(enemy_damage_type in ('slashing','piercing','blunt','fire','water','earth','air','lightning','ice','arcane','star','gravity','moon'));

alter table public.combat_encounters drop constraint if exists combat_encounters_player_magic_damage_type_check;
alter table public.combat_encounters add constraint combat_encounters_player_magic_damage_type_check
check(player_magic_damage_type in ('fire','water','earth','air','lightning','ice','arcane','star','gravity','moon'));

alter table public.enemy_templates drop constraint if exists enemy_templates_attack_damage_type_check;
alter table public.enemy_templates add constraint enemy_templates_attack_damage_type_check
check(attack_damage_type in ('slashing','piercing','blunt','fire','water','earth','air','lightning','ice','arcane','star','gravity','moon'));

alter table public.item_definitions drop constraint if exists item_definitions_damage_type_check;
alter table public.item_definitions add constraint item_definitions_damage_type_check
check(damage_type is null or damage_type in ('slashing','piercing','blunt','fire','water','earth','air','lightning','ice','arcane','star','gravity','moon'));

alter table public.pvp_duel_states drop constraint if exists pvp_duel_states_magic_damage_type_check;
alter table public.pvp_duel_states add constraint pvp_duel_states_magic_damage_type_check
check(magic_damage_type in ('fire','water','earth','air','lightning','ice','arcane','star','gravity','moon'));

alter table public.race_definitions drop constraint if exists race_definitions_innate_magic_damage_type_check;
alter table public.race_definitions add constraint race_definitions_innate_magic_damage_type_check
check(innate_magic_damage_type in ('fire','water','earth','air','lightning','ice','arcane','star','gravity','moon'));

alter table public.spell_definitions drop constraint if exists spell_definitions_damage_type_check;
alter table public.spell_definitions add constraint spell_definitions_damage_type_check
check(damage_type is null or damage_type in ('fire','water','earth','air','lightning','ice','arcane','star','gravity','moon'));

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

CREATE OR REPLACE FUNCTION private.damage_bonus_percent(p_bonuses jsonb, p_damage_type text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog'
AS $function$
  select case
    when p_damage_type not in ('slashing','piercing','blunt','fire','water','earth','air','lightning','ice','arcane','star','gravity','moon','arcane','star','gravity','moon') then 0
    when jsonb_typeof(coalesce(p_bonuses,'{}'::jsonb)->p_damage_type)='number'
      then greatest(0,least(75,((coalesce(p_bonuses,'{}'::jsonb)->>p_damage_type)::numeric)::integer))
    else 0
  end;
$function$;

CREATE OR REPLACE FUNCTION private.damage_type_label(p_damage_type text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  select case p_damage_type
    when 'slashing' then 'режущий'
    when 'piercing' then 'колющий'
    when 'blunt' then 'дробящий'
    when 'fire' then 'огненный'
    when 'water' then 'водный'
    when 'earth' then 'земляной'
    when 'air' then 'воздушный'
    when 'lightning' then 'электрический'
    when 'ice' then 'ледяной'
    when 'arcane' then 'арканный'
    when 'star' then 'звёздный'
    when 'gravity' then 'гравитационный'
    when 'moon' then 'лунный'
    else p_damage_type
  end;
$function$;

CREATE OR REPLACE FUNCTION private.get_character_combat_stats(p_character_id uuid)
 RETURNS TABLE(level integer, hp_current integer, hp_max integer, mana_current integer, mana_max integer, strength integer, agility integer, intellect integer, vitality integer, luck integer, physical_power integer, magic_power integer, defense integer, initiative integer, weapon_damage_type text, magic_damage_type text, damage_resistances jsonb, lifesteal_percent integer, mana_on_hit integer, damage_vs_wounded_percent integer, guard_boost_percent integer, all_damage_bonus_percent integer, physical_damage_bonus_percent integer, magic_damage_bonus_percent integer, low_hp_damage_reduction_percent integer, boss_damage_bonus_percent integer)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  with equipped as (
    select ce.slot,idf.*,ci.metadata,ci.enhancement_level,ci.awakening_level
    from public.character_equipment ce
    join public.character_items ci on ci.id=ce.character_item_id
    join public.item_definitions idf on idf.id=ci.item_definition_id
    where ce.character_id=p_character_id
  ),
  mods as (
    select
      coalesce(sum(
        case when jsonb_typeof(stat_modifiers->'strength')='number'
          then (stat_modifiers->>'strength')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'affix_stat_modifiers'->'strength')='number'
          then (metadata->'affix_stat_modifiers'->>'strength')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'religion_stat_modifiers'->'strength')='number'
          then (metadata->'religion_stat_modifiers'->>'strength')::numeric::integer else 0 end
      ),0)::integer strength_mod,
      coalesce(sum(
        case when jsonb_typeof(stat_modifiers->'agility')='number'
          then (stat_modifiers->>'agility')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'affix_stat_modifiers'->'agility')='number'
          then (metadata->'affix_stat_modifiers'->>'agility')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'religion_stat_modifiers'->'agility')='number'
          then (metadata->'religion_stat_modifiers'->>'agility')::numeric::integer else 0 end
      ),0)::integer agility_mod,
      coalesce(sum(
        case when jsonb_typeof(stat_modifiers->'intellect')='number'
          then (stat_modifiers->>'intellect')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'affix_stat_modifiers'->'intellect')='number'
          then (metadata->'affix_stat_modifiers'->>'intellect')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'religion_stat_modifiers'->'intellect')='number'
          then (metadata->'religion_stat_modifiers'->>'intellect')::numeric::integer else 0 end
      ),0)::integer intellect_mod,
      coalesce(sum(
        case when jsonb_typeof(stat_modifiers->'vitality')='number'
          then (stat_modifiers->>'vitality')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'affix_stat_modifiers'->'vitality')='number'
          then (metadata->'affix_stat_modifiers'->>'vitality')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'religion_stat_modifiers'->'vitality')='number'
          then (metadata->'religion_stat_modifiers'->>'vitality')::numeric::integer else 0 end
      ),0)::integer vitality_mod,
      coalesce(sum(
        case when jsonb_typeof(stat_modifiers->'luck')='number'
          then (stat_modifiers->>'luck')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'affix_stat_modifiers'->'luck')='number'
          then (metadata->'affix_stat_modifiers'->>'luck')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'religion_stat_modifiers'->'luck')='number'
          then (metadata->'religion_stat_modifiers'->>'luck')::numeric::integer else 0 end
      ),0)::integer luck_mod,
      coalesce(
        max(damage_type) filter(
          where slot='weapon' and damage_type in ('slashing','piercing','blunt')
        ),
        'blunt'
      )::text weapon_type,
      coalesce(max(weapon_base_damage + case when jsonb_typeof(metadata->'religion_weapon_base_damage_penalty')='number' then (metadata->>'religion_weapon_base_damage_penalty')::numeric::integer else 0 end) filter(where slot='weapon'),0)::integer weapon_base_damage,
      coalesce(max(weapon_scaling) filter(where slot='weapon'),'strength')::text weapon_scaling,
      coalesce(max(enhancement_level) filter(where slot='weapon'),0)::integer weapon_enhancement_level,
      jsonb_build_object(
        'slashing',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'slashing')='number'
            then (damage_resistances->>'slashing')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'slashing')='number'
            then (metadata->'affix_damage_resistances'->>'slashing')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'slashing')='number'
            then (metadata->'religion_damage_resistances'->>'slashing')::numeric::integer else 0 end
        ),0)::integer)),
        'piercing',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'piercing')='number'
            then (damage_resistances->>'piercing')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'piercing')='number'
            then (metadata->'affix_damage_resistances'->>'piercing')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'piercing')='number'
            then (metadata->'religion_damage_resistances'->>'piercing')::numeric::integer else 0 end
        ),0)::integer)),
        'blunt',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'blunt')='number'
            then (damage_resistances->>'blunt')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'blunt')='number'
            then (metadata->'affix_damage_resistances'->>'blunt')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'blunt')='number'
            then (metadata->'religion_damage_resistances'->>'blunt')::numeric::integer else 0 end
        ),0)::integer)),
        'fire',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'fire')='number'
            then (damage_resistances->>'fire')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'fire')='number'
            then (metadata->'affix_damage_resistances'->>'fire')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'fire')='number'
            then (metadata->'religion_damage_resistances'->>'fire')::numeric::integer else 0 end
        ),0)::integer)),
        'water',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'water')='number'
            then (damage_resistances->>'water')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'water')='number'
            then (metadata->'affix_damage_resistances'->>'water')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'water')='number'
            then (metadata->'religion_damage_resistances'->>'water')::numeric::integer else 0 end
        ),0)::integer)),
        'earth',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'earth')='number'
            then (damage_resistances->>'earth')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'earth')='number'
            then (metadata->'affix_damage_resistances'->>'earth')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'earth')='number'
            then (metadata->'religion_damage_resistances'->>'earth')::numeric::integer else 0 end
        ),0)::integer)),
        'air',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'air')='number'
            then (damage_resistances->>'air')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'air')='number'
            then (metadata->'affix_damage_resistances'->>'air')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'air')='number'
            then (metadata->'religion_damage_resistances'->>'air')::numeric::integer else 0 end
        ),0)::integer)),
        'lightning',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'lightning')='number'
            then (damage_resistances->>'lightning')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'lightning')='number'
            then (metadata->'affix_damage_resistances'->>'lightning')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'lightning')='number'
            then (metadata->'religion_damage_resistances'->>'lightning')::numeric::integer else 0 end
        ),0)::integer)),
        'ice',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'ice')='number'
            then (damage_resistances->>'ice')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'ice')='number'
            then (metadata->'affix_damage_resistances'->>'ice')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'ice')='number'
            then (metadata->'religion_damage_resistances'->>'ice')::numeric::integer else 0 end
        ),0)::integer)),
        'arcane',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'arcane')='number'
            then (damage_resistances->>'arcane')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'arcane')='number'
            then (metadata->'affix_damage_resistances'->>'arcane')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'arcane')='number'
            then (metadata->'religion_damage_resistances'->>'arcane')::numeric::integer else 0 end
        ),0)::integer)),
        'star',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'star')='number'
            then (damage_resistances->>'star')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'star')='number'
            then (metadata->'affix_damage_resistances'->>'star')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'star')='number'
            then (metadata->'religion_damage_resistances'->>'star')::numeric::integer else 0 end
        ),0)::integer)),
        'gravity',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'gravity')='number'
            then (damage_resistances->>'gravity')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'gravity')='number'
            then (metadata->'affix_damage_resistances'->>'gravity')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'gravity')='number'
            then (metadata->'religion_damage_resistances'->>'gravity')::numeric::integer else 0 end
        ),0)::integer)),
        'moon',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'moon')='number'
            then (damage_resistances->>'moon')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'moon')='number'
            then (metadata->'affix_damage_resistances'->>'moon')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'moon')='number'
            then (metadata->'religion_damage_resistances'->>'moon')::numeric::integer else 0 end
        ),0)::integer))
      ) resistances,
      least(50,coalesce(sum(
        case when unique_effect_type='lifesteal' then unique_effect_value + case when slot='weapon' then awakening_level else 0 end else 0 end
        + case when jsonb_typeof(metadata->'affix_unique_effects'->'lifesteal')='number'
          then (metadata->'affix_unique_effects'->>'lifesteal')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'religion_unique_effects'->'lifesteal')='number'
          then (metadata->'religion_unique_effects'->>'lifesteal')::numeric::integer else 0 end
      ),0))::integer item_lifesteal,
      least(30,coalesce(sum(
        case when unique_effect_type='mana_on_hit' then unique_effect_value + case when slot='weapon' then awakening_level else 0 end else 0 end
        + case when jsonb_typeof(metadata->'affix_unique_effects'->'mana_on_hit')='number'
          then (metadata->'affix_unique_effects'->>'mana_on_hit')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'religion_unique_effects'->'mana_on_hit')='number'
          then (metadata->'religion_unique_effects'->>'mana_on_hit')::numeric::integer else 0 end
      ),0))::integer item_mana_hit,
      least(75,coalesce(sum(
        case when unique_effect_type='damage_vs_wounded' then unique_effect_value + case when slot='weapon' then awakening_level else 0 end else 0 end
        + case when jsonb_typeof(metadata->'affix_unique_effects'->'damage_vs_wounded')='number'
          then (metadata->'affix_unique_effects'->>'damage_vs_wounded')::numeric::integer else 0 end
      ),0))::integer item_wounded_bonus,
      least(25,coalesce(sum(
        case when unique_effect_type='guard_boost' then unique_effect_value + case when slot='weapon' then awakening_level else 0 end else 0 end
        + case when jsonb_typeof(metadata->'affix_unique_effects'->'guard_boost')='number'
          then (metadata->'affix_unique_effects'->>'guard_boost')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'religion_unique_effects'->'guard_boost')='number'
          then (metadata->'religion_unique_effects'->>'guard_boost')::numeric::integer else 0 end
      ),0))::integer item_guard_bonus,
      least(50,coalesce(sum(
        case when jsonb_typeof(metadata->'affix_unique_effects'->'all_damage_bonus')='number'
          then (metadata->'affix_unique_effects'->>'all_damage_bonus')::numeric::integer else 0 end
      ),0))::integer item_all_damage_bonus,
      least(75,coalesce(sum(
        case when jsonb_typeof(metadata->'affix_unique_effects'->'physical_damage_bonus')='number'
          then (metadata->'affix_unique_effects'->>'physical_damage_bonus')::numeric::integer else 0 end
        + case when slot='weapon'
            and coalesce(unique_effect_type,'')=''
            and coalesce(echo_strike_chance_percent,0)=0
            and coalesce(bloodshed_chance_percent,0)=0
            and jsonb_typeof(stat_modifiers->'first_physical_strike_multiplier') is distinct from 'number'
          then awakening_level else 0 end
      ),0))::integer item_physical_damage_bonus,
      least(75,coalesce(sum(
        case when jsonb_typeof(metadata->'affix_unique_effects'->'magic_damage_bonus')='number'
          then (metadata->'affix_unique_effects'->>'magic_damage_bonus')::numeric::integer else 0 end
      ),0))::integer item_magic_damage_bonus,
      least(50,coalesce(sum(
        case when jsonb_typeof(metadata->'affix_unique_effects'->'low_hp_damage_reduction')='number'
          then (metadata->'affix_unique_effects'->>'low_hp_damage_reduction')::numeric::integer else 0 end
      ),0))::integer item_low_hp_reduction,
      least(75,coalesce(sum(
        case when jsonb_typeof(metadata->'affix_unique_effects'->'boss_damage_bonus')='number'
          then (metadata->'affix_unique_effects'->>'boss_damage_bonus')::numeric::integer else 0 end
      ),0))::integer item_boss_damage_bonus
    from equipped
  ),
  religion as (
    select private.character_religion_modifiers(p_character_id) mods
  ),
  base as (
    select
      cp.level,cp.hp_current,cp.hp_max,cp.mana_current,cp.mana_max,
      cp.strength+m.strength_mod+case when jsonb_typeof(rd.stat_modifiers->'strength')='number' then (rd.stat_modifiers->>'strength')::numeric::integer else 0 end+coalesce((rm.mods->>'strength')::integer,0) strength,
      cp.agility+m.agility_mod+case when jsonb_typeof(rd.stat_modifiers->'agility')='number' then (rd.stat_modifiers->>'agility')::numeric::integer else 0 end+coalesce((rm.mods->>'agility')::integer,0) agility,
      cp.intellect+m.intellect_mod+case when jsonb_typeof(rd.stat_modifiers->'intellect')='number' then (rd.stat_modifiers->>'intellect')::numeric::integer else 0 end+coalesce((rm.mods->>'intellect')::integer,0) intellect,
      cp.vitality+m.vitality_mod+case when jsonb_typeof(rd.stat_modifiers->'vitality')='number' then (rd.stat_modifiers->>'vitality')::numeric::integer else 0 end+coalesce((rm.mods->>'vitality')::integer,0) vitality,
      cp.luck+m.luck_mod+case when jsonb_typeof(rd.stat_modifiers->'luck')='number' then (rd.stat_modifiers->>'luck')::numeric::integer else 0 end+coalesce((rm.mods->>'luck')::integer,0) luck,
      m.weapon_type,
      m.weapon_base_damage,
      m.weapon_scaling,
      m.weapon_enhancement_level,
      coalesce(rd.innate_magic_damage_type,'fire')::text magic_type,
      private.merge_numeric_json(
        private.merge_numeric_json(
          m.resistances,
          coalesce(rd.damage_resistances,'{}'::jsonb),
          -75,75
        ),
        coalesce(rm.mods->'resistances','{}'::jsonb),
        -75,75
      ) resistances,
      least(50,m.item_lifesteal + case when rd.passive_type='lifesteal' then rd.passive_value else 0 end + coalesce((rm.mods->>'lifesteal')::integer,0)) lifesteal,
      least(30,m.item_mana_hit + case when rd.passive_type='mana_on_hit' then rd.passive_value else 0 end + coalesce((rm.mods->>'mana_on_hit')::integer,0)) mana_hit,
      least(75,m.item_wounded_bonus + case when rd.passive_type='damage_vs_wounded' then rd.passive_value else 0 end) wounded_bonus,
      least(25,m.item_guard_bonus + case when rd.passive_type='guard_boost' then rd.passive_value else 0 end + coalesce((rm.mods->>'guard_boost')::integer,0)) guard_bonus,
      least(50,m.item_all_damage_bonus + case when rd.passive_type='all_damage_bonus' then rd.passive_value else 0 end + coalesce((rm.mods->>'all_damage_bonus')::integer,0) + private.race_low_hp_trait_bonus(p_character_id,'low_hp_all_damage_bonus',cp.hp_current,cp.hp_max) + private.character_equipment_set_low_hp_damage_bonus(p_character_id,cp.hp_current,cp.hp_max)) all_damage_bonus,
      least(75,m.item_physical_damage_bonus + case when rd.passive_type='physical_damage_bonus' then rd.passive_value else 0 end + coalesce((rm.mods->>'physical_damage_bonus')::integer,0) + private.race_weapon_family_damage_bonus(p_character_id) + private.race_low_hp_trait_bonus(p_character_id,'low_hp_physical_damage_bonus',cp.hp_current,cp.hp_max) + private.character_equipment_set_static_bonus(p_character_id,'physical_damage_bonus')) physical_damage_bonus,
      least(75,m.item_magic_damage_bonus + case when rd.passive_type='magic_damage_bonus' then rd.passive_value else 0 end + coalesce((rm.mods->>'magic_damage_bonus')::integer,0)) magic_damage_bonus,
      least(50,m.item_low_hp_reduction + case when rd.passive_type='low_hp_damage_reduction' then rd.passive_value else 0 end + coalesce((rm.mods->>'low_hp_damage_reduction')::integer,0)) low_hp_reduction,
      least(75,m.item_boss_damage_bonus + case when rd.passive_type='boss_damage_bonus' then rd.passive_value else 0 end + coalesce((rm.mods->>'boss_damage_bonus')::integer,0)) boss_damage_bonus
    from public.character_progress cp
    join public.characters c on c.id=cp.character_id
    left join public.race_definitions rd on rd.id=c.race_id
    cross join mods m
    cross join religion rm
    where cp.character_id=p_character_id
  )
  select
    b.level,least(greatest(1,round(b.hp_max*(100+private.character_max_hp_percent(p_character_id))/100.0)::integer),greatest(1,round(b.hp_current*(100+private.character_max_hp_percent(p_character_id))/100.0)::integer)),greatest(1,round(b.hp_max*(100+private.character_max_hp_percent(p_character_id))/100.0)::integer),b.mana_current,b.mana_max,
    b.strength,b.agility,b.intellect,b.vitality,b.luck,
    private.physical_power_from_enhanced_weapon(
      b.strength,b.agility,b.level,b.weapon_base_damage,b.weapon_scaling,b.weapon_enhancement_level
    ),
    (b.intellect*3+b.luck+b.level*2)::integer,
    greatest(0,round(private.character_physical_defense(
      b.level,b.vitality,b.agility
    )*(100+private.character_defense_percent(p_character_id)+private.race_trait_number(p_character_id,'physical_defense_percent'))/100.0)::integer),
    (b.agility*2+b.luck+private.race_trait_number(p_character_id,'initiative_flat'))::integer,
    b.weapon_type,b.magic_type,b.resistances,
    b.lifesteal,b.mana_hit,b.wounded_bonus,b.guard_bonus,
    b.all_damage_bonus,b.physical_damage_bonus,b.magic_damage_bonus,
    b.low_hp_reduction,b.boss_damage_bonus
  from base b;
$function$;

CREATE OR REPLACE FUNCTION public.gm_save_enemy_template(p_id uuid, p_slug text, p_name text, p_description text, p_enabled boolean, p_terrain_type text, p_min_danger smallint, p_max_danger smallint, p_is_boss boolean, p_weight integer, p_attack_damage_type text, p_damage_resistances jsonb, p_hp_multiplier numeric, p_attack_multiplier numeric, p_defense_multiplier numeric, p_initiative_multiplier numeric, p_on_hit_effect_type text, p_on_hit_effect_chance smallint, p_on_hit_effect_turns smallint, p_on_hit_effect_potency integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  saved_id uuid;
  k text;
  v jsonb;
begin
  if not private.is_gm(auth.uid()) then raise exception 'GM_REQUIRED'; end if;

  if btrim(coalesce(p_slug,''))='' or btrim(coalesce(p_name,''))='' then
    raise exception 'ENEMY_NAME_AND_SLUG_REQUIRED';
  end if;

  if p_terrain_type is not null and p_terrain_type not in (
    'plains','forest','swamp','desert','mountains','tundra','coast','sea','riverlands'
  ) then raise exception 'INVALID_TERRAIN'; end if;

  if p_min_danger not between 0 and 10 or p_max_danger not between 0 and 10
     or p_min_danger>p_max_danger then raise exception 'INVALID_DANGER_RANGE'; end if;

  if p_attack_damage_type not in (
    'slashing','piercing','blunt','fire','water','earth','air','lightning','ice','arcane','star','gravity','moon','arcane','star','gravity','moon'
  ) then raise exception 'INVALID_DAMAGE_TYPE'; end if;

  if p_on_hit_effect_type is not null
     and p_on_hit_effect_type not in ('burn','bleed','poison','chill','stun','weaken','vulnerable')
  then raise exception 'INVALID_STATUS_EFFECT'; end if;

  if p_weight not between 1 and 1000
     or p_on_hit_effect_chance not between 0 and 100
     or p_on_hit_effect_turns not between 0 and 10
     or p_on_hit_effect_potency<0
  then raise exception 'INVALID_ENEMY_VALUES'; end if;

  if jsonb_typeof(coalesce(p_damage_resistances,'{}'::jsonb))<>'object' then
    raise exception 'INVALID_RESISTANCES';
  end if;

  for k,v in select * from jsonb_each(coalesce(p_damage_resistances,'{}'::jsonb))
  loop
    if k not in ('slashing','piercing','blunt','fire','water','earth','air','lightning','ice','arcane','star','gravity','moon','arcane','star','gravity','moon')
       or jsonb_typeof(v)<>'number'
       or (v::text)::numeric < -75
       or (v::text)::numeric > 75
    then raise exception 'INVALID_RESISTANCE_VALUE'; end if;
  end loop;

  if p_on_hit_effect_type is null then
    p_on_hit_effect_chance:=0;
    p_on_hit_effect_turns:=0;
    p_on_hit_effect_potency:=0;
  end if;

  if p_id is null then
    insert into public.enemy_templates(
      slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,
      attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,
      defense_multiplier,initiative_multiplier,
      on_hit_effect_type,on_hit_effect_chance,on_hit_effect_turns,on_hit_effect_potency
    )
    values(
      btrim(p_slug),btrim(p_name),coalesce(p_description,''),coalesce(p_enabled,true),
      p_terrain_type,p_min_danger,p_max_danger,coalesce(p_is_boss,false),p_weight,
      p_attack_damage_type,coalesce(p_damage_resistances,'{}'::jsonb),
      p_hp_multiplier,p_attack_multiplier,p_defense_multiplier,p_initiative_multiplier,
      p_on_hit_effect_type,p_on_hit_effect_chance,p_on_hit_effect_turns,p_on_hit_effect_potency
    )
    returning id into saved_id;
  else
    update public.enemy_templates
    set slug=btrim(p_slug),name=btrim(p_name),description=coalesce(p_description,''),
        enabled=coalesce(p_enabled,true),terrain_type=p_terrain_type,
        min_danger=p_min_danger,max_danger=p_max_danger,is_boss=coalesce(p_is_boss,false),
        weight=p_weight,attack_damage_type=p_attack_damage_type,
        damage_resistances=coalesce(p_damage_resistances,'{}'::jsonb),
        hp_multiplier=p_hp_multiplier,attack_multiplier=p_attack_multiplier,
        defense_multiplier=p_defense_multiplier,initiative_multiplier=p_initiative_multiplier,
        on_hit_effect_type=p_on_hit_effect_type,
        on_hit_effect_chance=p_on_hit_effect_chance,
        on_hit_effect_turns=p_on_hit_effect_turns,
        on_hit_effect_potency=p_on_hit_effect_potency,
        updated_at=now()
    where id=p_id
    returning id into saved_id;

    if saved_id is null then raise exception 'ENEMY_TEMPLATE_NOT_FOUND'; end if;
  end if;

  insert into public.gm_audit_log(actor_user_id,action,target_type,target_id,details)
  values(
    auth.uid(),
    case when p_id is null then 'enemy_template.create' else 'enemy_template.update' end,
    'enemy_template',saved_id::text,
    jsonb_build_object(
      'name',p_name,'attack_damage_type',p_attack_damage_type,'is_boss',p_is_boss,
      'on_hit_effect_type',p_on_hit_effect_type,'on_hit_effect_chance',p_on_hit_effect_chance
    )
  );

  return saved_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.gm_save_equipment_affix(p_id uuid, p_slug text, p_name text, p_description text, p_enabled boolean, p_min_rarity_rank smallint, p_max_rarity_rank smallint, p_weight integer, p_allowed_categories text[], p_allowed_equip_groups text[], p_stat_modifiers jsonb, p_damage_resistances jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  saved_id uuid;
  k text;
  v jsonb;
begin
  if not private.is_gm(auth.uid()) then raise exception 'GM_REQUIRED'; end if;

  if btrim(coalesce(p_slug,''))='' or btrim(coalesce(p_name,''))='' then
    raise exception 'AFFIX_NAME_AND_SLUG_REQUIRED';
  end if;

  if p_min_rarity_rank not between 1 and 6 or p_max_rarity_rank not between 1 and 6
     or p_min_rarity_rank>p_max_rarity_rank or p_weight<1
  then raise exception 'INVALID_AFFIX_VALUES'; end if;

  if coalesce(cardinality(p_allowed_categories),0)=0 then
    raise exception 'AFFIX_CATEGORY_REQUIRED';
  end if;

  if exists(
    select 1 from unnest(p_allowed_categories) c
    where c not in ('weapon','armor','accessory')
  ) then raise exception 'INVALID_AFFIX_CATEGORY'; end if;

  if exists(
    select 1 from unnest(coalesce(p_allowed_equip_groups,'{}'::text[])) g
    where g not in ('weapon','offhand','head','chest','hands','legs','feet','accessory')
  ) then raise exception 'INVALID_AFFIX_EQUIP_GROUP'; end if;

  for k,v in select * from jsonb_each(coalesce(p_damage_resistances,'{}'::jsonb))
  loop
    if k not in ('slashing','piercing','blunt','fire','water','earth','air','lightning','ice','arcane','star','gravity','moon','arcane','star','gravity','moon')
       or jsonb_typeof(v)<>'number'
       or (v::text)::numeric < -75
       or (v::text)::numeric > 75
    then raise exception 'INVALID_RESISTANCE_VALUE'; end if;
  end loop;

  if p_id is null then
    insert into public.equipment_affixes(
      slug,name,description,enabled,min_rarity_rank,max_rarity_rank,weight,
      allowed_categories,allowed_equip_groups,stat_modifiers,damage_resistances
    )
    values(
      btrim(p_slug),btrim(p_name),coalesce(p_description,''),coalesce(p_enabled,true),
      p_min_rarity_rank,p_max_rarity_rank,p_weight,p_allowed_categories,
      coalesce(p_allowed_equip_groups,'{}'::text[]),
      coalesce(p_stat_modifiers,'{}'::jsonb),coalesce(p_damage_resistances,'{}'::jsonb)
    )
    returning id into saved_id;
  else
    update public.equipment_affixes
    set slug=btrim(p_slug),name=btrim(p_name),description=coalesce(p_description,''),
        enabled=coalesce(p_enabled,true),min_rarity_rank=p_min_rarity_rank,
        max_rarity_rank=p_max_rarity_rank,weight=p_weight,
        allowed_categories=p_allowed_categories,
        allowed_equip_groups=coalesce(p_allowed_equip_groups,'{}'::text[]),
        stat_modifiers=coalesce(p_stat_modifiers,'{}'::jsonb),
        damage_resistances=coalesce(p_damage_resistances,'{}'::jsonb),
        updated_at=now()
    where id=p_id
    returning id into saved_id;

    if saved_id is null then raise exception 'AFFIX_NOT_FOUND'; end if;
  end if;

  insert into public.gm_audit_log(actor_user_id,action,target_type,target_id,details)
  values(
    auth.uid(),
    case when p_id is null then 'equipment_affix.create' else 'equipment_affix.update' end,
    'equipment_affix',saved_id::text,
    jsonb_build_object('name',p_name,'rarity',jsonb_build_array(p_min_rarity_rank,p_max_rarity_rank))
  );

  return saved_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.gm_save_equipment_affix_v2(p_id uuid, p_slug text, p_name text, p_description text, p_enabled boolean, p_min_rarity_rank smallint, p_max_rarity_rank smallint, p_weight integer, p_allowed_categories text[], p_allowed_equip_groups text[], p_stat_modifiers jsonb, p_damage_resistances jsonb, p_unique_effect_type text, p_unique_effect_value integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  saved_id uuid;
  k text;
  v jsonb;
begin
  if not private.is_gm(auth.uid()) then raise exception 'GM_REQUIRED'; end if;

  if btrim(coalesce(p_slug,''))='' or btrim(coalesce(p_name,''))='' then
    raise exception 'AFFIX_NAME_AND_SLUG_REQUIRED';
  end if;

  if p_min_rarity_rank not between 1 and 6 or p_max_rarity_rank not between 1 and 6
     or p_min_rarity_rank>p_max_rarity_rank or p_weight<1
  then raise exception 'INVALID_AFFIX_VALUES'; end if;

  if coalesce(cardinality(p_allowed_categories),0)=0 then
    raise exception 'AFFIX_CATEGORY_REQUIRED';
  end if;

  if exists(
    select 1 from unnest(p_allowed_categories) c
    where c not in ('weapon','armor','accessory')
  ) then raise exception 'INVALID_AFFIX_CATEGORY'; end if;

  if exists(
    select 1 from unnest(coalesce(p_allowed_equip_groups,'{}'::text[])) g
    where g not in ('weapon','offhand','head','chest','hands','legs','feet','accessory')
  ) then raise exception 'INVALID_AFFIX_EQUIP_GROUP'; end if;

  for k,v in select * from jsonb_each(coalesce(p_damage_resistances,'{}'::jsonb))
  loop
    if k not in ('slashing','piercing','blunt','fire','water','earth','air','lightning','ice','arcane','star','gravity','moon','arcane','star','gravity','moon')
       or jsonb_typeof(v)<>'number'
       or (v::text)::numeric < -75
       or (v::text)::numeric > 75
    then raise exception 'INVALID_RESISTANCE_VALUE'; end if;
  end loop;

  if p_unique_effect_type is not null
     and p_unique_effect_type not in (
       'lifesteal','mana_on_hit','damage_vs_wounded','guard_boost',
       'physical_damage_bonus','magic_damage_bonus','all_damage_bonus',
       'low_hp_damage_reduction','boss_damage_bonus'
     )
  then raise exception 'INVALID_AFFIX_UNIQUE_EFFECT'; end if;

  if p_unique_effect_value not between 0 and 100 then
    raise exception 'INVALID_AFFIX_UNIQUE_EFFECT_VALUE';
  end if;

  if p_unique_effect_type is null then p_unique_effect_value:=0; end if;

  if p_id is null then
    insert into public.equipment_affixes(
      slug,name,description,enabled,min_rarity_rank,max_rarity_rank,weight,
      allowed_categories,allowed_equip_groups,stat_modifiers,damage_resistances,
      unique_effect_type,unique_effect_value
    )
    values(
      btrim(p_slug),btrim(p_name),coalesce(p_description,''),coalesce(p_enabled,true),
      p_min_rarity_rank,p_max_rarity_rank,p_weight,p_allowed_categories,
      coalesce(p_allowed_equip_groups,'{}'::text[]),
      coalesce(p_stat_modifiers,'{}'::jsonb),coalesce(p_damage_resistances,'{}'::jsonb),
      p_unique_effect_type,p_unique_effect_value
    )
    returning id into saved_id;
  else
    update public.equipment_affixes
    set slug=btrim(p_slug),name=btrim(p_name),description=coalesce(p_description,''),
        enabled=coalesce(p_enabled,true),min_rarity_rank=p_min_rarity_rank,
        max_rarity_rank=p_max_rarity_rank,weight=p_weight,
        allowed_categories=p_allowed_categories,
        allowed_equip_groups=coalesce(p_allowed_equip_groups,'{}'::text[]),
        stat_modifiers=coalesce(p_stat_modifiers,'{}'::jsonb),
        damage_resistances=coalesce(p_damage_resistances,'{}'::jsonb),
        unique_effect_type=p_unique_effect_type,
        unique_effect_value=p_unique_effect_value,
        updated_at=now()
    where id=p_id
    returning id into saved_id;

    if saved_id is null then raise exception 'AFFIX_NOT_FOUND'; end if;
  end if;

  insert into public.gm_audit_log(actor_user_id,action,target_type,target_id,details)
  values(
    auth.uid(),
    case when p_id is null then 'equipment_affix.create' else 'equipment_affix.update' end,
    'equipment_affix',saved_id::text,
    jsonb_build_object(
      'name',p_name,
      'rarity',jsonb_build_array(p_min_rarity_rank,p_max_rarity_rank),
      'unique_effect_type',p_unique_effect_type,
      'unique_effect_value',p_unique_effect_value
    )
  );

  return saved_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.gm_save_item_definition(p_id uuid, p_slug text, p_name text, p_description text, p_category text, p_rarity text, p_equip_group text, p_stackable boolean, p_max_stack integer, p_stat_modifiers jsonb, p_heal_amount integer, p_base_value bigint, p_required_level integer, p_shop_tier smallint, p_shop_price bigint, p_shop_enabled boolean, p_damage_type text, p_damage_resistances jsonb, p_scroll_spell_id uuid, p_scroll_mode text, p_unique_property_name text, p_unique_property_description text, p_unique_effect_type text, p_unique_effect_value integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  saved_id uuid;
  effects_value jsonb:='[]'::jsonb;
  k text;
  v jsonb;
begin
  if not private.is_gm(auth.uid()) then raise exception 'GM_REQUIRED'; end if;

  if btrim(coalesce(p_slug,''))='' or btrim(coalesce(p_name,''))='' then
    raise exception 'ITEM_NAME_AND_SLUG_REQUIRED';
  end if;

  if p_category not in ('weapon','armor','accessory','consumable','material','quest') then
    raise exception 'INVALID_ITEM_CATEGORY';
  end if;

  if p_rarity not in ('common','uncommon','rare','epic','legendary','unique') then
    raise exception 'INVALID_ITEM_RARITY';
  end if;

  if p_equip_group is not null and p_equip_group not in (
    'weapon','offhand','head','chest','hands','legs','feet','accessory'
  ) then raise exception 'INVALID_EQUIP_GROUP'; end if;

  if p_damage_type is not null and p_damage_type not in (
    'slashing','piercing','blunt','fire','water','earth','air','lightning','ice','arcane','star','gravity','moon','arcane','star','gravity','moon'
  ) then raise exception 'INVALID_DAMAGE_TYPE'; end if;

  if p_scroll_mode is not null and p_scroll_mode not in ('learn','cast') then
    raise exception 'INVALID_SCROLL_MODE';
  end if;

  if p_scroll_mode is not null and p_scroll_spell_id is null then
    raise exception 'SCROLL_SPELL_REQUIRED';
  end if;

  if p_unique_effect_type is not null
     and p_unique_effect_type not in (
       'lifesteal','mana_on_hit','damage_vs_wounded','guard_boost','taunt'
     )
  then raise exception 'INVALID_UNIQUE_EFFECT'; end if;

  if p_unique_effect_value<0 or p_unique_effect_value>100 then
    raise exception 'INVALID_UNIQUE_EFFECT_VALUE';
  end if;

  if p_unique_effect_type is null then
    p_unique_effect_value:=0;
    if btrim(coalesce(p_unique_property_name,''))='' and not (
      (jsonb_typeof(coalesce(p_stat_modifiers,'{}'::jsonb)->'first_physical_strike_multiplier')='number'
       and (coalesce(p_stat_modifiers,'{}'::jsonb)->>'first_physical_strike_multiplier')::numeric>1)
      or
      (jsonb_typeof(coalesce(p_stat_modifiers,'{}'::jsonb)->'first_physical_bonus_damage_multiplier')='number'
       and (coalesce(p_stat_modifiers,'{}'::jsonb)->>'first_physical_bonus_damage_multiplier')::numeric>1)
      or
      (p_id is not null and exists(
        select 1 from public.item_definitions existing
        where existing.id=p_id and existing.echo_strike_chance_percent>0
      ))
    ) then
      p_unique_property_name:=null;
      p_unique_property_description:='';
    end if;
  end if;

  if p_max_stack<1 or p_required_level<1 or p_shop_tier not between 0 and 10
     or p_shop_price<0 or p_base_value<0 or p_heal_amount<0
  then raise exception 'INVALID_ITEM_VALUES'; end if;

  if jsonb_typeof(coalesce(p_stat_modifiers,'{}'::jsonb))<>'object'
     or jsonb_typeof(coalesce(p_damage_resistances,'{}'::jsonb))<>'object'
  then raise exception 'INVALID_ITEM_JSON'; end if;

  for k,v in select * from jsonb_each(coalesce(p_damage_resistances,'{}'::jsonb))
  loop
    if k not in ('slashing','piercing','blunt','fire','water','earth','air','lightning','ice','arcane','star','gravity','moon','arcane','star','gravity','moon')
       or jsonb_typeof(v)<>'number'
       or (v::text)::numeric < -75
       or (v::text)::numeric > 75
    then raise exception 'INVALID_RESISTANCE_VALUE'; end if;
  end loop;

  if p_heal_amount>0 then
    effects_value:=jsonb_build_array(
      jsonb_build_object('type','heal_hp','amount',p_heal_amount)
    );
  end if;

  if p_id is null then
    insert into public.item_definitions(
      slug,name,description,category,rarity,equip_group,stackable,max_stack,
      stat_modifiers,effects,base_value,required_level,shop_tier,shop_price,shop_enabled,
      damage_type,damage_resistances,scroll_spell_id,scroll_mode,
      unique_property_name,unique_property_description,unique_effect_type,unique_effect_value
    )
    values(
      btrim(p_slug),btrim(p_name),coalesce(p_description,''),
      p_category::public.item_category,p_rarity::public.item_rarity,
      case when p_equip_group is null then null else p_equip_group::public.item_equip_group end,
      coalesce(p_stackable,false),case when p_stackable then p_max_stack else 1 end,
      coalesce(p_stat_modifiers,'{}'::jsonb),effects_value,p_base_value,
      p_required_level,p_shop_tier,p_shop_price,coalesce(p_shop_enabled,false),
      p_damage_type,coalesce(p_damage_resistances,'{}'::jsonb),p_scroll_spell_id,p_scroll_mode,
      p_unique_property_name,coalesce(p_unique_property_description,''),
      p_unique_effect_type,p_unique_effect_value
    )
    returning id into saved_id;
  else
    update public.item_definitions
    set slug=btrim(p_slug),name=btrim(p_name),description=coalesce(p_description,''),
        category=p_category::public.item_category,rarity=p_rarity::public.item_rarity,
        equip_group=case when p_equip_group is null then null else p_equip_group::public.item_equip_group end,
        stackable=coalesce(p_stackable,false),
        max_stack=case when p_stackable then p_max_stack else 1 end,
        stat_modifiers=coalesce(p_stat_modifiers,'{}'::jsonb),
        effects=effects_value,base_value=p_base_value,required_level=p_required_level,
        shop_tier=p_shop_tier,shop_price=p_shop_price,shop_enabled=coalesce(p_shop_enabled,false),
        damage_type=p_damage_type,damage_resistances=coalesce(p_damage_resistances,'{}'::jsonb),
        scroll_spell_id=p_scroll_spell_id,scroll_mode=p_scroll_mode,
        unique_property_name=p_unique_property_name,
        unique_property_description=coalesce(p_unique_property_description,''),
        unique_effect_type=p_unique_effect_type,unique_effect_value=p_unique_effect_value,
        updated_at=now()
    where id=p_id
    returning id into saved_id;

    if saved_id is null then raise exception 'ITEM_NOT_FOUND'; end if;
  end if;

  insert into public.gm_audit_log(actor_user_id,action,target_type,target_id,details)
  values(
    auth.uid(),
    case when p_id is null then 'item_definition.create' else 'item_definition.update' end,
    'item_definition',saved_id::text,
    jsonb_build_object(
      'name',p_name,'category',p_category,'rarity',p_rarity,
      'required_level',p_required_level,'shop_tier',p_shop_tier,
      'shop_enabled',p_shop_enabled,'damage_type',p_damage_type,
      'unique_effect_type',p_unique_effect_type,'unique_effect_value',p_unique_effect_value
    )
  );

  return saved_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.gm_save_item_definition_v2(p_id uuid, p_slug text, p_name text, p_description text, p_category text, p_rarity text, p_equip_group text, p_stackable boolean, p_max_stack integer, p_stat_modifiers jsonb, p_heal_amount integer, p_base_value bigint, p_required_level integer, p_shop_tier smallint, p_shop_price bigint, p_shop_enabled boolean, p_damage_type text, p_damage_resistances jsonb, p_scroll_spell_id uuid, p_scroll_mode text, p_unique_property_name text, p_unique_property_description text, p_unique_effect_type text, p_unique_effect_value integer, p_damage_bonuses jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  saved_id uuid;
  k text;
  v jsonb;
begin
  if not private.is_gm(auth.uid()) then raise exception 'GM_REQUIRED'; end if;

  if jsonb_typeof(coalesce(p_damage_bonuses,'{}'::jsonb))<>'object' then
    raise exception 'INVALID_DAMAGE_BONUSES';
  end if;

  for k,v in select * from jsonb_each(coalesce(p_damage_bonuses,'{}'::jsonb))
  loop
    if k not in ('slashing','piercing','blunt','fire','water','earth','air','lightning','ice','arcane','star','gravity','moon','arcane','star','gravity','moon')
       or jsonb_typeof(v)<>'number'
       or (v::text)::numeric < 0
       or (v::text)::numeric > 75
    then raise exception 'INVALID_DAMAGE_BONUS_VALUE'; end if;
  end loop;

  saved_id:=public.gm_save_item_definition(
    p_id,p_slug,p_name,p_description,p_category,p_rarity,p_equip_group,
    p_stackable,p_max_stack,p_stat_modifiers,p_heal_amount,p_base_value,
    p_required_level,p_shop_tier,p_shop_price,p_shop_enabled,p_damage_type,
    p_damage_resistances,p_scroll_spell_id,p_scroll_mode,p_unique_property_name,
    p_unique_property_description,p_unique_effect_type,p_unique_effect_value
  );

  update public.item_definitions
  set damage_bonuses=coalesce(p_damage_bonuses,'{}'::jsonb),
      updated_at=now()
  where id=saved_id;

  insert into public.gm_audit_log(actor_user_id,action,target_type,target_id,details)
  values(
    auth.uid(),
    'item_definition.damage_bonuses',
    'item_definition',
    saved_id::text,
    jsonb_build_object('damage_bonuses',coalesce(p_damage_bonuses,'{}'::jsonb))
  );

  return saved_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.gm_save_race_definition(p_id uuid, p_slug text, p_name text, p_category text, p_description text, p_sort_order integer, p_playable boolean, p_access_mode text, p_innate_magic_damage_type text, p_hp_bonus integer, p_mana_bonus integer, p_hp_regen_per_hour integer, p_mana_regen_per_hour integer, p_damage_resistances jsonb, p_passive_type text, p_passive_value integer, p_passive_name text, p_passive_description text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  saved_id uuid;
  k text;
  v jsonb;
begin
  if not private.is_gm(auth.uid()) then raise exception 'GM_REQUIRED'; end if;

  if btrim(coalesce(p_slug,''))='' or btrim(coalesce(p_name,''))='' then
    raise exception 'RACE_NAME_AND_SLUG_REQUIRED';
  end if;

  if btrim(coalesce(p_category,''))='' then raise exception 'RACE_CATEGORY_REQUIRED'; end if;
  p_access_mode:='open';
  if p_innate_magic_damage_type not in ('fire','water','earth','air','lightning','ice','arcane','star','gravity','moon') then
    raise exception 'INVALID_DAMAGE_TYPE';
  end if;
  if p_hp_bonus not between -100 and 500 or p_mana_bonus not between -100 and 500
     or p_hp_regen_per_hour not between 0 and 100
     or p_mana_regen_per_hour not between 0 and 100
     or p_passive_value not between 0 and 100
  then raise exception 'INVALID_RACE_VALUES'; end if;

  if p_passive_type is not null
     and p_passive_type not in (
       'all_damage_bonus','physical_damage_bonus','magic_damage_bonus','lifesteal',
       'mana_on_hit','damage_vs_wounded','guard_boost',
       'low_hp_damage_reduction','boss_damage_bonus'
     )
  then raise exception 'INVALID_RACE_PASSIVE'; end if;

  if p_passive_type is null then
    p_passive_value:=0;
    p_passive_name:='';
    p_passive_description:='';
  end if;

  if jsonb_typeof(coalesce(p_damage_resistances,'{}'::jsonb))<>'object' then
    raise exception 'INVALID_RESISTANCES';
  end if;

  for k,v in select * from jsonb_each(coalesce(p_damage_resistances,'{}'::jsonb))
  loop
    if k not in ('slashing','piercing','blunt','fire','water','earth','air','lightning','ice','arcane','star','gravity','moon','arcane','star','gravity','moon')
       or jsonb_typeof(v)<>'number'
       or (v::text)::numeric < -75
       or (v::text)::numeric > 75
    then raise exception 'INVALID_RESISTANCE_VALUE'; end if;
  end loop;

  if p_id is null then
    insert into public.race_definitions(
      slug,name,category,description,sort_order,playable,
      innate_magic_damage_type,access_mode,hp_bonus,mana_bonus,
      hp_regen_per_hour,mana_regen_per_hour,damage_resistances,
      passive_type,passive_value,passive_name,passive_description
    )
    values(
      btrim(p_slug),btrim(p_name),btrim(p_category),coalesce(p_description,''),
      p_sort_order,coalesce(p_playable,true),p_innate_magic_damage_type,p_access_mode,
      p_hp_bonus,p_mana_bonus,p_hp_regen_per_hour,p_mana_regen_per_hour,
      coalesce(p_damage_resistances,'{}'::jsonb),
      p_passive_type,p_passive_value,coalesce(p_passive_name,''),
      coalesce(p_passive_description,'')
    )
    returning id into saved_id;
  else
    update public.race_definitions
    set slug=btrim(p_slug),name=btrim(p_name),category=btrim(p_category),
        description=coalesce(p_description,''),sort_order=p_sort_order,
        playable=coalesce(p_playable,true),innate_magic_damage_type=p_innate_magic_damage_type,
        access_mode=p_access_mode,hp_bonus=p_hp_bonus,mana_bonus=p_mana_bonus,
        hp_regen_per_hour=p_hp_regen_per_hour,mana_regen_per_hour=p_mana_regen_per_hour,
        damage_resistances=coalesce(p_damage_resistances,'{}'::jsonb),
        passive_type=p_passive_type,passive_value=p_passive_value,
        passive_name=coalesce(p_passive_name,''),
        passive_description=coalesce(p_passive_description,''),
        updated_at=now()
    where id=p_id
    returning id into saved_id;

    if saved_id is null then raise exception 'RACE_NOT_FOUND'; end if;
  end if;

  -- Recalculate maxima for existing characters of this race without filling them to full.
  update public.character_progress cp
  set vitality=cp.vitality,
      intellect=cp.intellect
  where exists(
    select 1 from public.characters c
    where c.id=cp.character_id and c.race_id=saved_id
  );

  insert into public.gm_audit_log(actor_user_id,action,target_type,target_id,details)
  values(
    auth.uid(),
    case when p_id is null then 'race.create' else 'race.update' end,
    'race_definition',saved_id::text,
    jsonb_build_object(
      'name',p_name,'access_mode',p_access_mode,'innate_magic',p_innate_magic_damage_type,
      'hp_bonus',p_hp_bonus,'mana_bonus',p_mana_bonus,
      'passive_type',p_passive_type,'passive_value',p_passive_value
    )
  );

  return saved_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.gm_save_spell_definition(p_id uuid, p_slug text, p_name text, p_description text, p_enabled boolean, p_spell_kind text, p_damage_type text, p_mana_cost integer, p_required_level integer, p_power_multiplier numeric, p_flat_power integer, p_status_effect_type text, p_status_effect_chance smallint, p_status_effect_turns smallint, p_status_effect_potency integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare saved_id uuid;
begin
  if not private.is_gm(auth.uid()) then raise exception 'GM_REQUIRED'; end if;

  if btrim(coalesce(p_slug,''))='' or btrim(coalesce(p_name,''))='' then
    raise exception 'SPELL_NAME_AND_SLUG_REQUIRED';
  end if;

  if p_spell_kind not in ('damage','heal') then raise exception 'INVALID_SPELL_KIND'; end if;

  if p_spell_kind='damage'
     and p_damage_type not in ('fire','water','earth','air','lightning','ice','arcane','star','gravity','moon')
  then raise exception 'INVALID_DAMAGE_TYPE'; end if;

  if p_spell_kind='heal' then p_damage_type:=null; end if;

  if p_status_effect_type is not null
     and p_status_effect_type not in ('burn','bleed','poison','chill','stun','weaken','vulnerable')
  then raise exception 'INVALID_STATUS_EFFECT'; end if;

  if p_mana_cost<0 or p_required_level<1 or p_power_multiplier<0 or p_flat_power<0
     or p_status_effect_chance not between 0 and 100
     or p_status_effect_turns not between 0 and 10
     or p_status_effect_potency<0
  then raise exception 'INVALID_SPELL_VALUES'; end if;

  if p_status_effect_type is null then
    p_status_effect_chance:=0;
    p_status_effect_turns:=0;
    p_status_effect_potency:=0;
  end if;

  if p_id is null then
    insert into public.spell_definitions(
      slug,name,description,enabled,spell_kind,damage_type,mana_cost,
      required_level,power_multiplier,flat_power,
      status_effect_type,status_effect_chance,status_effect_turns,status_effect_potency
    )
    values(
      btrim(p_slug),btrim(p_name),coalesce(p_description,''),coalesce(p_enabled,true),
      p_spell_kind,p_damage_type,p_mana_cost,p_required_level,p_power_multiplier,p_flat_power,
      p_status_effect_type,p_status_effect_chance,p_status_effect_turns,p_status_effect_potency
    )
    returning id into saved_id;
  else
    update public.spell_definitions
    set slug=btrim(p_slug),name=btrim(p_name),description=coalesce(p_description,''),
        enabled=coalesce(p_enabled,true),spell_kind=p_spell_kind,damage_type=p_damage_type,
        mana_cost=p_mana_cost,required_level=p_required_level,
        power_multiplier=p_power_multiplier,flat_power=p_flat_power,
        status_effect_type=p_status_effect_type,
        status_effect_chance=p_status_effect_chance,
        status_effect_turns=p_status_effect_turns,
        status_effect_potency=p_status_effect_potency,
        updated_at=now()
    where id=p_id
    returning id into saved_id;

    if saved_id is null then raise exception 'SPELL_NOT_FOUND'; end if;
  end if;

  insert into public.gm_audit_log(actor_user_id,action,target_type,target_id,details)
  values(
    auth.uid(),
    case when p_id is null then 'spell.create' else 'spell.update' end,
    'spell_definition',saved_id::text,
    jsonb_build_object(
      'name',p_name,'kind',p_spell_kind,'damage_type',p_damage_type,
      'mana_cost',p_mana_cost,'status_effect_type',p_status_effect_type,
      'status_effect_chance',p_status_effect_chance
    )
  );

  return saved_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.gm_save_spell_definition_v2(p_id uuid, p_slug text, p_name text, p_description text, p_enabled boolean, p_spell_kind text, p_damage_type text, p_mana_cost integer, p_required_level integer, p_power_multiplier numeric, p_flat_power integer, p_status_effect_type text, p_status_effect_chance smallint, p_status_effect_turns smallint, p_status_effect_potency integer, p_support_effect_type text, p_support_value integer, p_support_turns smallint)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare saved_id uuid;
begin
  if not private.is_gm(auth.uid()) then raise exception 'GM_REQUIRED'; end if;

  if btrim(coalesce(p_slug,''))='' or btrim(coalesce(p_name,''))='' then
    raise exception 'SPELL_NAME_AND_SLUG_REQUIRED';
  end if;

  if p_spell_kind not in ('damage','heal','guard','cleanse','buff','taunt','sacrifice') then
    raise exception 'INVALID_SPELL_KIND';
  end if;

  if p_spell_kind='damage'
     and p_damage_type not in ('fire','water','earth','air','lightning','ice','arcane','star','gravity','moon')
  then raise exception 'INVALID_DAMAGE_TYPE'; end if;

  if p_spell_kind<>'damage' then p_damage_type:=null; end if;

  if p_status_effect_type is not null
     and p_status_effect_type not in ('burn','bleed','poison','chill','stun','weaken','vulnerable')
  then raise exception 'INVALID_STATUS_EFFECT'; end if;

  if p_spell_kind<>'damage' then
    p_status_effect_type:=null;
    p_status_effect_chance:=0;
    p_status_effect_turns:=0;
    p_status_effect_potency:=0;
  end if;

  if p_spell_kind='guard' then
    p_support_effect_type:='guard';
    p_support_value:=greatest(55,least(85,coalesce(p_support_value,70)));
    p_support_turns:=1;
  elsif p_spell_kind='cleanse' then
    p_support_effect_type:='cleanse';
    p_support_value:=0;
    p_support_turns:=0;
  elsif p_spell_kind='buff' then
    p_support_effect_type:='empower';
    p_support_value:=greatest(1,least(100,coalesce(p_support_value,20)));
    p_support_turns:=greatest(1,least(10,coalesce(p_support_turns,2)));
  elsif p_spell_kind='taunt' then
    p_support_effect_type:='taunt';
    p_support_value:=greatest(1,least(100,coalesce(p_support_value,90)));
    p_support_turns:=0;
  elsif p_spell_kind='sacrifice' then
    p_support_effect_type:='sacrifice';
    p_support_value:=30;
    p_support_turns:=3;
    p_mana_cost:=0;
  else
    p_support_effect_type:=null;
    p_support_value:=0;
    p_support_turns:=0;
  end if;

  if p_mana_cost<0 or p_required_level<1 or p_power_multiplier<0 or p_flat_power<0
     or p_status_effect_chance not between 0 and 100
     or p_status_effect_turns not between 0 and 10
     or p_status_effect_potency<0
     or p_support_value not between 0 and 100
     or p_support_turns not between 0 and 10
  then raise exception 'INVALID_SPELL_VALUES'; end if;

  if p_id is null then
    insert into public.spell_definitions(
      slug,name,description,enabled,spell_kind,damage_type,mana_cost,
      required_level,power_multiplier,flat_power,
      status_effect_type,status_effect_chance,status_effect_turns,status_effect_potency,
      support_effect_type,support_value,support_turns
    )
    values(
      btrim(p_slug),btrim(p_name),coalesce(p_description,''),coalesce(p_enabled,true),
      p_spell_kind,p_damage_type,p_mana_cost,p_required_level,p_power_multiplier,p_flat_power,
      p_status_effect_type,p_status_effect_chance,p_status_effect_turns,p_status_effect_potency,
      p_support_effect_type,p_support_value,p_support_turns
    )
    returning id into saved_id;
  else
    update public.spell_definitions
    set slug=btrim(p_slug),name=btrim(p_name),description=coalesce(p_description,''),
        enabled=coalesce(p_enabled,true),spell_kind=p_spell_kind,damage_type=p_damage_type,
        mana_cost=p_mana_cost,required_level=p_required_level,
        power_multiplier=p_power_multiplier,flat_power=p_flat_power,
        status_effect_type=p_status_effect_type,
        status_effect_chance=p_status_effect_chance,
        status_effect_turns=p_status_effect_turns,
        status_effect_potency=p_status_effect_potency,
        support_effect_type=p_support_effect_type,
        support_value=p_support_value,
        support_turns=p_support_turns,
        updated_at=now()
    where id=p_id
    returning id into saved_id;

    if saved_id is null then raise exception 'SPELL_NOT_FOUND'; end if;
  end if;

  insert into public.gm_audit_log(actor_user_id,action,target_type,target_id,details)
  values(
    auth.uid(),
    case when p_id is null then 'spell.create' else 'spell.update' end,
    'spell_definition',saved_id::text,
    jsonb_build_object(
      'name',p_name,'kind',p_spell_kind,'damage_type',p_damage_type,
      'mana_cost',p_mana_cost,'status_effect_type',p_status_effect_type,
      'support_effect_type',p_support_effect_type,'support_value',p_support_value,'support_turns',p_support_turns
    )
  );

  return saved_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.gm_set_enemy_special(p_enemy_id uuid, p_special_name text, p_kind text, p_value smallint, p_damage_multiplier numeric, p_every_n smallint, p_damage_type text, p_effect_type text, p_effect_chance smallint, p_effect_turns smallint, p_effect_potency integer, p_telegraph_text text, p_attack_text text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
begin
  if not private.is_gm(auth.uid()) then raise exception 'GM_REQUIRED'; end if;
  if not exists(select 1 from public.enemy_templates where id=p_enemy_id) then
    raise exception 'ENEMY_TEMPLATE_NOT_FOUND';
  end if;

  p_special_name:=btrim(coalesce(p_special_name,''));
  p_kind:=coalesce(p_kind,'attack');
  p_value:=coalesce(p_value,0);
  p_damage_multiplier:=coalesce(p_damage_multiplier,0);
  p_every_n:=coalesce(p_every_n,0);

  if p_kind not in ('attack','heal','guard','enrage','cleanse') then raise exception 'INVALID_SPECIAL_KIND'; end if;
  if p_every_n<>0 and p_every_n not between 2 and 20 then raise exception 'INVALID_SPECIAL_INTERVAL'; end if;
  if p_damage_multiplier<0 or p_damage_multiplier>5 then raise exception 'INVALID_SPECIAL_DAMAGE'; end if;
  if p_value not between 0 and 100 then raise exception 'INVALID_SPECIAL_VALUE'; end if;
  if p_every_n>0 and p_special_name='' then raise exception 'SPECIAL_NAME_REQUIRED'; end if;
  if p_every_n>0 and p_kind='attack' and p_damage_multiplier<=0 then raise exception 'SPECIAL_DAMAGE_REQUIRED'; end if;
  if p_every_n>0 and p_kind in ('heal','guard','enrage') and p_value<=0 then raise exception 'SPECIAL_VALUE_REQUIRED'; end if;

  if p_damage_type is not null and p_damage_type not in (
    'slashing','piercing','blunt','fire','water','earth','air','lightning','ice','arcane','star','gravity','moon','arcane','star','gravity','moon'
  ) then raise exception 'INVALID_DAMAGE_TYPE'; end if;

  if p_effect_type is not null and p_effect_type not in (
    'burn','bleed','poison','chill','stun','weaken','vulnerable'
  ) then raise exception 'INVALID_STATUS_EFFECT'; end if;

  if coalesce(p_effect_chance,0) not between 0 and 100
     or coalesce(p_effect_turns,0) not between 0 and 10
     or coalesce(p_effect_potency,0)<0
  then raise exception 'INVALID_SPECIAL_EFFECT'; end if;

  if p_every_n=0 then
    p_special_name:='';
    p_kind:='attack';
    p_value:=0;
    p_damage_multiplier:=0;
    p_damage_type:=null;
    p_effect_type:=null;
    p_effect_chance:=0;
    p_effect_turns:=0;
    p_effect_potency:=0;
    p_telegraph_text:='';
    p_attack_text:='';
  elsif p_kind<>'attack' then
    p_damage_multiplier:=0;
    p_damage_type:=null;
    p_effect_type:=null;
    p_effect_chance:=0;
    p_effect_turns:=0;
    p_effect_potency:=0;
  elsif p_effect_type is null then
    p_effect_chance:=0;
    p_effect_turns:=0;
    p_effect_potency:=0;
  end if;

  update public.enemy_templates
  set special_name=p_special_name,
      special_kind=p_kind,
      special_value=p_value,
      special_damage_multiplier=p_damage_multiplier,
      special_every_n=p_every_n,
      special_damage_type=p_damage_type,
      special_effect_type=p_effect_type,
      special_effect_chance=coalesce(p_effect_chance,0),
      special_effect_turns=coalesce(p_effect_turns,0),
      special_effect_potency=coalesce(p_effect_potency,0),
      special_telegraph_text=coalesce(p_telegraph_text,''),
      special_attack_text=coalesce(p_attack_text,''),
      updated_at=now()
  where id=p_enemy_id;

  insert into public.gm_audit_log(actor_user_id,action,target_type,target_id,details)
  values(
    auth.uid(),'enemy_template.special.update','enemy_template',p_enemy_id::text,
    jsonb_build_object('name',p_special_name,'kind',p_kind,'value',p_value,'every_n',p_every_n)
  );
end;
$function$;
