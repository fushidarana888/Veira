-- Synced from live Supabase migration 20260927215659 (world_alive_wandering_merchant)


create or replace function private.current_wandering_merchant_sector(
  p_character_id uuid
) returns smallint
language sql
stable
security definer
set search_path='pg_catalog','public','private'
as $$
  select sd.sector_id
  from public.character_sector_discoveries cd
  join public.sector_details sd
    on sd.sector_id=cd.sector_id
   and sd.content_type='settlement'
  where cd.character_id=p_character_id
  order by md5(current_date::text||':'||sd.sector_id::text)
  limit 1;
$$;

create or replace function public.buy_wandering_merchant_item(
  p_character_id uuid,
  p_item_definition_id uuid
) returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  caller uuid:=auth.uid();
  cp public.character_progress;
  offer_price_value integer;
  offer_name text;
  merchant_sector smallint;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  merchant_sector:=private.current_wandering_merchant_sector(p_character_id);
  if merchant_sector is null then raise exception 'WANDERING_MERCHANT_NOT_AVAILABLE'; end if;

  if not exists(
    select 1
    from (
      select c2.item_definition_id
      from public.wandering_merchant_catalog c2
      join public.character_progress p2 on p2.character_id=p_character_id
      where c2.enabled
        and p2.level between c2.min_level and c2.max_level
      order by md5(current_date::text||':'||c2.item_definition_id::text)
      limit 4
    ) offered
    where offered.item_definition_id=p_item_definition_id
  ) then
    raise exception 'WANDERING_ITEM_NOT_OFFERED_TODAY';
  end if;

  select c.offer_price,d.name
  into offer_price_value,offer_name
  from public.wandering_merchant_catalog c
  join public.item_definitions d on d.id=c.item_definition_id
  where c.item_definition_id=p_item_definition_id
    and c.enabled;

  if offer_price_value is null then raise exception 'WANDERING_ITEM_NOT_OFFERED'; end if;

  if exists(
    select 1
    from public.wandering_merchant_purchases p
    where p.character_id=p_character_id
      and p.item_definition_id=p_item_definition_id
      and p.rotation_date=current_date
  ) then raise exception 'WANDERING_ITEM_ALREADY_BOUGHT'; end if;

  select * into cp
  from public.character_progress
  where character_id=p_character_id
  for update;

  if cp.gold<offer_price_value then raise exception 'NOT_ENOUGH_GOLD'; end if;

  update public.character_progress
  set gold=gold-offer_price_value,
      updated_at=now()
  where character_id=p_character_id;

  perform private.grant_item_slug(
    p_character_id,
    (select slug from public.item_definitions where id=p_item_definition_id),
    1
  );

  insert into public.wandering_merchant_purchases(
    character_id,item_definition_id,rotation_date
  )
  values(p_character_id,p_item_definition_id,current_date);

  return jsonb_build_object(
    'item_name',offer_name,
    'price',offer_price_value,
    'sector_id',merchant_sector
  );
end;
$$;

revoke all on function private.current_wandering_merchant_sector(uuid) from public;

