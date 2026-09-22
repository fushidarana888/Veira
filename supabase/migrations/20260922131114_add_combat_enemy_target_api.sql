
create or replace function public.get_combat_enemy_targets(
  p_character_id uuid,p_context_type text,p_encounter_id uuid
) returns table(
  target_type text,
  target_id uuid,
  name text,
  hp_current integer,
  hp_max integer,
  status text
)
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare caller_id uuid:=auth.uid();
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller_id
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  if p_context_type='solo' then
    if not exists(
      select 1 from public.combat_encounters ce
      where ce.id=p_encounter_id and ce.character_id=p_character_id
    ) then raise exception 'COMBAT_NOT_FOUND'; end if;

    return query
    select
      'encounter_enemy'::text,
      null::uuid,
      ce.enemy_name,
      ce.enemy_hp_current,
      ce.enemy_hp_max,
      case when ce.enemy_hp_current>0 and ce.status='active' then 'active' else 'defeated' end
    from public.combat_encounters ce
    where ce.id=p_encounter_id;

  elsif p_context_type='party' then
    if not exists(
      select 1
      from public.party_combat_encounters pce
      join public.party_dungeon_run_members prm on prm.run_id=pce.run_id
      where pce.id=p_encounter_id and prm.character_id=p_character_id
    ) then raise exception 'PARTY_COMBAT_NOT_FOUND'; end if;

    return query
    select
      'encounter_enemy'::text,
      null::uuid,
      pce.enemy_name,
      pce.enemy_hp_current,
      pce.enemy_hp_max,
      case when pce.enemy_hp_current>0 and pce.status='active' then 'active' else 'defeated' end
    from public.party_combat_encounters pce
    where pce.id=p_encounter_id;
  else
    raise exception 'INVALID_SUMMON_CONTEXT';
  end if;
end;
$$;

revoke all on function public.get_combat_enemy_targets(uuid,text,uuid) from public,anon;
grant execute on function public.get_combat_enemy_targets(uuid,text,uuid) to authenticated;
