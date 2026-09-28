-- Synced from live Supabase migration 20260927221444 (fix_treasure_map_target_sector)

CREATE OR REPLACE FUNCTION public.activate_treasure_map(p_character_id uuid, p_character_item_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
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

  select ms.id,
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
$function$;
