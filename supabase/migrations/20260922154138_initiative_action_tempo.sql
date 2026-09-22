alter table public.combat_encounters
  add column if not exists player_initiative_meter smallint not null default 0;

alter table public.party_combat_member_states
  add column if not exists initiative_meter smallint not null default 0;

alter table public.pvp_duel_states
  add column if not exists initiative_meter smallint not null default 0;

alter table public.combat_encounters
  drop constraint if exists combat_encounters_player_initiative_meter_check;
alter table public.combat_encounters
  add constraint combat_encounters_player_initiative_meter_check
  check (player_initiative_meter between 0 and 99);

alter table public.party_combat_member_states
  drop constraint if exists party_combat_member_states_initiative_meter_check;
alter table public.party_combat_member_states
  add constraint party_combat_member_states_initiative_meter_check
  check (initiative_meter between 0 and 99);

alter table public.pvp_duel_states
  drop constraint if exists pvp_duel_states_initiative_meter_check;
alter table public.pvp_duel_states
  add constraint pvp_duel_states_initiative_meter_check
  check (initiative_meter between 0 and 99);

create or replace function private.initiative_tempo_gain(
  p_actor_initiative integer,
  p_reference_initiative integer
)
returns smallint
language sql
immutable
set search_path to 'pg_catalog'
as $$
  select case
    when greatest(0,coalesce(p_actor_initiative,0))
         <= greatest(10,coalesce(p_reference_initiative,0))
      then 0::smallint
    else least(
      25,
      greatest(
        0,
        floor(
          (
            (
              (100.0 + greatest(0,coalesce(p_actor_initiative,0))*3.0)
              /
              (100.0 + greatest(10,coalesce(p_reference_initiative,0))*3.0)
            ) - 1.0
          ) * 100.0
        )::integer
      )
    )::smallint
  end;
$$;

comment on function private.initiative_tempo_gain(integer,integer) is
'HSR-like soft initiative tempo. Fast actors accumulate 0-25 tempo per full action; 100 grants one additional full action. Reference initiative is floored at 10 to avoid trivial enemies producing permanent doubles.';

do $migration$
declare
  v_def text;
  v_before text;
begin
  select pg_get_functiondef(p.oid)
  into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='private'
    and p.proname='perform_combat_action_internal'
    and pg_get_function_identity_arguments(p.oid)='p_encounter_id uuid, p_mode text, p_spell_id uuid, p_character_item_id uuid';

  if v_def is null then
    raise exception 'perform_combat_action_internal definition not found';
  end if;

  if position('player_initiative_meter' in v_def)=0 then
    v_before:=v_def;

    v_def:=replace(
      v_def,
$old$
  enemy_attack_effective integer:=0;
$old$,
$new$
  enemy_attack_effective integer:=0;
  tempo_gain integer:=0;
  tempo_total integer:=0;
$new$
    );

    if v_def=v_before then
      raise exception 'solo initiative declaration anchor not found';
    end if;

    v_before:=v_def;
    v_def:=replace(
      v_def,
$old$
  if encounter.enemy_bloodshed_stacks>0 then
$old$,
$new$
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

  if encounter.enemy_bloodshed_stacks>0 then
$new$
    );

    if v_def=v_before then
      raise exception 'solo initiative action anchor not found';
    end if;

    execute v_def;
  end if;
end
$migration$;

do $migration$
declare
  v_def text;
  v_before text;
begin
  select pg_get_functiondef(p.oid)
  into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='private'
    and p.proname='advance_party_combat_round'
    and pg_get_function_identity_arguments(p.oid)='p_encounter_id uuid, p_character_id uuid';

  if v_def is null then
    raise exception 'advance_party_combat_round definition not found';
  end if;

  if position('initiative_meter' in v_def)=0 then
    v_before:=v_def;

    v_def:=replace(
      v_def,
$old$
  target_dodged boolean:=false;
$old$,
$new$
  target_dodged boolean:=false;
  actor_stats record;
  actor_meter integer:=0;
  tempo_gain integer:=0;
  tempo_total integer:=0;
$new$
    );

    if v_def=v_before then
      raise exception 'party initiative declaration anchor not found';
    end if;

    v_before:=v_def;
    v_def:=replace(
      v_def,
$old$
  if p_character_id=any(encounter.acted_character_ids) then
$old$,
$new$
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

  if p_character_id=any(encounter.acted_character_ids) then
$new$
    );

    if v_def=v_before then
      raise exception 'party initiative action anchor not found';
    end if;

    execute v_def;
  end if;
end
$migration$;

do $migration$
declare
  v_def text;
  v_before text;
begin
  select pg_get_functiondef(p.oid)
  into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='perform_pvp_duel_action'
    and pg_get_function_identity_arguments(p.oid)='p_duel_id uuid, p_action text, p_spell_id uuid';

  if v_def is null then
    raise exception 'perform_pvp_duel_action definition not found';
  end if;

  if position('initiative_extra_action' in v_def)=0 then
    v_before:=v_def;

    v_def:=replace(
      v_def,
$old$
  white_fang_rupture_damage integer:=0;
$old$,
$new$
  white_fang_rupture_damage integer:=0;
  tempo_gain integer:=0;
  tempo_total integer:=0;
$new$
    );

    if v_def=v_before then
      raise exception 'pvp initiative declaration anchor not found';
    end if;

    v_before:=v_def;
    v_def:=replace(
      v_def,
$old$
  update public.pvp_duels
  set current_turn_character_id=target_id,
      round=round+1,
      turn_started_at=now(),
      updated_at=now()
  where id=d.id;
$old$,
$new$
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
$new$
    );

    if v_def=v_before then
      raise exception 'pvp initiative turn-switch anchor not found';
    end if;

    execute v_def;
  end if;
end
$migration$;

do $migration$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid)
  into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='get_pvp_duel'
    and pg_get_function_identity_arguments(p.oid)='p_duel_id uuid';

  if v_def is not null and position('initiative_meter' in v_def)=0 then
    v_def:=replace(
      v_def,
      $old$          'initiative',s.initiative,$old$,
      $new$          'initiative',s.initiative,'initiative_meter',s.initiative_meter,$new$
    );
    execute v_def;
  end if;
end
$migration$;

revoke all on function private.initiative_tempo_gain(integer,integer) from public,anon,authenticated;
