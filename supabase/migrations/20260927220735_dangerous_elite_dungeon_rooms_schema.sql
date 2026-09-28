-- Synced from live Supabase migration 20260927220735 (dangerous_elite_dungeon_rooms_schema)


alter table public.dungeon_runs
  add column if not exists next_room_elite boolean not null default false;

alter table public.combat_encounters
  add column if not exists is_elite_room boolean not null default false;

insert into public.dungeon_event_definitions(
  slug,name,description,min_danger,max_danger,weight,choices,auto_choice
)
values(
  'sealed_arena',
  'Запечатанная арена',
  'Боковой проход ведёт в зал с тяжёлой дверью. На ней выцарапано: «Войдёт один — выйдет сильнее».',
  1,10,3,
  '[{"slug":"enter","label":"Открыть арену","result":"Печать ломается. В следующем зале тебя ждёт элитный противник и гарантированный трофей.","effect":{"elite_room":true,"discovery_slug":"sealed_arena","discovery_title":"Запечатанная арена","discovery_description":"В некоторых подземельях скрыты опасные боковые залы с усиленными противниками."}},{"slug":"leave","label":"Не открывать","result":"Ты оставляешь тяжёлую дверь закрытой.","effect":{}}]'::jsonb,
  'leave'
)
on conflict(slug) do update set
  name=excluded.name,
  description=excluded.description,
  min_danger=excluded.min_danger,
  max_danger=excluded.max_danger,
  weight=excluded.weight,
  choices=excluded.choices,
  auto_choice=excluded.auto_choice,
  enabled=true,
  updated_at=now();

