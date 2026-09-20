CREATE OR REPLACE FUNCTION public.get_religion_catalog(p_character_id uuid)
 RETURNS TABLE(slug text, name text, short_motto text, description text, praise_text text, taboo_text text, is_current boolean, faith_points integer, religion_level smallint, favor integer, current_level_points integer, next_level_points integer, daily_earned integer, daily_cap smallint, reward_item_id uuid, reward_item_name text, reward_item_description text, reward_claimed boolean, combat_modifiers jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller uuid:=auth.uid();
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  return query
  select
    r.slug,r.name,r.short_motto,r.description,r.praise_text,r.taboo_text,
    coalesce(cr.current_religion_slug=r.slug,false),
    coalesce(cp.faith_points,0),
    private.religion_level(coalesce(cp.faith_points,0)),
    coalesce(cp.favor,0),
    private.religion_level_threshold(private.religion_level(coalesce(cp.faith_points,0))),
    case when private.religion_level(coalesce(cp.faith_points,0))>=10 then 2200
      else private.religion_level_threshold(private.religion_level(coalesce(cp.faith_points,0))+1) end,
    coalesce((
      select sum(greatest(e.faith_delta,0))::integer
      from public.religion_faith_events e
      where e.character_id=p_character_id and e.religion_slug=r.slug
        and e.event_type<>'oath_completed'
        and e.created_at>=date_trunc('day',now())
    ),0),
    r.faith_daily_cap,
    r.level10_reward_item_id,reward.name,reward.description,
    coalesce(cp.level10_reward_claimed,false),
    case when cr.current_religion_slug=r.slug
      then private.character_religion_modifiers(p_character_id)
      else '{}'::jsonb end
  from public.religion_definitions r
  left join public.character_religions cr on cr.character_id=p_character_id
  left join public.character_religion_progress cp
    on cp.character_id=p_character_id and cp.religion_slug=r.slug
  left join public.item_definitions reward on reward.id=r.level10_reward_item_id
  where r.enabled
  order by r.sort_order,r.name;
end;
$function$
