create table if not exists public.settlement_quest_definitions (
  id uuid primary key default gen_random_uuid(),
  sector_id smallint not null references public.map_sectors(id) on delete cascade,
  title text not null check (char_length(title) between 3 and 100),
  description text not null default '' check (char_length(description) <= 1200),
  theme text not null default 'general'
    check (theme in ('general','protection','nature','research','arcane','combat','delivery')),
  objective_type text not null
    check (objective_type in ('discover_sectors','complete_expeditions','complete_dungeons','defeat_enemies','deliver_item')),
  objective_target integer not null default 1 check (objective_target between 1 and 1000),
  target_item_definition_id uuid references public.item_definitions(id) on delete restrict,
  reward_gold bigint not null default 0 check (reward_gold between 0 and 1000000000),
  reward_experience bigint not null default 0 check (reward_experience between 0 and 1000000000),
  min_level integer not null default 1 check (min_level between 1 and 1000),
  repeatable boolean not null default true,
  cooldown_hours integer not null default 24 check (cooldown_hours between 0 and 720),
  enabled boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint settlement_quest_target_item_check check (
    (objective_type = 'deliver_item' and target_item_definition_id is not null)
    or
    (objective_type <> 'deliver_item' and target_item_definition_id is null)
  )
);

create table if not exists public.character_settlement_quests (
  id uuid primary key default gen_random_uuid(),
  character_id uuid not null references public.characters(id) on delete cascade,
  quest_definition_id uuid not null references public.settlement_quest_definitions(id) on delete restrict,
  status text not null default 'active' check (status in ('active','completed','abandoned')),
  accepted_at timestamptz not null default now(),
  completed_at timestamptz,
  abandoned_at timestamptz,
  reward_gold_granted bigint not null default 0,
  reward_experience_granted bigint not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists settlement_quest_definitions_sector_idx
  on public.settlement_quest_definitions(sector_id, enabled, sort_order, title);
create index if not exists character_settlement_quests_character_status_idx
  on public.character_settlement_quests(character_id, status, accepted_at desc);
create index if not exists character_settlement_quests_completion_idx
  on public.character_settlement_quests(character_id, quest_definition_id, completed_at desc)
  where status = 'completed';
create unique index if not exists character_settlement_quests_one_active_idx
  on public.character_settlement_quests(character_id, quest_definition_id)
  where status = 'active';

alter table public.settlement_quest_definitions enable row level security;
alter table public.character_settlement_quests enable row level security;

revoke all on table public.settlement_quest_definitions from anon, authenticated;
revoke all on table public.character_settlement_quests from anon, authenticated;

drop trigger if exists settlement_quest_definitions_set_updated_at on public.settlement_quest_definitions;
create trigger settlement_quest_definitions_set_updated_at
before update on public.settlement_quest_definitions
for each row execute function public.set_updated_at();

create or replace function private.settlement_quest_progress(p_assignment_id uuid)
returns integer
language plpgsql
security invoker
set search_path = pg_catalog, public, private
as $$
declare
  a public.character_settlement_quests;
  q public.settlement_quest_definitions;
  value integer := 0;
begin
  select * into a
  from public.character_settlement_quests
  where id = p_assignment_id;

  if a.id is null then
    return 0;
  end if;

  select * into q
  from public.settlement_quest_definitions
  where id = a.quest_definition_id;

  if q.id is null then
    return 0;
  end if;

  case q.objective_type
    when 'discover_sectors' then
      select count(*)::integer into value
      from public.character_sector_discoveries d
      where d.character_id = a.character_id
        and d.discovered_at >= a.accepted_at;

    when 'complete_expeditions' then
      select count(*)::integer into value
      from public.sector_expeditions e
      where e.character_id = a.character_id
        and e.status = 'completed'
        and e.completed_at >= a.accepted_at;

    when 'complete_dungeons' then
      select count(*)::integer into value
      from public.dungeon_runs r
      where r.character_id = a.character_id
        and r.status = 'completed'
        and r.ended_at >= a.accepted_at
        and r.event_boss_id is null
        and r.hunting_attempt_id is null;

    when 'defeat_enemies' then
      select count(*)::integer into value
      from public.combat_encounters c
      where c.character_id = a.character_id
        and c.status = 'victory'
        and c.ended_at >= a.accepted_at;

    when 'deliver_item' then
      select coalesce(sum(ci.quantity),0)::integer into value
      from public.character_items ci
      where ci.character_id = a.character_id
        and ci.item_definition_id = q.target_item_definition_id;

    else
      value := 0;
  end case;

  return least(greatest(value,0), q.objective_target);
end;
$$;

revoke all on function private.settlement_quest_progress(uuid) from public, anon, authenticated;

create or replace function public.get_settlement_quests(
  p_character_id uuid,
  p_sector_id smallint
)
returns table(
  quest_id uuid,
  sector_id smallint,
  settlement_name text,
  title text,
  description text,
  theme text,
  objective_type text,
  objective_target integer,
  target_item_definition_id uuid,
  target_item_name text,
  reward_gold bigint,
  reward_experience bigint,
  min_level integer,
  repeatable boolean,
  cooldown_hours integer,
  enabled boolean,
  assignment_id uuid,
  assignment_status text,
  accepted_at timestamptz,
  progress integer,
  can_complete boolean,
  can_accept boolean,
  cooldown_remaining_seconds bigint,
  active_quest_count integer
)
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  caller uuid := auth.uid();
  character_level integer;
  current_active_count integer;
begin
  if caller is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.characters c
    where c.id = p_character_id
      and c.owner_user_id = caller
  ) then
    raise exception 'CHARACTER_NOT_OWNED';
  end if;

  if not exists (
    select 1
    from public.character_sector_discoveries d
    where d.character_id = p_character_id
      and d.sector_id = p_sector_id
  ) then
    raise exception 'SETTLEMENT_NOT_DISCOVERED';
  end if;

  if not exists (
    select 1
    from public.sector_details sd
    where sd.sector_id = p_sector_id
      and sd.content_type = 'settlement'
  ) then
    raise exception 'SECTOR_IS_NOT_SETTLEMENT';
  end if;

  select cp.level into character_level
  from public.character_progress cp
  where cp.character_id = p_character_id;

  select count(*)::integer into current_active_count
  from public.character_settlement_quests a
  where a.character_id = p_character_id
    and a.status = 'active';

  return query
  select
    q.id,
    q.sector_id,
    coalesce(sd.title, ms.location_name, 'Поселение #' || q.sector_id::text),
    q.title,
    q.description,
    q.theme,
    q.objective_type,
    q.objective_target,
    q.target_item_definition_id,
    target_item.name,
    q.reward_gold,
    q.reward_experience,
    q.min_level,
    q.repeatable,
    q.cooldown_hours,
    q.enabled,
    active_assignment.id,
    active_assignment.status,
    active_assignment.accepted_at,
    coalesce(private.settlement_quest_progress(active_assignment.id),0),
    (
      active_assignment.id is not null
      and private.settlement_quest_progress(active_assignment.id) >= q.objective_target
    ),
    (
      q.enabled
      and active_assignment.id is null
      and character_level >= q.min_level
      and current_active_count < 3
      and (
        last_completed.completed_at is null
        or (
          q.repeatable
          and now() >= last_completed.completed_at + make_interval(hours => q.cooldown_hours)
        )
      )
    ),
    case
      when last_completed.completed_at is null then 0::bigint
      when not q.repeatable then -1::bigint
      else greatest(
        0,
        floor(extract(epoch from (
          last_completed.completed_at + make_interval(hours => q.cooldown_hours) - now()
        )))::bigint
      )
    end,
    current_active_count
  from public.settlement_quest_definitions q
  join public.sector_details sd on sd.sector_id = q.sector_id
  join public.map_sectors ms on ms.id = q.sector_id
  left join public.item_definitions target_item on target_item.id = q.target_item_definition_id
  left join lateral (
    select a.id, a.status, a.accepted_at
    from public.character_settlement_quests a
    where a.character_id = p_character_id
      and a.quest_definition_id = q.id
      and a.status = 'active'
    order by a.accepted_at desc
    limit 1
  ) active_assignment on true
  left join lateral (
    select a.completed_at
    from public.character_settlement_quests a
    where a.character_id = p_character_id
      and a.quest_definition_id = q.id
      and a.status = 'completed'
    order by a.completed_at desc
    limit 1
  ) last_completed on true
  where q.sector_id = p_sector_id
    and (q.enabled or active_assignment.id is not null)
  order by
    (active_assignment.id is not null) desc,
    q.sort_order,
    q.title;
end;
$$;

revoke all on function public.get_settlement_quests(uuid, smallint) from public, anon;
grant execute on function public.get_settlement_quests(uuid, smallint) to authenticated;

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

  if not exists (
    select 1 from public.characters c
    where c.id = p_character_id and c.owner_user_id = caller
  ) then
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

revoke all on function public.accept_settlement_quest(uuid, uuid) from public, anon;
grant execute on function public.accept_settlement_quest(uuid, uuid) to authenticated;

create or replace function public.abandon_settlement_quest(
  p_character_id uuid,
  p_assignment_id uuid
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  caller uuid := auth.uid();
begin
  if caller is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (
    select 1 from public.characters c
    where c.id = p_character_id and c.owner_user_id = caller
  ) then
    raise exception 'CHARACTER_NOT_OWNED';
  end if;

  update public.character_settlement_quests a
  set status = 'abandoned',
      abandoned_at = now()
  where a.id = p_assignment_id
    and a.character_id = p_character_id
    and a.status = 'active';

  if not found then
    raise exception 'ACTIVE_QUEST_NOT_FOUND';
  end if;
end;
$$;

revoke all on function public.abandon_settlement_quest(uuid, uuid) from public, anon;
grant execute on function public.abandon_settlement_quest(uuid, uuid) to authenticated;

create or replace function public.complete_settlement_quest(
  p_character_id uuid,
  p_assignment_id uuid
)
returns table(
  reward_gold bigint,
  reward_experience bigint,
  new_level integer,
  remaining_experience bigint
)
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  caller uuid := auth.uid();
  a public.character_settlement_quests;
  q public.settlement_quest_definitions;
  current_progress integer;
  remaining integer;
  stack_row record;
  take_amount integer;
begin
  if caller is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (
    select 1 from public.characters c
    where c.id = p_character_id and c.owner_user_id = caller
  ) then
    raise exception 'CHARACTER_NOT_OWNED';
  end if;

  select * into a
  from public.character_settlement_quests
  where id = p_assignment_id
    and character_id = p_character_id
    and status = 'active'
  for update;

  if a.id is null then
    raise exception 'ACTIVE_QUEST_NOT_FOUND';
  end if;

  select * into q
  from public.settlement_quest_definitions
  where id = a.quest_definition_id;

  if q.id is null then
    raise exception 'QUEST_NOT_FOUND';
  end if;

  current_progress := private.settlement_quest_progress(a.id);

  if current_progress < q.objective_target then
    raise exception 'QUEST_NOT_COMPLETE';
  end if;

  if q.objective_type = 'deliver_item' then
    remaining := q.objective_target;

    for stack_row in
      select ci.id, ci.quantity
      from public.character_items ci
      where ci.character_id = p_character_id
        and ci.item_definition_id = q.target_item_definition_id
      order by ci.acquired_at, ci.id
      for update
    loop
      exit when remaining <= 0;
      take_amount := least(stack_row.quantity, remaining);

      if take_amount >= stack_row.quantity then
        delete from public.character_items where id = stack_row.id;
      else
        update public.character_items
        set quantity = quantity - take_amount
        where id = stack_row.id;
      end if;

      remaining := remaining - take_amount;
    end loop;

    if remaining > 0 then
      raise exception 'QUEST_ITEMS_MISSING';
    end if;
  end if;

  update public.character_progress
  set gold = gold + q.reward_gold,
      experience = experience + q.reward_experience
  where character_id = p_character_id;

  update public.character_settlement_quests
  set status = 'completed',
      completed_at = now(),
      reward_gold_granted = q.reward_gold,
      reward_experience_granted = q.reward_experience
  where id = a.id;

  return query
  select
    q.reward_gold,
    q.reward_experience,
    cp.level,
    cp.experience
  from public.character_progress cp
  where cp.character_id = p_character_id;
end;
$$;

revoke all on function public.complete_settlement_quest(uuid, uuid) from public, anon;
grant execute on function public.complete_settlement_quest(uuid, uuid) to authenticated;

create or replace function public.gm_list_settlement_quests()
returns table(
  quest_id uuid,
  sector_id smallint,
  settlement_name text,
  title text,
  description text,
  theme text,
  objective_type text,
  objective_target integer,
  target_item_definition_id uuid,
  target_item_name text,
  reward_gold bigint,
  reward_experience bigint,
  min_level integer,
  repeatable boolean,
  cooldown_hours integer,
  enabled boolean,
  sort_order integer,
  active_assignments bigint,
  total_completions bigint
)
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
begin
  if not private.is_gm(auth.uid()) then
    raise exception 'GM_REQUIRED';
  end if;

  return query
  select
    q.id,
    q.sector_id,
    coalesce(sd.title, ms.location_name, 'Поселение #' || q.sector_id::text),
    q.title,
    q.description,
    q.theme,
    q.objective_type,
    q.objective_target,
    q.target_item_definition_id,
    target_item.name,
    q.reward_gold,
    q.reward_experience,
    q.min_level,
    q.repeatable,
    q.cooldown_hours,
    q.enabled,
    q.sort_order,
    count(a.id) filter (where a.status = 'active')::bigint,
    count(a.id) filter (where a.status = 'completed')::bigint
  from public.settlement_quest_definitions q
  join public.sector_details sd on sd.sector_id = q.sector_id
  join public.map_sectors ms on ms.id = q.sector_id
  left join public.item_definitions target_item on target_item.id = q.target_item_definition_id
  left join public.character_settlement_quests a on a.quest_definition_id = q.id
  group by q.id, sd.title, ms.location_name, target_item.name
  order by q.sector_id, q.sort_order, q.title;
end;
$$;

revoke all on function public.gm_list_settlement_quests() from public, anon;
grant execute on function public.gm_list_settlement_quests() to authenticated;

create or replace function public.gm_save_settlement_quest(
  p_id uuid,
  p_sector_id smallint,
  p_title text,
  p_description text,
  p_theme text,
  p_objective_type text,
  p_objective_target integer,
  p_target_item_definition_id uuid,
  p_reward_gold bigint,
  p_reward_experience bigint,
  p_min_level integer,
  p_repeatable boolean,
  p_cooldown_hours integer,
  p_enabled boolean,
  p_sort_order integer
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  saved_id uuid;
begin
  if not private.is_gm(auth.uid()) then
    raise exception 'GM_REQUIRED';
  end if;

  if not exists (
    select 1 from public.sector_details sd
    where sd.sector_id = p_sector_id
      and sd.content_type = 'settlement'
  ) then
    raise exception 'SECTOR_IS_NOT_SETTLEMENT';
  end if;

  if btrim(coalesce(p_title,'')) = '' then
    raise exception 'TITLE_REQUIRED';
  end if;

  if p_theme not in ('general','protection','nature','research','arcane','combat','delivery') then
    raise exception 'INVALID_QUEST_THEME';
  end if;

  if p_objective_type not in ('discover_sectors','complete_expeditions','complete_dungeons','defeat_enemies','deliver_item') then
    raise exception 'INVALID_QUEST_OBJECTIVE';
  end if;

  if p_objective_target not between 1 and 1000 then
    raise exception 'INVALID_QUEST_TARGET';
  end if;

  if p_reward_gold < 0 or p_reward_experience < 0 then
    raise exception 'INVALID_QUEST_REWARD';
  end if;

  if p_min_level < 1 or p_min_level > 1000 then
    raise exception 'INVALID_MIN_LEVEL';
  end if;

  if p_cooldown_hours < 0 or p_cooldown_hours > 720 then
    raise exception 'INVALID_COOLDOWN';
  end if;

  if p_objective_type = 'deliver_item' then
    if p_target_item_definition_id is null then
      raise exception 'TARGET_ITEM_REQUIRED';
    end if;

    if not exists (
      select 1
      from public.item_definitions i
      where i.id = p_target_item_definition_id
        and i.stackable = true
        and i.category::text in ('material','consumable','quest')
    ) then
      raise exception 'DELIVERY_ITEM_MUST_BE_STACKABLE';
    end if;
  else
    p_target_item_definition_id := null;
  end if;

  if p_id is null then
    insert into public.settlement_quest_definitions(
      sector_id, title, description, theme, objective_type, objective_target,
      target_item_definition_id, reward_gold, reward_experience, min_level,
      repeatable, cooldown_hours, enabled, sort_order
    )
    values(
      p_sector_id,
      btrim(p_title),
      coalesce(p_description,''),
      p_theme,
      p_objective_type,
      p_objective_target,
      p_target_item_definition_id,
      p_reward_gold,
      p_reward_experience,
      p_min_level,
      coalesce(p_repeatable,true),
      p_cooldown_hours,
      coalesce(p_enabled,true),
      coalesce(p_sort_order,0)
    )
    returning id into saved_id;
  else
    update public.settlement_quest_definitions
    set sector_id = p_sector_id,
        title = btrim(p_title),
        description = coalesce(p_description,''),
        theme = p_theme,
        objective_type = p_objective_type,
        objective_target = p_objective_target,
        target_item_definition_id = p_target_item_definition_id,
        reward_gold = p_reward_gold,
        reward_experience = p_reward_experience,
        min_level = p_min_level,
        repeatable = coalesce(p_repeatable,true),
        cooldown_hours = p_cooldown_hours,
        enabled = coalesce(p_enabled,true),
        sort_order = coalesce(p_sort_order,0)
    where id = p_id
    returning id into saved_id;

    if saved_id is null then
      raise exception 'QUEST_NOT_FOUND';
    end if;
  end if;

  insert into public.gm_audit_log(
    actor_user_id, action, target_type, target_id, details
  )
  values(
    auth.uid(),
    case when p_id is null then 'settlement_quest.create' else 'settlement_quest.update' end,
    'settlement_quest',
    saved_id::text,
    jsonb_build_object(
      'sector_id', p_sector_id,
      'theme', p_theme,
      'objective_type', p_objective_type,
      'objective_target', p_objective_target,
      'reward_gold', p_reward_gold,
      'reward_experience', p_reward_experience,
      'enabled', p_enabled
    )
  );

  return saved_id;
end;
$$;

revoke all on function public.gm_save_settlement_quest(uuid, smallint, text, text, text, text, integer, uuid, bigint, bigint, integer, boolean, integer, boolean, integer) from public, anon;
grant execute on function public.gm_save_settlement_quest(uuid, smallint, text, text, text, text, integer, uuid, bigint, bigint, integer, boolean, integer, boolean, integer) to authenticated;

create or replace function public.gm_set_settlement_quest_enabled(
  p_quest_id uuid,
  p_enabled boolean
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
begin
  if not private.is_gm(auth.uid()) then
    raise exception 'GM_REQUIRED';
  end if;

  update public.settlement_quest_definitions
  set enabled = p_enabled
  where id = p_quest_id;

  if not found then
    raise exception 'QUEST_NOT_FOUND';
  end if;

  insert into public.gm_audit_log(
    actor_user_id, action, target_type, target_id, details
  )
  values(
    auth.uid(),
    'settlement_quest.set_enabled',
    'settlement_quest',
    p_quest_id::text,
    jsonb_build_object('enabled', p_enabled)
  );
end;
$$;

revoke all on function public.gm_set_settlement_quest_enabled(uuid, boolean) from public, anon;
grant execute on function public.gm_set_settlement_quest_enabled(uuid, boolean) to authenticated;

insert into public.settlement_quest_definitions(
  sector_id, title, description, theme, objective_type, objective_target,
  reward_gold, reward_experience, min_level, repeatable, cooldown_hours, sort_order
)
select 131, 'Разведка окрестностей',
       'Открой два новых сектора после принятия поручения и вернись за наградой.',
       'research', 'discover_sectors', 2, 35, 30, 1, true, 12, 10
where exists (
  select 1 from public.sector_details where sector_id=131 and content_type='settlement'
)
and not exists (
  select 1 from public.settlement_quest_definitions
  where sector_id=131 and title='Разведка окрестностей'
);

insert into public.settlement_quest_definitions(
  sector_id, title, description, theme, objective_type, objective_target,
  reward_gold, reward_experience, min_level, repeatable, cooldown_hours, sort_order
)
select 170, 'Дороги Лиавена',
       'Заверши две экспедиции после принятия поручения.',
       'protection', 'complete_expeditions', 2, 45, 35, 1, true, 12, 10
where exists (
  select 1 from public.sector_details where sector_id=170 and content_type='settlement'
)
and not exists (
  select 1 from public.settlement_quest_definitions
  where sector_id=170 and title='Дороги Лиавена'
);

insert into public.settlement_quest_definitions(
  sector_id, title, description, theme, objective_type, objective_target,
  reward_gold, reward_experience, min_level, repeatable, cooldown_hours, sort_order
)
select 177, 'Опасные тропы',
       'Победи трёх противников после принятия поручения.',
       'combat', 'defeat_enemies', 3, 60, 45, 2, true, 12, 10
where exists (
  select 1 from public.sector_details where sector_id=177 and content_type='settlement'
)
and not exists (
  select 1 from public.settlement_quest_definitions
  where sector_id=177 and title='Опасные тропы'
);

insert into public.settlement_quest_definitions(
  sector_id, title, description, theme, objective_type, objective_target,
  reward_gold, reward_experience, min_level, repeatable, cooldown_hours, sort_order
)
select 230, 'Испытание Сахрета',
       'Полностью заверши одно обычное подземелье после принятия поручения.',
       'combat', 'complete_dungeons', 1, 80, 60, 3, true, 18, 10
where exists (
  select 1 from public.sector_details where sector_id=230 and content_type='settlement'
)
and not exists (
  select 1 from public.settlement_quest_definitions
  where sector_id=230 and title='Испытание Сахрета'
);
