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

  self_new:=greatest(0,least(5000,round(self_rating.mmr+k_factor*(self_score-expected_self))::integer));
  opp_new:=greatest(0,least(5000,round(opp_rating.mmr+k_factor*(opp_score-(1.0-expected_self)))::integer));

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
    'rank_name',private.arena_rank_name(self_rank_after),
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
