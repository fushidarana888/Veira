create or replace function private.dungeon_duplicate_loot_multiplier(
  p_character_id uuid,
  p_item_definition_id uuid
)
returns numeric
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','private'
as $function$
declare
  def public.item_definitions;
  owned_count integer:=0;
begin
  select * into def
  from public.item_definitions
  where id=p_item_definition_id;

  if def.id is null
     or def.category::text not in ('weapon','armor','accessory')
  then
    return 1.0;
  end if;

  -- Антидубликатный штраф действует только на обычную экипировку.
  if def.rarity::text <> 'common' then
    return 1.0;
  end if;

  select count(*)::integer into owned_count
  from public.character_items ci
  where ci.character_id=p_character_id
    and ci.item_definition_id=p_item_definition_id
    and ci.death_spirit_id is null;

  if owned_count<=0 then
    return 1.0;
  end if;

  return case
    when owned_count=1 then 0.55
    when owned_count=2 then 0.40
    else 0.30
  end;
end;
$function$;
