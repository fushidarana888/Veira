CREATE OR REPLACE FUNCTION private.get_game_guide_catalog_internal()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  caller uuid:=auth.uid();
begin
  if caller is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  return jsonb_build_object(
    'items',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',d.id,
          'slug',d.slug,
          'name',d.name,
          'description',d.description,
          'category',d.category::text,
          'rarity',d.rarity::text,
          'equip_group',case when d.equip_group is null then null else d.equip_group::text end,
          'stat_modifiers',coalesce(d.stat_modifiers,'{}'::jsonb),
          'required_level',d.required_level,
          'shop_tier',d.shop_tier,
          'shop_price',d.shop_price,
          'damage_type',d.damage_type,
          'damage_resistances',coalesce(d.damage_resistances,'{}'::jsonb),
          'damage_bonuses',coalesce(d.damage_bonuses,'{}'::jsonb),
          'weapon_base_damage',coalesce(d.weapon_base_damage,0),
          'weapon_scaling',d.weapon_scaling,
          'weapon_family',d.weapon_family,
          'bow_full_draw_armor_penetration_percent',coalesce(d.bow_full_draw_armor_penetration_percent,0),
          'bloodshed_chance_percent',coalesce(d.bloodshed_chance_percent,0),
          'echo_strike_chance_percent',coalesce(d.echo_strike_chance_percent,0),
          'unique_property_name',d.unique_property_name,
          'unique_property_description',coalesce(d.unique_property_description,''),
          'unique_effect_type',d.unique_effect_type,
          'unique_effect_value',coalesce(d.unique_effect_value,0)
        )
        order by
          case d.category::text when 'weapon' then 0 when 'armor' then 1 else 2 end,
          d.required_level,
          d.rarity::text,
          d.name
      )
      from public.item_definitions d
      where d.category::text in ('weapon','armor','accessory')
    ),'[]'::jsonb),
    'spells',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',s.id,
          'slug',s.slug,
          'name',s.name,
          'description',s.description,
          'spell_kind',s.spell_kind,
          'damage_type',s.damage_type,
          'mana_cost',s.mana_cost,
          'required_level',s.required_level,
          'power_multiplier',s.power_multiplier,
          'flat_power',s.flat_power,
          'status_effect_type',s.status_effect_type,
          'status_effect_chance',s.status_effect_chance,
          'status_effect_turns',s.status_effect_turns,
          'status_effect_potency',s.status_effect_potency,
          'support_effect_type',s.support_effect_type,
          'support_value',s.support_value,
          'support_turns',s.support_turns,
          'families',coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'slug',mf.slug,
                'name',mf.name,
                'kind',mf.kind
              )
              order by mf.kind,mf.sort_order,mf.name
            )
            from public.spell_magic_families smf
            join public.magic_families mf on mf.slug=smf.family_slug
            where smf.spell_id=s.id and mf.enabled=true
          ),'[]'::jsonb)
        )
        order by s.required_level,s.name
      )
      from public.spell_definitions s
      where s.enabled=true
    ),'[]'::jsonb),
    'magic_families',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'slug',mf.slug,
          'name',mf.name,
          'kind',mf.kind,
          'description',mf.description,
          'spell_count',(
            select count(*)::integer
            from public.spell_magic_families smf
            join public.spell_definitions sd on sd.id=smf.spell_id
            where smf.family_slug=mf.slug and sd.enabled=true
          )
        )
        order by
          case mf.kind when 'element' then 0 when 'school' then 1 else 2 end,
          mf.sort_order,mf.name
      )
      from public.magic_families mf
      where mf.enabled=true
    ),'[]'::jsonb),
    'races',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',r.id,
          'slug',r.slug,
          'name',r.name,
          'category',r.category,
          'description',r.description,
          'stat_modifiers',coalesce(r.stat_modifiers,'{}'::jsonb),
          'traits',coalesce(r.traits,'[]'::jsonb),
          'innate_magic_damage_type',r.innate_magic_damage_type,
          'hp_bonus',r.hp_bonus,
          'mana_bonus',r.mana_bonus,
          'hp_regen_per_hour',r.hp_regen_per_hour,
          'mana_regen_per_hour',r.mana_regen_per_hour,
          'damage_resistances',coalesce(r.damage_resistances,'{}'::jsonb),
          'passive_type',r.passive_type,
          'passive_value',r.passive_value,
          'passive_name',r.passive_name,
          'passive_description',r.passive_description
        )
        order by r.sort_order,r.name
      )
      from public.race_definitions r
      where r.playable=true
    ),'[]'::jsonb),
    'affixes',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',a.id,
          'slug',a.slug,
          'name',a.name,
          'description',a.description,
          'min_rarity_rank',a.min_rarity_rank,
          'max_rarity_rank',a.max_rarity_rank,
          'allowed_categories',a.allowed_categories,
          'allowed_equip_groups',a.allowed_equip_groups,
          'stat_modifiers',coalesce(a.stat_modifiers,'{}'::jsonb),
          'damage_resistances',coalesce(a.damage_resistances,'{}'::jsonb),
          'unique_effect_type',a.unique_effect_type,
          'unique_effect_value',coalesce(a.unique_effect_value,0)
        )
        order by a.min_rarity_rank,a.name
      )
      from public.equipment_affixes a
      where a.enabled=true
    ),'[]'::jsonb),
    'religions',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'slug',r.slug,
          'name',r.name,
          'short_motto',r.short_motto,
          'description',r.description,
          'praise_text',r.praise_text,
          'taboo_text',r.taboo_text,
          'faith_daily_cap',r.faith_daily_cap,
          'level10_reward_item_id',r.level10_reward_item_id,
          'level10_reward_item_name',reward.name,
          'perks',coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'level',p.level,
                'title',p.title,
                'description',p.description,
                'modifiers',coalesce(p.modifiers,'{}'::jsonb)
              )
              order by p.level
            )
            from public.religion_level_perks p
            where p.religion_slug=r.slug
          ),'[]'::jsonb),
          'oaths',coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'id',o.id,
                'slug',o.slug,
                'name',o.name,
                'description',o.description,
                'target_count',o.target_count,
                'faith_reward',o.faith_reward,
                'favor_reward',o.favor_reward,
                'failure_faith_penalty',o.failure_faith_penalty,
                'failure_favor_penalty',o.failure_favor_penalty
              )
              order by o.sort_order,o.name
            )
            from public.religion_oath_definitions o
            where o.religion_slug=r.slug and o.enabled=true
          ),'[]'::jsonb)
        )
        order by r.sort_order,r.name
      )
      from public.religion_definitions r
      left join public.item_definitions reward on reward.id=r.level10_reward_item_id
      where r.enabled=true
    ),'[]'::jsonb),
    'religion_level_thresholds',
    jsonb_build_array(
      jsonb_build_object('level',1,'faith',0),
      jsonb_build_object('level',2,'faith',100),
      jsonb_build_object('level',3,'faith',220),
      jsonb_build_object('level',4,'faith',380),
      jsonb_build_object('level',5,'faith',580),
      jsonb_build_object('level',6,'faith',820),
      jsonb_build_object('level',7,'faith',1100),
      jsonb_build_object('level',8,'faith',1420),
      jsonb_build_object('level',9,'faith',1780),
      jsonb_build_object('level',10,'faith',2200)
    ),
    'religion_rules',
    jsonb_build_object(
      'faith_max',2200,
      'ordinary_daily_cap',60,
      'oath_weekly_cap',100,
      'inactive_relic_penalty_percent',20
    ),
    'religion_faith_sources',
    jsonb_build_array(
      jsonb_build_object('religion_slug','path_of_light','kind','gain','title','Поручение защиты','faith',10,'favor',0,'description','Завершить поручение поселения с темой защиты.'),
      jsonb_build_object('religion_slug','path_of_light','kind','gain','title','Обычное поручение','faith',5,'favor',0,'description','Завершить общее поручение поселения. Другие темы дают +3 веры.'),
      jsonb_build_object('religion_slug','path_of_light','kind','gain','title','Поддерживающее действие','faith',2,'favor',0,'description','Применить в реальном бою лечение, щит, очищение, бафф или провокацию.'),
      jsonb_build_object('religion_slug','path_of_light','kind','gain','title','Защита','faith',1,'favor',0,'description','Использовать действие «Защита» в реальном бою.'),
      jsonb_build_object('religion_slug','path_of_light','kind','gain','title','Групповое подземелье','faith',10,'favor',1,'description','Завершить групповое подземелье живым участником группы.'),

      jsonb_build_object('religion_slug','old_roots','kind','gain','title','Природное поручение','faith',10,'favor',0,'description','Завершить поручение поселения с природной темой.'),
      jsonb_build_object('religion_slug','old_roots','kind','gain','title','Обычное поручение','faith',5,'favor',0,'description','Завершить общее поручение поселения. Другие темы дают +2 веры.'),
      jsonb_build_object('religion_slug','old_roots','kind','gain','title','Новый сектор дикой природы','faith',4,'favor',0,'description','Впервые открыть wilderness-сектор.'),
      jsonb_build_object('religion_slug','old_roots','kind','gain','title','Экспедиция в дикой природе','faith',10,'favor',0,'description','Полностью завершить экспедицию в wilderness-секторе.'),
      jsonb_build_object('religion_slug','old_roots','kind','penalty','title','Начало охоты','faith',-20,'favor',-10,'description','Охота нарушает табу Старых Корней уже в момент начала.'),
      jsonb_build_object('religion_slug','old_roots','kind','penalty','title','Убийство на охоте','faith',-30,'favor',-15,'description','Успешное убийство сильного монстра на охоте дополнительно усугубляет нарушение.'),

      jsonb_build_object('religion_slug','star_covenant','kind','gain','title','Исследовательское или магическое поручение','faith',10,'favor',0,'description','Завершить поручение поселения с темой research или arcane.'),
      jsonb_build_object('religion_slug','star_covenant','kind','gain','title','Обычное поручение','faith',5,'favor',0,'description','Завершить общее поручение поселения. Другие темы дают +2 веры.'),
      jsonb_build_object('religion_slug','star_covenant','kind','gain','title','Изучение заклинания','faith',15,'favor',1,'description','Навсегда изучить новое заклинание.'),
      jsonb_build_object('religion_slug','star_covenant','kind','gain','title','Применение магии','faith',2,'favor',0,'description','Использовать врождённую магию или изученное заклинание в реальном бою.'),
      jsonb_build_object('religion_slug','star_covenant','kind','gain','title','Новый сектор','faith',2,'favor',0,'description','Впервые открыть любой новый сектор мира.'),

      jsonb_build_object('religion_slug','abyss','kind','gain','title','Боевое поручение','faith',10,'favor',0,'description','Завершить поручение поселения с боевой темой.'),
      jsonb_build_object('religion_slug','abyss','kind','gain','title','Обычное поручение','faith',5,'favor',0,'description','Завершить общее поручение поселения. Другие темы дают +2 веры.'),
      jsonb_build_object('religion_slug','abyss','kind','gain','title','Обычное подземелье','faith',10,'favor',0,'description','Полностью зачистить обычное соло-подземелье.'),
      jsonb_build_object('religion_slug','abyss','kind','gain','title','Мировой event-босс','faith',15,'favor',2,'description','Победить активного event-босса.'),
      jsonb_build_object('religion_slug','abyss','kind','gain','title','Жертва Rare','faith',8,'favor',1,'description','Пожертвовать Бездне подходящий предмет редкости Rare.'),
      jsonb_build_object('religion_slug','abyss','kind','gain','title','Жертва Epic','faith',12,'favor',2,'description','Пожертвовать Бездне подходящий предмет редкости Epic.'),
      jsonb_build_object('religion_slug','abyss','kind','gain','title','Жертва Legendary','faith',18,'favor',3,'description','Пожертвовать Бездне подходящий предмет редкости Legendary.'),
      jsonb_build_object('religion_slug','abyss','kind','gain','title','Жертва Unique','faith',20,'favor',4,'description','Пожертвовать подходящий Unique-предмет. Уникальные материалы/ресурсы и религиозные реликвии жертвовать нельзя.')
    ),
    'mechanics',
    jsonb_build_object(
      'enhancement_percent_per_level',3,
      'enhancement_max',20,
      'awakening_max',5,
      'critical_cap_percent',60,
      'physical_critical_multiplier',1.5,
      'magic_critical_multiplier',1.4,
      'loot_quality_luck_relative_percent_per_point',1,
      'affix_slots',jsonb_build_object(
        'common',0,
        'uncommon',1,
        'rare',2,
        'epic',3,
        'unique',4,
        'legendary',5
      )
    )
  );
end;
$function$;