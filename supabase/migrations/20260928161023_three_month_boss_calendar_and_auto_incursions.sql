-- Synced from live Supabase migration 20260928161023 (three_month_boss_calendar_and_auto_incursions)


insert into public.enemy_templates(
 slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,
 attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,
 special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,
 special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,
 phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,phase2_special_every_n,
 abilities,is_strong_enemy,is_rare_variant
)
values(
 'calendar_weekly_2026_09_28_ash_matron','Пепельная Матрона','Матрона несёт в себе тлеющий очаг и превращает лечение и выживание в борьбу на истощение.',true,null,0,10,true,1,
 'fire','{"fire":35,"water":-25,"ice":-15}'::jsonb,1,1,1,1,
 'Похоронный уголь',1.65,3,'fire','burn',70,2,15,
 'Пепельная Матрона готовит «Похоронный уголь».','Пепельная Матрона применяет «Похоронный уголь».',
 40,'Последний очаг',20,10,2,
 '[{"id":"weekly_2026_09_28_ash_matron_special","kind":"attack","name":"Похоронный уголь","phase":0,"value":0,"enabled":true,"cooldown":2,"max_uses":0,"priority":75,"attack_text":"Пепельная Матрона применяет «Похоронный уголь».","damage_type":"fire","effect_type":"burn","min_debuffs":0,"effect_turns":2,"effect_chance":70,"effect_potency":15,"telegraph_text":"Пепельная Матрона готовит «Похоронный уголь».","damage_multiplier":1.65,"max_enemy_hp_percent":100,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0},{"id":"weekly_2026_09_28_ash_matron_phase","kind":"enrage","name":"Последний очаг","phase":2,"value":20,"enabled":true,"cooldown":9,"max_uses":1,"priority":90,"attack_text":"Пепельная Матрона: Последний очаг.","damage_type":null,"effect_type":null,"min_debuffs":0,"effect_turns":0,"effect_chance":0,"effect_potency":0,"telegraph_text":"Фаза меняется: Последний очаг.","damage_multiplier":0,"max_enemy_hp_percent":40,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0}]'::jsonb,true,false
)
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,
 special_name=excluded.special_name,special_damage_multiplier=excluded.special_damage_multiplier,
 special_every_n=excluded.special_every_n,special_damage_type=excluded.special_damage_type,
 special_effect_type=excluded.special_effect_type,special_effect_chance=excluded.special_effect_chance,
 special_effect_turns=excluded.special_effect_turns,special_effect_potency=excluded.special_effect_potency,
 special_telegraph_text=excluded.special_telegraph_text,special_attack_text=excluded.special_attack_text,
 phase2_hp_percent=excluded.phase2_hp_percent,phase2_name=excluded.phase2_name,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,
 phase2_defense_bonus_percent=excluded.phase2_defense_bonus_percent,
 phase2_special_every_n=excluded.phase2_special_every_n,abilities=excluded.abilities,is_strong_enemy=true,updated_at=now();

insert into public.event_boss_events(
 slug,boss_kind,name,description,enabled,starts_at,ends_at,enemy_template_id,
 recommended_level,solo_enemy_level,solo_hp,solo_attack,solo_defense,solo_initiative,
 party_hp_per_extra,party_attack_per_extra,party_defense_per_extra,
 special_reward_item_id,first_reward_gold,first_reward_experience,repeat_reward_gold,repeat_reward_experience,
 special_every_n,special_damage_multiplier,phase2_hp_percent,phase2_attack_bonus_percent,
 solo_only,max_victories_per_character,mechanics,global_clear_target,
 reward_material_item_id,reward_material_quantity,featured_loot
)
select
 'weekly_2026_09_28_ash_matron','weekly','Пепельная Матрона',
 'Матрона несёт в себе тлеющий очаг и превращает лечение и выживание в борьбу на истощение. Каждая победа даёт материал босса. Уникальная вещь может выпасть сразу или быть гарантированно создана из накопленных материалов.',
 true,'2026-09-28T15:00:00Z'::timestamptz,'2026-10-05T15:00:00Z'::timestamptz,et.id,
 5,7,520,38,20,15,
 0.7,0.10,0.06,
 null,180,180,35,30,
 3,1.65,40,20,false,null,
 '{"scheduled":true,"loot_model":"material_plus_drop"}'::jsonb,null,
 mat.id,1,'[{"slug":"last_ember_vessel","chance_percent":10,"craft_cost":8}]'::jsonb
from public.enemy_templates et
join public.item_definitions mat on mat.slug='matron_last_cinder'
where et.slug='calendar_weekly_2026_09_28_ash_matron'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 starts_at=excluded.starts_at,ends_at=excluded.ends_at,enemy_template_id=excluded.enemy_template_id,
 recommended_level=excluded.recommended_level,solo_enemy_level=excluded.solo_enemy_level,
 solo_hp=excluded.solo_hp,solo_attack=excluded.solo_attack,solo_defense=excluded.solo_defense,
 solo_initiative=excluded.solo_initiative,first_reward_gold=excluded.first_reward_gold,
 first_reward_experience=excluded.first_reward_experience,repeat_reward_gold=excluded.repeat_reward_gold,
 repeat_reward_experience=excluded.repeat_reward_experience,special_every_n=excluded.special_every_n,
 special_damage_multiplier=excluded.special_damage_multiplier,phase2_hp_percent=excluded.phase2_hp_percent,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,mechanics=excluded.mechanics,
 reward_material_item_id=excluded.reward_material_item_id,reward_material_quantity=excluded.reward_material_quantity,
 featured_loot=excluded.featured_loot,updated_at=now();

insert into public.crafting_recipes(slug,name,description,enabled,required_level,gold_cost,output_item_definition_id,output_quantity,affix_bonus,sort_order)
select 'boss_last_ember_vessel','Создать: '||out.name,
 'Гарантированное создание уникальной добычи босса из 8 материалов его ротации.',
 true,out.required_level,450,out.id,1,0,3000+out.required_level
from public.item_definitions out where out.slug='last_ember_vessel'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 required_level=excluded.required_level,gold_cost=excluded.gold_cost,output_item_definition_id=excluded.output_item_definition_id,
 output_quantity=1,affix_bonus=0,sort_order=excluded.sort_order,updated_at=now();

insert into public.crafting_recipe_ingredients(recipe_id,item_definition_id,quantity)
select r.id,m.id,8
from public.crafting_recipes r join public.item_definitions m on m.slug='matron_last_cinder'
where r.slug='boss_last_ember_vessel'
on conflict(recipe_id,item_definition_id) do update set quantity=excluded.quantity;

insert into public.enemy_templates(
 slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,
 attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,
 special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,
 special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,
 phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,phase2_special_every_n,
 abilities,is_strong_enemy,is_rare_variant
)
values(
 'calendar_weekly_2026_10_05_blind_duelist','Слепой Дуэлянт','Он не смотрит на оружие противника — только слушает шаги и отвечает на каждую ошибку мгновенным выпадом.',true,null,0,10,true,1,
 'piercing','{"piercing":20,"blunt":-20,"air":15}'::jsonb,1,1,1,1,
 'Ответ без взгляда',1.55,3,'piercing','vulnerable',70,2,15,
 'Слепой Дуэлянт готовит «Ответ без взгляда».','Слепой Дуэлянт применяет «Ответ без взгляда».',
 35,'Идеальный слух',20,0,2,
 '[{"id":"weekly_2026_10_05_blind_duelist_special","kind":"attack","name":"Ответ без взгляда","phase":0,"value":0,"enabled":true,"cooldown":2,"max_uses":0,"priority":75,"attack_text":"Слепой Дуэлянт применяет «Ответ без взгляда».","damage_type":"piercing","effect_type":"vulnerable","min_debuffs":0,"effect_turns":2,"effect_chance":70,"effect_potency":15,"telegraph_text":"Слепой Дуэлянт готовит «Ответ без взгляда».","damage_multiplier":1.55,"max_enemy_hp_percent":100,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0},{"id":"weekly_2026_10_05_blind_duelist_phase","kind":"enrage","name":"Идеальный слух","phase":2,"value":20,"enabled":true,"cooldown":9,"max_uses":1,"priority":90,"attack_text":"Слепой Дуэлянт: Идеальный слух.","damage_type":null,"effect_type":null,"min_debuffs":0,"effect_turns":0,"effect_chance":0,"effect_potency":0,"telegraph_text":"Фаза меняется: Идеальный слух.","damage_multiplier":0,"max_enemy_hp_percent":35,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0}]'::jsonb,true,false
)
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,
 special_name=excluded.special_name,special_damage_multiplier=excluded.special_damage_multiplier,
 special_every_n=excluded.special_every_n,special_damage_type=excluded.special_damage_type,
 special_effect_type=excluded.special_effect_type,special_effect_chance=excluded.special_effect_chance,
 special_effect_turns=excluded.special_effect_turns,special_effect_potency=excluded.special_effect_potency,
 special_telegraph_text=excluded.special_telegraph_text,special_attack_text=excluded.special_attack_text,
 phase2_hp_percent=excluded.phase2_hp_percent,phase2_name=excluded.phase2_name,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,
 phase2_defense_bonus_percent=excluded.phase2_defense_bonus_percent,
 phase2_special_every_n=excluded.phase2_special_every_n,abilities=excluded.abilities,is_strong_enemy=true,updated_at=now();

insert into public.event_boss_events(
 slug,boss_kind,name,description,enabled,starts_at,ends_at,enemy_template_id,
 recommended_level,solo_enemy_level,solo_hp,solo_attack,solo_defense,solo_initiative,
 party_hp_per_extra,party_attack_per_extra,party_defense_per_extra,
 special_reward_item_id,first_reward_gold,first_reward_experience,repeat_reward_gold,repeat_reward_experience,
 special_every_n,special_damage_multiplier,phase2_hp_percent,phase2_attack_bonus_percent,
 solo_only,max_victories_per_character,mechanics,global_clear_target,
 reward_material_item_id,reward_material_quantity,featured_loot
)
select
 'weekly_2026_10_05_blind_duelist','weekly','Слепой Дуэлянт',
 'Он не смотрит на оружие противника — только слушает шаги и отвечает на каждую ошибку мгновенным выпадом. Каждая победа даёт материал босса. Уникальная вещь может выпасть сразу или быть гарантированно создана из накопленных материалов.',
 true,'2026-10-05T15:00:00Z'::timestamptz,'2026-10-12T15:00:00Z'::timestamptz,et.id,
 6,8,560,43,18,28,
 0.7,0.10,0.06,
 null,180,180,35,30,
 3,1.55,35,20,false,null,
 '{"scheduled":true,"loot_model":"material_plus_drop"}'::jsonb,null,
 mat.id,1,'[{"slug":"blind_duelist_thread","chance_percent":10,"craft_cost":8}]'::jsonb
from public.enemy_templates et
join public.item_definitions mat on mat.slug='duelist_blind_thread'
where et.slug='calendar_weekly_2026_10_05_blind_duelist'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 starts_at=excluded.starts_at,ends_at=excluded.ends_at,enemy_template_id=excluded.enemy_template_id,
 recommended_level=excluded.recommended_level,solo_enemy_level=excluded.solo_enemy_level,
 solo_hp=excluded.solo_hp,solo_attack=excluded.solo_attack,solo_defense=excluded.solo_defense,
 solo_initiative=excluded.solo_initiative,first_reward_gold=excluded.first_reward_gold,
 first_reward_experience=excluded.first_reward_experience,repeat_reward_gold=excluded.repeat_reward_gold,
 repeat_reward_experience=excluded.repeat_reward_experience,special_every_n=excluded.special_every_n,
 special_damage_multiplier=excluded.special_damage_multiplier,phase2_hp_percent=excluded.phase2_hp_percent,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,mechanics=excluded.mechanics,
 reward_material_item_id=excluded.reward_material_item_id,reward_material_quantity=excluded.reward_material_quantity,
 featured_loot=excluded.featured_loot,updated_at=now();

insert into public.crafting_recipes(slug,name,description,enabled,required_level,gold_cost,output_item_definition_id,output_quantity,affix_bonus,sort_order)
select 'boss_blind_duelist_thread','Создать: '||out.name,
 'Гарантированное создание уникальной добычи босса из 8 материалов его ротации.',
 true,out.required_level,450,out.id,1,0,3000+out.required_level
from public.item_definitions out where out.slug='blind_duelist_thread'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 required_level=excluded.required_level,gold_cost=excluded.gold_cost,output_item_definition_id=excluded.output_item_definition_id,
 output_quantity=1,affix_bonus=0,sort_order=excluded.sort_order,updated_at=now();

insert into public.crafting_recipe_ingredients(recipe_id,item_definition_id,quantity)
select r.id,m.id,8
from public.crafting_recipes r join public.item_definitions m on m.slug='duelist_blind_thread'
where r.slug='boss_blind_duelist_thread'
on conflict(recipe_id,item_definition_id) do update set quantity=excluded.quantity;

insert into public.enemy_templates(
 slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,
 attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,
 special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,
 special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,
 phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,phase2_special_every_n,
 abilities,is_strong_enemy,is_rare_variant
)
values(
 'calendar_weekly_2026_10_12_storm_shepherd','Грозовой Пастырь','Пастырь стягивает молнии к посоху и наказывает тех, кто бездумно расходует ресурс.',true,null,0,10,true,1,
 'lightning','{"lightning":40,"earth":-25,"water":15}'::jsonb,1,1,1,1,
 'Стадо молний',1.8,4,'lightning','weaken',70,2,15,
 'Грозовой Пастырь готовит «Стадо молний».','Грозовой Пастырь применяет «Стадо молний».',
 45,'Чёрная гроза',25,5,3,
 '[{"id":"weekly_2026_10_12_storm_shepherd_special","kind":"attack","name":"Стадо молний","phase":0,"value":0,"enabled":true,"cooldown":3,"max_uses":0,"priority":75,"attack_text":"Грозовой Пастырь применяет «Стадо молний».","damage_type":"lightning","effect_type":"weaken","min_debuffs":0,"effect_turns":2,"effect_chance":70,"effect_potency":15,"telegraph_text":"Грозовой Пастырь готовит «Стадо молний».","damage_multiplier":1.8,"max_enemy_hp_percent":100,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0},{"id":"weekly_2026_10_12_storm_shepherd_phase","kind":"enrage","name":"Чёрная гроза","phase":2,"value":25,"enabled":true,"cooldown":9,"max_uses":1,"priority":90,"attack_text":"Грозовой Пастырь: Чёрная гроза.","damage_type":null,"effect_type":null,"min_debuffs":0,"effect_turns":0,"effect_chance":0,"effect_potency":0,"telegraph_text":"Фаза меняется: Чёрная гроза.","damage_multiplier":0,"max_enemy_hp_percent":45,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0}]'::jsonb,true,false
)
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,
 special_name=excluded.special_name,special_damage_multiplier=excluded.special_damage_multiplier,
 special_every_n=excluded.special_every_n,special_damage_type=excluded.special_damage_type,
 special_effect_type=excluded.special_effect_type,special_effect_chance=excluded.special_effect_chance,
 special_effect_turns=excluded.special_effect_turns,special_effect_potency=excluded.special_effect_potency,
 special_telegraph_text=excluded.special_telegraph_text,special_attack_text=excluded.special_attack_text,
 phase2_hp_percent=excluded.phase2_hp_percent,phase2_name=excluded.phase2_name,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,
 phase2_defense_bonus_percent=excluded.phase2_defense_bonus_percent,
 phase2_special_every_n=excluded.phase2_special_every_n,abilities=excluded.abilities,is_strong_enemy=true,updated_at=now();

insert into public.event_boss_events(
 slug,boss_kind,name,description,enabled,starts_at,ends_at,enemy_template_id,
 recommended_level,solo_enemy_level,solo_hp,solo_attack,solo_defense,solo_initiative,
 party_hp_per_extra,party_attack_per_extra,party_defense_per_extra,
 special_reward_item_id,first_reward_gold,first_reward_experience,repeat_reward_gold,repeat_reward_experience,
 special_every_n,special_damage_multiplier,phase2_hp_percent,phase2_attack_bonus_percent,
 solo_only,max_victories_per_character,mechanics,global_clear_target,
 reward_material_item_id,reward_material_quantity,featured_loot
)
select
 'weekly_2026_10_12_storm_shepherd','weekly','Грозовой Пастырь',
 'Пастырь стягивает молнии к посоху и наказывает тех, кто бездумно расходует ресурс. Каждая победа даёт материал босса. Уникальная вещь может выпасть сразу или быть гарантированно создана из накопленных материалов.',
 true,'2026-10-12T15:00:00Z'::timestamptz,'2026-10-19T15:00:00Z'::timestamptz,et.id,
 7,9,620,47,22,23,
 0.7,0.10,0.06,
 null,180,180,35,30,
 4,1.8,45,25,false,null,
 '{"scheduled":true,"loot_model":"material_plus_drop"}'::jsonb,null,
 mat.id,1,'[{"slug":"stored_storm_staff","chance_percent":10,"craft_cost":8}]'::jsonb
from public.enemy_templates et
join public.item_definitions mat on mat.slug='storm_shepherd_core'
where et.slug='calendar_weekly_2026_10_12_storm_shepherd'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 starts_at=excluded.starts_at,ends_at=excluded.ends_at,enemy_template_id=excluded.enemy_template_id,
 recommended_level=excluded.recommended_level,solo_enemy_level=excluded.solo_enemy_level,
 solo_hp=excluded.solo_hp,solo_attack=excluded.solo_attack,solo_defense=excluded.solo_defense,
 solo_initiative=excluded.solo_initiative,first_reward_gold=excluded.first_reward_gold,
 first_reward_experience=excluded.first_reward_experience,repeat_reward_gold=excluded.repeat_reward_gold,
 repeat_reward_experience=excluded.repeat_reward_experience,special_every_n=excluded.special_every_n,
 special_damage_multiplier=excluded.special_damage_multiplier,phase2_hp_percent=excluded.phase2_hp_percent,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,mechanics=excluded.mechanics,
 reward_material_item_id=excluded.reward_material_item_id,reward_material_quantity=excluded.reward_material_quantity,
 featured_loot=excluded.featured_loot,updated_at=now();

insert into public.crafting_recipes(slug,name,description,enabled,required_level,gold_cost,output_item_definition_id,output_quantity,affix_bonus,sort_order)
select 'boss_stored_storm_staff','Создать: '||out.name,
 'Гарантированное создание уникальной добычи босса из 8 материалов его ротации.',
 true,out.required_level,450,out.id,1,0,3000+out.required_level
from public.item_definitions out where out.slug='stored_storm_staff'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 required_level=excluded.required_level,gold_cost=excluded.gold_cost,output_item_definition_id=excluded.output_item_definition_id,
 output_quantity=1,affix_bonus=0,sort_order=excluded.sort_order,updated_at=now();

insert into public.crafting_recipe_ingredients(recipe_id,item_definition_id,quantity)
select r.id,m.id,8
from public.crafting_recipes r join public.item_definitions m on m.slug='storm_shepherd_core'
where r.slug='boss_stored_storm_staff'
on conflict(recipe_id,item_definition_id) do update set quantity=excluded.quantity;

insert into public.enemy_templates(
 slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,
 attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,
 special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,
 special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,
 phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,phase2_special_every_n,
 abilities,is_strong_enemy,is_rare_variant
)
values(
 'calendar_weekly_2026_10_19_root_devourer','Пожиратель Корней','Старая тварь болот питается болезнями и сама становится крепче, когда бой затягивается.',true,null,0,10,true,1,
 'earth','{"earth":40,"fire":-30,"slashing":-10}'::jsonb,1,1,1,1,
 'Гнилой венец',1.45,3,'earth','poison',70,2,15,
 'Пожиратель Корней готовит «Гнилой венец».','Пожиратель Корней применяет «Гнилой венец».',
 40,'Сердце болота',15,25,2,
 '[{"id":"weekly_2026_10_19_root_devourer_special","kind":"attack","name":"Гнилой венец","phase":0,"value":0,"enabled":true,"cooldown":2,"max_uses":0,"priority":75,"attack_text":"Пожиратель Корней применяет «Гнилой венец».","damage_type":"earth","effect_type":"poison","min_debuffs":0,"effect_turns":2,"effect_chance":70,"effect_potency":15,"telegraph_text":"Пожиратель Корней готовит «Гнилой венец».","damage_multiplier":1.45,"max_enemy_hp_percent":100,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0},{"id":"weekly_2026_10_19_root_devourer_phase","kind":"enrage","name":"Сердце болота","phase":2,"value":15,"enabled":true,"cooldown":9,"max_uses":1,"priority":90,"attack_text":"Пожиратель Корней: Сердце болота.","damage_type":null,"effect_type":null,"min_debuffs":0,"effect_turns":0,"effect_chance":0,"effect_potency":0,"telegraph_text":"Фаза меняется: Сердце болота.","damage_multiplier":0,"max_enemy_hp_percent":40,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0}]'::jsonb,true,false
)
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,
 special_name=excluded.special_name,special_damage_multiplier=excluded.special_damage_multiplier,
 special_every_n=excluded.special_every_n,special_damage_type=excluded.special_damage_type,
 special_effect_type=excluded.special_effect_type,special_effect_chance=excluded.special_effect_chance,
 special_effect_turns=excluded.special_effect_turns,special_effect_potency=excluded.special_effect_potency,
 special_telegraph_text=excluded.special_telegraph_text,special_attack_text=excluded.special_attack_text,
 phase2_hp_percent=excluded.phase2_hp_percent,phase2_name=excluded.phase2_name,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,
 phase2_defense_bonus_percent=excluded.phase2_defense_bonus_percent,
 phase2_special_every_n=excluded.phase2_special_every_n,abilities=excluded.abilities,is_strong_enemy=true,updated_at=now();

insert into public.event_boss_events(
 slug,boss_kind,name,description,enabled,starts_at,ends_at,enemy_template_id,
 recommended_level,solo_enemy_level,solo_hp,solo_attack,solo_defense,solo_initiative,
 party_hp_per_extra,party_attack_per_extra,party_defense_per_extra,
 special_reward_item_id,first_reward_gold,first_reward_experience,repeat_reward_gold,repeat_reward_experience,
 special_every_n,special_damage_multiplier,phase2_hp_percent,phase2_attack_bonus_percent,
 solo_only,max_victories_per_character,mechanics,global_clear_target,
 reward_material_item_id,reward_material_quantity,featured_loot
)
select
 'weekly_2026_10_19_root_devourer','weekly','Пожиратель Корней',
 'Старая тварь болот питается болезнями и сама становится крепче, когда бой затягивается. Каждая победа даёт материал босса. Уникальная вещь может выпасть сразу или быть гарантированно создана из накопленных материалов.',
 true,'2026-10-19T15:00:00Z'::timestamptz,'2026-10-26T15:00:00Z'::timestamptz,et.id,
 8,10,720,50,28,14,
 0.7,0.10,0.06,
 null,180,180,35,30,
 3,1.45,40,15,false,null,
 '{"scheduled":true,"loot_model":"material_plus_drop"}'::jsonb,null,
 mat.id,1,'[{"slug":"living_bark_cuirass","chance_percent":10,"craft_cost":8}]'::jsonb
from public.enemy_templates et
join public.item_definitions mat on mat.slug='root_devourer_heartwood'
where et.slug='calendar_weekly_2026_10_19_root_devourer'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 starts_at=excluded.starts_at,ends_at=excluded.ends_at,enemy_template_id=excluded.enemy_template_id,
 recommended_level=excluded.recommended_level,solo_enemy_level=excluded.solo_enemy_level,
 solo_hp=excluded.solo_hp,solo_attack=excluded.solo_attack,solo_defense=excluded.solo_defense,
 solo_initiative=excluded.solo_initiative,first_reward_gold=excluded.first_reward_gold,
 first_reward_experience=excluded.first_reward_experience,repeat_reward_gold=excluded.repeat_reward_gold,
 repeat_reward_experience=excluded.repeat_reward_experience,special_every_n=excluded.special_every_n,
 special_damage_multiplier=excluded.special_damage_multiplier,phase2_hp_percent=excluded.phase2_hp_percent,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,mechanics=excluded.mechanics,
 reward_material_item_id=excluded.reward_material_item_id,reward_material_quantity=excluded.reward_material_quantity,
 featured_loot=excluded.featured_loot,updated_at=now();

insert into public.crafting_recipes(slug,name,description,enabled,required_level,gold_cost,output_item_definition_id,output_quantity,affix_bonus,sort_order)
select 'boss_living_bark_cuirass','Создать: '||out.name,
 'Гарантированное создание уникальной добычи босса из 8 материалов его ротации.',
 true,out.required_level,450,out.id,1,0,3000+out.required_level
from public.item_definitions out where out.slug='living_bark_cuirass'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 required_level=excluded.required_level,gold_cost=excluded.gold_cost,output_item_definition_id=excluded.output_item_definition_id,
 output_quantity=1,affix_bonus=0,sort_order=excluded.sort_order,updated_at=now();

insert into public.crafting_recipe_ingredients(recipe_id,item_definition_id,quantity)
select r.id,m.id,8
from public.crafting_recipes r join public.item_definitions m on m.slug='root_devourer_heartwood'
where r.slug='boss_living_bark_cuirass'
on conflict(recipe_id,item_definition_id) do update set quantity=excluded.quantity;

insert into public.enemy_templates(
 slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,
 attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,
 special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,
 special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,
 phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,phase2_special_every_n,
 abilities,is_strong_enemy,is_rare_variant
)
values(
 'calendar_weekly_2026_10_26_crystal_stag','Хрустальный Олень','Каждый его рывок оставляет в воздухе хрупкие кристаллические линии, которые можно обратить против него.',true,null,0,10,true,1,
 'piercing','{"ice":35,"piercing":20,"blunt":-25}'::jsonb,1,1,1,1,
 'Хрустальный разгон',1.7,3,'piercing','bleed',70,2,15,
 'Хрустальный Олень готовит «Хрустальный разгон».','Хрустальный Олень применяет «Хрустальный разгон».',
 35,'Расколотые рога',30,0,2,
 '[{"id":"weekly_2026_10_26_crystal_stag_special","kind":"attack","name":"Хрустальный разгон","phase":0,"value":0,"enabled":true,"cooldown":2,"max_uses":0,"priority":75,"attack_text":"Хрустальный Олень применяет «Хрустальный разгон».","damage_type":"piercing","effect_type":"bleed","min_debuffs":0,"effect_turns":2,"effect_chance":70,"effect_potency":15,"telegraph_text":"Хрустальный Олень готовит «Хрустальный разгон».","damage_multiplier":1.7,"max_enemy_hp_percent":100,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0},{"id":"weekly_2026_10_26_crystal_stag_phase","kind":"enrage","name":"Расколотые рога","phase":2,"value":30,"enabled":true,"cooldown":9,"max_uses":1,"priority":90,"attack_text":"Хрустальный Олень: Расколотые рога.","damage_type":null,"effect_type":null,"min_debuffs":0,"effect_turns":0,"effect_chance":0,"effect_potency":0,"telegraph_text":"Фаза меняется: Расколотые рога.","damage_multiplier":0,"max_enemy_hp_percent":35,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0}]'::jsonb,true,false
)
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,
 special_name=excluded.special_name,special_damage_multiplier=excluded.special_damage_multiplier,
 special_every_n=excluded.special_every_n,special_damage_type=excluded.special_damage_type,
 special_effect_type=excluded.special_effect_type,special_effect_chance=excluded.special_effect_chance,
 special_effect_turns=excluded.special_effect_turns,special_effect_potency=excluded.special_effect_potency,
 special_telegraph_text=excluded.special_telegraph_text,special_attack_text=excluded.special_attack_text,
 phase2_hp_percent=excluded.phase2_hp_percent,phase2_name=excluded.phase2_name,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,
 phase2_defense_bonus_percent=excluded.phase2_defense_bonus_percent,
 phase2_special_every_n=excluded.phase2_special_every_n,abilities=excluded.abilities,is_strong_enemy=true,updated_at=now();

insert into public.event_boss_events(
 slug,boss_kind,name,description,enabled,starts_at,ends_at,enemy_template_id,
 recommended_level,solo_enemy_level,solo_hp,solo_attack,solo_defense,solo_initiative,
 party_hp_per_extra,party_attack_per_extra,party_defense_per_extra,
 special_reward_item_id,first_reward_gold,first_reward_experience,repeat_reward_gold,repeat_reward_experience,
 special_every_n,special_damage_multiplier,phase2_hp_percent,phase2_attack_bonus_percent,
 solo_only,max_victories_per_character,mechanics,global_clear_target,
 reward_material_item_id,reward_material_quantity,featured_loot
)
select
 'weekly_2026_10_26_crystal_stag','weekly','Хрустальный Олень',
 'Каждый его рывок оставляет в воздухе хрупкие кристаллические линии, которые можно обратить против него. Каждая победа даёт материал босса. Уникальная вещь может выпасть сразу или быть гарантированно создана из накопленных материалов.',
 true,'2026-10-26T15:00:00Z'::timestamptz,'2026-11-02T15:00:00Z'::timestamptz,et.id,
 9,11,760,56,26,31,
 0.7,0.10,0.06,
 null,180,180,35,30,
 3,1.7,35,30,false,null,
 '{"scheduled":true,"loot_model":"material_plus_drop"}'::jsonb,null,
 mat.id,1,'[{"slug":"crystal_vein_bow","chance_percent":10,"craft_cost":8}]'::jsonb
from public.enemy_templates et
join public.item_definitions mat on mat.slug='crystal_stag_antler'
where et.slug='calendar_weekly_2026_10_26_crystal_stag'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 starts_at=excluded.starts_at,ends_at=excluded.ends_at,enemy_template_id=excluded.enemy_template_id,
 recommended_level=excluded.recommended_level,solo_enemy_level=excluded.solo_enemy_level,
 solo_hp=excluded.solo_hp,solo_attack=excluded.solo_attack,solo_defense=excluded.solo_defense,
 solo_initiative=excluded.solo_initiative,first_reward_gold=excluded.first_reward_gold,
 first_reward_experience=excluded.first_reward_experience,repeat_reward_gold=excluded.repeat_reward_gold,
 repeat_reward_experience=excluded.repeat_reward_experience,special_every_n=excluded.special_every_n,
 special_damage_multiplier=excluded.special_damage_multiplier,phase2_hp_percent=excluded.phase2_hp_percent,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,mechanics=excluded.mechanics,
 reward_material_item_id=excluded.reward_material_item_id,reward_material_quantity=excluded.reward_material_quantity,
 featured_loot=excluded.featured_loot,updated_at=now();

insert into public.crafting_recipes(slug,name,description,enabled,required_level,gold_cost,output_item_definition_id,output_quantity,affix_bonus,sort_order)
select 'boss_crystal_vein_bow','Создать: '||out.name,
 'Гарантированное создание уникальной добычи босса из 8 материалов его ротации.',
 true,out.required_level,450,out.id,1,0,3000+out.required_level
from public.item_definitions out where out.slug='crystal_vein_bow'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 required_level=excluded.required_level,gold_cost=excluded.gold_cost,output_item_definition_id=excluded.output_item_definition_id,
 output_quantity=1,affix_bonus=0,sort_order=excluded.sort_order,updated_at=now();

insert into public.crafting_recipe_ingredients(recipe_id,item_definition_id,quantity)
select r.id,m.id,8
from public.crafting_recipes r join public.item_definitions m on m.slug='crystal_stag_antler'
where r.slug='boss_crystal_vein_bow'
on conflict(recipe_id,item_definition_id) do update set quantity=excluded.quantity;

insert into public.enemy_templates(
 slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,
 attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,
 special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,
 special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,
 phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,phase2_special_every_n,
 abilities,is_strong_enemy,is_rare_variant
)
values(
 'calendar_weekly_2026_11_02_faceless_monk','Монах Без Лица','Его молитва стирает различия между атакой и проклятием; первый ошибочный эффект часто возвращается к источнику.',true,null,0,10,true,1,
 'arcane','{"arcane":40,"blunt":-20,"moon":-10}'::jsonb,1,1,1,1,
 'Пустая молитва',1.6,4,'arcane','weaken',70,2,15,
 'Монах Без Лица готовит «Пустая молитва».','Монах Без Лица применяет «Пустая молитва».',
 40,'Лик за маской',20,15,3,
 '[{"id":"weekly_2026_11_02_faceless_monk_special","kind":"attack","name":"Пустая молитва","phase":0,"value":0,"enabled":true,"cooldown":3,"max_uses":0,"priority":75,"attack_text":"Монах Без Лица применяет «Пустая молитва».","damage_type":"arcane","effect_type":"weaken","min_debuffs":0,"effect_turns":2,"effect_chance":70,"effect_potency":15,"telegraph_text":"Монах Без Лица готовит «Пустая молитва».","damage_multiplier":1.6,"max_enemy_hp_percent":100,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0},{"id":"weekly_2026_11_02_faceless_monk_phase","kind":"enrage","name":"Лик за маской","phase":2,"value":20,"enabled":true,"cooldown":9,"max_uses":1,"priority":90,"attack_text":"Монах Без Лица: Лик за маской.","damage_type":null,"effect_type":null,"min_debuffs":0,"effect_turns":0,"effect_chance":0,"effect_potency":0,"telegraph_text":"Фаза меняется: Лик за маской.","damage_multiplier":0,"max_enemy_hp_percent":40,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0}]'::jsonb,true,false
)
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,
 special_name=excluded.special_name,special_damage_multiplier=excluded.special_damage_multiplier,
 special_every_n=excluded.special_every_n,special_damage_type=excluded.special_damage_type,
 special_effect_type=excluded.special_effect_type,special_effect_chance=excluded.special_effect_chance,
 special_effect_turns=excluded.special_effect_turns,special_effect_potency=excluded.special_effect_potency,
 special_telegraph_text=excluded.special_telegraph_text,special_attack_text=excluded.special_attack_text,
 phase2_hp_percent=excluded.phase2_hp_percent,phase2_name=excluded.phase2_name,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,
 phase2_defense_bonus_percent=excluded.phase2_defense_bonus_percent,
 phase2_special_every_n=excluded.phase2_special_every_n,abilities=excluded.abilities,is_strong_enemy=true,updated_at=now();

insert into public.event_boss_events(
 slug,boss_kind,name,description,enabled,starts_at,ends_at,enemy_template_id,
 recommended_level,solo_enemy_level,solo_hp,solo_attack,solo_defense,solo_initiative,
 party_hp_per_extra,party_attack_per_extra,party_defense_per_extra,
 special_reward_item_id,first_reward_gold,first_reward_experience,repeat_reward_gold,repeat_reward_experience,
 special_every_n,special_damage_multiplier,phase2_hp_percent,phase2_attack_bonus_percent,
 solo_only,max_victories_per_character,mechanics,global_clear_target,
 reward_material_item_id,reward_material_quantity,featured_loot
)
select
 'weekly_2026_11_02_faceless_monk','weekly','Монах Без Лица',
 'Его молитва стирает различия между атакой и проклятием; первый ошибочный эффект часто возвращается к источнику. Каждая победа даёт материал босса. Уникальная вещь может выпасть сразу или быть гарантированно создана из накопленных материалов.',
 true,'2026-11-02T15:00:00Z'::timestamptz,'2026-11-09T15:00:00Z'::timestamptz,et.id,
 10,12,820,58,30,24,
 0.7,0.10,0.06,
 null,180,180,35,30,
 4,1.6,40,20,false,null,
 '{"scheduled":true,"loot_model":"material_plus_drop"}'::jsonb,null,
 mat.id,1,'[{"slug":"faceless_mask","chance_percent":10,"craft_cost":8}]'::jsonb
from public.enemy_templates et
join public.item_definitions mat on mat.slug='faceless_prayer_bead'
where et.slug='calendar_weekly_2026_11_02_faceless_monk'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 starts_at=excluded.starts_at,ends_at=excluded.ends_at,enemy_template_id=excluded.enemy_template_id,
 recommended_level=excluded.recommended_level,solo_enemy_level=excluded.solo_enemy_level,
 solo_hp=excluded.solo_hp,solo_attack=excluded.solo_attack,solo_defense=excluded.solo_defense,
 solo_initiative=excluded.solo_initiative,first_reward_gold=excluded.first_reward_gold,
 first_reward_experience=excluded.first_reward_experience,repeat_reward_gold=excluded.repeat_reward_gold,
 repeat_reward_experience=excluded.repeat_reward_experience,special_every_n=excluded.special_every_n,
 special_damage_multiplier=excluded.special_damage_multiplier,phase2_hp_percent=excluded.phase2_hp_percent,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,mechanics=excluded.mechanics,
 reward_material_item_id=excluded.reward_material_item_id,reward_material_quantity=excluded.reward_material_quantity,
 featured_loot=excluded.featured_loot,updated_at=now();

insert into public.crafting_recipes(slug,name,description,enabled,required_level,gold_cost,output_item_definition_id,output_quantity,affix_bonus,sort_order)
select 'boss_faceless_mask','Создать: '||out.name,
 'Гарантированное создание уникальной добычи босса из 8 материалов его ротации.',
 true,out.required_level,450,out.id,1,0,3000+out.required_level
from public.item_definitions out where out.slug='faceless_mask'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 required_level=excluded.required_level,gold_cost=excluded.gold_cost,output_item_definition_id=excluded.output_item_definition_id,
 output_quantity=1,affix_bonus=0,sort_order=excluded.sort_order,updated_at=now();

insert into public.crafting_recipe_ingredients(recipe_id,item_definition_id,quantity)
select r.id,m.id,8
from public.crafting_recipes r join public.item_definitions m on m.slug='faceless_prayer_bead'
where r.slug='boss_faceless_mask'
on conflict(recipe_id,item_definition_id) do update set quantity=excluded.quantity;

insert into public.enemy_templates(
 slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,
 attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,
 special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,
 special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,
 phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,phase2_special_every_n,
 abilities,is_strong_enemy,is_rare_variant
)
values(
 'calendar_weekly_2026_11_09_clockmaker','Часовщик Семи Башен','Он ломает привычный порядок ходов: промедление даёт ему темп, а чистая серия действий позволяет вырваться вперёд.',true,null,0,10,true,1,
 'blunt','{"blunt":30,"lightning":-20,"gravity":20}'::jsonb,1,1,1,1,
 'Седьмой удар',1.75,3,'blunt','stun',70,2,15,
 'Часовщик Семи Башен готовит «Седьмой удар».','Часовщик Семи Башен применяет «Седьмой удар».',
 50,'Сбитый маятник',25,10,2,
 '[{"id":"weekly_2026_11_09_clockmaker_special","kind":"attack","name":"Седьмой удар","phase":0,"value":0,"enabled":true,"cooldown":2,"max_uses":0,"priority":75,"attack_text":"Часовщик Семи Башен применяет «Седьмой удар».","damage_type":"blunt","effect_type":"stun","min_debuffs":0,"effect_turns":2,"effect_chance":70,"effect_potency":15,"telegraph_text":"Часовщик Семи Башен готовит «Седьмой удар».","damage_multiplier":1.75,"max_enemy_hp_percent":100,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0},{"id":"weekly_2026_11_09_clockmaker_phase","kind":"enrage","name":"Сбитый маятник","phase":2,"value":25,"enabled":true,"cooldown":9,"max_uses":1,"priority":90,"attack_text":"Часовщик Семи Башен: Сбитый маятник.","damage_type":null,"effect_type":null,"min_debuffs":0,"effect_turns":0,"effect_chance":0,"effect_potency":0,"telegraph_text":"Фаза меняется: Сбитый маятник.","damage_multiplier":0,"max_enemy_hp_percent":50,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0}]'::jsonb,true,false
)
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,
 special_name=excluded.special_name,special_damage_multiplier=excluded.special_damage_multiplier,
 special_every_n=excluded.special_every_n,special_damage_type=excluded.special_damage_type,
 special_effect_type=excluded.special_effect_type,special_effect_chance=excluded.special_effect_chance,
 special_effect_turns=excluded.special_effect_turns,special_effect_potency=excluded.special_effect_potency,
 special_telegraph_text=excluded.special_telegraph_text,special_attack_text=excluded.special_attack_text,
 phase2_hp_percent=excluded.phase2_hp_percent,phase2_name=excluded.phase2_name,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,
 phase2_defense_bonus_percent=excluded.phase2_defense_bonus_percent,
 phase2_special_every_n=excluded.phase2_special_every_n,abilities=excluded.abilities,is_strong_enemy=true,updated_at=now();

insert into public.event_boss_events(
 slug,boss_kind,name,description,enabled,starts_at,ends_at,enemy_template_id,
 recommended_level,solo_enemy_level,solo_hp,solo_attack,solo_defense,solo_initiative,
 party_hp_per_extra,party_attack_per_extra,party_defense_per_extra,
 special_reward_item_id,first_reward_gold,first_reward_experience,repeat_reward_gold,repeat_reward_experience,
 special_every_n,special_damage_multiplier,phase2_hp_percent,phase2_attack_bonus_percent,
 solo_only,max_victories_per_character,mechanics,global_clear_target,
 reward_material_item_id,reward_material_quantity,featured_loot
)
select
 'weekly_2026_11_09_clockmaker','weekly','Часовщик Семи Башен',
 'Он ломает привычный порядок ходов: промедление даёт ему темп, а чистая серия действий позволяет вырваться вперёд. Каждая победа даёт материал босса. Уникальная вещь может выпасть сразу или быть гарантированно создана из накопленных материалов.',
 true,'2026-11-09T15:00:00Z'::timestamptz,'2026-11-16T15:00:00Z'::timestamptz,et.id,
 11,13,880,61,33,34,
 0.7,0.10,0.06,
 null,180,180,35,30,
 3,1.75,50,25,false,null,
 '{"scheduled":true,"loot_model":"material_plus_drop"}'::jsonb,null,
 mat.id,1,'[{"slug":"broken_rhythm_boots","chance_percent":10,"craft_cost":8}]'::jsonb
from public.enemy_templates et
join public.item_definitions mat on mat.slug='clockmaker_seventh_gear'
where et.slug='calendar_weekly_2026_11_09_clockmaker'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 starts_at=excluded.starts_at,ends_at=excluded.ends_at,enemy_template_id=excluded.enemy_template_id,
 recommended_level=excluded.recommended_level,solo_enemy_level=excluded.solo_enemy_level,
 solo_hp=excluded.solo_hp,solo_attack=excluded.solo_attack,solo_defense=excluded.solo_defense,
 solo_initiative=excluded.solo_initiative,first_reward_gold=excluded.first_reward_gold,
 first_reward_experience=excluded.first_reward_experience,repeat_reward_gold=excluded.repeat_reward_gold,
 repeat_reward_experience=excluded.repeat_reward_experience,special_every_n=excluded.special_every_n,
 special_damage_multiplier=excluded.special_damage_multiplier,phase2_hp_percent=excluded.phase2_hp_percent,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,mechanics=excluded.mechanics,
 reward_material_item_id=excluded.reward_material_item_id,reward_material_quantity=excluded.reward_material_quantity,
 featured_loot=excluded.featured_loot,updated_at=now();

insert into public.crafting_recipes(slug,name,description,enabled,required_level,gold_cost,output_item_definition_id,output_quantity,affix_bonus,sort_order)
select 'boss_broken_rhythm_boots','Создать: '||out.name,
 'Гарантированное создание уникальной добычи босса из 8 материалов его ротации.',
 true,out.required_level,450,out.id,1,0,3000+out.required_level
from public.item_definitions out where out.slug='broken_rhythm_boots'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 required_level=excluded.required_level,gold_cost=excluded.gold_cost,output_item_definition_id=excluded.output_item_definition_id,
 output_quantity=1,affix_bonus=0,sort_order=excluded.sort_order,updated_at=now();

insert into public.crafting_recipe_ingredients(recipe_id,item_definition_id,quantity)
select r.id,m.id,8
from public.crafting_recipes r join public.item_definitions m on m.slug='clockmaker_seventh_gear'
where r.slug='boss_broken_rhythm_boots'
on conflict(recipe_id,item_definition_id) do update set quantity=excluded.quantity;

insert into public.enemy_templates(
 slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,
 attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,
 special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,
 special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,
 phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,phase2_special_every_n,
 abilities,is_strong_enemy,is_rare_variant
)
values(
 'calendar_weekly_2026_11_16_drowned_queen','Утонувшая Королева','Королева тянет бой под воду и заставляет группу спасать самых слабых участников прежде, чем они исчезнут под волной.',true,null,0,10,true,1,
 'water','{"water":45,"lightning":-30,"ice":15}'::jsonb,1,1,1,1,
 'Королевский прилив',1.85,4,'water','chill',70,2,15,
 'Утонувшая Королева готовит «Королевский прилив».','Утонувшая Королева применяет «Королевский прилив».',
 40,'Двор под водой',20,20,3,
 '[{"id":"weekly_2026_11_16_drowned_queen_special","kind":"attack","name":"Королевский прилив","phase":0,"value":0,"enabled":true,"cooldown":3,"max_uses":0,"priority":75,"attack_text":"Утонувшая Королева применяет «Королевский прилив».","damage_type":"water","effect_type":"chill","min_debuffs":0,"effect_turns":2,"effect_chance":70,"effect_potency":15,"telegraph_text":"Утонувшая Королева готовит «Королевский прилив».","damage_multiplier":1.85,"max_enemy_hp_percent":100,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0},{"id":"weekly_2026_11_16_drowned_queen_phase","kind":"enrage","name":"Двор под водой","phase":2,"value":20,"enabled":true,"cooldown":9,"max_uses":1,"priority":90,"attack_text":"Утонувшая Королева: Двор под водой.","damage_type":null,"effect_type":null,"min_debuffs":0,"effect_turns":0,"effect_chance":0,"effect_potency":0,"telegraph_text":"Фаза меняется: Двор под водой.","damage_multiplier":0,"max_enemy_hp_percent":40,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0}]'::jsonb,true,false
)
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,
 special_name=excluded.special_name,special_damage_multiplier=excluded.special_damage_multiplier,
 special_every_n=excluded.special_every_n,special_damage_type=excluded.special_damage_type,
 special_effect_type=excluded.special_effect_type,special_effect_chance=excluded.special_effect_chance,
 special_effect_turns=excluded.special_effect_turns,special_effect_potency=excluded.special_effect_potency,
 special_telegraph_text=excluded.special_telegraph_text,special_attack_text=excluded.special_attack_text,
 phase2_hp_percent=excluded.phase2_hp_percent,phase2_name=excluded.phase2_name,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,
 phase2_defense_bonus_percent=excluded.phase2_defense_bonus_percent,
 phase2_special_every_n=excluded.phase2_special_every_n,abilities=excluded.abilities,is_strong_enemy=true,updated_at=now();

insert into public.event_boss_events(
 slug,boss_kind,name,description,enabled,starts_at,ends_at,enemy_template_id,
 recommended_level,solo_enemy_level,solo_hp,solo_attack,solo_defense,solo_initiative,
 party_hp_per_extra,party_attack_per_extra,party_defense_per_extra,
 special_reward_item_id,first_reward_gold,first_reward_experience,repeat_reward_gold,repeat_reward_experience,
 special_every_n,special_damage_multiplier,phase2_hp_percent,phase2_attack_bonus_percent,
 solo_only,max_victories_per_character,mechanics,global_clear_target,
 reward_material_item_id,reward_material_quantity,featured_loot
)
select
 'weekly_2026_11_16_drowned_queen','weekly','Утонувшая Королева',
 'Королева тянет бой под воду и заставляет группу спасать самых слабых участников прежде, чем они исчезнут под волной. Каждая победа даёт материал босса. Уникальная вещь может выпасть сразу или быть гарантированно создана из накопленных материалов.',
 true,'2026-11-16T15:00:00Z'::timestamptz,'2026-11-23T15:00:00Z'::timestamptz,et.id,
 12,14,980,65,35,22,
 0.7,0.10,0.06,
 null,180,180,35,30,
 4,1.85,40,20,false,null,
 '{"scheduled":true,"loot_model":"material_plus_drop"}'::jsonb,null,
 mat.id,1,'[{"slug":"drowned_queen_tear","chance_percent":10,"craft_cost":8}]'::jsonb
from public.enemy_templates et
join public.item_definitions mat on mat.slug='drowned_queen_pearl'
where et.slug='calendar_weekly_2026_11_16_drowned_queen'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 starts_at=excluded.starts_at,ends_at=excluded.ends_at,enemy_template_id=excluded.enemy_template_id,
 recommended_level=excluded.recommended_level,solo_enemy_level=excluded.solo_enemy_level,
 solo_hp=excluded.solo_hp,solo_attack=excluded.solo_attack,solo_defense=excluded.solo_defense,
 solo_initiative=excluded.solo_initiative,first_reward_gold=excluded.first_reward_gold,
 first_reward_experience=excluded.first_reward_experience,repeat_reward_gold=excluded.repeat_reward_gold,
 repeat_reward_experience=excluded.repeat_reward_experience,special_every_n=excluded.special_every_n,
 special_damage_multiplier=excluded.special_damage_multiplier,phase2_hp_percent=excluded.phase2_hp_percent,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,mechanics=excluded.mechanics,
 reward_material_item_id=excluded.reward_material_item_id,reward_material_quantity=excluded.reward_material_quantity,
 featured_loot=excluded.featured_loot,updated_at=now();

insert into public.crafting_recipes(slug,name,description,enabled,required_level,gold_cost,output_item_definition_id,output_quantity,affix_bonus,sort_order)
select 'boss_drowned_queen_tear','Создать: '||out.name,
 'Гарантированное создание уникальной добычи босса из 8 материалов его ротации.',
 true,out.required_level,450,out.id,1,0,3000+out.required_level
from public.item_definitions out where out.slug='drowned_queen_tear'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 required_level=excluded.required_level,gold_cost=excluded.gold_cost,output_item_definition_id=excluded.output_item_definition_id,
 output_quantity=1,affix_bonus=0,sort_order=excluded.sort_order,updated_at=now();

insert into public.crafting_recipe_ingredients(recipe_id,item_definition_id,quantity)
select r.id,m.id,8
from public.crafting_recipes r join public.item_definitions m on m.slug='drowned_queen_pearl'
where r.slug='boss_drowned_queen_tear'
on conflict(recipe_id,item_definition_id) do update set quantity=excluded.quantity;

insert into public.enemy_templates(
 slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,
 attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,
 special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,
 special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,
 phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,phase2_special_every_n,
 abilities,is_strong_enemy,is_rare_variant
)
values(
 'calendar_weekly_2026_11_23_black_bell_prince','Князь Чёрных Колоколов','Каждый удар его колоколов отдаётся в броне. Правильная защита превращает звон в возможность расколоть его панцирь.',true,null,0,10,true,1,
 'blunt','{"blunt":35,"lightning":-20,"piercing":15}'::jsonb,1,1,1,1,
 'Чёрный звон',1.9,3,'blunt','vulnerable',70,2,15,
 'Князь Чёрных Колоколов готовит «Чёрный звон».','Князь Чёрных Колоколов применяет «Чёрный звон».',
 35,'Треснувший колокол',30,0,2,
 '[{"id":"weekly_2026_11_23_black_bell_prince_special","kind":"attack","name":"Чёрный звон","phase":0,"value":0,"enabled":true,"cooldown":2,"max_uses":0,"priority":75,"attack_text":"Князь Чёрных Колоколов применяет «Чёрный звон».","damage_type":"blunt","effect_type":"vulnerable","min_debuffs":0,"effect_turns":2,"effect_chance":70,"effect_potency":15,"telegraph_text":"Князь Чёрных Колоколов готовит «Чёрный звон».","damage_multiplier":1.9,"max_enemy_hp_percent":100,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0},{"id":"weekly_2026_11_23_black_bell_prince_phase","kind":"enrage","name":"Треснувший колокол","phase":2,"value":30,"enabled":true,"cooldown":9,"max_uses":1,"priority":90,"attack_text":"Князь Чёрных Колоколов: Треснувший колокол.","damage_type":null,"effect_type":null,"min_debuffs":0,"effect_turns":0,"effect_chance":0,"effect_potency":0,"telegraph_text":"Фаза меняется: Треснувший колокол.","damage_multiplier":0,"max_enemy_hp_percent":35,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0}]'::jsonb,true,false
)
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,
 special_name=excluded.special_name,special_damage_multiplier=excluded.special_damage_multiplier,
 special_every_n=excluded.special_every_n,special_damage_type=excluded.special_damage_type,
 special_effect_type=excluded.special_effect_type,special_effect_chance=excluded.special_effect_chance,
 special_effect_turns=excluded.special_effect_turns,special_effect_potency=excluded.special_effect_potency,
 special_telegraph_text=excluded.special_telegraph_text,special_attack_text=excluded.special_attack_text,
 phase2_hp_percent=excluded.phase2_hp_percent,phase2_name=excluded.phase2_name,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,
 phase2_defense_bonus_percent=excluded.phase2_defense_bonus_percent,
 phase2_special_every_n=excluded.phase2_special_every_n,abilities=excluded.abilities,is_strong_enemy=true,updated_at=now();

insert into public.event_boss_events(
 slug,boss_kind,name,description,enabled,starts_at,ends_at,enemy_template_id,
 recommended_level,solo_enemy_level,solo_hp,solo_attack,solo_defense,solo_initiative,
 party_hp_per_extra,party_attack_per_extra,party_defense_per_extra,
 special_reward_item_id,first_reward_gold,first_reward_experience,repeat_reward_gold,repeat_reward_experience,
 special_every_n,special_damage_multiplier,phase2_hp_percent,phase2_attack_bonus_percent,
 solo_only,max_victories_per_character,mechanics,global_clear_target,
 reward_material_item_id,reward_material_quantity,featured_loot
)
select
 'weekly_2026_11_23_black_bell_prince','weekly','Князь Чёрных Колоколов',
 'Каждый удар его колоколов отдаётся в броне. Правильная защита превращает звон в возможность расколоть его панцирь. Каждая победа даёт материал босса. Уникальная вещь может выпасть сразу или быть гарантированно создана из накопленных материалов.',
 true,'2026-11-23T15:00:00Z'::timestamptz,'2026-11-30T15:00:00Z'::timestamptz,et.id,
 13,15,1080,70,40,20,
 0.7,0.10,0.06,
 null,180,180,35,30,
 3,1.9,35,30,false,null,
 '{"scheduled":true,"loot_model":"material_plus_drop"}'::jsonb,null,
 mat.id,1,'[{"slug":"black_bell_hammer","chance_percent":10,"craft_cost":8}]'::jsonb
from public.enemy_templates et
join public.item_definitions mat on mat.slug='black_bell_shard'
where et.slug='calendar_weekly_2026_11_23_black_bell_prince'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 starts_at=excluded.starts_at,ends_at=excluded.ends_at,enemy_template_id=excluded.enemy_template_id,
 recommended_level=excluded.recommended_level,solo_enemy_level=excluded.solo_enemy_level,
 solo_hp=excluded.solo_hp,solo_attack=excluded.solo_attack,solo_defense=excluded.solo_defense,
 solo_initiative=excluded.solo_initiative,first_reward_gold=excluded.first_reward_gold,
 first_reward_experience=excluded.first_reward_experience,repeat_reward_gold=excluded.repeat_reward_gold,
 repeat_reward_experience=excluded.repeat_reward_experience,special_every_n=excluded.special_every_n,
 special_damage_multiplier=excluded.special_damage_multiplier,phase2_hp_percent=excluded.phase2_hp_percent,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,mechanics=excluded.mechanics,
 reward_material_item_id=excluded.reward_material_item_id,reward_material_quantity=excluded.reward_material_quantity,
 featured_loot=excluded.featured_loot,updated_at=now();

insert into public.crafting_recipes(slug,name,description,enabled,required_level,gold_cost,output_item_definition_id,output_quantity,affix_bonus,sort_order)
select 'boss_black_bell_hammer','Создать: '||out.name,
 'Гарантированное создание уникальной добычи босса из 8 материалов его ротации.',
 true,out.required_level,450,out.id,1,0,3000+out.required_level
from public.item_definitions out where out.slug='black_bell_hammer'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 required_level=excluded.required_level,gold_cost=excluded.gold_cost,output_item_definition_id=excluded.output_item_definition_id,
 output_quantity=1,affix_bonus=0,sort_order=excluded.sort_order,updated_at=now();

insert into public.crafting_recipe_ingredients(recipe_id,item_definition_id,quantity)
select r.id,m.id,8
from public.crafting_recipes r join public.item_definitions m on m.slug='black_bell_shard'
where r.slug='boss_black_bell_hammer'
on conflict(recipe_id,item_definition_id) do update set quantity=excluded.quantity;

insert into public.enemy_templates(
 slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,
 attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,
 special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,
 special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,
 phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,phase2_special_every_n,
 abilities,is_strong_enemy,is_rare_variant
)
values(
 'calendar_weekly_2026_11_30_white_witch','Белая Ведьма Севера','Она меняет ритм заклинаний и карает магов, которые повторяют один и тот же приём.',true,null,0,10,true,1,
 'ice','{"ice":50,"fire":-35,"moon":20}'::jsonb,1,1,1,1,
 'Белая тишина',1.75,4,'ice','chill',70,2,15,
 'Белая Ведьма Севера готовит «Белая тишина».','Белая Ведьма Севера применяет «Белая тишина».',
 45,'Полярная ночь',25,15,3,
 '[{"id":"weekly_2026_11_30_white_witch_special","kind":"attack","name":"Белая тишина","phase":0,"value":0,"enabled":true,"cooldown":3,"max_uses":0,"priority":75,"attack_text":"Белая Ведьма Севера применяет «Белая тишина».","damage_type":"ice","effect_type":"chill","min_debuffs":0,"effect_turns":2,"effect_chance":70,"effect_potency":15,"telegraph_text":"Белая Ведьма Севера готовит «Белая тишина».","damage_multiplier":1.75,"max_enemy_hp_percent":100,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0},{"id":"weekly_2026_11_30_white_witch_phase","kind":"enrage","name":"Полярная ночь","phase":2,"value":25,"enabled":true,"cooldown":9,"max_uses":1,"priority":90,"attack_text":"Белая Ведьма Севера: Полярная ночь.","damage_type":null,"effect_type":null,"min_debuffs":0,"effect_turns":0,"effect_chance":0,"effect_potency":0,"telegraph_text":"Фаза меняется: Полярная ночь.","damage_multiplier":0,"max_enemy_hp_percent":45,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0}]'::jsonb,true,false
)
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,
 special_name=excluded.special_name,special_damage_multiplier=excluded.special_damage_multiplier,
 special_every_n=excluded.special_every_n,special_damage_type=excluded.special_damage_type,
 special_effect_type=excluded.special_effect_type,special_effect_chance=excluded.special_effect_chance,
 special_effect_turns=excluded.special_effect_turns,special_effect_potency=excluded.special_effect_potency,
 special_telegraph_text=excluded.special_telegraph_text,special_attack_text=excluded.special_attack_text,
 phase2_hp_percent=excluded.phase2_hp_percent,phase2_name=excluded.phase2_name,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,
 phase2_defense_bonus_percent=excluded.phase2_defense_bonus_percent,
 phase2_special_every_n=excluded.phase2_special_every_n,abilities=excluded.abilities,is_strong_enemy=true,updated_at=now();

insert into public.event_boss_events(
 slug,boss_kind,name,description,enabled,starts_at,ends_at,enemy_template_id,
 recommended_level,solo_enemy_level,solo_hp,solo_attack,solo_defense,solo_initiative,
 party_hp_per_extra,party_attack_per_extra,party_defense_per_extra,
 special_reward_item_id,first_reward_gold,first_reward_experience,repeat_reward_gold,repeat_reward_experience,
 special_every_n,special_damage_multiplier,phase2_hp_percent,phase2_attack_bonus_percent,
 solo_only,max_victories_per_character,mechanics,global_clear_target,
 reward_material_item_id,reward_material_quantity,featured_loot
)
select
 'weekly_2026_11_30_white_witch','weekly','Белая Ведьма Севера',
 'Она меняет ритм заклинаний и карает магов, которые повторяют один и тот же приём. Каждая победа даёт материал босса. Уникальная вещь может выпасть сразу или быть гарантированно создана из накопленных материалов.',
 true,'2026-11-30T15:00:00Z'::timestamptz,'2026-12-07T15:00:00Z'::timestamptz,et.id,
 14,16,1140,74,39,29,
 0.7,0.10,0.06,
 null,180,180,35,30,
 4,1.75,45,25,false,null,
 '{"scheduled":true,"loot_model":"material_plus_drop"}'::jsonb,null,
 mat.id,1,'[{"slug":"white_silence_mantle","chance_percent":10,"craft_cost":8}]'::jsonb
from public.enemy_templates et
join public.item_definitions mat on mat.slug='white_witch_thread'
where et.slug='calendar_weekly_2026_11_30_white_witch'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 starts_at=excluded.starts_at,ends_at=excluded.ends_at,enemy_template_id=excluded.enemy_template_id,
 recommended_level=excluded.recommended_level,solo_enemy_level=excluded.solo_enemy_level,
 solo_hp=excluded.solo_hp,solo_attack=excluded.solo_attack,solo_defense=excluded.solo_defense,
 solo_initiative=excluded.solo_initiative,first_reward_gold=excluded.first_reward_gold,
 first_reward_experience=excluded.first_reward_experience,repeat_reward_gold=excluded.repeat_reward_gold,
 repeat_reward_experience=excluded.repeat_reward_experience,special_every_n=excluded.special_every_n,
 special_damage_multiplier=excluded.special_damage_multiplier,phase2_hp_percent=excluded.phase2_hp_percent,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,mechanics=excluded.mechanics,
 reward_material_item_id=excluded.reward_material_item_id,reward_material_quantity=excluded.reward_material_quantity,
 featured_loot=excluded.featured_loot,updated_at=now();

insert into public.crafting_recipes(slug,name,description,enabled,required_level,gold_cost,output_item_definition_id,output_quantity,affix_bonus,sort_order)
select 'boss_white_silence_mantle','Создать: '||out.name,
 'Гарантированное создание уникальной добычи босса из 8 материалов его ротации.',
 true,out.required_level,450,out.id,1,0,3000+out.required_level
from public.item_definitions out where out.slug='white_silence_mantle'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 required_level=excluded.required_level,gold_cost=excluded.gold_cost,output_item_definition_id=excluded.output_item_definition_id,
 output_quantity=1,affix_bonus=0,sort_order=excluded.sort_order,updated_at=now();

insert into public.crafting_recipe_ingredients(recipe_id,item_definition_id,quantity)
select r.id,m.id,8
from public.crafting_recipes r join public.item_definitions m on m.slug='white_witch_thread'
where r.slug='boss_white_silence_mantle'
on conflict(recipe_id,item_definition_id) do update set quantity=excluded.quantity;

insert into public.enemy_templates(
 slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,
 attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,
 special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,
 special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,
 phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,phase2_special_every_n,
 abilities,is_strong_enemy,is_rare_variant
)
values(
 'calendar_weekly_2026_12_07_empty_throne_guardian','Страж Пустого Трона','Страж не охраняет короля — он охраняет само место. Его удары постоянно ищут самого уязвимого в группе.',true,null,0,10,true,1,
 'slashing','{"slashing":35,"piercing":25,"arcane":-20}'::jsonb,1,1,1,1,
 'Приговор трону',1.95,3,'slashing','stun',70,2,15,
 'Страж Пустого Трона готовит «Приговор трону».','Страж Пустого Трона применяет «Приговор трону».',
 40,'Последний вассал',30,20,2,
 '[{"id":"weekly_2026_12_07_empty_throne_guardian_special","kind":"attack","name":"Приговор трону","phase":0,"value":0,"enabled":true,"cooldown":2,"max_uses":0,"priority":75,"attack_text":"Страж Пустого Трона применяет «Приговор трону».","damage_type":"slashing","effect_type":"stun","min_debuffs":0,"effect_turns":2,"effect_chance":70,"effect_potency":15,"telegraph_text":"Страж Пустого Трона готовит «Приговор трону».","damage_multiplier":1.95,"max_enemy_hp_percent":100,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0},{"id":"weekly_2026_12_07_empty_throne_guardian_phase","kind":"enrage","name":"Последний вассал","phase":2,"value":30,"enabled":true,"cooldown":9,"max_uses":1,"priority":90,"attack_text":"Страж Пустого Трона: Последний вассал.","damage_type":null,"effect_type":null,"min_debuffs":0,"effect_turns":0,"effect_chance":0,"effect_potency":0,"telegraph_text":"Фаза меняется: Последний вассал.","damage_multiplier":0,"max_enemy_hp_percent":40,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0}]'::jsonb,true,false
)
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,
 special_name=excluded.special_name,special_damage_multiplier=excluded.special_damage_multiplier,
 special_every_n=excluded.special_every_n,special_damage_type=excluded.special_damage_type,
 special_effect_type=excluded.special_effect_type,special_effect_chance=excluded.special_effect_chance,
 special_effect_turns=excluded.special_effect_turns,special_effect_potency=excluded.special_effect_potency,
 special_telegraph_text=excluded.special_telegraph_text,special_attack_text=excluded.special_attack_text,
 phase2_hp_percent=excluded.phase2_hp_percent,phase2_name=excluded.phase2_name,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,
 phase2_defense_bonus_percent=excluded.phase2_defense_bonus_percent,
 phase2_special_every_n=excluded.phase2_special_every_n,abilities=excluded.abilities,is_strong_enemy=true,updated_at=now();

insert into public.event_boss_events(
 slug,boss_kind,name,description,enabled,starts_at,ends_at,enemy_template_id,
 recommended_level,solo_enemy_level,solo_hp,solo_attack,solo_defense,solo_initiative,
 party_hp_per_extra,party_attack_per_extra,party_defense_per_extra,
 special_reward_item_id,first_reward_gold,first_reward_experience,repeat_reward_gold,repeat_reward_experience,
 special_every_n,special_damage_multiplier,phase2_hp_percent,phase2_attack_bonus_percent,
 solo_only,max_victories_per_character,mechanics,global_clear_target,
 reward_material_item_id,reward_material_quantity,featured_loot
)
select
 'weekly_2026_12_07_empty_throne_guardian','weekly','Страж Пустого Трона',
 'Страж не охраняет короля — он охраняет само место. Его удары постоянно ищут самого уязвимого в группе. Каждая победа даёт материал босса. Уникальная вещь может выпасть сразу или быть гарантированно создана из накопленных материалов.',
 true,'2026-12-07T15:00:00Z'::timestamptz,'2026-12-14T15:00:00Z'::timestamptz,et.id,
 15,17,1260,79,46,23,
 0.7,0.10,0.06,
 null,180,180,35,30,
 3,1.95,40,30,false,null,
 '{"scheduled":true,"loot_model":"material_plus_drop"}'::jsonb,null,
 mat.id,1,'[{"slug":"empty_throne_shield","chance_percent":10,"craft_cost":8}]'::jsonb
from public.enemy_templates et
join public.item_definitions mat on mat.slug='empty_throne_seal'
where et.slug='calendar_weekly_2026_12_07_empty_throne_guardian'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 starts_at=excluded.starts_at,ends_at=excluded.ends_at,enemy_template_id=excluded.enemy_template_id,
 recommended_level=excluded.recommended_level,solo_enemy_level=excluded.solo_enemy_level,
 solo_hp=excluded.solo_hp,solo_attack=excluded.solo_attack,solo_defense=excluded.solo_defense,
 solo_initiative=excluded.solo_initiative,first_reward_gold=excluded.first_reward_gold,
 first_reward_experience=excluded.first_reward_experience,repeat_reward_gold=excluded.repeat_reward_gold,
 repeat_reward_experience=excluded.repeat_reward_experience,special_every_n=excluded.special_every_n,
 special_damage_multiplier=excluded.special_damage_multiplier,phase2_hp_percent=excluded.phase2_hp_percent,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,mechanics=excluded.mechanics,
 reward_material_item_id=excluded.reward_material_item_id,reward_material_quantity=excluded.reward_material_quantity,
 featured_loot=excluded.featured_loot,updated_at=now();

insert into public.crafting_recipes(slug,name,description,enabled,required_level,gold_cost,output_item_definition_id,output_quantity,affix_bonus,sort_order)
select 'boss_empty_throne_shield','Создать: '||out.name,
 'Гарантированное создание уникальной добычи босса из 8 материалов его ротации.',
 true,out.required_level,450,out.id,1,0,3000+out.required_level
from public.item_definitions out where out.slug='empty_throne_shield'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 required_level=excluded.required_level,gold_cost=excluded.gold_cost,output_item_definition_id=excluded.output_item_definition_id,
 output_quantity=1,affix_bonus=0,sort_order=excluded.sort_order,updated_at=now();

insert into public.crafting_recipe_ingredients(recipe_id,item_definition_id,quantity)
select r.id,m.id,8
from public.crafting_recipes r join public.item_definitions m on m.slug='empty_throne_seal'
where r.slug='boss_empty_throne_shield'
on conflict(recipe_id,item_definition_id) do update set quantity=excluded.quantity;

insert into public.enemy_templates(
 slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,
 attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,
 special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,
 special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,
 phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,phase2_special_every_n,
 abilities,is_strong_enemy,is_rare_variant
)
values(
 'calendar_weekly_2026_12_14_name_hunter','Охотник за Именами','Он запоминает приёмы противника и отвечает тем же языком урона, превращая каждую особую атаку в дуэль памяти.',true,null,0,10,true,1,
 'arcane','{"arcane":35,"star":15,"blunt":-15}'::jsonb,1,1,1,1,
 'Украденное имя',1.9,3,'arcane','vulnerable',70,2,15,
 'Охотник за Именами готовит «Украденное имя».','Охотник за Именами применяет «Украденное имя».',
 35,'Имя владельца',35,10,2,
 '[{"id":"weekly_2026_12_14_name_hunter_special","kind":"attack","name":"Украденное имя","phase":0,"value":0,"enabled":true,"cooldown":2,"max_uses":0,"priority":75,"attack_text":"Охотник за Именами применяет «Украденное имя».","damage_type":"arcane","effect_type":"vulnerable","min_debuffs":0,"effect_turns":2,"effect_chance":70,"effect_potency":15,"telegraph_text":"Охотник за Именами готовит «Украденное имя».","damage_multiplier":1.9,"max_enemy_hp_percent":100,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0},{"id":"weekly_2026_12_14_name_hunter_phase","kind":"enrage","name":"Имя владельца","phase":2,"value":35,"enabled":true,"cooldown":9,"max_uses":1,"priority":90,"attack_text":"Охотник за Именами: Имя владельца.","damage_type":null,"effect_type":null,"min_debuffs":0,"effect_turns":0,"effect_chance":0,"effect_potency":0,"telegraph_text":"Фаза меняется: Имя владельца.","damage_multiplier":0,"max_enemy_hp_percent":35,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0}]'::jsonb,true,false
)
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,
 special_name=excluded.special_name,special_damage_multiplier=excluded.special_damage_multiplier,
 special_every_n=excluded.special_every_n,special_damage_type=excluded.special_damage_type,
 special_effect_type=excluded.special_effect_type,special_effect_chance=excluded.special_effect_chance,
 special_effect_turns=excluded.special_effect_turns,special_effect_potency=excluded.special_effect_potency,
 special_telegraph_text=excluded.special_telegraph_text,special_attack_text=excluded.special_attack_text,
 phase2_hp_percent=excluded.phase2_hp_percent,phase2_name=excluded.phase2_name,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,
 phase2_defense_bonus_percent=excluded.phase2_defense_bonus_percent,
 phase2_special_every_n=excluded.phase2_special_every_n,abilities=excluded.abilities,is_strong_enemy=true,updated_at=now();

insert into public.event_boss_events(
 slug,boss_kind,name,description,enabled,starts_at,ends_at,enemy_template_id,
 recommended_level,solo_enemy_level,solo_hp,solo_attack,solo_defense,solo_initiative,
 party_hp_per_extra,party_attack_per_extra,party_defense_per_extra,
 special_reward_item_id,first_reward_gold,first_reward_experience,repeat_reward_gold,repeat_reward_experience,
 special_every_n,special_damage_multiplier,phase2_hp_percent,phase2_attack_bonus_percent,
 solo_only,max_victories_per_character,mechanics,global_clear_target,
 reward_material_item_id,reward_material_quantity,featured_loot
)
select
 'weekly_2026_12_14_name_hunter','weekly','Охотник за Именами',
 'Он запоминает приёмы противника и отвечает тем же языком урона, превращая каждую особую атаку в дуэль памяти. Каждая победа даёт материал босса. Уникальная вещь может выпасть сразу или быть гарантированно создана из накопленных материалов.',
 true,'2026-12-14T15:00:00Z'::timestamptz,'2026-12-21T15:00:00Z'::timestamptz,et.id,
 16,18,1360,84,48,32,
 0.7,0.10,0.06,
 null,180,180,35,30,
 3,1.9,35,35,false,null,
 '{"scheduled":true,"loot_model":"material_plus_drop"}'::jsonb,null,
 mat.id,1,'[{"slug":"answering_name_blade","chance_percent":10,"craft_cost":8}]'::jsonb
from public.enemy_templates et
join public.item_definitions mat on mat.slug='name_hunter_ink'
where et.slug='calendar_weekly_2026_12_14_name_hunter'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 starts_at=excluded.starts_at,ends_at=excluded.ends_at,enemy_template_id=excluded.enemy_template_id,
 recommended_level=excluded.recommended_level,solo_enemy_level=excluded.solo_enemy_level,
 solo_hp=excluded.solo_hp,solo_attack=excluded.solo_attack,solo_defense=excluded.solo_defense,
 solo_initiative=excluded.solo_initiative,first_reward_gold=excluded.first_reward_gold,
 first_reward_experience=excluded.first_reward_experience,repeat_reward_gold=excluded.repeat_reward_gold,
 repeat_reward_experience=excluded.repeat_reward_experience,special_every_n=excluded.special_every_n,
 special_damage_multiplier=excluded.special_damage_multiplier,phase2_hp_percent=excluded.phase2_hp_percent,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,mechanics=excluded.mechanics,
 reward_material_item_id=excluded.reward_material_item_id,reward_material_quantity=excluded.reward_material_quantity,
 featured_loot=excluded.featured_loot,updated_at=now();

insert into public.crafting_recipes(slug,name,description,enabled,required_level,gold_cost,output_item_definition_id,output_quantity,affix_bonus,sort_order)
select 'boss_answering_name_blade','Создать: '||out.name,
 'Гарантированное создание уникальной добычи босса из 8 материалов его ротации.',
 true,out.required_level,450,out.id,1,0,3000+out.required_level
from public.item_definitions out where out.slug='answering_name_blade'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 required_level=excluded.required_level,gold_cost=excluded.gold_cost,output_item_definition_id=excluded.output_item_definition_id,
 output_quantity=1,affix_bonus=0,sort_order=excluded.sort_order,updated_at=now();

insert into public.crafting_recipe_ingredients(recipe_id,item_definition_id,quantity)
select r.id,m.id,8
from public.crafting_recipes r join public.item_definitions m on m.slug='name_hunter_ink'
where r.slug='boss_answering_name_blade'
on conflict(recipe_id,item_definition_id) do update set quantity=excluded.quantity;

insert into public.enemy_templates(
 slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,
 attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,
 special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,
 special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,
 phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,phase2_special_every_n,
 abilities,is_strong_enemy,is_rare_variant
)
values(
 'calendar_world_2026_10_22_salt_leviathan','Левиафан Соляной Бездны','Мировая угроза: древний Левиафан поднялся из северных вод. Бой рассчитан на долгую охоту и даёт материалы для двух разных легендарных предметов.',true,null,0,10,true,1,
 'water','{"water":55,"ice":25,"lightning":-35,"piercing":15}'::jsonb,1,1,1,1,
 'Соляной обвал',2.1,3,'water','vulnerable',70,2,15,
 'Левиафан Соляной Бездны готовит «Соляной обвал».','Левиафан Соляной Бездны применяет «Соляной обвал».',
 45,'Бездна раскрывается',35,20,2,
 '[{"id":"world_2026_10_22_salt_leviathan_special","kind":"attack","name":"Соляной обвал","phase":0,"value":0,"enabled":true,"cooldown":2,"max_uses":0,"priority":75,"attack_text":"Левиафан Соляной Бездны применяет «Соляной обвал».","damage_type":"water","effect_type":"vulnerable","min_debuffs":0,"effect_turns":2,"effect_chance":70,"effect_potency":15,"telegraph_text":"Левиафан Соляной Бездны готовит «Соляной обвал».","damage_multiplier":2.1,"max_enemy_hp_percent":100,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0},{"id":"world_2026_10_22_salt_leviathan_phase","kind":"enrage","name":"Бездна раскрывается","phase":2,"value":35,"enabled":true,"cooldown":9,"max_uses":1,"priority":90,"attack_text":"Левиафан Соляной Бездны: Бездна раскрывается.","damage_type":null,"effect_type":null,"min_debuffs":0,"effect_turns":0,"effect_chance":0,"effect_potency":0,"telegraph_text":"Фаза меняется: Бездна раскрывается.","damage_multiplier":0,"max_enemy_hp_percent":45,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0}]'::jsonb,true,false
)
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,
 special_name=excluded.special_name,special_damage_multiplier=excluded.special_damage_multiplier,
 special_every_n=excluded.special_every_n,special_damage_type=excluded.special_damage_type,
 special_effect_type=excluded.special_effect_type,special_effect_chance=excluded.special_effect_chance,
 special_effect_turns=excluded.special_effect_turns,special_effect_potency=excluded.special_effect_potency,
 special_telegraph_text=excluded.special_telegraph_text,special_attack_text=excluded.special_attack_text,
 phase2_hp_percent=excluded.phase2_hp_percent,phase2_name=excluded.phase2_name,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,
 phase2_defense_bonus_percent=excluded.phase2_defense_bonus_percent,
 phase2_special_every_n=excluded.phase2_special_every_n,abilities=excluded.abilities,is_strong_enemy=true,updated_at=now();

insert into public.event_boss_events(
 slug,boss_kind,name,description,enabled,starts_at,ends_at,enemy_template_id,
 recommended_level,solo_enemy_level,solo_hp,solo_attack,solo_defense,solo_initiative,
 party_hp_per_extra,party_attack_per_extra,party_defense_per_extra,
 special_reward_item_id,first_reward_gold,first_reward_experience,repeat_reward_gold,repeat_reward_experience,
 special_every_n,special_damage_multiplier,phase2_hp_percent,phase2_attack_bonus_percent,
 solo_only,max_victories_per_character,mechanics,global_clear_target,
 reward_material_item_id,reward_material_quantity,featured_loot
)
select
 'world_2026_10_22_salt_leviathan','monthly','Левиафан Соляной Бездны',
 'Мировая угроза: древний Левиафан поднялся из северных вод. Бой рассчитан на долгую охоту и даёт материалы для двух разных легендарных предметов. Каждая победа даёт материал босса. Уникальная вещь может выпасть сразу или быть гарантированно создана из накопленных материалов.',
 true,'2026-10-22T15:00:00Z'::timestamptz,'2026-11-01T15:00:00Z'::timestamptz,et.id,
 10,12,1900,72,48,18,
 0.85,0.10,0.06,
 null,400,420,80,80,
 3,2.1,45,35,false,null,
 '{"scheduled":true,"loot_model":"material_plus_drop"}'::jsonb,null,
 mat.id,1,'[{"slug":"leviathan_keel","chance_percent":5,"craft_cost":10},{"slug":"deep_tide_hide","chance_percent":5,"craft_cost":10}]'::jsonb
from public.enemy_templates et
join public.item_definitions mat on mat.slug='leviathan_scale'
where et.slug='calendar_world_2026_10_22_salt_leviathan'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 starts_at=excluded.starts_at,ends_at=excluded.ends_at,enemy_template_id=excluded.enemy_template_id,
 recommended_level=excluded.recommended_level,solo_enemy_level=excluded.solo_enemy_level,
 solo_hp=excluded.solo_hp,solo_attack=excluded.solo_attack,solo_defense=excluded.solo_defense,
 solo_initiative=excluded.solo_initiative,first_reward_gold=excluded.first_reward_gold,
 first_reward_experience=excluded.first_reward_experience,repeat_reward_gold=excluded.repeat_reward_gold,
 repeat_reward_experience=excluded.repeat_reward_experience,special_every_n=excluded.special_every_n,
 special_damage_multiplier=excluded.special_damage_multiplier,phase2_hp_percent=excluded.phase2_hp_percent,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,mechanics=excluded.mechanics,
 reward_material_item_id=excluded.reward_material_item_id,reward_material_quantity=excluded.reward_material_quantity,
 featured_loot=excluded.featured_loot,updated_at=now();

insert into public.crafting_recipes(slug,name,description,enabled,required_level,gold_cost,output_item_definition_id,output_quantity,affix_bonus,sort_order)
select 'boss_leviathan_keel','Создать: '||out.name,
 'Гарантированное создание уникальной добычи босса из 10 материалов его ротации.',
 true,out.required_level,900,out.id,1,0,3000+out.required_level
from public.item_definitions out where out.slug='leviathan_keel'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 required_level=excluded.required_level,gold_cost=excluded.gold_cost,output_item_definition_id=excluded.output_item_definition_id,
 output_quantity=1,affix_bonus=0,sort_order=excluded.sort_order,updated_at=now();

insert into public.crafting_recipe_ingredients(recipe_id,item_definition_id,quantity)
select r.id,m.id,10
from public.crafting_recipes r join public.item_definitions m on m.slug='leviathan_scale'
where r.slug='boss_leviathan_keel'
on conflict(recipe_id,item_definition_id) do update set quantity=excluded.quantity;

insert into public.crafting_recipes(slug,name,description,enabled,required_level,gold_cost,output_item_definition_id,output_quantity,affix_bonus,sort_order)
select 'boss_deep_tide_hide','Создать: '||out.name,
 'Гарантированное создание уникальной добычи босса из 10 материалов его ротации.',
 true,out.required_level,900,out.id,1,0,3000+out.required_level
from public.item_definitions out where out.slug='deep_tide_hide'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 required_level=excluded.required_level,gold_cost=excluded.gold_cost,output_item_definition_id=excluded.output_item_definition_id,
 output_quantity=1,affix_bonus=0,sort_order=excluded.sort_order,updated_at=now();

insert into public.crafting_recipe_ingredients(recipe_id,item_definition_id,quantity)
select r.id,m.id,10
from public.crafting_recipes r join public.item_definitions m on m.slug='leviathan_scale'
where r.slug='boss_deep_tide_hide'
on conflict(recipe_id,item_definition_id) do update set quantity=excluded.quantity;

insert into public.enemy_templates(
 slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,
 attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,
 special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,
 special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,
 phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,phase2_special_every_n,
 abilities,is_strong_enemy,is_rare_variant
)
values(
 'calendar_world_2026_11_19_aster','Астэр, Небесный Червь','Мировая угроза: Астэр проходит над Эйларом и разрывает небо звёздными дугами. Его добыча открывает мультиэлементальный магический стиль.',true,null,0,10,true,1,
 'star','{"star":60,"arcane":30,"gravity":-30,"blunt":-10}'::jsonb,1,1,1,1,
 'Падение созвездия',2.2,3,'star','weaken',70,2,15,
 'Астэр, Небесный Червь готовит «Падение созвездия».','Астэр, Небесный Червь применяет «Падение созвездия».',
 40,'Разворот небосвода',40,20,2,
 '[{"id":"world_2026_11_19_aster_special","kind":"attack","name":"Падение созвездия","phase":0,"value":0,"enabled":true,"cooldown":2,"max_uses":0,"priority":75,"attack_text":"Астэр, Небесный Червь применяет «Падение созвездия».","damage_type":"star","effect_type":"weaken","min_debuffs":0,"effect_turns":2,"effect_chance":70,"effect_potency":15,"telegraph_text":"Астэр, Небесный Червь готовит «Падение созвездия».","damage_multiplier":2.2,"max_enemy_hp_percent":100,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0},{"id":"world_2026_11_19_aster_phase","kind":"enrage","name":"Разворот небосвода","phase":2,"value":40,"enabled":true,"cooldown":9,"max_uses":1,"priority":90,"attack_text":"Астэр, Небесный Червь: Разворот небосвода.","damage_type":null,"effect_type":null,"min_debuffs":0,"effect_turns":0,"effect_chance":0,"effect_potency":0,"telegraph_text":"Фаза меняется: Разворот небосвода.","damage_multiplier":0,"max_enemy_hp_percent":40,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0}]'::jsonb,true,false
)
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,
 special_name=excluded.special_name,special_damage_multiplier=excluded.special_damage_multiplier,
 special_every_n=excluded.special_every_n,special_damage_type=excluded.special_damage_type,
 special_effect_type=excluded.special_effect_type,special_effect_chance=excluded.special_effect_chance,
 special_effect_turns=excluded.special_effect_turns,special_effect_potency=excluded.special_effect_potency,
 special_telegraph_text=excluded.special_telegraph_text,special_attack_text=excluded.special_attack_text,
 phase2_hp_percent=excluded.phase2_hp_percent,phase2_name=excluded.phase2_name,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,
 phase2_defense_bonus_percent=excluded.phase2_defense_bonus_percent,
 phase2_special_every_n=excluded.phase2_special_every_n,abilities=excluded.abilities,is_strong_enemy=true,updated_at=now();

insert into public.event_boss_events(
 slug,boss_kind,name,description,enabled,starts_at,ends_at,enemy_template_id,
 recommended_level,solo_enemy_level,solo_hp,solo_attack,solo_defense,solo_initiative,
 party_hp_per_extra,party_attack_per_extra,party_defense_per_extra,
 special_reward_item_id,first_reward_gold,first_reward_experience,repeat_reward_gold,repeat_reward_experience,
 special_every_n,special_damage_multiplier,phase2_hp_percent,phase2_attack_bonus_percent,
 solo_only,max_victories_per_character,mechanics,global_clear_target,
 reward_material_item_id,reward_material_quantity,featured_loot
)
select
 'world_2026_11_19_aster','monthly','Астэр, Небесный Червь',
 'Мировая угроза: Астэр проходит над Эйларом и разрывает небо звёздными дугами. Его добыча открывает мультиэлементальный магический стиль. Каждая победа даёт материал босса. Уникальная вещь может выпасть сразу или быть гарантированно создана из накопленных материалов.',
 true,'2026-11-19T15:00:00Z'::timestamptz,'2026-11-29T15:00:00Z'::timestamptz,et.id,
 14,16,2700,92,58,30,
 0.85,0.10,0.06,
 null,400,420,80,80,
 3,2.2,40,40,false,null,
 '{"scheduled":true,"loot_model":"material_plus_drop"}'::jsonb,null,
 mat.id,1,'[{"slug":"aster_axis_staff","chance_percent":5,"craft_cost":10},{"slug":"zero_sphere","chance_percent":5,"craft_cost":10}]'::jsonb
from public.enemy_templates et
join public.item_definitions mat on mat.slug='aster_stardust'
where et.slug='calendar_world_2026_11_19_aster'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 starts_at=excluded.starts_at,ends_at=excluded.ends_at,enemy_template_id=excluded.enemy_template_id,
 recommended_level=excluded.recommended_level,solo_enemy_level=excluded.solo_enemy_level,
 solo_hp=excluded.solo_hp,solo_attack=excluded.solo_attack,solo_defense=excluded.solo_defense,
 solo_initiative=excluded.solo_initiative,first_reward_gold=excluded.first_reward_gold,
 first_reward_experience=excluded.first_reward_experience,repeat_reward_gold=excluded.repeat_reward_gold,
 repeat_reward_experience=excluded.repeat_reward_experience,special_every_n=excluded.special_every_n,
 special_damage_multiplier=excluded.special_damage_multiplier,phase2_hp_percent=excluded.phase2_hp_percent,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,mechanics=excluded.mechanics,
 reward_material_item_id=excluded.reward_material_item_id,reward_material_quantity=excluded.reward_material_quantity,
 featured_loot=excluded.featured_loot,updated_at=now();

insert into public.crafting_recipes(slug,name,description,enabled,required_level,gold_cost,output_item_definition_id,output_quantity,affix_bonus,sort_order)
select 'boss_aster_axis_staff','Создать: '||out.name,
 'Гарантированное создание уникальной добычи босса из 10 материалов его ротации.',
 true,out.required_level,900,out.id,1,0,3000+out.required_level
from public.item_definitions out where out.slug='aster_axis_staff'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 required_level=excluded.required_level,gold_cost=excluded.gold_cost,output_item_definition_id=excluded.output_item_definition_id,
 output_quantity=1,affix_bonus=0,sort_order=excluded.sort_order,updated_at=now();

insert into public.crafting_recipe_ingredients(recipe_id,item_definition_id,quantity)
select r.id,m.id,10
from public.crafting_recipes r join public.item_definitions m on m.slug='aster_stardust'
where r.slug='boss_aster_axis_staff'
on conflict(recipe_id,item_definition_id) do update set quantity=excluded.quantity;

insert into public.crafting_recipes(slug,name,description,enabled,required_level,gold_cost,output_item_definition_id,output_quantity,affix_bonus,sort_order)
select 'boss_zero_sphere','Создать: '||out.name,
 'Гарантированное создание уникальной добычи босса из 10 материалов его ротации.',
 true,out.required_level,900,out.id,1,0,3000+out.required_level
from public.item_definitions out where out.slug='zero_sphere'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 required_level=excluded.required_level,gold_cost=excluded.gold_cost,output_item_definition_id=excluded.output_item_definition_id,
 output_quantity=1,affix_bonus=0,sort_order=excluded.sort_order,updated_at=now();

insert into public.crafting_recipe_ingredients(recipe_id,item_definition_id,quantity)
select r.id,m.id,10
from public.crafting_recipes r join public.item_definitions m on m.slug='aster_stardust'
where r.slug='boss_zero_sphere'
on conflict(recipe_id,item_definition_id) do update set quantity=excluded.quantity;

insert into public.enemy_templates(
 slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,
 attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,
 special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,
 special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,
 phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,phase2_special_every_n,
 abilities,is_strong_enemy,is_rare_variant
)
values(
 'calendar_world_2026_12_17_gravity_dragon','Дракон Гравитационного Разлома','Мировая угроза: дракон удерживает вокруг себя искривлённое пространство. Его реликты становятся основой первого отдельного гравитационного билда.',true,null,0,10,true,1,
 'gravity','{"gravity":65,"star":25,"arcane":20,"slashing":-15}'::jsonb,1,1,1,1,
 'Схлопывание',2.35,3,'gravity','stun',70,2,15,
 'Дракон Гравитационного Разлома готовит «Схлопывание».','Дракон Гравитационного Разлома применяет «Схлопывание».',
 40,'Нулевая масса',45,25,2,
 '[{"id":"world_2026_12_17_gravity_dragon_special","kind":"attack","name":"Схлопывание","phase":0,"value":0,"enabled":true,"cooldown":2,"max_uses":0,"priority":75,"attack_text":"Дракон Гравитационного Разлома применяет «Схлопывание».","damage_type":"gravity","effect_type":"stun","min_debuffs":0,"effect_turns":2,"effect_chance":70,"effect_potency":15,"telegraph_text":"Дракон Гравитационного Разлома готовит «Схлопывание».","damage_multiplier":2.35,"max_enemy_hp_percent":100,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0},{"id":"world_2026_12_17_gravity_dragon_phase","kind":"enrage","name":"Нулевая масса","phase":2,"value":45,"enabled":true,"cooldown":9,"max_uses":1,"priority":90,"attack_text":"Дракон Гравитационного Разлома: Нулевая масса.","damage_type":null,"effect_type":null,"min_debuffs":0,"effect_turns":0,"effect_chance":0,"effect_potency":0,"telegraph_text":"Фаза меняется: Нулевая масса.","damage_multiplier":0,"max_enemy_hp_percent":40,"min_enemy_hp_percent":0,"max_player_hp_percent":100,"min_player_hp_percent":0}]'::jsonb,true,false
)
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,
 special_name=excluded.special_name,special_damage_multiplier=excluded.special_damage_multiplier,
 special_every_n=excluded.special_every_n,special_damage_type=excluded.special_damage_type,
 special_effect_type=excluded.special_effect_type,special_effect_chance=excluded.special_effect_chance,
 special_effect_turns=excluded.special_effect_turns,special_effect_potency=excluded.special_effect_potency,
 special_telegraph_text=excluded.special_telegraph_text,special_attack_text=excluded.special_attack_text,
 phase2_hp_percent=excluded.phase2_hp_percent,phase2_name=excluded.phase2_name,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,
 phase2_defense_bonus_percent=excluded.phase2_defense_bonus_percent,
 phase2_special_every_n=excluded.phase2_special_every_n,abilities=excluded.abilities,is_strong_enemy=true,updated_at=now();

insert into public.event_boss_events(
 slug,boss_kind,name,description,enabled,starts_at,ends_at,enemy_template_id,
 recommended_level,solo_enemy_level,solo_hp,solo_attack,solo_defense,solo_initiative,
 party_hp_per_extra,party_attack_per_extra,party_defense_per_extra,
 special_reward_item_id,first_reward_gold,first_reward_experience,repeat_reward_gold,repeat_reward_experience,
 special_every_n,special_damage_multiplier,phase2_hp_percent,phase2_attack_bonus_percent,
 solo_only,max_victories_per_character,mechanics,global_clear_target,
 reward_material_item_id,reward_material_quantity,featured_loot
)
select
 'world_2026_12_17_gravity_dragon','monthly','Дракон Гравитационного Разлома',
 'Мировая угроза: дракон удерживает вокруг себя искривлённое пространство. Его реликты становятся основой первого отдельного гравитационного билда. Каждая победа даёт материал босса. Уникальная вещь может выпасть сразу или быть гарантированно создана из накопленных материалов.',
 true,'2026-12-17T15:00:00Z'::timestamptz,'2026-12-28T15:00:00Z'::timestamptz,et.id,
 18,20,3900,118,74,38,
 0.85,0.10,0.06,
 null,400,420,80,80,
 3,2.35,40,45,false,null,
 '{"scheduled":true,"loot_model":"material_plus_drop"}'::jsonb,null,
 mat.id,1,'[{"slug":"falling_axis_spear","chance_percent":5,"craft_cost":10},{"slug":"singularity_core","chance_percent":5,"craft_cost":10}]'::jsonb
from public.enemy_templates et
join public.item_definitions mat on mat.slug='gravity_dragon_core_shard'
where et.slug='calendar_world_2026_12_17_gravity_dragon'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 starts_at=excluded.starts_at,ends_at=excluded.ends_at,enemy_template_id=excluded.enemy_template_id,
 recommended_level=excluded.recommended_level,solo_enemy_level=excluded.solo_enemy_level,
 solo_hp=excluded.solo_hp,solo_attack=excluded.solo_attack,solo_defense=excluded.solo_defense,
 solo_initiative=excluded.solo_initiative,first_reward_gold=excluded.first_reward_gold,
 first_reward_experience=excluded.first_reward_experience,repeat_reward_gold=excluded.repeat_reward_gold,
 repeat_reward_experience=excluded.repeat_reward_experience,special_every_n=excluded.special_every_n,
 special_damage_multiplier=excluded.special_damage_multiplier,phase2_hp_percent=excluded.phase2_hp_percent,
 phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,mechanics=excluded.mechanics,
 reward_material_item_id=excluded.reward_material_item_id,reward_material_quantity=excluded.reward_material_quantity,
 featured_loot=excluded.featured_loot,updated_at=now();

insert into public.crafting_recipes(slug,name,description,enabled,required_level,gold_cost,output_item_definition_id,output_quantity,affix_bonus,sort_order)
select 'boss_falling_axis_spear','Создать: '||out.name,
 'Гарантированное создание уникальной добычи босса из 10 материалов его ротации.',
 true,out.required_level,900,out.id,1,0,3000+out.required_level
from public.item_definitions out where out.slug='falling_axis_spear'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 required_level=excluded.required_level,gold_cost=excluded.gold_cost,output_item_definition_id=excluded.output_item_definition_id,
 output_quantity=1,affix_bonus=0,sort_order=excluded.sort_order,updated_at=now();

insert into public.crafting_recipe_ingredients(recipe_id,item_definition_id,quantity)
select r.id,m.id,10
from public.crafting_recipes r join public.item_definitions m on m.slug='gravity_dragon_core_shard'
where r.slug='boss_falling_axis_spear'
on conflict(recipe_id,item_definition_id) do update set quantity=excluded.quantity;

insert into public.crafting_recipes(slug,name,description,enabled,required_level,gold_cost,output_item_definition_id,output_quantity,affix_bonus,sort_order)
select 'boss_singularity_core','Создать: '||out.name,
 'Гарантированное создание уникальной добычи босса из 10 материалов его ротации.',
 true,out.required_level,900,out.id,1,0,3000+out.required_level
from public.item_definitions out where out.slug='singularity_core'
on conflict(slug) do update set name=excluded.name,description=excluded.description,enabled=true,
 required_level=excluded.required_level,gold_cost=excluded.gold_cost,output_item_definition_id=excluded.output_item_definition_id,
 output_quantity=1,affix_bonus=0,sort_order=excluded.sort_order,updated_at=now();

insert into public.crafting_recipe_ingredients(recipe_id,item_definition_id,quantity)
select r.id,m.id,10
from public.crafting_recipes r join public.item_definitions m on m.slug='gravity_dragon_core_shard'
where r.slug='boss_singularity_core'
on conflict(recipe_id,item_definition_id) do update set quantity=excluded.quantity;

insert into public.enemy_templates(slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,phase2_special_every_n,abilities,is_strong_enemy,is_rare_variant)
values('auto_incursion_beasts','Озверевшая стая','Автоматически возникающая угроза захваченного сектора.',true,null,0,10,true,1,'piercing','{"piercing":10,"fire":-10}'::jsonb,1,1,1,1,'Рваный наскок',1.55,3,'piercing','bleed',55,2,12,'Озверевшая стая готовит особый приём.','Озверевшая стая применяет «Рваный наскок».',35,'Последний натиск',20,0,2,'[]'::jsonb,true,false)
on conflict(slug) do update set enabled=true,name=excluded.name,attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,special_name=excluded.special_name,special_effect_type=excluded.special_effect_type,updated_at=now();

insert into public.enemy_templates(slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,phase2_special_every_n,abilities,is_strong_enemy,is_rare_variant)
values('auto_incursion_marauders','Банда захватчиков','Автоматически возникающая угроза захваченного сектора.',true,null,0,10,true,1,'slashing','{"slashing":10,"blunt":-10}'::jsonb,1,1,1,1,'Грязный натиск',1.55,3,'slashing','vulnerable',55,2,12,'Банда захватчиков готовит особый приём.','Банда захватчиков применяет «Грязный натиск».',35,'Последний натиск',20,0,2,'[]'::jsonb,true,false)
on conflict(slug) do update set enabled=true,name=excluded.name,attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,special_name=excluded.special_name,special_effect_type=excluded.special_effect_type,updated_at=now();

insert into public.enemy_templates(slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,phase2_special_every_n,abilities,is_strong_enemy,is_rare_variant)
values('auto_incursion_spirits','Беспокойные духи','Автоматически возникающая угроза захваченного сектора.',true,null,0,10,true,1,'arcane','{"arcane":25,"moon":-20}'::jsonb,1,1,1,1,'Мёртвый шёпот',1.55,3,'arcane','weaken',55,2,12,'Беспокойные духи готовит особый приём.','Беспокойные духи применяет «Мёртвый шёпот».',35,'Последний натиск',20,0,2,'[]'::jsonb,true,false)
on conflict(slug) do update set enabled=true,name=excluded.name,attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,special_name=excluded.special_name,special_effect_type=excluded.special_effect_type,updated_at=now();

insert into public.enemy_templates(slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,special_name,special_damage_multiplier,special_every_n,special_damage_type,special_effect_type,special_effect_chance,special_effect_turns,special_effect_potency,special_telegraph_text,special_attack_text,phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,phase2_special_every_n,abilities,is_strong_enemy,is_rare_variant)
values('auto_incursion_aberrations','Искажённые твари','Автоматически возникающая угроза захваченного сектора.',true,null,0,10,true,1,'earth','{"earth":20,"fire":-15}'::jsonb,1,1,1,1,'Ломающее тело',1.55,3,'earth','stun',55,2,12,'Искажённые твари готовит особый приём.','Искажённые твари применяет «Ломающее тело».',35,'Последний натиск',20,0,2,'[]'::jsonb,true,false)
on conflict(slug) do update set enabled=true,name=excluded.name,attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,special_name=excluded.special_name,special_effect_type=excluded.special_effect_type,updated_at=now();

create or replace function private.ensure_rotating_sector_incursions()
returns void language plpgsql security definer
set search_path='pg_catalog','public','private'
as $$
declare
 slot_start timestamptz; slot_end timestamptz; slot_key text; i integer;
 chosen_sector smallint; danger integer; profile integer; template_slug text;
 event_name text; event_desc text; v_slug text;
begin
 slot_start:=to_timestamp(floor(extract(epoch from now())/172800)*172800);
 slot_end:=slot_start+interval '48 hours';
 slot_key:=to_char(slot_start at time zone 'UTC','YYYYMMDDHH24');

 for i in 1..2 loop
  v_slug:='auto_incursion_'||slot_key||'_'||i;
  if exists(select 1 from public.event_boss_events where slug=v_slug) then continue; end if;

  select sd.sector_id,greatest(1,least(10,coalesce(sd.danger_level,1)))
  into chosen_sector,danger
  from public.sector_details sd
  where sd.content_type='wilderness' and sd.terrain_type<>'sea'
    and not exists(
      select 1 from public.event_boss_events old
      where old.boss_kind='sector_incursion' and old.sector_id=sd.sector_id
        and old.starts_at>=slot_start-interval '6 days'
    )
    and not exists(
      select 1 from public.event_boss_events same_slot
      where same_slot.boss_kind='sector_incursion' and same_slot.starts_at=slot_start
        and same_slot.sector_id=sd.sector_id
    )
  order by md5(slot_key||':'||i||':'||sd.sector_id::text)
  limit 1;

  if chosen_sector is null then continue; end if;

  profile:=1+(abs(hashtext(slot_key||':'||i||':'||chosen_sector::text))%4);
  template_slug:=case profile when 1 then 'auto_incursion_beasts' when 2 then 'auto_incursion_marauders' when 3 then 'auto_incursion_spirits' else 'auto_incursion_aberrations' end;
  event_name:=case profile when 1 then 'Озверевшая стая' when 2 then 'Банда захватчиков' when 3 then 'Беспокойные духи' else 'Искажённые твари' end;
  event_desc:=event_name||' захватили сектор. Угроза выбрана живым миром автоматически и исчезнет через 48 часов, если её не зачистить.';

  insert into public.event_boss_events(
    slug,boss_kind,name,description,enabled,starts_at,ends_at,enemy_template_id,
    recommended_level,solo_enemy_level,solo_hp,solo_attack,solo_defense,solo_initiative,
    party_hp_per_extra,party_attack_per_extra,party_defense_per_extra,special_reward_item_id,
    first_reward_gold,first_reward_experience,repeat_reward_gold,repeat_reward_experience,
    special_every_n,special_damage_multiplier,phase2_hp_percent,phase2_attack_bonus_percent,
    sector_id,solo_only,max_victories_per_character,mechanics,global_clear_target
  )
  select v_slug,'sector_incursion',event_name,event_desc,true,slot_start,slot_end,et.id,
    greatest(1,danger*2),greatest(2,danger*2+1),150+danger*70,18+danger*7,7+danger*4,10+danger*2,
    0.65,0.08,0.05,null,50,100,50,100,3,1.55,35,20,chosen_sector,false,1,
    jsonb_build_object('auto_rotation',true,'slot',slot_key,'profile',profile),3
  from public.enemy_templates et where et.slug=template_slug;
 end loop;
end;
$$;
revoke all on function private.ensure_rotating_sector_incursions() from public;

create index if not exists event_boss_events_active_kind_idx
  on public.event_boss_events(boss_kind,starts_at,ends_at) where enabled;

