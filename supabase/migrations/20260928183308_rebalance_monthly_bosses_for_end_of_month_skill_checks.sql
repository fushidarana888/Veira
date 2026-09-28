-- Synced from live Supabase migration 20260928183308 (rebalance_monthly_bosses_for_end_of_month_skill_checks)


-- Monthly bosses are end-of-month skill checks, not impossible stat walls.
-- The intended curve follows the weekly progression: ~9 / 14 / 18 by the end of each month.

update public.event_boss_events
set
  description='Месячный босс октября. В начале месяца это почти стена, но к последней неделе сильная группа примерно 9 уровня уже получает реальный шанс. Победа должна приходить через правильный состав, защиту на телеграфах, отражение и окна уязвимости, а не через чистый перевес характеристик.',
  recommended_level=9,
  solo_enemy_level=11,
  solo_hp=3400,
  solo_attack=180,
  solo_defense=170,
  solo_initiative=55,
  party_hp_per_extra=0.65,
  party_attack_per_extra=0.04,
  party_defense_per_extra=0.04,
  special_every_n=3,
  special_damage_multiplier=2.15,
  phase2_hp_percent=40,
  phase2_attack_bonus_percent=20,
  mechanics=jsonb_build_object(
    'scheduled',true,
    'monthly_endgame',true,
    'end_of_month_challenge',true,
    'target_party_level',9,
    'design_goal','skill_build_over_stats',
    'loot_model','material_plus_drop',
    'counterplay',jsonb_build_array(
      'Отражать или блокировать «Обнуление такта»',
      'Поддерживать Уязвимость на боссе вместо чистого спама уроном',
      'Разводить ману и защитные действия между телеграфами',
      'Во второй фазе не жадничать уроном'
    )
  )
where slug='monthly_2026_10_zero_hour_colossus';

update public.enemy_templates
set
  description='Месячная угроза октября. Колосс проверяет ритм группы: его обычные удары переживаемы, а телеграфируемое «Обнуление такта» требует блока, щита или отражения.',
  damage_resistances='{"gravity":50,"blunt":25,"piercing":20,"slashing":20,"arcane":10,"star":10,"lightning":-20}'::jsonb,
  special_damage_multiplier=2.15,
  special_every_n=3,
  special_effect_chance=85,
  special_effect_turns=1,
  special_effect_potency=0,
  phase2_hp_percent=40,
  phase2_name='Полночь без конца',
  phase2_attack_bonus_percent=20,
  phase2_defense_bonus_percent=10,
  phase2_special_every_n=2,
  special_telegraph_text='Колосс останавливает маятник. Следующий «Обнуление такта» нужно пережить защитой, отражением или точным контролем.',
  updated_at=now()
where slug='monthly_zero_hour_colossus';

update public.event_boss_events
set
  description='Месячный босс ноября. Рассчитан на сильную группу примерно 14 уровня к последней неделе месяца. Главная проверка — лечение, очищение длительного горения и использование слабости Серафима к воде, а не огромный запас здоровья.',
  recommended_level=14,
  solo_enemy_level=16,
  solo_hp=6500,
  solo_attack=260,
  solo_defense=240,
  solo_initiative=68,
  party_hp_per_extra=0.70,
  party_attack_per_extra=0.05,
  party_defense_per_extra=0.05,
  special_every_n=3,
  special_damage_multiplier=2.30,
  phase2_hp_percent=35,
  phase2_attack_bonus_percent=25,
  mechanics=jsonb_build_object(
    'scheduled',true,
    'monthly_endgame',true,
    'end_of_month_challenge',true,
    'target_party_level',14,
    'design_goal','skill_build_over_stats',
    'loot_model','material_plus_drop',
    'counterplay',jsonb_build_array(
      'Брать стабильное лечение и очищение',
      'Использовать водный урон и Уязвимость',
      'Не оставлять «Последний рассвет» без защитной реакции',
      'Беречь ресурсы к последней фазе'
    )
  )
where slug='monthly_2026_11_extinguished_seraph';

update public.enemy_templates
set
  description='Месячная угроза ноября. Серафим убивает затяжным звёздным горением: грамотное очищение и лечение важнее ещё одного чистого дамагера.',
  damage_resistances='{"star":55,"fire":50,"arcane":15,"piercing":25,"slashing":25,"blunt":20,"water":-25}'::jsonb,
  special_damage_multiplier=2.30,
  special_every_n=3,
  special_effect_chance=90,
  special_effect_turns=3,
  special_effect_potency=16,
  phase2_hp_percent=35,
  phase2_name='Солнце гаснет',
  phase2_attack_bonus_percent=25,
  phase2_defense_bonus_percent=10,
  phase2_special_every_n=2,
  special_telegraph_text='За спиной Серафима раскрывается чёрное солнце. Приготовь щит и очищение к «Последнему рассвету».',
  updated_at=now()
where slug='monthly_extinguished_seraph';

update public.event_boss_events
set
  description='Месячный босс декабря. Рассчитан на хорошо собранную группу примерно 18 уровня к концу месяца. Здесь особенно важны танк с Провокацией, отражение тяжёлых ударов, поддержка через Уязвимость и правильный выбор типа урона.',
  recommended_level=18,
  solo_enemy_level=21,
  solo_hp=11000,
  solo_attack=380,
  solo_defense=340,
  solo_initiative=62,
  party_hp_per_extra=0.75,
  party_attack_per_extra=0.06,
  party_defense_per_extra=0.06,
  special_every_n=3,
  special_damage_multiplier=2.50,
  phase2_hp_percent=30,
  phase2_attack_bonus_percent=30,
  mechanics=jsonb_build_object(
    'scheduled',true,
    'monthly_endgame',true,
    'end_of_month_challenge',true,
    'target_party_level',18,
    'design_goal','skill_build_over_stats',
    'loot_model','material_plus_drop',
    'counterplay',jsonb_build_array(
      'Танк с Провокацией принимает телеграфируемые приговоры',
      'Зеркальный барьер превращает тяжёлый удар босса в окно контратаки',
      'Саппорт держит Уязвимость и помогает пробивать высокую защиту',
      'Молния эффективнее обычного физического спама',
      'Последняя фаза требует экономить ману и защитные кулдауны'
    )
  )
where slug='monthly_2026_12_underking';

update public.enemy_templates
set
  description='Месячная угроза декабря. Король очень крепок, но не является мешком характеристик: его нужно разбирать составом — танк, поддержка и правильное использование телеграфов.',
  damage_resistances='{"earth":60,"blunt":40,"piercing":30,"slashing":30,"gravity":15,"lightning":-25}'::jsonb,
  special_damage_multiplier=2.50,
  special_every_n=3,
  special_effect_chance=90,
  special_effect_turns=2,
  special_effect_potency=20,
  phase2_hp_percent=30,
  phase2_name='Трон под материком',
  phase2_attack_bonus_percent=30,
  phase2_defense_bonus_percent=15,
  phase2_special_every_n=2,
  special_telegraph_text='Гора поднимается вместе с рукой Короля. «Приговор глубин» нельзя принимать всей группой без подготовки.',
  updated_at=now()
where slug='monthly_underking';

