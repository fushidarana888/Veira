CREATE OR REPLACE FUNCTION private.character_religion_modifiers(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
with state as (
  select cr.current_religion_slug religion_slug,
         private.religion_level(coalesce(cp.faith_points,0)) religion_level
  from public.character_religions cr
  left join public.character_religion_progress cp
    on cp.character_id=cr.character_id and cp.religion_slug=cr.current_religion_slug
  where cr.character_id=p_character_id and cr.current_religion_slug is not null
), perks as (
  select p.modifiers
  from state s join public.religion_level_perks p
    on p.religion_slug=s.religion_slug and p.level<=s.religion_level
)
select jsonb_build_object(
  'strength',coalesce(sum(case when jsonb_typeof(modifiers->'strength')='number' then (modifiers->>'strength')::int else 0 end),0),
  'agility',coalesce(sum(case when jsonb_typeof(modifiers->'agility')='number' then (modifiers->>'agility')::int else 0 end),0),
  'intellect',coalesce(sum(case when jsonb_typeof(modifiers->'intellect')='number' then (modifiers->>'intellect')::int else 0 end),0),
  'vitality',coalesce(sum(case when jsonb_typeof(modifiers->'vitality')='number' then (modifiers->>'vitality')::int else 0 end),0),
  'luck',coalesce(sum(case when jsonb_typeof(modifiers->'luck')='number' then (modifiers->>'luck')::int else 0 end),0),
  'lifesteal',coalesce(sum(case when jsonb_typeof(modifiers->'lifesteal')='number' then (modifiers->>'lifesteal')::int else 0 end),0),
  'mana_on_hit',coalesce(sum(case when jsonb_typeof(modifiers->'mana_on_hit')='number' then (modifiers->>'mana_on_hit')::int else 0 end),0),
  'guard_boost',coalesce(sum(case when jsonb_typeof(modifiers->'guard_boost')='number' then (modifiers->>'guard_boost')::int else 0 end),0),
  'evasion_chance',coalesce(sum(case when jsonb_typeof(modifiers->'evasion_chance')='number' then (modifiers->>'evasion_chance')::int else 0 end),0),
  'healing_spell_bonus',coalesce(sum(case when jsonb_typeof(modifiers->'healing_spell_bonus')='number' then (modifiers->>'healing_spell_bonus')::int else 0 end),0),
  'shield_spell_bonus',coalesce(sum(case when jsonb_typeof(modifiers->'shield_spell_bonus')='number' then (modifiers->>'shield_spell_bonus')::int else 0 end),0),
  'low_hp_50_damage_reduction',coalesce(sum(case when jsonb_typeof(modifiers->'low_hp_50_damage_reduction')='number' then (modifiers->>'low_hp_50_damage_reduction')::int else 0 end),0),
  'exploration_speed_percent',coalesce(sum(case when jsonb_typeof(modifiers->'exploration_speed_percent')='number' then (modifiers->>'exploration_speed_percent')::int else 0 end),0),
  'all_damage_bonus',coalesce(sum(case when jsonb_typeof(modifiers->'all_damage_bonus')='number' then (modifiers->>'all_damage_bonus')::int else 0 end),0),
  'physical_damage_bonus',coalesce(sum(case when jsonb_typeof(modifiers->'physical_damage_bonus')='number' then (modifiers->>'physical_damage_bonus')::int else 0 end),0),
  'magic_damage_bonus',coalesce(sum(case when jsonb_typeof(modifiers->'magic_damage_bonus')='number' then (modifiers->>'magic_damage_bonus')::int else 0 end),0),
  'low_hp_damage_reduction',coalesce(sum(case when jsonb_typeof(modifiers->'low_hp_damage_reduction')='number' then (modifiers->>'low_hp_damage_reduction')::int else 0 end),0),
  'boss_damage_bonus',coalesce(sum(case when jsonb_typeof(modifiers->'boss_damage_bonus')='number' then (modifiers->>'boss_damage_bonus')::int else 0 end),0),
  'resistances',jsonb_build_object(
    'slashing',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'slashing')='number' then (modifiers->'resistances'->>'slashing')::int else 0 end),0),
    'piercing',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'piercing')='number' then (modifiers->'resistances'->>'piercing')::int else 0 end),0),
    'blunt',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'blunt')='number' then (modifiers->'resistances'->>'blunt')::int else 0 end),0),
    'fire',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'fire')='number' then (modifiers->'resistances'->>'fire')::int else 0 end),0),
    'water',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'water')='number' then (modifiers->'resistances'->>'water')::int else 0 end),0),
    'earth',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'earth')='number' then (modifiers->'resistances'->>'earth')::int else 0 end),0),
    'air',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'air')='number' then (modifiers->'resistances'->>'air')::int else 0 end),0),
    'lightning',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'lightning')='number' then (modifiers->'resistances'->>'lightning')::int else 0 end),0),
    'ice',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'ice')='number' then (modifiers->'resistances'->>'ice')::int else 0 end),0),
    'arcane',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'arcane')='number' then (modifiers->'resistances'->>'arcane')::int else 0 end),0),
    'star',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'star')='number' then (modifiers->'resistances'->>'star')::int else 0 end),0),
    'gravity',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'gravity')='number' then (modifiers->'resistances'->>'gravity')::int else 0 end),0),
    'moon',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'moon')='number' then (modifiers->'resistances'->>'moon')::int else 0 end),0)
  )
) from perks;
$function$;

CREATE OR REPLACE FUNCTION private.character_accessory_exploration_speed_percent(p_character_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  select coalesce(sum(
    case
      when jsonb_typeof(d.stat_modifiers->'exploration_speed_percent')='number'
        then (d.stat_modifiers->>'exploration_speed_percent')::numeric::integer
      else 0
    end
    + case
      when jsonb_typeof(ci.metadata->'affix_stat_modifiers'->'exploration_speed_percent')='number'
        then (ci.metadata->'affix_stat_modifiers'->>'exploration_speed_percent')::numeric::integer
      else 0
    end
    + case
      when jsonb_typeof(ci.metadata->'religion_stat_modifiers'->'exploration_speed_percent')='number'
        then (ci.metadata->'religion_stat_modifiers'->>'exploration_speed_percent')::numeric::integer
      else 0
    end
  ),0)::integer
  from public.character_equipment ce
  join public.character_items ci on ci.id=ce.character_item_id
  join public.item_definitions d on d.id=ci.item_definition_id
  where ce.character_id=p_character_id
    and ce.slot in ('accessory_1','accessory_2')
    and d.category='accessory';
$function$;

CREATE OR REPLACE FUNCTION private.character_exploration_speed_percent(p_character_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  select greatest(
    -75,
    least(
      300,
      private.character_religion_modifier_number(p_character_id,'exploration_speed_percent')
      + private.character_accessory_exploration_speed_percent(p_character_id)
    )
  );
$function$;

CREATE OR REPLACE FUNCTION private.exploration_duration_seconds(p_base_seconds integer, p_speed_percent integer)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog'
AS $function$
  select greatest(
    60,
    ceil(
      greatest(60,p_base_seconds)::numeric
      *100.0
      /greatest(25,100+greatest(-75,least(300,p_speed_percent)))
    )::integer
  );
$function$;

CREATE OR REPLACE FUNCTION private.character_exploration_duration_seconds(p_character_id uuid, p_base_seconds integer)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  select private.exploration_duration_seconds(
    p_base_seconds,
    private.character_exploration_speed_percent(p_character_id)
  );
$function$;

CREATE OR REPLACE FUNCTION public.get_character_exploration_speed(p_character_id uuid)
 RETURNS TABLE(speed_percent integer, religion_percent integer, accessory_percent integer, sector_seconds integer, ruins_seconds integer, dungeon_scout_seconds integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists(
    select 1
    from public.characters c
    where c.id=p_character_id
      and (c.owner_user_id=auth.uid() or private.is_gm(auth.uid()))
  ) then
    raise exception 'CHARACTER_NOT_OWNED';
  end if;

  speed_percent:=private.character_exploration_speed_percent(p_character_id);
  religion_percent:=private.character_religion_modifier_number(
    p_character_id,
    'exploration_speed_percent'
  );
  accessory_percent:=private.character_accessory_exploration_speed_percent(p_character_id);
  sector_seconds:=private.exploration_duration_seconds(14400,speed_percent);
  ruins_seconds:=private.exploration_duration_seconds(7200,speed_percent);
  dungeon_scout_seconds:=private.exploration_duration_seconds(3600,speed_percent);

  return next;
end;
$function$;

CREATE OR REPLACE FUNCTION private.start_sector_exploration(p_character_id uuid, p_sector_id smallint)
 RETURNS sector_expeditions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid := auth.uid();
  target public.map_sectors;
  expedition public.sector_expeditions;
  duration_seconds integer;
begin
  if caller_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.characters c
    where c.id = p_character_id
      and c.owner_user_id = caller_id
  ) then
    raise exception 'CHARACTER_NOT_OWNED';
  end if;

  perform private.complete_expired_sector_expeditions(p_character_id);
  perform private.complete_expired_site_actions(p_character_id);

  select *
    into target
  from public.map_sectors s
  where s.id = p_sector_id;

  if target.id is null then
    raise exception 'SECTOR_NOT_FOUND';
  end if;

  if exists (
    select 1
    from public.character_sector_discoveries d
    where d.character_id = p_character_id
      and d.sector_id = p_sector_id
  ) then
    raise exception 'SECTOR_ALREADY_DISCOVERED';
  end if;

  if exists (
    select 1
    from public.sector_expeditions e
    where e.character_id = p_character_id
      and e.status in ('active','awaiting_event')
  ) then
    raise exception 'EXPEDITION_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.sector_site_actions a
    where a.character_id = p_character_id
      and a.status = 'active'
  ) then
    raise exception 'SITE_ACTION_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.dungeon_runs r
    where r.character_id = p_character_id
      and r.status = 'active'
  ) then
    raise exception 'DUNGEON_RUN_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.combat_encounters ce
    where ce.character_id = p_character_id
      and ce.status = 'active'
  ) then
    raise exception 'COMBAT_ALREADY_ACTIVE';
  end if;

  if not exists (
    select 1
    from public.character_sector_discoveries d
    join public.map_sectors known on known.id = d.sector_id
    where d.character_id = p_character_id
      and abs(known.grid_col - target.grid_col) <= 1
      and abs(known.grid_row - target.grid_row) <= 1
      and not (
        known.grid_col = target.grid_col
        and known.grid_row = target.grid_row
      )
  ) then
    raise exception 'SECTOR_NOT_ADJACENT_TO_DISCOVERED';
  end if;

  duration_seconds:=private.character_exploration_duration_seconds(p_character_id,14400);

  insert into public.sector_expeditions (
    character_id,
    sector_id,
    ends_at
  )
  values (
    p_character_id,
    p_sector_id,
    now() + make_interval(secs=>duration_seconds)
  )
  returning * into expedition;

  return expedition;
end;
$function$;

CREATE OR REPLACE FUNCTION public.start_sector_site_action(p_character_id uuid, p_sector_id smallint, p_action_type text)
 RETURNS sector_site_actions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid := auth.uid();
  sd public.sector_details;
  created_action public.sector_site_actions;
  base_duration_seconds integer;
  effective_duration_seconds integer;
begin
  if caller_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.characters c
    where c.id = p_character_id
      and c.owner_user_id = caller_id
  ) then
    raise exception 'CHARACTER_NOT_OWNED';
  end if;

  perform private.complete_expired_sector_expeditions(p_character_id);
  perform private.complete_expired_site_actions(p_character_id);

  if not exists (
    select 1
    from public.character_sector_discoveries d
    where d.character_id = p_character_id
      and d.sector_id = p_sector_id
  ) then
    raise exception 'SECTOR_NOT_DISCOVERED';
  end if;

  select *
    into sd
  from public.sector_details
  where sector_id = p_sector_id;

  if sd.sector_id is null then
    raise exception 'SECTOR_DETAILS_NOT_FOUND';
  end if;

  if p_action_type = 'explore_ruins' then
    if sd.content_type <> 'ruins' then
      raise exception 'SECTOR_IS_NOT_RUINS';
    end if;
    base_duration_seconds := 7200;

    if exists (
      select 1
      from public.character_sector_site_progress p
      where p.character_id = p_character_id
        and p.sector_id = p_sector_id
        and p.status in ('explored','cleared')
    ) then
      raise exception 'RUINS_ALREADY_EXPLORED';
    end if;
  elsif p_action_type = 'scout_dungeon' then
    if sd.content_type <> 'dungeon' then
      raise exception 'SECTOR_IS_NOT_DUNGEON';
    end if;
    base_duration_seconds := 3600;

    if exists (
      select 1
      from public.character_sector_site_progress p
      where p.character_id = p_character_id
        and p.sector_id = p_sector_id
        and p.status in ('scouted','cleared')
    ) then
      raise exception 'DUNGEON_ALREADY_SCOUTED';
    end if;
  else
    raise exception 'INVALID_SITE_ACTION';
  end if;

  if exists (
    select 1
    from public.sector_expeditions e
    where e.character_id = p_character_id
      and e.status in ('active','awaiting_event')
  ) then
    raise exception 'EXPEDITION_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.sector_site_actions a
    where a.character_id = p_character_id
      and a.status = 'active'
  ) then
    raise exception 'SITE_ACTION_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.dungeon_runs r
    where r.character_id = p_character_id
      and r.status = 'active'
  ) then
    raise exception 'DUNGEON_RUN_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.combat_encounters ce
    where ce.character_id = p_character_id
      and ce.status = 'active'
  ) then
    raise exception 'COMBAT_ALREADY_ACTIVE';
  end if;

  effective_duration_seconds:=private.character_exploration_duration_seconds(
    p_character_id,
    base_duration_seconds
  );

  insert into public.sector_site_actions (
    character_id,
    sector_id,
    action_type,
    ends_at
  )
  values (
    p_character_id,
    p_sector_id,
    p_action_type,
    now() + make_interval(secs=>effective_duration_seconds)
  )
  returning * into created_action;

  return created_action;
end;
$function$;


revoke all on function private.character_accessory_exploration_speed_percent(uuid) from public, anon, authenticated;
revoke all on function private.character_exploration_speed_percent(uuid) from public, anon, authenticated;
revoke all on function private.exploration_duration_seconds(integer,integer) from public, anon, authenticated;
revoke all on function private.character_exploration_duration_seconds(uuid,integer) from public, anon, authenticated;
revoke all on function public.get_character_exploration_speed(uuid) from public, anon;
grant execute on function public.get_character_exploration_speed(uuid) to authenticated;
