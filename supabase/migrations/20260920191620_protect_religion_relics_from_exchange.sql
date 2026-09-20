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
$function$
