
create or replace function public.get_party_boss_options(p_character_id uuid)
returns table(
  event_id uuid,
  slug text,
  boss_kind text,
  name text,
  description text,
  recommended_level integer,
  sector_id smallint,
  ends_at timestamptz,
  party_size integer,
  fresh_reward_members integer,
  capped_members integer,
  first_reward_gold integer,
  first_reward_experience integer,
  repeat_reward_gold integer,
  repeat_reward_experience integer,
  special_reward_name text
)
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  caller_id uuid:=auth.uid();
  v_party_id uuid;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id
      and c.owner_user_id=caller_id
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select p.id into v_party_id
  from public.parties p
  join public.party_members pm on pm.party_id=p.id
  where pm.character_id=p_character_id
    and p.status='active'
  limit 1;

  if v_party_id is null then return; end if;

  return query
  with members as (
    select pm.character_id
    from public.party_members pm
    where pm.party_id=v_party_id
  ),
  member_count as (
    select count(*)::integer as value from members
  )
  select
    e.id,
    e.slug,
    e.boss_kind,
    e.name,
    e.description,
    e.recommended_level,
    e.sector_id,
    e.ends_at,
    mc.value,
    (
      select count(*)::integer
      from members m
      left join public.event_boss_completions c
        on c.event_id=e.id and c.character_id=m.character_id
      where coalesce(c.victories,0)=0
    ),
    (
      select count(*)::integer
      from members m
      left join public.event_boss_completions c
        on c.event_id=e.id and c.character_id=m.character_id
      where e.max_victories_per_character is not null
        and coalesce(c.victories,0)>=e.max_victories_per_character
    ),
    e.first_reward_gold,
    e.first_reward_experience,
    e.repeat_reward_gold,
    e.repeat_reward_experience,
    reward_item.name
  from public.event_boss_events e
  cross join member_count mc
  left join public.item_definitions reward_item
    on reward_item.id=e.special_reward_item_id
  where e.enabled=true
    and now()>=e.starts_at
    and now()<e.ends_at
    and lower(coalesce(e.mechanics->>'party_disabled','false')) not in ('true','1','yes')
    and (
      e.sector_id is null
      or not exists(
        select 1
        from members m
        where not exists(
          select 1
          from public.character_sector_discoveries d
          where d.character_id=m.character_id
            and d.sector_id=e.sector_id
        )
      )
    )
  order by
    case e.boss_kind
      when 'raid' then 0
      when 'weekly' then 1
      when 'world_enemy' then 2
      when 'sector_incursion' then 3
      else 4
    end,
    e.recommended_level,
    e.name;
end;
$$;

revoke all on function public.get_party_boss_options(uuid) from public,anon;
grant execute on function public.get_party_boss_options(uuid) to authenticated;


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

  if p_mode='party'
     and lower(coalesce(event_row.mechanics->>'party_disabled','false')) in ('true','1','yes')
  then
    raise exception 'EVENT_BOSS_PARTY_DISABLED';
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

  if p_mode='solo'
     and event_row.max_victories_per_character is not null
     and event_row.boss_kind<>'world_enemy'
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