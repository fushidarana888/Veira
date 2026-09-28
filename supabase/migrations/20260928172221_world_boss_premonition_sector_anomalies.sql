-- Synced from live Supabase migration 20260928172221 (world_boss_premonition_sector_anomalies)


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

  return query
  with upcoming as (
    select
      e.id,
      e.slug,
      e.name,
      e.starts_at,
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
      and e.boss_kind='monthly'
      and coalesce(e.mechanics->>'scheduled','false')='true'
      and now() >= e.starts_at - interval '5 days'
      and now() < e.starts_at
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
    cross join lateral (
      select ms.id,ms.grid_col,ms.grid_row
      from public.map_sectors ms
      join public.sector_details sd on sd.sector_id=ms.id
      where sd.content_type='wilderness'
        and coalesce(sd.terrain_type,'')<>'sea'
      order by md5(u.slug||':'||ms.id::text)
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

revoke execute on function public.get_visible_world_anomalies(uuid) from anon, public;
grant execute on function public.get_visible_world_anomalies(uuid) to authenticated;

