-- Synced from live Supabase migration 20260927215544 (world_alive_helpers_and_dungeon_events)


create or replace function private.grant_item_slug(
  p_character_id uuid,
  p_slug text,
  p_quantity integer default 1
) returns uuid
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  def public.item_definitions;
  existing_id uuid;
  created_id uuid;
begin
  if p_quantity<=0 then return null; end if;
  select * into def from public.item_definitions where slug=p_slug;
  if def.id is null then raise exception 'ITEM_DEFINITION_NOT_FOUND'; end if;

  if def.stackable then
    select ci.id into existing_id
    from public.character_items ci
    where ci.character_id=p_character_id
      and ci.item_definition_id=def.id
      and ci.custom_name is null
      and ci.death_spirit_id is null
    order by ci.acquired_at
    limit 1
    for update;

    if existing_id is not null then
      update public.character_items set quantity=quantity+p_quantity where id=existing_id;
      return existing_id;
    end if;
  end if;

  insert into public.character_items(character_id,item_definition_id,quantity)
  values(p_character_id,def.id,case when def.stackable then p_quantity else 1 end)
  returning id into created_id;

  return created_id;
end;
$$;

create or replace function private.record_discovery(
  p_character_id uuid,
  p_category text,
  p_slug text,
  p_title text,
  p_description text default '',
  p_metadata jsonb default '{}'::jsonb
) returns void
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
begin
  insert into public.character_discoveries(character_id,category,slug,title,description,metadata)
  values(p_character_id,p_category,p_slug,p_title,coalesce(p_description,''),coalesce(p_metadata,'{}'::jsonb))
  on conflict(character_id,category,slug) do update
  set times_seen=public.character_discoveries.times_seen+1,
      last_seen_at=now(),
      metadata=public.character_discoveries.metadata||excluded.metadata;
end;
$$;

create or replace function private.pick_dungeon_modifier(p_danger integer)
returns text
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  chance integer;
  picked text;
begin
  chance:=case
    when p_danger<=0 then 12
    when p_danger=1 then 28
    when p_danger<=4 then 40
    when p_danger<=7 then 48
    else 55
  end;

  if floor(random()*100)::integer>=chance then return null; end if;

  select d.slug into picked
  from public.dungeon_modifier_definitions d
  where d.enabled
    and p_danger between d.min_danger and d.max_danger
  order by (-ln(greatest(random(),0.000001))/greatest(d.weight,1))
  limit 1;

  return picked;
end;
$$;

create or replace function private.dungeon_modifier_value(p_slug text,p_key text)
returns integer
language plpgsql
stable
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  d public.dungeon_modifier_definitions;
begin
  if p_slug is null then return 0; end if;
  select * into d from public.dungeon_modifier_definitions where slug=p_slug and enabled;
  if d.slug is null then return 0; end if;

  return case p_key
    when 'enemy_hp_percent' then d.enemy_hp_percent
    when 'enemy_attack_percent' then d.enemy_attack_percent
    when 'enemy_defense_percent' then d.enemy_defense_percent
    when 'reward_gold_percent' then d.reward_gold_percent
    when 'reward_xp_percent' then d.reward_xp_percent
    when 'rare_boss_bonus_percent' then d.rare_boss_bonus_percent
    else 0
  end;
end;
$$;

create or replace function private.maybe_create_dungeon_event(
  p_run_id uuid,
  p_room_index integer
) returns uuid
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  r public.dungeon_runs;
  danger integer:=0;
  chosen public.dungeon_event_definitions;
  created_id uuid;
  event_chance integer:=35;
begin
  select * into r from public.dungeon_runs where id=p_run_id for update;
  if r.id is null or r.status<>'active' or p_room_index>=r.total_rooms then return null; end if;

  select id into created_id
  from public.dungeon_run_events
  where run_id=r.id and room_index=p_room_index
  limit 1;

  if created_id is not null then return created_id; end if;

  select greatest(0,least(10,coalesce(sd.danger_level,0)))
  into danger
  from public.sector_details sd
  where sd.sector_id=r.sector_id;

  event_chance:=case
    when danger=0 then 22
    when danger<=2 then 35
    when danger<=5 then 42
    else 48
  end;

  if floor(random()*100)::integer>=event_chance then return null; end if;

  select d.* into chosen
  from public.dungeon_event_definitions d
  where d.enabled
    and danger between d.min_danger and d.max_danger
  order by (-ln(greatest(random(),0.000001))/greatest(d.weight,1))
  limit 1;

  if chosen.slug is null then return null; end if;

  insert into public.dungeon_run_events(run_id,character_id,room_index,event_slug,choices)
  values(r.id,r.character_id,p_room_index,chosen.slug,chosen.choices)
  returning id into created_id;

  update public.dungeon_runs
  set current_stage='event_pending'
  where id=r.id;

  return created_id;
end;
$$;

create or replace function public.resolve_dungeon_event(
  p_run_id uuid,
  p_choice_slug text
) returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  caller uuid:=auth.uid();
  r public.dungeon_runs;
  ev public.dungeon_run_events;
  choice jsonb;
  effect jsonb;
  cp public.character_progress;
  hp_delta integer:=0;
  mana_delta integer:=0;
  gold_delta integer:=0;
  exp_delta integer:=0;
  item_slug text;
  item_chance numeric:=100;
  result_text text:='';
  risk_roll numeric;
  event_name text;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  select dr.* into r
  from public.dungeon_runs dr
  join public.characters c on c.id=dr.character_id
  where dr.id=p_run_id
    and c.owner_user_id=caller
  for update of dr;

  if r.id is null then raise exception 'DUNGEON_RUN_NOT_FOUND'; end if;
  if r.status<>'active' then raise exception 'DUNGEON_RUN_NOT_ACTIVE'; end if;

  select * into ev
  from public.dungeon_run_events
  where run_id=r.id
    and status='pending'
  order by created_at desc
  limit 1
  for update;

  if ev.id is null then raise exception 'DUNGEON_EVENT_NOT_PENDING'; end if;

  select x into choice
  from jsonb_array_elements(ev.choices) x
  where x->>'slug'=p_choice_slug
  limit 1;

  if choice is null then raise exception 'INVALID_DUNGEON_EVENT_CHOICE'; end if;

  effect:=coalesce(choice->'effect','{}'::jsonb);
  result_text:=coalesce(choice->>'result','Событие завершено.');

  if effect ? 'risk_good_chance' then
    risk_roll:=random()*100;
    if risk_roll<coalesce((effect->>'risk_good_chance')::numeric,50) then
      effect:=coalesce(effect->'good','{}'::jsonb);
      result_text:=result_text||' Удача на твоей стороне.';
    else
      effect:=coalesce(effect->'bad','{}'::jsonb);
      result_text:=result_text||' Пространство отвечает болезненно.';
    end if;
  end if;

  select * into cp
  from public.character_progress
  where character_id=r.character_id
  for update;

  hp_delta:=round(cp.hp_max*coalesce((effect->>'hp_percent')::numeric,0)/100.0)::integer;
  mana_delta:=round(cp.mana_max*coalesce((effect->>'mana_percent')::numeric,0)/100.0)::integer;
  gold_delta:=coalesce((effect->>'gold_delta')::integer,0);
  exp_delta:=coalesce((effect->>'experience_delta')::integer,0);

  if gold_delta<0 and cp.gold<abs(gold_delta) then
    raise exception 'NOT_ENOUGH_GOLD_FOR_EVENT';
  end if;

  update public.character_progress
  set hp_current=greatest(1,least(hp_max,hp_current+hp_delta)),
      mana_current=greatest(0,least(mana_max,mana_current+mana_delta)),
      gold=greatest(0,gold+gold_delta),
      experience=greatest(0,experience+exp_delta),
      hp_regen_anchor_at=now(),
      mana_regen_anchor_at=now(),
      updated_at=now()
  where character_id=r.character_id;

  item_slug:=effect->>'item_slug';
  item_chance:=coalesce((effect->>'item_chance')::numeric,100);

  if item_slug is not null and random()*100<item_chance then
    perform private.grant_item_slug(r.character_id,item_slug,1);
    result_text:=result_text||' Получено: '||(select name from public.item_definitions where slug=item_slug)||'.';
  end if;

  if effect ? 'discovery_slug' then
    perform private.record_discovery(
      r.character_id,
      'mystery',
      effect->>'discovery_slug',
      coalesce(effect->>'discovery_title','Необычная находка'),
      coalesce(effect->>'discovery_description',''),
      jsonb_build_object('run_id',r.id,'sector_id',r.sector_id)
    );
  end if;

  select name into event_name from public.dungeon_event_definitions where slug=ev.event_slug;

  update public.dungeon_run_events
  set status='resolved',
      selected_choice=p_choice_slug,
      result_text=result_text,
      resolved_at=now()
  where id=ev.id;

  update public.dungeon_runs
  set current_stage='room_'||(rooms_cleared+1)||'_ready'
  where id=r.id
    and status='active';

  perform private.record_discovery(
    r.character_id,'dungeon_event',ev.event_slug,
    coalesce(event_name,'Событие подземелья'),
    result_text,
    jsonb_build_object('run_id',r.id,'sector_id',r.sector_id)
  );

  return jsonb_build_object(
    'event_id',ev.id,
    'event_name',event_name,
    'result',result_text,
    'choice',p_choice_slug
  );
end;
$$;

revoke all on function private.grant_item_slug(uuid,text,integer) from public;
revoke all on function private.record_discovery(uuid,text,text,text,text,jsonb) from public;
revoke all on function private.pick_dungeon_modifier(integer) from public;
revoke all on function private.dungeon_modifier_value(text,text) from public;
revoke all on function private.maybe_create_dungeon_event(uuid,integer) from public;

