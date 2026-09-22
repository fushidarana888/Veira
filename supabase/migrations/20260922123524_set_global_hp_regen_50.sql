
update public.race_definitions
set hp_regen_per_hour=50,
    updated_at=now();

alter table public.race_definitions
  alter column hp_regen_per_hour set default 50;

create or replace function private.apply_passive_hp_regen(p_character_id uuid)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $function$
declare
  p public.character_progress;
  regen_rate integer:=50;
  full_hours integer;
  heal_amount integer;
  new_hp integer;
begin
  select cp.* into p
  from public.character_progress cp
  where cp.character_id=p_character_id
  for update;

  if p.character_id is null then return 0; end if;

  select coalesce(rd.hp_regen_per_hour,50) into regen_rate
  from public.characters c
  left join public.race_definitions rd on rd.id=c.race_id
  where c.id=p_character_id;

  regen_rate:=coalesce(regen_rate,50);

  if exists(
    select 1 from public.combat_encounters ce
    where ce.character_id=p_character_id and ce.status='active'
  ) then
    update public.character_progress
    set hp_regen_anchor_at=now()
    where character_id=p_character_id;
    return 0;
  end if;

  if p.hp_current>=p.hp_max or regen_rate<=0 then
    update public.character_progress
    set hp_current=least(hp_current,hp_max),
        hp_regen_anchor_at=now()
    where character_id=p_character_id;
    return 0;
  end if;

  full_hours:=floor(extract(epoch from (now()-p.hp_regen_anchor_at))/3600.0)::integer;
  if full_hours<=0 then return 0; end if;

  heal_amount:=full_hours*regen_rate;
  new_hp:=least(p.hp_max,p.hp_current+heal_amount);

  update public.character_progress
  set hp_current=new_hp,
      hp_regen_anchor_at=case
        when new_hp>=p.hp_max then now()
        else p.hp_regen_anchor_at+make_interval(hours=>full_hours)
      end,
      updated_at=now()
  where character_id=p_character_id;

  return new_hp-p.hp_current;
end;
$function$;
