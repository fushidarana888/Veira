
alter table public.camp_scout_reports
  add column if not exists has_point_of_interest boolean not null default false;

CREATE OR REPLACE FUNCTION public.finish_camp_action(p_character_id uuid, p_action_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid:=auth.uid();
  a public.camp_actions;
  sd public.sector_details;
  result_data jsonb;
  has_poi boolean;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select * into a
  from public.camp_actions
  where id=p_action_id and actor_character_id=p_character_id
  for update;

  if a.id is null then raise exception 'CAMP_ACTION_NOT_FOUND'; end if;
  if a.status<>'active' then raise exception 'CAMP_ACTION_NOT_ACTIVE'; end if;
  if a.ends_at>now() then raise exception 'CAMP_ACTION_NOT_READY'; end if;

  if a.action_type='rest' then
    update public.character_progress
    set hp_current=hp_max,
        mana_current=mana_max,
        hp_regen_anchor_at=now(),
        mana_regen_anchor_at=now(),
        updated_at=now()
    where character_id=p_character_id;

    result_data:=jsonb_build_object(
      'title','Отдых завершён',
      'text','После двух часов отдыха ОЗ и мана полностью восстановлены.'
    );
  else
    select * into sd from public.sector_details where sector_id=a.target_sector_id;
    has_poi:=coalesce(sd.content_type,'unassigned') not in ('unassigned','wilderness');

    insert into public.camp_scout_reports(
      character_id,camp_owner_character_id,sector_id,terrain_type,content_hint,danger_level,has_point_of_interest
    ) values(
      p_character_id,a.camp_owner_character_id,a.target_sector_id,
      coalesce(sd.terrain_type,'unknown'),
      case when has_poi then 'обнаружены признаки точки интереса' else 'точек интереса не замечено' end,
      coalesce(sd.danger_level,0),
      has_poi
    );

    result_data:=jsonb_build_object(
      'title','Предпросмотр завершён',
      'text','Разведчики оценили сектор, не открывая его.',
      'sector_id',a.target_sector_id,
      'danger_level',coalesce(sd.danger_level,0),
      'has_point_of_interest',has_poi
    );
  end if;

  update public.camp_actions
  set status='completed',result=result_data,completed_at=now()
  where id=a.id;

  return result_data;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_camp_state(p_character_id uuid, p_camp_owner_character_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid:=auth.uid();
  owner_id uuid;
  c public.character_camps;
  camp_json jsonb:='null'::jsonb;
  modules_json jsonb:='[]'::jsonb;
  action_json jsonb:='null'::jsonb;
  prep_json jsonb:='null'::jsonb;
  reports_json jsonb:='[]'::jsonb;
  targets_json jsonb:='[]'::jsonb;
  storage_json jsonb:='[]'::jsonb;
  offers_json jsonb:='[]'::jsonb;
  resource_json jsonb:='{}'::jsonb;
  event_json jsonb:='null'::jsonb;
  event_roll integer;
  event_claimed boolean;
  prep_used_today boolean:=false;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters
    where id=p_character_id and owner_user_id=caller_id
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  perform private.cleanup_expired_camps();
  perform private.cleanup_expired_camp_trade_offers();

  owner_id:=coalesce(p_camp_owner_character_id,p_character_id);

  select * into c
  from public.character_camps
  where character_id=owner_id and maintenance_due_at>now();

  if c.character_id is not null
     and not private.camp_access_allowed(p_character_id,owner_id)
  then raise exception 'CAMP_ACCESS_DENIED'; end if;

  if c.character_id is not null then
    camp_json:=jsonb_build_object(
      'owner_character_id',c.character_id,
      'owner_name',(select ch.name from public.characters ch where ch.id=c.character_id),
      'sector_id',c.sector_id,
      'camp_level',c.camp_level,
      'access_mode',c.access_mode,
      'camp_name',c.camp_name,
      'placed_at',c.placed_at,
      'expires_at',c.maintenance_due_at,
      'module_slots',private.camp_module_slots(c.camp_level),
      'storage_capacity',private.camp_storage_capacity(c.camp_level),
      'is_owner',c.character_id=p_character_id
    );

    select coalesce(
      jsonb_agg(jsonb_build_object('module_type',m.module_type,'built_at',m.built_at) order by m.built_at),
      '[]'::jsonb
    )
    into modules_json
    from public.camp_modules m
    where m.camp_owner_character_id=owner_id;

    if private.camp_has_module(owner_id,'scout_post') then
      select coalesce(
        jsonb_agg(
          jsonb_build_object('sector_id',s.id,'grid_col',s.grid_col,'grid_row',s.grid_row)
          order by s.id
        ),
        '[]'::jsonb
      )
      into targets_json
      from public.map_sectors s
      where not exists(
        select 1 from public.character_sector_discoveries d
        where d.character_id=p_character_id and d.sector_id=s.id
      )
      and exists(
        select 1
        from public.character_sector_discoveries d
        join public.map_sectors known on known.id=d.sector_id
        where d.character_id=p_character_id
          and abs(known.grid_col-s.grid_col)<=1
          and abs(known.grid_row-s.grid_row)<=1
          and not(known.grid_col=s.grid_col and known.grid_row=s.grid_row)
      );
    end if;

    if c.character_id=p_character_id then
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id',s.id,'item_definition_id',s.item_definition_id,'item_name',d.name,
            'rarity',d.rarity::text,'quantity',s.quantity,'custom_name',s.custom_name,
            'enhancement_level',s.enhancement_level,'awakening_level',s.awakening_level
          )
          order by s.stored_at
        ),
        '[]'::jsonb
      )
      into storage_json
      from public.camp_storage_items s
      join public.item_definitions d on d.id=s.item_definition_id
      where s.camp_owner_character_id=owner_id;
    end if;

    if private.camp_has_module(owner_id,'trading_post') then
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id',o.id,'offered_by_character_id',o.offered_by_character_id,
            'offered_by_name',seller.name,'offered_item_definition_id',o.offered_item_definition_id,
            'offered_item_name',od.name,'offered_quantity',o.offered_quantity,
            'offered_rarity',od.rarity::text,'offered_custom_name',o.offered_custom_name,
            'requested_item_definition_id',o.requested_item_definition_id,
            'requested_item_name',rd.name,'requested_quantity',o.requested_quantity,
            'expires_at',o.expires_at,'is_mine',o.offered_by_character_id=p_character_id
          )
          order by o.created_at desc
        ),
        '[]'::jsonb
      )
      into offers_json
      from public.camp_trade_offers o
      join public.item_definitions od on od.id=o.offered_item_definition_id
      join public.item_definitions rd on rd.id=o.requested_item_definition_id
      join public.characters seller on seller.id=o.offered_by_character_id
      where o.camp_owner_character_id=owner_id
        and o.status='open'
        and o.expires_at>now();
    end if;

    event_roll:=abs(hashtext(current_date::text||':'||p_character_id::text||':'||owner_id::text))%4;
    event_claimed:=exists(
      select 1 from public.camp_event_claims
      where character_id=p_character_id and event_date=current_date
    );

    event_json:=jsonb_build_object(
      'kind',case event_roll when 0 then 'traveler' when 1 then 'lost_pack' when 2 then 'fallen_branch' else 'quiet' end,
      'title',case event_roll when 0 then 'Путник у костра' when 1 then 'Потерянный свёрток' when 2 then 'После ночного ветра' else 'Тихая ночь' end,
      'claimed',event_claimed
    );
  end if;

  select jsonb_build_object(
    'field_timber',coalesce(sum(ci.quantity) filter(where d.slug='field_timber'),0),
    'field_fiber',coalesce(sum(ci.quantity) filter(where d.slug='field_fiber'),0),
    'smithing_scrap',coalesce(sum(ci.quantity) filter(where d.slug='smithing_scrap_beta'),0)
  )
  into resource_json
  from public.character_items ci
  join public.item_definitions d on d.id=ci.item_definition_id
  where ci.character_id=p_character_id and ci.death_spirit_id is null;

  select jsonb_build_object(
    'id',a.id,'action_type',a.action_type,'target_sector_id',a.target_sector_id,
    'started_at',a.started_at,'ends_at',a.ends_at
  )
  into action_json
  from public.camp_actions a
  where a.actor_character_id=p_character_id and a.status='active'
  order by a.started_at desc limit 1;

  select jsonb_build_object(
    'preparation_type',p.preparation_type,'expires_at',p.expires_at,'bonus_percent',6
  )
  into prep_json
  from public.character_camp_preparations p
  where p.character_id=p_character_id and p.expires_at>now();

  select exists(
    select 1 from public.character_camp_preparations p
    where p.character_id=p_character_id and p.prepared_at::date=current_date
  )
  into prep_used_today;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',r.id,'sector_id',r.sector_id,'danger_level',r.danger_level,
        'has_point_of_interest',r.has_point_of_interest,
        'created_at',r.created_at,'expires_at',r.expires_at
      )
      order by r.created_at desc
    ),
    '[]'::jsonb
  )
  into reports_json
  from public.camp_scout_reports r
  where r.character_id=p_character_id and r.expires_at>now();

  return jsonb_build_object(
    'camp',camp_json,'modules',modules_json,'active_action',action_json,
    'preparation',prep_json,'preparation_used_today',prep_used_today,
    'scout_reports',reports_json,'scout_targets',targets_json,'storage',storage_json,
    'trade_offers',offers_json,'resources',resource_json,'daily_event',event_json
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
   blocker_data:=jsonb_build_object(
     'kind','hunting','title','Идёт охота',
     'detail','Выслеживание занимает 10 минут. После возвращения забери результат.',
     'sector_id',h.sector_id,'ends_at',h.finishes_at
   );
   entries_data:=entries_data||jsonb_build_array(jsonb_build_object(
     'id',h.id::text,'kind','hunting','title','Охота',
     'objective','Выслеживание в секторе #'||h.sector_id::text,
     'reward_hint','Ресурсы региона, следы или встреча с сильным противником',
     'sector_id',h.sector_id,'ends_at',h.finishes_at,'progress_current',0,'progress_target',1,
     'status','active','action_hint',case when h.finishes_at<=now() then 'Охота завершена — забери результат на карте.' else 'Дождись возвращения с охоты.' end
   ));
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
     or private.character_has_active_hunt(p_character_id)
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
     or private.character_has_active_hunt(p_character_id)
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

revoke all on function public.start_camp_action(uuid,uuid,text,smallint) from public,anon;
grant execute on function public.start_camp_action(uuid,uuid,text,smallint) to authenticated,service_role;
revoke all on function public.finish_camp_action(uuid,uuid) from public,anon;
grant execute on function public.finish_camp_action(uuid,uuid) to authenticated,service_role;
revoke all on function public.prepare_at_camp(uuid,uuid,text) from public,anon;
grant execute on function public.prepare_at_camp(uuid,uuid,text) to authenticated,service_role;
revoke all on function public.get_camp_state(uuid,uuid) from public,anon;
grant execute on function public.get_camp_state(uuid,uuid) to authenticated,service_role;

