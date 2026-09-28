-- Synced from live Supabase migration 20260927222220 (expand_world_discovery_archive)

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
    order by md5(current_date::text||':'||wr.slug)
    limit 3
  ) r;

  merchant_sector:=private.current_wandering_merchant_sector(p_character_id);

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
      ),
      '[]'::jsonb
    )
    into merchant_offers
    from (
      select
        d.id,d.slug,d.name,d.description,d.rarity,c.offer_price,
        exists(
          select 1 from public.wandering_merchant_purchases p
          where p.character_id=p_character_id
            and p.item_definition_id=d.id
            and p.rotation_date=current_date
        ) bought
      from public.wandering_merchant_catalog c
      join public.item_definitions d on d.id=c.item_definition_id
      where c.enabled
        and lvl between c.min_level and c.max_level
      order by md5(current_date::text||':'||c.item_definition_id::text)
      limit 4
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
          'offers',merchant_offers
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
$function$;
