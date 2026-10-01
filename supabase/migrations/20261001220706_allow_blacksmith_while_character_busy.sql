do $$
declare
  fn record;
  definition text;
begin
  for fn in
    select p.oid
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in (
        'apply_equipment_affix_at_blacksmith',
        'apply_weapon_affix_at_blacksmith',
        'awaken_weapon_at_blacksmith',
        'enhance_weapon_at_blacksmith_to_level',
        'reroll_equipment_affix_at_blacksmith',
        'reroll_weapon_affix_at_blacksmith',
        'use_tempering_mark_iii_at_blacksmith'
      )
  loop
    definition:=pg_get_functiondef(fn.oid);

    definition:=replace(
      definition,
      E'  if private.character_busy_for_blacksmith(p_character_id)\n    then raise exception ''CHARACTER_BUSY''; end if;\n',
      ''
    );

    definition:=replace(
      definition,
      E'  if private.character_busy_for_blacksmith(p_character_id) then\n    raise exception ''CHARACTER_BUSY'';\n  end if;\n',
      ''
    );

    execute definition;
  end loop;
end;
$$;
