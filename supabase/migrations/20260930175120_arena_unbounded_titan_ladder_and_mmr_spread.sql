-- Arena: ±500 MMR matchmaking, unbounded rating, Titan numbered ladder from 5000 MMR.
alter table public.arena_character_ratings
  drop constraint if exists arena_character_ratings_mmr_check;
alter table public.arena_character_ratings
  add constraint arena_character_ratings_mmr_check check (mmr>=0);

alter table public.arena_character_ratings
  drop constraint if exists arena_character_ratings_peak_mmr_check;
alter table public.arena_character_ratings
  add constraint arena_character_ratings_peak_mmr_check check (peak_mmr>=0);

insert into public.arena_rank_definitions(
  slug,name,min_mmr,sort_order,milestone_gold,season_gold
)
values('titan','Титан',5000,9,750,1500)
on conflict (slug) do update
set name=excluded.name,
    min_mmr=excluded.min_mmr,
    sort_order=excluded.sort_order,
    milestone_gold=excluded.milestone_gold,
    season_gold=excluded.season_gold;

CREATE OR REPLACE FUNCTION private.arena_ladder_position(p_season_id uuid, p_character_id uuid, p_mode text DEFAULT 'solo'::text)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  select case
    when rr.matches < 5 or rr.mmr < 5000 then null
    else (
      select ranked.position::integer
      from (
        select
          r.character_id,
          row_number() over (
            order by r.mmr desc, r.wins desc, r.losses asc, r.matches asc, r.character_id
          ) as position
        from public.arena_character_ratings r
        where r.season_id=p_season_id
          and r.mode=p_mode
          and r.matches>=5
          and r.mmr>=5000
      ) ranked
      where ranked.character_id=p_character_id
    )
  end
  from public.arena_character_ratings rr
  where rr.season_id=p_season_id
    and rr.character_id=p_character_id
    and rr.mode=p_mode
$function$
;

CREATE OR REPLACE FUNCTION private.arena_display_rank_name(p_season_id uuid, p_character_id uuid, p_mode text DEFAULT 'solo'::text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  select case
    when private.arena_rank_for_mmr(r.mmr,r.matches)='titan'
      then 'Титан #'||coalesce(private.arena_ladder_position(p_season_id,p_character_id,p_mode)::text,'—')
    else private.arena_rank_name(private.arena_rank_for_mmr(r.mmr,r.matches))
  end
  from public.arena_character_ratings r
  where r.season_id=p_season_id
    and r.character_id=p_character_id
    and r.mode=p_mode
$function$
;

CREATE OR REPLACE FUNCTION public.play_solo_arena_match(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid:=auth.uid();
  season public.arena_seasons;
  self_rating public.arena_character_ratings;
  opp_rating public.arena_character_ratings;
  opponent_id uuid;
  simulation jsonb;
  winner_id uuid;
  self_score numeric;
  opp_score numeric;
  expected_self numeric;
  k_factor integer;
  self_new integer;
  opp_new integer;
  self_rank_before text;
  opp_rank_before text;
  self_rank_after text;
  opp_rank_after text;
  self_reward integer:=0;
  opp_reward integer:=0;
  match_id uuid;
  self_ladder_position integer;
  recent_cutoff timestamptz:=now()-interval '5 minutes';
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters
    where id=p_character_id and owner_user_id=caller_id
  ) then raise exception 'CHARACTER_NOT_FOUND'; end if;

  select * into season
  from public.arena_seasons
  where starts_at<=now() and ends_at>now()
  order by starts_at desc
  limit 1;
  if season.id is null then raise exception 'ARENA_SEASON_INACTIVE'; end if;

  insert into public.arena_character_ratings(season_id,character_id,mode)
  select season.id,c.id,m.mode
  from public.characters c
  join public.profiles p on p.user_id=c.owner_user_id and p.account_type='player'
  cross join (values('solo'::text),('party'::text)) m(mode)
  on conflict do nothing;

  select * into self_rating
  from public.arena_character_ratings
  where season_id=season.id and character_id=p_character_id and mode='solo';

  if self_rating.last_match_at is not null and self_rating.last_match_at>now()-interval '2 seconds' then
    raise exception 'ARENA_COOLDOWN';
  end if;

  select r.character_id into opponent_id
  from public.arena_character_ratings r
  join public.characters c on c.id=r.character_id
  join public.characters me on me.id=p_character_id
  join public.character_progress cp on cp.character_id=c.id
  join public.character_progress mycp on mycp.character_id=p_character_id
  where r.season_id=season.id
    and r.mode='solo'
    and r.character_id<>p_character_id
    and c.owner_user_id<>me.owner_user_id
    and r.mmr between greatest(0,self_rating.mmr-500) and self_rating.mmr+500
    and not exists(
      select 1
      from public.arena_matches m
      where m.season_id=season.id and m.mode='solo'
        and m.created_at>recent_cutoff
        and (
          (m.challenger_character_id=p_character_id and m.opponent_character_id=r.character_id)
          or (m.opponent_character_id=p_character_id and m.challenger_character_id=r.character_id)
        )
    )
  order by
    abs(r.mmr-self_rating.mmr),
    abs(cp.level-mycp.level),
    random()
  limit 1;

  if opponent_id is null then raise exception 'NO_ARENA_OPPONENT'; end if;

  perform pg_advisory_xact_lock(hashtextextended('arena:'||least(p_character_id::text,opponent_id::text),0));
  perform pg_advisory_xact_lock(hashtextextended('arena:'||greatest(p_character_id::text,opponent_id::text),0));

  select * into self_rating
  from public.arena_character_ratings
  where season_id=season.id and character_id=p_character_id and mode='solo'
  for update;

  select * into opp_rating
  from public.arena_character_ratings
  where season_id=season.id and character_id=opponent_id and mode='solo'
  for update;

  if abs(opp_rating.mmr-self_rating.mmr)>500 then
    raise exception 'ARENA_OPPONENT_OUT_OF_RANGE';
  end if;

  simulation:=private.arena_simulate_solo(p_character_id,opponent_id);
  winner_id:=nullif(simulation->>'winner_character_id','')::uuid;

  if winner_id is null then
    self_score:=0.5; opp_score:=0.5;
  elsif winner_id=p_character_id then
    self_score:=1; opp_score:=0;
  else
    self_score:=0; opp_score:=1;
  end if;

  expected_self:=1.0/(1.0+power(10.0,(opp_rating.mmr-self_rating.mmr)/400.0));
  k_factor:=case when self_rating.matches<10 or opp_rating.matches<10 then 48 else 32 end;

  self_new:=greatest(0,round(self_rating.mmr+k_factor*(self_score-expected_self))::integer);
  opp_new:=greatest(0,round(opp_rating.mmr+k_factor*(opp_score-(1.0-expected_self)))::integer);

  self_rank_before:=private.arena_rank_for_mmr(self_rating.mmr,self_rating.matches);
  opp_rank_before:=private.arena_rank_for_mmr(opp_rating.mmr,opp_rating.matches);
  self_rank_after:=private.arena_rank_for_mmr(self_new,self_rating.matches+1);
  opp_rank_after:=private.arena_rank_for_mmr(opp_new,opp_rating.matches+1);

  update public.arena_character_ratings
  set mmr=self_new,
      peak_mmr=greatest(peak_mmr,self_new),
      matches=matches+1,
      wins=wins+case when self_score=1 then 1 else 0 end,
      losses=losses+case when self_score=0 then 1 else 0 end,
      draws=draws+case when self_score=0.5 then 1 else 0 end,
      last_match_at=now(),
      updated_at=now()
  where season_id=season.id and character_id=p_character_id and mode='solo';

  update public.arena_character_ratings
  set mmr=opp_new,
      peak_mmr=greatest(peak_mmr,opp_new),
      matches=matches+1,
      wins=wins+case when opp_score=1 then 1 else 0 end,
      losses=losses+case when opp_score=0 then 1 else 0 end,
      draws=draws+case when opp_score=0.5 then 1 else 0 end,
      last_match_at=now(),
      updated_at=now()
  where season_id=season.id and character_id=opponent_id and mode='solo';

  self_ladder_position:=private.arena_ladder_position(season.id,p_character_id,'solo');

  self_reward:=private.arena_grant_rank_rewards(
    season.id,p_character_id,'solo',self_rating.mmr,self_rating.matches,self_new,self_rating.matches+1
  );
  opp_reward:=private.arena_grant_rank_rewards(
    season.id,opponent_id,'solo',opp_rating.mmr,opp_rating.matches,opp_new,opp_rating.matches+1
  );

  insert into public.arena_matches(
    season_id,mode,challenger_character_id,opponent_character_id,winner_character_id,
    challenger_mmr_before,challenger_mmr_after,opponent_mmr_before,opponent_mmr_after,
    challenger_rank_before,challenger_rank_after,opponent_rank_before,opponent_rank_after,
    rounds,challenger_final_hp,opponent_final_hp,combat_log
  )
  values(
    season.id,'solo',p_character_id,opponent_id,winner_id,
    self_rating.mmr,self_new,opp_rating.mmr,opp_new,
    self_rank_before,self_rank_after,opp_rank_before,opp_rank_after,
    coalesce((simulation->>'rounds')::integer,0),
    coalesce((simulation->>'challenger_final_hp')::integer,0),
    coalesce((simulation->>'opponent_final_hp')::integer,0),
    coalesce(simulation->'log','[]'::jsonb)
  )
  returning id into match_id;

  return jsonb_build_object(
    'match_id',match_id,
    'season_id',season.id,
    'winner_character_id',winner_id,
    'result',case when winner_id is null then 'draw' when winner_id=p_character_id then 'win' else 'loss' end,
    'opponent',(
      select jsonb_build_object('character_id',c.id,'name',c.name,'level',cp.level,'avatar_url',c.avatar_url)
      from public.characters c join public.character_progress cp on cp.character_id=c.id
      where c.id=opponent_id
    ),
    'mmr_before',self_rating.mmr,
    'mmr_after',self_new,
    'mmr_delta',self_new-self_rating.mmr,
    'rank_before',self_rank_before,
    'rank_after',self_rank_after,
    'rank_name',case when self_rank_after='titan' and self_ladder_position is not null
      then 'Титан #'||self_ladder_position
      else private.arena_rank_name(self_rank_after)
    end,
    'ladder_position',self_ladder_position,
    'rank_reward_gold',self_reward,
    'rounds',coalesce((simulation->>'rounds')::integer,0),
    'challenger_final_hp',coalesce((simulation->>'challenger_final_hp')::integer,0),
    'challenger_hp_max',coalesce((simulation->>'challenger_hp_max')::integer,1),
    'opponent_final_hp',coalesce((simulation->>'opponent_final_hp')::integer,0),
    'opponent_hp_max',coalesce((simulation->>'opponent_hp_max')::integer,1),
    'log',coalesce(simulation->'log','[]'::jsonb)
  );
end;
$function$
;

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
        'rank_name',private.arena_display_rank_name(season.id,r.character_id,'solo'),
        'ladder_position',private.arena_ladder_position(season.id,r.character_id,'solo'),
        'max_matchmaking_spread',500,
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
          'rank_name',private.arena_display_rank_name(season.id,r.character_id,'solo'),
          'ladder_position',private.arena_ladder_position(season.id,r.character_id,'solo')
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
;

revoke all on function private.arena_ladder_position(uuid,uuid,text)
  from public,anon,authenticated;
revoke all on function private.arena_display_rank_name(uuid,uuid,text)
  from public,anon,authenticated;
