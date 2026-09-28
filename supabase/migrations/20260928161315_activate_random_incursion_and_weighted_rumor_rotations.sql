-- Synced from live Supabase migration 20260928161315 (activate_random_incursion_and_weighted_rumor_rotations)

CREATE OR REPLACE FUNCTION public.get_visible_sector_incursions(p_character_id uuid)
 RETURNS TABLE(event_id uuid, name text, description text, sector_id smallint, grid_col smallint, grid_row smallint, ends_at timestamp with time zone, enemy_level integer, enemy_hp integer, enemy_attack integer, enemy_defense integer, clear_count integer, clear_target integer, contributed boolean, party_id uuid, party_member_count integer, is_party_leader boolean, solo_run_id uuid, solo_run_status text, party_run_id uuid, party_run_status text, character_busy boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  perform private.ensure_rotating_sector_incursions();

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  return query
  with party_info as (
    select p.id,p.leader_character_id,count(pm2.character_id)::integer member_count
    from public.parties p
    join public.party_members pm on pm.party_id=p.id and pm.character_id=p_character_id
    join public.party_members pm2 on pm2.party_id=p.id
    where p.status='active'
    group by p.id,p.leader_character_id
    limit 1
  )
  select
    e.id,e.name,e.description,e.sector_id,ms.grid_col,ms.grid_row,e.ends_at,
    e.solo_enemy_level,
    greatest(1,ceil(e.solo_hp*1.15)::integer),
    greatest(1,ceil(e.solo_attack*1.08)::integer),
    greatest(0,ceil(e.solo_defense*1.10)::integer),
    least(
      e.global_clear_target,
      (select count(*)::integer from public.event_boss_completions c where c.event_id=e.id and c.victories>0)
    ),
    e.global_clear_target,
    exists(
      select 1 from public.event_boss_completions c
      where c.event_id=e.id and c.character_id=p_character_id and c.victories>0
    ),
    pi.id,coalesce(pi.member_count,0),coalesce(pi.leader_character_id=p_character_id,false),
    solo.id,solo.status,
    party_run.id,party_run.status,
    private.character_blocked_for_event_boss(p_character_id)
  from public.event_boss_events e
  join public.map_sectors ms on ms.id=e.sector_id
  join public.character_sector_discoveries d
    on d.character_id=p_character_id and d.sector_id=e.sector_id
  left join party_info pi on true
  left join lateral(
    select dr.*
    from public.dungeon_runs dr
    where dr.character_id=p_character_id and dr.event_boss_id=e.id
    order by (dr.status='active') desc,dr.created_at desc
    limit 1
  ) solo on true
  left join lateral(
    select pr.*
    from public.party_dungeon_runs pr
    join public.party_dungeon_run_members prm on prm.run_id=pr.id
    where prm.character_id=p_character_id and pr.event_boss_id=e.id
    order by (pr.status='active') desc,pr.created_at desc
    limit 1
  ) party_run on true
  where e.enabled=true
    and e.boss_kind='sector_incursion'
    and e.global_clear_target is not null
    and now()>=e.starts_at and now()<e.ends_at
  order by e.ends_at,e.name;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_world_pulse(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
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
    jsonb_agg(jsonb_build_object(
      'slug',r.slug,
      'title',r.title,
      'body',r.body,
      'kind',r.rumor_kind,
      'related_event_slug',r.related_event_slug
    )),
    '[]'::jsonb
  )
  into rumors_data
  from (
    select wr.*
    from public.world_rumors wr
    where wr.enabled
      and wr.min_level<=lvl
      and (wr.starts_at is null or now()>=wr.starts_at)
      and (wr.ends_at is null or now()<wr.ends_at)
    order by
      (
        -ln(
          (
            ((pg_catalog.hashtextextended(
              current_date::text||':'||p_character_id::text||':'||wr.slug,
              0
            ) & 2147483647)::numeric+1)
            /2147483649.0
          )
        )
        /greatest(wr.weight,1)
      )
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
$function$
;
