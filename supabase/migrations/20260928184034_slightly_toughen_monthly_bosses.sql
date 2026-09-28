-- Synced from live Supabase migration 20260928184034 (slightly_toughen_monthly_bosses)

update public.event_boss_events
set
  solo_hp=3650,
  solo_attack=188,
  solo_defense=176,
  special_damage_multiplier=2.20,
  phase2_attack_bonus_percent=22,
  updated_at=now()
where slug='monthly_2026_10_zero_hour_colossus';

update public.enemy_templates
set
  special_damage_multiplier=2.20,
  phase2_attack_bonus_percent=22,
  phase2_defense_bonus_percent=12,
  updated_at=now()
where slug='monthly_zero_hour_colossus';

update public.event_boss_events
set
  solo_hp=7000,
  solo_attack=272,
  solo_defense=250,
  special_damage_multiplier=2.35,
  phase2_attack_bonus_percent=27,
  updated_at=now()
where slug='monthly_2026_11_extinguished_seraph';

update public.enemy_templates
set
  special_damage_multiplier=2.35,
  phase2_attack_bonus_percent=27,
  phase2_defense_bonus_percent=12,
  updated_at=now()
where slug='monthly_extinguished_seraph';

update public.event_boss_events
set
  solo_hp=11800,
  solo_attack=398,
  solo_defense=355,
  special_damage_multiplier=2.55,
  phase2_attack_bonus_percent=32,
  updated_at=now()
where slug='monthly_2026_12_underking';

update public.enemy_templates
set
  special_damage_multiplier=2.55,
  phase2_attack_bonus_percent=32,
  phase2_defense_bonus_percent=17,
  updated_at=now()
where slug='monthly_underking';
