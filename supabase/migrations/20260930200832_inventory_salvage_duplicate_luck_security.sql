
-- Inventory quality-of-life, salvage economy, duplicate-drop protection,
-- Luck feedback, and RPC/table access hardening.

insert into public.item_definitions(
  slug,name,description,category,rarity,stackable,max_stack,base_value,required_level,shop_enabled
)
values(
  'smithing_scrap_beta',
  'Кузнечный лом',
  'Металл, кожа и крепёж, снятые с ненужной экипировки. При заточке оружия кузнец автоматически тратит до 1 лома на ступень и снижает золотую цену этой ступени на 15%.',
  'material','common',true,999,0,1,false
)
on conflict(slug) do update set
  name=excluded.name,
  description=excluded.description,
  stackable=true,
  max_stack=999,
  shop_enabled=false,
  updated_at=now();

CREATE OR REPLACE FUNCTION private.character_smithing_scrap_count(p_character_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  select coalesce(sum(ci.quantity),0)::integer
  from public.character_items ci
  join public.item_definitions d on d.id=ci.item_definition_id
  where ci.character_id=p_character_id
    and d.slug='smithing_scrap_beta'
    and ci.death_spirit_id is null;
$function$
;

CREATE OR REPLACE FUNCTION private.dismantle_inventory_item_internal(p_character_item_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
  ci public.character_items;
  def public.item_definitions;
  scrap_def public.item_definitions;
  affix_count integer:=0;
  scrap_qty integer:=0;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  select ci0.* into ci
  from public.character_items ci0
  join public.characters c on c.id=ci0.character_id
  where ci0.id=p_character_item_id
    and c.owner_user_id=caller
    and ci0.death_spirit_id is null
  for update of ci0;

  if ci.id is null then raise exception 'ITEM_NOT_AVAILABLE'; end if;

  if exists(select 1 from public.combat_encounters ce where ce.character_id=ci.character_id and ce.status='active')
     or private.character_in_active_party_combat(ci.character_id)
  then raise exception 'COMBAT_ACTIVE'; end if;

  select * into def from public.item_definitions where id=ci.item_definition_id;
  if def.id is null or def.category::text not in ('weapon','armor','accessory') then
    raise exception 'ITEM_IS_NOT_DISMANTLABLE';
  end if;

  if def.rarity::text='unique'
     or def.slug like 'ancient_%'
     or def.religion_origin_slug is not null
  then raise exception 'PROTECTED_ITEM'; end if;

  if coalesce((ci.metadata->>'inventory_locked')::boolean,false) then
    raise exception 'ITEM_LOCKED';
  end if;

  if exists(select 1 from public.character_equipment ce where ce.character_item_id=ci.id) then
    raise exception 'ITEM_IS_EQUIPPED';
  end if;

  affix_count:=case
    when jsonb_typeof(ci.metadata->'affixes')='array'
      then jsonb_array_length(ci.metadata->'affixes')
    else 0
  end;

  scrap_qty:=case def.rarity::text
    when 'common' then 1
    when 'uncommon' then 2
    when 'rare' then 4
    when 'epic' then 7
    when 'legendary' then 12
    else 1
  end + least(3,affix_count);

  select * into scrap_def from public.item_definitions where slug='smithing_scrap_beta';
  if scrap_def.id is null then raise exception 'SCRAP_ITEM_NOT_FOUND'; end if;

  perform set_config('veira.item_delete_reason','dismantled',true);
  delete from public.character_items where id=ci.id;
  perform set_config('veira.item_delete_reason','',true);

  perform private.grant_character_item(
    ci.character_id,
    scrap_def.id,
    scrap_qty,
    jsonb_build_object('source','dismantle','dismantled_item_slug',def.slug)
  );

  return scrap_qty;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.dungeon_duplicate_loot_multiplier(p_character_id uuid, p_item_definition_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  def public.item_definitions;
  owned_count integer:=0;
begin
  select * into def from public.item_definitions where id=p_item_definition_id;
  if def.id is null or def.category::text not in ('weapon','armor','accessory') then
    return 1.0;
  end if;

  if def.rarity::text in ('epic','legendary','unique') then
    return 1.0;
  end if;

  select count(*)::integer into owned_count
  from public.character_items ci
  where ci.character_id=p_character_id
    and ci.item_definition_id=p_item_definition_id
    and ci.death_spirit_id is null;

  if owned_count<=0 then return 1.0; end if;

  if def.rarity::text='common' then
    return case
      when owned_count=1 then 0.55
      when owned_count=2 then 0.40
      else 0.30
    end;
  elsif def.rarity::text='uncommon' then
    return case
      when owned_count=1 then 0.70
      when owned_count=2 then 0.55
      else 0.45
    end;
  elsif def.rarity::text='rare' then
    return case when owned_count=1 then 0.90 else 0.80 end;
  end if;

  return 1.0;
end;
$function$
;

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

  if def.slug in ('tempering_mark_iii','ancient_relic_fragment_beta')
     or def.slug like 'ancient_%_damaged'
     or def.religion_origin_slug is not null then
    raise exception 'PROTECTED_ITEM';
  end if;

  if coalesce((ci.metadata->>'inventory_locked')::boolean,false) then
    raise exception 'ITEM_LOCKED';
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
;

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
  item_def public.item_definitions;
  qty integer;
  drops_count integer:=0;
  equipment_cap integer:=2147483647;
  equipment_drops integer:=0;
  is_equipment boolean:=false;
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

  if encounter.dungeon_run_id is not null then
    equipment_cap:=private.dungeon_equipment_drop_cap(sd.danger_level);

    select count(*)::integer into equipment_drops
    from public.loot_drops ld
    join public.item_definitions d on d.id=ld.item_definition_id
    where ld.dungeon_run_id=encounter.dungeon_run_id
      and d.category::text in ('weapon','armor','accessory');
  end if;

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

    if private.character_can_receive_loot_item(encounter.character_id,entry.item_definition_id)
       and private.roll_dungeon_quality_loot(
         encounter.character_id,
         entry.item_definition_id,
         (entry.chance_percent * case
           when entry.enemy_template_id is not null then 1.0
           else private.dungeon_duplicate_loot_multiplier(encounter.character_id,entry.item_definition_id)
         end)
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

      if is_equipment then
        equipment_drops:=equipment_drops+1;
      end if;

      drops_count:=drops_count+1;
    end if;
  end loop;

  update public.combat_encounters
  set loot_rolled=true
  where id=encounter.id;

  return drops_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.roll_dungeon_completion_loot(p_run_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  run_row public.dungeon_runs;
  sd public.sector_details;
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
  from public.dungeon_runs
  where id=p_run_id
  for update;

  if run_row.id is null then raise exception 'DUNGEON_RUN_NOT_FOUND'; end if;
  if run_row.loot_rolled then return 0; end if;
  if run_row.status<>'completed' then raise exception 'DUNGEON_NOT_COMPLETED'; end if;

  if coalesce(run_row.reward_exhausted,false) then
    update public.dungeon_runs set loot_rolled=true where id=run_row.id;
    return 0;
  end if;

  select * into sd
  from public.sector_details
  where sector_id=run_row.sector_id;

  equipment_cap:=private.dungeon_equipment_drop_cap(sd.danger_level);

  select count(*)::integer into equipment_drops
  from public.loot_drops ld
  join public.item_definitions d on d.id=ld.item_definition_id
  where ld.dungeon_run_id=run_row.id
    and d.category::text in ('weapon','armor','accessory');

  favor_reroll_available:=private.character_current_favor(run_row.character_id)>=100;

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

    if private.character_can_receive_loot_item(run_row.character_id,entry.item_definition_id) then
      drop_success:=private.roll_dungeon_quality_loot(
        run_row.character_id,
        entry.item_definition_id,
        (entry.chance_percent * private.dungeon_duplicate_loot_multiplier(run_row.character_id,entry.item_definition_id))
      );

      if not drop_success
         and favor_reroll_available
         and private.is_quality_dungeon_gear(entry.item_definition_id)
      then
        favor_reroll_available:=false;
        drop_success:=private.roll_dungeon_quality_loot(
          run_row.character_id,
          entry.item_definition_id,
          (entry.chance_percent * private.dungeon_duplicate_loot_multiplier(run_row.character_id,entry.item_definition_id))
        );
      end if;
    end if;

    if drop_success then
      qty:=entry.min_quantity
        + floor(random()*(entry.max_quantity-entry.min_quantity+1))::integer;

      perform private.grant_character_item(
        run_row.character_id,
        entry.item_definition_id,
        qty,
        jsonb_build_object(
          'source','dungeon_completion',
          'dungeon_run_id',run_row.id,
          'sector_id',run_row.sector_id
        )
      );

      insert into public.loot_drops(
        character_id,dungeon_run_id,combat_encounter_id,source_type,
        item_definition_id,quantity
      )
      values(
        run_row.character_id,run_row.id,null,'dungeon',
        entry.item_definition_id,qty
      );

      if is_equipment then
        equipment_drops:=equipment_drops+1;
      end if;

      drops_count:=drops_count+1;
    end if;
  end loop;

  update public.dungeon_runs
  set loot_rolled=true
  where id=run_row.id;

  return drops_count;
end;
$function$
;

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
           (entry.chance_percent * case
             when entry.enemy_template_id is not null then 1.0
             else private.dungeon_duplicate_loot_multiplier(member_row.character_id,entry.item_definition_id)
           end)
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
          (entry.chance_percent * private.dungeon_duplicate_loot_multiplier(member_row.character_id,entry.item_definition_id))
        );

        if not drop_success
           and favor_reroll_available
           and private.is_quality_dungeon_gear(entry.item_definition_id)
        then
          favor_reroll_available:=false;
          drop_success:=private.roll_dungeon_quality_loot(
            member_row.character_id,
            entry.item_definition_id,
            (entry.chance_percent * private.dungeon_duplicate_loot_multiplier(member_row.character_id,entry.item_definition_id))
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

CREATE OR REPLACE FUNCTION public.set_inventory_item_locked(p_character_item_id uuid, p_locked boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
  ci public.character_items;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  select ci0.* into ci
  from public.character_items ci0
  join public.characters c on c.id=ci0.character_id
  where ci0.id=p_character_item_id
    and c.owner_user_id=caller
    and ci0.death_spirit_id is null
  for update of ci0;

  if ci.id is null then raise exception 'ITEM_NOT_AVAILABLE'; end if;

  update public.character_items
  set metadata=case
    when coalesce(p_locked,false)
      then coalesce(metadata,'{}'::jsonb)||jsonb_build_object('inventory_locked',true)
    else coalesce(metadata,'{}'::jsonb)-'inventory_locked'
  end
  where id=ci.id;

  return jsonb_build_object(
    'item_id',ci.id,
    'locked',coalesce(p_locked,false)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.dismantle_inventory_item(p_character_item_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  qty integer;
begin
  qty:=private.dismantle_inventory_item_internal(p_character_item_id);
  return jsonb_build_object('items_dismantled',1,'scrap_received',qty);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.bulk_dismantle_inventory_items(p_character_item_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  item_id uuid;
  total_items integer:=0;
  total_scrap integer:=0;
  skipped integer:=0;
  got integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;

  foreach item_id in array coalesce(p_character_item_ids,'{}'::uuid[]) loop
    begin
      got:=private.dismantle_inventory_item_internal(item_id);
      total_items:=total_items+1;
      total_scrap:=total_scrap+got;
    exception
      when others then
        if sqlerrm in (
          'ITEM_NOT_AVAILABLE','ITEM_IS_NOT_DISMANTLABLE','PROTECTED_ITEM',
          'ITEM_LOCKED','ITEM_IS_EQUIPPED'
        ) then
          skipped:=skipped+1;
        else
          raise;
        end if;
    end;
  end loop;

  return jsonb_build_object(
    'items_dismantled',total_items,
    'scrap_received',total_scrap,
    'skipped',skipped
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.bulk_exchange_inventory_items(p_character_item_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  item_id uuid;
  ci public.character_items;
  def public.item_definitions;
  row_result record;
  total_items integer:=0;
  total_gold bigint:=0;
  skipped integer:=0;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;

  foreach item_id in array coalesce(p_character_item_ids,'{}'::uuid[]) loop
    select ci0.* into ci
    from public.character_items ci0
    join public.characters c on c.id=ci0.character_id
    where ci0.id=item_id and c.owner_user_id=auth.uid() and ci0.death_spirit_id is null;

    if ci.id is null then
      skipped:=skipped+1;
      continue;
    end if;

    select * into def from public.item_definitions where id=ci.item_definition_id;
    if def.id is null
       or def.category::text not in ('weapon','armor','accessory')
       or def.rarity::text='unique'
       or def.slug like 'ancient_%'
       or def.religion_origin_slug is not null
       or coalesce((ci.metadata->>'inventory_locked')::boolean,false)
       or exists(select 1 from public.character_equipment ce where ce.character_item_id=ci.id)
    then
      skipped:=skipped+1;
      continue;
    end if;

    begin
      select * into row_result
      from private.exchange_inventory_item_internal(ci.id,1);
      total_items:=total_items+1;
      total_gold:=total_gold+coalesce(row_result.gold_received,0);
    exception
      when others then
        if sqlerrm in ('ITEM_NOT_AVAILABLE','PROTECTED_ITEM','ITEM_LOCKED','ITEM_IS_EQUIPPED') then
          skipped:=skipped+1;
        else
          raise;
        end if;
    end;
  end loop;

  return jsonb_build_object(
    'items_exchanged',total_items,
    'gold_received',total_gold,
    'skipped',skipped
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_party_dungeon_state(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid:=auth.uid();
  v_run_id uuid;
  v_encounter_id uuid;
  result jsonb;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id
      and c.owner_user_id=caller_id
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select pr.id into v_run_id
  from public.party_dungeon_runs pr
  join public.party_dungeon_run_members prm on prm.run_id=pr.id
  where prm.character_id=p_character_id
  order by (pr.status='active') desc,pr.created_at desc
  limit 1;

  if v_run_id is null then
    return jsonb_build_object(
      'run',null,
      'encounter',null,
      'members','[]'::jsonb,
      'statuses','[]'::jsonb,
      'turns','[]'::jsonb,
      'loot','[]'::jsonb,
      'sacrifice_scroll_count',coalesce((
        select sum(ci.quantity)::integer
        from public.character_items ci
        join public.item_definitions idf on idf.id=ci.item_definition_id
        where ci.character_id=p_character_id
          and idf.slug='combat_scroll_last_sacrifice'
      ),0)
    );
  end if;

  select ce.id into v_encounter_id
  from public.party_combat_encounters ce
  where ce.run_id=v_run_id
  order by (ce.status='active') desc,ce.room_index desc,ce.created_at desc
  limit 1;

  select jsonb_build_object(
    'sacrifice_scroll_count',coalesce((
      select sum(ci.quantity)::integer
      from public.character_items ci
      join public.item_definitions idf on idf.id=ci.item_definition_id
      where ci.character_id=p_character_id
        and idf.slug='combat_scroll_last_sacrifice'
    ),0),
    'run',(
      select jsonb_build_object(
        'id',pr.id,
        'party_id',pr.party_id,
        'leader_character_id',pr.leader_character_id,
        'sector_id',pr.sector_id,
        'title',coalesce((select ebe.name from public.event_boss_events ebe where ebe.id=pr.event_boss_id),coalesce(sd.title,'Подземелье')),
        'is_event_boss',pr.event_boss_id is not null,
        'event_boss_id',pr.event_boss_id,
        'event_boss',case when pr.event_boss_id is null then null else (
          select jsonb_build_object(
            'boss_kind',ebe.boss_kind,
            'name',ebe.name,
            'description',ebe.description,
            'recommended_level',ebe.recommended_level,
            'ends_at',ebe.ends_at,
            'special_every_n',ebe.special_every_n,
            'phase2_hp_percent',ebe.phase2_hp_percent,
            'special_name',coalesce(et.special_name,'Особый приём'),
            'phase2_name',coalesce(et.phase2_name,'Вторая фаза'),
            'reward_material_name',rm.name,
            'reward_material_quantity',ebe.reward_material_quantity,
            'first_reward_gold',ebe.first_reward_gold,
            'first_reward_experience',ebe.first_reward_experience,
            'repeat_reward_gold',ebe.repeat_reward_gold,
            'repeat_reward_experience',ebe.repeat_reward_experience
          )
          from public.event_boss_events ebe
          left join public.enemy_templates et on et.id=ebe.enemy_template_id
          left join public.item_definitions rm on rm.id=ebe.reward_material_item_id
          where ebe.id=pr.event_boss_id
        ) end,
        'danger_level',sd.danger_level,
        'modifier',case when pr.modifier_slug is null then null else (
          select jsonb_build_object(
            'slug',m.slug,
            'name',m.name,
            'description',m.description,
            'theme',m.theme,
            'enemy_hp_percent',m.enemy_hp_percent,
            'enemy_attack_percent',m.enemy_attack_percent,
            'enemy_defense_percent',m.enemy_defense_percent,
            'reward_gold_percent',m.reward_gold_percent,
            'reward_xp_percent',m.reward_xp_percent
          )
          from public.dungeon_modifier_definitions m
          where m.slug=pr.modifier_slug
        ) end,
        'status',pr.status,
        'current_stage',pr.current_stage,
        'rooms_cleared',pr.rooms_cleared,
        'total_rooms',pr.total_rooms,
        'reward_gold',pr.reward_gold,
        'reward_experience',pr.reward_experience,
        'member_count',pr.member_count,
        'escape_attempt_stage',pr.escape_attempt_stage,
        'started_at',pr.started_at,
        'sacrifice_scroll_used',pr.sacrifice_scroll_used
      )
      from public.party_dungeon_runs pr
      join public.sector_details sd on sd.sector_id=pr.sector_id
      where pr.id=v_run_id
    ),
    'encounter',case when v_encounter_id is null then null else (
      select jsonb_build_object(
        'id',ce.id,
        'room_index',ce.room_index,
        'is_boss',ce.is_boss,
        'is_rare_variant',exists(
          select 1 from public.enemy_templates et
          where et.id=ce.enemy_template_id and et.is_rare_variant
        ),
        'status',ce.status,
        'round',ce.round,
        'enemy_name',ce.enemy_name,
        'enemy_level',ce.enemy_level,
        'enemy_hp_current',ce.enemy_hp_current,
        'enemy_hp_max',ce.enemy_hp_max,
        'enemy_attack',ce.enemy_attack,
        'enemy_defense',ce.enemy_defense,
        'enemy_initiative',ce.enemy_initiative,
        'enemy_damage_type',ce.enemy_damage_type,
        'enemy_resistances',ce.enemy_resistances,
        'enemy_danger_pending',coalesce((ce.enemy_ai_state->>'danger_pending')::boolean,false),
        'enemy_bloodshed_stacks',ce.enemy_bloodshed_stacks,
        'acted_character_ids',to_jsonb(ce.acted_character_ids),
        'next_actor_character_id',private.party_next_actor_id(ce.id),
        'created_at',ce.created_at,
        'ended_at',ce.ended_at
      )
      from public.party_combat_encounters ce
      where ce.id=v_encounter_id
    ) end,
    'members',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'character_id',c.id,
          'name',c.name,
          'display_name',pf.display_name,
          'race',c.race,
          'level',cp.level,
          'initiative',combat_stats.initiative,
          'hp_current',case when prm.lost then 0 when prm.dead and ms.character_id is null then 1 else coalesce(ms.hp_current,cp.hp_current) end,
          'hp_max',coalesce(ms.hp_max,cp.hp_max),
          'mana_current',coalesce(ms.mana_current,cp.mana_current),
          'mana_max',coalesce(ms.mana_max,cp.mana_max),
          'downed',case when prm.lost then true else coalesce(ms.downed,prm.dead) end,
          'dead',prm.dead,
          'lost',prm.lost,
          'lost_reason',prm.lost_reason,
          'incoming_damage_reduction_percent',coalesce(ms.incoming_damage_reduction_percent,0),
          'incoming_damage_reduction_rounds',coalesce(ms.incoming_damage_reduction_rounds,0),
          'guard_percent',coalesce(ms.guard_percent,0),
          'reflect_percent',coalesce(ms.reflect_percent,0),
          'damage_bonus_percent',coalesce(ms.damage_bonus_percent,0),
          'damage_bonus_hits',coalesce(ms.damage_bonus_hits,0),
          'taunt_chance',coalesce(ms.taunt_chance,0),
          'bow_distance',coalesce(ms.bow_distance,'medium'),
          'bow_draw_pending',coalesce(ms.bow_draw_pending,false),
          'acted',case
            when ce.id is null then false
            else c.id=any(ce.acted_character_ids)
          end,
          'is_leader',(c.id=pr.leader_character_id),
          'joined_order',prm.joined_order,
          'initiative_meter',coalesce(ms.initiative_meter,0),
          'reward_exhausted',coalesce(prm.reward_exhausted,false),
          'reward_attempt_number',prm.reward_attempt_number,
          'reward_cycle_ends_at',prm.reward_cycle_ends_at
        )
        order by combat_stats.initiative desc, prm.joined_order
      )
      from public.party_dungeon_run_members prm
      join public.party_dungeon_runs pr on pr.id=prm.run_id
      join public.characters c on c.id=prm.character_id
      join public.profiles pf on pf.user_id=c.owner_user_id
      join public.character_progress cp on cp.character_id=c.id
      cross join lateral private.get_character_combat_stats(c.id) combat_stats
      left join public.party_combat_encounters ce on ce.id=v_encounter_id
      left join public.party_combat_member_states ms
        on ms.encounter_id=ce.id
       and ms.character_id=c.id
      where prm.run_id=v_run_id
    ),'[]'::jsonb),
    'statuses',case when v_encounter_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',se.id,
        'target_type',se.target_type,
        'target_character_id',se.target_character_id,
        'effect_type',se.effect_type,
        'potency',se.potency,
        'remaining_turns',se.remaining_turns,
        'source',se.source
      ) order by se.id)
      from public.party_combat_status_effects se
      where se.encounter_id=v_encounter_id
    ),'[]'::jsonb) end,
    'turns',case when v_encounter_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(to_jsonb(x) order by x.id desc)
      from (
        select
          t.id,t.round,t.actor_type,t.actor_character_id,t.target_character_id,
          t.action_type,t.damage,t.message,t.created_at
        from public.party_combat_turns t
        where t.encounter_id=v_encounter_id
        order by t.id desc
        limit 30
      ) x
    ),'[]'::jsonb) end,
    'loot',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',pl.id,
          'source_type',pl.source_type,
          'item_definition_id',pl.item_definition_id,
          'item_name',idf.name,
          'rarity',idf.rarity::text,
          'quantity',pl.quantity,
          'lucky_find',exists(
            select 1
            from public.character_items lucky_ci
            where lucky_ci.character_id=p_character_id
              and lucky_ci.item_definition_id=pl.item_definition_id
              and lucky_ci.metadata->>'party_dungeon_run_id'=v_run_id::text
              and coalesce((lucky_ci.metadata->>'lucky_affix_upgrade')::boolean,false)
          ),
          'created_at',pl.created_at
        )
        order by pl.created_at desc
      )
      from public.party_loot_drops pl
      join public.item_definitions idf on idf.id=pl.item_definition_id
      where pl.run_id=v_run_id
        and pl.character_id=p_character_id
    ),'[]'::jsonb)
  ) into result;

  return result;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.enhance_weapon_at_blacksmith_to_level(p_character_id uuid, p_sector_id smallint, p_character_item_id uuid, p_target_level integer)
 RETURNS TABLE(character_item_id uuid, old_enhancement_level smallint, new_enhancement_level smallint, gold_spent bigint, gold_remaining bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
  settlement public.sector_details;
  cp public.character_progress;
  ci public.character_items;
  item public.item_definitions;
  old_level smallint;
  max_level integer;
  cost bigint:=0;
  lvl integer;
  step_cost bigint:=0;
  scrap_def public.item_definitions;
  scrap_remaining integer:=0;
  scrap_used integer:=0;
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

  select * into ci from public.character_items x
  where x.id=p_character_item_id and x.character_id=p_character_id
  for update;
  if ci.id is null then raise exception 'ITEM_NOT_OWNED'; end if;

  select * into item from public.item_definitions d where d.id=ci.item_definition_id;
  if item.id is null or item.category::text<>'weapon'
    then raise exception 'ITEM_IS_NOT_WEAPON'; end if;

  old_level:=ci.enhancement_level;
  max_level:=least(20,private.blacksmith_max_enhancement(settlement.settlement_level));

  if p_target_level<=old_level then raise exception 'INVALID_TARGET_LEVEL'; end if;
  if p_target_level>max_level then raise exception 'BLACKSMITH_LEVEL_TOO_LOW'; end if;

  select * into scrap_def from public.item_definitions where slug='smithing_scrap_beta';
  if scrap_def.id is not null then
    scrap_remaining:=private.available_character_item_quantity(p_character_id,scrap_def.id);
  end if;

  for lvl in old_level+1..p_target_level loop
    step_cost:=private.weapon_enhancement_cost(item.base_value,item.rarity::text,lvl);
    if scrap_remaining>0 then
      step_cost:=ceil(step_cost*0.85)::bigint;
      scrap_remaining:=scrap_remaining-1;
      scrap_used:=scrap_used+1;
    end if;
    cost:=cost+step_cost;
  end loop;

  select * into cp from public.character_progress p
  where p.character_id=p_character_id for update;
  if cp.gold<cost then raise exception 'NOT_ENOUGH_GOLD'; end if;

  if scrap_used>0 then
    perform private.consume_character_item_definition(p_character_id,scrap_def.id,scrap_used);
  end if;

  update public.character_progress
  set gold=gold-cost,updated_at=now()
  where character_id=p_character_id;

  update public.character_items
  set enhancement_level=p_target_level
  where id=ci.id;

  return query select ci.id,old_level,p_target_level::smallint,cost,(cp.gold-cost)::bigint;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.quote_weapon_enhancement_at_blacksmith(p_character_id uuid, p_sector_id smallint, p_character_item_id uuid, p_target_level integer)
 RETURNS TABLE(current_level smallint, target_level smallint, total_cost bigint, current_gold bigint, can_afford boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
  settlement public.sector_details;
  ci public.character_items;
  item public.item_definitions;
  gold_now bigint:=0;
  max_level integer;
  cost bigint:=0;
  lvl integer;
  step_cost bigint:=0;
  scrap_def public.item_definitions;
  scrap_remaining integer:=0;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters c where c.id=p_character_id and c.owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;
  if not exists(select 1 from public.character_sector_discoveries d where d.character_id=p_character_id and d.sector_id=p_sector_id)
    then raise exception 'SETTLEMENT_NOT_DISCOVERED'; end if;

  select * into settlement from public.sector_details where sector_id=p_sector_id;
  if settlement.sector_id is null or settlement.content_type<>'settlement'
    then raise exception 'SECTOR_IS_NOT_SETTLEMENT'; end if;

  select * into ci from public.character_items x
  where x.id=p_character_item_id and x.character_id=p_character_id;
  if ci.id is null then raise exception 'ITEM_NOT_OWNED'; end if;

  select * into item from public.item_definitions d where d.id=ci.item_definition_id;
  if item.id is null or item.category::text<>'weapon'
    then raise exception 'ITEM_IS_NOT_WEAPON'; end if;

  max_level:=least(20,private.blacksmith_max_enhancement(settlement.settlement_level));
  if p_target_level<=ci.enhancement_level then raise exception 'INVALID_TARGET_LEVEL'; end if;
  if p_target_level>max_level then raise exception 'BLACKSMITH_LEVEL_TOO_LOW'; end if;

  select * into scrap_def from public.item_definitions where slug='smithing_scrap_beta';
  if scrap_def.id is not null then
    scrap_remaining:=private.available_character_item_quantity(p_character_id,scrap_def.id);
  end if;

  for lvl in ci.enhancement_level+1..p_target_level loop
    step_cost:=private.weapon_enhancement_cost(item.base_value,item.rarity::text,lvl);
    if scrap_remaining>0 then
      step_cost:=ceil(step_cost*0.85)::bigint;
      scrap_remaining:=scrap_remaining-1;
    end if;
    cost:=cost+step_cost;
  end loop;

  select cp.gold into gold_now from public.character_progress cp where cp.character_id=p_character_id;

  return query select ci.enhancement_level,p_target_level::smallint,cost,gold_now,gold_now>=cost;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_settlement_blacksmith_v2(p_character_id uuid, p_sector_id smallint)
 RETURNS TABLE(settlement_name text, settlement_level smallint, max_enhancement integer, affix_apply_unlocked boolean, affix_reroll_unlocked boolean, awakening_unlocked boolean, character_item_id uuid, item_definition_id uuid, item_name text, custom_name text, rarity text, weapon_family text, weapon_base_damage integer, enhancement_level smallint, enhanced_base_damage numeric, next_enhancement_level integer, next_cost bigint, can_enhance_here boolean, can_afford boolean, is_equipped boolean, awakening_level smallint, max_awakening integer, awakening_effect_text text, duplicate_count integer, duplicate_candidates jsonb, affix_slots integer, affix_count integer, affixes jsonb, next_affix_cost bigint, can_add_affix boolean, can_afford_affix boolean, affix_reroll_count integer, reroll_costs jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
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
      ci.*,
      d.name item_name0,
      d.rarity::text rarity0,
      d.weapon_family weapon_family0,
      d.weapon_base_damage weapon_base_damage0,
      d.base_value base_value0,
      d.unique_property_name unique_property_name0,
      d.unique_effect_type unique_effect_type0,
      d.unique_effect_value unique_effect_value0,
      d.echo_strike_chance_percent echo0,
      d.bloodshed_chance_percent bloodshed0,
      d.stat_modifiers stat_modifiers0,
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
      and d.category::text='weapon'
  )
  select
    coalesce(settlement.title,'Поселение')::text,
    settlement.settlement_level,
    private.blacksmith_max_enhancement(settlement.settlement_level),
    private.blacksmith_affix_apply_unlocked(settlement.settlement_level),
    private.blacksmith_affix_reroll_unlocked(settlement.settlement_level),
    private.blacksmith_awakening_unlocked(settlement.settlement_level),
    o.id,
    o.item_definition_id,
    o.item_name0,
    o.custom_name,
    o.rarity0,
    o.weapon_family0,
    o.weapon_base_damage0,
    o.enhancement_level,
    round(
      o.weapon_base_damage0
      * private.weapon_enhancement_multiplier(o.enhancement_level),
      2
    )::numeric,
    case when o.enhancement_level>=20 then null else o.enhancement_level+1 end,
    case when o.enhancement_level>=20 then null else
      case when private.character_smithing_scrap_count(p_character_id)>0
        then ceil(private.weapon_enhancement_cost(o.base_value0,o.rarity0,o.enhancement_level+1)*0.85)::bigint
        else private.weapon_enhancement_cost(o.base_value0,o.rarity0,o.enhancement_level+1)
      end
    end,
    o.enhancement_level
      < least(20,private.blacksmith_max_enhancement(settlement.settlement_level)),
    case when o.enhancement_level>=20 then false else
      current_gold>=case when private.character_smithing_scrap_count(p_character_id)>0
        then ceil(private.weapon_enhancement_cost(o.base_value0,o.rarity0,o.enhancement_level+1)*0.85)::bigint
        else private.weapon_enhancement_cost(o.base_value0,o.rarity0,o.enhancement_level+1)
      end
    end,
    exists(
      select 1 from public.character_equipment ce
      where ce.character_id=p_character_id
        and ce.character_item_id=o.id
        and ce.slot='weapon'
    ),
    o.awakening_level,
    5,
    case
      when o.echo0>0 then 'Эхо ударов: +1 п.п. шанса за ступень'
      when o.bloodshed0>0 then 'Кровопролитие: +1 п.п. шанса за ступень'
      when o.unique_effect_type0='lifesteal' then 'Вампиризм: +1 п.п. за ступень'
      when o.unique_effect_type0='damage_vs_wounded' then 'Урон по раненым: +1 п.п. за ступень'
      when o.unique_effect_type0='mana_on_hit' then 'Мана за удар: +1 за ступень'
      when o.unique_effect_type0='guard_boost' then 'Усиление блока: +1 п.п. за ступень'
      when jsonb_typeof(o.stat_modifiers0->'first_physical_strike_multiplier')='number'
        then 'Первый удар: бонусная часть ×+0.02 за ступень'
      else 'Физический урон оружием: +1% за ступень'
    end,
    (
      select count(*)::integer
      from public.character_items src
      where src.character_id=p_character_id
        and src.item_definition_id=o.item_definition_id
        and src.id<>o.id
        and not exists(
          select 1 from public.character_equipment ce
          where ce.character_item_id=src.id
        )
    ),
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',src.id,
          'custom_name',src.custom_name,
          'enhancement_level',src.enhancement_level,
          'awakening_level',src.awakening_level,
          'affix_count',case
            when jsonb_typeof(src.metadata->'affixes')='array'
            then jsonb_array_length(src.metadata->'affixes')
            else 0
          end
        )
        order by src.enhancement_level,src.awakening_level,src.acquired_at
      )
      from public.character_items src
      where src.character_id=p_character_id
        and src.item_definition_id=o.item_definition_id
        and src.id<>o.id
        and not exists(
          select 1 from public.character_equipment ce
          where ce.character_item_id=src.id
        )
    ),'[]'::jsonb),
    o.slots0,
    o.affix_count0,
    case when jsonb_typeof(o.metadata->'affixes')='array'
      then o.metadata->'affixes' else '[]'::jsonb end,
    case when o.affix_count0>=o.slots0 or o.slots0=0 then null else
      private.weapon_affix_apply_cost(
        o.base_value0,o.rarity0,o.affix_count0+1
      )
    end,
    private.blacksmith_affix_apply_unlocked(settlement.settlement_level)
      and o.slots0>0
      and o.affix_count0<o.slots0,
    private.blacksmith_affix_apply_unlocked(settlement.settlement_level)
      and o.slots0>0
      and o.affix_count0<o.slots0
      and current_gold>=private.weapon_affix_apply_cost(
        o.base_value0,o.rarity0,o.affix_count0+1
      ),
    o.rerolls0,
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'slot',x.ordinality,
          'affix_id',x.value->>'id',
          'cost',private.weapon_affix_reroll_cost(
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
        and ce.slot='weapon'
    ) desc,
    o.enhancement_level desc,
    o.awakening_level desc,
    o.item_name0,
    o.acquired_at;
end;
$function$
;

drop function if exists public.get_dungeon_run_loot(uuid);
CREATE OR REPLACE FUNCTION public.get_dungeon_run_loot(p_run_id uuid)
 RETURNS TABLE(drop_id uuid, source_type text, item_id uuid, item_name text, item_slug text, category text, rarity text, quantity integer, combat_encounter_id uuid, lucky_find boolean, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  if not private.is_gm(caller)
     and not exists(
       select 1
       from public.dungeon_runs r
       join public.characters c on c.id=r.character_id
       where r.id=p_run_id and c.owner_user_id=caller
     )
  then raise exception 'DUNGEON_RUN_NOT_OWNED'; end if;

  return query
  select
    ld.id,
    ld.source_type,
    d.id,
    d.name,
    d.slug,
    d.category::text,
    d.rarity::text,
    ld.quantity,
    ld.combat_encounter_id,
    exists(
      select 1
      from public.character_items ci
      join public.dungeon_runs r2 on r2.id=p_run_id
      where ci.character_id=r2.character_id
        and ci.item_definition_id=ld.item_definition_id
        and ci.metadata->>'dungeon_run_id'=p_run_id::text
        and coalesce((ci.metadata->>'lucky_affix_upgrade')::boolean,false)
    ),
    ld.created_at
  from public.loot_drops ld
  join public.item_definitions d on d.id=ld.item_definition_id
  where ld.dungeon_run_id=p_run_id
  order by ld.created_at,ld.id;
end;
$function$
;

revoke all on table
  public.character_discoveries,
  public.character_treasure_hunts,
  public.dungeon_event_definitions,
  public.dungeon_modifier_definitions,
  public.dungeon_run_events,
  public.wandering_merchant_catalog,
  public.wandering_merchant_purchases,
  public.world_rumors
from public,anon,authenticated;

revoke all on function public.set_updated_at() from public,anon,authenticated;

revoke all on function private.character_smithing_scrap_count(uuid) from public,anon,authenticated;
revoke all on function private.dungeon_duplicate_loot_multiplier(uuid,uuid) from public,anon,authenticated;
revoke all on function private.dismantle_inventory_item_internal(uuid) from public,anon,authenticated;
revoke all on function private.exchange_inventory_item_internal(uuid,integer) from public,anon,authenticated;
revoke all on function private.roll_combat_loot(uuid) from public,anon,authenticated;
revoke all on function private.roll_dungeon_completion_loot(uuid) from public,anon,authenticated;
revoke all on function private.roll_party_combat_loot(uuid) from public,anon,authenticated;
revoke all on function private.roll_party_dungeon_completion_loot(uuid) from public,anon,authenticated;

revoke all on function public.set_inventory_item_locked(uuid,boolean) from public,anon;
grant execute on function public.set_inventory_item_locked(uuid,boolean) to authenticated;
revoke all on function public.dismantle_inventory_item(uuid) from public,anon;
grant execute on function public.dismantle_inventory_item(uuid) to authenticated;
revoke all on function public.bulk_dismantle_inventory_items(uuid[]) from public,anon;
grant execute on function public.bulk_dismantle_inventory_items(uuid[]) to authenticated;
revoke all on function public.bulk_exchange_inventory_items(uuid[]) from public,anon;
grant execute on function public.bulk_exchange_inventory_items(uuid[]) to authenticated;
revoke all on function public.get_dungeon_run_loot(uuid) from public,anon;
grant execute on function public.get_dungeon_run_loot(uuid) to authenticated;
