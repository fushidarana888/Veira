
update public.race_definitions
set
  hp_regen_per_hour = case slug
    when 'human' then 50
    when 'dwarf' then 55
    when 'gnome' then 45
    when 'halfling' then 50
    when 'orc' then 57
    when 'half_orc' then 54
    when 'goblin' then 50
    when 'hobgoblin' then 52
    when 'ogre' then 60
    when 'trollkin' then 60
    when 'elf' then 46
    when 'high_elf' then 42
    when 'wood_elf' then 52
    when 'dark_elf' then 46
    when 'snow_elf' then 45
    when 'beastfolk' then 52
    when 'catfolk' then 50
    when 'wolffolk' then 56
    when 'foxfolk' then 48
    when 'bearfolk' then 58
    when 'rabbitfolk' then 52
    when 'deerfolk' then 55
    when 'lizardfolk' then 56
    when 'serpentfolk' then 47
    when 'avian' then 45
    when 'amphibian' then 54
    when 'draconid' then 55
    when 'kobold' then 49
    when 'merfolk' then 48
    when 'plantfolk' then 59
    when 'treantkin' then 60
    when 'fungalfolk' then 55
    when 'stoneborn' then 58
    when 'elementalborn' then 40
    when 'nature_spirit' then 53
    when 'dryad' then 60
    when 'vampire' then 42
    when 'dhampir' then 45
    when 'revenant' then 41
    when 'living_dead' then 40
    when 'demon' then 46
    when 'demonblood' then 49
    when 'celestialborn' then 47
    when 'oni' then 56
    else greatest(40, least(60, hp_regen_per_hour))
  end,
  mana_regen_per_hour = case slug
    when 'human' then 35
    when 'dwarf' then 30
    when 'gnome' then 42
    when 'halfling' then 36
    when 'orc' then 28
    when 'half_orc' then 30
    when 'goblin' then 34
    when 'hobgoblin' then 32
    when 'ogre' then 25
    when 'trollkin' then 26
    when 'elf' then 40
    when 'high_elf' then 45
    when 'wood_elf' then 38
    when 'dark_elf' then 41
    when 'snow_elf' then 42
    when 'beastfolk' then 31
    when 'catfolk' then 35
    when 'wolffolk' then 30
    when 'foxfolk' then 41
    when 'bearfolk' then 27
    when 'rabbitfolk' then 36
    when 'deerfolk' then 40
    when 'lizardfolk' then 29
    when 'serpentfolk' then 40
    when 'avian' then 42
    when 'amphibian' then 41
    when 'draconid' then 36
    when 'kobold' then 37
    when 'merfolk' then 44
    when 'plantfolk' then 31
    when 'treantkin' then 25
    when 'fungalfolk' then 35
    when 'stoneborn' then 25
    when 'elementalborn' then 45
    when 'nature_spirit' then 45
    when 'dryad' then 40
    when 'vampire' then 43
    when 'dhampir' then 40
    when 'revenant' then 36
    when 'living_dead' then 32
    when 'demon' then 43
    when 'demonblood' then 40
    when 'celestialborn' then 45
    when 'oni' then 30
    else greatest(25, least(45, mana_regen_per_hour))
  end,
  updated_at = now();

alter table public.race_definitions
  alter column hp_regen_per_hour set default 50,
  alter column mana_regen_per_hour set default 35;

create or replace function private.apply_passive_hp_regen(p_character_id uuid)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $function$
declare
  p public.character_progress;
  regen_rate integer:=50;
  full_hours integer;
  heal_amount integer;
  new_hp integer;
begin
  select cp.* into p
  from public.character_progress cp
  where cp.character_id=p_character_id
  for update;

  if p.character_id is null then return 0; end if;

  select coalesce(rd.hp_regen_per_hour,50) into regen_rate
  from public.characters c
  left join public.race_definitions rd on rd.id=c.race_id
  where c.id=p_character_id;

  regen_rate:=coalesce(regen_rate,50);

  if exists(
    select 1 from public.combat_encounters ce
    where ce.character_id=p_character_id and ce.status='active'
  ) then
    update public.character_progress
    set hp_regen_anchor_at=now()
    where character_id=p_character_id;
    return 0;
  end if;

  if p.hp_current>=p.hp_max or regen_rate<=0 then
    update public.character_progress
    set hp_current=least(hp_current,hp_max),
        hp_regen_anchor_at=now()
    where character_id=p_character_id;
    return 0;
  end if;

  full_hours:=floor(extract(epoch from (now()-p.hp_regen_anchor_at))/3600.0)::integer;
  if full_hours<=0 then return 0; end if;

  heal_amount:=full_hours*regen_rate;
  new_hp:=least(p.hp_max,p.hp_current+heal_amount);

  update public.character_progress
  set hp_current=new_hp,
      hp_regen_anchor_at=case
        when new_hp>=p.hp_max then now()
        else p.hp_regen_anchor_at+make_interval(hours=>full_hours)
      end,
      updated_at=now()
  where character_id=p_character_id;

  return new_hp-p.hp_current;
end;
$function$;

create or replace function private.apply_passive_mana_regen(p_character_id uuid)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $function$
declare
  p public.character_progress;
  regen_rate integer:=35;
  full_hours integer;
  restore_amount integer;
  new_mana integer;
begin
  select cp.* into p
  from public.character_progress cp
  where cp.character_id=p_character_id
  for update;

  if p.character_id is null then return 0; end if;

  select coalesce(rd.mana_regen_per_hour,35) into regen_rate
  from public.characters c
  left join public.race_definitions rd on rd.id=c.race_id
  where c.id=p_character_id;

  regen_rate:=coalesce(regen_rate,35);

  if exists(
    select 1 from public.combat_encounters ce
    where ce.character_id=p_character_id and ce.status='active'
  ) then
    update public.character_progress
    set mana_regen_anchor_at=now()
    where character_id=p_character_id;
    return 0;
  end if;

  if p.mana_current>=p.mana_max or regen_rate<=0 then
    update public.character_progress
    set mana_current=least(mana_current,mana_max),
        mana_regen_anchor_at=now()
    where character_id=p_character_id;
    return 0;
  end if;

  full_hours:=floor(extract(epoch from (now()-p.mana_regen_anchor_at))/3600.0)::integer;
  if full_hours<=0 then return 0; end if;

  restore_amount:=full_hours*regen_rate;
  new_mana:=least(p.mana_max,p.mana_current+restore_amount);

  update public.character_progress
  set mana_current=new_mana,
      mana_regen_anchor_at=case
        when new_mana>=p.mana_max then now()
        else p.mana_regen_anchor_at+make_interval(hours=>full_hours)
      end,
      updated_at=now()
  where character_id=p_character_id;

  return new_mana-p.mana_current;
end;
$function$;
