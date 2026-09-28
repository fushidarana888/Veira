-- Synced from live Supabase migration 20260927220825 (activate_elite_dungeon_rooms)

CREATE OR REPLACE FUNCTION public.start_dungeon_combat(p_run_id uuid)
 RETURNS combat_encounters
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid := auth.uid();
  run_row public.dungeon_runs;
  sd public.sector_details;
  stats record;
  template public.enemy_templates;
  encounter public.combat_encounters;
  danger integer;
  next_room integer;
  boss boolean;
  enemy_hp integer;
  enemy_attack integer;
  enemy_defense integer;
  enemy_initiative integer;
  enemy_level_value integer;
  danger_ten_scale integer := 0;
  rare_variant_allowed boolean:=false;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;

  select r.* into run_row
  from public.dungeon_runs r
  join public.characters c on c.id=r.character_id
  where r.id=p_run_id and c.owner_user_id=caller_id
  for update of r;

  if run_row.id is null then raise exception 'DUNGEON_RUN_NOT_FOUND'; end if;
  if run_row.status<>'active' then raise exception 'DUNGEON_RUN_NOT_ACTIVE'; end if;

  if exists(
    select 1 from public.dungeon_run_events e
    where e.run_id=run_row.id and e.status='pending'
  ) then raise exception 'DUNGEON_EVENT_PENDING'; end if;

  if exists(
    select 1 from public.combat_encounters ce
    where ce.dungeon_run_id=run_row.id and ce.status='active'
  ) then raise exception 'COMBAT_ALREADY_ACTIVE'; end if;

  next_room:=run_row.rooms_cleared+1;
  if next_room>run_row.total_rooms then raise exception 'DUNGEON_ALREADY_CLEARED'; end if;

  if exists(
    select 1 from public.combat_encounters ce
    where ce.dungeon_run_id=run_row.id and ce.room_index=next_room
  ) then raise exception 'ROOM_COMBAT_ALREADY_EXISTS'; end if;

  perform private.apply_passive_hp_regen(run_row.character_id);
  perform private.apply_passive_mana_regen(run_row.character_id);

  select * into sd from public.sector_details where sector_id=run_row.sector_id;
  select * into stats from private.get_character_combat_stats(run_row.character_id);

  if stats.level is null then raise exception 'CHARACTER_PROGRESS_NOT_FOUND'; end if;
  if stats.hp_current<=0 then raise exception 'CHARACTER_HAS_NO_HP'; end if;

  danger:=greatest(0,least(10,coalesce(sd.danger_level,0)));
  boss:=next_room=run_row.total_rooms;
  rare_variant_allowed:=boss and random()*100 < least(30,5+private.dungeon_modifier_value(run_row.modifier_slug,'rare_boss_bonus_percent'));

  select t.* into template
  from public.enemy_templates t
  where t.enabled=true
    and t.is_boss=boss
    and danger between t.min_danger and t.max_danger
    and (t.terrain_type is null or t.terrain_type=sd.terrain_type)
    and (not t.is_rare_variant or rare_variant_allowed)
  order by
    case when rare_variant_allowed and t.is_rare_variant then 0 else 1 end,
    case when t.terrain_type=sd.terrain_type then 0 else 1 end,
    (t.max_danger-t.min_danger) asc,
    (-ln(greatest(random(),0.000001))/greatest(t.weight,1))
  limit 1;

  if template.id is null then raise exception 'NO_ENEMY_TEMPLATE_FOR_DUNGEON'; end if;

  if danger=10 then danger_ten_scale:=greatest(0,stats.level-1); end if;

  if danger=0 then
    enemy_level_value:=1;
    enemy_hp:=42;
    enemy_attack:=6;
    enemy_defense:=2;
    enemy_initiative:=3;
  else
    enemy_level_value:=case
      when danger=10 then greatest(25+next_room,stats.level+5+next_room)
      else greatest(1,danger*2+next_room)
    end;

    enemy_hp:=50+danger*25+next_room*12+danger_ten_scale*20;
    enemy_attack:=10+danger*4+next_room*2+danger_ten_scale*5;
    enemy_defense:=6+danger*3+next_room*2+danger_ten_scale*4;
    enemy_initiative:=6+danger*2+next_room+danger_ten_scale*2;

    if danger=10 then
      enemy_hp:=enemy_hp+150;
      enemy_attack:=enemy_attack+15;
      enemy_defense:=enemy_defense+12;
      enemy_initiative:=enemy_initiative+8;
    end if;

    if boss then
      if danger=10 then
        enemy_hp:=ceil(enemy_hp*1.75)::integer;
        enemy_attack:=ceil(enemy_attack*1.35)::integer;
        enemy_defense:=ceil(enemy_defense*1.30)::integer;
        enemy_initiative:=enemy_initiative+6;
      else
        enemy_hp:=ceil(enemy_hp*1.40)::integer;
        enemy_attack:=ceil(enemy_attack*1.20)::integer;
        enemy_defense:=ceil(enemy_defense*1.15)::integer;
        enemy_initiative:=enemy_initiative+3;
      end if;
    end if;
  end if;

  enemy_hp:=greatest(1,round(enemy_hp*template.hp_multiplier)::integer);
  enemy_attack:=greatest(1,round(enemy_attack*template.attack_multiplier)::integer);
  enemy_defense:=greatest(0,round(enemy_defense*template.defense_multiplier)::integer);
  enemy_initiative:=greatest(0,round(enemy_initiative*template.initiative_multiplier)::integer);

  if run_row.modifier_slug is not null then
    enemy_hp:=greatest(1,round(enemy_hp*(100+private.dungeon_modifier_value(run_row.modifier_slug,'enemy_hp_percent'))/100.0)::integer);
    enemy_attack:=greatest(1,round(enemy_attack*(100+private.dungeon_modifier_value(run_row.modifier_slug,'enemy_attack_percent'))/100.0)::integer);
    enemy_defense:=greatest(0,round(enemy_defense*(100+private.dungeon_modifier_value(run_row.modifier_slug,'enemy_defense_percent'))/100.0)::integer);
  end if;

  if run_row.next_room_elite then
    enemy_hp:=greatest(1,round(enemy_hp*1.45)::integer);
    enemy_attack:=greatest(1,round(enemy_attack*1.25)::integer);
    enemy_defense:=greatest(0,round(enemy_defense*1.20)::integer);
    enemy_initiative:=greatest(0,round(enemy_initiative*1.10)::integer);
  end if;

  insert into public.combat_encounters(
    dungeon_run_id,character_id,sector_id,status,round,room_index,is_boss,is_elite_room,
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
    enemy_phase2_special_every_n,
    player_physical_damage_type,player_magic_damage_type,
    player_hp_current,player_hp_max,player_mana_current,player_mana_max
  )
  values(
    run_row.id,run_row.character_id,run_row.sector_id,'active',0,next_room,boss,run_row.next_room_elite,
    template.id,template.name,enemy_level_value,enemy_hp,enemy_hp,
    enemy_attack,enemy_defense,enemy_initiative,template.attack_damage_type,template.damage_resistances,
    template.on_hit_effect_type,template.on_hit_effect_chance,
    template.on_hit_effect_turns,template.on_hit_effect_potency,
    template.special_name,template.special_damage_multiplier,template.special_every_n,
    template.special_damage_type,template.special_effect_type,template.special_effect_chance,
    template.special_effect_turns,template.special_effect_potency,
    template.special_telegraph_text,template.special_attack_text,
    template.special_kind,template.special_value,
    template.phase2_hp_percent,template.phase2_name,
    template.phase2_attack_bonus_percent,template.phase2_defense_bonus_percent,
    template.phase2_special_every_n,
    stats.weapon_damage_type,stats.magic_damage_type,
    stats.hp_current,stats.hp_max,stats.mana_current,stats.mana_max
  )
  returning * into encounter;

  perform private.record_discovery(
    run_row.character_id,
    case
      when template.is_rare_variant then 'rare_boss'
      when run_row.next_room_elite then 'elite_enemy'
      else 'enemy'
    end,
    template.slug,
    template.name,
    template.description,
    jsonb_build_object('terrain',template.terrain_type,'danger',danger,'boss',template.is_boss)
  );

  update public.character_progress
  set hp_regen_anchor_at=now(),mana_regen_anchor_at=now()
  where character_id=run_row.character_id;

  update public.dungeon_runs
  set current_stage='room_'||next_room||'_combat',
      next_room_elite=false
  where id=run_row.id;

  insert into public.combat_turns(
    encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
  )
  values(
    encounter.id,0,'system','start',0,stats.hp_current,enemy_hp,
    (case when run_row.next_room_elite then 'ОПАСНАЯ КОМНАТА! ' else '' end)
    ||case
      when boss then
        case when template.is_rare_variant then 'Редкий хранитель! ' else '' end
        ||'Последний зал охраняет '||template.name||'. Тип атаки: '||private.damage_type_label(template.attack_damage_type)||'.'
        ||case when template.special_every_n>=2 and template.special_name<>'' then ' Особая атака: «'||template.special_name||'» — её подготовка будет видна заранее.' else '' end
      else 'Зал '||next_room||' перекрывает '||template.name||'. Тип атаки: '||private.damage_type_label(template.attack_damage_type)||'.'
    end
    ||case
      when run_row.modifier_slug is not null
      then ' Модификатор похода: '||(select name from public.dungeon_modifier_definitions where slug=run_row.modifier_slug)||'.'
      else ''
    end
  );

  return encounter;
end;
$function$;
