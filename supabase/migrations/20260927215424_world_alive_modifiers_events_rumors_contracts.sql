-- Synced from live Supabase migration 20260927215424 (world_alive_modifiers_events_rumors_contracts)


insert into public.dungeon_modifier_definitions
(slug,name,description,min_danger,max_danger,weight,enemy_hp_percent,enemy_attack_percent,enemy_defense_percent,reward_gold_percent,reward_xp_percent,rare_boss_bonus_percent,theme)
values
('cursed_depths','Проклятые глубины','Стены шепчут, враги бьют больнее, но добыча и награды заметно выше.',1,10,5,10,18,0,25,20,8,'curse'),
('unstable_magic','Нестабильная магия','Магические потоки искажают бой: враги агрессивнее, но их защита хуже.',1,10,5,0,12,-10,15,15,6,'arcane'),
('treasure_echoes','Эхо сокровищ','В глубине слышен звон старых тайников. Противники чуть крепче, зато золота значительно больше.',1,10,4,8,0,0,35,10,4,'treasure'),
('elite_guard','Элитная охрана','Подземелье заняла усиленная стража. Здесь опаснее всего, но и награда соответствующая.',2,10,3,25,12,15,35,30,12,'elite'),
('fragile_depths','Хрупкие глубины','Всё здесь нестабильно: и враги, и ты чувствуете, что бой закончится быстро.',1,10,4,-15,25,-10,20,15,7,'risk'),
('ancient_seal','Древняя печать','Старинные защитные руны укрепляют обитателей подземелья. Разбить их тяжело, но выгодно.',2,10,3,15,0,25,20,25,10,'ancient')
on conflict(slug) do update set
name=excluded.name,description=excluded.description,min_danger=excluded.min_danger,max_danger=excluded.max_danger,
weight=excluded.weight,enemy_hp_percent=excluded.enemy_hp_percent,enemy_attack_percent=excluded.enemy_attack_percent,
enemy_defense_percent=excluded.enemy_defense_percent,reward_gold_percent=excluded.reward_gold_percent,
reward_xp_percent=excluded.reward_xp_percent,rare_boss_bonus_percent=excluded.rare_boss_bonus_percent,
theme=excluded.theme,enabled=true,updated_at=now();

insert into public.dungeon_event_definitions(slug,name,description,min_danger,max_danger,weight,choices,auto_choice)
values
('healing_spring','Тёплый источник','Между залами ты находишь тёплый источник. Вода пахнет металлом, но выглядит чистой.',0,10,6,
 '[{"slug":"drink","label":"Выпить","result":"Тёплая вода затягивает раны и проясняет мысли.","effect":{"hp_percent":25,"mana_percent":15}},{"slug":"leave","label":"Не трогать","result":"Ты проходишь мимо, не рискуя.","effect":{}}]'::jsonb,'drink'),
('blood_altar','Алтарь без имени','На камне засохли старые следы крови. Кто-то явно оставлял здесь дары задолго до тебя.',1,10,3,
 '[{"slug":"offer","label":"Оставить кровь","result":"Алтарь принимает дар. Где-то в стене открывается тайник.","effect":{"hp_percent":-15,"gold_delta":45,"discovery_slug":"nameless_altar","discovery_title":"Алтарь без имени","discovery_description":"Странный алтарь реагирует на кровь. Его происхождение неизвестно."}},{"slug":"leave","label":"Уйти","result":"Лучше не трогать то, чего не понимаешь.","effect":{}}]'::jsonb,'leave'),
('sealed_cache','Запечатанный тайник','За осыпавшейся кладкой скрыт сундук с сорванной печатью. Замок всё ещё держится.',1,10,5,
 '[{"slug":"force","label":"Взломать силой","result":"Ты вскрываешь тайник, поранившись об осколки металла.","effect":{"hp_percent":-10,"gold_delta":30,"item_slug":"treasure_map_faded","item_chance":25}},{"slug":"leave","label":"Оставить","result":"Сундук остаётся ждать следующего искателя.","effect":{}}]'::jsonb,'leave'),
('wounded_traveler','Раненый странник','У стены сидит незнакомец. Он просит воды и немного монет на дорогу.',0,10,4,
 '[{"slug":"help","label":"Помочь · 15 золота","result":"Странник благодарит тебя и отдаёт потрёпанный клочок карты.","effect":{"gold_delta":-15,"item_slug":"treasure_map_faded","item_chance":65,"discovery_slug":"wounded_traveler","discovery_title":"Раненый странник","discovery_description":"Не каждый, кого встречаешь в подземелье, хочет драться."}},{"slug":"leave","label":"Пройти мимо","result":"Ты оставляешь странника позади.","effect":{}}]'::jsonb,'leave'),
('echo_shrine','Шепчущая ниша','В стене вырезан символ, которого нет ни в одном известном тебе храме.',1,10,3,
 '[{"slug":"touch","label":"Коснуться символа","result":"На миг ты слышишь чужой шёпот. Мана возвращается, а символ гаснет.","effect":{"mana_percent":35,"discovery_slug":"whispering_shrine","discovery_title":"Шепчущая ниша","discovery_description":"Неизвестный символ отзывается на прикосновение магической энергией."}},{"slug":"leave","label":"Не трогать","result":"Ты запоминаешь символ и уходишь.","effect":{"discovery_slug":"whispering_shrine_seen","discovery_title":"Неизвестный символ","discovery_description":"В подземельях встречаются знаки, не похожие на символы известных религий."}}]'::jsonb,'leave'),
('unstable_portal','Треснувший портал','Арка из чёрного камня мерцает на секунду, будто пространство за ней дышит.',2,10,2,
 '[{"slug":"enter","label":"Шагнуть внутрь","result":"Портал выбрасывает тебя обратно, но ты успеваешь выхватить что-то из темноты.","effect":{"risk_good_chance":60,"good":{"gold_delta":75,"item_slug":"treasure_map_royal","item_chance":20},"bad":{"hp_percent":-22,"mana_percent":-20}}},{"slug":"leave","label":"Не рисковать","result":"Портал схлопывается сам собой.","effect":{}}]'::jsonb,'leave')
on conflict(slug) do update set
name=excluded.name,description=excluded.description,min_danger=excluded.min_danger,max_danger=excluded.max_danger,
weight=excluded.weight,choices=excluded.choices,auto_choice=excluded.auto_choice,enabled=true,updated_at=now();

insert into public.world_rumors(slug,title,body,min_level)
values
('rumor_black_arch','Чёрная арка','Говорят, в некоторых подземельях на секунду появляется арка из чёрного камня. Те, кто вошёл, рассказывают разные истории.',2),
('rumor_moss_king','Король под корнями','Лесники Вардена клянутся, что видели оленя с короной из живого мха. Обычные стрелы его только злят.',1),
('rumor_glass_song','Песня стекла','Караванщики Сахрета слышат звон из-под песка. Иногда после него находят идеально круглые стеклянные следы.',2),
('rumor_unknown_gods','Незнакомые символы','В старых нишах находят знаки, которых нет в книгах известных культов. Некоторые отвечают на прикосновение.',1),
('rumor_maps','Карты без автора','По рукам ходят карты, где кресты нанесены поверх очень старых дорог. Никто не знает, кто продолжает их рисовать.',1),
('rumor_bell','Колокол в камне','В горах иногда слышен одиночный колокол там, где нет ни дорог, ни храмов.',3),
('rumor_mirror','Человек без лица','Несколько искателей рассказывали о фигуре в гладкой маске, повторяющей их движения.',2),
('rumor_cursed_gear','Вещи с ценой','Старые торговцы предупреждают: не вся сильная вещь делает владельца сильнее во всём. Некоторые обязательно забирают что-то взамен.',2),
('rumor_treasure_echo','Звон за стеной','Если в подземелье слышен звон монет из пустой стены — не спеши считать это галлюцинацией.',1),
('rumor_wanderer','Торговец без дороги','Иногда в поселении появляется человек с телегой, которую никто не видел у городских ворот.',1)
on conflict(slug) do update set title=excluded.title,body=excluded.body,min_level=excluded.min_level,enabled=true;

insert into public.settlement_quest_definitions(sector_id,title,description,theme,objective_type,objective_target,reward_gold,reward_experience,reward_reputation,min_level,repeatable,cooldown_hours,enabled,sort_order)
values
(131,'Проверить старые подвалы','В Вардене снова жалуются на шум под складами. Зачисти 1 подземелье.','protection','complete_dungeons',1,32,28,35,1,true,18,true,20),
(131,'Тише на дорогах','Разберись с 4 противниками, мешающими путникам.','combat','defeat_enemies',4,28,24,30,1,true,12,true,21),
(170,'Полевые наблюдения','Лиавену нужны данные о 2 завершённых экспедициях.','research','complete_expeditions',2,48,42,45,2,true,18,true,30),
(170,'Нестабильные образцы','Победи 6 противников для сравнительного отчёта.','arcane','defeat_enemies',6,52,46,45,2,true,18,true,31),
(230,'Песок помнит','Зачисти 2 подземелья для караванной службы Сахрета.','protection','complete_dungeons',2,78,64,55,4,true,20,true,40),
(230,'Белые пятна карты','Открой 2 новых сектора и принеси координаты картографам.','general','discover_sectors',2,74,68,55,4,true,24,true,41)
on conflict do nothing;

