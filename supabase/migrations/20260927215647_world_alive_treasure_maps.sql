-- Synced from live Supabase migration 20260927215647 (world_alive_treasure_maps)


create or replace function public.activate_treasure_map(
  p_character_id uuid,
  p_character_item_id uuid
) returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  caller uuid:=auth.uid();
  item_row public.character_items;
  def public.item_definitions;
  target_sector smallint;
  target_name text;
  hunt_id uuid;
  tier smallint:=1;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  if exists(
    select 1 from public.character_treasure_hunts h
    where h.character_id=p_character_id and h.status='active'
  ) then raise exception 'TREASURE_HUNT_ALREADY_ACTIVE'; end if;

  select ci.* into item_row
  from public.character_items ci
  where ci.id=p_character_item_id
    and ci.character_id=p_character_id
    and ci.death_spirit_id is null
  for update;

  if item_row.id is null then raise exception 'TREASURE_MAP_ITEM_NOT_FOUND'; end if;

  select * into def
  from public.item_definitions
  where id=item_row.item_definition_id;

  if def.slug not in ('treasure_map_faded','treasure_map_royal') then
    raise exception 'ITEM_IS_NOT_TREASURE_MAP';
  end if;

  tier:=case when def.slug='treasure_map_royal' then 2 else 1 end;

  select sd.sector_id,
         coalesce(sd.title,'Сектор '||ms.grid_col||':'||ms.grid_row)
  into target_sector,target_name
  from public.character_sector_discoveries cd
  join public.map_sectors ms on ms.id=cd.sector_id
  left join public.sector_details sd on sd.sector_id=cd.sector_id
  where cd.character_id=p_character_id
    and coalesce(sd.content_type,'unassigned')<>'settlement'
  order by random()
  limit 1;

  if target_sector is null then
    raise exception 'NO_DISCOVERED_SECTOR_FOR_TREASURE_MAP';
  end if;

  if item_row.quantity>1 then
    update public.character_items
    set quantity=quantity-1
    where id=item_row.id;
  else
    delete from public.character_items where id=item_row.id;
  end if;

  insert into public.character_treasure_hunts(
    character_id,map_item_slug,target_sector_id,target_name,reward_tier
  )
  values(p_character_id,def.slug,target_sector,target_name,tier)
  returning id into hunt_id;

  perform private.record_discovery(
    p_character_id,'treasure_map','active_'||hunt_id::text,
    'Карта сокровищ',
    'На карте отмечен '||target_name||'. Соверши туда новую экспедицию после активации карты.',
    jsonb_build_object('target_sector_id',target_sector,'reward_tier',tier)
  );

  return jsonb_build_object(
    'hunt_id',hunt_id,
    'target_sector_id',target_sector,
    'target_name',target_name,
    'reward_tier',tier
  );
end;
$$;

create or replace function public.claim_treasure_hunt(
  p_hunt_id uuid
) returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  caller uuid:=auth.uid();
  h public.character_treasure_hunts;
  gold_reward integer;
  xp_reward integer;
  bonus_slug text:=null;
  bonus_name text:=null;
  bonus_chance integer:=24;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  select h0.* into h
  from public.character_treasure_hunts h0
  join public.characters c on c.id=h0.character_id
  where h0.id=p_hunt_id
    and c.owner_user_id=caller
  for update of h0;

  if h.id is null then raise exception 'TREASURE_HUNT_NOT_FOUND'; end if;
  if h.status<>'active' then raise exception 'TREASURE_HUNT_NOT_ACTIVE'; end if;

  if not exists(
    select 1
    from public.sector_expeditions e
    where e.character_id=h.character_id
      and e.sector_id=h.target_sector_id
      and e.status='completed'
      and coalesce(e.completed_at,e.created_at)>h.created_at
  ) then
    raise exception 'TREASURE_SECTOR_NOT_VISITED_AFTER_MAP';
  end if;

  gold_reward:=case
    when h.reward_tier>=2 then 170+floor(random()*81)::integer
    else 70+floor(random()*51)::integer
  end;

  xp_reward:=case when h.reward_tier>=2 then 85 else 35 end;
  bonus_chance:=case when h.reward_tier>=2 then 48 else 24 end;

  update public.character_progress
  set gold=gold+gold_reward,
      experience=experience+xp_reward,
      updated_at=now()
  where character_id=h.character_id;

  perform private.grant_item_slug(
    h.character_id,
    'ancient_coin_cache',
    case when h.reward_tier>=2 then 2 else 1 end
  );

  if random()*100 < bonus_chance then
    select x.slug into bonus_slug
    from (values
      ('cursed_glass_ring'),
      ('blessed_wayfarer_charm'),
      ('cursed_bone_mask'),
      ('blessed_moonthread_cloak'),
      ('black_mirror_talisman'),
      ('oathbreaker_greaves')
    ) x(slug)
    join public.item_definitions d on d.slug=x.slug
    where d.required_level<=(
      select level+1
      from public.character_progress
      where character_id=h.character_id
    )
    order by random()
    limit 1;

    if bonus_slug is not null then
      perform private.grant_item_slug(h.character_id,bonus_slug,1);
      select name into bonus_name
      from public.item_definitions
      where slug=bonus_slug;
    end if;
  end if;

  update public.character_treasure_hunts
  set status='claimed',claimed_at=now()
  where id=h.id;

  perform private.record_discovery(
    h.character_id,'treasure','cache_'||h.id::text,
    'Скрытый тайник',
    'Тайник по старой карте найден в районе «'||h.target_name||'».',
    jsonb_build_object('gold',gold_reward,'experience',xp_reward,'bonus_item',bonus_name)
  );

  return jsonb_build_object(
    'gold',gold_reward,
    'experience',xp_reward,
    'bonus_item',bonus_name,
    'target_name',h.target_name
  );
end;
$$;

