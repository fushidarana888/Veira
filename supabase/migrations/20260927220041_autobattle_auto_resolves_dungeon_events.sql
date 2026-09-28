-- Synced from live Supabase migration 20260927220041 (autobattle_auto_resolves_dungeon_events)

CREATE OR REPLACE FUNCTION public.run_dungeon_autobattle(p_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
  run_row public.dungeon_runs;
  settings public.character_autobattle_settings;
  encounter public.combat_encounters;
  result jsonb;
  total_actions integer:=0;
  hp_percent integer:=100;
  next_room integer;
  next_is_boss boolean;
  boss_defeated boolean:=false;
  boss_name text:=null;
  auto_choice text;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  select r.* into run_row
  from public.dungeon_runs r
  join public.characters c on c.id=r.character_id
  where r.id=p_run_id and c.owner_user_id=caller;

  if run_row.id is null then raise exception 'DUNGEON_RUN_NOT_FOUND'; end if;
  if run_row.status<>'active' then
    return jsonb_build_object(
      'status',run_row.status,
      'reason',run_row.status,
      'actions',0,
      'run_id',run_row.id
    );
  end if;

  settings:=private.ensure_character_autobattle_settings(run_row.character_id);

  loop
    select * into run_row
    from public.dungeon_runs
    where id=p_run_id;

    if run_row.status<>'active' then
      return jsonb_build_object(
        'status',run_row.status,
        'reason',run_row.status,
        'actions',total_actions,
        'rooms_cleared',run_row.rooms_cleared,
        'run_id',run_row.id,
        'boss_defeated',boss_defeated,
        'boss_name',boss_name
      );
    end if;

    if run_row.current_stage='event_pending' then
      select d.auto_choice
      into auto_choice
      from public.dungeon_run_events e
      join public.dungeon_event_definitions d on d.slug=e.event_slug
      where e.run_id=run_row.id and e.status='pending'
      order by e.created_at desc
      limit 1;

      if auto_choice is not null then
        perform public.resolve_dungeon_event(run_row.id,auto_choice);
        select * into run_row from public.dungeon_runs where id=p_run_id;
      end if;
    end if;

    select
      case when cp.hp_max<=0 then 0 else floor(cp.hp_current*100.0/cp.hp_max)::integer end
    into hp_percent
    from public.character_progress cp
    where cp.character_id=run_row.character_id;

    if hp_percent<=settings.stop_hp_percent and run_row.rooms_cleared>0 then
      return jsonb_build_object(
        'status','stopped',
        'reason','low_hp_between_rooms',
        'actions',total_actions,
        'rooms_cleared',run_row.rooms_cleared,
        'run_id',run_row.id,
        'hp_percent',hp_percent
      );
    end if;

    next_room:=run_row.rooms_cleared+1;
    next_is_boss:=next_room=run_row.total_rooms;

    if next_is_boss and not settings.include_boss then
      return jsonb_build_object(
        'status','stopped',
        'reason','boss_wait',
        'actions',total_actions,
        'rooms_cleared',run_row.rooms_cleared,
        'run_id',run_row.id
      );
    end if;

    select ce.* into encounter
    from public.combat_encounters ce
    where ce.dungeon_run_id=run_row.id and ce.status='active'
    order by ce.created_at desc
    limit 1;

    if encounter.id is null then
      encounter:=public.start_dungeon_combat(run_row.id);
    end if;

    result:=private.run_combat_autobattle_internal(
      encounter.id,
      least(80,greatest(1,240-total_actions))
    );

    total_actions:=total_actions+coalesce((result->>'actions')::integer,0);

    if coalesce(result->>'status','')='victory' and encounter.is_boss then
      boss_defeated:=true;
      boss_name:=encounter.enemy_name;
    end if;

    if coalesce(result->>'status','')<>'victory' then
      return result||jsonb_build_object(
        'actions',total_actions,
        'rooms_cleared',(
          select rooms_cleared from public.dungeon_runs where id=p_run_id
        ),
        'run_id',p_run_id
      );
    end if;

    if total_actions>=240 then
      return jsonb_build_object(
        'status','stopped',
        'reason','dungeon_action_limit',
        'actions',total_actions,
        'rooms_cleared',(
          select rooms_cleared from public.dungeon_runs where id=p_run_id
        ),
        'run_id',p_run_id
      );
    end if;

    encounter:=null;
  end loop;
end;
$function$;
