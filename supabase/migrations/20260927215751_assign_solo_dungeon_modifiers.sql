-- Synced from live Supabase migration 20260927215751 (assign_solo_dungeon_modifiers)

CREATE OR REPLACE FUNCTION public.start_dungeon_run(p_character_id uuid, p_sector_id smallint)
 RETURNS dungeon_runs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid := auth.uid();
  created_run public.dungeon_runs;
  sector_info public.sector_details;
  danger integer;
  room_count integer;
  reward_gold_value integer;
  reward_exp_value integer;
  character_level integer:=1;
  reward_exhausted_value boolean:=false;
  reward_attempt_number_value integer:=1;
  reward_cycle_ends_at_value timestamptz;
  modifier_slug_value text;
begin
  if caller_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.characters c
    where c.id = p_character_id
      and c.owner_user_id = caller_id
  ) then
    raise exception 'CHARACTER_NOT_OWNED';
  end if;

  perform private.complete_expired_sector_expeditions(p_character_id);
  perform private.complete_expired_site_actions(p_character_id);

  select details.*
    into sector_info
  from public.character_sector_discoveries d
  join public.sector_details details on details.sector_id = d.sector_id
  where d.character_id = p_character_id
    and d.sector_id = p_sector_id
    and details.content_type = 'dungeon';

  if sector_info.sector_id is null then
    raise exception 'DUNGEON_NOT_DISCOVERED';
  end if;

  if not exists (
    select 1
    from public.character_sector_site_progress p
    where p.character_id = p_character_id
      and p.sector_id = p_sector_id
      and p.site_type = 'dungeon'
      and p.status in ('scouted','cleared')
  ) then
    raise exception 'DUNGEON_NOT_SCOUTED';
  end if;

  if exists (
    select 1
    from public.sector_expeditions e
    where e.character_id = p_character_id
      and e.status in ('active','awaiting_event')
  ) then
    raise exception 'EXPEDITION_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.sector_site_actions a
    where a.character_id = p_character_id
      and a.status = 'active'
  ) then
    raise exception 'SITE_ACTION_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.dungeon_runs r
    where r.character_id = p_character_id
      and r.status = 'active'
  ) then
    raise exception 'DUNGEON_RUN_ALREADY_ACTIVE';
  end if;

  select a.attempt_number,a.reward_exhausted,a.cycle_ends_at
  into reward_attempt_number_value,reward_exhausted_value,reward_cycle_ends_at_value
  from private.consume_dungeon_reward_attempt(p_character_id,p_sector_id) a;

  danger := greatest(0, least(10, coalesce(sector_info.danger_level, 0)));
  modifier_slug_value:=private.pick_dungeon_modifier(danger);

  select coalesce(cp.level,1) into character_level
  from public.character_progress cp
  where cp.character_id=p_character_id;

  room_count := case
    when danger = 0 then 1
    when danger <= 2 then 2
    when danger <= 4 then 3
    when danger <= 6 then 4
    when danger <= 8 then 5
    else 6
  end;

  reward_gold_value:=private.scaled_dungeon_gold(
    danger,character_level,private.dungeon_base_gold(danger)
  );

  if danger = 0 then
    reward_exp_value := private.dungeon_zero_experience(character_level);
  else
    reward_exp_value := 50 + danger * 45 + room_count * 18;
    reward_exp_value:=private.scaled_dungeon_xp(danger,character_level,reward_exp_value);
  end if;

  reward_gold_value:=greatest(
    1,
    round(reward_gold_value
      *private.dungeon_repeat_gold_multiplier_percent(p_character_id,p_sector_id)
      /100.0
    )::integer
  );
  reward_exp_value:=greatest(
    0,
    round(reward_exp_value
      *private.dungeon_repeat_xp_multiplier_percent(p_character_id,p_sector_id)
      /100.0
    )::integer
  );

  if not reward_exhausted_value and modifier_slug_value is not null then
    reward_gold_value:=greatest(1,round(reward_gold_value*(100+private.dungeon_modifier_value(modifier_slug_value,'reward_gold_percent'))/100.0)::integer);
    reward_exp_value:=greatest(0,round(reward_exp_value*(100+private.dungeon_modifier_value(modifier_slug_value,'reward_xp_percent'))/100.0)::integer);
  end if;

  if reward_exhausted_value then
    reward_gold_value:=0;
    reward_exp_value:=0;
  end if;

  insert into public.dungeon_runs (
    character_id,
    sector_id,
    status,
    current_stage,
    rooms_cleared,
    total_rooms,
    reward_gold,
    reward_experience,
    reward_exhausted,
    reward_attempt_number,
    reward_cycle_ends_at,
    modifier_slug
  )
  values (
    p_character_id,
    p_sector_id,
    'active',
    'entrance',
    0,
    room_count,
    reward_gold_value,
    reward_exp_value,
    reward_exhausted_value,
    reward_attempt_number_value,
    reward_cycle_ends_at_value,
    modifier_slug_value
  )
  returning * into created_run;

  return created_run;
end;
$function$;
