create or replace function public.accept_settlement_quest(
  p_character_id uuid,
  p_quest_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  caller uuid := auth.uid();
  q public.settlement_quest_definitions;
  character_level integer;
  last_completed_at timestamptz;
  new_assignment_id uuid;
begin
  if caller is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  perform 1
  from public.characters c
  where c.id = p_character_id
    and c.owner_user_id = caller
  for update;

  if not found then
    raise exception 'CHARACTER_NOT_OWNED';
  end if;

  select * into q
  from public.settlement_quest_definitions
  where id = p_quest_id
  for share;

  if q.id is null or not q.enabled then
    raise exception 'QUEST_NOT_AVAILABLE';
  end if;

  if not exists (
    select 1 from public.sector_details sd
    where sd.sector_id = q.sector_id and sd.content_type = 'settlement'
  ) then
    raise exception 'QUEST_SETTLEMENT_INVALID';
  end if;

  if not exists (
    select 1 from public.character_sector_discoveries d
    where d.character_id = p_character_id and d.sector_id = q.sector_id
  ) then
    raise exception 'SETTLEMENT_NOT_DISCOVERED';
  end if;

  if exists (
    select 1 from public.character_settlement_quests a
    where a.character_id = p_character_id
      and a.quest_definition_id = q.id
      and a.status = 'active'
  ) then
    raise exception 'QUEST_ALREADY_ACTIVE';
  end if;

  if (
    select count(*)
    from public.character_settlement_quests a
    where a.character_id = p_character_id
      and a.status = 'active'
  ) >= 3 then
    raise exception 'TOO_MANY_ACTIVE_QUESTS';
  end if;

  select cp.level into character_level
  from public.character_progress cp
  where cp.character_id = p_character_id;

  if character_level < q.min_level then
    raise exception 'LEVEL_TOO_LOW';
  end if;

  select max(a.completed_at) into last_completed_at
  from public.character_settlement_quests a
  where a.character_id = p_character_id
    and a.quest_definition_id = q.id
    and a.status = 'completed';

  if last_completed_at is not null then
    if not q.repeatable then
      raise exception 'QUEST_ALREADY_COMPLETED';
    end if;

    if now() < last_completed_at + make_interval(hours => q.cooldown_hours) then
      raise exception 'QUEST_COOLDOWN';
    end if;
  end if;

  insert into public.character_settlement_quests(
    character_id, quest_definition_id
  )
  values (p_character_id, q.id)
  returning id into new_assignment_id;

  return new_assignment_id;
end;
$$;
