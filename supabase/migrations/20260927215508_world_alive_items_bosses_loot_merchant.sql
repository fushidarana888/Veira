-- Synced from live Supabase migration 20260927215508 (world_alive_items_bosses_loot_merchant)


insert into public.item_definitions(
 slug,name,description,category,rarity,equip_group,stackable,max_stack,stat_modifiers,effects,base_value,
 required_level,shop_tier,shop_price,shop_enabled,damage_resistances,damage_bonuses,
 unique_property_name,unique_property_description,unique_effect_type,unique_effect_value
)
values
('treasure_map_faded','Выцветшая карта сокровищ','На карте отмечен знакомый сектор, но крест явно нанесён недавно. Активируется в разделе «Приключения».','consumable','uncommon',null,true,20,'{}'::jsonb,'[]'::jsonb,45,1,0,0,false,'{}'::jsonb,'{}'::jsonb,'След на полях','После активации карта укажет сектор. Нужно совершить туда новую экспедицию и забрать тайник.',null,0),
('treasure_map_royal','Карта с золотой печатью','Редкая карта, запечатанная выцветшим гербом. Тайник обещает быть серьёзнее обычного.','consumable','rare',null,true,10,'{}'::jsonb,'[]'::jsonb,110,3,0,0,false,'{}'::jsonb,'{}'::jsonb,'Золотая печать','После активации указывает сектор с богатым тайником.',null,0),
('cursed_glass_ring','Кольцо треснувшего стекла','Чёрное стекло усиливает магию, но медленно вытягивает жизненную силу владельца.','accessory','unique','accessory',false,1,'{"intellect":3,"luck":2,"max_hp_percent":-12}'::jsonb,'[]'::jsonb,180,2,0,0,false,'{"arcane":5}'::jsonb,'{"arcane":6}'::jsonb,'Плата отражению','Сильный ранний магический талисман ценой −12% максимального HP.',null,0),
('blessed_wayfarer_charm','Оберег тихой дороги','Тёплый камень, который становится чуть тяжелее рядом с опасностью.','accessory','unique','accessory',false,1,'{"vitality":2,"luck":2}'::jsonb,'[]'::jsonb,170,2,0,0,false,'{"blunt":3,"piercing":3,"slashing":3,"fire":3,"water":3,"earth":3,"air":3,"ice":3,"lightning":3}'::jsonb,'{}'::jsonb,'Тихая дорога','Небольшая защита почти от всего без побочного эффекта.',null,0),
('cursed_bone_mask','Костяная маска охотника','Маска делает движения яростнее. Носить её долго неприятно даже физически.','armor','unique','head',false,1,'{"strength":4,"luck":2,"vitality":-2}'::jsonb,'[]'::jsonb,250,3,0,0,false,'{"fire":-10}'::jsonb,'{"slashing":6}'::jsonb,'Голод охотника','Сильный атакующий профиль: больше силы и режущего урона, но меньше живучести и слабость к огню.',null,0),
('blessed_moonthread_cloak','Плащ лунной нити','Серебристая ткань остаётся прохладной даже в пустыне и едва заметно светится ночью.','armor','unique','chest',false,1,'{"intellect":3,"agility":2}'::jsonb,'[]'::jsonb,315,4,0,0,false,'{"ice":8,"moon":10}'::jsonb,'{"moon":6}'::jsonb,'Лунная нить','Усиливает лунную магию и защищает от холода.',null,0),
('black_mirror_talisman','Талисман чёрного зеркала','В отражении иногда видно не владельца, а пустую комнату позади него.','accessory','unique','accessory',false,1,'{"intellect":4,"max_hp_percent":-15}'::jsonb,'[]'::jsonb,340,4,0,0,false,'{"arcane":8}'::jsonb,'{"arcane":8}'::jsonb,'Чужое отражение','+8% арканного урона и +4 INT, но −15% максимального HP. Успешная прямая атака возвращает 2 маны.','mana_on_hit',2),
('oathbreaker_greaves','Поножи клятвопреступника','Лёгкая броня, будто созданная для того, чтобы не останавливаться ни перед чем.','armor','rare','legs',false,1,'{"agility":4,"strength":2,"vitality":-2}'::jsonb,'[]'::jsonb,270,4,0,0,false,'{"piercing":6}'::jsonb,'{}'::jsonb,'Ни шага назад','Высокая мобильность и атака ценой части живучести.',null,0),
('trophy_moss_crown','Трофей: мшистая корона','Рога редкого лесного чудовища, обросшие живым мхом.','material','unique',null,true,20,'{}'::jsonb,'[]'::jsonb,90,1,0,0,false,'{}'::jsonb,'{}'::jsonb,null,'',null,0),
('trophy_glass_heart','Трофей: стеклянное сердце','Сердцевина пустынного хранителя. Даже остыв, она звенит как бокал.','material','unique',null,true,20,'{}'::jsonb,'[]'::jsonb,120,1,0,0,false,'{}'::jsonb,'{}'::jsonb,null,'',null,0),
('trophy_bog_eye','Трофей: глаз трясины','Глаз редкого болотного существа. В мутной жидкости что-то продолжает двигаться.','material','unique',null,true,20,'{}'::jsonb,'[]'::jsonb,110,1,0,0,false,'{}'::jsonb,'{}'::jsonb,null,'',null,0),
('trophy_bell_core','Трофей: колокольное ядро','Металлическое ядро горного конструкта. Если встряхнуть, слышен далёкий удар колокола.','material','unique',null,true,20,'{}'::jsonb,'[]'::jsonb,140,1,0,0,false,'{}'::jsonb,'{}'::jsonb,null,'',null,0),
('trophy_pale_scale','Трофей: бледная чешуя','Почти прозрачная чешуя северного хищника.','material','unique',null,true,20,'{}'::jsonb,'[]'::jsonb,155,1,0,0,false,'{}'::jsonb,'{}'::jsonb,null,'',null,0),
('ancient_coin_cache','Связка древних монет','Монеты разных эпох, найденные в тайнике. Коллекционеры за такое платят хорошо.','material','rare',null,true,99,'{}'::jsonb,'[]'::jsonb,65,1,0,0,false,'{}'::jsonb,'{}'::jsonb,null,'',null,0)
on conflict(slug) do update set
name=excluded.name,description=excluded.description,rarity=excluded.rarity,equip_group=excluded.equip_group,stackable=excluded.stackable,
max_stack=excluded.max_stack,stat_modifiers=excluded.stat_modifiers,base_value=excluded.base_value,required_level=excluded.required_level,
shop_enabled=false,damage_resistances=excluded.damage_resistances,damage_bonuses=excluded.damage_bonuses,
unique_property_name=excluded.unique_property_name,unique_property_description=excluded.unique_property_description,
unique_effect_type=excluded.unique_effect_type,unique_effect_value=excluded.unique_effect_value,updated_at=now();

insert into public.enemy_templates(
 slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,attack_damage_type,
 damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,
 on_hit_effect_type,on_hit_effect_chance,on_hit_effect_turns,on_hit_effect_potency,
 special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,
 special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,
 special_kind,special_value,phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,
 phase2_special_every_n,is_strong_enemy,is_rare_variant
)
values
('moss_crowned_stag','Мшистый король','Редкий древний олень, чьи рога заросли мхом и корнями.',true,'forest',1,5,true,1,'piercing',
 '{"earth":25,"fire":-25,"slashing":10}'::jsonb,1.18,1.12,0.95,1.18,
 'bleed',35,2,5,'Корневой разбег',1.45,3,'piercing','bleed',70,2,7,'Король скребёт землю рогами и готовится к разбегу.','Мшистый король пробивает зал корневым разбегом!','attack',0,40,'Последний гон',20,0,2,true,true),
('ash_horn_boar','Пепельный Рог','Огромный секач со шрамами, будто его уже пытались сжечь.',true,'plains',1,5,true,1,'blunt',
 '{"fire":20,"piercing":-15,"blunt":10}'::jsonb,1.15,1.18,1.02,1.10,
 null,0,0,0,'Пепельный таран',1.55,3,'blunt','stun',35,1,0,'Пепельный Рог отходит к стене, набирая дистанцию.','Секач врезается в цель всем весом!','attack',0,35,'Бешенство',25,-5,2,true,true),
('glass_warden','Стеклянный хранитель','Пустынный страж из спёкшегося песка. Свет проходит сквозь трещины в его теле.',true,'desert',2,6,true,1,'earth',
 '{"earth":35,"fire":30,"blunt":-20,"water":-25}'::jsonb,1.22,1.10,1.22,0.95,
 null,0,0,0,'Стеклянный обвал',1.40,4,'earth','vulnerable',55,2,12,'По телу хранителя бегут яркие трещины.','Стеклянные пластины обрушиваются градом осколков!','attack',0,45,'Красное стекло',20,20,3,true,true),
('bog_oracle','Оракул трясины','Редкое болотное существо, которое будто знает, куда ты увернёшься.',true,'swamp',2,6,true,1,'water',
 '{"water":35,"earth":20,"fire":-20,"lightning":-15}'::jsonb,1.12,1.16,1.05,1.25,
 'poison',35,3,5,'Чёрное предсказание',1.30,3,'water','weaken',75,2,18,'Оракул замолкает и смотрит прямо сквозь тебя.','Чёрная вода повторяет движение ещё до того, как ты его сделал!','attack',0,35,'Вторая судьба',15,10,2,true,true),
('bell_golem','Колокольный голем','Горный конструкт с полым металлическим ядром. Каждый шаг звучит как удар колокола.',true,'mountains',3,7,true,1,'blunt',
 '{"blunt":30,"piercing":25,"lightning":-25}'::jsonb,1.28,1.10,1.28,0.90,
 null,0,0,0,'Погребальный звон',1.55,4,'blunt','stun',50,1,0,'В груди голема начинает гудеть тяжёлый металл.','Колокольный удар проходит через камень и кости!','attack',0,50,'Раскол ядра',25,-10,2,true,true),
('pale_wyrm','Бледный змей','Северный хищник, почти прозрачный на фоне льда.',true,'tundra',4,9,true,1,'ice',
 '{"ice":45,"fire":-35,"slashing":15}'::jsonb,1.20,1.22,1.05,1.30,
 'chill',50,2,18,'Белая петля',1.45,3,'ice','chill',90,3,25,'Змей сворачивается кольцом, и воздух резко холодает.','Белая петля захлопывается вокруг цели!','attack',0,30,'Подлёдная ярость',30,0,2,true,true),
('mirror_pilgrim','Зеркальный паломник','Фигура в гладкой маске. Никто не знает, кто скрывается под ней.',true,null,2,7,true,1,'arcane',
 '{"arcane":35,"moon":15,"blunt":-15}'::jsonb,1.10,1.20,1.10,1.20,
 null,0,0,0,'Отражённый жест',1.35,3,'arcane','vulnerable',65,2,15,'Паломник повторяет твою стойку с идеальной точностью.','Зеркальная фигура атакует твоим же ритмом!','attack',0,40,'Лицо за маской',25,10,2,true,true)
on conflict(slug) do update set
name=excluded.name,description=excluded.description,enabled=true,terrain_type=excluded.terrain_type,
min_danger=excluded.min_danger,max_danger=excluded.max_danger,is_boss=true,weight=excluded.weight,
attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,
hp_multiplier=excluded.hp_multiplier,attack_multiplier=excluded.attack_multiplier,defense_multiplier=excluded.defense_multiplier,
initiative_multiplier=excluded.initiative_multiplier,on_hit_effect_type=excluded.on_hit_effect_type,
on_hit_effect_chance=excluded.on_hit_effect_chance,on_hit_effect_turns=excluded.on_hit_effect_turns,on_hit_effect_potency=excluded.on_hit_effect_potency,
special_name=excluded.special_name,special_damage_multiplier=excluded.special_damage_multiplier,special_every_n=excluded.special_every_n,
special_damage_type=excluded.special_damage_type,special_effect_type=excluded.special_effect_type,
special_effect_chance=excluded.special_effect_chance,special_effect_turns=excluded.special_effect_turns,
special_effect_potency=excluded.special_effect_potency,special_telegraph_text=excluded.special_telegraph_text,
special_attack_text=excluded.special_attack_text,special_kind=excluded.special_kind,special_value=excluded.special_value,
phase2_hp_percent=excluded.phase2_hp_percent,phase2_name=excluded.phase2_name,
phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,phase2_defense_bonus_percent=excluded.phase2_defense_bonus_percent,
phase2_special_every_n=excluded.phase2_special_every_n,is_strong_enemy=true,is_rare_variant=true,updated_at=now();

insert into public.loot_pool_entries(source_type,enemy_template_id,terrain_type,min_danger,max_danger,item_definition_id,chance_percent,min_quantity,max_quantity,enabled)
select 'boss',e.id,e.terrain_type,e.min_danger,e.max_danger,i.id,x.chance,1,1,true
from (values
 ('moss_crowned_stag','trophy_moss_crown',100::numeric),
 ('moss_crowned_stag','blessed_wayfarer_charm',12::numeric),
 ('ash_horn_boar','cursed_bone_mask',10::numeric),
 ('glass_warden','trophy_glass_heart',100::numeric),
 ('glass_warden','cursed_glass_ring',11::numeric),
 ('bog_oracle','trophy_bog_eye',100::numeric),
 ('bog_oracle','black_mirror_talisman',7::numeric),
 ('bell_golem','trophy_bell_core',100::numeric),
 ('bell_golem','oathbreaker_greaves',9::numeric),
 ('pale_wyrm','trophy_pale_scale',100::numeric),
 ('pale_wyrm','blessed_moonthread_cloak',10::numeric),
 ('mirror_pilgrim','black_mirror_talisman',10::numeric)
) x(enemy_slug,item_slug,chance)
join public.enemy_templates e on e.slug=x.enemy_slug
join public.item_definitions i on i.slug=x.item_slug
where not exists(
  select 1 from public.loot_pool_entries l
  where l.enemy_template_id=e.id and l.item_definition_id=i.id and l.source_type='boss'
);

insert into public.loot_pool_entries(source_type,min_danger,max_danger,item_definition_id,chance_percent,min_quantity,max_quantity,enabled)
select 'dungeon',0,10,i.id,case when i.slug='treasure_map_faded' then 4.5 else 1.5 end,1,1,true
from public.item_definitions i
where i.slug in ('treasure_map_faded','treasure_map_royal')
  and not exists(select 1 from public.loot_pool_entries l where l.item_definition_id=i.id and l.source_type='dungeon');

insert into public.wandering_merchant_catalog(item_definition_id,min_level,max_level,offer_price,weight,enabled)
select i.id,x.min_level,99,x.price,1,true
from (values
 ('treasure_map_faded',1,95),
 ('treasure_map_royal',3,220),
 ('cursed_glass_ring',2,310),
 ('blessed_wayfarer_charm',2,300),
 ('cursed_bone_mask',3,410),
 ('blessed_moonthread_cloak',4,520),
 ('black_mirror_talisman',4,560),
 ('oathbreaker_greaves',4,460),
 ('cast_scroll_mirror_barrier',2,140),
 ('cast_scroll_healing_spark',2,120)
) x(slug,min_level,price)
join public.item_definitions i on i.slug=x.slug
on conflict(item_definition_id) do update
set min_level=excluded.min_level,max_level=excluded.max_level,offer_price=excluded.offer_price,enabled=true;

