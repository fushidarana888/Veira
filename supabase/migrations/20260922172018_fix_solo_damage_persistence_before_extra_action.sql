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

  if v_def is null then
    raise exception 'perform_combat_action_internal definition not found';
  end if;

  old_block := $old$
  insert into public.combat_turns(
    encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
  )
  values(
    encounter.id,next_round,'player',action_type_value,
    player_damage,player_hp_after,enemy_hp_after,player_message
  );

  if enemy_hp_after>0 then
    perform private.resolve_solo_summon_action(encounter.id,next_round);
    select enemy_hp_current into enemy_hp_after
    from public.combat_encounters
    where id=encounter.id;
  end if;
$old$;

  new_block := $new$
  insert into public.combat_turns(
    encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
  )
  values(
    encounter.id,next_round,'player',action_type_value,
    player_damage,player_hp_after,enemy_hp_after,player_message
  );

  -- Persist the player's action before summons or an initiative extra-action can
  -- read/return the encounter. Without this, non-lethal damage existed only in
  -- local PL/pgSQL variables and could be overwritten by the stored old HP.
  update public.combat_encounters
  set enemy_hp_current=enemy_hp_after,
      player_hp_current=player_hp_after,
      player_hp_max=stats.hp_max,
      player_mana_current=player_mana_after,
      player_mana_max=stats.mana_max,
      player_physical_damage_type=stats.weapon_damage_type,
      player_magic_damage_type=stats.magic_damage_type
  where id=encounter.id;

  if enemy_hp_after>0 then
    perform private.resolve_solo_summon_action(encounter.id,next_round);
    select enemy_hp_current into enemy_hp_after
    from public.combat_encounters
    where id=encounter.id;
  end if;
$new$;

  if position(old_block in v_def)=0 then
    raise exception 'solo combat persistence anchor not found';
  end if;

  v_def:=replace(v_def,old_block,new_block);
  execute v_def;
end
$migration$;
