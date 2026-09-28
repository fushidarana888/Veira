-- Synced from live Supabase migration 20260928195255 (add_exploration_speed_dungeon_gear)


create or replace function private.character_equipment_exploration_speed_percent(
  p_character_id uuid
) returns integer
language sql
stable
security definer
set search_path='pg_catalog','public','private'
as $$
  select coalesce(sum(
    case
      when jsonb_typeof(d.stat_modifiers->'exploration_speed_percent')='number'
        then (d.stat_modifiers->>'exploration_speed_percent')::numeric::integer
      else 0
    end
    + case
      when jsonb_typeof(ci.metadata->'affix_stat_modifiers'->'exploration_speed_percent')='number'
        then (ci.metadata->'affix_stat_modifiers'->>'exploration_speed_percent')::numeric::integer
      else 0
    end
    + case
      when jsonb_typeof(ci.metadata->'religion_stat_modifiers'->'exploration_speed_percent')='number'
        then (ci.metadata->'religion_stat_modifiers'->>'exploration_speed_percent')::numeric::integer
      else 0
    end
  ),0)::integer
  from public.character_equipment ce
  join public.character_items ci on ci.id=ce.character_item_id
  join public.item_definitions d on d.id=ci.item_definition_id
  where ce.character_id=p_character_id;
$$;

create or replace function private.character_accessory_exploration_speed_percent(
  p_character_id uuid
) returns integer
language sql
stable
security definer
set search_path='pg_catalog','public','private'
as $$
  select private.character_equipment_exploration_speed_percent(p_character_id);
$$;

create or replace function private.character_exploration_speed_percent(
  p_character_id uuid
) returns integer
language sql
stable
security definer
set search_path='pg_catalog','public','private'
as $$
  select greatest(
    -75,
    least(
      300,
      private.character_religion_modifier_number(p_character_id,'exploration_speed_percent')
      + private.character_equipment_exploration_speed_percent(p_character_id)
    )
  );
$$;

insert into public.item_definitions(
  slug,name,description,category,rarity,equip_group,stackable,max_stack,
  stat_modifiers,effects,base_value,required_level,shop_enabled
)
values
(
  'trailfinder_compass',
  'Компас первопроходца',
  'Простой компас с насечками старых маршрутов. Ускоряет исследование мира на 15%.',
  'accessory','uncommon','accessory',false,1,
  '{"luck":1,"exploration_speed_percent":15}'::jsonb,
  '[]'::jsonb,180,2,false
),
(
  'cartographer_hood',
  'Капюшон картографа',
  'Лёгкий капюшон с набором меток и складной линзой. Ускоряет исследование мира на 20%.',
  'armor','rare','head',false,1,
  '{"agility":2,"luck":1,"exploration_speed_percent":20}'::jsonb,
  '[]'::jsonb,420,4,false
),
(
  'pathfinder_boots',
  'Сапоги дальнего следа',
  'Походные сапоги, созданные для долгих переходов по незнакомой местности. Ускоряют исследование мира на 25%.',
  'armor','rare','feet',false,1,
  '{"agility":3,"vitality":1,"exploration_speed_percent":25}'::jsonb,
  '[]'::jsonb,760,7,false
),
(
  'frontier_cloak',
  'Плащ Последней Тропы',
  'Плащ опытного исследователя, сохраняющий тепло и скрывающий силуэт на дальних переходах. Ускоряет исследование мира на 35%.',
  'armor','epic','chest',false,1,
  '{"agility":3,"vitality":3,"luck":1,"exploration_speed_percent":35}'::jsonb,
  '[]'::jsonb,1500,11,false
),
(
  'worldline_astrolabe',
  'Астролябия Края Мира',
  'Редкий навигационный прибор, сверяющий путь со звёздами и древними линиями мира. Ускоряет исследование мира на 50%.',
  'accessory','legendary','accessory',false,1,
  '{"luck":4,"intellect":3,"exploration_speed_percent":50}'::jsonb,
  '[]'::jsonb,3600,16,false
)
on conflict(slug) do update set
  name=excluded.name,
  description=excluded.description,
  category=excluded.category,
  rarity=excluded.rarity,
  equip_group=excluded.equip_group,
  stackable=excluded.stackable,
  max_stack=excluded.max_stack,
  stat_modifiers=excluded.stat_modifiers,
  effects=excluded.effects,
  base_value=excluded.base_value,
  required_level=excluded.required_level,
  shop_enabled=false,
  updated_at=now();

delete from public.loot_pool_entries
where source_type='dungeon'
  and item_definition_id in (
    select id from public.item_definitions
    where slug in (
      'trailfinder_compass',
      'cartographer_hood',
      'pathfinder_boots',
      'frontier_cloak',
      'worldline_astrolabe'
    )
  );

insert into public.loot_pool_entries(
  source_type,enemy_template_id,sector_id,terrain_type,
  min_danger,max_danger,item_definition_id,
  chance_percent,min_quantity,max_quantity,enabled
)
select 'dungeon',null,null,null,x.min_danger,x.max_danger,i.id,
       x.chance_percent,1,1,true
from (
  values
    ('trailfinder_compass',1::smallint,2::smallint,4.00::numeric),
    ('cartographer_hood',3::smallint,4::smallint,3.00::numeric),
    ('pathfinder_boots',5::smallint,6::smallint,2.40::numeric),
    ('frontier_cloak',7::smallint,8::smallint,1.50::numeric),
    ('worldline_astrolabe',9::smallint,10::smallint,0.70::numeric)
) x(slug,min_danger,max_danger,chance_percent)
join public.item_definitions i on i.slug=x.slug;

