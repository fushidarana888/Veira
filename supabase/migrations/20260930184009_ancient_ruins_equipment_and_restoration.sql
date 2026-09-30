-- Ancient equipment from ruins, damaged variants and relic-fragment restoration.
insert into public.item_definitions(
  slug,name,description,category,rarity,equip_group,stackable,max_stack,
  base_value,required_level,shop_tier,shop_price,shop_enabled,
  damage_type,weapon_base_damage,weapon_scaling,weapon_family,
  stat_modifiers,damage_resistances,damage_bonuses,effects,
  unique_property_name,unique_property_description,unique_effect_type,unique_effect_value,
  echo_strike_chance_percent,bloodshed_chance_percent,bow_full_draw_armor_penetration_percent
)
values
('ancient_broken_beat_boots','Сапоги Сломанного Такта','Сапоги будто пытаются идти на полшага раньше владельца, сбивая обычный ритм боя.','armor','epic','feet',false,1,520,9,0,0,false,null,0,null,null,'{"luck":2,"agility":5}'::jsonb,'{"air":8}'::jsonb,'{}'::jsonb,'[{"type":"untouched_tempo","initiative_meter_bonus":15}]'::jsonb,'Сломанный такт','Если между собственными действиями владелец не получил прямого урона, следующий ход получает +15 к шкале инициативы.','untouched_tempo',15,0,0,0),
('ancient_broken_beat_boots_damaged','Повреждённый: Сапоги Сломанного Такта','Древний предмет пережил века не полностью. Его можно восстановить за 3 Осколка древней реликвии.','armor','rare','feet',false,1,182,9,0,0,false,null,0,null,null,'{"luck":1,"agility":3}'::jsonb,'{}'::jsonb,'{}'::jsonb,'[{"type":"ancient_restoration","target_slug":"ancient_broken_beat_boots","fragment_cost":3}]'::jsonb,'Повреждённая реликвия','Часть древнего механизма не работает. Восстановление: 3 Осколка древней реликвии.',null,0,0,0,0),
('ancient_fallen_star_spear','Копьё Погасшей Звезды','Копьё из матового металла, который становится тяжелее в момент стремительного выпада.','weapon','epic','weapon',false,1,520,7,0,0,false,'piercing',20,'hybrid','spear','{"luck":1,"agility":3,"strength":3}'::jsonb,'{"star":7}'::jsonb,'{}'::jsonb,'[{"type":"initiative_gap_bonus","max_bonus_percent":16,"initiative_per_percent":4}]'::jsonb,'Падение звезды','Преимущество в инициативе превращается в дополнительный прямой урон, вплоть до +16%.','initiative_gap_bonus',16,0,0,0),
('ancient_fallen_star_spear_damaged','Повреждённый: Копьё Погасшей Звезды','Древний предмет пережил века не полностью. Его можно восстановить за 3 Осколка древней реликвии.','weapon','rare','weapon',false,1,182,7,0,0,false,'piercing',14,'hybrid','spear','{"agility":1,"strength":2}'::jsonb,'{}'::jsonb,'{}'::jsonb,'[{"type":"ancient_restoration","target_slug":"ancient_fallen_star_spear","fragment_cost":3}]'::jsonb,'Повреждённая реликвия','Часть древнего механизма не работает. Восстановление: 3 Осколка древней реликвии.',null,0,0,0,0),
('ancient_forgotten_guard_plate','Панцирь Забытого Стража','Тяжёлый панцирь неизвестной стражи. Внутренние пластины на миг смыкаются перед смертельным ударом.','armor','unique','chest',false,1,850,11,0,0,false,null,0,null,null,'{"strength":2,"vitality":7,"max_hp_percent":6}'::jsonb,'{"blunt":8,"piercing":8,"slashing":8}'::jsonb,'{}'::jsonb,'[{"type":"one_shot_cap","max_single_hit_max_hp_percent":40}]'::jsonb,'Последняя пластина','Раз за бой один прямой удар не может снять больше 40% максимального HP.','one_shot_cap',40,0,0,0),
('ancient_forgotten_guard_plate_damaged','Повреждённый: Панцирь Забытого Стража','Древний предмет пережил века не полностью. Его можно восстановить за 4 Осколка древней реликвии.','armor','epic','chest',false,1,298,11,0,0,false,null,0,null,null,'{"vitality":4,"max_hp_percent":3}'::jsonb,'{}'::jsonb,'{}'::jsonb,'[{"type":"ancient_restoration","target_slug":"ancient_forgotten_guard_plate","fragment_cost":4}]'::jsonb,'Повреждённая реликвия','Часть древнего механизма не работает. Восстановление: 4 Осколка древней реликвии.',null,0,0,0,0),
('ancient_glass_chorus_mask','Маска Стеклянного Хора','Полупрозрачная маска отвечает на чужие проклятия множеством едва слышных голосов.','armor','epic','head',false,1,500,8,0,0,false,null,0,null,null,'{"luck":3,"intellect":4}'::jsonb,'{"arcane":10}'::jsonb,'{}'::jsonb,'[{"type":"first_debuff_reflect","reflected_potency_percent":45}]'::jsonb,'Стеклянный хор','Первый негативный статус в каждом бою поглощается и возвращается источнику с 45% исходной силы.','first_debuff_reflect',45,0,0,0),
('ancient_glass_chorus_mask_damaged','Повреждённый: Маска Стеклянного Хора','Древний предмет пережил века не полностью. Его можно восстановить за 3 Осколка древней реликвии.','armor','rare','head',false,1,175,8,0,0,false,null,0,null,null,'{"luck":1,"intellect":2}'::jsonb,'{}'::jsonb,'{}'::jsonb,'[{"type":"ancient_restoration","target_slug":"ancient_glass_chorus_mask","fragment_cost":3}]'::jsonb,'Повреждённая реликвия','Часть древнего механизма не работает. Восстановление: 3 Осколка древней реликвии.',null,0,0,0,0),
('ancient_old_cartographer_eye','Око Старого Картографа','Линза древнего картографа показывает на местности линии, которых нет ни на одной современной карте.','accessory','rare','accessory',false,1,300,4,0,0,false,null,0,null,null,'{"luck":2,"agility":1,"exploration_speed_percent":20,"ruins_rare_find_bonus_percent":3}'::jsonb,'{}'::jsonb,'{}'::jsonb,'[]'::jsonb,'Невидимые маршруты','Скорость исследования +20%. Пока Око надето, шанс древней экипировки в руинах повышается на 3 п.п.',null,0,0,0,0),
('ancient_old_cartographer_eye_damaged','Повреждённый: Око Старого Картографа','Древний предмет пережил века не полностью. Его можно восстановить за 2 Осколка древней реликвии.','accessory','uncommon','accessory',false,1,105,4,0,0,false,null,0,null,null,'{"luck":1,"exploration_speed_percent":8,"ruins_rare_find_bonus_percent":1}'::jsonb,'{}'::jsonb,'{}'::jsonb,'[{"type":"ancient_restoration","target_slug":"ancient_old_cartographer_eye","fragment_cost":2}]'::jsonb,'Повреждённая реликвия','Часть древнего механизма не работает. Восстановление: 2 Осколка древней реликвии.',null,0,0,0,0),
('ancient_second_strike_blade','Клинок Второго Удара','Тонкий древний меч с раздвоенным эхом удара. Руны на лезвии вспыхивают уже после попадания.','weapon','rare','weapon',false,1,260,4,0,0,false,'slashing',13,'hybrid','sword','{"luck":1,"agility":2,"strength":2}'::jsonb,'{"arcane":4}'::jsonb,'{}'::jsonb,'[]'::jsonb,'Второй удар','Каждый прямой физический удар имеет 30% шанс породить Эхо — дополнительный удар по той же цели.',null,0,30,0,0),
('ancient_second_strike_blade_damaged','Повреждённый: Клинок Второго Удара','Древний предмет пережил века не полностью. Его можно восстановить за 2 Осколка древней реликвии.','weapon','uncommon','weapon',false,1,91,4,0,0,false,'slashing',9,'hybrid','sword','{"agility":1,"strength":1}'::jsonb,'{}'::jsonb,'{}'::jsonb,'[{"type":"ancient_restoration","target_slug":"ancient_second_strike_blade","fragment_cost":2}]'::jsonb,'Повреждённая реликвия','Часть древнего механизма не работает. Восстановление: 2 Осколка древней реликвии.',null,0,0,0,0),
('ancient_silent_string_bow','Лук Безмолвной Тетивы','Тетива не издаёт звука даже при полном натяжении. На плечах лука проступают тонкие трещины света.','weapon','epic','weapon',false,1,560,8,0,0,false,'piercing',18,'agility','short_bow','{"luck":2,"agility":5}'::jsonb,'{"air":6}'::jsonb,'{}'::jsonb,'[{"type":"bow_alternation","crack_bonus_percent":30,"bonus_armor_penetration_percent":25}]'::jsonb,'Тихая трещина','Быстрый выстрел оставляет Трещину, а следующий полный натяг раскалывает её: +30% урона и +25 п.п. пробития брони.','bow_alternation',30,0,0,28),
('ancient_silent_string_bow_damaged','Повреждённый: Лук Безмолвной Тетивы','Древний предмет пережил века не полностью. Его можно восстановить за 3 Осколка древней реликвии.','weapon','rare','weapon',false,1,196,8,0,0,false,'piercing',13,'agility','short_bow','{"luck":1,"agility":3}'::jsonb,'{}'::jsonb,'{}'::jsonb,'[{"type":"ancient_restoration","target_slug":"ancient_silent_string_bow","fragment_cost":3}]'::jsonb,'Повреждённая реликвия','Часть древнего механизма не работает. Восстановление: 3 Осколка древней реликвии.',null,0,0,0,12),
('ancient_stone_memory_hammer','Молот Каменной Памяти','Каменный молот хранит вибрацию каждого удара, который владелец пережил в защитной стойке.','weapon','epic','weapon',false,1,540,7,0,0,false,'blunt',21,'strength','hammer','{"strength":4,"vitality":3}'::jsonb,'{"blunt":6}'::jsonb,'{}'::jsonb,'[{"type":"guard_store","stored_damage_percent":35,"stored_damage_cap_max_hp_percent":20}]'::jsonb,'Каменная память','35% предотвращённого блоком урона сохраняется и усиливает следующую физическую атаку; запас ограничен 20% Max HP.','guard_store',35,0,0,0),
('ancient_stone_memory_hammer_damaged','Повреждённый: Молот Каменной Памяти','Древний предмет пережил века не полностью. Его можно восстановить за 3 Осколка древней реликвии.','weapon','rare','weapon',false,1,189,7,0,0,false,'blunt',15,'strength','hammer','{"strength":2,"vitality":2}'::jsonb,'{}'::jsonb,'{}'::jsonb,'[{"type":"ancient_restoration","target_slug":"ancient_stone_memory_hammer","fragment_cost":3}]'::jsonb,'Повреждённая реликвия','Часть древнего механизма не работает. Восстановление: 3 Осколка древней реликвии.',null,0,0,0,0)
on conflict(slug) do update set
  name=excluded.name,description=excluded.description,category=excluded.category,rarity=excluded.rarity,
  equip_group=excluded.equip_group,stackable=excluded.stackable,max_stack=excluded.max_stack,
  base_value=excluded.base_value,required_level=excluded.required_level,shop_tier=excluded.shop_tier,
  shop_price=excluded.shop_price,shop_enabled=excluded.shop_enabled,damage_type=excluded.damage_type,
  weapon_base_damage=excluded.weapon_base_damage,weapon_scaling=excluded.weapon_scaling,
  weapon_family=excluded.weapon_family,stat_modifiers=excluded.stat_modifiers,
  damage_resistances=excluded.damage_resistances,damage_bonuses=excluded.damage_bonuses,effects=excluded.effects,
  unique_property_name=excluded.unique_property_name,unique_property_description=excluded.unique_property_description,
  unique_effect_type=excluded.unique_effect_type,unique_effect_value=excluded.unique_effect_value,
  echo_strike_chance_percent=excluded.echo_strike_chance_percent,
  bloodshed_chance_percent=excluded.bloodshed_chance_percent,
  bow_full_draw_armor_penetration_percent=excluded.bow_full_draw_armor_penetration_percent,
  updated_at=now();

CREATE OR REPLACE FUNCTION public.restore_ancient_item(p_character_item_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
  ci public.character_items;
  def public.item_definitions;
  restoration jsonb;
  target_slug text;
  target_def public.item_definitions;
  fragment_def public.item_definitions;
  fragment_cost integer;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  select ci0.* into ci
  from public.character_items ci0
  join public.characters c on c.id=ci0.character_id
  where ci0.id=p_character_item_id
    and c.owner_user_id=caller
  for update of ci0;

  if ci.id is null then raise exception 'ITEM_NOT_AVAILABLE'; end if;

  if exists(
    select 1 from public.character_equipment ce
    where ce.character_item_id=ci.id
  ) then raise exception 'ITEM_IS_EQUIPPED'; end if;

  if exists(
    select 1 from public.combat_encounters ce
    where ce.character_id=ci.character_id and ce.status='active'
  ) or private.character_in_active_party_combat(ci.character_id) then
    raise exception 'COMBAT_ACTIVE';
  end if;

  select * into def from public.item_definitions where id=ci.item_definition_id;
  if def.id is null then raise exception 'ITEM_NOT_AVAILABLE'; end if;

  select x into restoration
  from jsonb_array_elements(coalesce(def.effects,'[]'::jsonb)) x
  where x->>'type'='ancient_restoration'
  limit 1;

  if restoration is null then raise exception 'ITEM_IS_NOT_DAMAGED_ANCIENT'; end if;

  target_slug:=restoration->>'target_slug';
  fragment_cost:=greatest(1,coalesce((restoration->>'fragment_cost')::integer,1));

  select * into target_def from public.item_definitions where slug=target_slug;
  select * into fragment_def from public.item_definitions where slug='ancient_relic_fragment_beta';

  if target_def.id is null or fragment_def.id is null then
    raise exception 'ANCIENT_RESTORATION_CONFIG_INVALID';
  end if;

  if private.available_character_item_quantity(ci.character_id,fragment_def.id)<fragment_cost then
    raise exception 'NOT_ENOUGH_RELIC_FRAGMENTS';
  end if;

  perform private.consume_character_item_definition(ci.character_id,fragment_def.id,fragment_cost);

  perform set_config('veira.item_delete_reason','ancient_restored',true);
  delete from public.character_items where id=ci.id;
  perform set_config('veira.item_delete_reason','',true);

  perform private.grant_character_item(
    ci.character_id,
    target_def.id,
    1,
    jsonb_build_object(
      'source','ancient_restoration',
      'restored_from',def.slug,
      'fragment_cost',fragment_cost
    )
  );

  perform private.record_discovery(
    ci.character_id,
    'ancient_restoration',
    target_def.slug,
    'Восстановлена древняя реликвия',
    'Осколки древней реликвии вернули предмету его исходную форму: '||target_def.name||'.',
    jsonb_build_object('fragment_cost',fragment_cost,'source_item',def.slug)
  );

  return jsonb_build_object(
    'restored_slug',target_def.slug,
    'restored_name',target_def.name,
    'fragment_cost',fragment_cost
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.resolve_ruins_exploration(p_character_id uuid, p_sector_id smallint, p_action_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  sd public.sector_details;
  v_danger integer:=0;
  v_roll numeric:=random()*100;
  v_ancient_roll numeric:=random()*100;
  v_ancient_chance numeric:=0;
  v_ancient_bonus numeric:=0;
  v_ancient_base_slug text;
  v_damaged_chance numeric:=0;
  v_gold integer;
  v_experience integer;
  v_kind text;
  v_title text;
  v_text text;
  v_item_slug text;
  v_item public.item_definitions;
  v_quantity integer:=0;
  v_items jsonb:='[]'::jsonb;
  v_item_label text:='';
begin
  select * into sd
  from public.sector_details
  where sector_id=p_sector_id;

  if sd.sector_id is null or sd.content_type<>'ruins' then
    raise exception 'SECTOR_IS_NOT_RUINS';
  end if;

  v_danger:=greatest(0,least(10,coalesce(sd.danger_level,0)));

  v_gold:=20+v_danger*10+floor(random()*(11+v_danger*2))::integer;
  v_experience:=25+v_danger*18+floor(random()*(16+v_danger*3))::integer;

  select least(10,coalesce(sum(
    case
      when jsonb_typeof(d.stat_modifiers->'ruins_rare_find_bonus_percent')='number'
        then (d.stat_modifiers->>'ruins_rare_find_bonus_percent')::numeric
      else 0
    end
  ),0))
  into v_ancient_bonus
  from public.character_equipment ce
  join public.character_items ci on ci.id=ce.character_item_id
  join public.item_definitions d on d.id=ci.item_definition_id
  where ce.character_id=p_character_id;

  v_ancient_chance:=case
    when v_danger>=8 then 10
    when v_danger>=7 then 8
    when v_danger>=5 then 6
    when v_danger>=3 then 4
    else 0
  end + coalesce(v_ancient_bonus,0);

  if v_danger>=3 and v_ancient_roll<v_ancient_chance then
    v_kind:='ancient_equipment';
    v_title:='Древняя экипировка';

    if v_danger>=8 then
      v_ancient_base_slug:=(array[
        'ancient_second_strike_blade',
        'ancient_fallen_star_spear',
        'ancient_silent_string_bow',
        'ancient_stone_memory_hammer',
        'ancient_forgotten_guard_plate',
        'ancient_glass_chorus_mask',
        'ancient_broken_beat_boots',
        'ancient_old_cartographer_eye'
      ])[1+floor(random()*8)::integer];
    elsif v_danger>=7 then
      v_ancient_base_slug:=(array[
        'ancient_second_strike_blade',
        'ancient_fallen_star_spear',
        'ancient_silent_string_bow',
        'ancient_stone_memory_hammer',
        'ancient_glass_chorus_mask',
        'ancient_broken_beat_boots',
        'ancient_old_cartographer_eye'
      ])[1+floor(random()*7)::integer];
    elsif v_danger>=5 then
      v_ancient_base_slug:=(array[
        'ancient_second_strike_blade',
        'ancient_fallen_star_spear',
        'ancient_stone_memory_hammer',
        'ancient_glass_chorus_mask',
        'ancient_old_cartographer_eye'
      ])[1+floor(random()*5)::integer];
    else
      v_ancient_base_slug:=(array[
        'ancient_second_strike_blade',
        'ancient_old_cartographer_eye'
      ])[1+floor(random()*2)::integer];
    end if;

    v_damaged_chance:=greatest(35,75-v_danger*4);
    if random()*100<v_damaged_chance then
      v_item_slug:=v_ancient_base_slug||'_damaged';
      v_text:='Среди обломков найден древний предмет. Он повреждён, но его можно восстановить Осколками древней реликвии.';
    else
      v_item_slug:=v_ancient_base_slug;
      v_text:='Редкая удача: древний предмет сохранился достаточно хорошо, чтобы использовать его сразу.';
    end if;
    v_quantity:=1;

  elsif v_roll<40 then
    v_kind:='material_cache';
    v_title:='Старый тайник';
    v_item_slug:=case sd.terrain_type
      when 'desert' then 'sun_glass_beta'
      when 'tundra' then 'frost_crystal_beta'
      when 'swamp' then 'swamp_ichor_beta'
      when 'mountains' then 'stone_core_fragment_beta'
      else 'spirit_ash_beta'
    end;
    v_quantity:=case
      when v_item_slug in ('swamp_ichor_beta','stone_core_fragment_beta')
        then 2+case when v_danger>=6 then 1 else 0 end
      else 1
    end;
    v_text:='За обвалившейся кладкой сохранился небольшой тайник с материалами.';

  elsif v_roll<65 then
    v_kind:='supplies';
    v_title:='Забытые припасы';
    if v_danger<=3 then
      v_item_slug:=case when random()<0.5 then 'healing_potion_small_beta' else 'minor_mana_potion_beta' end;
    elsif v_danger<=6 then
      v_item_slug:=case when random()<0.5 then 'healing_potion_standard_beta' else 'mana_potion_beta' end;
    else
      v_item_slug:=case when random()<0.5 then 'healing_potion_large_beta' else 'greater_mana_potion_beta' end;
    end if;
    v_quantity:=1;
    v_text:='В закрытой нише уцелели припасы прежних обитателей руин.';

  elsif v_roll<82 then
    v_kind:='lost_knowledge';
    v_title:='Утраченное знание';
    if v_danger<5 then
      v_item_slug:=(array[
        'cast_scroll_fire_bolt_beta',
        'cast_scroll_stone_shard_beta',
        'cast_scroll_spark_lance_beta'
      ])[1+floor(random()*3)::integer];
      v_text:='Среди истлевших записей сохранился пригодный к использованию боевой свиток.';
    else
      v_item_slug:=(array[
        'learn_scroll_fire_bolt_beta',
        'learn_scroll_water_lash_beta',
        'learn_scroll_gust_blade_beta',
        'learn_scroll_stone_shard_beta',
        'learn_scroll_spark_lance_beta',
        'learn_scroll_ice_needle_beta',
        'learn_scroll_mending_beta'
      ])[1+floor(random()*7)::integer];
      v_text:='Удалось восстановить фрагмент древнего магического трактата — его знания ещё можно освоить.';
    end if;
    v_quantity:=1;

  elsif v_roll<95 and v_danger>=3 then
    v_kind:='relic_fragment';
    v_title:='Реликтовая находка';
    v_item_slug:='ancient_relic_fragment_beta';
    v_quantity:=1+case when v_danger>=8 and random()<0.30 then 1 else 0 end;
    v_text:='В глубине комплекса обнаружен фрагмент неизвестного древнего изделия.';

  elsif v_roll>=95 and v_danger>=6 then
    v_kind:='sealed_reliquary';
    v_title:='Запечатанный реликварий';
    v_item_slug:='ancient_relic_fragment_beta';
    v_quantity:=2+case when v_danger>=9 then 1 else 0 end;
    v_gold:=v_gold+50+v_danger*10;
    v_experience:=v_experience+40+v_danger*5;
    v_text:='Редкая удача: скрытый реликварий пережил века почти нетронутым.';

  else
    v_kind:='lost_knowledge';
    v_title:='Утраченное знание';
    v_item_slug:=(array[
      'cast_scroll_fire_bolt_beta',
      'cast_scroll_stone_shard_beta',
      'cast_scroll_spark_lance_beta'
    ])[1+floor(random()*3)::integer];
    v_quantity:=1;
    v_text:='Среди обломков удалось найти сохранившийся боевой свиток.';
  end if;

  if v_item_slug is not null and v_quantity>0 then
    select * into v_item
    from public.item_definitions
    where slug=v_item_slug;

    if v_item.id is not null then
      perform private.grant_character_item(
        p_character_id,
        v_item.id,
        v_quantity,
        jsonb_build_object(
          'source','ruins',
          'sector_id',p_sector_id,
          'site_action_id',p_action_id,
          'ruins_result_kind',v_kind
        )
      );

      v_item_label:=v_item.name||' ×'||v_quantity;
      v_items:=jsonb_build_array(jsonb_build_object(
        'item_definition_id',v_item.id,
        'slug',v_item.slug,
        'name',v_item.name,
        'rarity',v_item.rarity::text,
        'quantity',v_quantity
      ));
    end if;
  end if;

  update public.character_progress
  set gold=gold+v_gold,
      experience=experience+v_experience,
      updated_at=now()
  where character_id=p_character_id;

  v_text:=v_text
    ||' Награда: '||v_gold||' золота и '||v_experience||' опыта.'
    ||case when v_item_label<>'' then ' Находка: '||v_item_label||'.' else '' end;

  return jsonb_build_object(
    'kind',v_kind,
    'title',v_title,
    'text',v_text,
    'gold',v_gold,
    'experience',v_experience,
    'items',v_items,
    'danger',v_danger
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.exchange_inventory_item_internal(p_character_item_id uuid, p_quantity integer DEFAULT 1)
 RETURNS TABLE(quantity_exchanged integer, gold_received bigint, remaining_quantity integer, total_gold bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  caller uuid:=auth.uid();
  ci public.character_items;
  def public.item_definitions;
  owner_id uuid;
  unit_value integer:=0;
  remaining integer:=0;
  gained bigint:=0;
  new_total bigint:=0;
  is_equipment boolean:=false;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_quantity<1 then raise exception 'INVALID_QUANTITY'; end if;

  select * into ci
  from public.character_items
  where id=p_character_item_id
  for update;

  if ci.id is null then raise exception 'ITEM_NOT_AVAILABLE'; end if;

  select c.owner_user_id into owner_id
  from public.characters c
  where c.id=ci.character_id;

  if owner_id is null or owner_id<>caller then
    raise exception 'ITEM_NOT_AVAILABLE';
  end if;

  if exists(
    select 1 from public.combat_encounters ce
    where ce.character_id=ci.character_id and ce.status='active'
  ) or private.character_in_active_party_combat(ci.character_id) then
    raise exception 'COMBAT_ACTIVE';
  end if;

  select * into def
  from public.item_definitions d
  where d.id=ci.item_definition_id;

  if def.id is null
     or def.category::text not in ('material','weapon','armor','accessory')
  then
    raise exception 'ITEM_IS_NOT_EXCHANGEABLE';
  end if;

  if def.category::text='material' and def.rarity::text='unique' then
    raise exception 'UNIQUE_MATERIAL_PROTECTED';
  end if;

  if def.slug in ('tempering_mark_iii','ancient_relic_fragment_beta')
     or def.religion_origin_slug is not null then
    raise exception 'PROTECTED_ITEM';
  end if;

  is_equipment:=def.category::text in ('weapon','armor','accessory');

  if is_equipment and exists(
    select 1
    from public.character_equipment eq
    where eq.character_item_id=ci.id
  ) then
    raise exception 'ITEM_IS_EQUIPPED';
  end if;

  if is_equipment and p_quantity<>1 then
    raise exception 'EQUIPMENT_QUANTITY_MUST_BE_ONE';
  end if;

  if p_quantity>ci.quantity then
    raise exception 'NOT_ENOUGH_ITEMS';
  end if;

  if def.category::text='material' then
    unit_value:=case def.rarity::text
      when 'common' then 2
      when 'uncommon' then 5
      when 'rare' then 12
      when 'epic' then 25
      when 'legendary' then 50
      when 'unique' then 100
      else 1
    end;
  else
    unit_value:=case def.rarity::text
      when 'common' then 5
      when 'uncommon' then 12
      when 'rare' then 30
      when 'epic' then 70
      when 'legendary' then 160
      when 'unique' then 350
      else 3
    end;
  end if;

  gained:=unit_value::bigint*p_quantity;
  remaining:=ci.quantity-p_quantity;

  if remaining<=0 then
    if is_equipment then
      perform set_config('veira.item_delete_reason','exchanged',true);
    end if;
    delete from public.character_items where id=ci.id;
    if is_equipment then
      perform set_config('veira.item_delete_reason','',true);
    end if;
  else
    update public.character_items
    set quantity=remaining
    where id=ci.id;
  end if;

  update public.character_progress
  set gold=gold+gained,updated_at=now()
  where character_id=ci.character_id
  returning gold into new_total;

  return query
  select p_quantity,gained,greatest(0,remaining),new_total;
end;
$function$
;

revoke all on function public.restore_ancient_item(uuid) from public,anon;
grant execute on function public.restore_ancient_item(uuid) to authenticated;
revoke all on function private.resolve_ruins_exploration(uuid,smallint,uuid) from public,anon,authenticated;
revoke all on function private.exchange_inventory_item_internal(uuid,integer) from public,anon,authenticated;
