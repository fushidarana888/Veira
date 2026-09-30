-- Restore the public guide RPC after private helper hardening.
-- The authenticated caller may execute only the public wrapper; the private
-- implementation remains inaccessible directly and still validates auth.uid().

create or replace function public.get_game_guide_catalog()
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select private.get_game_guide_catalog_internal();
$function$;

revoke all on function public.get_game_guide_catalog() from public, anon;
grant execute on function public.get_game_guide_catalog() to authenticated;
