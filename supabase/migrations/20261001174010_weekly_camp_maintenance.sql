
alter table public.character_camps
  add column if not exists maintenance_due_at timestamptz,
  add column if not exists last_repaired_at timestamptz;

update public.character_camps
set maintenance_due_at=now()+interval '7 days',
    last_repaired_at=now(),
    expires_at='infinity'::timestamptz,
    updated_at=now();

alter table public.character_camps
  alter column maintenance_due_at set default (now()+interval '7 days'),
  alter column maintenance_due_at set not null,
  alter column last_repaired_at set default now(),
  alter column last_repaired_at set not null;

create or replace function private.camp_repair_cost(p_level integer)
returns table(field_timber integer, field_fiber integer)
language sql immutable
as $$
  select
    case when p_level<=1 then 3 when p_level=2 then 5 else 7 end,
    case when p_level<=1 then 2 when p_level=2 then 3 else 5 end;
$$;

create or replace function private.cleanup_expired_camps()
returns void
language plpgsql security definer
set search_path to 'pg_catalog','public','private'
as $$
declare x record;
begin
  for x in
    select character_id
    from public.character_camps
    where maintenance_due_at<=now()
    for update
  loop
    perform private.return_camp_assets(x.character_id);
    delete from public.character_camps where character_id=x.character_id;
  end loop;
end;
$$;

create or replace function public.place_character_camp(
  p_character_id uuid,p_sector_id smallint,p_specialization text default 'base'
)
returns jsonb
language plpgsql security definer
set search_path to 'pg_catalog','public','private'
as $$
declare caller_id uuid:=auth.uid(); sd public.sector_details; due_at timestamptz;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters c where c.id=p_character_id and c.owner_user_id=caller_id)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  perform private.cleanup_expired_camps();
  if exists(select 1 from public.character_camps where character_id=p_character_id)
    then raise exception 'CAMP_ALREADY_ACTIVE'; end if;

  if not exists(select 1 from public.character_sector_discoveries d where d.character_id=p_character_id and d.sector_id=p_sector_id)
    then raise exception 'CAMP_SECTOR_NOT_DISCOVERED'; end if;

  select * into sd from public.sector_details where sector_id=p_sector_id;
  if sd.sector_id is null or sd.content_type<>'wilderness' or sd.terrain_type='sea'
    then raise exception 'CAMP_REQUIRES_WILDERNESS'; end if;

  if private.character_blocked_for_party_dungeon(p_character_id)
     or private.character_has_active_hunt(p_character_id)
     or private.character_has_active_camp_action(p_character_id)
  then raise exception 'CHARACTER_BUSY'; end if;

  due_at:=now()+interval '7 days';

  insert into public.character_camps(
    character_id,sector_id,specialization,camp_level,access_mode,camp_name,
    placed_at,expires_at,maintenance_due_at,last_repaired_at,updated_at
  ) values(
    p_character_id,p_sector_id,'base',1,'private','Полевой лагерь',
    now(),'infinity'::timestamptz,due_at,now(),now()
  );

  return jsonb_build_object(
    'character_id',p_character_id,'sector_id',p_sector_id,'camp_level',1,
    'access_mode','private','price',0,
    'expires_at',due_at,'maintenance_due_at',due_at
  );
end;
$$;

create or replace function public.repair_character_camp(p_character_id uuid)
returns jsonb
language plpgsql security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  caller_id uuid:=auth.uid();
  c public.character_camps;
  cost record;
  due_at timestamptz;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  perform private.cleanup_expired_camps();

  select * into c
  from public.character_camps
  where character_id=p_character_id and maintenance_due_at>now()
  for update;

  if c.character_id is null then raise exception 'CAMP_NOT_FOUND'; end if;

  select * into cost from private.camp_repair_cost(c.camp_level);
  perform private.consume_item_slug(p_character_id,'field_timber',cost.field_timber);
  perform private.consume_item_slug(p_character_id,'field_fiber',cost.field_fiber);

  due_at:=now()+interval '7 days';

  update public.character_camps
  set maintenance_due_at=due_at,
      last_repaired_at=now(),
      expires_at='infinity'::timestamptz,
      updated_at=now()
  where character_id=p_character_id;

  return jsonb_build_object(
    'maintenance_due_at',due_at,
    'expires_at',due_at,
    'field_timber',cost.field_timber,
    'field_fiber',cost.field_fiber,
    'camp_level',c.camp_level
  );
end;
$$;

create or replace function public.refuel_character_camp(p_character_id uuid)
returns jsonb
language sql security definer
set search_path to 'pg_catalog','public','private'
as $$
  select public.repair_character_camp(p_character_id);
$$;

do $$
declare r record; src text;
begin
  for r in
    select p.oid
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where p.prokind='f'
      and n.nspname in ('public','private')
      and p.proname in (
        'camp_access_allowed','camp_has_module',
        'build_camp_module','create_camp_trade_offer','deposit_camp_storage',
        'finish_hunt_v2','get_camp_state','get_character_activity_journal',
        'get_character_activity_journal_v2','get_character_world_markers',
        'get_character_world_markers_v2','set_camp_access','start_camp_action',
        'start_hunt_v2','upgrade_character_camp'
      )
  loop
    src:=pg_get_functiondef(r.oid);
    src:=replace(src,'c.expires_at>now()','c.maintenance_due_at>now()');
    src:=replace(src,'c.expires_at > now()','c.maintenance_due_at > now()');
    src:=replace(src,'where character_id=p_character_id and expires_at>now()','where character_id=p_character_id and maintenance_due_at>now()');
    src:=replace(src,'where character_id=p_character_id and expires_at > now()','where character_id=p_character_id and maintenance_due_at > now()');
    src:=replace(src,'where character_id=owner_id and expires_at>now()','where character_id=owner_id and maintenance_due_at>now()');
    src:=replace(src,'where character_id=owner_id and expires_at > now()','where character_id=owner_id and maintenance_due_at > now()');
    src:=replace(src,'c.expires_at','c.maintenance_due_at');
    execute src;
  end loop;
end;
$$;

revoke all on function private.camp_repair_cost(integer) from public,anon,authenticated;
revoke all on function public.repair_character_camp(uuid) from public,anon;
grant execute on function public.repair_character_camp(uuid) to authenticated,service_role;

do $$
declare old_job bigint;
begin
  select jobid into old_job from cron.job where jobname='veira-camp-maintenance' limit 1;
  if old_job is not null then perform cron.unschedule(old_job); end if;
end;
$$;

select cron.schedule(
  'veira-camp-maintenance',
  '29 * * * *',
  'select private.cleanup_expired_camps();'
);

