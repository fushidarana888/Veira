alter table public.event_boss_completions
  add column if not exists global_reward_claimed boolean not null default false;

CREATE OR REPLACE FUNCTION private.grant_event_boss_victory(p_event_id uuid, p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  event_row public.event_boss_events;
  completion public.event_boss_completions;
  first_victory boolean:=false;
  reward_gold integer:=0;
  reward_exp integer:=0;
  special_awarded boolean:=false;
  global_count integer:=0;
  global_resolved boolean:=false;
  global_bonus_recipients integer:=0;
begin
  select * into event_row
  from public.event_boss_events
  where id=p_event_id
  for update;

  if event_row.id is null then raise exception 'EVENT_BOSS_NOT_FOUND'; end if;

  if event_row.global_clear_target is not null then
    select count(*)::integer into global_count
    from public.event_boss_completions c
    where c.event_id=p_event_id
      and c.victories>0;

    if global_count>=event_row.global_clear_target
       and event_row.boss_kind<>'sector_incursion'
    then
      return jsonb_build_object(
        'first_victory',false,
        'gold',0,
        'experience',0,
        'special_reward_awarded',false,
        'special_reward_item_id',event_row.special_reward_item_id,
        'event_already_resolved',true,
        'global_clear_count',event_row.global_clear_target,
        'global_clear_target',event_row.global_clear_target,
        'global_resolved',true
      );
    end if;
  end if;

  select * into completion
  from public.event_boss_completions
  where event_id=p_event_id and character_id=p_character_id
  for update;

  if completion.event_id is null then
    first_victory:=true;
    if event_row.boss_kind='sector_incursion' then
      reward_gold:=50;
      reward_exp:=100;
    else
      reward_gold:=event_row.first_reward_gold;
      reward_exp:=event_row.first_reward_experience;
    end if;

    insert into public.event_boss_completions(
      event_id,character_id,victories,special_reward_claimed,first_victory_at,last_victory_at
    )
    values(
      p_event_id,p_character_id,1,event_row.special_reward_item_id is not null,now(),now()
    );

    if event_row.special_reward_item_id is not null then
      perform private.grant_character_item(
        p_character_id,
        event_row.special_reward_item_id,
        1,
        jsonb_build_object(
          'source','event_boss',
          'event_boss_id',p_event_id,
          'first_victory',true
        )
      );
      special_awarded:=true;
    end if;
  elsif event_row.max_victories_per_character is not null
        and completion.victories>=event_row.max_victories_per_character
  then
    return jsonb_build_object(
      'first_victory',false,
      'gold',0,
      'experience',0,
      'special_reward_awarded',false,
      'special_reward_item_id',event_row.special_reward_item_id,
      'victory_limit_reached',true
    );
  else
    if event_row.boss_kind='sector_incursion' then
      reward_gold:=50;
      reward_exp:=100;
    else
      reward_gold:=event_row.repeat_reward_gold;
      reward_exp:=event_row.repeat_reward_experience;
    end if;

    update public.event_boss_completions
    set victories=victories+1,
        last_victory_at=now()
    where event_id=p_event_id and character_id=p_character_id;
  end if;

  if event_row.global_clear_target is not null then
    select count(*)::integer into global_count
    from public.event_boss_completions c
    where c.event_id=p_event_id
      and c.victories>0;

    global_count:=least(global_count,event_row.global_clear_target);
    global_resolved:=global_count>=event_row.global_clear_target;

    if global_resolved then
      if event_row.boss_kind='sector_incursion' then
        with rewarded as (
          update public.event_boss_completions c
          set global_reward_claimed=true
          where c.event_id=p_event_id
            and c.victories>0
            and coalesce(c.global_reward_claimed,false)=false
          returning c.character_id
        ),
        paid as (
          update public.character_progress cp
          set gold=cp.gold+50,
              experience=cp.experience+150,
              updated_at=now()
          where cp.character_id in (select character_id from rewarded)
          returning cp.character_id
        )
        select count(*)::integer into global_bonus_recipients from paid;
      end if;

      update public.event_boss_events
      set enabled=false,updated_at=now()
      where id=p_event_id;
    end if;
  end if;

  perform private.log_equipped_item_milestone(
    p_character_id,
    'event_victory',
    'Победа в мировом событии',
    'Владелец предмета участвовал в победе над «'||event_row.name||'».',
    jsonb_build_object(
      'event_id',event_row.id,
      'event_slug',event_row.slug,
      'event_name',event_row.name,
      'boss_kind',event_row.boss_kind
    )
  );

  update public.character_progress
  set gold=gold+reward_gold,
      experience=experience+reward_exp,
      hp_regen_anchor_at=now(),
      mana_regen_anchor_at=now(),
      updated_at=now()
  where character_id=p_character_id;

  return jsonb_build_object(
    'first_victory',first_victory,
    'gold',reward_gold,
    'experience',reward_exp,
    'special_reward_awarded',special_awarded,
    'special_reward_item_id',event_row.special_reward_item_id,
    'global_clear_count',global_count,
    'global_clear_target',event_row.global_clear_target,
    'global_resolved',global_resolved,
    'global_bonus_gold',case when global_resolved and event_row.boss_kind='sector_incursion' then 50 else 0 end,
    'global_bonus_experience',case when global_resolved and event_row.boss_kind='sector_incursion' then 150 else 0 end,
    'global_bonus_recipients',global_bonus_recipients
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.start_event_boss(p_character_id uuid, p_event_id uuid, p_mode text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
  event_row public.event_boss_events;
  template public.enemy_templates;
  stats record;
  solo_run public.dungeon_runs;
  solo_encounter public.combat_encounters;
  party_row public.parties;
  party_run public.party_dungeon_runs;
  party_encounter_id uuid;
  member_row public.party_members;
  run_member public.party_dungeon_run_members;
  party_size integer:=0;
  enemy_hp integer;
  enemy_attack integer;
  enemy_defense integer;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_mode not in ('solo','party') then raise exception 'INVALID_EVENT_BOSS_MODE'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select * into event_row
  from public.event_boss_events
  where id=p_event_id
    and enabled=true
    and now()>=starts_at
    and now()<ends_at
  for update;

  if event_row.id is null then raise exception 'EVENT_BOSS_NOT_ACTIVE'; end if;

  if event_row.boss_kind='sector_incursion' then
    event_row.solo_hp:=greatest(1,ceil(event_row.solo_hp*1.15)::integer);
    event_row.solo_attack:=greatest(1,ceil(event_row.solo_attack*1.08)::integer);
    event_row.solo_defense:=greatest(0,ceil(event_row.solo_defense*1.10)::integer);
    event_row.solo_initiative:=greatest(0,ceil(event_row.solo_initiative*1.05)::integer);
  end if;

  if event_row.solo_only and p_mode='party' then
    raise exception 'EVENT_BOSS_SOLO_ONLY';
  end if;

  if event_row.sector_id is not null
     and not exists(
       select 1
       from public.character_sector_discoveries d
       where d.character_id=p_character_id
         and d.sector_id=event_row.sector_id
     )
  then
    raise exception 'EVENT_BOSS_SECTOR_NOT_DISCOVERED';
  end if;

  if event_row.max_victories_per_character is not null
     and not (event_row.boss_kind='sector_incursion' and p_mode='party')
     and coalesce((
       select c.victories
       from public.event_boss_completions c
       where c.event_id=event_row.id
         and c.character_id=p_character_id
     ),0) >= event_row.max_victories_per_character
  then
    raise exception 'EVENT_BOSS_CHARACTER_LIMIT_REACHED';
  end if;

  select * into template
  from public.enemy_templates
  where id=event_row.enemy_template_id;

  if template.id is null then raise exception 'EVENT_BOSS_TEMPLATE_NOT_FOUND'; end if;

  if p_mode='solo' then
    if private.character_blocked_for_event_boss(p_character_id) then
      raise exception 'CHARACTER_BUSY';
    end if;

    perform private.apply_passive_hp_regen(p_character_id);
    perform private.apply_passive_mana_regen(p_character_id);

    select * into stats
    from private.get_character_combat_stats(p_character_id);

    if stats.level is null then raise exception 'CHARACTER_PROGRESS_NOT_FOUND'; end if;
    if stats.hp_current<=0 then raise exception 'CHARACTER_HAS_NO_HP'; end if;

    insert into public.dungeon_runs(
      character_id,sector_id,status,current_stage,rooms_cleared,total_rooms,
      reward_gold,reward_experience,event_boss_id
    )
    values(
      p_character_id,coalesce(event_row.sector_id,131::smallint),'active','event_boss_combat',0,1,0,0,event_row.id
    )
    returning * into solo_run;

    insert into public.combat_encounters(
      dungeon_run_id,character_id,sector_id,status,round,room_index,is_boss,
      enemy_template_id,enemy_name,enemy_level,enemy_hp_current,enemy_hp_max,
      enemy_attack,enemy_defense,enemy_initiative,enemy_damage_type,enemy_resistances,
      enemy_on_hit_effect_type,enemy_on_hit_effect_chance,
      enemy_on_hit_effect_turns,enemy_on_hit_effect_potency,
      enemy_special_name,enemy_special_damage_multiplier,enemy_special_every_n,
      enemy_special_damage_type,enemy_special_effect_type,enemy_special_effect_chance,
      enemy_special_effect_turns,enemy_special_effect_potency,
      enemy_special_telegraph_text,enemy_special_attack_text,
      enemy_special_kind,enemy_special_value,
      enemy_phase2_hp_percent,enemy_phase2_name,
      enemy_phase2_attack_bonus_percent,enemy_phase2_defense_bonus_percent,
      enemy_phase2_special_every_n,enemy_abilities,enemy_ai_state,
      player_physical_damage_type,player_magic_damage_type,
      player_hp_current,player_hp_max,player_mana_current,player_mana_max
    )
    values(
      solo_run.id,p_character_id,coalesce(event_row.sector_id,131::smallint),'active',0,1,true,
      template.id,event_row.name,event_row.solo_enemy_level,event_row.solo_hp,event_row.solo_hp,
      event_row.solo_attack,event_row.solo_defense,event_row.solo_initiative,
      template.attack_damage_type,template.damage_resistances,
      template.on_hit_effect_type,template.on_hit_effect_chance,
      template.on_hit_effect_turns,template.on_hit_effect_potency,
      template.special_name,template.special_damage_multiplier,template.special_every_n,
      template.special_damage_type,template.special_effect_type,template.special_effect_chance,
      template.special_effect_turns,template.special_effect_potency,
      template.special_telegraph_text,template.special_attack_text,
      template.special_kind,template.special_value,
      template.phase2_hp_percent,template.phase2_name,
      template.phase2_attack_bonus_percent,template.phase2_defense_bonus_percent,
      template.phase2_special_every_n,template.abilities,'{}'::jsonb,
      stats.weapon_damage_type,stats.magic_damage_type,
      stats.hp_current,stats.hp_max,stats.mana_current,stats.mana_max
    )
    returning * into solo_encounter;

    update public.character_progress
    set hp_regen_anchor_at=now(),mana_regen_anchor_at=now()
    where character_id=p_character_id;

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      solo_encounter.id,0,'system','event_boss_start',0,
      stats.hp_current,event_row.solo_hp,
      case
        when event_row.boss_kind='sector_incursion'
          then 'Захваченный сектор: '||event_row.name||'. '
        when event_row.boss_kind='world_enemy'
          then 'Сильный враг: '||event_row.name||'. '
        else 'Временная угроза: '||event_row.name||'. '
      end
      ||'Рекомендуемый уровень: '||event_row.recommended_level||'.'
    );

    return jsonb_build_object(
      'mode','solo',
      'event_id',event_row.id,
      'run_id',solo_run.id,
      'encounter_id',solo_encounter.id
    );
  end if;

  select p.* into party_row
  from public.parties p
  join public.party_members pm on pm.party_id=p.id
  where pm.character_id=p_character_id
    and p.status='active'
  for update of p;

  if party_row.id is null then raise exception 'PARTY_NOT_FOUND'; end if;
  if party_row.leader_character_id<>p_character_id then raise exception 'PARTY_LEADER_REQUIRED'; end if;

  select count(*)::integer into party_size
  from public.party_members
  where party_id=party_row.id;

  if party_size<2 then raise exception 'PARTY_NEEDS_TWO_MEMBERS'; end if;
  if party_size>4 then raise exception 'PARTY_TOO_LARGE'; end if;

  if event_row.boss_kind='sector_incursion'
     and not exists(
       select 1
       from public.party_members pm
       left join public.event_boss_completions c
         on c.event_id=event_row.id
        and c.character_id=pm.character_id
       where pm.party_id=party_row.id
         and (
           event_row.max_victories_per_character is null
           or coalesce(c.victories,0)<event_row.max_victories_per_character
         )
     )
  then
    raise exception 'SECTOR_INCURSION_PARTY_NO_NEW_CONTRIBUTORS';
  end if;

  if exists(
    select 1 from public.party_dungeon_runs
    where party_id=party_row.id and status='active'
  ) then raise exception 'PARTY_DUNGEON_ALREADY_ACTIVE'; end if;

  for member_row in
    select pm.*
    from public.party_members pm
    where pm.party_id=party_row.id
    order by (pm.character_id=party_row.leader_character_id) desc,pm.joined_at,pm.character_id
  loop
    if event_row.sector_id is not null
       and not exists(
         select 1 from public.character_sector_discoveries d
         where d.character_id=member_row.character_id
           and d.sector_id=event_row.sector_id
       )
    then
      raise exception 'PARTY_MEMBER_SECTOR_NOT_DISCOVERED:%',member_row.character_id;
    end if;

    if private.character_blocked_for_event_boss(member_row.character_id) then
      raise exception 'PARTY_MEMBER_BUSY:%',member_row.character_id;
    end if;
    perform private.apply_passive_hp_regen(member_row.character_id);
    perform private.apply_passive_mana_regen(member_row.character_id);
  end loop;

  enemy_hp:=greatest(
    1,
    round(event_row.solo_hp*(1+event_row.party_hp_per_extra*(party_size-1)))::integer
  );
  enemy_attack:=greatest(
    1,
    round(event_row.solo_attack*(1+event_row.party_attack_per_extra*(party_size-1)))::integer
  );
  enemy_defense:=greatest(
    0,
    round(event_row.solo_defense*(1+event_row.party_defense_per_extra*(party_size-1)))::integer
  );

  insert into public.party_dungeon_runs(
    party_id,leader_character_id,sector_id,status,current_stage,rooms_cleared,total_rooms,
    reward_gold,reward_experience,member_count,event_boss_id
  )
  values(
    party_row.id,p_character_id,coalesce(event_row.sector_id,131::smallint),'active','event_boss_combat',
    0,1,0,0,party_size,event_row.id
  )
  returning * into party_run;

  insert into public.party_dungeon_run_members(run_id,character_id,joined_order)
  select
    party_run.id,
    pm.character_id,
    row_number() over(
      order by (pm.character_id=party_row.leader_character_id) desc,pm.joined_at,pm.character_id
    )::smallint
  from public.party_members pm
  where pm.party_id=party_row.id;

  insert into public.party_combat_encounters(
    run_id,room_index,is_boss,status,round,
    enemy_template_id,enemy_name,enemy_level,
    enemy_hp_current,enemy_hp_max,enemy_attack,enemy_defense,enemy_initiative,
    enemy_damage_type,enemy_resistances,
    enemy_on_hit_effect_type,enemy_on_hit_effect_chance,
    enemy_on_hit_effect_turns,enemy_on_hit_effect_potency
  )
  values(
    party_run.id,1,true,'active',1,
    template.id,event_row.name,event_row.solo_enemy_level,
    enemy_hp,enemy_hp,enemy_attack,enemy_defense,event_row.solo_initiative,
    template.attack_damage_type,template.damage_resistances,
    template.on_hit_effect_type,template.on_hit_effect_chance,
    template.on_hit_effect_turns,template.on_hit_effect_potency
  )
  returning id into party_encounter_id;

  for run_member in
    select *
    from public.party_dungeon_run_members
    where run_id=party_run.id
    order by joined_order
  loop
    select * into stats
    from private.get_character_combat_stats(run_member.character_id);

    if stats.level is null then raise exception 'CHARACTER_PROGRESS_NOT_FOUND'; end if;
    if stats.hp_current<=0 then raise exception 'PARTY_MEMBER_HAS_NO_HP:%',run_member.character_id; end if;

    insert into public.party_combat_member_states(
      encounter_id,character_id,hp_current,hp_max,mana_current,mana_max,
      downed,guard_percent,taunt_chance
    )
    values(
      party_encounter_id,run_member.character_id,
      stats.hp_current,stats.hp_max,stats.mana_current,stats.mana_max,
      false,0,private.character_taunt_chance(run_member.character_id)
    );

    update public.character_progress
    set hp_regen_anchor_at=now(),mana_regen_anchor_at=now()
    where character_id=run_member.character_id;
  end loop;

  insert into public.party_combat_turns(
    encounter_id,round,actor_type,action_type,damage,message
  )
  values(
    party_encounter_id,1,'system','event_boss_start',0,
    case
      when event_row.boss_kind='sector_incursion'
        then 'Группа начинает зачистку захваченного сектора: '||event_row.name||'. '
      else 'Группа вступает в бой с временной угрозой: '||event_row.name||'. '
    end
    ||'У каждого участника по одному действию за раунд.'
  );

  return jsonb_build_object(
    'mode','party',
    'event_id',event_row.id,
    'run_id',party_run.id,
    'encounter_id',party_encounter_id,
    'party_size',party_size,
    'enemy_hp',enemy_hp,
    'enemy_attack',enemy_attack,
    'enemy_defense',enemy_defense
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_visible_sector_incursions(p_character_id uuid)
 RETURNS TABLE(event_id uuid, name text, description text, sector_id smallint, grid_col smallint, grid_row smallint, ends_at timestamp with time zone, enemy_level integer, enemy_hp integer, enemy_attack integer, enemy_defense integer, clear_count integer, clear_target integer, contributed boolean, party_id uuid, party_member_count integer, is_party_leader boolean, solo_run_id uuid, solo_run_status text, party_run_id uuid, party_run_status text, character_busy boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  return query
  with party_info as (
    select p.id,p.leader_character_id,count(pm2.character_id)::integer member_count
    from public.parties p
    join public.party_members pm on pm.party_id=p.id and pm.character_id=p_character_id
    join public.party_members pm2 on pm2.party_id=p.id
    where p.status='active'
    group by p.id,p.leader_character_id
    limit 1
  )
  select
    e.id,e.name,e.description,e.sector_id,ms.grid_col,ms.grid_row,e.ends_at,
    e.solo_enemy_level,
    greatest(1,ceil(e.solo_hp*1.15)::integer),
    greatest(1,ceil(e.solo_attack*1.08)::integer),
    greatest(0,ceil(e.solo_defense*1.10)::integer),
    least(
      e.global_clear_target,
      (select count(*)::integer from public.event_boss_completions c where c.event_id=e.id and c.victories>0)
    ),
    e.global_clear_target,
    exists(
      select 1 from public.event_boss_completions c
      where c.event_id=e.id and c.character_id=p_character_id and c.victories>0
    ),
    pi.id,coalesce(pi.member_count,0),coalesce(pi.leader_character_id=p_character_id,false),
    solo.id,solo.status,
    party_run.id,party_run.status,
    private.character_blocked_for_event_boss(p_character_id)
  from public.event_boss_events e
  join public.map_sectors ms on ms.id=e.sector_id
  join public.character_sector_discoveries d
    on d.character_id=p_character_id and d.sector_id=e.sector_id
  left join party_info pi on true
  left join lateral(
    select dr.*
    from public.dungeon_runs dr
    where dr.character_id=p_character_id and dr.event_boss_id=e.id
    order by (dr.status='active') desc,dr.created_at desc
    limit 1
  ) solo on true
  left join lateral(
    select pr.*
    from public.party_dungeon_runs pr
    join public.party_dungeon_run_members prm on prm.run_id=pr.id
    where prm.character_id=p_character_id and pr.event_boss_id=e.id
    order by (pr.status='active') desc,pr.created_at desc
    limit 1
  ) party_run on true
  where e.enabled=true
    and e.boss_kind='sector_incursion'
    and e.global_clear_target is not null
    and now()>=e.starts_at and now()<e.ends_at
  order by e.ends_at,e.name;
end;
$function$;

CREATE OR REPLACE FUNCTION private.finish_combat_victory(p_encounter_id uuid, p_round integer, p_player_hp integer, p_player_mana integer)
 RETURNS combat_encounters
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  encounter public.combat_encounters;
  run_row public.dungeon_runs;
  cleared_rooms integer;
  is_final_room boolean;
  room_drop_count integer:=0;
  chest_drop_count integer:=0;
  dungeon_danger integer:=0;
  character_level integer:=1;
  actual_reward_exp integer:=0;
  actual_reward_gold integer:=0;
  event_reward jsonb;
  spirit_trophy text;
begin
  select * into encounter
  from public.combat_encounters
  where id=p_encounter_id
  for update;

  if encounter.id is null then raise exception 'COMBAT_NOT_FOUND'; end if;

  if encounter.death_spirit_id is not null then
    spirit_trophy:=private.resolve_death_spirit_victory(encounter.death_spirit_id,encounter.character_id);
    update public.character_progress
    set hp_regen_anchor_at=now(),mana_regen_anchor_at=now(),updated_at=now()
    where character_id=encounter.character_id;
    update public.combat_encounters
    set status='victory',round=p_round,enemy_hp_current=0,
        player_hp_current=p_player_hp,player_mana_current=p_player_mana,
        ended_at=coalesce(ended_at,now())
    where id=encounter.id returning * into encounter;
    insert into public.combat_turns(encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message)
    values(encounter.id,p_round,'system','death_spirit_victory',0,p_player_hp,0,
      case when spirit_trophy is null
        then 'Дух рассеян. У него не было удерживаемого снаряжения.'
        else 'Дух рассеян. Получено снаряжение: '||spirit_trophy||'.' end);
    delete from public.combat_status_effects where encounter_id=encounter.id;
    return encounter;
  end if;

  select * into run_row
  from public.dungeon_runs
  where id=encounter.dungeon_run_id
  for update;

  if run_row.hunting_attempt_id is not null then
    update public.combat_encounters
    set status='victory',round=p_round,enemy_hp_current=0,
        player_hp_current=p_player_hp,player_mana_current=p_player_mana,
        ended_at=coalesce(ended_at,now())
    where id=encounter.id
    returning * into encounter;

    update public.dungeon_runs
    set status='completed',current_stage='hunting_victory',rooms_cleared=1,
        reward_gold=0,reward_experience=0,ended_at=coalesce(ended_at,now())
    where id=run_row.id;

    update private.hunting_attempts
    set status='victory',resolved_at=now()
    where id=run_row.hunting_attempt_id;

    update public.character_progress
    set hp_regen_anchor_at=now(),mana_regen_anchor_at=now(),updated_at=now()
    where character_id=encounter.character_id;

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    ) values(
      encounter.id,p_round,'system','hunting_victory',0,p_player_hp,0,
      'Сильный монстр повержен. Давление охоты в регионе не сбрасывается: при 6/6 следующая охота снова приведёт к сильному монстру.'
    );

    delete from public.combat_status_effects where encounter_id=encounter.id;
    return encounter;
  end if;

  if run_row.event_boss_id is not null then
    update public.combat_encounters
    set status='victory',round=p_round,enemy_hp_current=0,
        player_hp_current=p_player_hp,player_mana_current=p_player_mana,
        ended_at=coalesce(ended_at,now())
    where id=encounter.id
    returning * into encounter;

    event_reward:=private.grant_event_boss_victory(run_row.event_boss_id,encounter.character_id);

    update public.dungeon_runs
    set status='completed',current_stage='event_boss_victory',rooms_cleared=1,
        reward_gold=coalesce((event_reward->>'gold')::integer,0),
        reward_experience=coalesce((event_reward->>'experience')::integer,0),
        ended_at=coalesce(ended_at,now())
    where id=run_row.id;

    update public.character_progress
    set hp_regen_anchor_at=now(),mana_regen_anchor_at=now()
    where character_id=encounter.character_id;

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    ) values(
      encounter.id,p_round,'system','event_boss_victory',0,p_player_hp,0,
      'Событие завершено победой. Награда: '||(event_reward->>'gold')||' золота и '||(event_reward->>'experience')||' опыта.'
      ||case when coalesce((event_reward->>'special_reward_awarded')::boolean,false)
        then ' Получена особая награда.' else '' end
      ||case when coalesce((event_reward->>'global_resolved')::boolean,false)
        then ' Глобальная угроза полностью устранена.'
          ||case
            when coalesce((event_reward->>'global_bonus_recipients')::integer,0)>0
            then ' Всем участникам с засчитанным вкладом дополнительно выдано 50 золота и 150 опыта.'
            else ''
          end
        else '' end
    );

    delete from public.combat_status_effects where encounter_id=encounter.id;
    return encounter;
  end if;

  select greatest(0,least(10,coalesce(sd.danger_level,0))) into dungeon_danger
  from public.sector_details sd
  where sd.sector_id=run_row.sector_id;

  select coalesce(cp.level,1) into character_level
  from public.character_progress cp
  where cp.character_id=encounter.character_id;

  actual_reward_exp:=private.scaled_dungeon_xp(
    dungeon_danger,
    character_level,
    case
      when dungeon_danger=0 then 15
      else 50+dungeon_danger*45+
        (case
          when dungeon_danger<=2 then 2
          when dungeon_danger<=4 then 3
          when dungeon_danger<=6 then 4
          when dungeon_danger<=8 then 5
          else 6
        end)*18
    end
  );

  actual_reward_gold:=private.scaled_dungeon_gold(
    dungeon_danger,
    character_level,
    case
      when dungeon_danger=0 then 40
      else 40+dungeon_danger*25+
        (case
          when dungeon_danger<=2 then 2
          when dungeon_danger<=4 then 3
          when dungeon_danger<=6 then 4
          when dungeon_danger<=8 then 5
          else 6
        end)*12
    end
  );

  actual_reward_exp:=greatest(
    0,
    round(actual_reward_exp
      *private.dungeon_repeat_xp_multiplier_percent(
        encounter.character_id,run_row.sector_id,run_row.id,null
      )/100.0
    )::integer
  );
  actual_reward_gold:=greatest(
    1,
    round(actual_reward_gold
      *private.dungeon_repeat_gold_multiplier_percent(
        encounter.character_id,run_row.sector_id,run_row.id,null
      )/100.0
    )::integer
  );

  if coalesce(run_row.reward_exhausted,false) then
    actual_reward_exp:=0;
    actual_reward_gold:=0;
  end if;

  update public.combat_encounters
  set status='victory',round=p_round,enemy_hp_current=0,
      player_hp_current=p_player_hp,
      player_mana_current=p_player_mana,
      ended_at=coalesce(ended_at,now())
  where id=encounter.id
  returning * into encounter;

  room_drop_count:=private.roll_combat_loot(encounter.id);

  if room_drop_count>0 then
    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      encounter.id,p_round,'system','loot',0,p_player_hp,0,
      'После боя найдено предметов: '||room_drop_count||'. Они добавлены в инвентарь.'
    );
  end if;

  update public.character_progress
  set hp_regen_anchor_at=now(),mana_regen_anchor_at=now()
  where character_id=encounter.character_id;

  cleared_rooms:=greatest(run_row.rooms_cleared,encounter.room_index);
  is_final_room:=cleared_rooms>=run_row.total_rooms;

  if is_final_room then
    update public.dungeon_runs
    set status='completed',current_stage='cleared',
        rooms_cleared=cleared_rooms,
        reward_gold=actual_reward_gold,
        reward_experience=actual_reward_exp,
        ended_at=coalesce(ended_at,now())
    where id=encounter.dungeon_run_id;

    update public.character_progress
    set gold=gold+actual_reward_gold,
        experience=experience+actual_reward_exp,
        updated_at=now()
    where character_id=encounter.character_id;

    insert into public.character_sector_site_progress(
      character_id,sector_id,site_type,status,first_interacted_at,completed_at,updated_at
    )
    values(
      encounter.character_id,encounter.sector_id,'dungeon','cleared',
      run_row.started_at,now(),now()
    )
    on conflict(character_id,sector_id) do update
    set site_type='dungeon',status='cleared',completed_at=now(),updated_at=now();

    chest_drop_count:=private.roll_dungeon_completion_loot(run_row.id);

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      encounter.id,p_round,'system','dungeon_victory',0,p_player_hp,0,
      case
        when coalesce(run_row.reward_exhausted,false)
        then 'Противник повержен. Подземелье зачищено. Лимит наград этого 18-часового цикла исчерпан: опыт, золото и лут не выдаются.'
        else 'Противник повержен. Подземелье зачищено. Награда: '
          ||actual_reward_gold||' золота и '||actual_reward_exp||' опыта.'
          ||case
            when chest_drop_count>0
            then ' В финальном тайнике найдено предметов: '||chest_drop_count||'.'
            else ''
          end
      end
    );
  else
    update public.dungeon_runs
    set current_stage='room_'||(cleared_rooms+1)||'_ready',
        rooms_cleared=cleared_rooms
    where id=encounter.dungeon_run_id;

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      encounter.id,p_round,'system','room_victory',0,p_player_hp,0,
      'Зал '||cleared_rooms||' очищен. Впереди ещё '
      ||(run_row.total_rooms-cleared_rooms)||'.'
    );
  end if;

  delete from public.combat_status_effects where encounter_id=encounter.id;
  return encounter;
end;
$function$;

CREATE OR REPLACE FUNCTION private.finish_party_combat_victory(p_encounter_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  encounter public.party_combat_encounters;
  run_row public.party_dungeon_runs;
  member_row public.party_dungeon_run_members;
  cleared_rooms integer;
  is_final boolean;
  room_drops integer:=0;
  chest_drops integer:=0;
  member_level integer:=1;
  member_reward_exp integer:=0;
  member_reward_gold integer:=0;
  dungeon_danger integer:=0;
  event_reward jsonb;
begin
  select * into encounter
  from public.party_combat_encounters
  where id=p_encounter_id
  for update;

  if encounter.id is null then raise exception 'PARTY_COMBAT_NOT_FOUND'; end if;

  select * into run_row
  from public.party_dungeon_runs
  where id=encounter.run_id
  for update;

  if run_row.event_boss_id is not null then
    update public.party_combat_encounters
    set status='victory',enemy_hp_current=0,ended_at=coalesce(ended_at,now())
    where id=encounter.id;

    update public.party_dungeon_runs
    set status='completed',current_stage='event_boss_victory',rooms_cleared=1,
        ended_at=coalesce(ended_at,now())
    where id=run_row.id;

    for member_row in
      select * from public.party_dungeon_run_members
      where run_id=run_row.id
      order by joined_order
    loop
      event_reward:=private.grant_event_boss_victory(run_row.event_boss_id,member_row.character_id);
    end loop;

    insert into public.party_combat_turns(
      encounter_id,round,actor_type,action_type,damage,message
    ) values(
      encounter.id,encounter.round,'system','event_boss_victory',0,
      case
        when coalesce((event_reward->>'global_resolved')::boolean,false)
        then 'Захваченный сектор полностью освобождён. Каждый новый вклад получает личную награду; всем участникам с засчитанным вкладом дополнительно выдано 50 золота и 150 опыта.'
        else 'Временная угроза побеждена. Вклад каждого участника учитывается отдельно; повторный вклад одного и того же персонажа не засчитывается.'
      end 
    );
    return;
  end if;

  select greatest(0,least(10,coalesce(sd.danger_level,0))) into dungeon_danger
  from public.sector_details sd
  where sd.sector_id=run_row.sector_id;

  update public.party_combat_encounters
  set status='victory',
      enemy_hp_current=0,
      ended_at=coalesce(ended_at,now())
  where id=encounter.id;

  room_drops:=private.roll_party_combat_loot(encounter.id);

  cleared_rooms:=greatest(run_row.rooms_cleared,encounter.room_index);
  is_final:=cleared_rooms>=run_row.total_rooms;

  if is_final then
    update public.party_dungeon_runs
    set status='completed',
        current_stage='cleared',
        rooms_cleared=cleared_rooms,
        ended_at=coalesce(ended_at,now())
    where id=run_row.id;

    for member_row in
      select *
      from public.party_dungeon_run_members
      where run_id=run_row.id
      order by joined_order
    loop
      select coalesce(cp.level,1) into member_level
      from public.character_progress cp
      where cp.character_id=member_row.character_id;

      member_reward_exp:=private.scaled_dungeon_xp(
        dungeon_danger,
        member_level,
        case
          when dungeon_danger=0 then 15
          else 50+dungeon_danger*45+
            (case
              when dungeon_danger<=2 then 2
              when dungeon_danger<=4 then 3
              when dungeon_danger<=6 then 4
              when dungeon_danger<=8 then 5
              else 6
            end)*18
        end
      );

      member_reward_gold:=private.scaled_dungeon_gold(
        dungeon_danger,
        member_level,
        case
          when dungeon_danger=0 then 40
          else 40+dungeon_danger*25+
            (case
              when dungeon_danger<=2 then 2
              when dungeon_danger<=4 then 3
              when dungeon_danger<=6 then 4
              when dungeon_danger<=8 then 5
              else 6
            end)*12
        end
      );

      member_reward_exp:=greatest(
        0,
        round(member_reward_exp
          *private.dungeon_repeat_xp_multiplier_percent(
            member_row.character_id,run_row.sector_id,null,run_row.id
          )/100.0
        )::integer
      );
      member_reward_gold:=greatest(
        1,
        round(member_reward_gold
          *private.dungeon_repeat_gold_multiplier_percent(
            member_row.character_id,run_row.sector_id,null,run_row.id
          )/100.0
        )::integer
      );

      if coalesce(member_row.reward_exhausted,false) then
        member_reward_exp:=0;
        member_reward_gold:=0;
      end if;

      update public.character_progress
      set gold=gold+member_reward_gold,
          experience=experience+member_reward_exp,
          hp_regen_anchor_at=now(),
          mana_regen_anchor_at=now(),
          updated_at=now()
      where character_id=member_row.character_id;

      insert into public.character_sector_site_progress(
        character_id,sector_id,site_type,status,
        first_interacted_at,completed_at,updated_at
      )
      values(
        member_row.character_id,run_row.sector_id,'dungeon','cleared',
        run_row.started_at,now(),now()
      )
      on conflict(character_id,sector_id) do update
      set site_type='dungeon',
          status='cleared',
          completed_at=now(),
          updated_at=now();
    end loop;

    chest_drops:=private.roll_party_dungeon_completion_loot(run_row.id);

    insert into public.party_combat_turns(
      encounter_id,round,actor_type,action_type,damage,message
    )
    values(
      encounter.id,encounter.round,'system','dungeon_victory',0,
      case
        when dungeon_danger=0 then
          'Подземелье 0 уровня зачищено. Каждый участник получает 40 золота; опыт зависит от уровня персонажа: LVL 1 = 15, LVL 2 = 11, LVL 3 = 6, LVL 4 = 2, LVL 5+ = 1.'
        else
          'Подземелье зачищено всей группой. Награда каждого участника масштабируется по его уровню относительно сложности данжа; минимум — 35% золота и 5% опыта.'
      end
      ||case
        when exists(
          select 1 from public.party_dungeon_run_members x
          where x.run_id=run_row.id and coalesce(x.reward_exhausted,false)
        )
        then ' Участники, превысившие 25 попыток в текущем 18-часовом цикле, не получают опыт, золото и личный лут.'
        else ''
      end
      ||case when chest_drops>0 then ' В финальном тайнике выпало предметов: '||chest_drops||'.' else '' end
    );
  else
    update public.party_dungeon_runs
    set current_stage='room_'||(cleared_rooms+1)||'_ready',
        rooms_cleared=cleared_rooms
    where id=run_row.id;

    insert into public.party_combat_turns(
      encounter_id,round,actor_type,action_type,damage,message
    )
    values(
      encounter.id,encounter.round,'system','room_victory',0,
      'Зал '||cleared_rooms||' очищен группой. Впереди ещё '
      ||(run_row.total_rooms-cleared_rooms)||'.'
      ||case when room_drops>0 then ' Личная добыча уже добавлена в инвентари.' else '' end
    );
  end if;
end;
$function$;
