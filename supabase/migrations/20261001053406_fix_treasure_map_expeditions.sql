-- Synced from live Supabase migration 20261001053406 (fix_treasure_map_expeditions)

alter table public.sector_expeditions
  add column treasure_hunt_id uuid references public.character_treasure_hunts(id) on delete set null;

create index sector_expeditions_treasure_hunt_idx
  on public.sector_expeditions(treasure_hunt_id)
  where treasure_hunt_id is not null;

alter function private.complete_expired_sector_expeditions(uuid)
  rename to complete_expired_sector_expeditions_standard;

create or replace function private.complete_expired_treasure_expeditions(
  p_character_id uuid
) returns integer
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  caller_id uuid := auth.uid();
  completed_count integer := 0;
begin
  if caller_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.characters c
    where c.id = p_character_id
      and (
        c.owner_user_id = caller_id
        or private.is_gm(caller_id)
      )
  ) then
    raise exception 'CHARACTER_NOT_OWNED';
  end if;

  with completed as (
    update public.sector_expeditions e
    set status = 'completed',
        completed_at = now()
    where e.character_id = p_character_id
      and e.treasure_hunt_id is not null
      and e.status = 'active'
      and e.ends_at <= now()
    returning 1
  )
  select count(*)::integer
  into completed_count
  from completed;

  return coalesce(completed_count, 0);
end;
$$;

revoke execute on function private.complete_expired_treasure_expeditions(uuid)
  from public, anon, authenticated;

revoke execute on function private.complete_expired_sector_expeditions_standard(uuid)
  from public, anon, authenticated;

create or replace function private.complete_expired_sector_expeditions(
  p_character_id uuid
) returns integer
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  treasure_count integer := 0;
  standard_count integer := 0;
begin
  treasure_count := private.complete_expired_treasure_expeditions(p_character_id);
  standard_count := private.complete_expired_sector_expeditions_standard(p_character_id);
  return coalesce(treasure_count, 0) + coalesce(standard_count, 0);
end;
$$;

revoke execute on function private.complete_expired_sector_expeditions(uuid)
  from public, anon, authenticated;

create or replace function public.start_treasure_hunt_expedition(
  p_hunt_id uuid
) returns public.sector_expeditions
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  caller_id uuid := auth.uid();
  hunt public.character_treasure_hunts;
  expedition public.sector_expeditions;
  duration_seconds integer;
begin
  if caller_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select h.*
  into hunt
  from public.character_treasure_hunts h
  join public.characters c on c.id = h.character_id
  where h.id = p_hunt_id
    and c.owner_user_id = caller_id
  for update of h;

  if hunt.id is null then
    raise exception 'TREASURE_HUNT_NOT_FOUND';
  end if;

  if hunt.status <> 'active' then
    raise exception 'TREASURE_HUNT_NOT_ACTIVE';
  end if;

  perform private.complete_expired_sector_expeditions(hunt.character_id);
  perform private.complete_expired_site_actions(hunt.character_id);

  select e.*
  into expedition
  from public.sector_expeditions e
  where e.treasure_hunt_id = hunt.id
    and e.status = 'active'
  order by e.started_at desc
  limit 1;

  if expedition.id is not null then
    return expedition;
  end if;

  if exists (
    select 1
    from public.sector_expeditions e
    where e.treasure_hunt_id = hunt.id
      and e.status = 'completed'
  ) then
    raise exception 'TREASURE_HUNT_ALREADY_VISITED';
  end if;

  if exists (
    select 1
    from public.sector_expeditions e
    where e.character_id = hunt.character_id
      and e.status in ('active','awaiting_event')
  ) then
    raise exception 'EXPEDITION_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.sector_site_actions a
    where a.character_id = hunt.character_id
      and a.status = 'active'
  ) then
    raise exception 'SITE_ACTION_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.dungeon_runs r
    where r.character_id = hunt.character_id
      and r.status = 'active'
  ) then
    raise exception 'DUNGEON_RUN_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.combat_encounters ce
    where ce.character_id = hunt.character_id
      and ce.status = 'active'
  ) then
    raise exception 'COMBAT_ALREADY_ACTIVE';
  end if;

  if not exists (
    select 1
    from public.character_sector_discoveries d
    where d.character_id = hunt.character_id
      and d.sector_id = hunt.target_sector_id
  ) then
    raise exception 'TREASURE_TARGET_NOT_DISCOVERED';
  end if;

  duration_seconds := private.character_exploration_duration_seconds(
    hunt.character_id,
    14400
  );

  insert into public.sector_expeditions (
    character_id,
    sector_id,
    ends_at,
    treasure_hunt_id
  )
  values (
    hunt.character_id,
    hunt.target_sector_id,
    now() + make_interval(secs => duration_seconds),
    hunt.id
  )
  returning * into expedition;

  return expedition;
end;
$$;

revoke execute on function public.start_treasure_hunt_expedition(uuid)
  from public, anon;

grant execute on function public.start_treasure_hunt_expedition(uuid)
  to authenticated, service_role;
