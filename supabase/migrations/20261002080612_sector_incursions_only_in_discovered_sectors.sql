create or replace function private.ensure_rotating_sector_incursions()
returns void
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $function$
declare
  slot_start timestamptz;
  slot_end timestamptz;
  slot_key text;
  i integer;
  chosen_sector smallint;
  danger integer;
  profile integer;
  template_slug text;
  event_name text;
  event_desc text;
  v_slug text;
begin
  slot_start:=to_timestamp(floor(extract(epoch from now())/172800)*172800);
  slot_end:=slot_start+interval '48 hours';
  slot_key:=to_char(slot_start at time zone 'UTC','YYYYMMDDHH24');

  for i in 1..2 loop
    v_slug:='auto_incursion_'||slot_key||'_'||i;
    if exists(select 1 from public.event_boss_events where slug=v_slug) then
      continue;
    end if;

    select sd.sector_id,greatest(1,least(10,coalesce(sd.danger_level,1)))
    into chosen_sector,danger
    from public.sector_details sd
    where sd.content_type='wilderness'
      and sd.terrain_type<>'sea'
      and exists(
        select 1
        from public.character_sector_discoveries discovered
        where discovered.sector_id=sd.sector_id
      )
      and not exists(
        select 1
        from public.event_boss_events old
        where old.boss_kind='sector_incursion'
          and old.sector_id=sd.sector_id
          and old.starts_at>=slot_start-interval '6 days'
      )
      and not exists(
        select 1
        from public.event_boss_events same_slot
        where same_slot.boss_kind='sector_incursion'
          and same_slot.starts_at=slot_start
          and same_slot.sector_id=sd.sector_id
      )
    order by md5(slot_key||':'||i||':'||sd.sector_id::text)
    limit 1;

    if chosen_sector is null then
      continue;
    end if;

    profile:=1+(abs(hashtext(slot_key||':'||i||':'||chosen_sector::text))%4);
    template_slug:=case profile
      when 1 then 'auto_incursion_beasts'
      when 2 then 'auto_incursion_marauders'
      when 3 then 'auto_incursion_spirits'
      else 'auto_incursion_aberrations'
    end;
    event_name:=case profile
      when 1 then 'Озверевшая стая'
      when 2 then 'Банда захватчиков'
      when 3 then 'Беспокойные духи'
      else 'Искажённые твари'
    end;
    event_desc:=case profile
      when 1 then 'Озверевшая стая заняла окрестности, разогнав обычную дичь и заполнив лес тревожным воем.'
      when 2 then 'Банда захватчиков укрепилась в секторе, развесив над стоянкой чужие знамёна и трофеи.'
      when 3 then 'Беспокойные духи наполнили сектор холодным светом и голосами, которым не отвечает никто живой.'
      else 'Искажённые твари заполнили сектор, оставляя на земле следы чуждой и нестабильной магии.'
    end;

    insert into public.event_boss_events(
      slug,boss_kind,name,description,enabled,starts_at,ends_at,enemy_template_id,
      recommended_level,solo_enemy_level,solo_hp,solo_attack,solo_defense,solo_initiative,
      party_hp_per_extra,party_attack_per_extra,party_defense_per_extra,special_reward_item_id,
      first_reward_gold,first_reward_experience,repeat_reward_gold,repeat_reward_experience,
      special_every_n,special_damage_multiplier,phase2_hp_percent,phase2_attack_bonus_percent,
      sector_id,solo_only,max_victories_per_character,mechanics,global_clear_target
    )
    select
      v_slug,'sector_incursion',event_name,event_desc,true,slot_start,slot_end,et.id,
      greatest(1,danger*2),greatest(2,danger*2+1),150+danger*70,18+danger*7,7+danger*4,10+danger*2,
      0.65,0.08,0.05,null,50,100,50,100,3,1.55,35,20,chosen_sector,false,1,
      jsonb_build_object('auto_rotation',true,'slot',slot_key,'profile',profile),3
    from public.enemy_templates et
    where et.slug=template_slug;
  end loop;
end;
$function$;

do $repair$
declare
  ev record;
  chosen_sector smallint;
  danger integer;
begin
  for ev in
    select e.id,e.slug,e.starts_at
    from public.event_boss_events e
    where e.enabled=true
      and e.boss_kind='sector_incursion'
      and now()>=e.starts_at
      and now()<e.ends_at
      and e.sector_id is not null
      and not exists(
        select 1
        from public.character_sector_discoveries d
        where d.sector_id=e.sector_id
      )
      and not exists(
        select 1
        from public.event_boss_completions c
        where c.event_id=e.id and c.victories>0
      )
    order by e.slug
  loop
    chosen_sector:=null;
    danger:=null;

    select sd.sector_id,greatest(1,least(10,coalesce(sd.danger_level,1)))
    into chosen_sector,danger
    from public.sector_details sd
    where sd.content_type='wilderness'
      and sd.terrain_type<>'sea'
      and exists(
        select 1
        from public.character_sector_discoveries d
        where d.sector_id=sd.sector_id
      )
      and not exists(
        select 1
        from public.event_boss_events old
        where old.id<>ev.id
          and old.boss_kind='sector_incursion'
          and old.sector_id=sd.sector_id
          and old.starts_at>=ev.starts_at-interval '6 days'
      )
      and not exists(
        select 1
        from public.event_boss_events same_slot
        where same_slot.id<>ev.id
          and same_slot.boss_kind='sector_incursion'
          and same_slot.starts_at=ev.starts_at
          and same_slot.sector_id=sd.sector_id
      )
    order by md5(ev.slug||':'||sd.sector_id::text)
    limit 1;

    if chosen_sector is null then
      continue;
    end if;

    update public.event_boss_events
    set sector_id=chosen_sector,
        recommended_level=greatest(1,danger*2),
        solo_enemy_level=greatest(2,danger*2+1),
        solo_hp=150+danger*70,
        solo_attack=18+danger*7,
        solo_defense=7+danger*4,
        solo_initiative=10+danger*2,
        updated_at=now()
    where id=ev.id;
  end loop;
end;
$repair$;
