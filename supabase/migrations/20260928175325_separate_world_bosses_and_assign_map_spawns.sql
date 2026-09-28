-- Synced from live Supabase migration 20260928175325 (separate_world_bosses_and_assign_map_spawns)


-- Separate scheduled map world bosses from monthly endgame bosses.
update public.event_boss_events
set boss_kind='world_enemy',
    sector_id=case slug
      when 'world_2026_10_22_salt_leviathan' then 111::smallint
      else null
    end,
    mechanics=coalesce(mechanics,'{}'::jsonb)
      || jsonb_build_object(
        'scheduled',true,
        'world_boss',true,
        'spawn_policy',
          case slug
            when 'world_2026_10_22_salt_leviathan' then 'initially_known_for_everyone'
            else 'near_any_player_discovery'
          end
      )
where slug in (
  'world_2026_10_22_salt_leviathan',
  'world_2026_11_19_aster',
  'world_2026_12_17_gravity_dragon'
);

create or replace function private.ensure_scheduled_world_boss_sectors()
returns void
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  event_row public.event_boss_events;
  picked_sector smallint;
begin
  update public.event_boss_events e
  set sector_id=111::smallint,
      mechanics=coalesce(e.mechanics,'{}'::jsonb)
        || jsonb_build_object('spawn_policy','initially_known_for_everyone')
  where e.slug='world_2026_10_22_salt_leviathan'
    and e.boss_kind='world_enemy'
    and e.sector_id is distinct from 111::smallint;

  for event_row in
    select e.*
    from public.event_boss_events e
    where e.enabled
      and e.boss_kind='world_enemy'
      and coalesce(e.mechanics->>'scheduled','false')='true'
      and e.slug<>'world_2026_10_22_salt_leviathan'
      and e.sector_id is null
      and now()>=e.starts_at-interval '5 days'
      and now()<e.ends_at
    order by e.starts_at,e.id
    for update
  loop
    picked_sector:=null;

    select candidate.id
    into picked_sector
    from public.map_sectors candidate
    join public.sector_details candidate_detail
      on candidate_detail.sector_id=candidate.id
    where candidate_detail.content_type='wilderness'
      and coalesce(candidate_detail.terrain_type,'')<>'sea'
      and exists(
        select 1
        from public.character_sector_discoveries d
        join public.map_sectors known on known.id=d.sector_id
        where abs(known.grid_col-candidate.grid_col)<=1
          and abs(known.grid_row-candidate.grid_row)<=1
      )
      and not exists(
        select 1
        from public.event_boss_events used
        where used.boss_kind='world_enemy'
          and used.id<>event_row.id
          and used.sector_id=candidate.id
          and used.starts_at>=event_row.starts_at-interval '45 days'
          and used.starts_at<=event_row.starts_at+interval '45 days'
      )
    order by md5(event_row.slug||':'||candidate.id::text)
    limit 1;

    if picked_sector is null then
      select candidate.id
      into picked_sector
      from public.map_sectors candidate
      join public.sector_details candidate_detail
        on candidate_detail.sector_id=candidate.id
      where candidate.initially_known
        and candidate_detail.content_type='wilderness'
        and coalesce(candidate_detail.terrain_type,'')<>'sea'
      order by md5(event_row.slug||':fallback:'||candidate.id::text)
      limit 1;
    end if;

    if picked_sector is not null then
      update public.event_boss_events
      set sector_id=picked_sector,
          mechanics=coalesce(mechanics,'{}'::jsonb)
            || jsonb_build_object('spawn_policy','near_any_player_discovery')
      where id=event_row.id;
    end if;
  end loop;
end;
$$;

revoke all on function private.ensure_scheduled_world_boss_sectors() from public;

create or replace function public.get_visible_world_anomalies(p_character_id uuid)
returns table(
  event_id uuid,
  event_slug text,
  boss_name text,
  title text,
  description text,
  sector_id smallint,
  grid_col smallint,
  grid_row smallint,
  starts_at timestamptz,
  ends_at timestamptz
)
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  caller uuid:=auth.uid();
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then
    raise exception 'CHARACTER_NOT_OWNED';
  end if;

  perform private.ensure_scheduled_world_boss_sectors();

  return query
  with upcoming as (
    select
      e.id,
      e.slug,
      e.name,
      e.starts_at,
      e.sector_id,
      case e.slug
        when 'world_2026_10_22_salt_leviathan' then 'Соляной след'
        when 'world_2026_11_19_aster' then 'Сломанное небо'
        when 'world_2026_12_17_gravity_dragon' then 'Сбой веса'
        else 'Необычная аномалия'
      end as anomaly_title,
      case e.slug
        when 'world_2026_10_22_salt_leviathan'
          then 'Воздух пахнет морской солью, а на земле остаётся белёсый налёт. Что-то огромное приближается с севера.'
        when 'world_2026_11_19_aster'
          then 'Над сектором звёзды видны даже днём и будто смещаются при взгляде. Небо ведёт себя неправильно.'
        when 'world_2026_12_17_gravity_dragon'
          then 'Камни становятся то тяжелее, то легче, а пыль на секунды зависает в воздухе. Пространство рядом нестабильно.'
        else 'В секторе происходит явление, которое не похоже на обычное событие.'
      end as anomaly_description
    from public.event_boss_events e
    where e.enabled
      and e.boss_kind='world_enemy'
      and coalesce(e.mechanics->>'scheduled','false')='true'
      and e.sector_id is not null
      and now()>=e.starts_at-interval '5 days'
      and now()<e.starts_at
  ),
  anomaly_sectors as (
    select
      u.id as event_id,
      u.slug as event_slug,
      u.name as boss_name,
      u.anomaly_title,
      u.anomaly_description,
      u.starts_at,
      s.id as sector_id,
      s.grid_col,
      s.grid_row
    from upcoming u
    join public.map_sectors boss_sector on boss_sector.id=u.sector_id
    cross join lateral (
      select ms.id,ms.grid_col,ms.grid_row
      from public.map_sectors ms
      join public.sector_details sd on sd.sector_id=ms.id
      where sd.content_type='wilderness'
        and coalesce(sd.terrain_type,'')<>'sea'
        and abs(ms.grid_col-boss_sector.grid_col)<=1
        and abs(ms.grid_row-boss_sector.grid_row)<=1
      order by
        case when ms.id=u.sector_id then 0 else 1 end,
        md5(u.slug||':anomaly:'||ms.id::text)
      limit 2
    ) s
  )
  select
    a.event_id,
    a.event_slug,
    a.boss_name,
    a.anomaly_title,
    a.anomaly_description,
    a.sector_id,
    a.grid_col,
    a.grid_row,
    a.starts_at,
    a.starts_at
  from anomaly_sectors a
  where exists(
    select 1
    from public.character_sector_discoveries d
    where d.character_id=p_character_id
      and d.sector_id=a.sector_id
  )
  order by a.starts_at,a.sector_id;
end;
$$;

drop function if exists public.get_visible_world_strong_enemies_v2(uuid);

create function public.get_visible_world_strong_enemies_v2(p_character_id uuid)
returns table(
  event_id uuid, slug text, name text, description text, sector_id smallint,
  grid_col smallint, grid_row smallint, starts_at timestamptz, ends_at timestamptz,
  recommended_level integer, enemy_level integer, enemy_hp integer, enemy_attack integer,
  enemy_defense integer, enemy_initiative integer, enemy_damage_type text,
  enemy_resistances jsonb, phase2_hp_percent integer, phase2_name text,
  mechanics jsonb, reward_name text, reward_description text,
  reward_material_name text, reward_material_quantity integer, featured_loot jsonb,
  reward_gold integer, reward_experience integer, victories integer, defeated boolean,
  solo_only boolean, run_id uuid, run_status text, encounter_id uuid,
  encounter_status text, character_busy boolean
)
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  caller uuid:=auth.uid();
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  perform private.ensure_scheduled_world_boss_sectors();

  return query
  select
    e.id,e.slug,e.name,e.description,e.sector_id,ms.grid_col,ms.grid_row,
    e.starts_at,e.ends_at,e.recommended_level,e.solo_enemy_level,e.solo_hp,
    e.solo_attack,e.solo_defense,e.solo_initiative,et.attack_damage_type,
    et.damage_resistances,et.phase2_hp_percent::integer,et.phase2_name,e.mechanics,
    reward.name,reward.description,
    material.name,e.reward_material_quantity::integer,
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'slug',x->>'slug',
          'chance_percent',coalesce((x->>'chance_percent')::numeric,0),
          'craft_cost',coalesce((x->>'craft_cost')::integer,0),
          'name',i.name,
          'description',i.description,
          'rarity',i.rarity::text,
          'required_level',i.required_level,
          'unique_property_name',i.unique_property_name,
          'unique_property_description',i.unique_property_description
        )
        order by i.name
      )
      from jsonb_array_elements(coalesce(e.featured_loot,'[]'::jsonb)) x
      join public.item_definitions i on i.slug=x->>'slug'
    ),'[]'::jsonb),
    case when coalesce(comp.victories,0)=0
      then private.world_enemy_reward_gold(e.solo_enemy_level,true)
      else 0 end,
    case when coalesce(comp.victories,0)=0
      then private.world_enemy_reward_experience(e.solo_enemy_level,true)
      else 0 end,
    coalesce(comp.victories,0),
    (coalesce(comp.victories,0)>0),
    e.solo_only,solo.id,solo.status,ce.id,ce.status,
    private.character_blocked_for_event_boss(p_character_id)
  from public.event_boss_events e
  join public.map_sectors ms on ms.id=e.sector_id
  join public.enemy_templates et on et.id=e.enemy_template_id
  join public.character_sector_discoveries d
    on d.character_id=p_character_id and d.sector_id=e.sector_id
  left join public.item_definitions reward on reward.id=e.special_reward_item_id
  left join public.item_definitions material on material.id=e.reward_material_item_id
  left join public.event_boss_completions comp
    on comp.event_id=e.id and comp.character_id=p_character_id
  left join lateral(
    select dr.* from public.dungeon_runs dr
    where dr.character_id=p_character_id and dr.event_boss_id=e.id
    order by (dr.status='active') desc,dr.created_at desc limit 1
  ) solo on true
  left join lateral(
    select combat.* from public.combat_encounters combat
    where combat.dungeon_run_id=solo.id
    order by combat.created_at desc limit 1
  ) ce on true
  where e.enabled=true
    and e.boss_kind='world_enemy'
    and e.sector_id is not null
    and now()>=e.starts_at
    and now()<e.ends_at
  order by e.ends_at,e.name;
end;
$$;

revoke execute on function public.get_visible_world_anomalies(uuid) from anon, public;
grant execute on function public.get_visible_world_anomalies(uuid) to authenticated;
revoke execute on function public.get_visible_world_strong_enemies_v2(uuid) from anon, public;
grant execute on function public.get_visible_world_strong_enemies_v2(uuid) to authenticated;

select cron.unschedule(jobid)
from cron.job
where jobname='veira-world-boss-spawns';

select cron.schedule(
  'veira-world-boss-spawns',
  '17 * * * *',
  $$select private.ensure_scheduled_world_boss_sectors();$$
);

select private.ensure_scheduled_world_boss_sectors();

