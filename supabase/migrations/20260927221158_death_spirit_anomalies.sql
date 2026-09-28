-- Synced from live Supabase migration 20260927221158 (death_spirit_anomalies)

CREATE OR REPLACE FUNCTION private.create_death_spirit(p_character_id uuid, p_source_sector_id smallint, p_source_kind text DEFAULT 'other'::text, p_source_ref_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  existing_id uuid; stats record; owner_name text; origin_col integer; origin_row integer;
  target_sector smallint; spirit_id uuid; held_item uuid; equipment_snapshot jsonb:='[]'::jsonb;
  anomaly text:=null; anomaly_name text:=null; anomaly_roll numeric;
begin
  perform private.expire_death_spirits();
  if p_source_ref_id is not null then
    select id into existing_id from private.death_spirits
      where owner_character_id=p_character_id and source_ref_id=p_source_ref_id limit 1;
    if existing_id is not null then return existing_id; end if;
  end if;

  select * into stats from private.get_character_combat_stats(p_character_id);
  if stats.level is null then raise exception 'CHARACTER_PROGRESS_NOT_FOUND'; end if;
  select c.name into owner_name from public.characters c where c.id=p_character_id;
  select s.grid_col,s.grid_row into origin_col,origin_row from public.map_sectors s where s.id=p_source_sector_id;

  anomaly_roll:=random()*100;
  if anomaly_roll<10 then
    anomaly:='restless';
    anomaly_name:='Беспокойный дух';
  elsif anomaly_roll<20 then
    anomaly:='fading';
    anomaly_name:='Угасающий дух';
  elsif anomaly_roll<25 then
    anomaly:='echoing';
    anomaly_name:='Эхо духа';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'slot',ce.slot::text,'character_item_id',ci.id,'item_definition_id',idf.id,
    'name',coalesce(ci.custom_name,idf.name),'rarity',idf.rarity::text,
    'enhancement_level',ci.enhancement_level,'awakening_level',ci.awakening_level,'metadata',ci.metadata
  ) order by ce.slot::text),'[]'::jsonb)
  into equipment_snapshot
  from public.character_equipment ce
  join public.character_items ci on ci.id=ce.character_item_id
  join public.item_definitions idf on idf.id=ci.item_definition_id
  where ce.character_id=p_character_id;

  select s.id into target_sector
  from public.map_sectors s
  join public.sector_details sd on sd.sector_id=s.id
  left join public.character_sector_discoveries d on d.character_id=p_character_id and d.sector_id=s.id
  where sd.content_type='wilderness'
    and not exists(select 1 from private.death_spirits ds where ds.sector_id=s.id and ds.status='active')
  order by case when s.id=p_source_sector_id then 0 else 1 end,
           case when d.character_id is not null then 0 else 1 end,
           abs(s.grid_col-origin_col)+abs(s.grid_row-origin_row),random()
  limit 1;
  if target_sector is null then target_sector:=p_source_sector_id; end if;

  insert into private.death_spirits(
    owner_character_id,sector_id,source_sector_id,source_kind,source_ref_id,snapshot,
    base_hp,base_attack,base_defense,base_initiative,damage_type,resistances
  ) values(
    p_character_id,target_sector,p_source_sector_id,coalesce(nullif(p_source_kind,''),'other'),p_source_ref_id,
    jsonb_build_object('owner_name',owner_name,'level',stats.level,'strength',stats.strength,'agility',stats.agility,
      'intellect',stats.intellect,'vitality',stats.vitality,'luck',stats.luck,'equipment',equipment_snapshot,
      'anomaly',anomaly,'anomaly_name',anomaly_name),
    greatest(1,stats.hp_max),greatest(1,stats.physical_power),greatest(0,stats.defense),
    greatest(0,stats.initiative),coalesce(stats.weapon_damage_type,'blunt'),coalesce(stats.damage_resistances,'{}'::jsonb)
  ) returning id into spirit_id;

  select ce.character_item_id into held_item
  from public.character_equipment ce
  join public.character_items ci on ci.id=ce.character_item_id
  where ce.character_id=p_character_id
    and ce.slot in('weapon','offhand','head','chest','hands','legs','feet')
    and ci.death_spirit_id is null
  order by random() limit 1 for update of ci;

  if held_item is not null then
    delete from public.character_equipment where character_item_id=held_item;
    update public.character_items set death_spirit_id=spirit_id where id=held_item;
  end if;
  return spirit_id;
end $function$;

CREATE OR REPLACE FUNCTION public.start_death_spirit_combat(p_character_id uuid, p_spirit_id uuid)
 RETURNS combat_encounters
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller uuid:=auth.uid(); spirit private.death_spirits; stats record; owner_name text; factor numeric; created public.combat_encounters;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters c where c.id=p_character_id and c.owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;
  perform private.expire_death_spirits();
  select * into spirit from private.death_spirits where id=p_spirit_id for update;
  if spirit.id is null or spirit.status<>'active' or spirit.expires_at<=now() then raise exception 'DEATH_SPIRIT_NOT_ACTIVE'; end if;
  if not exists(select 1 from public.character_sector_discoveries d where d.character_id=p_character_id and d.sector_id=spirit.sector_id)
    then raise exception 'SPIRIT_SECTOR_NOT_DISCOVERED'; end if;
  if exists(select 1 from public.combat_encounters ce where ce.character_id=p_character_id and ce.status='active')
    then raise exception 'COMBAT_ALREADY_ACTIVE'; end if;
  if exists(select 1 from public.dungeon_runs dr where dr.character_id=p_character_id and dr.status='active')
    then raise exception 'DUNGEON_RUN_ALREADY_ACTIVE'; end if;
  if exists(select 1 from public.party_dungeon_runs pr join public.party_dungeon_run_members pm on pm.run_id=pr.id
            where pm.character_id=p_character_id and pr.status='active')
    then raise exception 'PARTY_DUNGEON_ACTIVE'; end if;
  if exists(select 1 from public.pvp_duels pd where pd.status='active' and p_character_id in(pd.challenger_character_id,pd.opponent_character_id))
    then raise exception 'PVP_DUEL_ACTIVE'; end if;
  if exists(select 1 from public.combat_encounters ce where ce.death_spirit_id=spirit.id and ce.status='active')
    then raise exception 'SPIRIT_ALREADY_CHALLENGED'; end if;

  perform private.apply_passive_hp_regen(p_character_id);
  perform private.apply_passive_mana_regen(p_character_id);
  select * into stats from private.get_character_combat_stats(p_character_id);
  if stats.level is null then raise exception 'CHARACTER_PROGRESS_NOT_FOUND'; end if;
  if stats.hp_current<=0 then raise exception 'CHARACTER_HAS_NO_HP'; end if;
  select c.name into owner_name from public.characters c where c.id=spirit.owner_character_id;
  factor:=case when spirit.owner_character_id=p_character_id then 0.60 else 1.60 end;
  factor:=factor*case coalesce(spirit.snapshot->>'anomaly','')
    when 'restless' then 1.15
    when 'fading' then 0.85
    when 'echoing' then 1.05
    else 1.0
  end;

  insert into public.combat_encounters(
    dungeon_run_id,death_spirit_id,character_id,sector_id,status,round,room_index,is_boss,
    enemy_name,enemy_level,enemy_hp_current,enemy_hp_max,enemy_attack,enemy_defense,enemy_initiative,
    enemy_damage_type,enemy_resistances,player_physical_damage_type,player_magic_damage_type,
    player_hp_current,player_hp_max,player_mana_current,player_mana_max
  ) values(
    null,spirit.id,p_character_id,spirit.sector_id,'active',0,1,false,'Дух '||owner_name,
    greatest(1,coalesce((spirit.snapshot->>'level')::integer,1)),
    greatest(1,round(spirit.base_hp*factor)::integer),greatest(1,round(spirit.base_hp*factor)::integer),
    greatest(1,round(spirit.base_attack*factor)::integer),greatest(0,round(spirit.base_defense*factor)::integer),
    greatest(0,round(spirit.base_initiative*factor)::integer),spirit.damage_type,spirit.resistances,
    stats.weapon_damage_type,stats.magic_damage_type,stats.hp_current,stats.hp_max,stats.mana_current,stats.mana_max
  ) returning * into created;

  insert into public.combat_turns(encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message)
  values(created.id,0,'system','death_spirit_start',0,created.player_hp_current,created.enemy_hp_current,
    case when spirit.owner_character_id=p_character_id
      then 'Ты сталкиваешься со своим духом. Базовая сила — 60% исходного персонажа. Победа вернёт удерживаемое снаряжение.'
        ||case coalesce(spirit.snapshot->>'anomaly','')
          when 'restless' then ' Дух беспокоен и примерно на 15% сильнее обычного.'
          when 'fading' then ' Дух угасает и примерно на 15% слабее обычного.'
          when 'echoing' then ' Вокруг духа дрожит эхо, немного усиливающее его.'
          else '' end
      else 'Ты бросаешь вызов чужому духу. Базовая сила — 160% исходного персонажа. Победа передаст тебе удерживаемое снаряжение.'
        ||case coalesce(spirit.snapshot->>'anomaly','')
          when 'restless' then ' Дух беспокоен и примерно на 15% сильнее обычного.'
          when 'fading' then ' Дух угасает и примерно на 15% слабее обычного.'
          when 'echoing' then ' Вокруг духа дрожит эхо, немного усиливающее его.'
          else '' end
    end);
  return created;
end $function$;
