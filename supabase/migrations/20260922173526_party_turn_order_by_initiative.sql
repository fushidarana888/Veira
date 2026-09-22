
create or replace function private.party_next_actor_id(p_encounter_id uuid)
returns uuid
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'private'
as $$
  select ms.character_id
  from public.party_combat_member_states ms
  join public.party_combat_encounters ce
    on ce.id=ms.encounter_id
  join public.party_dungeon_run_members prm
    on prm.run_id=ce.run_id
   and prm.character_id=ms.character_id
  cross join lateral private.get_character_combat_stats(ms.character_id) stats
  where ms.encounter_id=p_encounter_id
    and ce.status='active'
    and not ms.downed
    and not prm.lost
    and not (ms.character_id=any(ce.acted_character_ids))
  order by stats.initiative desc, prm.joined_order asc, ms.character_id asc
  limit 1;
$$;

create or replace function private.assert_party_action_turn(
  p_encounter_id uuid,
  p_character_id uuid
)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'private'
as $$
declare
  next_id uuid;
begin
  next_id:=private.party_next_actor_id(p_encounter_id);

  if next_id is null then
    raise exception 'PARTY_NO_ACTIVE_MEMBERS';
  end if;

  if next_id<>p_character_id then
    raise exception 'PARTY_NOT_YOUR_TURN';
  end if;
end;
$$;

revoke all on function private.party_next_actor_id(uuid) from public,anon,authenticated;
revoke all on function private.assert_party_action_turn(uuid,uuid) from public,anon,authenticated;

do $migration$
declare
  v_def text;
  v_before text;
begin
  select pg_get_functiondef(p.oid)
  into v_def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='perform_party_combat_action'
    and pg_get_function_identity_arguments(p.oid)='p_character_id uuid, p_encounter_id uuid, p_action text';

  if v_def is null then raise exception 'perform_party_combat_action not found'; end if;
  if position('assert_party_action_turn' in v_def)=0 then
    v_before:=v_def;
    v_def:=replace(
      v_def,
$old$
  if private.party_status_stunned(encounter.id,'member',p_character_id) then
    raise exception 'PARTY_MEMBER_STUNNED';
  end if;

  select * into stats
$old$,
$new$
  if private.party_status_stunned(encounter.id,'member',p_character_id) then
    raise exception 'PARTY_MEMBER_STUNNED';
  end if;

  perform private.assert_party_action_turn(encounter.id,p_character_id);

  select * into stats
$new$
    );
    if v_def=v_before then raise exception 'perform_party_combat_action turn anchor not found'; end if;
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
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='cast_party_character_spell'
    and pg_get_function_identity_arguments(p.oid)='p_character_id uuid, p_encounter_id uuid, p_spell_id uuid, p_target_character_id uuid';

  if v_def is null then raise exception 'cast_party_character_spell not found'; end if;
  if position('assert_party_action_turn' in v_def)=0 then
    v_before:=v_def;
    v_def:=replace(
      v_def,
$old$
  if private.party_status_stunned(encounter.id,'member',p_character_id) then
    raise exception 'PARTY_MEMBER_STUNNED';
  end if;

  select s.* into spell
$old$,
$new$
  if private.party_status_stunned(encounter.id,'member',p_character_id) then
    raise exception 'PARTY_MEMBER_STUNNED';
  end if;

  perform private.assert_party_action_turn(encounter.id,p_character_id);

  select s.* into spell
$new$
    );
    if v_def=v_before then raise exception 'cast_party_character_spell turn anchor not found'; end if;
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
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='skip_party_stunned_turn'
    and pg_get_function_identity_arguments(p.oid)='p_character_id uuid, p_encounter_id uuid';

  if v_def is null then raise exception 'skip_party_stunned_turn not found'; end if;
  if position('assert_party_action_turn' in v_def)=0 then
    v_before:=v_def;
    v_def:=replace(
      v_def,
$old$
  if not private.party_status_stunned(encounter.id,'member',p_character_id) then
    raise exception 'PARTY_MEMBER_NOT_STUNNED';
  end if;

  select name into actor_name from public.characters where id=p_character_id;
$old$,
$new$
  if not private.party_status_stunned(encounter.id,'member',p_character_id) then
    raise exception 'PARTY_MEMBER_NOT_STUNNED';
  end if;

  perform private.assert_party_action_turn(encounter.id,p_character_id);

  select name into actor_name from public.characters where id=p_character_id;
$new$
    );
    if v_def=v_before then raise exception 'skip_party_stunned_turn turn anchor not found'; end if;
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
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='use_party_sacrifice_scroll'
    and pg_get_function_identity_arguments(p.oid)='p_character_id uuid, p_encounter_id uuid';

  if v_def is null then raise exception 'use_party_sacrifice_scroll not found'; end if;
  if position('assert_party_action_turn' in v_def)=0 then
    v_before:=v_def;
    v_def:=replace(
      v_def,
$old$
  if private.party_status_stunned(encounter.id,'member',p_character_id) then
    raise exception 'PARTY_MEMBER_STUNNED';
  end if;

  if actor_state.hp_current<=200 then
$old$,
$new$
  if private.party_status_stunned(encounter.id,'member',p_character_id) then
    raise exception 'PARTY_MEMBER_STUNNED';
  end if;

  perform private.assert_party_action_turn(encounter.id,p_character_id);

  if actor_state.hp_current<=200 then
$new$
    );
    if v_def=v_before then raise exception 'use_party_sacrifice_scroll turn anchor not found'; end if;
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
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='get_party_dungeon_state'
    and pg_get_function_identity_arguments(p.oid)='p_character_id uuid';

  if v_def is null then raise exception 'get_party_dungeon_state not found'; end if;

  if position('next_actor_character_id' in v_def)=0 then
    v_before:=v_def;
    v_def:=replace(
      v_def,
$old$
        'enemy_bloodshed_stacks',ce.enemy_bloodshed_stacks,
        'acted_character_ids',to_jsonb(ce.acted_character_ids),
        'created_at',ce.created_at,
$old$,
$new$
        'enemy_bloodshed_stacks',ce.enemy_bloodshed_stacks,
        'acted_character_ids',to_jsonb(ce.acted_character_ids),
        'next_actor_character_id',private.party_next_actor_id(ce.id),
        'created_at',ce.created_at,
$new$
    );
    if v_def=v_before then raise exception 'get_party_dungeon_state encounter anchor not found'; end if;
  end if;

  if position('''initiative'',combat_stats.initiative' in v_def)=0 then
    v_before:=v_def;
    v_def:=replace(
      v_def,
$old$
          'race',c.race,
          'level',cp.level,
          'hp_current',case when prm.lost then 0 when prm.dead and ms.character_id is null then 1 else coalesce(ms.hp_current,cp.hp_current) end,
$old$,
$new$
          'race',c.race,
          'level',cp.level,
          'initiative',combat_stats.initiative,
          'hp_current',case when prm.lost then 0 when prm.dead and ms.character_id is null then 1 else coalesce(ms.hp_current,cp.hp_current) end,
$new$
    );
    if v_def=v_before then raise exception 'get_party_dungeon_state initiative field anchor not found'; end if;

    v_before:=v_def;
    v_def:=replace(
      v_def,
$old$
        order by prm.joined_order
      )
      from public.party_dungeon_run_members prm
      join public.party_dungeon_runs pr on pr.id=prm.run_id
      join public.characters c on c.id=prm.character_id
      join public.profiles pf on pf.user_id=c.owner_user_id
      join public.character_progress cp on cp.character_id=c.id
      left join public.party_combat_encounters ce on ce.id=v_encounter_id
$old$,
$new$
        order by combat_stats.initiative desc, prm.joined_order
      )
      from public.party_dungeon_run_members prm
      join public.party_dungeon_runs pr on pr.id=prm.run_id
      join public.characters c on c.id=prm.character_id
      join public.profiles pf on pf.user_id=c.owner_user_id
      join public.character_progress cp on cp.character_id=c.id
      cross join lateral private.get_character_combat_stats(c.id) combat_stats
      left join public.party_combat_encounters ce on ce.id=v_encounter_id
$new$
    );
    if v_def=v_before then raise exception 'get_party_dungeon_state initiative join anchor not found'; end if;
  end if;

  execute v_def;
end
$migration$;
