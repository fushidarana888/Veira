-- Rebalance Luck: stronger Rare+ quality, lucky bonus affixes, scalable damage variance and ruins finds.
CREATE OR REPLACE FUNCTION private.character_lucky_affix_chance_percent(p_character_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  select least(
    35.0,
    greatest(0.0,coalesce(s.luck,0)::numeric)
  )
  from private.get_character_combat_stats(p_character_id) s;
$function$
;

CREATE OR REPLACE FUNCTION private.character_loot_quality_bonus_percent(p_character_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  select least(
    100.0,
    greatest(0,coalesce(s.luck,0))*2.0
      +case when coalesce(private.character_current_favor(p_character_id),0)>=50 then 15.0 else 0.0 end
  )
  from private.get_character_combat_stats(p_character_id) s;
$function$
;

CREATE OR REPLACE FUNCTION private.combat_damage_variance(p_luck integer DEFAULT 0)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
declare
  result integer := floor(random()*9)::integer - 4;
  luck_value integer:=greatest(0,coalesce(p_luck,0));
  full_nudges integer:=least(10,greatest(0,coalesce(p_luck,0))/10);
  remainder_chance integer:=(greatest(0,coalesce(p_luck,0))%10)*3;
begin
  -- Luck never expands the visible -4..+4 range.
  -- Every full 10 Luck adds another independent 30% chance to nudge
  -- the result upward by one; the remaining Luck contributes 3% each.
  if full_nudges>0 then
    for i in 1..full_nudges loop
      if result<4 and floor(random()*100)::integer<30 then
        result:=result+1;
      end if;
    end loop;
  end if;

  if result<4
     and remainder_chance>0
     and floor(random()*100)::integer<remainder_chance
  then
    result:=result+1;
  end if;

  return result;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.roll_item_affixes(p_item_definition_id uuid, p_bonus_count integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  item public.item_definitions;
  wanted_count integer;
  current_count integer:=0;
  picked jsonb;
  metadata jsonb:=jsonb_build_object('affixes','[]'::jsonb);
  excluded uuid[]:='{}'::uuid[];
  picked_id uuid;
begin
  select * into item
  from public.item_definitions
  where id=p_item_definition_id;

  if item.id is null
     or item.category::text not in ('weapon','armor','accessory')
     or item.equip_group is null
  then
    return private.rebuild_item_affix_metadata(metadata);
  end if;

  wanted_count:=private.item_affix_slot_count(item.rarity::text);
  wanted_count:=least(
    5,
    greatest(0,wanted_count+coalesce(p_bonus_count,0))
  );

  while current_count<wanted_count loop
    picked:=private.roll_single_item_affix(item.id,excluded);
    exit when picked is null;

    metadata:=jsonb_set(
      metadata,
      '{affixes}',
      coalesce(metadata->'affixes','[]'::jsonb)||jsonb_build_array(picked),
      true
    );

    picked_id:=(picked->>'id')::uuid;
    excluded:=array_append(excluded,picked_id);
    current_count:=current_count+1;
  end loop;

  return private.rebuild_item_affix_metadata(metadata);
end;
$function$
;

CREATE OR REPLACE FUNCTION private.grant_character_item(p_character_id uuid, p_item_definition_id uuid, p_quantity integer, p_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  item public.item_definitions;
  stack_row public.character_items;
  remaining integer;
  add_now integer;
  generated_metadata jsonb;
  bonus_count integer;
  source_kind text;
  lucky_affix_chance numeric:=0;
  lucky_bonus_count integer:=0;
  base_affix_slots integer:=0;
  luck_at_drop integer:=0;
begin
  if p_quantity<1 then return; end if;

  select * into item
  from public.item_definitions
  where id=p_item_definition_id;

  if item.id is null then raise exception 'ITEM_NOT_FOUND'; end if;

  if item.stackable then
    remaining:=p_quantity;

    for stack_row in
      select ci.*
      from public.character_items ci
      where ci.character_id=p_character_id
        and ci.item_definition_id=p_item_definition_id
        and ci.custom_name is null
        and ci.quantity<item.max_stack
      order by ci.acquired_at
      for update
    loop
      exit when remaining<=0;
      add_now:=least(remaining,item.max_stack-stack_row.quantity);
      update public.character_items set quantity=quantity+add_now where id=stack_row.id;
      remaining:=remaining-add_now;
    end loop;

    while remaining>0 loop
      add_now:=least(remaining,item.max_stack);
      insert into public.character_items(character_id,item_definition_id,quantity,metadata)
      values(p_character_id,p_item_definition_id,add_now,'{}'::jsonb);
      remaining:=remaining-add_now;
    end loop;
  else
    source_kind:=coalesce(p_metadata->>'source','');
    bonus_count:=coalesce((p_metadata->>'affix_bonus')::integer,0);
    base_affix_slots:=private.item_affix_slot_count(item.rarity::text);

    if source_kind in ('loot','dungeon_completion')
       and item.category::text in ('weapon','armor','accessory')
    then
      select coalesce(s.luck,0)::integer into luck_at_drop
      from private.get_character_combat_stats(p_character_id) s;
      lucky_affix_chance:=private.character_lucky_affix_chance_percent(p_character_id);
    end if;

    for i in 1..p_quantity loop
      generated_metadata:=coalesce(p_metadata,'{}'::jsonb);
      lucky_bonus_count:=0;

      if source_kind in ('loot','dungeon_completion')
         and item.category::text in ('weapon','armor','accessory')
         and base_affix_slots between 1 and 4
         and random()*100<lucky_affix_chance
      then
        lucky_bonus_count:=1;
        generated_metadata:=generated_metadata||jsonb_build_object(
          'lucky_affix_upgrade',true,
          'luck_at_drop',luck_at_drop,
          'lucky_affix_chance_percent',round(lucky_affix_chance,2)
        );
      end if;

      if source_kind in ('loot','dungeon_completion','crafting')
         and item.category::text in ('weapon','armor','accessory')
      then
        generated_metadata:=generated_metadata
          ||private.roll_item_affixes(item.id,bonus_count+lucky_bonus_count);
      end if;

      insert into public.character_items(
        character_id,item_definition_id,quantity,metadata
      )
      values(
        p_character_id,p_item_definition_id,1,generated_metadata
      );
    end loop;
  end if;
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
  v_luck integer:=0;
  v_luck_ancient_bonus numeric:=0;
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

  select coalesce(s.luck,0)::integer into v_luck
  from private.get_character_combat_stats(p_character_id) s;
  v_luck_ancient_bonus:=least(4.0,greatest(0,v_luck)*0.15);

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
  end + coalesce(v_ancient_bonus,0) + coalesce(v_luck_ancient_bonus,0);

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
      'critical_cap_percent',75,
      'physical_critical_multiplier',1.5,
      'magic_critical_multiplier',1.4,
      'loot_quality_luck_relative_percent_per_point',2,
      'lucky_affix_chance_percent_per_luck',1,
      'lucky_affix_chance_cap_percent',35,
      'ruins_ancient_luck_flat_percent_per_point',0.15,
      'ruins_ancient_luck_cap_percent',4,
      'luck_variance_nudge_percent_per_point',3,
      'luck_variance_nudge_chunk',10,
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
$function$
;

revoke all on function private.character_lucky_affix_chance_percent(uuid) from public,anon,authenticated;
revoke all on function private.character_loot_quality_bonus_percent(uuid) from public,anon,authenticated;
revoke all on function private.combat_damage_variance(integer) from public,anon,authenticated;
revoke all on function private.roll_item_affixes(uuid,integer) from public,anon,authenticated;
revoke all on function private.grant_character_item(uuid,uuid,integer,jsonb) from public,anon,authenticated;
revoke all on function private.resolve_ruins_exploration(uuid,smallint,uuid) from public,anon,authenticated;
revoke all on function private.get_game_guide_catalog_internal() from public,anon,authenticated;
