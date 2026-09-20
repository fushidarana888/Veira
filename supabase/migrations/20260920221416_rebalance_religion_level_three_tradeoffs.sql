update public.religion_level_perks
set title=v.title,
    description=v.description,
    modifiers=v.modifiers::jsonb
from (values
  ('path_of_light'::text,3,'Ясность долга'::text,'Весь прямой урон -5%, Удача +3.'::text,'{"all_damage_bonus":-5,"luck":3}'::text),
  ('old_roots'::text,3,'Звериная поступь'::text,'Весь магический урон -3%, Ловкость +3.'::text,'{"magic_damage_bonus":-3,"agility":3}'::text),
  ('star_covenant'::text,3,'Знак пути'::text,'Весь физический урон -3%, Удача +3.'::text,'{"physical_damage_bonus":-3,"luck":3}'::text)
) as v(religion_slug,level,title,description,modifiers)
where religion_level_perks.religion_slug=v.religion_slug
  and religion_level_perks.level=v.level;
