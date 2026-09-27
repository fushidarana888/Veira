-- Synced from live Supabase migration 20260927215809 (assign_party_dungeon_modifiers)

CREATE OR REPLACE FUNCTION public.start_party_dungeon_run(p_character_id uuid, p_sector_id smallint)
 RETURNS party_dungeon_runs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid:=auth.uid();
  party_row public.parties;
  sector_info public.sector_details;
  created_run public.party_dungeon_runs;
  member_row public.party_members;
  party_size integer;
  danger integer;
  room_count integer;
  reward_gold_value integer;
  reward_exp_value integer;
  modifier_slug_value text;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id
      and c.owner_user_id=caller_id
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select p.* into party_row
  from public.parties p
  join public.party_members pm on pm.party_id=p.id
  where pm.character_id=p_character_id
    and p.status='active'
  for update of p;

  if party_row.id is null then raise exception 'PARTY_NOT_FOUND'; end if;
  if party_row.leader_character_id<>p_character_id then raise exception 'PARTY_LEADER_REQUIRED'; end if;

  select count(*) into party_size
  from public.party_members
  where party_id=party_row.id;

  if party_size<2 then raise exception 'PARTY_NEEDS_TWO_MEMBERS'; end if;
  if party_size>4 then raise exception 'PARTY_TOO_LARGE'; end if;

  if exists(
    select 1 from public.party_dungeon_runs
    where party_id=party_row.id
      and status='active'
  ) then raise exception 'PARTY_DUNGEON_ALREADY_ACTIVE'; end if;

  if not private.party_common_dungeon_access(party_row.id,p_sector_id) then
    raise exception 'PARTY_DUNGEON_NOT_AVAILABLE_TO_ALL';
  end if;

  select * into sector_info
  from public.sector_details
  where sector_id=p_sector_id
    and content_type='dungeon';

  if sector_info.sector_id is null then raise exception 'DUNGEON_NOT_FOUND'; end if;

  for member_row in
    select *
    from public.party_members
    where party_id=party_row.id
    order by (character_id=party_row.leader_character_id) desc,joined_at,character_id
  loop
    if private.character_blocked_for_party_dungeon(member_row.character_id) then
      raise exception 'PARTY_MEMBER_BUSY:%',member_row.character_id;
    end if;

    perform private.apply_passive_hp_regen(member_row.character_id);
    perform private.apply_passive_mana_regen(member_row.character_id);
  end loop;

  danger:=greatest(0,least(10,coalesce(sector_info.danger_level,0)));
  modifier_slug_value:=private.pick_dungeon_modifier(danger);

  room_count:=case
    when danger=0 then 1
    when danger<=2 then 2
    when danger<=4 then 3
    when danger<=6 then 4
    when danger<=8 then 5
    else 6
  end;

  reward_gold_value:=private.dungeon_base_gold(danger);
  if danger=0 then
    reward_exp_value:=15;
  else
    reward_exp_value:=50+danger*45+room_count*18;
  end if;

  if modifier_slug_value is not null then
    reward_gold_value:=greatest(1,round(reward_gold_value*(100+private.dungeon_modifier_value(modifier_slug_value,'reward_gold_percent'))/100.0)::integer);
    reward_exp_value:=greatest(0,round(reward_exp_value*(100+private.dungeon_modifier_value(modifier_slug_value,'reward_xp_percent'))/100.0)::integer);
  end if;

  insert into public.party_dungeon_runs(
    party_id,leader_character_id,sector_id,status,current_stage,
    rooms_cleared,total_rooms,reward_gold,reward_experience,member_count,modifier_slug
  )
  values(
    party_row.id,p_character_id,p_sector_id,'active','entrance',
    0,room_count,reward_gold_value,reward_exp_value,party_size,modifier_slug_value
  )
  returning * into created_run;

  insert into public.party_dungeon_run_members(
    run_id,character_id,joined_order,reward_exhausted,reward_attempt_number,reward_cycle_ends_at
  )
  select
    created_run.id,
    pm.character_id,
    row_number() over(
      order by (pm.character_id=party_row.leader_character_id) desc,pm.joined_at,pm.character_id
    )::smallint,
    cycle.reward_exhausted,
    cycle.attempt_number,
    cycle.cycle_ends_at
  from public.party_members pm
  cross join lateral private.consume_dungeon_reward_attempt(pm.character_id,p_sector_id) cycle
  where pm.party_id=party_row.id;

  return created_run;
end;
$function$;
