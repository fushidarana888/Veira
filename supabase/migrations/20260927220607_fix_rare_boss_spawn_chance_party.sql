-- Synced from live Supabase migration 20260927220607 (fix_rare_boss_spawn_chance_party)

CREATE OR REPLACE FUNCTION public.start_party_dungeon_combat(p_character_id uuid, p_run_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid:=auth.uid();
  run_row public.party_dungeon_runs;
  sd public.sector_details;
  template public.enemy_templates;
  encounter_id uuid;
  member_row public.party_dungeon_run_members;
  stats record;
  danger integer;
  next_room integer;
  boss boolean;
  party_size integer;
  avg_level integer;
  danger_ten_scale integer:=0;
  enemy_level_value integer;
  enemy_hp integer;
  enemy_attack integer;
  enemy_defense integer;
  enemy_initiative integer;
  rare_variant_allowed boolean:=false;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id
      and c.owner_user_id=caller_id
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select * into run_row
  from public.party_dungeon_runs
  where id=p_run_id
  for update;

  if run_row.id is null then raise exception 'PARTY_DUNGEON_RUN_NOT_FOUND'; end if;
  if run_row.status<>'active' then raise exception 'PARTY_DUNGEON_RUN_NOT_ACTIVE'; end if;
  if run_row.leader_character_id<>p_character_id then raise exception 'PARTY_LEADER_REQUIRED'; end if;

  if exists(
    select 1 from public.party_combat_encounters
    where run_id=run_row.id
      and status='active'
  ) then raise exception 'PARTY_COMBAT_ALREADY_ACTIVE'; end if;

  if not exists(
    select 1 from public.party_dungeon_run_members
    where run_id=run_row.id and not lost and not dead
  ) then raise exception 'PARTY_NO_ACTIVE_MEMBERS'; end if;

  next_room:=run_row.rooms_cleared+1;
  if next_room>run_row.total_rooms then raise exception 'PARTY_DUNGEON_ALREADY_CLEARED'; end if;

  if exists(
    select 1 from public.party_combat_encounters
    where run_id=run_row.id
      and room_index=next_room
  ) then raise exception 'PARTY_ROOM_COMBAT_ALREADY_EXISTS'; end if;

  select count(*) into party_size
  from public.party_dungeon_run_members
  where run_id=run_row.id;

  for member_row in
    select *
    from public.party_dungeon_run_members
    where run_id=run_row.id and not lost and not dead
    order by joined_order
  loop
    perform private.apply_passive_hp_regen(member_row.character_id);
    perform private.apply_passive_mana_regen(member_row.character_id);
  end loop;

  select greatest(1,round(avg(cp.level))::integer) into avg_level
  from public.party_dungeon_run_members prm
  join public.character_progress cp on cp.character_id=prm.character_id
  where prm.run_id=run_row.id;

  select * into sd
  from public.sector_details
  where sector_id=run_row.sector_id;

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

  if danger=10 then danger_ten_scale:=greatest(0,avg_level-1); end if;

  if danger=0 then
    enemy_level_value:=1;
    enemy_hp:=42;
    enemy_attack:=6;
    enemy_defense:=2;
    enemy_initiative:=3;
  else
    enemy_level_value:=case
      when danger=10 then greatest(25+next_room,avg_level+5+next_room)
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

  enemy_hp:=greatest(
    1,
    round(enemy_hp*template.hp_multiplier*(1+0.70*(party_size-1)))::integer
  );
  enemy_attack:=greatest(
    1,
    round(enemy_attack*template.attack_multiplier*(1+0.12*(party_size-1)))::integer
  );
  enemy_defense:=greatest(
    0,
    round(enemy_defense*template.defense_multiplier*(1+0.08*(party_size-1)))::integer
  );
  enemy_initiative:=greatest(0,round(enemy_initiative*template.initiative_multiplier)::integer);

  if run_row.modifier_slug is not null then
    enemy_hp:=greatest(1,round(enemy_hp*(100+private.dungeon_modifier_value(run_row.modifier_slug,'enemy_hp_percent'))/100.0)::integer);
    enemy_attack:=greatest(1,round(enemy_attack*(100+private.dungeon_modifier_value(run_row.modifier_slug,'enemy_attack_percent'))/100.0)::integer);
    enemy_defense:=greatest(0,round(enemy_defense*(100+private.dungeon_modifier_value(run_row.modifier_slug,'enemy_defense_percent'))/100.0)::integer);
  end if;

  insert into public.party_combat_encounters(
    run_id,room_index,is_boss,status,round,
    enemy_template_id,enemy_name,enemy_level,
    enemy_hp_current,enemy_hp_max,enemy_attack,enemy_defense,enemy_initiative,
    enemy_damage_type,enemy_resistances,
    enemy_on_hit_effect_type,enemy_on_hit_effect_chance,
    enemy_on_hit_effect_turns,enemy_on_hit_effect_potency
  )
  values(
    run_row.id,next_room,boss,'active',1,
    template.id,template.name,enemy_level_value,
    enemy_hp,enemy_hp,enemy_attack,enemy_defense,enemy_initiative,
    template.attack_damage_type,template.damage_resistances,
    template.on_hit_effect_type,template.on_hit_effect_chance,
    template.on_hit_effect_turns,template.on_hit_effect_potency
  )
  returning id into encounter_id;

  for member_row in
    select *
    from public.party_dungeon_run_members
    where run_id=run_row.id and not lost
    order by joined_order
  loop
    select * into stats
    from private.get_character_combat_stats(member_row.character_id);

    insert into public.party_combat_member_states(
      encounter_id,character_id,hp_current,hp_max,mana_current,mana_max,downed,guard_percent,taunt_chance
    )
    values(
      encounter_id,member_row.character_id,
      case when member_row.dead then 1 else greatest(1,stats.hp_current) end,stats.hp_max,
      greatest(0,stats.mana_current),stats.mana_max,
      member_row.dead,0,case when member_row.dead then 0 else private.character_taunt_chance(member_row.character_id) end
    );

    perform private.record_discovery(
      member_row.character_id,
      case when template.is_rare_variant then 'rare_boss' else 'enemy' end,
      template.slug,
      template.name,
      template.description,
      jsonb_build_object('terrain',template.terrain_type,'danger',danger,'boss',template.is_boss,'party',true)
    );

    update public.character_progress
    set hp_regen_anchor_at=now(),
        mana_regen_anchor_at=now()
    where character_id=member_row.character_id;
  end loop;

  update public.party_dungeon_runs
  set current_stage='room_'||next_room||'_combat'
  where id=run_row.id;

  insert into public.party_combat_turns(
    encounter_id,round,actor_type,action_type,damage,message
  )
  values(
    encounter_id,1,'system','start',0,
    case when boss
      then case when template.is_rare_variant then 'Редкий хранитель! ' else '' end
        ||'Группа входит в финальный зал. Хранитель: '||template.name||'.'
      else 'Группа входит в зал '||next_room||'. Противник: '||template.name||'.'
    end
    ||case when run_row.modifier_slug is not null
      then ' Модификатор похода: '||(select name from public.dungeon_modifier_definitions where slug=run_row.modifier_slug)||'.'
      else ''
    end
    ||' У каждого участника по одному действию за раунд.'
  );

  return encounter_id;
end;
$function$;
