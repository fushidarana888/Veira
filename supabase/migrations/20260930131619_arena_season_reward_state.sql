CREATE OR REPLACE FUNCTION public.get_arena_overview(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid:=auth.uid();
  season public.arena_seasons;
  result jsonb;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id)
    then raise exception 'CHARACTER_NOT_FOUND'; end if;

  select * into season
  from public.arena_seasons
  where starts_at<=now() and ends_at>now()
  order by starts_at desc limit 1;

  if season.id is null then select * into season from public.arena_seasons order by starts_at desc limit 1; end if;
  if season.id is null then
    return jsonb_build_object('season',null,'solo',null,'party',null,'history','[]'::jsonb,'leaderboard','[]'::jsonb);
  end if;

  insert into public.arena_character_ratings(season_id,character_id,mode)
  values(season.id,p_character_id,'solo'),(season.id,p_character_id,'party')
  on conflict do nothing;

  select jsonb_build_object(
    'season',jsonb_build_object(
      'id',season.id,'slug',season.slug,'name',season.name,'starts_at',season.starts_at,'ends_at',season.ends_at,
      'active',(season.starts_at<=now() and season.ends_at>now())
    ),
    'solo',(
      select jsonb_build_object(
        'mmr',r.mmr,'peak_mmr',r.peak_mmr,'matches',r.matches,'wins',r.wins,'losses',r.losses,'draws',r.draws,
        'rank_slug',private.arena_rank_for_mmr(r.mmr,r.matches),
        'rank_name',private.arena_rank_name(private.arena_rank_for_mmr(r.mmr,r.matches)),
        'placement_remaining',greatest(0,5-r.matches),
        'season_reward_gold',case when r.matches<5 then 0 else coalesce(
          (select season_gold from public.arena_rank_definitions where slug=private.arena_rank_for_mmr(r.peak_mmr,5)),0
        ) end,
        'season_reward_claimed',exists(
          select 1
          from public.arena_season_reward_claims src
          where src.season_id=season.id
            and src.character_id=p_character_id
            and src.mode='solo'
        ),
        'next_rank',case when r.matches<5 then null else (
          select jsonb_build_object('slug',d.slug,'name',d.name,'min_mmr',d.min_mmr)
          from public.arena_rank_definitions d where d.min_mmr>r.mmr order by d.min_mmr limit 1
        ) end
      )
      from public.arena_character_ratings r
      where r.season_id=season.id and r.character_id=p_character_id and r.mode='solo'
    ),
    'party',(
      select jsonb_build_object(
        'mmr',r.mmr,'peak_mmr',r.peak_mmr,'matches',r.matches,'wins',r.wins,'losses',r.losses,'draws',r.draws,
        'rank_slug',private.arena_rank_for_mmr(r.mmr,r.matches),
        'rank_name',private.arena_rank_name(private.arena_rank_for_mmr(r.mmr,r.matches)),
        'placement_remaining',greatest(0,5-r.matches),'enabled',false
      )
      from public.arena_character_ratings r
      where r.season_id=season.id and r.character_id=p_character_id and r.mode='party'
    ),
    'ranks',coalesce((
      select jsonb_agg(jsonb_build_object(
        'slug',d.slug,'name',d.name,'min_mmr',d.min_mmr,'milestone_gold',d.milestone_gold,'season_gold',d.season_gold
      ) order by d.sort_order) from public.arena_rank_definitions d
    ),'[]'::jsonb),
    'history',coalesce((
      select jsonb_agg(x.obj order by x.created_at desc)
      from (
        select m.created_at,jsonb_build_object(
          'id',m.id,'created_at',m.created_at,'winner_character_id',m.winner_character_id,
          'opponent_id',case when m.challenger_character_id=p_character_id then m.opponent_character_id else m.challenger_character_id end,
          'opponent_name',case when m.challenger_character_id=p_character_id then oc.name else cc.name end,
          'result',case when m.winner_character_id is null then 'draw' when m.winner_character_id=p_character_id then 'win' else 'loss' end,
          'mmr_before',case when m.challenger_character_id=p_character_id then m.challenger_mmr_before else m.opponent_mmr_before end,
          'mmr_after',case when m.challenger_character_id=p_character_id then m.challenger_mmr_after else m.opponent_mmr_after end,
          'rounds',m.rounds
        ) obj
        from public.arena_matches m
        left join public.characters cc on cc.id=m.challenger_character_id
        left join public.characters oc on oc.id=m.opponent_character_id
        where m.season_id=season.id and m.mode='solo' and p_character_id in (m.challenger_character_id,m.opponent_character_id)
        order by m.created_at desc limit 12
      ) x
    ),'[]'::jsonb),
    'leaderboard',coalesce((
      select jsonb_agg(x.obj order by x.mmr desc,x.wins desc,x.name)
      from (
        select r.mmr,r.wins,c.name,jsonb_build_object(
          'character_id',c.id,'name',c.name,'level',cp.level,'mmr',r.mmr,'matches',r.matches,'wins',r.wins,
          'rank_slug',private.arena_rank_for_mmr(r.mmr,r.matches),
          'rank_name',private.arena_rank_name(private.arena_rank_for_mmr(r.mmr,r.matches))
        ) obj
        from public.arena_character_ratings r
        join public.characters c on c.id=r.character_id
        join public.character_progress cp on cp.character_id=c.id
        where r.season_id=season.id and r.mode='solo'
        order by r.mmr desc,r.wins desc,c.name limit 20
      ) x
    ),'[]'::jsonb)
  ) into result;

  return result;
end;
$function$
