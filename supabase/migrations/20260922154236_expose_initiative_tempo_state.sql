do $migration$
declare
  v_def text;
  v_before text;
begin
  select pg_get_functiondef(p.oid)
  into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='get_party_dungeon_state'
    and pg_get_function_identity_arguments(p.oid)='p_character_id uuid';

  if v_def is null then
    raise exception 'get_party_dungeon_state definition not found';
  end if;

  if position('initiative_meter' in v_def)=0 then
    v_before:=v_def;
    v_def:=replace(
      v_def,
      $old$          'joined_order',prm.joined_order,$old$,
      $new$          'joined_order',prm.joined_order,
          'initiative_meter',coalesce(ms.initiative_meter,0),$new$
    );

    if v_def=v_before then
      raise exception 'party state initiative meter anchor not found';
    end if;

    execute v_def;
  end if;
end
$migration$;
