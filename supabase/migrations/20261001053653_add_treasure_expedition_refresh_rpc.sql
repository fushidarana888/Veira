-- Synced from live Supabase migration 20261001053653 (add_treasure_expedition_refresh_rpc)

create or replace function public.refresh_treasure_hunt_expeditions(
  p_character_id uuid
) returns integer
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
begin
  return private.complete_expired_treasure_expeditions(p_character_id);
end;
$$;

revoke execute on function public.refresh_treasure_hunt_expeditions(uuid)
  from public, anon;

grant execute on function public.refresh_treasure_hunt_expeditions(uuid)
  to authenticated, service_role;
