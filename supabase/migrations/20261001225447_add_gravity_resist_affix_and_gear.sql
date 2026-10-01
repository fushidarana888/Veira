insert into public.equipment_affixes(
  slug,name,description,enabled,min_rarity_rank,max_rarity_rank,weight,
  allowed_categories,allowed_equip_groups,stat_modifiers,damage_resistances,
  unique_effect_type,unique_effect_value
)
values(
  'gravity_anchor',
  'Гравитационный якорь',
  'Стабилизирует владельца в искажённом поле и снижает урон гравитацией.',
  true,3,5,50,
  array['armor','accessory']::text[],
  '{}'::text[],
  '{}'::jsonb,
  '{"gravity":10}'::jsonb,
  null,0
)
on conflict (slug) do update set
  name=excluded.name,
  description=excluded.description,
  enabled=excluded.enabled,
  min_rarity_rank=excluded.min_rarity_rank,
  max_rarity_rank=excluded.max_rarity_rank,
  weight=excluded.weight,
  allowed_categories=excluded.allowed_categories,
  allowed_equip_groups=excluded.allowed_equip_groups,
  stat_modifiers=excluded.stat_modifiers,
  damage_resistances=excluded.damage_resistances,
  unique_effect_type=excluded.unique_effect_type,
  unique_effect_value=excluded.unique_effect_value,
  updated_at=now();

insert into public.item_definitions(
  slug,name,description,category,rarity,equip_group,
  stackable,max_stack,stat_modifiers,damage_resistances,
  base_value,required_level,shop_tier,shop_price,shop_enabled,
  unique_property_name,unique_property_description,trade_policy
)
values(
  'counterweight_seal',
  'Печать противовеса',
  'Тяжёлая печать с подвижным внутренним кольцом. При скачке гравитации кольцо уходит в противофазу и удерживает владельца в собственной точке опоры.',
  'accessory'::public.item_category,
  'rare'::public.item_rarity,
  'accessory'::public.item_equip_group,
  false,1,
  '{"vitality":3}'::jsonb,
  '{"gravity":12}'::jsonb,
  340,6,0,0,false,
  'Противофаза',
  '+12% сопротивления гравитации. Создана как ранний способ подготовиться к противникам, искажающим вес и пространство.',
  'tradeable'
)
on conflict (slug) do update set
  name=excluded.name,
  description=excluded.description,
  category=excluded.category,
  rarity=excluded.rarity,
  equip_group=excluded.equip_group,
  stat_modifiers=excluded.stat_modifiers,
  damage_resistances=excluded.damage_resistances,
  base_value=excluded.base_value,
  required_level=excluded.required_level,
  shop_enabled=false,
  unique_property_name=excluded.unique_property_name,
  unique_property_description=excluded.unique_property_description,
  updated_at=now();

delete from public.loot_pool_entries
where source_type='dungeon'
  and sector_id=207
  and item_definition_id=(select id from public.item_definitions where slug='counterweight_seal');

insert into public.loot_pool_entries(
  source_type,sector_id,terrain_type,min_danger,max_danger,item_definition_id,
  chance_percent,min_quantity,max_quantity,enabled
)
select
  'dungeon',207::smallint,null,4::smallint,4::smallint,id,
  5.00,1,1,true
from public.item_definitions
where slug='counterweight_seal';
