-- Synced from live Supabase migration 20260927220744 (enable_elite_room_event_choice)

CREATE OR REPLACE FUNCTION public.resolve_dungeon_event(p_run_id uuid, p_choice_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
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

  if coalesce((effect->>'elite_room')::boolean,false) then
    update public.dungeon_runs
    set next_room_elite=true
    where id=r.id;
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
$function$;
