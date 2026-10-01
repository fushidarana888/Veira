
update public.event_boss_events
set description=case slug
  when 'monthly_2026_10_zero_hour_colossus'
    then 'Колосс Нулевого Часа ломает ритм боя гравитационными ударами. «Обнуление такта» лучше встречать блоком, щитом, отражением или контролем.'
  when 'monthly_2026_11_extinguished_seraph'
    then 'Серафим Погасшего Солнца давит затяжным звёздным горением. Здесь особенно полезны лечение, очищение и водный урон.'
  when 'monthly_2026_12_underking'
    then 'Король Под Горами выдерживает долгий бой и наказывает слабую защиту. Провокация, отражение, Уязвимость и молния помогают вскрывать его оборону.'
  else description
end
where slug in (
  'monthly_2026_10_zero_hour_colossus',
  'monthly_2026_11_extinguished_seraph',
  'monthly_2026_12_underking'
);

