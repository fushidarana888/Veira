
alter table public.enemy_templates
  add column if not exists behavior_profile text not null default 'balanced';

alter table public.enemy_templates
  drop constraint if exists enemy_templates_behavior_profile_check;
alter table public.enemy_templates
  add constraint enemy_templates_behavior_profile_check
  check (behavior_profile in (
    'balanced','executioner','guardian','controller','berserker','survivor'
  ));

update public.enemy_templates t
set behavior_profile=case
  when jsonb_path_exists(coalesce(t.abilities,'[]'::jsonb),'$[*] ? (@.kind == "heal" || @.kind == "cleanse")')
    then 'survivor'
  when jsonb_path_exists(coalesce(t.abilities,'[]'::jsonb),'$[*] ? (@.kind == "guard")')
       or coalesce(t.defense_multiplier,1)>=coalesce(t.attack_multiplier,1)*1.15
    then 'guardian'
  when jsonb_path_exists(coalesce(t.abilities,'[]'::jsonb),'$[*] ? (@.kind == "enrage")')
       or coalesce(t.phase2_attack_bonus_percent,0)>=15
    then 'berserker'
  when coalesce(t.special_effect_type,'')<>''
       or jsonb_path_exists(coalesce(t.abilities,'[]'::jsonb),'$[*] ? (exists(@.effect_type))')
    then 'controller'
  when coalesce(t.attack_multiplier,1)>=1.15
       or coalesce(t.special_damage_multiplier,0)>=1.6
    then 'executioner'
  else 'balanced'
end;

do $$
declare
  fn_source text;
  old_fragment text;
  new_fragment text;
begin
  select pg_get_functiondef(p.oid)
  into fn_source
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='private'
    and p.proname='prepare_enemy_ai_action'
    and pg_get_function_identity_arguments(p.oid)
      ='p_encounter_id uuid, p_round integer, p_enemy_hp_after integer, p_player_hp_after integer';

  if fn_source is null then
    raise exception 'prepare_enemy_ai_action definition not found';
  end if;

  old_fragment:='  next_state jsonb;'||chr(10)||'begin';
  new_fragment:='  next_state jsonb;'||chr(10)
    ||'  behavior_profile text:=''balanced'';'||chr(10)||'begin';
  if position(old_fragment in fn_source)=0 then
    raise exception 'prepare_enemy_ai_action declaration anchor not found';
  end if;
  fn_source:=replace(fn_source,old_fragment,new_fragment);

  old_fragment:='  if ce.id is null or ce.status<>''active'' then return; end if;'
    ||chr(10)||'  if ce.enemy_special_charging then return; end if;';
  new_fragment:='  if ce.id is null or ce.status<>''active'' then return; end if;'
    ||chr(10)
    ||'  select coalesce(t.behavior_profile,''balanced'') into behavior_profile'
    ||chr(10)||'  from public.enemy_templates t'
    ||chr(10)||'  where t.id=ce.enemy_template_id;'
    ||chr(10)||'  behavior_profile:=coalesce(behavior_profile,''balanced'');'
    ||chr(10)||'  if ce.enemy_special_charging then return; end if;';
  if position(old_fragment in fn_source)=0 then
    raise exception 'prepare_enemy_ai_action state anchor not found';
  end if;
  fn_source:=replace(fn_source,old_fragment,new_fragment);

  old_fragment:='    if score>best_score then'
    ||chr(10)||'      best_score:=score;';
  new_fragment:=
       '    if behavior_profile=''executioner'' then'||chr(10)
    || '      if kind=''attack'' then score:=score+case when player_hp_percent<=35 then 30 else 8 end; end if;'||chr(10)
    || '      if kind in (''heal'',''guard'') and player_hp_percent<=35 then score:=score-12; end if;'||chr(10)
    || '    elsif behavior_profile=''guardian'' then'||chr(10)
    || '      if kind=''guard'' then score:=score+case when enemy_hp_percent<=65 then 28 else 14 end; end if;'||chr(10)
    || '      if kind=''cleanse'' then score:=score+10; end if;'||chr(10)
    || '    elsif behavior_profile=''controller'' then'||chr(10)
    || '      if nullif(ability->>''effect_type'','''') is not null then score:=score+22; end if;'||chr(10)
    || '      if kind=''cleanse'' then score:=score+8; end if;'||chr(10)
    || '    elsif behavior_profile=''berserker'' then'||chr(10)
    || '      if kind=''enrage'' then score:=score+28; end if;'||chr(10)
    || '      if kind=''attack'' then score:=score+case when enemy_hp_percent<=50 then 18 else 8 end; end if;'||chr(10)
    || '      if kind=''guard'' then score:=score-10; end if;'||chr(10)
    || '    elsif behavior_profile=''survivor'' then'||chr(10)
    || '      if kind=''heal'' then score:=score+case when enemy_hp_percent<=45 then 34 else 12 end; end if;'||chr(10)
    || '      if kind=''cleanse'' then score:=score+debuff_count*8+12; end if;'||chr(10)
    || '    end if;'||chr(10)||chr(10)
    || '    if score>best_score then'||chr(10)
    || '      best_score:=score;';
  if position(old_fragment in fn_source)=0 then
    raise exception 'prepare_enemy_ai_action score anchor not found';
  end if;
  fn_source:=replace(fn_source,old_fragment,new_fragment);

  execute fn_source;
end;
$$;

create or replace function private.party_synergy_on_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  buffed integer:=0;
begin
  if new.actor_type='player'
     and new.actor_character_id is not null
     and new.action_type='guard'
  then
    update public.party_combat_member_states s
    set damage_bonus_percent=greatest(s.damage_bonus_percent,8),
        damage_bonus_hits=greatest(s.damage_bonus_hits,1),
        updated_at=now()
    where s.encounter_id=new.encounter_id
      and s.character_id<>new.actor_character_id
      and not s.downed;

    get diagnostics buffed=row_count;

    if buffed>0 then
      new.message:=coalesce(new.message,'')
        ||' Защитная стойка создаёт окно для союзников: следующая прямая атака каждого живого союзника получает +8% урона.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists party_synergy_on_guard on public.party_combat_turns;
create trigger party_synergy_on_guard
before insert on public.party_combat_turns
for each row execute function private.party_synergy_on_guard();

revoke all on function private.party_synergy_on_guard() from public,anon,authenticated;

