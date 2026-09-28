-- Synced from live Supabase migration 20260928175442 (add_three_monthly_endgame_bosses)


-- Three monthly endgame bosses. They are intentionally far beyond the current live power curve.
insert into public.spell_definitions(
  slug,name,description,enabled,spell_kind,damage_type,mana_cost,required_level,
  power_multiplier,flat_power,status_effect_type,status_effect_chance,status_effect_turns,status_effect_potency
)
values
(
  'zero_hour_tick','Нулевой такт',
  'Короткий разрыв хода противника: гравитационный удар с гарантированным оглушением на 1 ход.',
  true,'damage','gravity',90,25,1.25,25,'stun',100,1,0
),
(
  'extinguished_sun_ash','Пепел Погасшего Солнца',
  'Звёздный жар оставляет длительное горение. Сильное заклинание для поздней игры.',
  true,'damage','star',110,30,1.60,45,'burn',100,3,20
),
(
  'underking_sentence','Каменный приговор',
  'Тяжёлый удар землёй, который вскрывает защиту цели и делает её уязвимой.',
  true,'damage','earth',120,35,1.80,50,'vulnerable',100,3,25
)
on conflict(slug) do update set
  name=excluded.name,
  description=excluded.description,
  enabled=true,
  spell_kind=excluded.spell_kind,
  damage_type=excluded.damage_type,
  mana_cost=excluded.mana_cost,
  required_level=excluded.required_level,
  power_multiplier=excluded.power_multiplier,
  flat_power=excluded.flat_power,
  status_effect_type=excluded.status_effect_type,
  status_effect_chance=excluded.status_effect_chance,
  status_effect_turns=excluded.status_effect_turns,
  status_effect_potency=excluded.status_effect_potency,
  updated_at=now();

insert into public.spell_magic_families(spell_id,family_slug)
select s.id,x.family_slug
from public.spell_definitions s
join (values
  ('zero_hour_tick','gravity'),
  ('extinguished_sun_ash','star'),
  ('underking_sentence','earth')
) x(spell_slug,family_slug) on x.spell_slug=s.slug
on conflict do nothing;

insert into public.item_definitions(
  slug,name,description,category,rarity,equip_group,stackable,max_stack,
  stat_modifiers,effects,base_value,required_level,shop_enabled,damage_resistances,
  unique_property_name,unique_property_description,unique_effect_type,unique_effect_value,
  damage_bonuses
)
values
(
  'zero_hour_chronometer',
  'Хронометр Нулевого Часа',
  'Реликвия Колосса Нулевого Часа. Пока надета, открывает заклинание «Нулевой такт».',
  'accessory','legendary','accessory',false,1,
  '{"agility":6,"intellect":6,"luck":3}'::jsonb,
  '[{"type":"grant_spell","spell_slug":"zero_hour_tick"}]'::jsonb,
  0,25,false,'{"gravity":30,"arcane":15}'::jsonb,
  'Остановка такта',
  'Открывает «Нулевой такт»: гравитационный удар с гарантированным оглушением на 1 ход.',
  'grant_spell',0,'{"gravity":10}'::jsonb
),
(
  'extinguished_sun_reliquary',
  'Реликварий Погасшего Солнца',
  'Обугленная святыня Серафима. Пока надета, открывает заклинание «Пепел Погасшего Солнца».',
  'accessory','legendary','accessory',false,1,
  '{"intellect":10,"vitality":5,"luck":3}'::jsonb,
  '[{"type":"grant_spell","spell_slug":"extinguished_sun_ash"}]'::jsonb,
  0,30,false,'{"fire":30,"star":30}'::jsonb,
  'Пепельное солнце',
  'Открывает «Пепел Погасшего Солнца»: мощный звёздный удар с длительным горением.',
  'grant_spell',0,'{"star":12,"fire":8}'::jsonb
),
(
  'underking_seal',
  'Печать Короля Под Горами',
  'Каменная печать древнего владыки. Пока надета, открывает заклинание «Каменный приговор».',
  'accessory','legendary','accessory',false,1,
  '{"vitality":10,"intellect":7,"strength":4}'::jsonb,
  '[{"type":"grant_spell","spell_slug":"underking_sentence"}]'::jsonb,
  0,35,false,'{"earth":35,"blunt":20}'::jsonb,
  'Приговор гор',
  'Открывает «Каменный приговор»: тяжёлый земной удар, который накладывает сильную уязвимость.',
  'grant_spell',0,'{"earth":12}'::jsonb
)
on conflict(slug) do update set
  name=excluded.name,
  description=excluded.description,
  rarity=excluded.rarity,
  equip_group=excluded.equip_group,
  stat_modifiers=excluded.stat_modifiers,
  effects=excluded.effects,
  required_level=excluded.required_level,
  shop_enabled=false,
  damage_resistances=excluded.damage_resistances,
  unique_property_name=excluded.unique_property_name,
  unique_property_description=excluded.unique_property_description,
  unique_effect_type=excluded.unique_effect_type,
  unique_effect_value=excluded.unique_effect_value,
  damage_bonuses=excluded.damage_bonuses,
  updated_at=now();

insert into public.item_definitions(
  slug,name,description,category,rarity,equip_group,stackable,max_stack,
  stat_modifiers,effects,base_value,required_level,shop_enabled,damage_resistances,
  unique_property_description,unique_effect_value,damage_bonuses
)
values
('zero_hour_fragment','Осколок Нулевого Часа',
 'Материал месячного босса. Используется для гарантированного создания Хронометра Нулевого Часа.',
 'material','epic',null,true,999,'{}'::jsonb,'[]'::jsonb,0,25,false,'{}'::jsonb,'',0,'{}'::jsonb),
('extinguished_sun_ember','Уголь Погасшего Солнца',
 'Материал месячного босса. Используется для гарантированного создания Реликвария Погасшего Солнца.',
 'material','epic',null,true,999,'{}'::jsonb,'[]'::jsonb,0,30,false,'{}'::jsonb,'',0,'{}'::jsonb),
('underking_heartstone','Сердечный камень Подземного Трона',
 'Материал месячного босса. Используется для гарантированного создания Печати Короля Под Горами.',
 'material','epic',null,true,999,'{}'::jsonb,'[]'::jsonb,0,35,false,'{}'::jsonb,'',0,'{}'::jsonb)
on conflict(slug) do update set
  name=excluded.name,description=excluded.description,rarity=excluded.rarity,
  required_level=excluded.required_level,stackable=true,max_stack=999,updated_at=now();

insert into public.enemy_templates(
  slug,name,description,enabled,terrain_type,min_danger,max_danger,is_boss,weight,
  attack_damage_type,damage_resistances,hp_multiplier,attack_multiplier,defense_multiplier,initiative_multiplier,
  special_name,special_damage_multiplier,special_every_n,special_damage_type,
  special_effect_type,special_effect_chance,special_effect_turns,special_effect_potency,
  special_telegraph_text,special_attack_text,
  phase2_hp_percent,phase2_name,phase2_attack_bonus_percent,phase2_defense_bonus_percent,
  phase2_special_every_n,abilities,is_strong_enemy,is_rare_variant
)
values
(
  'monthly_zero_hour_colossus','Колосс Нулевого Часа',
  'Месячная эндгейм-угроза. Колосс искажает темп боя и ломает попытки переждать его тяжёлые удары.',
  true,null,0,10,true,1,'gravity',
  '{"gravity":70,"blunt":45,"piercing":35,"slashing":35,"arcane":25,"star":25}'::jsonb,
  1,1,1,1,'Обнуление такта',2.8,2,'gravity','stun',100,1,0,
  'Колосс останавливает маятник. Следующий удар обнулит темп.',
  'Колосс Нулевого Часа обрушивает «Обнуление такта».',
  50,'Полночь без конца',45,30,2,'[]'::jsonb,true,false
),
(
  'monthly_extinguished_seraph','Серафим Погасшего Солнца',
  'Месячная эндгейм-угроза. Его пламя смешано со звёздной энергией и продолжает убивать после прямого попадания.',
  true,null,0,10,true,1,'star',
  '{"star":75,"fire":70,"arcane":35,"piercing":30,"slashing":30,"water":15}'::jsonb,
  1,1,1,1,'Последний рассвет',3.0,2,'star','burn',100,4,28,
  'За спиной Серафима раскрывается чёрное солнце.',
  'Серафим выпускает «Последний рассвет».',
  45,'Солнце гаснет',50,25,2,'[]'::jsonb,true,false
),
(
  'monthly_underking','Король Под Горами',
  'Месячная эндгейм-угроза. Древний король почти неуязвим для обычного оружия и сокрушает защиту тяжёлыми приговорами.',
  true,null,0,10,true,1,'earth',
  '{"earth":80,"blunt":60,"piercing":45,"slashing":45,"gravity":30,"lightning":20}'::jsonb,
  1,1,1,1,'Приговор глубин',3.2,2,'earth','vulnerable',100,3,35,
  'Гора поднимается вместе с рукой Короля.',
  'Король Под Горами произносит «Приговор глубин».',
  40,'Трон под материком',55,40,2,'[]'::jsonb,true,false
)
on conflict(slug) do update set
  name=excluded.name,description=excluded.description,enabled=true,
  attack_damage_type=excluded.attack_damage_type,damage_resistances=excluded.damage_resistances,
  special_name=excluded.special_name,special_damage_multiplier=excluded.special_damage_multiplier,
  special_every_n=excluded.special_every_n,special_damage_type=excluded.special_damage_type,
  special_effect_type=excluded.special_effect_type,special_effect_chance=excluded.special_effect_chance,
  special_effect_turns=excluded.special_effect_turns,special_effect_potency=excluded.special_effect_potency,
  special_telegraph_text=excluded.special_telegraph_text,special_attack_text=excluded.special_attack_text,
  phase2_hp_percent=excluded.phase2_hp_percent,phase2_name=excluded.phase2_name,
  phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,
  phase2_defense_bonus_percent=excluded.phase2_defense_bonus_percent,
  phase2_special_every_n=excluded.phase2_special_every_n,updated_at=now();

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
  x.slug,'monthly',x.name,x.description,true,x.starts_at,x.ends_at,et.id,
  x.recommended_level,x.enemy_level,x.hp,x.attack,x.defense,x.initiative,
  1.10,0.20,0.12,
  null,x.first_gold,x.first_xp,x.repeat_gold,x.repeat_xp,
  x.special_every_n,x.special_mult,x.phase2_hp,x.phase2_attack,
  false,null,
  jsonb_build_object(
    'scheduled',true,
    'monthly_endgame',true,
    'intentionally_unbeatable_for_current_live_levels',true,
    'loot_model','material_plus_drop'
  ),
  null,
  mat.id,1,
  jsonb_build_array(jsonb_build_object(
    'slug',x.loot_slug,'chance_percent',2,'craft_cost',12
  ))
from (
  values
  (
    'monthly_2026_10_zero_hour_colossus',
    'Колосс Нулевого Часа',
    'Месячный босс октября. Это эндгейм-испытание, рассчитанное на персонажей, значительно превосходящих текущий уровень живых игроков.',
    '2026-10-01 00:00:00+00'::timestamptz,'2026-11-01 00:00:00+00'::timestamptz,
    25,30,120000,1400,700,90,2,2.8,50,45,5000,5000,500,500,
    'monthly_zero_hour_colossus','zero_hour_fragment','zero_hour_chronometer'
  ),
  (
    'monthly_2026_11_extinguished_seraph',
    'Серафим Погасшего Солнца',
    'Месячный босс ноября. Очень поздняя угроза со звёздным уроном и длительным горением.',
    '2026-11-01 00:00:00+00'::timestamptz,'2026-12-01 00:00:00+00'::timestamptz,
    30,35,200000,2000,900,120,2,3.0,45,50,7500,7500,750,750,
    'monthly_extinguished_seraph','extinguished_sun_ember','extinguished_sun_reliquary'
  ),
  (
    'monthly_2026_12_underking',
    'Король Под Горами',
    'Месячный босс декабря. Финальная угроза текущего трёхмесячного календаря с чудовищной защитой и земными приговорами.',
    '2026-12-01 00:00:00+00'::timestamptz,'2027-01-01 00:00:00+00'::timestamptz,
    35,40,320000,2600,1250,75,2,3.2,40,55,10000,10000,1000,1000,
    'monthly_underking','underking_heartstone','underking_seal'
  )
) x(
  slug,name,description,starts_at,ends_at,recommended_level,enemy_level,hp,attack,defense,initiative,
  special_every_n,special_mult,phase2_hp,phase2_attack,first_gold,first_xp,repeat_gold,repeat_xp,
  template_slug,material_slug,loot_slug
)
join public.enemy_templates et on et.slug=x.template_slug
join public.item_definitions mat on mat.slug=x.material_slug
on conflict(slug) do update set
  name=excluded.name,description=excluded.description,enabled=true,
  starts_at=excluded.starts_at,ends_at=excluded.ends_at,enemy_template_id=excluded.enemy_template_id,
  recommended_level=excluded.recommended_level,solo_enemy_level=excluded.solo_enemy_level,
  solo_hp=excluded.solo_hp,solo_attack=excluded.solo_attack,solo_defense=excluded.solo_defense,
  solo_initiative=excluded.solo_initiative,party_hp_per_extra=excluded.party_hp_per_extra,
  party_attack_per_extra=excluded.party_attack_per_extra,party_defense_per_extra=excluded.party_defense_per_extra,
  first_reward_gold=excluded.first_reward_gold,first_reward_experience=excluded.first_reward_experience,
  repeat_reward_gold=excluded.repeat_reward_gold,repeat_reward_experience=excluded.repeat_reward_experience,
  special_every_n=excluded.special_every_n,special_damage_multiplier=excluded.special_damage_multiplier,
  phase2_hp_percent=excluded.phase2_hp_percent,phase2_attack_bonus_percent=excluded.phase2_attack_bonus_percent,
  mechanics=excluded.mechanics,reward_material_item_id=excluded.reward_material_item_id,
  reward_material_quantity=excluded.reward_material_quantity,featured_loot=excluded.featured_loot,
  updated_at=now();

insert into public.crafting_recipes(
  slug,name,description,enabled,required_level,gold_cost,
  output_item_definition_id,output_quantity,affix_bonus,sort_order
)
select
  'boss_'||i.slug,
  'Создать: '||i.name,
  'Гарантированное создание реликвии месячного босса из 12 материалов соответствующей ротации.',
  true,i.required_level,5000,i.id,1,0,5000+i.required_level
from public.item_definitions i
where i.slug in (
  'zero_hour_chronometer','extinguished_sun_reliquary','underking_seal'
)
on conflict(slug) do update set
  name=excluded.name,description=excluded.description,enabled=true,
  required_level=excluded.required_level,gold_cost=excluded.gold_cost,
  output_item_definition_id=excluded.output_item_definition_id,
  output_quantity=1,affix_bonus=0,sort_order=excluded.sort_order,updated_at=now();

insert into public.crafting_recipe_ingredients(recipe_id,item_definition_id,quantity)
select r.id,m.id,12
from (values
  ('boss_zero_hour_chronometer','zero_hour_fragment'),
  ('boss_extinguished_sun_reliquary','extinguished_sun_ember'),
  ('boss_underking_seal','underking_heartstone')
) x(recipe_slug,material_slug)
join public.crafting_recipes r on r.slug=x.recipe_slug
join public.item_definitions m on m.slug=x.material_slug
on conflict(recipe_id,item_definition_id) do update set quantity=excluded.quantity;

