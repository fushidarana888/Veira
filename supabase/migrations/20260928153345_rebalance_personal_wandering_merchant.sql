-- Synced from live Supabase migration 20260928153345 (rebalance_personal_wandering_merchant)


-- Rebalance the wandering merchant into a personal, weighted daily rotation.

update public.wandering_merchant_catalog c
set
  weight = case d.slug
    when 'treasure_map_royal' then 1
    when 'treasure_map_faded' then 3
    else 10
  end,
  offer_price = case d.slug
    when 'cast_scroll_sand_veil' then 85
    when 'cast_scroll_weakening_spark' then 90
    when 'cast_scroll_venom_spore' then 125
    when 'cast_scroll_healing_spark' then 145
    when 'cast_scroll_combat_impulse' then 220
    when 'cast_scroll_moon_frost' then 270
    when 'treasure_map_faded' then 140
    when 'treasure_map_royal' then 420
    else c.offer_price
  end
from public.item_definitions d
where d.id=c.item_definition_id;

create or replace function private.current_wandering_merchant_sector(
  p_character_id uuid
) returns smallint
language sql
stable
security definer
set search_path='pg_catalog','public','private'
as $$
  select sd.sector_id
  from public.character_sector_discoveries cd
  join public.sector_details sd
    on sd.sector_id=cd.sector_id
   and sd.content_type='settlement'
  where cd.character_id=p_character_id
  order by md5(
    current_date::text||':'||p_character_id::text||':'||sd.sector_id::text
  )
  limit 1;
$$;

create or replace function private.current_wandering_merchant_offers(
  p_character_id uuid
) returns table(
  item_definition_id uuid,
  offer_price integer
)
language sql
stable
security definer
set search_path='pg_catalog','public','private'
as $$
  select c.item_definition_id,c.offer_price
  from public.wandering_merchant_catalog c
  join public.character_progress cp
    on cp.character_id=p_character_id
  where c.enabled
    and cp.level between c.min_level and c.max_level
  order by
    (
      -ln(
        (
          ((pg_catalog.hashtextextended(
            current_date::text||':'||p_character_id::text||':'||c.item_definition_id::text,
            0
          ) & 2147483647)::numeric + 1)
          / 2147483649.0
        )
      )
      / greatest(c.weight,1)
    ),
    c.item_definition_id
  limit 4;
$$;

create or replace function public.buy_wandering_merchant_item(
  p_character_id uuid,
  p_item_definition_id uuid
) returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  caller uuid:=auth.uid();
  cp public.character_progress;
  offer_price_value integer;
  offer_name text;
  merchant_sector smallint;
  purchases_used integer:=0;
  purchase_limit constant integer:=2;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  merchant_sector:=private.current_wandering_merchant_sector(p_character_id);
  if merchant_sector is null then raise exception 'WANDERING_MERCHANT_NOT_AVAILABLE'; end if;

  select * into cp
  from public.character_progress
  where character_id=p_character_id
  for update;

  if cp.character_id is null then raise exception 'CHARACTER_PROGRESS_NOT_FOUND'; end if;

  select count(*)::integer
  into purchases_used
  from public.wandering_merchant_purchases p
  where p.character_id=p_character_id
    and p.rotation_date=current_date;

  if purchases_used>=purchase_limit then
    raise exception 'WANDERING_DAILY_LIMIT_REACHED';
  end if;

  if not exists(
    select 1
    from private.current_wandering_merchant_offers(p_character_id) offered
    where offered.item_definition_id=p_item_definition_id
  ) then
    raise exception 'WANDERING_ITEM_NOT_OFFERED_TODAY';
  end if;

  if exists(
    select 1
    from public.wandering_merchant_purchases p
    where p.character_id=p_character_id
      and p.item_definition_id=p_item_definition_id
      and p.rotation_date=current_date
  ) then raise exception 'WANDERING_ITEM_ALREADY_BOUGHT'; end if;

  select o.offer_price,d.name
  into offer_price_value,offer_name
  from private.current_wandering_merchant_offers(p_character_id) o
  join public.item_definitions d on d.id=o.item_definition_id
  where o.item_definition_id=p_item_definition_id;

  if offer_price_value is null then raise exception 'WANDERING_ITEM_NOT_OFFERED'; end if;
  if cp.gold<offer_price_value then raise exception 'NOT_ENOUGH_GOLD'; end if;

  update public.character_progress
  set gold=gold-offer_price_value,
      updated_at=now()
  where character_id=p_character_id;

  perform private.grant_item_slug(
    p_character_id,
    (select slug from public.item_definitions where id=p_item_definition_id),
    1
  );

  insert into public.wandering_merchant_purchases(
    character_id,item_definition_id,rotation_date
  )
  values(p_character_id,p_item_definition_id,current_date);

  purchases_used:=purchases_used+1;

  return jsonb_build_object(
    'item_name',offer_name,
    'price',offer_price_value,
    'sector_id',merchant_sector,
    'purchases_used',purchases_used,
    'purchase_limit',purchase_limit,
    'purchases_remaining',greatest(0,purchase_limit-purchases_used)
  );
end;
$$;

create or replace function public.get_world_pulse(
  p_character_id uuid
) returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  caller uuid:=auth.uid();
  lvl integer:=1;
  merchant_sector smallint;
  merchant_name text;
  merchant_purchases_used integer:=0;
  merchant_purchase_limit constant integer:=2;
  active_run public.dungeon_runs;
  modifier_data jsonb:='null'::jsonb;
  pending_event jsonb:='null'::jsonb;
  rumors_data jsonb:='[]'::jsonb;
  merchant_offers jsonb:='[]'::jsonb;
  maps_data jsonb:='[]'::jsonb;
  hunts_data jsonb:='[]'::jsonb;
  discoveries_data jsonb:='[]'::jsonb;
  trophies_data jsonb:='[]'::jsonb;
  lost_spirits_data jsonb:='[]'::jsonb;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  if not private.is_gm(caller)
     and not exists(
       select 1 from public.characters c
       where c.id=p_character_id and c.owner_user_id=caller
     )
  then raise exception 'CHARACTER_NOT_OWNED'; end if;

  perform private.expire_death_spirits();

  select coalesce(level,1)
  into lvl
  from public.character_progress
  where character_id=p_character_id;

  select *
  into active_run
  from public.dungeon_runs
  where character_id=p_character_id
    and status='active'
    and event_boss_id is null
    and hunting_attempt_id is null
  order by created_at desc
  limit 1;

  if active_run.id is not null
     and active_run.modifier_slug is not null
  then
    select jsonb_build_object(
      'slug',d.slug,
      'name',d.name,
      'description',d.description,
      'theme',d.theme,
      'enemy_hp_percent',d.enemy_hp_percent,
      'enemy_attack_percent',d.enemy_attack_percent,
      'enemy_defense_percent',d.enemy_defense_percent,
      'reward_gold_percent',d.reward_gold_percent,
      'reward_xp_percent',d.reward_xp_percent
    )
    into modifier_data
    from public.dungeon_modifier_definitions d
    where d.slug=active_run.modifier_slug;
  end if;

  if active_run.id is not null then
    select jsonb_build_object(
      'id',e.id,
      'run_id',e.run_id,
      'event_slug',e.event_slug,
      'name',d.name,
      'description',d.description,
      'choices',e.choices,
      'room_index',e.room_index
    )
    into pending_event
    from public.dungeon_run_events e
    join public.dungeon_event_definitions d on d.slug=e.event_slug
    where e.run_id=active_run.id
      and e.status='pending'
    order by e.created_at desc
    limit 1;
  end if;

  select coalesce(
    jsonb_agg(jsonb_build_object('slug',r.slug,'title',r.title,'body',r.body)),
    '[]'::jsonb
  )
  into rumors_data
  from (
    select wr.*
    from public.world_rumors wr
    where wr.enabled
      and wr.min_level<=lvl
    order by md5(current_date::text||':'||p_character_id::text||':'||wr.slug)
    limit 3
  ) r;

  merchant_sector:=private.current_wandering_merchant_sector(p_character_id);

  select count(*)::integer
  into merchant_purchases_used
  from public.wandering_merchant_purchases p
  where p.character_id=p_character_id
    and p.rotation_date=current_date;

  if merchant_sector is not null then
    select coalesce(sd.title,'Сектор '||ms.grid_col||':'||ms.grid_row)
    into merchant_name
    from public.map_sectors ms
    left join public.sector_details sd on sd.sector_id=ms.id
    where ms.id=merchant_sector;

    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'item_definition_id',o.id,
          'slug',o.slug,
          'name',o.name,
          'description',o.description,
          'rarity',o.rarity::text,
          'price',o.offer_price,
          'bought',o.bought
        )
        order by o.sort_order
      ),
      '[]'::jsonb
    )
    into merchant_offers
    from (
      select
        d.id,d.slug,d.name,d.description,d.rarity,mo.offer_price,
        row_number() over () as sort_order,
        exists(
          select 1 from public.wandering_merchant_purchases p
          where p.character_id=p_character_id
            and p.item_definition_id=d.id
            and p.rotation_date=current_date
        ) bought
      from private.current_wandering_merchant_offers(p_character_id) mo
      join public.item_definitions d on d.id=mo.item_definition_id
    ) o;
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'character_item_id',ci.id,
        'slug',d.slug,
        'name',d.name,
        'quantity',ci.quantity
      )
      order by d.slug
    ),
    '[]'::jsonb
  )
  into maps_data
  from public.character_items ci
  join public.item_definitions d on d.id=ci.item_definition_id
  where ci.character_id=p_character_id
    and ci.death_spirit_id is null
    and d.slug in ('treasure_map_faded','treasure_map_royal');

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',h.id,
        'target_sector_id',h.target_sector_id,
        'target_name',h.target_name,
        'reward_tier',h.reward_tier,
        'status',h.status,
        'created_at',h.created_at,
        'ready',exists(
          select 1
          from public.sector_expeditions e
          where e.character_id=h.character_id
            and e.sector_id=h.target_sector_id
            and e.status='completed'
            and coalesce(e.completed_at,e.created_at)>h.created_at
        )
      )
      order by h.created_at desc
    ),
    '[]'::jsonb
  )
  into hunts_data
  from public.character_treasure_hunts h
  where h.character_id=p_character_id
    and h.status='active';

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',ds.id,
        'sector_id',ds.sector_id,
        'created_at',ds.created_at,
        'expires_at',ds.expires_at,
        'item_name',coalesce(idf.name,'Неизвестная вещь'),
        'character_item_id',ci.id,
        'anomaly',ds.snapshot->>'anomaly',
        'anomaly_name',ds.snapshot->>'anomaly_name'
      )
      order by ds.expires_at
    ),
    '[]'::jsonb
  )
  into lost_spirits_data
  from private.death_spirits ds
  left join public.character_items ci on ci.death_spirit_id=ds.id
  left join public.item_definitions idf on idf.id=ci.item_definition_id
  where ds.owner_character_id=p_character_id
    and ds.status='active'
    and ds.expires_at>now();

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'slug',i.slug,
        'name',i.name,
        'description',i.description,
        'quantity',ci.quantity
      )
      order by i.name
    ),
    '[]'::jsonb
  )
  into trophies_data
  from public.character_items ci
  join public.item_definitions i on i.id=ci.item_definition_id
  where ci.character_id=p_character_id
    and ci.death_spirit_id is null
    and i.slug like 'trophy_%';

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'category',d.category,
        'slug',d.slug,
        'title',d.title,
        'description',d.description,
        'times_seen',d.times_seen,
        'first_seen_at',d.first_seen_at,
        'last_seen_at',d.last_seen_at
      )
      order by d.last_seen_at desc
    ),
    '[]'::jsonb
  )
  into discoveries_data
  from (
    select *
    from public.character_discoveries
    where character_id=p_character_id
    order by last_seen_at desc
    limit 50
  ) d;

  return jsonb_build_object(
    'merchant',
      case
        when merchant_sector is null then null
        else jsonb_build_object(
          'sector_id',merchant_sector,
          'location_name',merchant_name,
          'offers',merchant_offers,
          'purchase_limit',merchant_purchase_limit,
          'purchases_used',merchant_purchases_used,
          'purchases_remaining',greatest(0,merchant_purchase_limit-merchant_purchases_used),
          'rotation_date',current_date
        )
      end,
    'rumors',rumors_data,
    'maps',maps_data,
    'treasure_hunts',hunts_data,
    'discoveries',discoveries_data,
    'trophies',trophies_data,
    'lost_spirits',lost_spirits_data,
    'discovery_count',(
      select count(*)
      from public.character_discoveries
      where character_id=p_character_id
    ),
    'active_dungeon',
      case
        when active_run.id is null then null
        else jsonb_build_object(
          'run_id',active_run.id,
          'sector_id',active_run.sector_id,
          'modifier',modifier_data,
          'pending_event',pending_event,
          'elite_room_ready',active_run.next_room_elite
        )
      end
  );
end;
$$;

revoke all on function private.current_wandering_merchant_sector(uuid) from public;
revoke all on function private.current_wandering_merchant_offers(uuid) from public;

revoke execute on function public.get_world_pulse(uuid) from anon, public;
grant execute on function public.get_world_pulse(uuid) to authenticated;

revoke execute on function public.buy_wandering_merchant_item(uuid,uuid) from anon, public;
grant execute on function public.buy_wandering_merchant_item(uuid,uuid) to authenticated;

