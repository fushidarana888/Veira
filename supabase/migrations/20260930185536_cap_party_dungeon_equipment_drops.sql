-- Apply the same per-character equipment cap to party dungeon loot.
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
  item_def public.item_definitions;
  qty integer;
  drops_count integer:=0;
  equipment_cap integer:=0;
  equipment_drops integer:=0;
  is_equipment boolean:=false;
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

  equipment_cap:=private.dungeon_equipment_drop_cap(sd.danger_level);

  for member_row in
    select *
    from public.party_dungeon_run_members
    where run_id=run_row.id
    order by joined_order
  loop
    select count(*)::integer into equipment_drops
    from public.party_loot_drops ld
    join public.item_definitions d on d.id=ld.item_definition_id
    where ld.run_id=run_row.id
      and ld.character_id=member_row.character_id
      and d.category::text in ('weapon','armor','accessory');

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
        (l.source_type='boss') desc,
        (l.enemy_template_id is not null) desc,
        coalesce((
          select private.item_rarity_rank(i.rarity)
          from public.item_definitions i
          where i.id=l.item_definition_id
        ),0) desc,
        (l.terrain_type is not null) desc,
        l.created_at
    loop
      select * into item_def
      from public.item_definitions
      where id=entry.item_definition_id;

      is_equipment:=item_def.category::text in ('weapon','armor','accessory');

      if is_equipment and equipment_drops>=equipment_cap then
        continue;
      end if;

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

        if is_equipment then
          equipment_drops:=equipment_drops+1;
        end if;

        drops_count:=drops_count+1;
      end if;
    end loop;
  end loop;

  update public.party_combat_encounters
  set loot_rolled=true
  where id=encounter.id;

  return drops_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.roll_party_dungeon_completion_loot(p_run_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  run_row public.party_dungeon_runs;
  sd public.sector_details;
  member_row public.party_dungeon_run_members;
  entry public.loot_pool_entries;
  item_def public.item_definitions;
  qty integer;
  drops_count integer:=0;
  favor_reroll_available boolean:=false;
  drop_success boolean:=false;
  equipment_cap integer:=0;
  equipment_drops integer:=0;
  is_equipment boolean:=false;
begin
  select * into run_row
  from public.party_dungeon_runs
  where id=p_run_id
  for update;

  if run_row.id is null then raise exception 'PARTY_DUNGEON_RUN_NOT_FOUND'; end if;
  if run_row.loot_rolled then return 0; end if;
  if run_row.status<>'completed' then raise exception 'PARTY_DUNGEON_NOT_COMPLETED'; end if;

  select * into sd
  from public.sector_details
  where sector_id=run_row.sector_id;

  equipment_cap:=private.dungeon_equipment_drop_cap(sd.danger_level);

  for member_row in
    select *
    from public.party_dungeon_run_members
    where run_id=run_row.id
    order by joined_order
  loop
    select count(*)::integer into equipment_drops
    from public.party_loot_drops ld
    join public.item_definitions d on d.id=ld.item_definition_id
    where ld.run_id=run_row.id
      and ld.character_id=member_row.character_id
      and d.category::text in ('weapon','armor','accessory');

    favor_reroll_available:=
      not coalesce(member_row.reward_exhausted,false)
      and private.character_current_favor(member_row.character_id)>=100;

    for entry in
      select l.*
      from public.loot_pool_entries l
      where l.enabled=true
        and l.source_type='dungeon'
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
        and (l.sector_id is null or l.sector_id=run_row.sector_id)
        and (l.terrain_type is null or l.terrain_type=sd.terrain_type)
      order by
        coalesce((
          select private.item_rarity_rank(i.rarity)
          from public.item_definitions i
          where i.id=l.item_definition_id
        ),0) desc,
        (l.sector_id is not null) desc,
        (l.terrain_type is not null) desc,
        l.created_at
    loop
      select * into item_def
      from public.item_definitions
      where id=entry.item_definition_id;

      is_equipment:=item_def.category::text in ('weapon','armor','accessory');

      if is_equipment and equipment_drops>=equipment_cap then
        continue;
      end if;

      drop_success:=false;

      if not coalesce(member_row.reward_exhausted,false)
         and private.character_can_receive_loot_item(member_row.character_id,entry.item_definition_id)
      then
        drop_success:=private.roll_dungeon_quality_loot(
          member_row.character_id,
          entry.item_definition_id,
          entry.chance_percent
        );

        if not drop_success
           and favor_reroll_available
           and private.is_quality_dungeon_gear(entry.item_definition_id)
        then
          favor_reroll_available:=false;
          drop_success:=private.roll_dungeon_quality_loot(
            member_row.character_id,
            entry.item_definition_id,
            entry.chance_percent
          );
        end if;
      end if;

      if drop_success then
        qty:=entry.min_quantity
          + floor(random()*(entry.max_quantity-entry.min_quantity+1))::integer;

        perform private.grant_character_item(
          member_row.character_id,
          entry.item_definition_id,
          qty,
          jsonb_build_object(
            'source','dungeon_completion',
            'party_dungeon_run_id',run_row.id,
            'sector_id',run_row.sector_id
          )
        );

        insert into public.party_loot_drops(
          character_id,run_id,encounter_id,source_type,item_definition_id,quantity
        )
        values(
          member_row.character_id,run_row.id,null,'dungeon',
          entry.item_definition_id,qty
        );

        if is_equipment then
          equipment_drops:=equipment_drops+1;
        end if;

        drops_count:=drops_count+1;
      end if;
    end loop;
  end loop;

  update public.party_dungeon_runs
  set loot_rolled=true
  where id=run_row.id;

  return drops_count;
end;
$function$
;

revoke all on function private.roll_party_combat_loot(uuid) from public,anon,authenticated;
revoke all on function private.roll_party_dungeon_completion_loot(uuid) from public,anon,authenticated;
