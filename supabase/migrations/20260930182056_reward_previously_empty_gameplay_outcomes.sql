-- Remove zero-value gameplay outcomes. Duels intentionally remain rewardless.
alter table private.hunting_attempts
  drop constraint if exists hunting_attempts_result_kind_check;
alter table private.hunting_attempts
  add constraint hunting_attempts_result_kind_check
  check (result_kind in ('resource','nothing','tracks','monster'));

CREATE OR REPLACE FUNCTION private.grant_exploration_event_reward(p_character_id uuid, p_event_key text, p_danger integer, p_sector_id smallint, p_outcome text DEFAULT 'discovered'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  v_danger integer:=greatest(0,least(10,coalesce(p_danger,0)));
  v_experience integer:=8+greatest(0,least(10,coalesce(p_danger,0)))*3;
  v_gold integer:=0;
  v_item_slug text;
  v_item public.item_definitions;
  v_quantity integer:=1;
  v_summary text:='';
begin
  if p_outcome='blocked' then
    v_experience:=greatest(3,ceil(v_experience*0.5)::integer);
  elsif p_outcome='discovered' then
    case coalesce(p_event_key,'')
      when 'world_alive_abandoned_camp' then
        v_gold:=10+v_danger*2;
      when 'world_alive_coast_empty_boat' then
        v_item_slug:='hunt_coast_shell';
      when 'world_alive_desert_glass_rain' then
        v_item_slug:='sun_glass_beta';
      when 'world_alive_forest_lights' then
        v_item_slug:='hunt_forest_herbs';
      when 'world_alive_mountain_bell' then
        v_item_slug:='stone_core_fragment_beta';
      when 'world_alive_plains_swordsman' then
        v_experience:=v_experience+8+v_danger*2;
      when 'world_alive_swamp_whisper' then
        v_item_slug:='hunt_swamp_reed';
      when 'world_alive_tundra_crack' then
        v_item_slug:='frost_crystal_beta';
      else
        null;
    end case;
  end if;

  update public.character_progress
  set experience=experience+v_experience,
      gold=gold+v_gold,
      updated_at=now()
  where character_id=p_character_id;

  if v_item_slug is not null then
    select * into v_item
    from public.item_definitions
    where slug=v_item_slug;

    if v_item.id is not null then
      perform private.grant_character_item(
        p_character_id,
        v_item.id,
        v_quantity,
        jsonb_build_object(
          'source','exploration_event',
          'event_key',coalesce(p_event_key,''),
          'sector_id',p_sector_id
        )
      );
    else
      v_item_slug:=null;
    end if;
  end if;

  v_summary:='Награда события: +'||v_experience||' опыта';
  if v_gold>0 then
    v_summary:=v_summary||', +'||v_gold||' золота';
  end if;
  if v_item_slug is not null then
    v_summary:=v_summary||', '||v_item.name||' ×'||v_quantity;
  end if;
  v_summary:=v_summary||'.';

  return jsonb_build_object(
    'experience',v_experience,
    'gold',v_gold,
    'item_slug',v_item_slug,
    'item_name',case when v_item_slug is null then null else v_item.name end,
    'quantity',case when v_item_slug is null then 0 else v_quantity end,
    'summary',v_summary
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.complete_expired_sector_expeditions(p_character_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  exp record;
  ev public.sector_event_definitions;
  sd public.sector_details;
  encounter public.exploration_event_templates;
  completed_count integer := 0;
  event_roll integer;
  event_reward jsonb;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.characters c
    where c.id = p_character_id
      and (
        c.owner_user_id = auth.uid()
        or private.is_gm(auth.uid())
      )
  ) then
    raise exception 'CHARACTER_NOT_OWNED';
  end if;

  for exp in
    select e.*
    from public.sector_expeditions e
    where e.character_id = p_character_id
      and e.status = 'active'
      and e.ends_at <= now()
    order by e.started_at
    for update
  loop
    ev := null;
    sd := null;
    encounter := null;

    select *
      into sd
    from public.sector_details
    where sector_id = exp.sector_id;

    select *
      into ev
    from public.sector_event_definitions sed
    where sed.sector_id = exp.sector_id
      and sed.enabled = true
    limit 1;

    if ev.id is not null then
      update public.sector_expeditions
      set status = 'awaiting_event'
      where id = exp.id;

      insert into public.expedition_event_instances (
        expedition_id,
        event_definition_id,
        encounter_template_id,
        source_kind,
        character_id,
        sector_id,
        title,
        player_prompt,
        gm_notes
      )
      values (
        exp.id,
        ev.id,
        null,
        'sector',
        exp.character_id,
        exp.sector_id,
        coalesce(nullif(ev.title,''), 'Неожиданное событие'),
        ev.player_prompt,
        ev.gm_notes
      )
      on conflict (expedition_id) do nothing;

      continue;
    end if;

    select t.*
      into encounter
    from public.exploration_event_templates t
    where t.enabled = true
      and (t.terrain_type is null or t.terrain_type = coalesce(sd.terrain_type, 'unassigned'))
      and (t.content_type is null or t.content_type = coalesce(sd.content_type, 'unassigned'))
      and coalesce(sd.danger_level, 0) between t.min_danger and t.max_danger
    order by (-ln(greatest(random(), 0.000001)) / greatest(t.weight, 1))
    limit 1;

    if encounter.id is not null then
      event_roll := floor(random() * 100)::integer + 1;

      if event_roll <= encounter.chance_percent then
        if encounter.requires_gm then
          update public.sector_expeditions
          set status = 'awaiting_event'
          where id = exp.id;

          insert into public.expedition_event_instances (
            expedition_id,
            event_definition_id,
            encounter_template_id,
            source_kind,
            character_id,
            sector_id,
            title,
            player_prompt,
            gm_notes
          )
          values (
            exp.id,
            null,
            encounter.id,
            'random',
            exp.character_id,
            exp.sector_id,
            encounter.title,
            encounter.player_prompt,
            encounter.gm_notes
          )
          on conflict (expedition_id) do nothing;

          continue;
        else
          update public.sector_expeditions
          set status = 'completed',
              completed_at = now()
          where id = exp.id;

          insert into public.character_sector_discoveries (
            character_id,
            sector_id,
            source
          )
          values (
            exp.character_id,
            exp.sector_id,
            'exploration_event'
          )
          on conflict do nothing;

          event_reward:=private.grant_exploration_event_reward(
            exp.character_id,
            encounter.name,
            coalesce(sd.danger_level,0),
            exp.sector_id,
            'discovered'
          );

          insert into public.expedition_results (
            expedition_id,
            character_id,
            sector_id,
            source,
            result_type,
            title,
            summary,
            outcome,
            encounter_template_id
          )
          values (
            exp.id,
            exp.character_id,
            exp.sector_id,
            'random_event',
            coalesce(sd.content_type, 'unassigned'),
            encounter.title,
            coalesce(nullif(encounter.automatic_result,''), nullif(encounter.player_prompt,''), 'Во время экспедиции произошло событие.')
              ||case when coalesce(event_reward->>'summary','')<>'' then ' '||(event_reward->>'summary') else '' end,
            'discovered',
            encounter.id
          )
          on conflict (expedition_id) do nothing;

          perform private.record_discovery(
            exp.character_id,
            'world_event',
            encounter.id::text,
            encounter.title,
            coalesce(nullif(encounter.automatic_result,''), nullif(encounter.player_prompt,''), 'Во время экспедиции произошло событие.'),
            jsonb_build_object('sector_id',exp.sector_id,'terrain',sd.terrain_type)
          );

          completed_count := completed_count + 1;
          continue;
        end if;
      end if;
    end if;

    update public.sector_expeditions
    set status = 'completed',
        completed_at = now()
    where id = exp.id;

    insert into public.character_sector_discoveries (
      character_id,
      sector_id,
      source
    )
    values (
      exp.character_id,
      exp.sector_id,
      'exploration'
    )
    on conflict do nothing;

    perform private.default_expedition_result(
      exp.id,
      exp.character_id,
      exp.sector_id
    );

    completed_count := completed_count + 1;
  end loop;

  return completed_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.gm_resolve_expedition_event(p_event_instance_id uuid, p_resolution_text text, p_outcome text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  instance public.expedition_event_instances;
  sd public.sector_details;
  event_reward jsonb;
  event_key text;
begin
  if not private.is_gm(auth.uid()) then
    raise exception 'GM_REQUIRED';
  end if;

  if p_outcome not in ('discovered','blocked') then
    raise exception 'INVALID_EVENT_OUTCOME';
  end if;

  select *
    into instance
  from public.expedition_event_instances
  where id = p_event_instance_id
  for update;

  if instance.id is null then
    raise exception 'EVENT_INSTANCE_NOT_FOUND';
  end if;

  if instance.status <> 'pending' then
    raise exception 'EVENT_ALREADY_RESOLVED';
  end if;

  select *
    into sd
  from public.sector_details
  where sector_id = instance.sector_id;

  update public.expedition_event_instances
  set status = 'resolved',
      resolution_text = coalesce(p_resolution_text,''),
      outcome = p_outcome,
      resolved_at = now(),
      resolved_by = auth.uid()
  where id = p_event_instance_id;

  if instance.encounter_template_id is not null then
    select t.name into event_key
    from public.exploration_event_templates t
    where t.id=instance.encounter_template_id;
  end if;
  event_key:=coalesce(event_key,'sector_event');

  if p_outcome = 'discovered' then
    update public.sector_expeditions
    set status = 'completed',
        completed_at = now()
    where id = instance.expedition_id
      and status = 'awaiting_event';

    insert into public.character_sector_discoveries (
      character_id,
      sector_id,
      source
    )
    values (
      instance.character_id,
      instance.sector_id,
      'gm_event'
    )
    on conflict do nothing;
  else
    update public.sector_expeditions
    set status = 'cancelled',
        completed_at = now()
    where id = instance.expedition_id
      and status = 'awaiting_event';
  end if;

  event_reward:=private.grant_exploration_event_reward(
    instance.character_id,
    event_key,
    coalesce(sd.danger_level,0),
    instance.sector_id,
    p_outcome
  );

  insert into public.expedition_results (
    expedition_id,
    character_id,
    sector_id,
    source,
    result_type,
    title,
    summary,
    outcome,
    encounter_template_id
  )
  values (
    instance.expedition_id,
    instance.character_id,
    instance.sector_id,
    'gm_event',
    coalesce(sd.content_type, 'unassigned'),
    instance.title,
    coalesce(
      nullif(btrim(coalesce(p_resolution_text,'')), ''),
      case
        when p_outcome = 'discovered' then 'Событие разрешено. Сектор открыт.'
        else 'Экспедиция остановлена решением события.'
      end
    )
    ||case when coalesce(event_reward->>'summary','')<>'' then ' '||(event_reward->>'summary') else '' end,
    p_outcome,
    instance.encounter_template_id
  )
  on conflict (expedition_id) do update
  set source = excluded.source,
      result_type = excluded.result_type,
      title = excluded.title,
      summary = excluded.summary,
      outcome = excluded.outcome,
      encounter_template_id = excluded.encounter_template_id;

  insert into public.gm_audit_log (
    actor_user_id,
    action,
    target_type,
    target_id,
    details
  )
  values (
    auth.uid(),
    'expedition.event.resolve',
    'expedition_event',
    p_event_instance_id::text,
    jsonb_build_object(
      'outcome', p_outcome,
      'character_id', instance.character_id,
      'sector_id', instance.sector_id,
      'source_kind', instance.source_kind,
      'encounter_template_id', instance.encounter_template_id
    )
  );
end;
$function$
;

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
  v_result_text text:='';
  risk_roll numeric;
  event_name text;
  event_danger integer:=0;
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
  v_result_text:=coalesce(choice->>'result','Событие завершено.');

  if effect ? 'risk_good_chance' then
    risk_roll:=random()*100;
    if risk_roll<coalesce((effect->>'risk_good_chance')::numeric,50) then
      effect:=coalesce(effect->'good','{}'::jsonb);
      v_result_text:=v_result_text||' Удача на твоей стороне.';
    else
      effect:=coalesce(effect->'bad','{}'::jsonb);
      v_result_text:=v_result_text||' Пространство отвечает болезненно.';
    end if;
  end if;

  select greatest(0,least(10,coalesce(sd.danger_level,0))) into event_danger
  from public.sector_details sd
  where sd.sector_id=r.sector_id;

  select * into cp
  from public.character_progress
  where character_id=r.character_id
  for update;

  hp_delta:=round(cp.hp_max*coalesce((effect->>'hp_percent')::numeric,0)/100.0)::integer;
  mana_delta:=round(cp.mana_max*coalesce((effect->>'mana_percent')::numeric,0)/100.0)::integer;
  gold_delta:=coalesce((effect->>'gold_delta')::integer,0);
  exp_delta:=coalesce((effect->>'experience_delta')::integer,0);

  if effect='{}'::jsonb then
    exp_delta:=4+coalesce(event_danger,0)*2;
    v_result_text:=v_result_text
      ||' Осторожность и наблюдательность: +'||exp_delta||' опыта.';
  end if;

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
    v_result_text:=v_result_text||' Получено: '||(select name from public.item_definitions where slug=item_slug)||'.';
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

  select name into event_name
  from public.dungeon_event_definitions
  where slug=ev.event_slug;

  update public.dungeon_run_events dre
  set status='resolved',
      selected_choice=p_choice_slug,
      result_text=v_result_text,
      resolved_at=now()
  where dre.id=ev.id;

  update public.dungeon_runs
  set current_stage='room_'||(rooms_cleared+1)||'_ready'
  where id=r.id
    and status='active';

  perform private.record_discovery(
    r.character_id,'dungeon_event',ev.event_slug,
    coalesce(event_name,'Событие подземелья'),
    v_result_text,
    jsonb_build_object('run_id',r.id,'sector_id',r.sector_id)
  );

  return jsonb_build_object(
    'event_id',ev.id,
    'event_name',event_name,
    'result',v_result_text,
    'choice',p_choice_slug,
    'gold_delta',gold_delta,
    'experience_delta',exp_delta
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.start_hunt(p_character_id uuid, p_sector_id smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
  sd public.sector_details;
  st private.hunting_states;
  stats record;
  template public.enemy_templates;
  loot_row record;
  attempt_id uuid;
  run_id uuid;
  encounter_id uuid;
  next_pressure integer;
  monster_chance integer;
  resource_roll numeric;
  monster_roll numeric;
  quantity integer:=0;
  effective_danger integer;
  enemy_hp integer;
  enemy_attack integer;
  enemy_defense integer;
  enemy_initiative integer;
  enemy_level integer;
  item_name text;
  tracking_experience integer:=0;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  if private.character_blocked_for_event_boss(p_character_id) then
    raise exception 'CHARACTER_BUSY';
  end if;

  if not exists(
    select 1 from public.character_sector_discoveries d
    where d.character_id=p_character_id and d.sector_id=p_sector_id
  ) then raise exception 'HUNT_SECTOR_NOT_DISCOVERED'; end if;

  select * into sd from public.sector_details where sector_id=p_sector_id;
  if sd.sector_id is null or sd.content_type<>'wilderness' then
    raise exception 'HUNT_REQUIRES_WILDERNESS';
  end if;
  if sd.terrain_type='sea' then raise exception 'HUNT_NOT_AVAILABLE_AT_SEA'; end if;

  if exists(
    select 1 from public.event_boss_events e
    where e.enabled=true
      and e.boss_kind='sector_incursion'
      and e.sector_id=p_sector_id
      and now()>=e.starts_at and now()<e.ends_at
  ) then raise exception 'SECTOR_CAPTURED'; end if;

  select * into st
  from private.hunting_states
  where character_id=p_character_id
  for update;

  if st.character_id is null or st.locked_until<=now() then
    next_pressure:=1;
    insert into private.hunting_states(character_id,region_key,pressure,locked_until,last_hunt_at,updated_at)
    values(p_character_id,sd.terrain_type,1,now()+interval '12 hours',now(),now())
    on conflict(character_id) do update
    set region_key=excluded.region_key,pressure=1,locked_until=excluded.locked_until,
        last_hunt_at=now(),updated_at=now();
  else
    if st.region_key<>sd.terrain_type then
      raise exception 'HUNT_REGION_LOCKED:%:%',st.region_key,st.locked_until;
    end if;
    next_pressure:=least(6,st.pressure+1);
    update private.hunting_states
    set pressure=next_pressure,locked_until=now()+interval '12 hours',
        last_hunt_at=now(),updated_at=now()
    where character_id=p_character_id;
  end if;

  monster_chance:=private.hunting_monster_chance(next_pressure);
  resource_roll:=random();
  monster_roll:=random();

  if next_pressure<6 and resource_roll<0.20 then
    select hp.*,d.name item_name into loot_row
    from private.hunting_loot_pool hp
    join public.item_definitions d on d.id=hp.item_definition_id
    where hp.terrain_type=sd.terrain_type
    order by (-ln(greatest(random(),0.000001))/greatest(hp.weight,1))
    limit 1;

    if loot_row.item_definition_id is null then
      raise exception 'HUNT_LOOT_POOL_EMPTY';
    end if;

    quantity:=loot_row.min_quantity
      + floor(random()*(loot_row.max_quantity-loot_row.min_quantity+1))::integer;

    perform private.grant_character_item(
      p_character_id,loot_row.item_definition_id,quantity,
      jsonb_build_object(
        'source','hunting',
        'sector_id',p_sector_id,
        'region',sd.terrain_type,
        'pressure',next_pressure
      )
    );

    insert into private.hunting_attempts(
      character_id,sector_id,region_key,pressure_level,monster_chance,
      result_kind,status,item_definition_id,quantity,resolved_at
    )
    values(
      p_character_id,p_sector_id,sd.terrain_type,next_pressure,monster_chance,
      'resource','resolved',loot_row.item_definition_id,quantity,now()
    )
    returning id into attempt_id;

    return jsonb_build_object(
      'result','resource','attempt_id',attempt_id,'pressure',next_pressure,
      'monster_chance',monster_chance,'region_key',sd.terrain_type,
      'locked_until',now()+interval '12 hours',
      'item_name',loot_row.item_name,'quantity',quantity
    );
  end if;

  if next_pressure>=6 or monster_roll < monster_chance/100.0 then
    perform private.apply_passive_hp_regen(p_character_id);
    perform private.apply_passive_mana_regen(p_character_id);
    select * into stats from private.get_character_combat_stats(p_character_id);

    if stats.level is null then raise exception 'CHARACTER_PROGRESS_NOT_FOUND'; end if;
    if stats.hp_current<=0 then raise exception 'CHARACTER_HAS_NO_HP'; end if;

    select t.* into template
    from public.enemy_templates t
    where t.enabled=true
      and t.is_boss=true
      and t.terrain_type=sd.terrain_type
      and t.slug<>'white_wolf_world_enemy'
    order by (-ln(greatest(random(),0.000001))/greatest(t.weight,1))
    limit 1;

    if template.id is null then raise exception 'NO_STRONG_HUNT_MONSTER_FOR_REGION'; end if;

    effective_danger:=greatest(3,least(10,coalesce(sd.danger_level,0)+2));
    enemy_level:=greatest(stats.level+1,effective_danger*2+1);
    enemy_hp:=50+effective_danger*25+12;
    enemy_attack:=10+effective_danger*4+2;
    enemy_defense:=6+effective_danger*3+2;
    enemy_initiative:=6+effective_danger*2+1;

    if effective_danger=10 then
      enemy_hp:=enemy_hp+150;
      enemy_attack:=enemy_attack+15;
      enemy_defense:=enemy_defense+12;
      enemy_initiative:=enemy_initiative+8;
    end if;

    enemy_hp:=ceil(enemy_hp*1.40*template.hp_multiplier)::integer;
    enemy_attack:=ceil(enemy_attack*1.20*template.attack_multiplier)::integer;
    enemy_defense:=ceil(enemy_defense*1.15*template.defense_multiplier)::integer;
    enemy_initiative:=greatest(0,round((enemy_initiative+3)*template.initiative_multiplier)::integer);

    insert into private.hunting_attempts(
      character_id,sector_id,region_key,pressure_level,monster_chance,
      result_kind,status,enemy_template_id
    )
    values(
      p_character_id,p_sector_id,sd.terrain_type,next_pressure,monster_chance,
      'monster','combat',template.id
    )
    returning id into attempt_id;

    insert into public.dungeon_runs(
      character_id,sector_id,status,current_stage,rooms_cleared,total_rooms,
      reward_gold,reward_experience,hunting_attempt_id
    )
    values(
      p_character_id,p_sector_id,'active','hunting_combat',0,1,0,0,attempt_id
    )
    returning id into run_id;

    insert into public.combat_encounters(
      dungeon_run_id,character_id,sector_id,status,round,room_index,is_boss,
      enemy_template_id,enemy_name,enemy_level,enemy_hp_current,enemy_hp_max,
      enemy_attack,enemy_defense,enemy_initiative,enemy_damage_type,enemy_resistances,
      enemy_on_hit_effect_type,enemy_on_hit_effect_chance,
      enemy_on_hit_effect_turns,enemy_on_hit_effect_potency,
      enemy_special_name,enemy_special_damage_multiplier,enemy_special_every_n,
      enemy_special_damage_type,enemy_special_effect_type,enemy_special_effect_chance,
      enemy_special_effect_turns,enemy_special_effect_potency,
      enemy_special_telegraph_text,enemy_special_attack_text,
      enemy_special_kind,enemy_special_value,
      enemy_phase2_hp_percent,enemy_phase2_name,
      enemy_phase2_attack_bonus_percent,enemy_phase2_defense_bonus_percent,
      enemy_phase2_special_every_n,enemy_abilities,enemy_ai_state,
      player_physical_damage_type,player_magic_damage_type,
      player_hp_current,player_hp_max,player_mana_current,player_mana_max
    )
    values(
      run_id,p_character_id,p_sector_id,'active',0,1,true,
      template.id,template.name,enemy_level,enemy_hp,enemy_hp,
      enemy_attack,enemy_defense,enemy_initiative,template.attack_damage_type,template.damage_resistances,
      template.on_hit_effect_type,template.on_hit_effect_chance,
      template.on_hit_effect_turns,template.on_hit_effect_potency,
      template.special_name,template.special_damage_multiplier,template.special_every_n,
      template.special_damage_type,template.special_effect_type,template.special_effect_chance,
      template.special_effect_turns,template.special_effect_potency,
      template.special_telegraph_text,template.special_attack_text,
      template.special_kind,template.special_value,
      template.phase2_hp_percent,template.phase2_name,
      template.phase2_attack_bonus_percent,template.phase2_defense_bonus_percent,
      template.phase2_special_every_n,template.abilities,'{}'::jsonb,
      stats.weapon_damage_type,stats.magic_damage_type,
      stats.hp_current,stats.hp_max,stats.mana_current,stats.mana_max
    )
    returning id into encounter_id;

    update private.hunting_attempts
    set dungeon_run_id=run_id,combat_encounter_id=encounter_id
    where id=attempt_id;

    update public.character_progress
    set hp_regen_anchor_at=now(),mana_regen_anchor_at=now(),updated_at=now()
    where character_id=p_character_id;

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      encounter_id,0,'system','hunting_monster_start',0,stats.hp_current,enemy_hp,
      'Охота потревожила сильного противника: '||template.name||'. '
      ||'Давление региона: '||next_pressure||'/6. '
      ||case when next_pressure>=6
        then 'Регион перегрет охотой: пока серия не остынет, каждая новая охота будет приводить к сильному монстру.'
        else 'Шанс сильного монстра на следующей охоте продолжит расти.' end
    );

    return jsonb_build_object(
      'result','monster','attempt_id',attempt_id,'pressure',next_pressure,
      'monster_chance',monster_chance,'region_key',sd.terrain_type,
      'locked_until',now()+interval '12 hours',
      'enemy_name',template.name,'run_id',run_id,'encounter_id',encounter_id
    );
  end if;

  tracking_experience:=3
    +greatest(0,least(10,coalesce(sd.danger_level,0)))
    +next_pressure;

  update public.character_progress
  set experience=experience+tracking_experience,
      updated_at=now()
  where character_id=p_character_id;

  insert into private.hunting_attempts(
    character_id,sector_id,region_key,pressure_level,monster_chance,
    result_kind,status,resolved_at
  )
  values(
    p_character_id,p_sector_id,sd.terrain_type,next_pressure,monster_chance,
    'tracks','resolved',now()
  )
  returning id into attempt_id;

  return jsonb_build_object(
    'result','tracks','attempt_id',attempt_id,'pressure',next_pressure,
    'monster_chance',monster_chance,'region_key',sd.terrain_type,
    'locked_until',now()+interval '12 hours',
    'experience',tracking_experience
  );
end;
$function$
;

revoke all on function private.grant_exploration_event_reward(uuid,text,integer,smallint,text)
  from public,anon,authenticated;
revoke all on function private.complete_expired_sector_expeditions(uuid)
  from public,anon,authenticated;
