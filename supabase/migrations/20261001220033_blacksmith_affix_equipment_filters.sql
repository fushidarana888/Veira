drop function public.get_settlement_blacksmith_affixes(uuid,smallint);

create function public.get_settlement_blacksmith_affixes(
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
  weapon_family text,
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
      d.weapon_family::text weapon_family0,
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
    o.weapon_family0,
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

revoke all on function public.get_settlement_blacksmith_affixes(uuid,smallint) from public, anon;
grant execute on function public.get_settlement_blacksmith_affixes(uuid,smallint) to authenticated;
