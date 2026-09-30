update public.spell_definitions
set
  support_value=25,
  description='Усиливает следующие 2 прямые атаки на 25%. Работает и с физическими, и с магическими атаками.'
where slug='combat_impulse';
