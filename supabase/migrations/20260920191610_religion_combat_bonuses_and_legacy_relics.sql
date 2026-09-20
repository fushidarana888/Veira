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
$function$
