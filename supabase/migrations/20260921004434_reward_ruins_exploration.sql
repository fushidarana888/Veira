
alter table public.sector_site_actions
  add column if not exists result_kind text not null default '',
  add column if not exists reward_gold integer not null default 0,
  add column if not exists reward_experience integer not null default 0,
  add column if not exists reward_items jsonb not null default '[]'::jsonb;

create or replace function private.resolve_ruins_exploration(
  p_character_id uuid,
  p_sector_id smallint,
  p_action_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $function$
declare
  sd public.sector_details;
  v_danger integer:=0;
  v_roll numeric:=random()*100;
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

  if v_roll<40 then
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
$function$;

create or replace function private.complete_expired_site_actions(p_character_id uuid)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $function$
declare
  action_row public.sector_site_actions;
  sd public.sector_details;
  completed_count integer := 0;
  v_result_title text;
  v_result_text text;
  v_result_kind text:='';
  v_reward_gold integer:=0;
  v_reward_experience integer:=0;
  v_reward_items jsonb:='[]'::jsonb;
  v_ruins_result jsonb;
  next_site_type text;
  next_status text;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.characters c
    where c.id = p_character_id
      and (
        c.owner_user_id = auth.uid()
        or private.is_gm(auth.uid())
      )
  ) then
    raise exception 'CHARACTER_NOT_OWNED';
  end if;

  for action_row in
    select a.*
    from public.sector_site_actions a
    where a.character_id = p_character_id
      and a.status = 'active'
      and a.ends_at <= now()
    order by a.started_at
    for update
  loop
    select *
      into sd
    from public.sector_details
    where sector_id = action_row.sector_id;

    v_result_kind:='';
    v_reward_gold:=0;
    v_reward_experience:=0;
    v_reward_items:='[]'::jsonb;

    if action_row.action_type = 'explore_ruins' then
      v_ruins_result:=private.resolve_ruins_exploration(
        action_row.character_id,
        action_row.sector_id,
        action_row.id
      );

      v_result_title:=coalesce(v_ruins_result->>'title',coalesce(nullif(sd.title,''),'Руины исследованы'));
      v_result_text:=coalesce(v_ruins_result->>'text','Руины исследованы.');
      v_result_kind:=coalesce(v_ruins_result->>'kind','');
      v_reward_gold:=coalesce((v_ruins_result->>'gold')::integer,0);
      v_reward_experience:=coalesce((v_ruins_result->>'experience')::integer,0);
      v_reward_items:=coalesce(v_ruins_result->'items','[]'::jsonb);
      next_site_type := 'ruins';
      next_status := 'explored';
    else
      v_result_title := coalesce(nullif(sd.title,''), 'Вход в подземелье разведан');
      v_result_text :=
        'Подходы к подземелью разведаны, безопасный вход найден и отмечен. '
        || 'Теперь персонаж может начать отдельное прохождение подземелья.';
      next_site_type := 'dungeon';
      next_status := 'scouted';
    end if;

    update public.sector_site_actions
    set status = 'completed',
        completed_at = now(),
        result_title = v_result_title,
        result_text = v_result_text,
        result_kind = v_result_kind,
        reward_gold = v_reward_gold,
        reward_experience = v_reward_experience,
        reward_items = v_reward_items
    where id = action_row.id;

    insert into public.character_sector_site_progress (
      character_id,
      sector_id,
      site_type,
      status,
      first_interacted_at,
      completed_at,
      updated_at
    )
    values (
      action_row.character_id,
      action_row.sector_id,
      next_site_type,
      next_status,
      action_row.started_at,
      now(),
      now()
    )
    on conflict (character_id, sector_id) do update
    set site_type = excluded.site_type,
        status = case
          when public.character_sector_site_progress.status = 'cleared' then 'cleared'
          else excluded.status
        end,
        completed_at = excluded.completed_at,
        updated_at = now();

    completed_count := completed_count + 1;
  end loop;

  return completed_count;
end;
$function$;
