create or replace function private.character_busy_for_blacksmith(p_character_id uuid)
returns boolean
language sql
security definer
set search_path to 'pg_catalog', 'public', 'private'
as $$
  select
    private.character_busy_for_duel(p_character_id,null)
    or exists(
      select 1
      from public.sector_site_actions a
      where a.character_id=p_character_id
        and a.status='active'
        and (a.ends_at is null or a.ends_at>now())
    );
$$;

comment on function private.character_busy_for_blacksmith(uuid) is
'Blocks race changes/blacksmith while combat, dungeon, duel, or a still-running timed site action is active. Ordinary sector expeditions no longer block race changes.';
