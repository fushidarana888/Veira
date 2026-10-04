-- A hunt only blocks other activities while its 10-minute timer is still running.
-- A finished, unclaimed hunt remains active so its reward cannot be duplicated by starting another hunt.

CREATE OR REPLACE FUNCTION private.character_has_running_hunt(p_character_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  select exists(
    select 1
    from private.hunting_attempts h
    where h.character_id=p_character_id
      and h.status='active'
      and h.finishes_at>now()
  );
$function$
;

CREATE OR REPLACE FUNCTION private.character_blocked_for_party_dungeon(p_character_id uuid)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
 select
   exists(select 1 from public.sector_expeditions where character_id=p_character_id and status in ('active','awaiting_event'))
   or exists(select 1 from public.sector_site_actions where character_id=p_character_id and status='active')
   or exists(select 1 from public.dungeon_runs where character_id=p_character_id and status='active')
   or private.character_in_active_party_dungeon(p_character_id)
   or exists(select 1 from public.pvp_duel_locks where character_id=p_character_id)
   or exists(select 1 from public.combat_encounters where character_id=p_character_id and status='active')
   or private.character_has_running_hunt(p_character_id)
   or private.character_has_active_camp_action(p_character_id);
$function$
;

CREATE OR REPLACE FUNCTION private.start_sector_exploration(p_character_id uuid, p_sector_id smallint)
 RETURNS sector_expeditions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid := auth.uid();
  target public.map_sectors;
  expedition public.sector_expeditions;
  duration_seconds integer;
begin
  if private.character_has_running_hunt(p_character_id) then raise exception 'HUNT_ALREADY_ACTIVE'; end if;
  if private.character_has_active_camp_action(p_character_id) then raise exception 'CAMP_ACTION_ALREADY_ACTIVE'; end if;
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

  select *
    into target
  from public.map_sectors s
  where s.id = p_sector_id;

  if target.id is null then
    raise exception 'SECTOR_NOT_FOUND';
  end if;

  if exists (
    select 1
    from public.character_sector_discoveries d
    where d.character_id = p_character_id
      and d.sector_id = p_sector_id
  ) then
    raise exception 'SECTOR_ALREADY_DISCOVERED';
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

  if exists (
    select 1
    from public.combat_encounters ce
    where ce.character_id = p_character_id
      and ce.status = 'active'
  ) then
    raise exception 'COMBAT_ALREADY_ACTIVE';
  end if;

  if not exists (
    select 1
    from public.character_sector_discoveries d
    join public.map_sectors known on known.id = d.sector_id
    where d.character_id = p_character_id
      and abs(known.grid_col - target.grid_col) <= 1
      and abs(known.grid_row - target.grid_row) <= 1
      and not (
        known.grid_col = target.grid_col
        and known.grid_row = target.grid_row
      )
  ) then
    raise exception 'SECTOR_NOT_ADJACENT_TO_DISCOVERED';
  end if;

  duration_seconds:=private.character_exploration_duration_seconds(p_character_id,14400);

  insert into public.sector_expeditions (
    character_id,
    sector_id,
    ends_at
  )
  values (
    p_character_id,
    p_sector_id,
    now() + make_interval(secs=>duration_seconds)
  )
  returning * into expedition;

  return expedition;
end;
$function$
;

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
  if private.character_has_running_hunt(p_character_id) then raise exception 'HUNT_ALREADY_ACTIVE'; end if;
  if private.character_has_active_camp_action(p_character_id) then raise exception 'CAMP_ACTION_ALREADY_ACTIVE'; end if;
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
$function$
;

CREATE OR REPLACE FUNCTION public.start_sector_site_action(p_character_id uuid, p_sector_id smallint, p_action_type text)
 RETURNS sector_site_actions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid := auth.uid();
  sd public.sector_details;
  created_action public.sector_site_actions;
  base_duration_seconds integer;
  effective_duration_seconds integer;
begin
  if private.character_has_running_hunt(p_character_id) then raise exception 'HUNT_ALREADY_ACTIVE'; end if;
  if private.character_has_active_camp_action(p_character_id) then raise exception 'CAMP_ACTION_ALREADY_ACTIVE'; end if;
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

  if not exists (
    select 1
    from public.character_sector_discoveries d
    where d.character_id = p_character_id
      and d.sector_id = p_sector_id
  ) then
    raise exception 'SECTOR_NOT_DISCOVERED';
  end if;

  select *
    into sd
  from public.sector_details
  where sector_id = p_sector_id;

  if sd.sector_id is null then
    raise exception 'SECTOR_DETAILS_NOT_FOUND';
  end if;

  if p_action_type = 'explore_ruins' then
    if sd.content_type <> 'ruins' then
      raise exception 'SECTOR_IS_NOT_RUINS';
    end if;
    base_duration_seconds := 7200;

    if exists (
      select 1
      from public.character_sector_site_progress p
      where p.character_id = p_character_id
        and p.sector_id = p_sector_id
        and p.status in ('explored','cleared')
    ) then
      raise exception 'RUINS_ALREADY_EXPLORED';
    end if;
  elsif p_action_type = 'scout_dungeon' then
    if sd.content_type <> 'dungeon' then
      raise exception 'SECTOR_IS_NOT_DUNGEON';
    end if;
    base_duration_seconds := 3600;

    if exists (
      select 1
      from public.character_sector_site_progress p
      where p.character_id = p_character_id
        and p.sector_id = p_sector_id
        and p.status in ('scouted','cleared')
    ) then
      raise exception 'DUNGEON_ALREADY_SCOUTED';
    end if;
  else
    raise exception 'INVALID_SITE_ACTION';
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

  if exists (
    select 1
    from public.combat_encounters ce
    where ce.character_id = p_character_id
      and ce.status = 'active'
  ) then
    raise exception 'COMBAT_ALREADY_ACTIVE';
  end if;

  effective_duration_seconds:=private.character_exploration_duration_seconds(
    p_character_id,
    base_duration_seconds
  );

  insert into public.sector_site_actions (
    character_id,
    sector_id,
    action_type,
    ends_at
  )
  values (
    p_character_id,
    p_sector_id,
    p_action_type,
    now() + make_interval(secs=>effective_duration_seconds)
  )
  returning * into created_action;

  return created_action;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.place_character_camp(p_character_id uuid, p_sector_id smallint, p_specialization text DEFAULT 'base'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); sd public.sector_details; due_at timestamptz;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters c where c.id=p_character_id and c.owner_user_id=caller_id)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  perform private.cleanup_expired_camps();
  if exists(select 1 from public.character_camps where character_id=p_character_id)
    then raise exception 'CAMP_ALREADY_ACTIVE'; end if;

  if not exists(select 1 from public.character_sector_discoveries d where d.character_id=p_character_id and d.sector_id=p_sector_id)
    then raise exception 'CAMP_SECTOR_NOT_DISCOVERED'; end if;

  select * into sd from public.sector_details where sector_id=p_sector_id;
  if sd.sector_id is null or sd.content_type<>'wilderness' or sd.terrain_type='sea'
    then raise exception 'CAMP_REQUIRES_WILDERNESS'; end if;

  if private.character_blocked_for_party_dungeon(p_character_id)
     or private.character_has_running_hunt(p_character_id)
     or private.character_has_active_camp_action(p_character_id)
  then raise exception 'CHARACTER_BUSY'; end if;

  due_at:=now()+interval '7 days';

  insert into public.character_camps(
    character_id,sector_id,specialization,camp_level,access_mode,camp_name,
    placed_at,expires_at,maintenance_due_at,last_repaired_at,updated_at
  ) values(
    p_character_id,p_sector_id,'base',1,'private','Полевой лагерь',
    now(),'infinity'::timestamptz,due_at,now(),now()
  );

  return jsonb_build_object(
    'character_id',p_character_id,'sector_id',p_sector_id,'camp_level',1,
    'access_mode','private','price',0,
    'expires_at',due_at,'maintenance_due_at',due_at
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.prepare_at_camp(p_character_id uuid, p_camp_owner_character_id uuid, p_preparation_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid:=auth.uid();
  exp timestamptz;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_preparation_type not in ('physical','magic','fortify')
    then raise exception 'INVALID_PREPARATION'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  perform private.cleanup_expired_camps();

  if not private.camp_access_allowed(p_character_id,p_camp_owner_character_id)
    then raise exception 'CAMP_ACCESS_DENIED'; end if;
  if not private.camp_has_module(p_camp_owner_character_id,'training_yard')
    then raise exception 'TRAINING_YARD_REQUIRED'; end if;
  if private.character_blocked_for_party_dungeon(p_character_id)
     or private.character_has_running_hunt(p_character_id)
  then raise exception 'CHARACTER_BUSY'; end if;

  if exists(
    select 1
    from public.character_camp_preparations p
    where p.character_id=p_character_id
      and p.prepared_at::date=current_date
  ) then
    raise exception 'PREPARATION_ALREADY_USED_TODAY';
  end if;

  exp:=now()+interval '1 hour';

  insert into public.character_camp_preparations(
    character_id,camp_owner_character_id,preparation_type,prepared_at,expires_at
  ) values(
    p_character_id,p_camp_owner_character_id,p_preparation_type,now(),exp
  )
  on conflict(character_id) do update
  set camp_owner_character_id=excluded.camp_owner_character_id,
      preparation_type=excluded.preparation_type,
      prepared_at=now(),
      expires_at=excluded.expires_at;

  return jsonb_build_object(
    'preparation_type',p_preparation_type,
    'bonus_percent',6,
    'expires_at',exp,
    'used_today',true
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.start_camp_action(p_character_id uuid, p_camp_owner_character_id uuid, p_action_type text, p_target_sector_id smallint DEFAULT NULL::smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid:=auth.uid();
  c public.character_camps;
  target public.map_sectors;
  ends_value timestamptz;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;
  if p_action_type not in ('rest','scout') then raise exception 'INVALID_CAMP_ACTION'; end if;

  perform private.cleanup_expired_camps();
  if not private.camp_access_allowed(p_character_id,p_camp_owner_character_id)
    then raise exception 'CAMP_ACCESS_DENIED'; end if;

  select * into c
  from public.character_camps
  where character_id=p_camp_owner_character_id
    and maintenance_due_at>now();

  if c.character_id is null then raise exception 'CAMP_NOT_FOUND'; end if;

  if private.character_blocked_for_party_dungeon(p_character_id)
     or private.character_has_running_hunt(p_character_id)
     or private.character_has_active_camp_action(p_character_id)
  then raise exception 'CHARACTER_BUSY'; end if;

  if p_action_type='scout' then
    if not private.camp_has_module(p_camp_owner_character_id,'scout_post')
      then raise exception 'SCOUT_POST_REQUIRED'; end if;
    if p_target_sector_id is null then raise exception 'SCOUT_TARGET_REQUIRED'; end if;

    select * into target from public.map_sectors where id=p_target_sector_id;
    if target.id is null then raise exception 'SECTOR_NOT_FOUND'; end if;

    if exists(
      select 1 from public.character_sector_discoveries d
      where d.character_id=p_character_id and d.sector_id=p_target_sector_id
    ) then
      raise exception 'SCOUT_TARGET_ALREADY_DISCOVERED';
    end if;

    if not exists(
      select 1
      from public.character_sector_discoveries d
      join public.map_sectors known on known.id=d.sector_id
      where d.character_id=p_character_id
        and abs(known.grid_col-target.grid_col)<=1
        and abs(known.grid_row-target.grid_row)<=1
        and not(known.grid_col=target.grid_col and known.grid_row=target.grid_row)
    ) then
      raise exception 'SCOUT_TARGET_NOT_EXPLORABLE';
    end if;

    ends_value:=now()+interval '2 hours';
  else
    ends_value:=now()+interval '2 hours';
  end if;

  insert into public.camp_actions(
    actor_character_id,camp_owner_character_id,action_type,target_sector_id,ends_at
  ) values(
    p_character_id,p_camp_owner_character_id,p_action_type,p_target_sector_id,ends_value
  );

  return jsonb_build_object(
    'action_type',p_action_type,
    'ends_at',ends_value,
    'target_sector_id',p_target_sector_id,
    'duration_seconds',7200
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_character_activity_journal_v2(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
 caller_id uuid:=auth.uid(); base jsonb; entries_data jsonb:='[]'::jsonb; camp_data jsonb:='null'::jsonb;
 blocker_data jsonb:='null'::jsonb; h private.hunting_attempts; a public.camp_actions; c public.character_camps;
begin
 if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
 if not exists(select 1 from public.characters ch where ch.id=p_character_id and (ch.owner_user_id=caller_id or private.is_gm(caller_id)))
   then raise exception 'CHARACTER_NOT_OWNED'; end if;

 perform private.cleanup_expired_camps();
 perform private.cleanup_expired_camp_trade_offers();
 base:=public.get_character_activity_journal(p_character_id);

 select coalesce(jsonb_agg(e),'[]'::jsonb) into entries_data
 from jsonb_array_elements(coalesce(base->'entries','[]'::jsonb)) e
 where e->>'kind'<>'camp';

 select * into h from private.hunting_attempts
 where character_id=p_character_id and status='active'
 order by created_at desc limit 1;

 select * into a from public.camp_actions
 where actor_character_id=p_character_id and status='active'
 order by started_at desc limit 1;

 if h.id is not null then
   entries_data:=entries_data||jsonb_build_array(jsonb_build_object(
     'id',h.id::text,'kind','hunting','title','Охота',
     'objective','Выслеживание в секторе #'||h.sector_id::text,
     'reward_hint','Ресурсы региона, следы или встреча с сильным противником',
     'sector_id',h.sector_id,'ends_at',h.finishes_at,'progress_current',0,'progress_target',1,
     'status','active','action_hint',case when h.finishes_at<=now() then 'Охота завершена — забери результат на карте.' else 'Дождись возвращения с охоты.' end
   ));
 end if;

 if h.id is not null and h.finishes_at>now() then
   blocker_data:=jsonb_build_object(
     'kind','hunting','title','Идёт охота',
     'detail','Выслеживание занимает 10 минут. После возвращения забери результат.',
     'sector_id',h.sector_id,'ends_at',h.finishes_at
   );
 elsif a.id is not null then
   blocker_data:=jsonb_build_object(
     'kind','camp_action','title',case a.action_type when 'rest' then 'Отдых в лагере' else 'Предпросмотр сектора' end,
     'detail',case a.action_type when 'rest' then 'Персонаж отдыхает у костра.' else 'Разведчики предпросматривают доступный к исследованию сектор.' end,
     'sector_id',(select sector_id from public.character_camps where character_id=a.camp_owner_character_id),
     'ends_at',a.ends_at
   );
   entries_data:=entries_data||jsonb_build_array(jsonb_build_object(
     'id',a.id::text,'kind','camp_action',
     'title',case a.action_type when 'rest' then 'Отдых в лагере' else 'Предпросмотр сектора' end,
     'objective',case a.action_type when 'rest' then 'Восстановить ОЗ и ману' else 'Предпросмотреть сектор #'||a.target_sector_id::text end,
     'reward_hint',case a.action_type when 'rest' then 'Полное восстановление ресурсов' else 'Опасность и наличие точки интереса без открытия сектора' end,
     'sector_id',(select sector_id from public.character_camps where character_id=a.camp_owner_character_id),
     'ends_at',a.ends_at,'progress_current',0,'progress_target',1,'status','active',
     'action_hint',case when a.ends_at<=now() then 'Действие завершено — забери результат в лагере.' else 'Дождись окончания.' end
   ));
 else
   blocker_data:=coalesce(base->'blocker','null'::jsonb);
 end if;

 select * into c from public.character_camps where character_id=p_character_id and maintenance_due_at>now();
 if c.character_id is not null then
   camp_data:=jsonb_build_object(
     'sector_id',c.sector_id,'camp_level',c.camp_level,'access_mode',c.access_mode,
     'placed_at',c.placed_at,'expires_at',c.maintenance_due_at,
     'module_slots',private.camp_module_slots(c.camp_level),
     'module_count',(select count(*) from public.camp_modules m where m.camp_owner_character_id=c.character_id),
     'storage_capacity',private.camp_storage_capacity(c.camp_level),
     'storage_used',(select count(*) from public.camp_storage_items s where s.camp_owner_character_id=c.character_id)
   );
   entries_data:=entries_data||jsonb_build_array(jsonb_build_object(
     'id',c.character_id::text,'kind','camp','title','Полевой лагерь · уровень '||c.camp_level::text,
     'objective','Сектор #'||c.sector_id::text||' · построек '
       ||(select count(*)::text from public.camp_modules m where m.camp_owner_character_id=c.character_id)
       ||'/'||private.camp_module_slots(c.camp_level)::text,
     'reward_hint','Отдых, постройки, склад, подготовка, предпросмотр секторов и локальный обмен',
     'sector_id',c.sector_id,'ends_at',c.maintenance_due_at,'progress_current',
       (select count(*)::integer from public.camp_modules m where m.camp_owner_character_id=c.character_id),
     'progress_target',private.camp_module_slots(c.camp_level),'status','active',
     'action_hint','Развивай лагерь ресурсами, строй модули или используй его как полевую базу.'
   ));
 end if;

 return jsonb_set(jsonb_set(jsonb_set(base,'{entries}',entries_data,true),'{blocker}',blocker_data,true),'{camp}',camp_data,true);
end;
$function$
;

