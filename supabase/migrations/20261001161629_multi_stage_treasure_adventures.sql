
alter table public.character_treasure_hunts
  add column if not exists hunt_kind text not null default 'cache',
  add column if not exists stage smallint not null default 1,
  add column if not exists total_stages smallint not null default 1,
  add column if not exists risk_level smallint not null default 0,
  add column if not exists clue_text text,
  add column if not exists last_stage_at timestamptz;

alter table public.character_treasure_hunts
  drop constraint if exists character_treasure_hunts_hunt_kind_check;
alter table public.character_treasure_hunts
  add constraint character_treasure_hunts_hunt_kind_check
  check (hunt_kind in ('cache','lost_trail','guarded_vault','cursed_route'));

alter table public.character_treasure_hunts
  drop constraint if exists character_treasure_hunts_stage_check;
alter table public.character_treasure_hunts
  add constraint character_treasure_hunts_stage_check
  check (stage between 1 and total_stages and total_stages between 1 and 3);

alter table public.character_treasure_hunts
  drop constraint if exists character_treasure_hunts_risk_check;
alter table public.character_treasure_hunts
  add constraint character_treasure_hunts_risk_check
  check (risk_level between 0 and 3);

alter table public.sector_expeditions
  add column if not exists treasure_stage smallint;

update public.character_treasure_hunts
set clue_text=coalesce(
  clue_text,
  'На карте отмечен знакомый сектор. Следуй к отметке и проверь тайник.'
)
where clue_text is null;

update public.sector_expeditions
set treasure_stage=1
where treasure_hunt_id is not null and treasure_stage is null;

create index if not exists sector_expeditions_treasure_stage_idx
on public.sector_expeditions(treasure_hunt_id,treasure_stage,status)
where treasure_hunt_id is not null;

create or replace function private.treasure_hunt_label(p_kind text)
returns text
language sql
immutable
set search_path to ''
as $$
  select case p_kind
    when 'lost_trail' then 'Потерянный след'
    when 'guarded_vault' then 'Охраняемое хранилище'
    when 'cursed_route' then 'Проклятый маршрут'
    else 'Скрытый тайник'
  end;
$$;

create or replace function private.treasure_hunt_clue(
  p_kind text,
  p_stage integer,
  p_total integer,
  p_target_name text
)
returns text
language sql
immutable
set search_path to ''
as $$
  select case p_kind
    when 'lost_trail' then
      case
        when p_stage=1 then 'Чернила почти стёрлись. Первая пометка ведёт в «'||p_target_name||'», где должен остаться следующий ориентир.'
        else 'След восстановлен. Последняя пометка указывает на «'||p_target_name||'». Там спрятан тайник.'
      end
    when 'guarded_vault' then
      case
        when p_stage=1 then 'Золотая печать скрывает два ориентира. Сначала проверь «'||p_target_name||'» и найди знак хранителей.'
        else 'Знак хранителей найден. Хранилище должно быть рядом с «'||p_target_name||'».'
      end
    when 'cursed_route' then
      case
        when p_stage=1 then 'На полях карты проступают тёмные символы. Первый след ведёт в «'||p_target_name||'».'
        when p_stage=2 then 'Символы изменились после первого перехода. Новый след указывает на «'||p_target_name||'».'
        else 'Последняя метка больше не двигается. Проклятый тайник находится у «'||p_target_name||'».'
      end
    else
      'Крест на карте указывает на «'||p_target_name||'». Соверши отдельный поход и проверь место.'
  end;
$$;

create or replace function private.pick_treasure_sector(
  p_character_id uuid,
  p_exclude_sector smallint default null
)
returns table(sector_id smallint,target_name text)
language sql
volatile
security definer
set search_path to 'pg_catalog','public','private'
as $$
  with candidates as (
    select
      ms.id::smallint as sector_id,
      coalesce(sd.title,'Сектор '||ms.grid_col||':'||ms.grid_row) as target_name,
      case when p_exclude_sector is not null and ms.id=p_exclude_sector then 1 else 0 end as same_sector
    from public.character_sector_discoveries cd
    join public.map_sectors ms on ms.id=cd.sector_id
    left join public.sector_details sd on sd.sector_id=cd.sector_id
    where cd.character_id=p_character_id
      and coalesce(sd.content_type,'unassigned')<>'settlement'
  )
  select c.sector_id,c.target_name
  from candidates c
  order by c.same_sector,random()
  limit 1;
$$;

create or replace function public.activate_treasure_map(
  p_character_id uuid,
  p_character_item_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  caller uuid:=auth.uid();
  item_row public.character_items;
  def public.item_definitions;
  target_sector smallint;
  target_name text;
  hunt_id uuid;
  tier smallint:=1;
  kind_value text:='cache';
  stages_value smallint:=1;
  risk_value smallint:=0;
  clue_value text;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  if exists(
    select 1 from public.character_treasure_hunts h
    where h.character_id=p_character_id and h.status='active'
  ) then raise exception 'TREASURE_HUNT_ALREADY_ACTIVE'; end if;

  select ci.* into item_row
  from public.character_items ci
  where ci.id=p_character_item_id
    and ci.character_id=p_character_id
    and ci.death_spirit_id is null
  for update;

  if item_row.id is null then raise exception 'TREASURE_MAP_ITEM_NOT_FOUND'; end if;

  select * into def
  from public.item_definitions
  where id=item_row.item_definition_id;

  if def.slug not in ('treasure_map_faded','treasure_map_royal') then
    raise exception 'ITEM_IS_NOT_TREASURE_MAP';
  end if;

  tier:=case when def.slug='treasure_map_royal' then 2 else 1 end;

  if def.slug='treasure_map_royal' then
    if random()<0.50 then
      kind_value:='guarded_vault';
      stages_value:=2;
      risk_value:=2;
    else
      kind_value:='cursed_route';
      stages_value:=3;
      risk_value:=3;
    end if;
  else
    if random()<0.65 then
      kind_value:='cache';
      stages_value:=1;
      risk_value:=0;
    else
      kind_value:='lost_trail';
      stages_value:=2;
      risk_value:=1;
    end if;
  end if;

  select s.sector_id,s.target_name
  into target_sector,target_name
  from private.pick_treasure_sector(p_character_id,null) s;

  if target_sector is null then
    raise exception 'NO_DISCOVERED_SECTOR_FOR_TREASURE_MAP';
  end if;

  clue_value:=private.treasure_hunt_clue(
    kind_value,1,stages_value,target_name
  );

  if item_row.quantity>1 then
    update public.character_items
    set quantity=quantity-1
    where id=item_row.id;
  else
    delete from public.character_items where id=item_row.id;
  end if;

  insert into public.character_treasure_hunts(
    character_id,map_item_slug,target_sector_id,target_name,reward_tier,
    hunt_kind,stage,total_stages,risk_level,clue_text,last_stage_at
  )
  values(
    p_character_id,def.slug,target_sector,target_name,tier,
    kind_value,1,stages_value,risk_value,clue_value,now()
  )
  returning id into hunt_id;

  perform private.record_discovery(
    p_character_id,'treasure_map','active_'||hunt_id::text,
    private.treasure_hunt_label(kind_value),
    clue_value,
    jsonb_build_object(
      'target_sector_id',target_sector,
      'reward_tier',tier,
      'hunt_kind',kind_value,
      'stage',1,
      'total_stages',stages_value,
      'risk_level',risk_value
    )
  );

  return jsonb_build_object(
    'hunt_id',hunt_id,
    'target_sector_id',target_sector,
    'target_name',target_name,
    'reward_tier',tier,
    'hunt_kind',kind_value,
    'stage',1,
    'total_stages',stages_value,
    'risk_level',risk_value,
    'clue_text',clue_value,
    'hunt_name',private.treasure_hunt_label(kind_value)
  );
end;
$$;

create or replace function private.complete_expired_treasure_expeditions(p_character_id uuid)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  caller_id uuid:=auth.uid();
  completed_count integer:=0;
  completed_row record;
  hunt_row public.character_treasure_hunts;
  next_sector smallint;
  next_name text;
  next_stage smallint;
  next_clue text;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id
      and (c.owner_user_id=caller_id or private.is_gm(caller_id))
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  for completed_row in
    update public.sector_expeditions e
    set status='completed',completed_at=now()
    where e.character_id=p_character_id
      and e.treasure_hunt_id is not null
      and e.status='active'
      and e.ends_at<=now()
    returning e.id,e.treasure_hunt_id,e.treasure_stage,e.sector_id
  loop
    completed_count:=completed_count+1;

    select * into hunt_row
    from public.character_treasure_hunts h
    where h.id=completed_row.treasure_hunt_id
    for update;

    if hunt_row.id is null or hunt_row.status<>'active' then
      continue;
    end if;

    if coalesce(completed_row.treasure_stage,1)=hunt_row.stage
       and hunt_row.stage<hunt_row.total_stages
    then
      next_stage:=hunt_row.stage+1;

      select s.sector_id,s.target_name
      into next_sector,next_name
      from private.pick_treasure_sector(
        hunt_row.character_id,
        hunt_row.target_sector_id
      ) s;

      if next_sector is null then
        next_sector:=hunt_row.target_sector_id;
        next_name:=hunt_row.target_name;
      end if;

      next_clue:=private.treasure_hunt_clue(
        hunt_row.hunt_kind,
        next_stage,
        hunt_row.total_stages,
        next_name
      );

      update public.character_treasure_hunts
      set stage=next_stage,
          target_sector_id=next_sector,
          target_name=next_name,
          clue_text=next_clue,
          last_stage_at=now()
      where id=hunt_row.id;

      perform private.record_discovery(
        hunt_row.character_id,
        'treasure_map',
        'stage_'||hunt_row.id::text||'_'||next_stage::text,
        private.treasure_hunt_label(hunt_row.hunt_kind)||' · этап '||next_stage::text,
        next_clue,
        jsonb_build_object(
          'hunt_id',hunt_row.id,
          'stage',next_stage,
          'total_stages',hunt_row.total_stages,
          'target_sector_id',next_sector
        )
      );
    end if;
  end loop;

  return completed_count;
end;
$$;

create or replace function public.start_treasure_hunt_expedition(p_hunt_id uuid)
returns public.sector_expeditions
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  caller_id uuid:=auth.uid();
  owner_character_id uuid;
  hunt public.character_treasure_hunts;
  expedition public.sector_expeditions;
  duration_seconds integer;
  base_seconds integer;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;

  select h.character_id
  into owner_character_id
  from public.character_treasure_hunts h
  join public.characters c on c.id=h.character_id
  where h.id=p_hunt_id and c.owner_user_id=caller_id;

  if owner_character_id is null then
    raise exception 'TREASURE_HUNT_NOT_FOUND';
  end if;

  perform private.complete_expired_sector_expeditions(owner_character_id);
  perform private.complete_expired_site_actions(owner_character_id);

  select h.*
  into hunt
  from public.character_treasure_hunts h
  where h.id=p_hunt_id
  for update;

  if hunt.id is null then raise exception 'TREASURE_HUNT_NOT_FOUND'; end if;
  if hunt.status<>'active' then raise exception 'TREASURE_HUNT_NOT_ACTIVE'; end if;

  select e.* into expedition
  from public.sector_expeditions e
  where e.treasure_hunt_id=hunt.id
    and e.treasure_stage=hunt.stage
    and e.status='active'
  order by e.started_at desc
  limit 1;

  if expedition.id is not null then return expedition; end if;

  if exists(
    select 1
    from public.sector_expeditions e
    where e.treasure_hunt_id=hunt.id
      and coalesce(e.treasure_stage,1)=hunt.stage
      and e.status='completed'
  ) then raise exception 'TREASURE_HUNT_ALREADY_VISITED'; end if;

  if exists(
    select 1 from public.sector_expeditions e
    where e.character_id=hunt.character_id
      and e.status in ('active','awaiting_event')
  ) then raise exception 'EXPEDITION_ALREADY_ACTIVE'; end if;

  if exists(
    select 1 from public.sector_site_actions a
    where a.character_id=hunt.character_id and a.status='active'
  ) then raise exception 'SITE_ACTION_ALREADY_ACTIVE'; end if;

  if exists(
    select 1 from public.dungeon_runs r
    where r.character_id=hunt.character_id and r.status='active'
  ) then raise exception 'DUNGEON_RUN_ALREADY_ACTIVE'; end if;

  if exists(
    select 1 from public.combat_encounters ce
    where ce.character_id=hunt.character_id and ce.status='active'
  ) then raise exception 'COMBAT_ALREADY_ACTIVE'; end if;

  if exists(
    select 1
    from public.party_dungeon_runs pr
    join public.party_dungeon_run_members prm on prm.run_id=pr.id
    where prm.character_id=hunt.character_id and pr.status='active'
  ) then raise exception 'PARTY_DUNGEON_ACTIVE'; end if;

  if not exists(
    select 1 from public.character_sector_discoveries d
    where d.character_id=hunt.character_id
      and d.sector_id=hunt.target_sector_id
  ) then raise exception 'TREASURE_TARGET_NOT_DISCOVERED'; end if;

  base_seconds:=case hunt.hunt_kind
    when 'lost_trail' then 9000
    when 'guarded_vault' then 10800
    when 'cursed_route' then 9000
    else 14400
  end;

  duration_seconds:=private.character_exploration_duration_seconds(
    hunt.character_id,base_seconds
  );

  insert into public.sector_expeditions(
    character_id,sector_id,ends_at,treasure_hunt_id,treasure_stage
  )
  values(
    hunt.character_id,hunt.target_sector_id,
    now()+make_interval(secs=>duration_seconds),
    hunt.id,hunt.stage
  )
  returning * into expedition;

  return expedition;
end;
$$;

create or replace function public.claim_treasure_hunt(p_hunt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  caller uuid:=auth.uid();
  h public.character_treasure_hunts;
  gold_reward integer;
  xp_reward integer;
  bonus_slug text:=null;
  bonus_name text:=null;
  material_slug text:=null;
  material_name text:=null;
  material_quantity integer:=1;
  bonus_chance integer:=24;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  select h0.* into h
  from public.character_treasure_hunts h0
  join public.characters c on c.id=h0.character_id
  where h0.id=p_hunt_id and c.owner_user_id=caller
  for update of h0;

  if h.id is null then raise exception 'TREASURE_HUNT_NOT_FOUND'; end if;
  if h.status<>'active' then raise exception 'TREASURE_HUNT_NOT_ACTIVE'; end if;
  if h.stage<h.total_stages then raise exception 'TREASURE_HUNT_HAS_MORE_STAGES'; end if;

  if not exists(
    select 1
    from public.sector_expeditions e
    where e.treasure_hunt_id=h.id
      and coalesce(e.treasure_stage,1)=h.stage
      and e.status='completed'
  ) then raise exception 'TREASURE_SECTOR_NOT_VISITED_AFTER_MAP'; end if;

  gold_reward:=case h.hunt_kind
    when 'cursed_route' then 80+floor(random()*61)::integer
    when 'guarded_vault' then 110+floor(random()*61)::integer
    when 'lost_trail' then 40+floor(random()*36)::integer
    else 50+floor(random()*41)::integer
  end;

  xp_reward:=case h.hunt_kind
    when 'cursed_route' then 180
    when 'guarded_vault' then 130
    when 'lost_trail' then 70
    else 45
  end;

  bonus_chance:=case h.hunt_kind
    when 'cursed_route' then 65
    when 'guarded_vault' then 55
    when 'lost_trail' then 32
    else 24
  end;

  update public.character_progress
  set gold=gold+gold_reward,
      experience=experience+xp_reward,
      updated_at=now()
  where character_id=h.character_id;

  perform private.grant_item_slug(
    h.character_id,
    'ancient_coin_cache',
    case when h.reward_tier>=2 then 2 else 1 end
  );

  if h.hunt_kind='lost_trail' then
    material_slug:='smithing_scrap_beta';
    material_quantity:=2;
  elsif h.hunt_kind='guarded_vault' then
    select x.slug into material_slug
    from (values
      ('deep_pearl_beta'),
      ('storm_core_beta'),
      ('frost_crystal_beta'),
      ('sun_glass_beta')
    ) x(slug)
    join public.item_definitions d on d.slug=x.slug
    order by random()
    limit 1;
  elsif h.hunt_kind='cursed_route' then
    select x.slug into material_slug
    from (values
      ('ancient_relic_fragment_beta'),
      ('deep_pearl_beta'),
      ('storm_core_beta'),
      ('spirit_ash_beta')
    ) x(slug)
    join public.item_definitions d on d.slug=x.slug
    order by random()
    limit 1;
  else
    if random()<0.40 then
      select x.slug into material_slug
      from (values
        ('minor_healing_potion_beta'),
        ('minor_mana_potion_beta'),
        ('smithing_scrap_beta')
      ) x(slug)
      join public.item_definitions d on d.slug=x.slug
      order by random()
      limit 1;
    end if;
  end if;

  if material_slug is not null then
    perform private.grant_item_slug(h.character_id,material_slug,material_quantity);
    select d.name into material_name
    from public.item_definitions d
    where d.slug=material_slug;
  end if;

  if random()*100<bonus_chance then
    select x.slug into bonus_slug
    from (values
      ('cursed_glass_ring'),
      ('blessed_wayfarer_charm'),
      ('cursed_bone_mask'),
      ('blessed_moonthread_cloak'),
      ('black_mirror_talisman'),
      ('oathbreaker_greaves')
    ) x(slug)
    join public.item_definitions d on d.slug=x.slug
    where d.required_level<=(
      select level+1 from public.character_progress
      where character_id=h.character_id
    )
    order by random()
    limit 1;

    if bonus_slug is not null then
      perform private.grant_item_slug(h.character_id,bonus_slug,1);
      select name into bonus_name
      from public.item_definitions
      where slug=bonus_slug;
    end if;
  end if;

  update public.character_treasure_hunts
  set status='claimed',claimed_at=now()
  where id=h.id;

  perform private.record_discovery(
    h.character_id,'treasure','cache_'||h.id::text,
    private.treasure_hunt_label(h.hunt_kind),
    'Маршрут завершён. Тайник найден в районе «'||h.target_name||'».',
    jsonb_build_object(
      'gold',gold_reward,
      'experience',xp_reward,
      'bonus_item',bonus_name,
      'material',material_name,
      'hunt_kind',h.hunt_kind,
      'stages',h.total_stages
    )
  );

  return jsonb_build_object(
    'gold',gold_reward,
    'experience',xp_reward,
    'bonus_item',bonus_name,
    'material_item',material_name,
    'material_quantity',case when material_slug is null then 0 else material_quantity end,
    'target_name',h.target_name,
    'hunt_kind',h.hunt_kind,
    'hunt_name',private.treasure_hunt_label(h.hunt_kind),
    'stages',h.total_stages
  );
end;
$$;

create or replace function public.get_world_pulse_v2(p_character_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  base_data jsonb;
  hunts_data jsonb:='[]'::jsonb;
begin
  base_data:=public.get_world_pulse(p_character_id);

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',h.id,
        'target_sector_id',h.target_sector_id,
        'target_name',h.target_name,
        'reward_tier',h.reward_tier,
        'status',h.status,
        'created_at',h.created_at,
        'hunt_kind',h.hunt_kind,
        'hunt_name',private.treasure_hunt_label(h.hunt_kind),
        'stage',h.stage,
        'total_stages',h.total_stages,
        'risk_level',h.risk_level,
        'clue_text',h.clue_text,
        'ready',(
          h.stage=h.total_stages
          and exists(
            select 1
            from public.sector_expeditions e
            where e.treasure_hunt_id=h.id
              and coalesce(e.treasure_stage,1)=h.stage
              and e.status='completed'
          )
        )
      )
      order by h.created_at desc
    ),
    '[]'::jsonb
  )
  into hunts_data
  from public.character_treasure_hunts h
  where h.character_id=p_character_id and h.status='active';

  return jsonb_set(base_data,'{treasure_hunts}',hunts_data,true);
end;
$$;

create or replace function public.get_character_world_markers(p_character_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  caller_id uuid:=auth.uid();
  merchant_sector smallint;
  marker_data jsonb:='[]'::jsonb;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id
      and (c.owner_user_id=caller_id or private.is_gm(caller_id))
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  merchant_sector:=private.current_wandering_merchant_sector(p_character_id);

  select coalesce(jsonb_agg(x.payload order by x.priority,x.kind,x.id),'[]'::jsonb)
  into marker_data
  from (
    select
      10 as priority,'treasure'::text as kind,h.id::text as id,
      jsonb_build_object(
        'id',h.id::text,
        'kind','treasure',
        'sector_id',h.target_sector_id,
        'title',private.treasure_hunt_label(h.hunt_kind),
        'detail',coalesce(h.clue_text,h.target_name),
        'stage',h.stage,
        'total_stages',h.total_stages,
        'risk_level',h.risk_level
      ) as payload
    from public.character_treasure_hunts h
    where h.character_id=p_character_id and h.status='active'

    union all

    select
      20,'camp',c.character_id::text,
      jsonb_build_object(
        'id',c.character_id::text,'kind','camp','sector_id',c.sector_id,
        'title','Лагерь',
        'detail',case c.specialization
          when 'scout' then 'Разведывательный'
          when 'hunter' then 'Охотничий'
          when 'war' then 'Военный'
          else 'Торговый'
        end,
        'ends_at',c.expires_at
      )
    from public.character_camps c
    where c.character_id=p_character_id and c.expires_at>now()

    union all

    select
      30,'merchant','daily',
      jsonb_build_object(
        'id','daily','kind','merchant','sector_id',merchant_sector,
        'title','Странствующий торговец','detail','Сегодняшняя стоянка'
      )
    where merchant_sector is not null

    union all

    select
      40,'quest',q.id::text,
      jsonb_build_object(
        'id',q.id::text,'kind','quest','sector_id',d.sector_id,
        'title',d.title,'detail','Активное поручение'
      )
    from public.character_settlement_quests q
    join public.settlement_quest_definitions d on d.id=q.quest_definition_id
    where q.character_id=p_character_id and q.status='active'
  ) x;

  return marker_data;
end;
$$;

revoke all on function public.get_world_pulse_v2(uuid) from public,anon;
grant execute on function public.get_world_pulse_v2(uuid) to authenticated,service_role;

revoke all on function private.treasure_hunt_label(text) from public,anon,authenticated;
revoke all on function private.treasure_hunt_clue(text,integer,integer,text) from public,anon,authenticated;
revoke all on function private.pick_treasure_sector(uuid,smallint) from public,anon,authenticated;

