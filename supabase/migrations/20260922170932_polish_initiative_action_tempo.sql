
do $migration$
declare
  v_def text;
  old_block text;
  new_block text;
begin
  select pg_get_functiondef(p.oid)
  into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='private'
    and p.proname='perform_combat_action_internal'
    and pg_get_function_identity_arguments(p.oid)='p_encounter_id uuid, p_mode text, p_spell_id uuid, p_character_item_id uuid';

  if v_def is null then raise exception 'perform_combat_action_internal definition not found'; end if;

  old_block := $old$
  tempo_gain:=private.initiative_tempo_gain(stats.initiative,encounter.enemy_initiative);
  tempo_total:=coalesce(encounter.player_initiative_meter,0)+tempo_gain;

  if tempo_total>=100 then
    update public.combat_encounters
    set player_initiative_meter=least(99,tempo_total-100)
    where id=encounter.id;

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    )
    values(
      encounter.id,next_round,'system','initiative_extra_action',0,
      player_hp_after,enemy_hp_after,
      'Инициатива продвигает персонажа вперёд по очереди: доступно ещё одно полное действие до хода противника.'
    );

    select * into encounter
    from public.combat_encounters
    where id=encounter.id;

    return encounter;
  elsif tempo_gain>0 then
    update public.combat_encounters
    set player_initiative_meter=least(99,tempo_total)
    where id=encounter.id;
    encounter.player_initiative_meter:=least(99,tempo_total);
  end if;
$old$;

  new_block := $new$
  if not player_stunned then
    tempo_gain:=private.initiative_tempo_gain(stats.initiative,encounter.enemy_initiative);
    tempo_total:=coalesce(encounter.player_initiative_meter,0)+tempo_gain;

    if tempo_total>=100 then
      update public.combat_encounters
      set player_initiative_meter=least(99,tempo_total-100)
      where id=encounter.id;

      insert into public.combat_turns(
        encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
      )
      values(
        encounter.id,next_round,'system','initiative_extra_action',0,
        player_hp_after,enemy_hp_after,
        'Высокая инициатива продвигает персонажа по шкале действий: доступно ещё одно полное действие до хода противника.'
      );

      select * into encounter
      from public.combat_encounters
      where id=encounter.id;

      return encounter;
    elsif tempo_gain>0 then
      update public.combat_encounters
      set player_initiative_meter=least(99,tempo_total)
      where id=encounter.id;
      encounter.player_initiative_meter:=least(99,tempo_total);
    end if;
  end if;
$new$;

  if position(old_block in v_def)=0 then
    raise exception 'solo tempo block anchor not found';
  end if;

  v_def:=replace(v_def,old_block,new_block);
  execute v_def;
end
$migration$;

do $migration$
declare
  v_def text;
  old_block text;
  new_block text;
begin
  select pg_get_functiondef(p.oid)
  into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='private'
    and p.proname='advance_party_combat_round'
    and pg_get_function_identity_arguments(p.oid)='p_encounter_id uuid, p_character_id uuid';

  if v_def is null then raise exception 'advance_party_combat_round definition not found'; end if;

  v_def:=replace(
    v_def,
    '  tempo_total integer:=0;' || chr(10),
    '  tempo_total integer:=0;' || chr(10) ||
    '  actor_can_gain_tempo boolean:=false;' || chr(10) ||
    '  last_actor_action text;' || chr(10)
  );

  old_block := $old$
  select * into actor_stats
  from private.get_character_combat_stats(p_character_id);

  select coalesce(initiative_meter,0)
  into actor_meter
  from public.party_combat_member_states
  where encounter_id=encounter.id
    and character_id=p_character_id
  for update;

  tempo_gain:=private.initiative_tempo_gain(actor_stats.initiative,encounter.enemy_initiative);
  tempo_total:=coalesce(actor_meter,0)+tempo_gain;

  if tempo_total>=100 then
    update public.party_combat_member_states
    set initiative_meter=least(99,tempo_total-100),
        updated_at=now()
    where encounter_id=encounter.id
      and character_id=p_character_id;

    insert into public.party_combat_turns(
      encounter_id,round,actor_type,actor_character_id,action_type,damage,message
    )
    values(
      encounter.id,encounter.round,'system',p_character_id,
      'initiative_extra_action',0,
      'Высокая инициатива продвигает героя вперёд по очереди: он получает ещё одно полное действие до хода противника.'
    );

    return jsonb_build_object(
      'status','active',
      'enemy_hp_current',encounter.enemy_hp_current,
      'enemy_acted',false,
      'round',encounter.round,
      'extra_action',true,
      'initiative_meter',least(99,tempo_total-100)
    );
  elsif tempo_gain>0 then
    update public.party_combat_member_states
    set initiative_meter=least(99,tempo_total),
        updated_at=now()
    where encounter_id=encounter.id
      and character_id=p_character_id;
  end if;
$old$;

  new_block := $new$
  select * into actor_stats
  from private.get_character_combat_stats(p_character_id);

  select coalesce(ms.initiative_meter,0),
         (not ms.downed and not coalesce(prm.lost,false))
  into actor_meter,actor_can_gain_tempo
  from public.party_combat_member_states ms
  left join public.party_dungeon_run_members prm
    on prm.run_id=encounter.run_id
   and prm.character_id=ms.character_id
  where ms.encounter_id=encounter.id
    and ms.character_id=p_character_id
  for update of ms;

  select pct.action_type
  into last_actor_action
  from public.party_combat_turns pct
  where pct.encounter_id=encounter.id
    and pct.actor_character_id=p_character_id
  order by pct.id desc
  limit 1;

  if actor_can_gain_tempo
     and coalesce(last_actor_action,'') not in ('stunned','scroll_last_sacrifice')
  then
    tempo_gain:=private.initiative_tempo_gain(actor_stats.initiative,encounter.enemy_initiative);
    tempo_total:=coalesce(actor_meter,0)+tempo_gain;

    if tempo_total>=100 then
      update public.party_combat_member_states
      set initiative_meter=least(99,tempo_total-100),
          updated_at=now()
      where encounter_id=encounter.id
        and character_id=p_character_id;

      insert into public.party_combat_turns(
        encounter_id,round,actor_type,actor_character_id,action_type,damage,message
      )
      values(
        encounter.id,encounter.round,'system',p_character_id,
        'initiative_extra_action',0,
        'Высокая инициатива продвигает героя по шкале действий: доступно ещё одно полное действие до хода противника.'
      );

      return jsonb_build_object(
        'status','active',
        'enemy_hp_current',encounter.enemy_hp_current,
        'enemy_acted',false,
        'round',encounter.round,
        'extra_action',true,
        'initiative_meter',least(99,tempo_total-100)
      );
    elsif tempo_gain>0 then
      update public.party_combat_member_states
      set initiative_meter=least(99,tempo_total),
          updated_at=now()
      where encounter_id=encounter.id
        and character_id=p_character_id;
    end if;
  end if;
$old$;

  if position(old_block in v_def)=0 then
    raise exception 'party tempo block anchor not found';
  end if;

  v_def:=replace(v_def,old_block,new_block);
  execute v_def;
end
$migration$;

do $migration$
declare
  v_def text;
  old_block text;
  new_block text;
begin
  select pg_get_functiondef(p.oid)
  into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='perform_pvp_duel_action'
    and pg_get_function_identity_arguments(p.oid)='p_duel_id uuid, p_action text, p_spell_id uuid';

  if v_def is null then raise exception 'perform_pvp_duel_action definition not found'; end if;

  old_block := $old$
  tempo_gain:=private.initiative_tempo_gain(actor.initiative,target.initiative);
  tempo_total:=coalesce(actor.initiative_meter,0)+tempo_gain;

  if tempo_total>=100 then
    update public.pvp_duel_states
    set initiative_meter=least(99,tempo_total-100),
        updated_at=now()
    where duel_id=d.id and character_id=actor_id;

    update public.pvp_duels
    set current_turn_character_id=actor_id,
        round=round+1,
        turn_started_at=now(),
        updated_at=now()
    where id=d.id;

    insert into public.pvp_duel_turns(
      duel_id,round,actor_character_id,action_type,damage,healing,message
    )
    values(
      d.id,d.round+1,null,'initiative_extra_action',0,0,
      coalesce(actor_name,'Персонаж')||
      ' за счёт высокой инициативы продвигается вперёд по очереди и получает ещё одно полное действие.'
    );
  else
    if tempo_gain>0 then
      update public.pvp_duel_states
      set initiative_meter=least(99,tempo_total),
          updated_at=now()
      where duel_id=d.id and character_id=actor_id;
    end if;

    update public.pvp_duels
    set current_turn_character_id=target_id,
        round=round+1,
        turn_started_at=now(),
        updated_at=now()
    where id=d.id;
  end if;
$old$;

  new_block := $new$
  if not stunned then
    tempo_gain:=private.initiative_tempo_gain(actor.initiative,target.initiative);
    tempo_total:=coalesce(actor.initiative_meter,0)+tempo_gain;
  else
    tempo_gain:=0;
    tempo_total:=coalesce(actor.initiative_meter,0);
  end if;

  if not stunned and tempo_total>=100 then
    update public.pvp_duel_states
    set initiative_meter=least(99,tempo_total-100),
        updated_at=now()
    where duel_id=d.id and character_id=actor_id;

    update public.pvp_duels
    set current_turn_character_id=actor_id,
        round=round+1,
        turn_started_at=now(),
        updated_at=now()
    where id=d.id;

    insert into public.pvp_duel_turns(
      duel_id,round,actor_character_id,action_type,damage,healing,message
    )
    values(
      d.id,d.round+1,null,'initiative_extra_action',0,0,
      coalesce(actor_name,'Персонаж')||
      ' за счёт высокой инициативы продвигается по шкале действий и получает ещё одно полное действие.'
    );
  else
    if tempo_gain>0 then
      update public.pvp_duel_states
      set initiative_meter=least(99,tempo_total),
          updated_at=now()
      where duel_id=d.id and character_id=actor_id;
    end if;

    update public.pvp_duels
    set current_turn_character_id=target_id,
        round=round+1,
        turn_started_at=now(),
        updated_at=now()
    where id=d.id;
  end if;
$new$;

  if position(old_block in v_def)=0 then
    raise exception 'pvp tempo block anchor not found';
  end if;

  v_def:=replace(v_def,old_block,new_block);
  execute v_def;
end
$migration$;
