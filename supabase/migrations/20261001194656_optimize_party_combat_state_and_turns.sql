CREATE OR REPLACE FUNCTION private.character_party_initiative(p_character_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  with equipped as (
    select d.stat_modifiers,ci.metadata
    from public.character_equipment ce
    join public.character_items ci on ci.id=ce.character_item_id
    join public.item_definitions d on d.id=ci.item_definition_id
    where ce.character_id=p_character_id
  ),
  eq as (
    select
      coalesce(sum(
        case when jsonb_typeof(stat_modifiers->'agility')='number' then (stat_modifiers->>'agility')::numeric::integer else 0 end
        +case when jsonb_typeof(metadata->'affix_stat_modifiers'->'agility')='number' then (metadata->'affix_stat_modifiers'->>'agility')::numeric::integer else 0 end
        +case when jsonb_typeof(metadata->'religion_stat_modifiers'->'agility')='number' then (metadata->'religion_stat_modifiers'->>'agility')::numeric::integer else 0 end
      ),0)::integer agility_mod,
      coalesce(sum(
        case when jsonb_typeof(stat_modifiers->'luck')='number' then (stat_modifiers->>'luck')::numeric::integer else 0 end
        +case when jsonb_typeof(metadata->'affix_stat_modifiers'->'luck')='number' then (metadata->'affix_stat_modifiers'->>'luck')::numeric::integer else 0 end
        +case when jsonb_typeof(metadata->'religion_stat_modifiers'->'luck')='number' then (metadata->'religion_stat_modifiers'->>'luck')::numeric::integer else 0 end
      ),0)::integer luck_mod
    from equipped
  ),
  religion as (
    select private.character_religion_modifiers(p_character_id) mods
  )
  select (
    (cp.agility+eq.agility_mod
      +case when jsonb_typeof(rd.stat_modifiers->'agility')='number' then (rd.stat_modifiers->>'agility')::numeric::integer else 0 end
      +coalesce((religion.mods->>'agility')::integer,0))*2
    +(cp.luck+eq.luck_mod
      +case when jsonb_typeof(rd.stat_modifiers->'luck')='number' then (rd.stat_modifiers->>'luck')::numeric::integer else 0 end
      +coalesce((religion.mods->>'luck')::integer,0))
    +private.race_trait_number(p_character_id,'initiative_flat')
  )::integer
  from public.character_progress cp
  join public.characters c on c.id=cp.character_id
  left join public.race_definitions rd on rd.id=c.race_id
  cross join eq
  cross join religion
  where cp.character_id=p_character_id;
$function$
;

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
      coalesce(rd.hp_bonus,0) race_hp_bonus,
      coalesce(rd.mana_bonus,0) race_mana_bonus,
      private.character_max_hp_percent(p_character_id) max_hp_percent,
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
      least(30,m.item_mana_hit + case when rd.passive_type='mana_on_hit' then rd.passive_value else 0 end + coalesce((rm.mods->>'mana_on_hit')::integer,0) + private.character_equipment_set_static_bonus(p_character_id,'mana_on_hit')) mana_hit,
      least(75,m.item_wounded_bonus + case when rd.passive_type='damage_vs_wounded' then rd.passive_value else 0 end) wounded_bonus,
      least(25,m.item_guard_bonus + case when rd.passive_type='guard_boost' then rd.passive_value else 0 end + coalesce((rm.mods->>'guard_boost')::integer,0) + private.character_equipment_set_static_bonus(p_character_id,'guard_boost')) guard_bonus,
      least(50,m.item_all_damage_bonus + case when rd.passive_type='all_damage_bonus' then rd.passive_value else 0 end + coalesce((rm.mods->>'all_damage_bonus')::integer,0) + private.race_low_hp_trait_bonus(p_character_id,'low_hp_all_damage_bonus',cp.hp_current,cp.hp_max) + private.character_equipment_set_low_hp_damage_bonus(p_character_id,cp.hp_current,cp.hp_max)) all_damage_bonus,
      least(75,m.item_physical_damage_bonus + case when rd.passive_type='physical_damage_bonus' then rd.passive_value else 0 end + coalesce((rm.mods->>'physical_damage_bonus')::integer,0) + private.race_weapon_family_damage_bonus(p_character_id) + private.race_low_hp_trait_bonus(p_character_id,'low_hp_physical_damage_bonus',cp.hp_current,cp.hp_max) + private.character_equipment_set_static_bonus(p_character_id,'physical_damage_bonus') + private.camp_preparation_bonus(p_character_id,'physical')) physical_damage_bonus,
      least(75,m.item_magic_damage_bonus + case when rd.passive_type='magic_damage_bonus' then rd.passive_value else 0 end + coalesce((rm.mods->>'magic_damage_bonus')::integer,0) + private.character_equipment_set_static_bonus(p_character_id,'magic_damage_bonus') + private.camp_preparation_bonus(p_character_id,'magic')) magic_damage_bonus,
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
    b.level,
    least(
      greatest(1,round((public.character_hp_max(b.level,b.vitality)+b.race_hp_bonus)*(100+b.max_hp_percent)/100.0)::integer),
      greatest(0,round(b.hp_current*greatest(1,round((public.character_hp_max(b.level,b.vitality)+b.race_hp_bonus)*(100+b.max_hp_percent)/100.0)::integer)::numeric/greatest(1,b.hp_max))::integer)
    ),
    greatest(1,round((public.character_hp_max(b.level,b.vitality)+b.race_hp_bonus)*(100+b.max_hp_percent)/100.0)::integer),
    least(
      greatest(0,public.character_mana_max(b.level,b.intellect)+b.race_mana_bonus),
      greatest(0,round(b.mana_current*greatest(0,public.character_mana_max(b.level,b.intellect)+b.race_mana_bonus)::numeric/greatest(1,b.mana_max))::integer)
    ),
    greatest(0,public.character_mana_max(b.level,b.intellect)+b.race_mana_bonus),
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
;

CREATE OR REPLACE FUNCTION private.party_next_actor_id(p_encounter_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  select ms.character_id
  from public.party_combat_member_states ms
  join public.party_combat_encounters ce
    on ce.id=ms.encounter_id
  join public.party_dungeon_run_members prm
    on prm.run_id=ce.run_id
   and prm.character_id=ms.character_id
  where ms.encounter_id=p_encounter_id
    and ce.status='active'
    and not ms.downed
    and not prm.lost
    and not (ms.character_id=any(ce.acted_character_ids))
  order by private.character_party_initiative(ms.character_id) desc,
           prm.joined_order asc,
           ms.character_id asc
  limit 1;
$function$
;

CREATE OR REPLACE FUNCTION public.get_party_dungeon_state(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid:=auth.uid();
  v_run_id uuid;
  v_encounter_id uuid;
  result jsonb;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id
      and c.owner_user_id=caller_id
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select pr.id into v_run_id
  from public.party_dungeon_runs pr
  join public.party_dungeon_run_members prm on prm.run_id=pr.id
  where prm.character_id=p_character_id
  order by (pr.status='active') desc,pr.created_at desc
  limit 1;

  if v_run_id is null then
    return jsonb_build_object(
      'run',null,
      'encounter',null,
      'members','[]'::jsonb,
      'statuses','[]'::jsonb,
      'turns','[]'::jsonb,
      'loot','[]'::jsonb,
      'sacrifice_scroll_count',coalesce((
        select sum(ci.quantity)::integer
        from public.character_items ci
        join public.item_definitions idf on idf.id=ci.item_definition_id
        where ci.character_id=p_character_id
          and idf.slug='combat_scroll_last_sacrifice'
      ),0)
    );
  end if;

  select ce.id into v_encounter_id
  from public.party_combat_encounters ce
  where ce.run_id=v_run_id
  order by (ce.status='active') desc,ce.room_index desc,ce.created_at desc
  limit 1;

  select jsonb_build_object(
    'sacrifice_scroll_count',coalesce((
      select sum(ci.quantity)::integer
      from public.character_items ci
      join public.item_definitions idf on idf.id=ci.item_definition_id
      where ci.character_id=p_character_id
        and idf.slug='combat_scroll_last_sacrifice'
    ),0),
    'run',(
      select jsonb_build_object(
        'id',pr.id,
        'party_id',pr.party_id,
        'leader_character_id',pr.leader_character_id,
        'sector_id',pr.sector_id,
        'title',coalesce((select ebe.name from public.event_boss_events ebe where ebe.id=pr.event_boss_id),coalesce(sd.title,'Подземелье')),
        'is_event_boss',pr.event_boss_id is not null,
        'event_boss_id',pr.event_boss_id,
        'event_boss',case when pr.event_boss_id is null then null else (
          select jsonb_build_object(
            'boss_kind',ebe.boss_kind,
            'name',ebe.name,
            'description',ebe.description,
            'recommended_level',ebe.recommended_level,
            'ends_at',ebe.ends_at,
            'special_every_n',ebe.special_every_n,
            'phase2_hp_percent',ebe.phase2_hp_percent,
            'special_name',coalesce(et.special_name,'Особый приём'),
            'phase2_name',coalesce(et.phase2_name,'Вторая фаза'),
            'reward_material_name',rm.name,
            'reward_material_quantity',ebe.reward_material_quantity,
            'first_reward_gold',ebe.first_reward_gold,
            'first_reward_experience',ebe.first_reward_experience,
            'repeat_reward_gold',ebe.repeat_reward_gold,
            'repeat_reward_experience',ebe.repeat_reward_experience
          )
          from public.event_boss_events ebe
          left join public.enemy_templates et on et.id=ebe.enemy_template_id
          left join public.item_definitions rm on rm.id=ebe.reward_material_item_id
          where ebe.id=pr.event_boss_id
        ) end,
        'danger_level',sd.danger_level,
        'modifier',case when pr.modifier_slug is null then null else (
          select jsonb_build_object(
            'slug',m.slug,
            'name',m.name,
            'description',m.description,
            'theme',m.theme,
            'enemy_hp_percent',m.enemy_hp_percent,
            'enemy_attack_percent',m.enemy_attack_percent,
            'enemy_defense_percent',m.enemy_defense_percent,
            'reward_gold_percent',m.reward_gold_percent,
            'reward_xp_percent',m.reward_xp_percent
          )
          from public.dungeon_modifier_definitions m
          where m.slug=pr.modifier_slug
        ) end,
        'status',pr.status,
        'current_stage',pr.current_stage,
        'rooms_cleared',pr.rooms_cleared,
        'total_rooms',pr.total_rooms,
        'reward_gold',pr.reward_gold,
        'reward_experience',pr.reward_experience,
        'member_count',pr.member_count,
        'escape_attempt_stage',pr.escape_attempt_stage,
        'started_at',pr.started_at,
        'sacrifice_scroll_used',pr.sacrifice_scroll_used
      )
      from public.party_dungeon_runs pr
      join public.sector_details sd on sd.sector_id=pr.sector_id
      where pr.id=v_run_id
    ),
    'encounter',case when v_encounter_id is null then null else (
      select jsonb_build_object(
        'id',ce.id,
        'room_index',ce.room_index,
        'is_boss',ce.is_boss,
        'is_rare_variant',exists(
          select 1 from public.enemy_templates et
          where et.id=ce.enemy_template_id and et.is_rare_variant
        ),
        'status',ce.status,
        'round',ce.round,
        'enemy_name',ce.enemy_name,
        'enemy_level',ce.enemy_level,
        'enemy_hp_current',ce.enemy_hp_current,
        'enemy_hp_max',ce.enemy_hp_max,
        'enemy_attack',ce.enemy_attack,
        'enemy_defense',ce.enemy_defense,
        'enemy_initiative',ce.enemy_initiative,
        'enemy_damage_type',ce.enemy_damage_type,
        'enemy_resistances',ce.enemy_resistances,
        'enemy_danger_pending',coalesce((ce.enemy_ai_state->>'danger_pending')::boolean,false),
        'enemy_bloodshed_stacks',ce.enemy_bloodshed_stacks,
        'acted_character_ids',to_jsonb(ce.acted_character_ids),
        'next_actor_character_id',private.party_next_actor_id(ce.id),
        'created_at',ce.created_at,
        'ended_at',ce.ended_at
      )
      from public.party_combat_encounters ce
      where ce.id=v_encounter_id
    ) end,
    'members',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'character_id',c.id,
          'name',c.name,
          'display_name',pf.display_name,
          'race',c.race,
          'level',cp.level,
          'initiative',private.character_party_initiative(c.id),
          'hp_current',case when prm.lost then 0 when prm.dead and ms.character_id is null then 1 else coalesce(ms.hp_current,cp.hp_current) end,
          'hp_max',coalesce(ms.hp_max,cp.hp_max),
          'mana_current',coalesce(ms.mana_current,cp.mana_current),
          'mana_max',coalesce(ms.mana_max,cp.mana_max),
          'downed',case when prm.lost then true else coalesce(ms.downed,prm.dead) end,
          'dead',prm.dead,
          'lost',prm.lost,
          'lost_reason',prm.lost_reason,
          'incoming_damage_reduction_percent',coalesce(ms.incoming_damage_reduction_percent,0),
          'incoming_damage_reduction_rounds',coalesce(ms.incoming_damage_reduction_rounds,0),
          'guard_percent',coalesce(ms.guard_percent,0),
          'reflect_percent',coalesce(ms.reflect_percent,0),
          'damage_bonus_percent',coalesce(ms.damage_bonus_percent,0),
          'damage_bonus_hits',coalesce(ms.damage_bonus_hits,0),
          'taunt_chance',coalesce(ms.taunt_chance,0),
          'bow_distance',coalesce(ms.bow_distance,'medium'),
          'bow_draw_pending',coalesce(ms.bow_draw_pending,false),
          'acted',case
            when ce.id is null then false
            else c.id=any(ce.acted_character_ids)
          end,
          'is_leader',(c.id=pr.leader_character_id),
          'joined_order',prm.joined_order,
          'initiative_meter',coalesce(ms.initiative_meter,0),
          'reward_exhausted',coalesce(prm.reward_exhausted,false),
          'reward_attempt_number',prm.reward_attempt_number,
          'reward_cycle_ends_at',prm.reward_cycle_ends_at
        )
        order by private.character_party_initiative(c.id) desc, prm.joined_order
      )
      from public.party_dungeon_run_members prm
      join public.party_dungeon_runs pr on pr.id=prm.run_id
      join public.characters c on c.id=prm.character_id
      join public.profiles pf on pf.user_id=c.owner_user_id
      join public.character_progress cp on cp.character_id=c.id
      left join public.party_combat_encounters ce on ce.id=v_encounter_id
      left join public.party_combat_member_states ms
        on ms.encounter_id=ce.id
       and ms.character_id=c.id
      where prm.run_id=v_run_id
    ),'[]'::jsonb),
    'statuses',case when v_encounter_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',se.id,
        'target_type',se.target_type,
        'target_character_id',se.target_character_id,
        'effect_type',se.effect_type,
        'potency',se.potency,
        'remaining_turns',se.remaining_turns,
        'source',se.source
      ) order by se.id)
      from public.party_combat_status_effects se
      where se.encounter_id=v_encounter_id
    ),'[]'::jsonb) end,
    'turns',case when v_encounter_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(to_jsonb(x) order by x.id desc)
      from (
        select
          t.id,t.round,t.actor_type,t.actor_character_id,t.target_character_id,
          t.action_type,t.damage,t.message,t.created_at
        from public.party_combat_turns t
        where t.encounter_id=v_encounter_id
        order by t.id desc
        limit 30
      ) x
    ),'[]'::jsonb) end,
    'loot',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',pl.id,
          'source_type',pl.source_type,
          'item_definition_id',pl.item_definition_id,
          'item_name',idf.name,
          'rarity',idf.rarity::text,
          'quantity',pl.quantity,
          'lucky_find',exists(
            select 1
            from public.character_items lucky_ci
            where lucky_ci.character_id=p_character_id
              and lucky_ci.item_definition_id=pl.item_definition_id
              and lucky_ci.metadata->>'party_dungeon_run_id'=v_run_id::text
              and coalesce((lucky_ci.metadata->>'lucky_affix_upgrade')::boolean,false)
          ),
          'created_at',pl.created_at
        )
        order by pl.created_at desc
      )
      from public.party_loot_drops pl
      join public.item_definitions idf on idf.id=pl.item_definition_id
      where pl.run_id=v_run_id
        and pl.character_id=p_character_id
    ),'[]'::jsonb)
  ) into result;

  return result;
end;
$function$
;
