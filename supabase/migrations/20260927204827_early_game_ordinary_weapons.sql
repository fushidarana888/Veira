-- Synced from live Supabase migration 20260927204827 (early_game_ordinary_weapons)

insert into public.item_definitions(
slug,name,description,category,rarity,equip_group,stackable,max_stack,stat_modifiers,effects,base_value,
required_level,shop_tier,shop_price,shop_enabled,damage_type,damage_resistances,damage_bonuses,
weapon_base_damage,weapon_scaling,weapon_family,bow_full_draw_armor_penetration_percent,shop_sector_id
) values
('field_sword','Полевой меч','Простой, надёжный меч для первых походов.','weapon','common','weapon',false,1,'{"strength":1}'::jsonb,'[]'::jsonb,19,1,0,42,true,'slashing','{}'::jsonb,'{}'::jsonb,6,'strength','sword',0,null),
('ashwood_spear','Копьё из ясеня','Лёгкое копьё с равным упором на силу и ловкость.','weapon','common','weapon',false,1,'{"strength":1,"agility":1}'::jsonb,'[]'::jsonb,21,1,0,46,true,'piercing','{}'::jsonb,'{}'::jsonb,7,'hybrid','spear',0,null),
('hunter_shortbow','Охотничий короткий лук','Ранний ловкостной лук. Полный натяг лучше работает против брони.','weapon','common','weapon',false,1,'{"agility":1}'::jsonb,'[]'::jsonb,22,1,0,48,true,'piercing','{}'::jsonb,'{}'::jsonb,5,'agility','short_bow',30,127),
('stone_mace','Каменная булава','Тяжёлое простое оружие, хорошо подходящее силовым персонажам.','weapon','common','weapon',false,1,'{"vitality":1}'::jsonb,'[]'::jsonb,20,1,0,44,true,'blunt','{}'::jsonb,'{}'::jsonb,7,'strength','mace',0,null),
('training_rapier','Учебная рапира','Быстрое колющее оружие для ловкостного старта.','weapon','common','weapon',false,1,'{"agility":1}'::jsonb,'[]'::jsonb,18,1,0,40,true,'piercing','{}'::jsonb,'{}'::jsonb,5,'agility','rapier',0,null),
('birch_wand','Берёзовый жезл','Простейший жезл, усиливающий интеллект, но почти бесполезный в рукопашной.','weapon','common','weapon',false,1,'{"intellect":1}'::jsonb,'[]'::jsonb,17,1,0,38,true,'blunt','{}'::jsonb,'{}'::jsonb,2,'hybrid','wand',0,131),
('iron_hatchet','Железный топорик','Короткий топор с хорошим ранним вкладом силы.','weapon','uncommon','weapon',false,1,'{"strength":2}'::jsonb,'[]'::jsonb,37,2,1,82,true,'slashing','{}'::jsonb,'{}'::jsonb,8,'strength','axe',0,null),
('scout_shortbow','Короткий лук разведчика','Усиленный лук для мобильного стрелка.','weapon','uncommon','weapon',false,1,'{"agility":2}'::jsonb,'[]'::jsonb,41,2,1,92,true,'piercing','{}'::jsonb,'{}'::jsonb,7,'agility','short_bow',35,127),
('reed_spear','Копьё речного тростника','Гибридное копьё с хорошим балансом скорости и силы.','weapon','common','weapon',false,1,'{"strength":1,"agility":1}'::jsonb,'[]'::jsonb,34,2,1,76,true,'piercing','{}'::jsonb,'{}'::jsonb,8,'hybrid','spear',0,153),
('quarry_hammer','Молот каменолома','Медленный, но тяжёлый дробящий молот.','weapon','uncommon','weapon',false,1,'{"strength":1,"vitality":2}'::jsonb,'[]'::jsonb,44,2,1,98,true,'blunt','{}'::jsonb,'{}'::jsonb,9,'strength','hammer',0,null),
('copper_rapier','Медная рапира','Точная рапира для ранней ловкостной сборки.','weapon','uncommon','weapon',false,1,'{"agility":2,"luck":1}'::jsonb,'[]'::jsonb,42,2,1,94,true,'piercing','{}'::jsonb,'{}'::jsonb,6,'agility','rapier',0,153),
('ember_wand','Угольный жезл','Жезл с тёплым сердечником. Усиливает огненную магию.','weapon','uncommon','weapon',false,1,'{"intellect":2}'::jsonb,'[]'::jsonb,50,2,2,112,true,'blunt','{}'::jsonb,'{"fire":4}'::jsonb,3,'hybrid','wand',0,170),
('guard_sword','Меч городской стражи','Уверенный силовой меч для середины ранней игры.','weapon','uncommon','weapon',false,1,'{"strength":3,"vitality":1}'::jsonb,'[]'::jsonb,71,3,2,158,true,'slashing','{}'::jsonb,'{}'::jsonb,9,'strength','sword',0,170),
('ranger_longbow','Длинный лук рейнджера','Силовой длинный лук с сильным полным натягом.','weapon','uncommon','weapon',false,1,'{"strength":2,"agility":1}'::jsonb,'[]'::jsonb,76,3,2,168,true,'piercing','{}'::jsonb,'{}'::jsonb,10,'strength','long_bow',50,170),
('needle_rapier','Рапира «Игла»','Тонкая рапира, делающая ставку на ловкость и удачу.','weapon','uncommon','weapon',false,1,'{"agility":3,"luck":1}'::jsonb,'[]'::jsonb,73,3,2,162,true,'piercing','{}'::jsonb,'{}'::jsonb,7,'agility','rapier',0,170),
('dust_spear','Пыльное копьё','Сбалансированное гибридное копьё, популярное у караванщиков.','weapon','uncommon','weapon',false,1,'{"strength":2,"agility":2}'::jsonb,'[]'::jsonb,77,3,2,172,true,'piercing','{}'::jsonb,'{}'::jsonb,11,'hybrid','spear',0,170),
('oak_wand','Дубовый жезл','Крепкий жезл ученика-мага с небольшим усилением земли и воды.','weapon','uncommon','weapon',false,1,'{"intellect":3,"luck":1}'::jsonb,'[]'::jsonb,80,3,2,178,true,'blunt','{}'::jsonb,'{"earth":3,"water":3}'::jsonb,4,'hybrid','wand',0,170),
('iron_greatsword','Железный двуручный меч','Большой силовой клинок с высоким базовым уроном.','weapon','uncommon','weapon',false,1,'{"strength":4}'::jsonb,'[]'::jsonb,110,4,3,245,true,'slashing','{}'::jsonb,'{}'::jsonb,11,'strength','greatsword',0,228),
('composite_shortbow','Составной короткий лук','Быстрый лук высокого качества для ловкостных персонажей.','weapon','uncommon','weapon',false,1,'{"agility":4}'::jsonb,'[]'::jsonb,107,4,3,238,true,'piercing','{}'::jsonb,'{}'::jsonb,9,'agility','short_bow',40,228),
('war_mace','Боевая булава','Тяжёлая булава, сочетающая силу и живучесть.','weapon','uncommon','weapon',false,1,'{"strength":3,"vitality":2}'::jsonb,'[]'::jsonb,112,4,3,248,true,'blunt','{}'::jsonb,'{}'::jsonb,11,'strength','mace',0,228),
('hardened_spear','Закалённое копьё','Сильное гибридное копьё для ровной STR/AGI-сборки.','weapon','uncommon','weapon',false,1,'{"strength":3,"agility":3}'::jsonb,'[]'::jsonb,122,4,4,272,true,'piercing','{}'::jsonb,'{}'::jsonb,13,'hybrid','spear',0,230),
('arcane_staff','Арканный посох','Первый полноценный посох. Даёт большой прирост INT и усиливает арканную магию.','weapon','uncommon','weapon',false,1,'{"intellect":4,"luck":1}'::jsonb,'[]'::jsonb,142,4,4,315,true,'blunt','{}'::jsonb,'{"arcane":4}'::jsonb,4,'hybrid','staff',0,230)
on conflict(slug) do update set name=excluded.name,description=excluded.description,category=excluded.category,rarity=excluded.rarity,
equip_group=excluded.equip_group,stat_modifiers=excluded.stat_modifiers,base_value=excluded.base_value,required_level=excluded.required_level,
shop_tier=excluded.shop_tier,shop_price=excluded.shop_price,shop_enabled=excluded.shop_enabled,damage_type=excluded.damage_type,
damage_resistances=excluded.damage_resistances,damage_bonuses=excluded.damage_bonuses,weapon_base_damage=excluded.weapon_base_damage,
weapon_scaling=excluded.weapon_scaling,weapon_family=excluded.weapon_family,bow_full_draw_armor_penetration_percent=excluded.bow_full_draw_armor_penetration_percent,
shop_sector_id=excluded.shop_sector_id,updated_at=now();
