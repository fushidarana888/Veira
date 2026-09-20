update public.religion_level_perks
         set title='Звёздный резонанс',
             description='Урон заклинаний семейства «Звёздная» +5%.',
             modifiers='{"magic_family_damage_bonuses":{"star":5}}'::jsonb
         where religion_slug='star_covenant' and level=8;
