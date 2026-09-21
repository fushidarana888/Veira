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

  if def.slug='tempering_mark_iii' or def.religion_origin_slug is not null then
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
$function$;

CREATE OR REPLACE FUNCTION public.sacrifice_item_to_abyss(p_character_id uuid, p_character_item_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
  ci public.character_items;
  def public.item_definitions;
  current_slug text;
  source_key text:=gen_random_uuid()::text;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select current_religion_slug into current_slug
  from public.character_religions where character_id=p_character_id;
  if current_slug<>'abyss' then raise exception 'ABYSS_RELIGION_REQUIRED'; end if;

  select * into ci
  from public.character_items
  where id=p_character_item_id and character_id=p_character_id
  for update;
  if ci.id is null then raise exception 'ITEM_NOT_AVAILABLE'; end if;

  if exists(select 1 from public.character_equipment where character_item_id=ci.id)
    then raise exception 'ITEM_IS_EQUIPPED'; end if;

  select * into def from public.item_definitions where id=ci.item_definition_id;
  if def.id is null or def.rarity::text not in ('rare','epic','legendary','unique')
    then raise exception 'SACRIFICE_REQUIRES_RARE_ITEM'; end if;
  if def.category::text='material' and def.rarity::text='unique' then
    raise exception 'UNIQUE_MATERIAL_PROTECTED';
  end if;
  if def.religion_origin_slug is not null then raise exception 'RELIGIOUS_RELIC_CANNOT_BE_SACRIFICED'; end if;

  if ci.quantity>1 then
    update public.character_items set quantity=quantity-1 where id=ci.id;
  else
    perform set_config('veira.item_delete_reason','abyss_sacrifice',true);
    delete from public.character_items where id=ci.id;
    perform set_config('veira.item_delete_reason','',true);
  end if;

  perform private.record_religion_event(
    p_character_id,'item_sacrificed',source_key,
    jsonb_build_object('rarity',def.rarity::text,'item_name',def.name)
  );

  return def.name;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_abyss_sacrifice_items(p_character_id uuid)
 RETURNS TABLE(character_item_id uuid, item_name text, rarity text, quantity integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller uuid:=auth.uid();
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  return query
  select ci.id,i.name,i.rarity::text,ci.quantity
  from public.character_items ci
  join public.item_definitions i on i.id=ci.item_definition_id
  left join public.character_equipment eq on eq.character_item_id=ci.id
  where ci.character_id=p_character_id
    and i.religion_origin_slug is null
    and eq.character_item_id is null
    and i.rarity::text in ('rare','epic','legendary','unique')
    and not (i.category::text='material' and i.rarity::text='unique')
  order by case i.rarity::text when 'unique' then 4 when 'legendary' then 3 when 'epic' then 2 else 1 end desc,
           i.name;
end;
$function$;