alter table public.settlement_quest_definitions
  alter column reward_reputation set default 45;

alter table public.settlement_quest_definitions
  drop constraint if exists settlement_quest_definitions_reward_reputation_check;
alter table public.settlement_quest_definitions
  add constraint settlement_quest_definitions_reward_reputation_check
  check (reward_reputation between 0 and 90);

alter table public.character_settlement_quests
  drop constraint if exists character_settlement_quests_reputation_granted_check;
alter table public.character_settlement_quests
  add constraint character_settlement_quests_reputation_granted_check
  check (reputation_granted between 0 and 90);

update public.settlement_reputation_configs
set daily_cap=90,updated_at=now();

update public.settlement_quest_definitions
set reward_reputation=45,
    cooldown_hours=case when repeatable then 12 else cooldown_hours end,
    updated_at=now()
where enabled;

create or replace function public.gm_save_settlement_quest_v2(
  p_id uuid,p_sector_id smallint,p_title text,p_description text,p_theme text,p_objective_type text,
  p_objective_target integer,p_target_item_definition_id uuid,p_reward_gold bigint,
  p_reward_experience bigint,p_reward_reputation smallint,p_min_level integer,p_repeatable boolean,
  p_cooldown_hours integer,p_enabled boolean,p_sort_order integer
)
returns uuid
language plpgsql
security definer
set search_path=pg_catalog,public,private
as $$
declare
  saved_id uuid;
begin
  if not private.is_gm(auth.uid()) then raise exception 'GM_REQUIRED'; end if;
  if p_reward_reputation<0 or p_reward_reputation>90 then
    raise exception 'INVALID_REPUTATION_REWARD';
  end if;

  saved_id:=public.gm_save_settlement_quest(
    p_id,p_sector_id,p_title,p_description,p_theme,p_objective_type,p_objective_target,
    p_target_item_definition_id,p_reward_gold,p_reward_experience,p_min_level,
    p_repeatable,p_cooldown_hours,p_enabled,p_sort_order
  );

  update public.settlement_quest_definitions
  set reward_reputation=p_reward_reputation
  where id=saved_id;

  return saved_id;
end;
$$;

revoke all on function public.gm_save_settlement_quest_v2(
  uuid,smallint,text,text,text,text,integer,uuid,bigint,bigint,smallint,integer,boolean,integer,boolean,integer
) from public,anon;
grant execute on function public.gm_save_settlement_quest_v2(
  uuid,smallint,text,text,text,text,integer,uuid,bigint,bigint,smallint,integer,boolean,integer,boolean,integer
) to authenticated;

update public.religion_definitions
set faith_daily_cap=60,updated_at=now()
where enabled;

update public.religion_oath_definitions
set faith_reward=50
where enabled;

create or replace function private.religion_event_reward(
  p_religion_slug text,p_event_type text,p_metadata jsonb
)
returns table(faith integer,favor integer)
language plpgsql
immutable
set search_path=''
as $$
declare
  theme text:=coalesce(p_metadata->>'theme','');
  content_type text:=coalesce(p_metadata->>'content_type','');
  rarity text:=coalesce(p_metadata->>'rarity','');
begin
  faith:=0; favor:=0;

  if p_religion_slug='path_of_light' then
    if p_event_type='settlement_quest_completed' then
      faith:=case theme when 'protection' then 10 when 'general' then 5 else 3 end;
    elsif p_event_type='support_action' then faith:=2;
    elsif p_event_type='guard_action' then faith:=1;
    elsif p_event_type='party_dungeon_completed' then faith:=10; favor:=1;
    end if;

  elsif p_religion_slug='old_roots' then
    if p_event_type='settlement_quest_completed' then
      faith:=case theme when 'nature' then 10 when 'general' then 5 else 2 end;
    elsif p_event_type='sector_discovered' and content_type='wilderness' then faith:=4;
    elsif p_event_type='wilderness_expedition_completed' then faith:=10;
    elsif p_event_type='hunting_started' then faith:=-20; favor:=-10;
    elsif p_event_type='hunting_kill' then faith:=-30; favor:=-15;
    end if;

  elsif p_religion_slug='star_covenant' then
    if p_event_type='settlement_quest_completed' then
      faith:=case when theme in ('research','arcane') then 10 when theme='general' then 5 else 2 end;
    elsif p_event_type='spell_learned' then faith:=15; favor:=1;
    elsif p_event_type='spell_cast' then faith:=2;
    elsif p_event_type='sector_discovered' then faith:=2;
    end if;

  elsif p_religion_slug='abyss' then
    if p_event_type='settlement_quest_completed' then
      faith:=case theme when 'combat' then 10 when 'general' then 5 else 2 end;
    elsif p_event_type='dungeon_completed' then faith:=10;
    elsif p_event_type='event_boss_victory' then faith:=15; favor:=2;
    elsif p_event_type='item_sacrificed' then
      faith:=case rarity
        when 'rare' then 8
        when 'epic' then 12
        when 'legendary' then 18
        when 'unique' then 20
        else 0
      end;
      favor:=case rarity
        when 'rare' then 1
        when 'epic' then 2
        when 'legendary' then 3
        when 'unique' then 4
        else 0
      end;
    end if;
  end if;

  return next;
end;
$$;

revoke all on function private.religion_event_reward(text,text,jsonb)
from public,anon,authenticated;

create or replace function private.record_religion_event(
  p_character_id uuid,p_event_type text,p_source_key text,p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path=pg_catalog,public,private
as $$
declare
  v_religion text;
  v_base_faith integer:=0;
  v_base_favor integer:=0;
  v_actual_faith integer:=0;
  v_cap integer:=60;
  v_earned_today integer:=0;
  v_oath_id uuid;
  v_oath_definition_id uuid;
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
  v_oath_weekly_earned integer:=0;
  v_oath_faith_granted integer:=0;
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
  from private.religion_event_reward(
    v_religion,p_event_type,coalesce(p_metadata,'{}'::jsonb)
  ) r;

  v_base_faith:=coalesce(v_base_faith,0);
  v_base_favor:=coalesce(v_base_favor,0);

  select faith_daily_cap into v_cap
  from public.religion_definitions
  where slug=v_religion;
  v_cap:=coalesce(v_cap,60);

  if v_base_faith>0 then
    select coalesce(sum(greatest(faith_delta,0)),0)::integer
    into v_earned_today
    from public.religion_faith_events
    where character_id=p_character_id
      and religion_slug=v_religion
      and event_type<>'oath_completed'
      and created_at>=date_trunc('day',now());

    v_actual_faith:=least(v_base_faith,greatest(v_cap-v_earned_today,0));
  else
    v_actual_faith:=v_base_faith;
  end if;

  insert into public.religion_faith_events(
    character_id,religion_slug,event_type,source_key,faith_delta,favor_delta,metadata
  )
  values(
    p_character_id,v_religion,p_event_type,p_source_key,
    v_actual_faith,v_base_favor,coalesce(p_metadata,'{}'::jsonb)
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
    o.id,o.oath_definition_id,o.progress_count,
    d.success_event_type,d.success_metadata,d.target_count,
    d.failure_event_type,d.failure_metadata,d.faith_reward,d.favor_reward,
    d.failure_faith_penalty,d.failure_favor_penalty
  into
    v_oath_id,v_oath_definition_id,v_oath_progress,
    v_success_event,v_success_meta,v_target,
    v_failure_event,v_failure_meta,v_faith_reward,v_favor_reward,
    v_failure_faith,v_failure_favor
  from public.character_religion_oaths o
  join public.religion_oath_definitions d on d.id=o.oath_definition_id
  where o.character_id=p_character_id
    and o.status='active'
    and o.religion_slug=v_religion
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

        select coalesce(sum(greatest(faith_delta,0)),0)::integer
        into v_oath_weekly_earned
        from public.religion_faith_events
        where character_id=p_character_id
          and religion_slug=v_religion
          and event_type='oath_completed'
          and created_at>=now()-interval '7 days';

        v_oath_faith_granted:=least(
          v_faith_reward,
          greatest(100-v_oath_weekly_earned,0)
        );

        insert into public.religion_faith_events(
          character_id,religion_slug,event_type,source_key,
          faith_delta,favor_delta,metadata
        )
        values(
          p_character_id,v_religion,'oath_completed',
          'oath_completed:'||v_oath_id::text,
          v_oath_faith_granted,v_favor_reward,
          jsonb_build_object(
            'oath_assignment_id',v_oath_id,
            'oath_definition_id',v_oath_definition_id,
            'weekly_cap',100
          )
        )
        on conflict(character_id,event_type,source_key) do nothing;

        update public.character_religion_progress
        set faith_points=least(2200,faith_points+v_oath_faith_granted),
            favor=least(100,favor+v_favor_reward),
            updated_at=now()
        where character_id=p_character_id and religion_slug=v_religion;
      end if;
    end if;
  end if;

  perform private.grant_religion_level10_reward(p_character_id,v_religion);
end;
$$;

revoke all on function private.record_religion_event(uuid,text,text,jsonb)
from public,anon,authenticated;
