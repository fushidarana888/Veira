do $migration$
declare
  v_oid oid;
  v_old text;
  v_new text;
begin
  select p.oid,pg_get_functiondef(p.oid)
  into v_oid,v_old
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='private'
    and p.proname='record_religion_event'
    and p.prokind='f';

  if v_oid is null then
    raise exception 'record_religion_event not found';
  end if;

  v_new:=replace(
    v_old,
    $old$
        select coalesce(sum(greatest(faith_delta,0)),0)::integer
        into v_oath_weekly_earned
        from public.religion_faith_events
        where character_id=p_character_id
          and religion_slug=v_religion
          and event_type='oath_completed'
          and created_at>=now()-interval '7 days';

        v_oath_faith_granted:=least(
          v_faith_reward,
          greatest(100-v_oath_weekly_earned,0)
        );
$old$,
    $new$
        v_oath_faith_granted:=v_faith_reward;
$new$
  );

  if v_new=v_old then
    raise exception 'weekly oath cap block not found';
  end if;

  execute v_new;
end
$migration$;

do $migration$
declare
  v_oid oid;
  v_old text;
  v_new text;
begin
  select p.oid,pg_get_functiondef(p.oid)
  into v_oid,v_old
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='private'
    and p.proname='get_game_guide_catalog_internal'
    and p.prokind='f';

  if v_oid is null then
    raise exception 'get_game_guide_catalog_internal not found';
  end if;

  v_new:=replace(v_old,'''oath_weekly_cap'',100','''oath_weekly_cap'',0');

  if v_new=v_old then
    raise exception 'oath_weekly_cap catalog value not found';
  end if;

  execute v_new;
end
$migration$;

do $migration$
declare
  r record;
  v_missing integer;
begin
  for r in
    select
      e.id as event_id,
      e.character_id,
      o.religion_slug,
      e.faith_delta,
      d.faith_reward
    from public.religion_faith_events e
    join public.character_religion_oaths o
      on e.metadata->>'oath_assignment_id'=o.id::text
    join public.religion_oath_definitions d
      on d.id=o.oath_definition_id
    where e.event_type='oath_completed'
      and e.faith_delta<d.faith_reward
  loop
    v_missing:=greatest(0,r.faith_reward-r.faith_delta);

    if v_missing>0 then
      update public.religion_faith_events
      set
        faith_delta=r.faith_reward,
        metadata=(metadata-'weekly_cap')||jsonb_build_object('oath_reward_uncapped',true)
      where id=r.event_id;

      update public.character_religion_progress
      set
        faith_points=least(2200,faith_points+v_missing),
        updated_at=now()
      where character_id=r.character_id
        and religion_slug=r.religion_slug;
    end if;
  end loop;
end
$migration$;

update public.religion_faith_events
set metadata=(metadata-'weekly_cap')||jsonb_build_object('oath_reward_uncapped',true)
where event_type='oath_completed';
