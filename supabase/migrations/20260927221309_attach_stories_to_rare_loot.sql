-- Synced from live Supabase migration 20260927221309 (attach_stories_to_rare_loot)

CREATE OR REPLACE FUNCTION private.roll_combat_loot(p_encounter_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  encounter public.combat_encounters;
  sd public.sector_details;
  entry public.loot_pool_entries;
  qty integer;
  drops_count integer:=0;
begin
  select * into encounter
  from public.combat_encounters
  where id=p_encounter_id
  for update;

  if encounter.id is null then raise exception 'COMBAT_NOT_FOUND'; end if;
  if encounter.loot_rolled then return 0; end if;
  if encounter.status<>'victory' then raise exception 'COMBAT_NOT_VICTORY'; end if;

  if exists(
    select 1
    from public.dungeon_runs r
    where r.id=encounter.dungeon_run_id
      and coalesce(r.reward_exhausted,false)
  ) then
    update public.combat_encounters
    set loot_rolled=true
    where id=encounter.id;
    return 0;
  end if;

  select * into sd
  from public.sector_details
  where sector_id=encounter.sector_id;

  for entry in
    select l.*
    from public.loot_pool_entries l
    where l.enabled=true
      and (l.source_type='enemy' or (encounter.is_boss and l.source_type='boss'))
      and sd.danger_level between l.min_danger and l.max_danger
      and (
        sd.danger_level<>0
        or exists(
          select 1
          from public.item_definitions zero_item
          where zero_item.id=l.item_definition_id
            and zero_item.rarity='common'
            and zero_item.required_level<=1
        )
      )
      and (l.enemy_template_id is null or l.enemy_template_id=encounter.enemy_template_id)
      and (l.terrain_type is null or l.terrain_type=sd.terrain_type)
    order by
      (l.enemy_template_id is not null) desc,
      (l.terrain_type is not null) desc,
      l.created_at
  loop
    if private.character_can_receive_loot_item(encounter.character_id,entry.item_definition_id)
       and private.roll_dungeon_quality_loot(
         encounter.character_id,
         entry.item_definition_id,
         entry.chance_percent
       ) then
      qty:=entry.min_quantity
        + floor(random()*(entry.max_quantity-entry.min_quantity+1))::integer;

      perform private.grant_character_item(
        encounter.character_id,
        entry.item_definition_id,
        qty,
        jsonb_build_object(
          'source','loot',
          'dungeon_run_id',encounter.dungeon_run_id,
          'combat_encounter_id',encounter.id
        )
        || private.item_drop_story(
          entry.item_definition_id,
          encounter.enemy_name,
          encounter.sector_id
        )
      );

      insert into public.loot_drops(
        character_id,dungeon_run_id,combat_encounter_id,source_type,
        item_definition_id,quantity
      )
      values(
        encounter.character_id,encounter.dungeon_run_id,encounter.id,
        case when encounter.is_boss then 'boss' else 'enemy' end,
        entry.item_definition_id,qty
      );

      drops_count:=drops_count+1;
    end if;
  end loop;

  update public.combat_encounters
  set loot_rolled=true
  where id=encounter.id;

  return drops_count;
end;
$function$;

CREATE OR REPLACE FUNCTION private.roll_party_combat_loot(p_encounter_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  encounter public.party_combat_encounters;
  run_row public.party_dungeon_runs;
  sd public.sector_details;
  member_row public.party_dungeon_run_members;
  entry public.loot_pool_entries;
  qty integer;
  drops_count integer:=0;
begin
  select * into encounter
  from public.party_combat_encounters
  where id=p_encounter_id
  for update;

  if encounter.id is null then raise exception 'PARTY_COMBAT_NOT_FOUND'; end if;
  if encounter.loot_rolled then return 0; end if;
  if encounter.status<>'victory' then raise exception 'PARTY_COMBAT_NOT_VICTORY'; end if;

  select * into run_row
  from public.party_dungeon_runs
  where id=encounter.run_id;

  select * into sd
  from public.sector_details
  where sector_id=run_row.sector_id;

  for member_row in
    select *
    from public.party_dungeon_run_members
    where run_id=run_row.id
    order by joined_order
  loop
    for entry in
      select l.*
      from public.loot_pool_entries l
      where l.enabled=true
        and (l.source_type='enemy' or (encounter.is_boss and l.source_type='boss'))
        and sd.danger_level between l.min_danger and l.max_danger
      and (
        sd.danger_level<>0
        or exists(
          select 1
          from public.item_definitions zero_item
          where zero_item.id=l.item_definition_id
            and zero_item.rarity='common'
            and zero_item.required_level<=1
        )
      )
        and (l.enemy_template_id is null or l.enemy_template_id=encounter.enemy_template_id)
        and (l.terrain_type is null or l.terrain_type=sd.terrain_type)
      order by
        (l.enemy_template_id is not null) desc,
        (l.terrain_type is not null) desc,
        l.created_at
    loop
      if not coalesce(member_row.reward_exhausted,false)
         and private.character_can_receive_loot_item(member_row.character_id,entry.item_definition_id)
         and private.roll_dungeon_quality_loot(
           member_row.character_id,
           entry.item_definition_id,
           entry.chance_percent
         ) then
        qty:=entry.min_quantity
          + floor(random()*(entry.max_quantity-entry.min_quantity+1))::integer;

        perform private.grant_character_item(
          member_row.character_id,
          entry.item_definition_id,
          qty,
          jsonb_build_object(
            'source','loot',
            'party_dungeon_run_id',run_row.id,
            'party_combat_encounter_id',encounter.id
          )
          || private.item_drop_story(
            entry.item_definition_id,
            encounter.enemy_name,
            run_row.sector_id
          )
        );

        insert into public.party_loot_drops(
          character_id,run_id,encounter_id,source_type,item_definition_id,quantity
        )
        values(
          member_row.character_id,run_row.id,encounter.id,
          case when encounter.is_boss then 'boss' else 'enemy' end,
          entry.item_definition_id,qty
        );

        drops_count:=drops_count+1;
      end if;
    end loop;
  end loop;

  update public.party_combat_encounters
  set loot_rolled=true
  where id=encounter.id;

  return drops_count;
end;
$function$;
