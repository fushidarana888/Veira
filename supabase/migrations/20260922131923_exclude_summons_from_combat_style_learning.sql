CREATE OR REPLACE FUNCTION private.record_manual_combat_decision(p_encounter_id uuid, p_mode text, p_spell_id uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  encounter public.combat_encounters;
  stats record;
  spell_kind_value text;
  action_kind_value text;
  debuff_count integer:=0;
begin
  if coalesce(current_setting('veira.autobattle',true),'')='1' then return; end if;
  if p_mode not in ('physical','magic','guard','learned_spell','support_spell') then return; end if;

  select * into encounter
  from public.combat_encounters
  where id=p_encounter_id and status='active';

  if encounter.id is null then return; end if;

  select * into stats from private.get_character_combat_stats(encounter.character_id);
  if stats.level is null then return; end if;

  if exists(
    select 1 from public.combat_status_effects
    where encounter_id=encounter.id and target='player' and effect_type='stun'
  ) then return; end if;

  select count(*)::integer into debuff_count
  from public.combat_status_effects
  where encounter_id=encounter.id and target='player';

  if p_mode='physical' then
    action_kind_value:='physical';
  elsif p_mode='magic' then
    action_kind_value:='magic';
  elsif p_mode='guard' then
    action_kind_value:='guard';
  else
    select s.spell_kind into spell_kind_value
    from public.character_spells cs
    join public.spell_definitions s on s.id=cs.spell_id
    where cs.character_id=encounter.character_id
      and cs.spell_id=p_spell_id
      and s.enabled=true
    limit 1;

    if spell_kind_value is null then return; end if;
    -- Призывы пока не входят в обучение «Играть как я»: у профиля стиля
    -- нет отдельного summon-веса, поэтому не искажаем проценты остальных действий.
    if spell_kind_value='summon' then return; end if;
    action_kind_value:='spell_'||spell_kind_value;
  end if;

  insert into public.combat_decision_events(
    encounter_id,character_id,context,raw_mode,action_kind,spell_id,
    hp_percent,mana_percent,enemy_hp_percent,player_debuff_count,
    enemy_special_charging,enemy_special_kind,enemy_phase
  )
  values(
    encounter.id,
    encounter.character_id,
    case when encounter.is_boss then 'boss' else 'normal' end,
    p_mode,
    action_kind_value,
    case when p_mode in ('learned_spell','support_spell') then p_spell_id else null end,
    case when stats.hp_max<=0 then 0 else greatest(0,least(100,round(stats.hp_current*100.0/stats.hp_max)::integer)) end,
    case when stats.mana_max<=0 then 0 else greatest(0,least(100,round(stats.mana_current*100.0/stats.mana_max)::integer)) end,
    case when encounter.enemy_hp_max<=0 then 0 else greatest(0,least(100,round(encounter.enemy_hp_current*100.0/encounter.enemy_hp_max)::integer)) end,
    least(20,greatest(0,debuff_count)),
    encounter.enemy_special_charging,
    encounter.enemy_special_kind,
    encounter.enemy_phase
  );
end;
$function$;