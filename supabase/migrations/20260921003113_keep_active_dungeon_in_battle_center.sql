create or replace function public.get_battle_center_overview(p_character_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  caller uuid:=auth.uid();
  result jsonb;
  solo_now boolean;
  party_now boolean;
  pvp_now boolean;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  solo_now:=
    exists(
      select 1
      from public.dungeon_runs dr
      where dr.character_id=p_character_id
        and dr.status='active'
    )
    or exists(
      select 1
      from public.combat_encounters ce
      where ce.character_id=p_character_id
        and ce.status='active'
    );

  party_now:=exists(
    select 1
    from public.party_dungeon_runs pdr
    join public.party_dungeon_run_members prm on prm.run_id=pdr.id
    where prm.character_id=p_character_id
      and pdr.status='active'
  ) or exists(
    select 1
    from public.party_combat_encounters pce
    join public.party_dungeon_run_members prm on prm.run_id=pce.run_id
    where prm.character_id=p_character_id
      and pce.status='active'
  );

  pvp_now:=exists(
    select 1
    from public.pvp_duels pd
    where pd.status='active'
      and p_character_id in(pd.challenger_character_id,pd.opponent_character_id)
  );

  select jsonb_build_object(
    'active_kind',
      case
        when solo_now then 'solo'
        when party_now then 'party'
        when pvp_now then 'pvp'
        else null
      end,
    'solo_active',solo_now,
    'party_active',party_now,
    'pvp_active',pvp_now,
    'history_count',least(50,
      (select count(*) from public.dungeon_runs dr where dr.character_id=p_character_id and dr.status<>'active')
      +(select count(*) from public.party_dungeon_runs pdr join public.party_dungeon_run_members prm on prm.run_id=pdr.id where prm.character_id=p_character_id and pdr.status<>'active')
      +(select count(*) from public.pvp_duels pd where p_character_id in(pd.challenger_character_id,pd.opponent_character_id) and pd.status not in('pending','active'))
    )
  ) into result;

  return result;
end;
$function$;
