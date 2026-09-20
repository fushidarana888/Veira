create or replace function private.religion_event_reward(
  p_religion_slug text,p_event_type text,p_metadata jsonb
)
returns table(faith integer,favor integer)
language plpgsql immutable set search_path='' as $$
declare
  theme text:=coalesce(p_metadata->>'theme','');
  content_type text:=coalesce(p_metadata->>'content_type','');
  rarity text:=coalesce(p_metadata->>'rarity','');
begin
  faith:=0; favor:=0;

  if p_religion_slug='path_of_light' then
    if p_event_type='settlement_quest_completed' then
      faith:=case theme when 'protection' then 8 when 'general' then 4 else 2 end;
    elsif p_event_type='support_action' then faith:=2;
    elsif p_event_type='guard_action' then faith:=1;
    elsif p_event_type='party_dungeon_completed' then faith:=6; favor:=1;
    end if;

  elsif p_religion_slug='old_roots' then
    if p_event_type='settlement_quest_completed' then
      faith:=case theme when 'nature' then 8 when 'general' then 3 else 1 end;
    elsif p_event_type='sector_discovered' and content_type='wilderness' then faith:=3;
    elsif p_event_type='wilderness_expedition_completed' then faith:=4;
    elsif p_event_type='hunting_started' then faith:=-20; favor:=-10;
    elsif p_event_type='hunting_kill' then faith:=-30; favor:=-15;
    end if;

  elsif p_religion_slug='star_covenant' then
    if p_event_type='settlement_quest_completed' then
      faith:=case when theme in ('research','arcane') then 8 when theme='general' then 3 else 1 end;
    elsif p_event_type='spell_learned' then faith:=12; favor:=1;
    elsif p_event_type='spell_cast' then faith:=1;
    elsif p_event_type='sector_discovered' then faith:=1;
    end if;

  elsif p_religion_slug='abyss' then
    if p_event_type='settlement_quest_completed' then
      faith:=case theme when 'combat' then 8 when 'general' then 3 else 1 end;
    elsif p_event_type='dungeon_completed' then faith:=5;
    elsif p_event_type='event_boss_victory' then faith:=12; favor:=2;
    elsif p_event_type='item_sacrificed' then
      faith:=case rarity when 'rare' then 6 when 'epic' then 10 when 'legendary' then 15 when 'unique' then 18 else 0 end;
      favor:=case rarity when 'rare' then 1 when 'epic' then 2 when 'legendary' then 3 when 'unique' then 4 else 0 end;
    end if;
  end if;

  return next;
end;
$$;

revoke all on function private.religion_event_reward(text,text,jsonb) from public,anon,authenticated;

create or replace function private.record_religion_event(
  p_character_id uuid,p_event_type text,p_source_key text,p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare
  v_religion text;
  v_base_faith integer:=0;
  v_base_favor integer:=0;
  v_actual_faith integer:=0;
  v_cap integer:=25;
  v_earned_today integer:=0;
  v_oath_id uuid;
  v_oath_progress integer;
  v_success_event text;
  v_success_meta jsonb;
  v_target integer;
  v_failure_event text;
  v_failure_meta jsonb;
  v_faith_reward integer;
  v_favor_reward integer;
  v_failure_faith integer;
  v_failure_favor integer;
  v_next integer;
begin
  select current_religion_slug into v_religion
  from public.character_religions
  where character_id=p_character_id;

  if v_religion is null then return; end if;

  if exists(
    select 1 from public.religion_faith_events
    where character_id=p_character_id and event_type=p_event_type and source_key=p_source_key
  ) then return; end if;

  select r.faith,r.favor into v_base_faith,v_base_favor
  from private.religion_event_reward(v_religion,p_event_type,coalesce(p_metadata,'{}'::jsonb)) r;

  v_base_faith:=coalesce(v_base_faith,0);
  v_base_favor:=coalesce(v_base_favor,0);

  select faith_daily_cap into v_cap
  from public.religion_definitions where slug=v_religion;
  v_cap:=coalesce(v_cap,25);

  if v_base_faith>0 then
    select coalesce(sum(greatest(faith_delta,0)),0)::integer into v_earned_today
    from public.religion_faith_events
    where character_id=p_character_id and religion_slug=v_religion
      and created_at>=date_trunc('day',now());

    v_actual_faith:=least(v_base_faith,greatest(v_cap-v_earned_today,0));
  else
    v_actual_faith:=v_base_faith;
  end if;

  insert into public.religion_faith_events(
    character_id,religion_slug,event_type,source_key,faith_delta,favor_delta,metadata
  ) values(
    p_character_id,v_religion,p_event_type,p_source_key,v_actual_faith,v_base_favor,coalesce(p_metadata,'{}'::jsonb)
  )
  on conflict(character_id,event_type,source_key) do nothing;

  if not found then return; end if;

  insert into public.character_religion_progress(character_id,religion_slug)
  values(p_character_id,v_religion)
  on conflict(character_id,religion_slug) do nothing;

  update public.character_religion_progress
  set faith_points=greatest(0,least(2200,faith_points+v_actual_faith)),
      favor=greatest(-100,least(100,favor+v_base_favor)),
      updated_at=now()
  where character_id=p_character_id and religion_slug=v_religion;

  select
    o.id,o.progress_count,d.success_event_type,d.success_metadata,d.target_count,
    d.failure_event_type,d.failure_metadata,d.faith_reward,d.favor_reward,
    d.failure_faith_penalty,d.failure_favor_penalty
  into
    v_oath_id,v_oath_progress,v_success_event,v_success_meta,v_target,
    v_failure_event,v_failure_meta,v_faith_reward,v_favor_reward,
    v_failure_faith,v_failure_favor
  from public.character_religion_oaths o
  join public.religion_oath_definitions d on d.id=o.oath_definition_id
  where o.character_id=p_character_id and o.status='active' and o.religion_slug=v_religion
  limit 1
  for update of o;

  if v_oath_id is not null then
    if v_failure_event is not null
       and v_failure_event=p_event_type
       and coalesce(p_metadata,'{}'::jsonb) @> coalesce(v_failure_meta,'{}'::jsonb)
    then
      update public.character_religion_oaths
      set status='failed',failed_at=now()
      where id=v_oath_id;

      update public.character_religion_progress
      set faith_points=greatest(0,faith_points-v_failure_faith),
          favor=greatest(-100,favor-v_failure_favor),
          updated_at=now()
      where character_id=p_character_id and religion_slug=v_religion;

    elsif v_success_event=p_event_type
       and coalesce(p_metadata,'{}'::jsonb) @> coalesce(v_success_meta,'{}'::jsonb)
    then
      v_next:=v_oath_progress+1;
      update public.character_religion_oaths
      set progress_count=least(v_next,v_target)
      where id=v_oath_id;

      if v_next>=v_target then
        update public.character_religion_oaths
        set status='completed',progress_count=v_target,completed_at=now()
        where id=v_oath_id;

        update public.character_religion_progress
        set faith_points=least(2200,faith_points+v_faith_reward),
            favor=least(100,favor+v_favor_reward),
            updated_at=now()
        where character_id=p_character_id and religion_slug=v_religion;
      end if;
    end if;
  end if;

  perform private.grant_religion_level10_reward(p_character_id,v_religion);
end;
$$;

revoke all on function private.record_religion_event(uuid,text,text,jsonb) from public,anon,authenticated;

create or replace function private.fail_active_religion_oath(p_character_id uuid)
returns void
language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare
  v_id uuid;
  v_religion text;
  v_faith integer;
  v_favor integer;
begin
  select o.id,o.religion_slug,d.failure_faith_penalty,d.failure_favor_penalty
  into v_id,v_religion,v_faith,v_favor
  from public.character_religion_oaths o
  join public.religion_oath_definitions d on d.id=o.oath_definition_id
  where o.character_id=p_character_id and o.status='active'
  limit 1
  for update of o;

  if v_id is null then return; end if;

  update public.character_religion_oaths
  set status='failed',failed_at=now()
  where id=v_id;

  update public.character_religion_progress
  set faith_points=greatest(0,faith_points-v_faith),
      favor=greatest(-100,favor-v_favor),
      updated_at=now()
  where character_id=p_character_id and religion_slug=v_religion;
end;
$$;

revoke all on function private.fail_active_religion_oath(uuid) from public,anon,authenticated;

create or replace function public.change_character_religion(
  p_character_id uuid,p_religion_slug text
)
returns void
language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare
  caller uuid:=auth.uid();
  old_slug text;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  if exists(select 1 from public.combat_encounters where character_id=p_character_id and status='active')
     or private.character_in_active_party_combat(p_character_id)
     or exists(select 1 from public.pvp_duels where status='active'
       and (challenger_character_id=p_character_id or opponent_character_id=p_character_id))
     or exists(select 1 from public.sector_expeditions where character_id=p_character_id and status in ('active','awaiting_event'))
     or exists(select 1 from public.dungeon_runs where character_id=p_character_id and status='active')
  then raise exception 'CHARACTER_BUSY'; end if;

  if p_religion_slug is not null and not exists(
    select 1 from public.religion_definitions where slug=p_religion_slug and enabled
  ) then raise exception 'RELIGION_NOT_AVAILABLE'; end if;

  select current_religion_slug into old_slug
  from public.character_religions
  where character_id=p_character_id
  for update;

  if old_slug is not distinct from p_religion_slug then return; end if;

  if old_slug is not null then
    perform private.fail_active_religion_oath(p_character_id);
  end if;

  insert into public.character_religions(character_id,current_religion_slug,joined_at,changed_at,updated_at)
  values(p_character_id,p_religion_slug,
    case when p_religion_slug is null then null else now() end,now(),now())
  on conflict(character_id) do update set
    current_religion_slug=excluded.current_religion_slug,
    joined_at=excluded.joined_at,
    changed_at=now(),
    updated_at=now();

  if p_religion_slug is not null then
    insert into public.character_religion_progress(character_id,religion_slug)
    values(p_character_id,p_religion_slug)
    on conflict(character_id,religion_slug) do nothing;

    perform private.grant_religion_level10_reward(p_character_id,p_religion_slug);
  end if;

  perform private.refresh_religious_item_penalties(p_character_id);
end;
$$;

revoke all on function public.change_character_religion(uuid,text) from public,anon;
grant execute on function public.change_character_religion(uuid,text) to authenticated;

create or replace function public.get_religion_catalog(p_character_id uuid)
returns table(
  slug text,name text,short_motto text,description text,praise_text text,taboo_text text,
  is_current boolean,faith_points integer,religion_level smallint,favor integer,
  current_level_points integer,next_level_points integer,daily_earned integer,daily_cap smallint,
  reward_item_id uuid,reward_item_name text,reward_item_description text,reward_claimed boolean,
  combat_modifiers jsonb
)
language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare caller uuid:=auth.uid();
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  return query
  select
    r.slug,r.name,r.short_motto,r.description,r.praise_text,r.taboo_text,
    coalesce(cr.current_religion_slug=r.slug,false),
    coalesce(cp.faith_points,0),
    private.religion_level(coalesce(cp.faith_points,0)),
    coalesce(cp.favor,0),
    private.religion_level_threshold(private.religion_level(coalesce(cp.faith_points,0))),
    case when private.religion_level(coalesce(cp.faith_points,0))>=10 then 2200
      else private.religion_level_threshold(private.religion_level(coalesce(cp.faith_points,0))+1) end,
    coalesce((
      select sum(greatest(e.faith_delta,0))::integer
      from public.religion_faith_events e
      where e.character_id=p_character_id and e.religion_slug=r.slug
        and e.created_at>=date_trunc('day',now())
    ),0),
    r.faith_daily_cap,
    r.level10_reward_item_id,reward.name,reward.description,
    coalesce(cp.level10_reward_claimed,false),
    case when cr.current_religion_slug=r.slug
      then private.character_religion_modifiers(p_character_id)
      else '{}'::jsonb end
  from public.religion_definitions r
  left join public.character_religions cr on cr.character_id=p_character_id
  left join public.character_religion_progress cp
    on cp.character_id=p_character_id and cp.religion_slug=r.slug
  left join public.item_definitions reward on reward.id=r.level10_reward_item_id
  where r.enabled
  order by r.sort_order,r.name;
end;
$$;

revoke all on function public.get_religion_catalog(uuid) from public,anon;
grant execute on function public.get_religion_catalog(uuid) to authenticated;

create or replace function public.get_religion_perks(p_character_id uuid,p_religion_slug text)
returns table(level smallint,title text,description text,modifiers jsonb,unlocked boolean)
language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare caller uuid:=auth.uid(); lvl smallint;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select private.religion_level(coalesce(cp.faith_points,0)) into lvl
  from public.religion_definitions r
  left join public.character_religion_progress cp
    on cp.character_id=p_character_id and cp.religion_slug=r.slug
  where r.slug=p_religion_slug;

  if lvl is null then raise exception 'RELIGION_NOT_FOUND'; end if;

  return query
  select p.level,p.title,p.description,p.modifiers,p.level<=lvl
  from public.religion_level_perks p
  where p.religion_slug=p_religion_slug
  order by p.level;
end;
$$;

revoke all on function public.get_religion_perks(uuid,text) from public,anon;
grant execute on function public.get_religion_perks(uuid,text) to authenticated;

create or replace function public.get_character_religion_oaths(p_character_id uuid)
returns table(
  oath_id uuid,name text,description text,target_count integer,progress_count integer,
  faith_reward integer,favor_reward integer,status text,active_assignment_id uuid,
  cooldown_remaining_seconds bigint
)
language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare caller uuid:=auth.uid(); current_slug text;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select current_religion_slug into current_slug
  from public.character_religions where character_id=p_character_id;
  if current_slug is null then return; end if;

  return query
  select
    d.id,d.name,d.description,d.target_count,
    case when a.status='active' then a.progress_count else 0 end,
    d.faith_reward,d.favor_reward,coalesce(a.status,'available'),
    case when a.status='active' then a.id else null end,
    case
      when a.status='completed' and a.completed_at>now()-interval '7 days'
      then ceil(extract(epoch from (a.completed_at+interval '7 days'-now())))::bigint
      else 0::bigint
    end
  from public.religion_oath_definitions d
  left join lateral(
    select o.id,o.status,o.progress_count,o.completed_at
    from public.character_religion_oaths o
    where o.character_id=p_character_id and o.oath_definition_id=d.id
    order by o.accepted_at desc limit 1
  ) a on true
  where d.religion_slug=current_slug and d.enabled
  order by d.sort_order,d.name;
end;
$$;

revoke all on function public.get_character_religion_oaths(uuid) from public,anon;
grant execute on function public.get_character_religion_oaths(uuid) to authenticated;

create or replace function public.accept_religion_oath(p_character_id uuid,p_oath_id uuid)
returns uuid
language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare caller uuid:=auth.uid(); current_slug text; oath_slug text; new_id uuid; last_completed timestamptz;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  if exists(select 1 from public.character_religion_oaths where character_id=p_character_id and status='active')
    then raise exception 'OATH_ALREADY_ACTIVE'; end if;

  select current_religion_slug into current_slug
  from public.character_religions where character_id=p_character_id;
  if current_slug is null then raise exception 'NO_ACTIVE_RELIGION'; end if;

  select religion_slug into oath_slug
  from public.religion_oath_definitions where id=p_oath_id and enabled;
  if oath_slug is null or oath_slug<>current_slug then raise exception 'OATH_NOT_AVAILABLE'; end if;

  select max(completed_at) into last_completed
  from public.character_religion_oaths
  where character_id=p_character_id and oath_definition_id=p_oath_id and status='completed';

  if last_completed is not null and last_completed>now()-interval '7 days'
    then raise exception 'OATH_COOLDOWN'; end if;

  insert into public.character_religion_oaths(character_id,oath_definition_id,religion_slug)
  values(p_character_id,p_oath_id,current_slug)
  returning id into new_id;
  return new_id;
end;
$$;

revoke all on function public.accept_religion_oath(uuid,uuid) from public,anon;
grant execute on function public.accept_religion_oath(uuid,uuid) to authenticated;

create or replace function public.abandon_religion_oath(p_character_id uuid,p_assignment_id uuid)
returns void
language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare caller uuid:=auth.uid(); v_religion text; v_faith integer; v_favor integer;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select o.religion_slug,d.failure_faith_penalty,d.failure_favor_penalty
  into v_religion,v_faith,v_favor
  from public.character_religion_oaths o
  join public.religion_oath_definitions d on d.id=o.oath_definition_id
  where o.id=p_assignment_id and o.character_id=p_character_id and o.status='active'
  for update of o;

  if v_religion is null then raise exception 'ACTIVE_OATH_NOT_FOUND'; end if;

  update public.character_religion_oaths
  set status='abandoned',failed_at=now()
  where id=p_assignment_id;

  update public.character_religion_progress
  set faith_points=greatest(0,faith_points-v_faith),
      favor=greatest(-100,favor-v_favor),
      updated_at=now()
  where character_id=p_character_id and religion_slug=v_religion;
end;
$$;

revoke all on function public.abandon_religion_oath(uuid,uuid) from public,anon;
grant execute on function public.abandon_religion_oath(uuid,uuid) to authenticated;

create or replace function public.get_character_religious_items(p_character_id uuid)
returns table(
  character_item_id uuid,item_name text,religion_slug text,religion_name text,
  weakened boolean,equipped boolean,equip_slot text
)
language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare caller uuid:=auth.uid();
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  return query
  select ci.id,i.name,i.religion_origin_slug,r.name,
    coalesce((ci.metadata->>'religion_weakened')::boolean,false),
    eq.character_item_id is not null,eq.slot::text
  from public.character_items ci
  join public.item_definitions i on i.id=ci.item_definition_id
  join public.religion_definitions r on r.slug=i.religion_origin_slug
  left join public.character_equipment eq on eq.character_item_id=ci.id
  where ci.character_id=p_character_id and i.religion_origin_slug is not null
  order by ci.acquired_at;
end;
$$;

revoke all on function public.get_character_religious_items(uuid) from public,anon;
grant execute on function public.get_character_religious_items(uuid) to authenticated;

create or replace function public.get_abyss_sacrifice_items(p_character_id uuid)
returns table(
  character_item_id uuid,item_name text,rarity text,quantity integer
)
language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare caller uuid:=auth.uid();
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  return query
  select ci.id,i.name,i.rarity::text,ci.quantity
  from public.character_items ci
  join public.item_definitions i on i.id=ci.item_definition_id
  left join public.character_equipment eq on eq.character_item_id=ci.id
  where ci.character_id=p_character_id
    and i.religion_origin_slug is null
    and eq.character_item_id is null
    and i.rarity::text in ('rare','epic','legendary','unique')
  order by case i.rarity::text when 'unique' then 4 when 'legendary' then 3 when 'epic' then 2 else 1 end desc,
           i.name;
end;
$$;

revoke all on function public.get_abyss_sacrifice_items(uuid) from public,anon;
grant execute on function public.get_abyss_sacrifice_items(uuid) to authenticated;

create or replace function public.sacrifice_item_to_abyss(
  p_character_id uuid,p_character_item_id uuid
)
returns text
language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare
  caller uuid:=auth.uid();
  ci public.character_items;
  def public.item_definitions;
  current_slug text;
  source_key text:=gen_random_uuid()::text;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select current_religion_slug into current_slug
  from public.character_religions where character_id=p_character_id;
  if current_slug<>'abyss' then raise exception 'ABYSS_RELIGION_REQUIRED'; end if;

  select * into ci
  from public.character_items
  where id=p_character_item_id and character_id=p_character_id
  for update;
  if ci.id is null then raise exception 'ITEM_NOT_AVAILABLE'; end if;

  if exists(select 1 from public.character_equipment where character_item_id=ci.id)
    then raise exception 'ITEM_IS_EQUIPPED'; end if;

  select * into def from public.item_definitions where id=ci.item_definition_id;
  if def.id is null or def.rarity::text not in ('rare','epic','legendary','unique')
    then raise exception 'SACRIFICE_REQUIRES_RARE_ITEM'; end if;
  if def.religion_origin_slug is not null then raise exception 'RELIGIOUS_RELIC_CANNOT_BE_SACRIFICED'; end if;

  if ci.quantity>1 then
    update public.character_items set quantity=quantity-1 where id=ci.id;
  else
    perform set_config('veira.item_delete_reason','abyss_sacrifice',true);
    delete from public.character_items where id=ci.id;
    perform set_config('veira.item_delete_reason','',true);
  end if;

  perform private.record_religion_event(
    p_character_id,'item_sacrificed',source_key,
    jsonb_build_object('rarity',def.rarity::text,'item_name',def.name)
  );

  return def.name;
end;
$$;

revoke all on function public.sacrifice_item_to_abyss(uuid,uuid) from public,anon;
grant execute on function public.sacrifice_item_to_abyss(uuid,uuid) to authenticated;
