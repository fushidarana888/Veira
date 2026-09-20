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

    if global_count>=event_row.global_clear_target then
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
    'global_resolved',global_resolved
  );
end;
$function$;

update public.event_boss_events
set first_reward_gold=50,
    first_reward_experience=100,
    repeat_reward_gold=50,
    repeat_reward_experience=100,
    updated_at=now()
where boss_kind='sector_incursion';
