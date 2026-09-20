CREATE OR REPLACE FUNCTION private.world_enemy_reward_experience(p_enemy_level integer, p_first_victory boolean DEFAULT true)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  select case
    when coalesce(p_first_victory,true)
      then greatest(80,80+greatest(1,coalesce(p_enemy_level,1))*40)
    else greatest(40,round((80+greatest(1,coalesce(p_enemy_level,1))*40)*0.5)::integer)
  end;
$function$;

CREATE OR REPLACE FUNCTION private.world_enemy_reward_gold(p_enemy_level integer, p_first_victory boolean DEFAULT true)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  select case
    when coalesce(p_first_victory,true)
      then greatest(40,40+greatest(1,coalesce(p_enemy_level,1))*20)
    else greatest(20,round((40+greatest(1,coalesce(p_enemy_level,1))*20)*0.5)::integer)
  end;
$function$;

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
    elsif event_row.boss_kind='world_enemy' then
      reward_gold:=private.world_enemy_reward_gold(event_row.solo_enemy_level,true);
      reward_exp:=private.world_enemy_reward_experience(event_row.solo_enemy_level,true);
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
    elsif event_row.boss_kind='world_enemy' then
      reward_gold:=private.world_enemy_reward_gold(event_row.solo_enemy_level,false);
      reward_exp:=private.world_enemy_reward_experience(event_row.solo_enemy_level,false);
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

CREATE OR REPLACE FUNCTION public.get_visible_world_strong_enemies_v2(p_character_id uuid)
 RETURNS TABLE(event_id uuid, slug text, name text, description text, sector_id smallint, grid_col smallint, grid_row smallint, starts_at timestamp with time zone, ends_at timestamp with time zone, recommended_level integer, enemy_level integer, enemy_hp integer, enemy_attack integer, enemy_defense integer, enemy_initiative integer, enemy_damage_type text, enemy_resistances jsonb, phase2_hp_percent integer, phase2_name text, mechanics jsonb, reward_name text, reward_description text, reward_gold integer, reward_experience integer, victories integer, defeated boolean, solo_only boolean, run_id uuid, run_status text, encounter_id uuid, encounter_status text, character_busy boolean)
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
  select
    e.id,
    e.slug,
    e.name,
    e.description,
    e.sector_id,
    ms.grid_col,
    ms.grid_row,
    e.starts_at,
    e.ends_at,
    e.recommended_level,
    e.solo_enemy_level,
    e.solo_hp,
    e.solo_attack,
    e.solo_defense,
    e.solo_initiative,
    et.attack_damage_type,
    et.damage_resistances,
    et.phase2_hp_percent::integer,
    et.phase2_name,
    e.mechanics,
    reward.name,
    reward.description,
    private.world_enemy_reward_gold(e.solo_enemy_level,coalesce(comp.victories,0)=0),
    private.world_enemy_reward_experience(e.solo_enemy_level,coalesce(comp.victories,0)=0),
    coalesce(comp.victories,0),
    (
      e.max_victories_per_character is not null
      and coalesce(comp.victories,0)>=e.max_victories_per_character
    ),
    e.solo_only,
    solo.id,
    solo.status,
    ce.id,
    ce.status,
    private.character_blocked_for_event_boss(p_character_id)
  from public.event_boss_events e
  join public.map_sectors ms on ms.id=e.sector_id
  join public.enemy_templates et on et.id=e.enemy_template_id
  join public.character_sector_discoveries d
    on d.character_id=p_character_id
   and d.sector_id=e.sector_id
  left join public.item_definitions reward on reward.id=e.special_reward_item_id
  left join public.event_boss_completions comp
    on comp.event_id=e.id
   and comp.character_id=p_character_id
  left join lateral(
    select dr.*
    from public.dungeon_runs dr
    where dr.character_id=p_character_id
      and dr.event_boss_id=e.id
    order by (dr.status='active') desc,dr.created_at desc
    limit 1
  ) solo on true
  left join lateral(
    select combat.*
    from public.combat_encounters combat
    where combat.dungeon_run_id=solo.id
    order by combat.created_at desc
    limit 1
  ) ce on true
  where e.enabled=true
    and e.boss_kind='world_enemy'
    and e.sector_id is not null
    and now()>=e.starts_at
    and now()<e.ends_at
  order by e.ends_at,e.name;
end;
$function$;

revoke all on function private.world_enemy_reward_experience(integer,boolean) from public,anon,authenticated;
revoke all on function private.world_enemy_reward_gold(integer,boolean) from public,anon,authenticated;

revoke all on function public.get_visible_world_strong_enemies_v2(uuid) from public,anon;
grant execute on function public.get_visible_world_strong_enemies_v2(uuid) to authenticated;

update public.event_boss_events
set first_reward_gold=private.world_enemy_reward_gold(solo_enemy_level,true),
    first_reward_experience=private.world_enemy_reward_experience(solo_enemy_level,true),
    repeat_reward_gold=private.world_enemy_reward_gold(solo_enemy_level,false),
    repeat_reward_experience=private.world_enemy_reward_experience(solo_enemy_level,false),
    updated_at=now()
where boss_kind='world_enemy';
