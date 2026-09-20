CREATE OR REPLACE FUNCTION private.get_game_guide_catalog_internal()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  caller uuid:=auth.uid();
begin
  if caller is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  return jsonb_build_object(
    'items',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',d.id,
          'slug',d.slug,
          'name',d.name,
          'description',d.description,
          'category',d.category::text,
          'rarity',d.rarity::text,
          'equip_group',case when d.equip_group is null then null else d.equip_group::text end,
          'stat_modifiers',coalesce(d.stat_modifiers,'{}'::jsonb),
          'required_level',d.required_level,
          'shop_tier',d.shop_tier,
          'shop_price',d.shop_price,
          'damage_type',d.damage_type,
          'damage_resistances',coalesce(d.damage_resistances,'{}'::jsonb),
          'damage_bonuses',coalesce(d.damage_bonuses,'{}'::jsonb),
          'weapon_base_damage',coalesce(d.weapon_base_damage,0),
          'weapon_scaling',d.weapon_scaling,
          'weapon_family',d.weapon_family,
          'bow_full_draw_armor_penetration_percent',coalesce(d.bow_full_draw_armor_penetration_percent,0),
          'bloodshed_chance_percent',coalesce(d.bloodshed_chance_percent,0),
          'echo_strike_chance_percent',coalesce(d.echo_strike_chance_percent,0),
          'unique_property_name',d.unique_property_name,
          'unique_property_description',coalesce(d.unique_property_description,''),
          'unique_effect_type',d.unique_effect_type,
          'unique_effect_value',coalesce(d.unique_effect_value,0)
        )
        order by
          case d.category::text when 'weapon' then 0 when 'armor' then 1 else 2 end,
          d.required_level,
          d.rarity::text,
          d.name
      )
      from public.item_definitions d
      where d.category::text in ('weapon','armor','accessory')
    ),'[]'::jsonb),
    'spells',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',s.id,
          'slug',s.slug,
          'name',s.name,
          'description',s.description,
          'spell_kind',s.spell_kind,
          'damage_type',s.damage_type,
          'mana_cost',s.mana_cost,
          'required_level',s.required_level,
          'power_multiplier',s.power_multiplier,
          'flat_power',s.flat_power,
          'status_effect_type',s.status_effect_type,
          'status_effect_chance',s.status_effect_chance,
          'status_effect_turns',s.status_effect_turns,
          'status_effect_potency',s.status_effect_potency,
          'support_effect_type',s.support_effect_type,
          'support_value',s.support_value,
          'support_turns',s.support_turns,
          'families',coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'slug',mf.slug,
                'name',mf.name,
                'kind',mf.kind
              )
              order by mf.kind,mf.sort_order,mf.name
            )
            from public.spell_magic_families smf
            join public.magic_families mf on mf.slug=smf.family_slug
            where smf.spell_id=s.id and mf.enabled=true
          ),'[]'::jsonb)
        )
        order by s.required_level,s.name
      )
      from public.spell_definitions s
      where s.enabled=true
    ),'[]'::jsonb),
    'magic_families',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'slug',mf.slug,
          'name',mf.name,
          'kind',mf.kind,
          'description',mf.description,
          'spell_count',(
            select count(*)::integer
            from public.spell_magic_families smf
            join public.spell_definitions sd on sd.id=smf.spell_id
            where smf.family_slug=mf.slug and sd.enabled=true
          )
        )
        order by
          case mf.kind when 'element' then 0 when 'school' then 1 else 2 end,
          mf.sort_order,mf.name
      )
      from public.magic_families mf
      where mf.enabled=true
    ),'[]'::jsonb),
    'races',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',r.id,
          'slug',r.slug,
          'name',r.name,
          'category',r.category,
          'description',r.description,
          'stat_modifiers',coalesce(r.stat_modifiers,'{}'::jsonb),
          'traits',coalesce(r.traits,'[]'::jsonb),
          'innate_magic_damage_type',r.innate_magic_damage_type,
          'hp_bonus',r.hp_bonus,
          'mana_bonus',r.mana_bonus,
          'hp_regen_per_hour',r.hp_regen_per_hour,
          'mana_regen_per_hour',r.mana_regen_per_hour,
          'damage_resistances',coalesce(r.damage_resistances,'{}'::jsonb),
          'passive_type',r.passive_type,
          'passive_value',r.passive_value,
          'passive_name',r.passive_name,
          'passive_description',r.passive_description
        )
        order by r.sort_order,r.name
      )
      from public.race_definitions r
      where r.playable=true
    ),'[]'::jsonb),
    'affixes',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',a.id,
          'slug',a.slug,
          'name',a.name,
          'description',a.description,
          'min_rarity_rank',a.min_rarity_rank,
          'max_rarity_rank',a.max_rarity_rank,
          'allowed_categories',a.allowed_categories,
          'allowed_equip_groups',a.allowed_equip_groups,
          'stat_modifiers',coalesce(a.stat_modifiers,'{}'::jsonb),
          'damage_resistances',coalesce(a.damage_resistances,'{}'::jsonb),
          'unique_effect_type',a.unique_effect_type,
          'unique_effect_value',coalesce(a.unique_effect_value,0)
        )
        order by a.min_rarity_rank,a.name
      )
      from public.equipment_affixes a
      where a.enabled=true
    ),'[]'::jsonb),
    'mechanics',
    jsonb_build_object(
      'enhancement_percent_per_level',3,
      'enhancement_max',20,
      'awakening_max',5,
      'critical_cap_percent',60,
      'physical_critical_multiplier',1.5,
      'magic_critical_multiplier',1.4,
      'loot_quality_luck_relative_percent_per_point',1,
      'affix_slots',jsonb_build_object(
        'common',0,
        'uncommon',1,
        'rare',2,
        'epic',3,
        'unique',4,
        'legendary',5
      )
    )
  );
end;
$function$;
