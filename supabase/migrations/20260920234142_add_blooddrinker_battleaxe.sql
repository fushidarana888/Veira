with upsert_item as (
  insert into public.item_definitions(
    slug,name,description,category,rarity,equip_group,
    stackable,max_stack,stat_modifiers,effects,base_value,
    required_level,shop_tier,shop_price,shop_enabled,
    damage_type,damage_resistances,
    unique_property_name,unique_property_description,
    unique_effect_type,unique_effect_value,
    damage_bonuses,weapon_base_damage,weapon_scaling,weapon_family,
    bow_full_draw_armor_penetration_percent,bloodshed_chance_percent,
    arrow_element_percent,echo_strike_chance_percent
  )
  values(
    'blooddrinker_battleaxe',
    'Секира кровопийцы',
    'Тяжёлая секира для физического бойца. Встроенный вампиризм восстанавливает 6% прямого нанесённого урона как ОЗ.',
    'weapon'::public.item_category,
    'uncommon'::public.item_rarity,
    'weapon',
    false,1,
    '{"strength":2}'::jsonb,
    '[]'::jsonb,
    170,
    4,3,0,false,
    'slashing','{}'::jsonb,
    null,'',
    'lifesteal',6,
    '{}'::jsonb,
    10,'strength','battleaxe',
    0,0,20,0
  )
  on conflict(slug) do update set
    name=excluded.name,
    description=excluded.description,
    rarity=excluded.rarity,
    equip_group=excluded.equip_group,
    stat_modifiers=excluded.stat_modifiers,
    base_value=excluded.base_value,
    required_level=excluded.required_level,
    shop_tier=excluded.shop_tier,
    shop_price=excluded.shop_price,
    shop_enabled=excluded.shop_enabled,
    damage_type=excluded.damage_type,
    damage_resistances=excluded.damage_resistances,
    unique_property_name=excluded.unique_property_name,
    unique_property_description=excluded.unique_property_description,
    unique_effect_type=excluded.unique_effect_type,
    unique_effect_value=excluded.unique_effect_value,
    weapon_base_damage=excluded.weapon_base_damage,
    weapon_scaling=excluded.weapon_scaling,
    weapon_family=excluded.weapon_family,
    updated_at=now()
  returning id
),
item as (
  select id from upsert_item
  union all
  select id from public.item_definitions where slug='blooddrinker_battleaxe'
  limit 1
)
insert into public.loot_pool_entries(
  source_type,enemy_template_id,sector_id,terrain_type,
  min_danger,max_danger,item_definition_id,chance_percent,
  min_quantity,max_quantity,enabled
)
select
  'dungeon',null,null,null,
  3,5,item.id,5.00,
  1,1,true
from item
where not exists(
  select 1
  from public.loot_pool_entries l
  where l.source_type='dungeon'
    and l.item_definition_id=item.id
    and l.sector_id is null
    and l.enemy_template_id is null
    and l.min_danger=3
    and l.max_danger=5
);
