create or replace function private.arena_choose_action(
  p_actor_id uuid,
  p_actor_stats jsonb,
  p_actor_hp integer,
  p_actor_hp_max integer,
  p_actor_mana integer,
  p_actor_mana_max integer,
  p_actor_action_count integer,
  p_actor_guard_active boolean,
  p_target_stats jsonb,
  p_target_hp integer,
  p_target_hp_max integer
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  settings public.character_autobattle_settings;
  hp_percent numeric;
  target_resistances jsonb := coalesce(p_target_stats->'damage_resistances','{}'::jsonb);
  physical_damage integer := -1;
  magic_damage integer := -1;
  spell_damage integer := -1;
  spell_cost integer := 0;
  spell_id uuid;
  spell_name text;
  heal_id uuid;
  heal_name text;
  heal_cost integer := 0;
  heal_value integer := 0;
  guard_due boolean := false;
  best_action text := 'physical';
  best_damage integer := 1;
  variance integer := 0;
  resist integer := 0;
  actor_all_bonus integer := coalesce((p_actor_stats->>'all_damage_bonus_percent')::integer,0);
  actor_physical_bonus integer := coalesce((p_actor_stats->>'physical_damage_bonus_percent')::integer,0);
  actor_magic_bonus integer := coalesce((p_actor_stats->>'magic_damage_bonus_percent')::integer,0);
  actor_wounded_bonus integer := coalesce((p_actor_stats->>'damage_vs_wounded_percent')::integer,0);
  target_low_hp_reduction integer := coalesce((p_target_stats->>'low_hp_damage_reduction_percent')::integer,0);
  actor_magic_power integer := greatest(1,coalesce((p_actor_stats->>'magic_power')::integer,1));
  actor_physical_power integer := greatest(1,coalesce((p_actor_stats->>'physical_power')::integer,1));
  target_physical_defense integer := greatest(0,coalesce((p_target_stats->>'defense')::integer,0));
  target_magic_defense integer := greatest(
    0,
    coalesce(
      (p_target_stats->>'magic_defense')::integer,
      coalesce((p_target_stats->>'level')::integer,1)
      + coalesce((p_target_stats->>'vitality')::integer,0)
      + coalesce((p_target_stats->>'intellect')::integer,0)
    )
  );
  weapon_type text := coalesce(p_actor_stats->>'weapon_damage_type','blunt');
  magic_type text := coalesce(p_actor_stats->>'magic_damage_type','fire');
  s record;
  raw integer;
begin
  select * into settings
  from public.character_autobattle_settings
  where character_id=p_actor_id;

  if settings.character_id is null then
    settings.strategy := 'balanced';
    settings.mana_reserve_percent := 25;
    settings.normal_allow_physical := true;
    settings.normal_allow_magic := true;
    settings.normal_allow_spells := true;
    settings.normal_guard_mode := 'low_hp';
    settings.normal_guard_hp_percent := 25;
    settings.normal_guard_every_n := 0;
    settings.normal_support_enabled := true;
    settings.normal_heal_hp_percent := 45;
  end if;

  hp_percent := case when p_actor_hp_max>0 then p_actor_hp*100.0/p_actor_hp_max else 100 end;

  if coalesce(settings.normal_support_enabled,true)
     and coalesce(settings.normal_allow_spells,true)
     and hp_percent <= coalesce(settings.normal_heal_hp_percent,45)
  then
    select sd.id,sd.name,private.character_effective_spell_mana_cost(p_actor_id,sd.id),
           private.concentrated_spell_direct_value(
             p_actor_id,
             sd.id,
             greatest(1,round(actor_magic_power*sd.power_multiplier)::integer+sd.flat_power)
           )
    into heal_id,heal_name,heal_cost,heal_value
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=p_actor_id
      and sd.enabled=true
      and sd.spell_kind='heal'
      and private.character_effective_spell_mana_cost(p_actor_id,sd.id) <= p_actor_mana
    order by (
      round(actor_magic_power*sd.power_multiplier)::integer+sd.flat_power
    ) desc
    limit 1;

    if heal_id is not null and heal_value>0 then
      return jsonb_build_object(
        'action','heal','label',heal_name,'value',least(p_actor_hp_max-p_actor_hp,heal_value),
        'mana_cost',heal_cost
      );
    end if;
  end if;

  guard_due := case coalesce(settings.normal_guard_mode,'low_hp')
    when 'never' then false
    when 'low_hp' then hp_percent <= coalesce(settings.normal_guard_hp_percent,25)
    when 'interval' then coalesce(settings.normal_guard_every_n,0)>0
      and p_actor_action_count>0
      and mod(p_actor_action_count,settings.normal_guard_every_n)=0
    when 'low_hp_or_interval' then
      hp_percent <= coalesce(settings.normal_guard_hp_percent,25)
      or (
        coalesce(settings.normal_guard_every_n,0)>0
        and p_actor_action_count>0
        and mod(p_actor_action_count,settings.normal_guard_every_n)=0
      )
    else false
  end;

  if guard_due and not p_actor_guard_active then
    return jsonb_build_object(
      'action','guard','label','Защита',
      'value',least(80,55+coalesce((p_actor_stats->>'guard_boost_percent')::integer,0)),
      'mana_cost',0
    );
  end if;

  variance := private.combat_damage_variance(coalesce((p_actor_stats->>'luck')::integer,0));

  if coalesce(settings.normal_allow_physical,true) then
    physical_damage := private.weapon_family_physical_raw_damage(
      p_actor_id,
      actor_physical_power,
      target_physical_defense,
      p_target_hp_max,
      variance
    );
    physical_damage := greatest(1,round(
      physical_damage*(100+actor_all_bonus+actor_physical_bonus)/100.0
    )::integer);
    resist := private.damage_resistance_percent(target_resistances,weapon_type);
    physical_damage := greatest(1,round(physical_damage*(100-resist)/100.0)::integer);
    if p_target_hp*2 <= p_target_hp_max then
      physical_damage := greatest(1,round(physical_damage*(100+actor_wounded_bonus)/100.0)::integer);
      physical_damage := greatest(1,round(physical_damage*(100-target_low_hp_reduction)/100.0)::integer);
    end if;
  end if;

  if coalesce(settings.normal_allow_magic,true) then
    magic_damage := greatest(
      1,
      private.damage_after_armor(actor_magic_power+variance,target_magic_defense)
    );
    magic_damage := greatest(1,round(
      magic_damage*(100+actor_all_bonus+actor_magic_bonus)/100.0
    )::integer);
    resist := private.damage_resistance_percent(target_resistances,magic_type);
    magic_damage := greatest(1,round(magic_damage*(100-resist)/100.0)::integer);
    if p_target_hp*2 <= p_target_hp_max then
      magic_damage := greatest(1,round(magic_damage*(100+actor_wounded_bonus)/100.0)::integer);
      magic_damage := greatest(1,round(magic_damage*(100-target_low_hp_reduction)/100.0)::integer);
    end if;
  end if;

  if coalesce(settings.normal_allow_spells,true) then
    for s in
      select sd.*
      from public.character_combat_spells ccs
      join public.spell_definitions sd on sd.id=ccs.spell_id
      where ccs.character_id=p_actor_id
        and sd.enabled=true
        and sd.spell_kind='damage'
        and private.character_effective_spell_mana_cost(p_actor_id,sd.id) <= p_actor_mana
        and (
          p_actor_mana_max<=0
          or p_actor_mana-private.character_effective_spell_mana_cost(p_actor_id,sd.id)
             >= floor(p_actor_mana_max*coalesce(settings.mana_reserve_percent,25)/100.0)
          or coalesce(settings.strategy,'balanced')='aggressive'
        )
    loop
      raw := private.concentrated_spell_direct_value(
        p_actor_id,
        s.id,
        greatest(
          1,
          private.damage_after_armor(
            round(actor_magic_power*s.power_multiplier)::integer+s.flat_power+variance,
            target_magic_defense*0.65
          )
        )
      );
      raw := private.ensure_spell_stronger_than_innate(
        raw,
        greatest(1,private.damage_after_armor(actor_magic_power+variance,target_magic_defense)),
        10
      );
      raw := greatest(1,round(
        raw*(
          100+actor_all_bonus+actor_magic_bonus+
          private.character_spell_family_damage_bonus_percent(p_actor_id,s.id)
        )/100.0
      )::integer);
      resist := private.damage_resistance_percent(target_resistances,s.damage_type);
      raw := greatest(1,round(raw*(100-resist)/100.0)::integer);
      if p_target_hp*2 <= p_target_hp_max then
        raw := greatest(1,round(raw*(100+actor_wounded_bonus)/100.0)::integer);
        raw := greatest(1,round(raw*(100-target_low_hp_reduction)/100.0)::integer);
      end if;

      if raw>spell_damage then
        spell_damage:=raw;
        spell_id:=s.id;
        spell_name:=s.name;
        spell_cost:=private.character_effective_spell_mana_cost(p_actor_id,s.id);
      end if;
    end loop;
  end if;

  best_damage:=greatest(physical_damage,magic_damage,spell_damage,1);
  if spell_damage=best_damage and spell_id is not null then
    return jsonb_build_object(
      'action','spell','label',spell_name,'value',best_damage,'mana_cost',spell_cost,'spell_id',spell_id
    );
  elsif magic_damage=best_damage and magic_damage>=0 then
    best_action:='magic';
  else
    best_action:='physical';
  end if;

  return jsonb_build_object(
    'action',best_action,
    'label',case when best_action='magic' then 'Врождённая магия' else 'Физическая атака' end,
    'value',best_damage,
    'mana_cost',0
  );
end;
$$;

create or replace function private.arena_simulate_solo(
  p_challenger_id uuid,
  p_opponent_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  a record;
  b record;
  a_json jsonb;
  b_json jsonb;
  a_name text;
  b_name text;
  a_hp integer;
  b_hp integer;
  a_mana integer;
  b_mana integer;
  a_guard integer:=0;
  b_guard integer:=0;
  a_actions integer:=0;
  b_actions integer:=0;
  a_time numeric;
  b_time numeric;
  action jsonb;
  action_type text;
  action_label text;
  value integer;
  mana_cost integer;
  actual integer;
  heal integer;
  actor_lifesteal integer;
  actor_mana_on_hit integer;
  total_actions integer:=0;
  log_data jsonb:='[]'::jsonb;
  winner uuid:=null;
  a_ratio numeric;
  b_ratio numeric;
  a_magic_defense integer;
  b_magic_defense integer;
begin
  select * into a from private.get_character_combat_stats(p_challenger_id);
  select * into b from private.get_character_combat_stats(p_opponent_id);
  if a.level is null or b.level is null then raise exception 'ARENA_COMBAT_STATS_NOT_FOUND'; end if;

  select name into a_name from public.characters where id=p_challenger_id;
  select name into b_name from public.characters where id=p_opponent_id;

  a_magic_defense:=greatest(0,round(
    private.character_magic_defense(a.level,a.vitality,a.intellect)
    *(
      100
      +private.character_defense_percent(p_challenger_id)
      +private.character_religion_modifier_number(p_challenger_id,'magic_defense_percent')
    )/100.0
  )::integer);
  b_magic_defense:=greatest(0,round(
    private.character_magic_defense(b.level,b.vitality,b.intellect)
    *(
      100
      +private.character_defense_percent(p_opponent_id)
      +private.character_religion_modifier_number(p_opponent_id,'magic_defense_percent')
    )/100.0
  )::integer);

  a_json:=to_jsonb(a)||jsonb_build_object('magic_defense',a_magic_defense);
  b_json:=to_jsonb(b)||jsonb_build_object('magic_defense',b_magic_defense);
  a_hp:=greatest(1,a.hp_max);
  b_hp:=greatest(1,b.hp_max);
  a_mana:=greatest(0,a.mana_max);
  b_mana:=greatest(0,b.mana_max);

  a_time:=1000.0/greatest(1,a.initiative) * (0.97+random()*0.06);
  b_time:=1000.0/greatest(1,b.initiative) * (0.97+random()*0.06);

  while a_hp>0 and b_hp>0 and total_actions<80 loop
    total_actions:=total_actions+1;

    if a_time<=b_time then
      action:=private.arena_choose_action(
        p_challenger_id,a_json,a_hp,a.hp_max,a_mana,a.mana_max,a_actions,a_guard>0,
        b_json,b_hp,b.hp_max
      );
      action_type:=action->>'action';
      action_label:=coalesce(action->>'label',action_type);
      value:=greatest(0,coalesce((action->>'value')::integer,0));
      mana_cost:=greatest(0,coalesce((action->>'mana_cost')::integer,0));
      a_mana:=greatest(0,a_mana-mana_cost);

      if action_type='guard' then
        a_guard:=value; actual:=0; heal:=0;
      elsif action_type='heal' then
        heal:=least(a.hp_max-a_hp,value); a_hp:=least(a.hp_max,a_hp+heal); actual:=0;
      else
        actual:=value;
        if b_guard>0 then actual:=greatest(1,round(actual*(100-b_guard)/100.0)::integer); b_guard:=0; end if;
        actual:=least(b_hp,actual); b_hp:=greatest(0,b_hp-actual);
        actor_lifesteal:=least(50,greatest(0,a.lifesteal_percent));
        if actor_lifesteal>0 and actual>0 then a_hp:=least(a.hp_max,a_hp+greatest(1,floor(actual*actor_lifesteal/100.0)::integer)); end if;
        actor_mana_on_hit:=greatest(0,a.mana_on_hit);
        if actor_mana_on_hit>0 and actual>0 then a_mana:=least(a.mana_max,a_mana+actor_mana_on_hit); end if;
        heal:=0;
      end if;

      a_actions:=a_actions+1;
      a_time:=a_time+1000.0/greatest(1,a.initiative);
      log_data:=log_data||jsonb_build_array(jsonb_build_object(
        'turn',total_actions,'actor_id',p_challenger_id,'actor_name',a_name,
        'action',action_type,'label',action_label,'damage',actual,'healing',heal,
        'actor_hp',a_hp,'actor_mana',a_mana,'target_hp',b_hp
      ));
    else
      action:=private.arena_choose_action(
        p_opponent_id,b_json,b_hp,b.hp_max,b_mana,b.mana_max,b_actions,b_guard>0,
        a_json,a_hp,a.hp_max
      );
      action_type:=action->>'action';
      action_label:=coalesce(action->>'label',action_type);
      value:=greatest(0,coalesce((action->>'value')::integer,0));
      mana_cost:=greatest(0,coalesce((action->>'mana_cost')::integer,0));
      b_mana:=greatest(0,b_mana-mana_cost);

      if action_type='guard' then
        b_guard:=value; actual:=0; heal:=0;
      elsif action_type='heal' then
        heal:=least(b.hp_max-b_hp,value); b_hp:=least(b.hp_max,b_hp+heal); actual:=0;
      else
        actual:=value;
        if a_guard>0 then actual:=greatest(1,round(actual*(100-a_guard)/100.0)::integer); a_guard:=0; end if;
        actual:=least(a_hp,actual); a_hp:=greatest(0,a_hp-actual);
        actor_lifesteal:=least(50,greatest(0,b.lifesteal_percent));
        if actor_lifesteal>0 and actual>0 then b_hp:=least(b.hp_max,b_hp+greatest(1,floor(actual*actor_lifesteal/100.0)::integer)); end if;
        actor_mana_on_hit:=greatest(0,b.mana_on_hit);
        if actor_mana_on_hit>0 and actual>0 then b_mana:=least(b.mana_max,b_mana+actor_mana_on_hit); end if;
        heal:=0;
      end if;

      b_actions:=b_actions+1;
      b_time:=b_time+1000.0/greatest(1,b.initiative);
      log_data:=log_data||jsonb_build_array(jsonb_build_object(
        'turn',total_actions,'actor_id',p_opponent_id,'actor_name',b_name,
        'action',action_type,'label',action_label,'damage',actual,'healing',heal,
        'actor_hp',b_hp,'actor_mana',b_mana,'target_hp',a_hp
      ));
    end if;
  end loop;

  if a_hp<=0 and b_hp>0 then winner:=p_opponent_id;
  elsif b_hp<=0 and a_hp>0 then winner:=p_challenger_id;
  elsif a_hp<=0 and b_hp<=0 then winner:=null;
  else
    a_ratio:=a_hp::numeric/greatest(1,a.hp_max);
    b_ratio:=b_hp::numeric/greatest(1,b.hp_max);
    if a_ratio>b_ratio+0.01 then winner:=p_challenger_id;
    elsif b_ratio>a_ratio+0.01 then winner:=p_opponent_id;
    else winner:=null;
    end if;
  end if;

  return jsonb_build_object(
    'winner_character_id',winner,'rounds',total_actions,
    'challenger_final_hp',a_hp,'challenger_hp_max',a.hp_max,
    'opponent_final_hp',b_hp,'opponent_hp_max',b.hp_max,'log',log_data
  );
end;
$$;

create or replace function public.get_arena_overview(p_character_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
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
$$;

revoke all on function public.get_arena_overview(uuid) from public, anon;
grant execute on function public.get_arena_overview(uuid) to authenticated;
revoke all on function private.arena_choose_action(uuid,jsonb,integer,integer,integer,integer,integer,boolean,jsonb,integer,integer) from public, anon, authenticated;
revoke all on function private.arena_simulate_solo(uuid,uuid) from public, anon, authenticated;
