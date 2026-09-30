create or replace function private.concentrated_spell_direct_value(
  p_character_id uuid,
  p_spell_id uuid,
  p_base_value integer
)
returns integer
language sql
stable
set search_path to ''
as $function$
  select greatest(
    0,
    case
      when private.character_spell_concentration_active(p_character_id,p_spell_id)
        then round(greatest(0,coalesce(p_base_value,0))*1.15)::integer
      else greatest(0,coalesce(p_base_value,0))
    end
  )
$function$;

do $migration$
declare
  r record;
  old_def text;
  new_def text;
begin
  for r in
    select p.oid,n.nspname,p.proname
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where p.prokind='f'
      and (
        (n.nspname='private' and p.proname in (
          'perform_combat_action_internal',
          'run_combat_autobattle_internal',
          'autobattle_damage_spell_score',
          'arena_choose_action',
          'arena_choose_action_v2',
          'arena_estimate_immediate_threat'
        ))
        or
        (n.nspname='public' and p.proname in (
          'cast_party_character_spell',
          'perform_pvp_duel_action'
        ))
      )
  loop
    old_def:=pg_get_functiondef(r.oid);
    new_def:=old_def;

    if r.nspname='private' and r.proname='perform_combat_action_internal' then
      new_def:=replace(new_def,'encounter.enemy_defense*0.65','encounter.enemy_defense*0.85');
    elsif r.nspname='private' and r.proname='run_combat_autobattle_internal' then
      new_def:=replace(new_def,'encounter.enemy_defense*0.65','encounter.enemy_defense*0.85');
    elsif r.nspname='private' and r.proname='autobattle_damage_spell_score' then
      new_def:=replace(new_def,'e.enemy_defense*0.65','e.enemy_defense*0.85');
    elsif r.nspname='private' and r.proname='arena_choose_action' then
      new_def:=replace(new_def,'target_magic_defense*0.65','target_magic_defense*0.85');
    elsif r.nspname='private' and r.proname='arena_choose_action_v2' then
      new_def:=replace(
        new_def,
        'greatest(0,coalesce((p_target_stats->>''magic_defense'')::integer,0))*0.65',
        'greatest(0,coalesce((p_target_stats->>''magic_defense'')::integer,0))*0.85'
      );
    elsif r.nspname='private' and r.proname='arena_estimate_immediate_threat' then
      new_def:=replace(new_def,'target_magic_def*0.65','target_magic_def*0.85');
    elsif r.nspname='public' and r.proname='perform_pvp_duel_action' then
      new_def:=replace(new_def,'target.magic_defense*0.65','target.magic_defense*0.85');
    elsif r.nspname='public' and r.proname='cast_party_character_spell' then
      new_def:=regexp_replace(
        new_def,
        'round\(stats\.magic_power\*spell\.power_multiplier\)::integer[[:space:]]+\+spell\.flat_power[[:space:]]+\+variance,[[:space:]]+encounter\.enemy_defense\*0\.65',
        'round(stats.magic_power*spell.power_multiplier)::integer
          +spell.flat_power
          +variance,
          encounter.enemy_defense*0.85'
      );
    end if;

    if new_def=old_def then
      raise exception 'Expected spell-defense pattern not found in %.%',r.nspname,r.proname;
    end if;

    execute new_def;
  end loop;
end
$migration$;
