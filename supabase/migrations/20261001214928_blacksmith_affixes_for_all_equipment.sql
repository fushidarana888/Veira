create or replace function private.equipment_affix_apply_cost(
  p_base_value bigint,
  p_rarity text,
  p_slot_number integer
)
returns bigint
language sql
immutable
set search_path to 'pg_catalog','private'
as $function$
  select private.weapon_affix_apply_cost(p_base_value,p_rarity,p_slot_number);
$function$;

create or replace function private.equipment_affix_reroll_cost(
  p_base_value bigint,
  p_rarity text,
  p_slot_number integer,
  p_reroll_count integer
)
returns bigint
language sql
immutable
set search_path to 'pg_catalog','private'
as $function$
  select private.weapon_affix_reroll_cost(p_base_value,p_rarity,p_slot_number,p_reroll_count);
$function$;

create or replace function public.get_settlement_blacksmith_affixes(
  p_character_id uuid,
  p_sector_id smallint
)
returns table(
  settlement_name text,
  settlement_level smallint,
  affix_apply_unlocked boolean,
  affix_reroll_unlocked boolean,
  character_item_id uuid,
  item_definition_id uuid,
  item_name text,
  custom_name text,
  category text,
  equip_group text,
  rarity text,
  is_equipped boolean,
  affix_slots integer,
  affix_count integer,
  affixes jsonb,
  next_affix_cost bigint,
  can_add_affix boolean,
  can_afford_affix boolean,
  affix_reroll_count integer,
  reroll_costs jsonb
)
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $function$
declare
  caller uuid:=auth.uid();
  settlement public.sector_details;
  current_gold bigint:=0;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  if not exists(
    select 1 from public.character_sector_discoveries d
    where d.character_id=p_character_id and d.sector_id=p_sector_id
  ) then raise exception 'SETTLEMENT_NOT_DISCOVERED'; end if;

  select * into settlement
  from public.sector_details
  where sector_id=p_sector_id;

  if settlement.sector_id is null or settlement.content_type<>'settlement' then
    raise exception 'SECTOR_IS_NOT_SETTLEMENT';
  end if;

  select cp.gold into current_gold
  from public.character_progress cp
  where cp.character_id=p_character_id;

  return query
  with owned as (
    select
      ci.id,
      ci.item_definition_id,
      ci.custom_name,
      ci.metadata,
      ci.acquired_at,
      d.name item_name0,
      d.category::text category0,
      d.equip_group::text equip_group0,
      d.rarity::text rarity0,
      d.base_value base_value0,
      private.item_affix_slot_count(d.rarity::text) slots0,
      case
        when jsonb_typeof(ci.metadata->'affixes')='array'
        then jsonb_array_length(ci.metadata->'affixes')
        else 0
      end affix_count0,
      greatest(0,coalesce((ci.metadata->>'affix_reroll_count')::integer,0)) rerolls0
    from public.character_items ci
    join public.item_definitions d on d.id=ci.item_definition_id
    where ci.character_id=p_character_id
      and d.category::text in ('weapon','armor','accessory')
      and d.equip_group is not null
  )
  select
    coalesce(settlement.title,'Поселение')::text,
    settlement.settlement_level,
    private.blacksmith_affix_apply_unlocked(settlement.settlement_level),
    private.blacksmith_affix_reroll_unlocked(settlement.settlement_level),
    o.id,
    o.item_definition_id,
    o.item_name0,
    o.custom_name,
    o.category0,
    o.equip_group0,
    o.rarity0,
    exists(
      select 1 from public.character_equipment ce
      where ce.character_id=p_character_id
        and ce.character_item_id=o.id
    ),
    o.slots0,
    o.affix_count0,
    case when jsonb_typeof(o.metadata->'affixes')='array'
      then o.metadata->'affixes' else '[]'::jsonb end,
    case when o.affix_count0>=o.slots0 or o.slots0=0 then null else
      private.equipment_affix_apply_cost(
        o.base_value0,o.rarity0,o.affix_count0+1
      )
    end,
    private.blacksmith_affix_apply_unlocked(settlement.settlement_level)
      and o.slots0>0
      and o.affix_count0<o.slots0,
    private.blacksmith_affix_apply_unlocked(settlement.settlement_level)
      and o.slots0>0
      and o.affix_count0<o.slots0
      and current_gold>=private.equipment_affix_apply_cost(
        o.base_value0,o.rarity0,o.affix_count0+1
      ),
    o.rerolls0,
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'slot',x.ordinality,
          'affix_id',x.value->>'id',
          'cost',private.equipment_affix_reroll_cost(
            o.base_value0,o.rarity0,x.ordinality::integer,o.rerolls0
          )
        )
        order by x.ordinality
      )
      from jsonb_array_elements(
        case when jsonb_typeof(o.metadata->'affixes')='array'
          then o.metadata->'affixes' else '[]'::jsonb end
      ) with ordinality x(value,ordinality)
    ),'[]'::jsonb)
  from owned o
  order by
    exists(
      select 1 from public.character_equipment ce
      where ce.character_id=p_character_id
        and ce.character_item_id=o.id
    ) desc,
    case o.category0 when 'weapon' then 1 when 'armor' then 2 else 3 end,
    o.item_name0,
    o.acquired_at;
end;
$function$;

create or replace function public.apply_equipment_affix_at_blacksmith(
  p_character_id uuid,
  p_sector_id smallint,
  p_character_item_id uuid
)
returns table(
  character_item_id uuid,
  added_affix jsonb,
  gold_spent bigint,
  gold_remaining bigint
)
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $function$
declare
  caller uuid:=auth.uid();
  settlement public.sector_details;
  cp public.character_progress;
  ci public.character_items;
  item public.item_definitions;
  slots integer;
  current_count integer;
  cost bigint;
  excluded uuid[]:='{}'::uuid[];
  picked jsonb;
  new_meta jsonb;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters c where c.id=p_character_id and c.owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;
  if private.character_busy_for_blacksmith(p_character_id)
    then raise exception 'CHARACTER_BUSY'; end if;
  if not exists(select 1 from public.character_sector_discoveries d where d.character_id=p_character_id and d.sector_id=p_sector_id)
    then raise exception 'SETTLEMENT_NOT_DISCOVERED'; end if;

  select * into settlement from public.sector_details where sector_id=p_sector_id;
  if settlement.sector_id is null or settlement.content_type<>'settlement'
    then raise exception 'SECTOR_IS_NOT_SETTLEMENT'; end if;
  if not private.blacksmith_affix_apply_unlocked(settlement.settlement_level)
    then raise exception 'AFFIX_SERVICE_LOCKED'; end if;

  select * into ci from public.character_items x
  where x.id=p_character_item_id and x.character_id=p_character_id
  for update;
  if ci.id is null then raise exception 'ITEM_NOT_OWNED'; end if;

  select * into item from public.item_definitions d where d.id=ci.item_definition_id;
  if item.id is null
     or item.category::text not in ('weapon','armor','accessory')
     or item.equip_group is null
    then raise exception 'ITEM_IS_NOT_EQUIPMENT'; end if;

  slots:=private.item_affix_slot_count(item.rarity::text);
  current_count:=case when jsonb_typeof(ci.metadata->'affixes')='array'
    then jsonb_array_length(ci.metadata->'affixes') else 0 end;

  if slots=0 then raise exception 'ITEM_HAS_NO_AFFIX_SLOTS'; end if;
  if current_count>=slots then raise exception 'AFFIX_SLOTS_FULL'; end if;

  select coalesce(array_agg((x.value->>'id')::uuid),'{}'::uuid[])
  into excluded
  from jsonb_array_elements(
    case when jsonb_typeof(ci.metadata->'affixes')='array'
      then ci.metadata->'affixes' else '[]'::jsonb end
  ) x(value)
  where x.value->>'id' is not null;

  picked:=private.roll_single_item_affix(item.id,excluded);
  if picked is null then raise exception 'NO_ELIGIBLE_AFFIX'; end if;

  cost:=private.equipment_affix_apply_cost(item.base_value,item.rarity::text,current_count+1);
  select * into cp from public.character_progress p where p.character_id=p_character_id for update;
  if cp.gold<cost then raise exception 'NOT_ENOUGH_GOLD'; end if;

  new_meta:=coalesce(ci.metadata,'{}'::jsonb);
  new_meta:=jsonb_set(
    new_meta,
    '{affixes}',
    (case when jsonb_typeof(new_meta->'affixes')='array' then new_meta->'affixes' else '[]'::jsonb end)
      ||jsonb_build_array(picked),
    true
  );
  new_meta:=private.rebuild_item_affix_metadata(new_meta);

  update public.character_items set metadata=new_meta where id=ci.id;
  update public.character_progress set gold=gold-cost,updated_at=now() where character_id=p_character_id;

  return query select ci.id,picked,cost,(cp.gold-cost)::bigint;
end;
$function$;

create or replace function public.reroll_equipment_affix_at_blacksmith(
  p_character_id uuid,
  p_sector_id smallint,
  p_character_item_id uuid,
  p_affix_id uuid
)
returns table(
  character_item_id uuid,
  removed_affix_id uuid,
  new_affix jsonb,
  gold_spent bigint,
  gold_remaining bigint
)
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $function$
declare
  caller uuid:=auth.uid();
  settlement public.sector_details;
  cp public.character_progress;
  ci public.character_items;
  item public.item_definitions;
  affixes jsonb;
  slot_no integer;
  rerolls integer;
  cost bigint;
  excluded uuid[]:='{}'::uuid[];
  picked jsonb;
  replaced jsonb;
  new_meta jsonb;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters c where c.id=p_character_id and c.owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;
  if private.character_busy_for_blacksmith(p_character_id)
    then raise exception 'CHARACTER_BUSY'; end if;
  if not exists(select 1 from public.character_sector_discoveries d where d.character_id=p_character_id and d.sector_id=p_sector_id)
    then raise exception 'SETTLEMENT_NOT_DISCOVERED'; end if;

  select * into settlement from public.sector_details where sector_id=p_sector_id;
  if settlement.sector_id is null or settlement.content_type<>'settlement'
    then raise exception 'SECTOR_IS_NOT_SETTLEMENT'; end if;
  if not private.blacksmith_affix_reroll_unlocked(settlement.settlement_level)
    then raise exception 'AFFIX_REROLL_LOCKED'; end if;

  select * into ci from public.character_items x
  where x.id=p_character_item_id and x.character_id=p_character_id
  for update;
  if ci.id is null then raise exception 'ITEM_NOT_OWNED'; end if;

  select * into item from public.item_definitions d where d.id=ci.item_definition_id;
  if item.id is null
     or item.category::text not in ('weapon','armor','accessory')
     or item.equip_group is null
    then raise exception 'ITEM_IS_NOT_EQUIPMENT'; end if;

  affixes:=case when jsonb_typeof(ci.metadata->'affixes')='array'
    then ci.metadata->'affixes' else '[]'::jsonb end;

  select x.ordinality::integer into slot_no
  from jsonb_array_elements(affixes) with ordinality x(value,ordinality)
  where x.value->>'id'=p_affix_id::text
  limit 1;

  if slot_no is null then raise exception 'AFFIX_NOT_FOUND'; end if;

  select coalesce(array_agg((x.value->>'id')::uuid),'{}'::uuid[])
  into excluded
  from jsonb_array_elements(affixes) x(value)
  where x.value->>'id' is not null;

  picked:=private.roll_single_item_affix(item.id,excluded);
  if picked is null then raise exception 'NO_ALTERNATIVE_AFFIX'; end if;

  rerolls:=greatest(0,coalesce((ci.metadata->>'affix_reroll_count')::integer,0));
  cost:=private.equipment_affix_reroll_cost(item.base_value,item.rarity::text,slot_no,rerolls);

  select * into cp from public.character_progress p where p.character_id=p_character_id for update;
  if cp.gold<cost then raise exception 'NOT_ENOUGH_GOLD'; end if;

  select coalesce(jsonb_agg(
    case when x.ordinality=slot_no then picked else x.value end
    order by x.ordinality
  ),'[]'::jsonb)
  into replaced
  from jsonb_array_elements(affixes) with ordinality x(value,ordinality);

  new_meta:=jsonb_set(coalesce(ci.metadata,'{}'::jsonb),'{affixes}',replaced,true);
  new_meta:=jsonb_set(new_meta,'{affix_reroll_count}',to_jsonb(rerolls+1),true);
  new_meta:=private.rebuild_item_affix_metadata(new_meta);

  update public.character_items set metadata=new_meta where id=ci.id;
  update public.character_progress set gold=gold-cost,updated_at=now() where character_id=p_character_id;

  return query select ci.id,p_affix_id,picked,cost,(cp.gold-cost)::bigint;
end;
$function$;

revoke all on function public.get_settlement_blacksmith_affixes(uuid,smallint) from public, anon;
grant execute on function public.get_settlement_blacksmith_affixes(uuid,smallint) to authenticated;

revoke all on function public.apply_equipment_affix_at_blacksmith(uuid,smallint,uuid) from public, anon;
grant execute on function public.apply_equipment_affix_at_blacksmith(uuid,smallint,uuid) to authenticated;

revoke all on function public.reroll_equipment_affix_at_blacksmith(uuid,smallint,uuid,uuid) from public, anon;
grant execute on function public.reroll_equipment_affix_at_blacksmith(uuid,smallint,uuid,uuid) to authenticated;
