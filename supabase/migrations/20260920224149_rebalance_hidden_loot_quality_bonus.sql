CREATE OR REPLACE FUNCTION private.character_loot_quality_bonus_percent(p_character_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  select least(
    100.0,
    greatest(0,coalesce(s.luck,0))*1.0
      +case when coalesce(private.character_current_favor(p_character_id),0)>=50 then 15.0 else 0.0 end
  )
  from private.get_character_combat_stats(p_character_id) s;
$function$;

revoke all on function private.character_loot_quality_bonus_percent(uuid)
from public,anon,authenticated;
