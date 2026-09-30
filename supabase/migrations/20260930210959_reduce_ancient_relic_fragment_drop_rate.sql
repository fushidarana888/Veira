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
    and p.proname='resolve_ruins_exploration'
    and p.prokind='f';

  if v_oid is null then
    raise exception 'resolve_ruins_exploration not found';
  end if;

  v_new:=replace(v_old,'elsif v_roll<95 and v_danger>=3 then','elsif v_roll<88 and v_danger>=3 then');
  v_new:=replace(v_new,'elsif v_roll>=95 and v_danger>=6 then','elsif v_roll>=98 and v_danger>=6 then');

  if v_new=v_old then
    raise exception 'ruins fragment thresholds not found';
  end if;

  execute v_new;
end
$migration$;
