create table if not exists public.magic_families (
  slug text primary key,
  name text not null unique,
  kind text not null default 'other'
    check (kind in ('element','school','function','other')),
  description text not null default '',
  enabled boolean not null default true,
  is_system boolean not null default false,
  sort_order smallint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint magic_family_slug_format check (slug ~ '^[a-z0-9_]+$')
);

create table if not exists public.spell_magic_families (
  spell_id uuid not null references public.spell_definitions(id) on delete cascade,
  family_slug text not null references public.magic_families(slug) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(spell_id,family_slug)
);

create index if not exists spell_magic_families_family_idx
  on public.spell_magic_families(family_slug,spell_id);

alter table public.magic_families enable row level security;
alter table public.spell_magic_families enable row level security;
revoke all on table public.magic_families from anon,authenticated;
revoke all on table public.spell_magic_families from anon,authenticated;

drop trigger if exists magic_families_set_updated_at on public.magic_families;
create trigger magic_families_set_updated_at
before update on public.magic_families
for each row execute function public.set_updated_at();

insert into public.magic_families(slug,name,kind,description,is_system,sort_order)
values
  ('fire','Огненная','element','Пламя, жар и магия огня.',true,10),
  ('water','Водная','element','Вода, течение и давление жидкости.',true,20),
  ('earth','Земляная','element','Камень, почва и сила земли.',true,30),
  ('air','Воздушная','element','Воздух, ветер и режущие потоки.',true,40),
  ('lightning','Электрическая','element','Молния, ток и электрические разряды.',true,50),
  ('ice','Ледяная','element','Холод, лёд и замораживание.',true,60),
  ('gravity','Гравитационная','school','Искажение веса, притяжения и пространства.',true,100),
  ('star','Звёздная','school','Звёздная энергия и небесная магия.',true,110),
  ('arcane','Арканная','school','Чистая структурированная магическая энергия.',true,120),
  ('protective','Защитная','function','Щиты, барьеры и снижение входящего урона.',true,200),
  ('healing','Лечебная','function','Восстановление здоровья и лечение ран.',true,210),
  ('cleansing','Очищающая','function','Снятие негативных эффектов и очищение.',true,220),
  ('enhancement','Усиливающая','function','Баффы и временное усиление характеристик или атак.',true,230),
  ('control','Контроль','function','Провокация, ограничение действий и управление боем.',true,240),
  ('sacrifice','Жертвенная','function','Магия, использующая добровольную цену или жертву.',true,250)
on conflict(slug) do update set
  name=excluded.name,
  kind=excluded.kind,
  description=excluded.description,
  enabled=true,
  is_system=true,
  sort_order=excluded.sort_order,
  updated_at=now();

insert into public.spell_magic_families(spell_id,family_slug)
select s.id,s.damage_type
from public.spell_definitions s
join public.magic_families f on f.slug=s.damage_type
where s.spell_kind='damage' and s.damage_type is not null
on conflict do nothing;

insert into public.spell_magic_families(spell_id,family_slug)
select s.id,'healing' from public.spell_definitions s where s.spell_kind='heal'
on conflict do nothing;
insert into public.spell_magic_families(spell_id,family_slug)
select s.id,'protective' from public.spell_definitions s where s.spell_kind='guard'
on conflict do nothing;
insert into public.spell_magic_families(spell_id,family_slug)
select s.id,'cleansing' from public.spell_definitions s where s.spell_kind='cleanse'
on conflict do nothing;
insert into public.spell_magic_families(spell_id,family_slug)
select s.id,'enhancement' from public.spell_definitions s where s.spell_kind='buff'
on conflict do nothing;
insert into public.spell_magic_families(spell_id,family_slug)
select s.id,'control' from public.spell_definitions s where s.spell_kind='taunt'
on conflict do nothing;
insert into public.spell_magic_families(spell_id,family_slug)
select s.id,'sacrifice' from public.spell_definitions s where s.spell_kind='sacrifice'
on conflict do nothing;
insert into public.spell_magic_families(spell_id,family_slug)
select s.id,'healing' from public.spell_definitions s where s.spell_kind='sacrifice'
on conflict do nothing;
insert into public.spell_magic_families(spell_id,family_slug)
select s.id,'protective' from public.spell_definitions s where s.spell_kind='sacrifice'
on conflict do nothing;
insert into public.spell_magic_families(spell_id,family_slug)
select s.id,'arcane' from public.spell_definitions s where s.slug='arcane_ward'
on conflict do nothing;

CREATE OR REPLACE FUNCTION private.spell_has_magic_family(p_spell_id uuid, p_family_slug text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select exists(
    select 1
    from public.spell_magic_families sf
    where sf.spell_id=p_spell_id
      and sf.family_slug=p_family_slug
  );
$function$;

CREATE OR REPLACE FUNCTION private.spell_magic_family_slugs(p_spell_id uuid)
 RETURNS text[]
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select coalesce(array_agg(sf.family_slug order by f.sort_order,f.name),'{}'::text[])
  from public.spell_magic_families sf
  join public.magic_families f on f.slug=sf.family_slug
  where sf.spell_id=p_spell_id
    and f.enabled;
$function$;

CREATE OR REPLACE FUNCTION public.get_character_spells_v2(p_character_id uuid)
 RETURNS TABLE(id uuid, slug text, name text, description text, spell_kind text, damage_type text, mana_cost integer, required_level integer, power_multiplier numeric, flat_power integer, status_effect_type text, status_effect_chance smallint, status_effect_turns smallint, status_effect_potency integer, magic_families jsonb, learned_at timestamp with time zone, source text, combat_slot smallint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller uuid:=auth.uid();
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  if not private.is_gm(caller)
     and not exists(
       select 1 from public.characters c
       where c.id=p_character_id and c.owner_user_id=caller
     )
  then raise exception 'CHARACTER_NOT_OWNED'; end if;

  return query
  select
    s.id,s.slug,s.name,s.description,s.spell_kind,s.damage_type,
    s.mana_cost,s.required_level,s.power_multiplier,s.flat_power,
    s.status_effect_type,s.status_effect_chance,s.status_effect_turns,s.status_effect_potency,
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'slug',f.slug,'name',f.name,'kind',f.kind,'description',f.description
        )
        order by
          case f.kind when 'element' then 1 when 'school' then 2 when 'function' then 3 else 4 end,
          f.sort_order,f.name
      )
      from public.spell_magic_families sf
      join public.magic_families f on f.slug=sf.family_slug
      where sf.spell_id=s.id and f.enabled
    ),'[]'::jsonb),
    cs.learned_at,cs.source,ccs.slot
  from public.character_spells cs
  join public.spell_definitions s on s.id=cs.spell_id
  left join public.character_combat_spells ccs
    on ccs.character_id=cs.character_id and ccs.spell_id=cs.spell_id
  where cs.character_id=p_character_id
    and s.enabled=true
  order by ccs.slot nulls last,s.required_level,s.name;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_gm_spell_definitions_v2()
 RETURNS TABLE(id uuid, slug text, name text, description text, enabled boolean, spell_kind text, damage_type text, mana_cost integer, required_level integer, power_multiplier numeric, flat_power integer, status_effect_type text, status_effect_chance smallint, status_effect_turns smallint, status_effect_potency integer, support_effect_type text, support_value integer, support_turns smallint, family_slugs text[], magic_families jsonb, created_at timestamp with time zone, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
begin
  if not private.is_gm(auth.uid()) then raise exception 'GM_REQUIRED'; end if;

  return query
  select
    s.id,s.slug,s.name,s.description,s.enabled,s.spell_kind,s.damage_type,
    s.mana_cost,s.required_level,s.power_multiplier,s.flat_power,
    s.status_effect_type,s.status_effect_chance,s.status_effect_turns,s.status_effect_potency,
    s.support_effect_type,s.support_value,s.support_turns,
    private.spell_magic_family_slugs(s.id),
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'slug',f.slug,'name',f.name,'kind',f.kind,'description',f.description
        )
        order by
          case f.kind when 'element' then 1 when 'school' then 2 when 'function' then 3 else 4 end,
          f.sort_order,f.name
      )
      from public.spell_magic_families sf
      join public.magic_families f on f.slug=sf.family_slug
      where sf.spell_id=s.id and f.enabled
    ),'[]'::jsonb),
    s.created_at,s.updated_at
  from public.spell_definitions s
  order by s.required_level,s.name;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_magic_family_catalog()
 RETURNS TABLE(slug text, name text, kind text, description text, sort_order smallint)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select f.slug,f.name,f.kind,f.description,f.sort_order
  from public.magic_families f
  where f.enabled
  order by
    case f.kind when 'element' then 1 when 'school' then 2 when 'function' then 3 else 4 end,
    f.sort_order,f.name;
$function$;

CREATE OR REPLACE FUNCTION public.gm_delete_magic_family(p_slug text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  system_family boolean;
begin
  if not private.is_gm(auth.uid()) then raise exception 'GM_REQUIRED'; end if;

  select is_system into system_family
  from public.magic_families
  where slug=p_slug;

  if system_family is null then raise exception 'MAGIC_FAMILY_NOT_FOUND'; end if;
  if system_family then raise exception 'SYSTEM_MAGIC_FAMILY_PROTECTED'; end if;

  delete from public.magic_families where slug=p_slug;

  insert into public.gm_audit_log(
    actor_user_id,action,target_type,target_id,details
  )
  values(
    auth.uid(),'magic_family.delete','magic_family',p_slug,'{}'::jsonb
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.gm_list_magic_families()
 RETURNS TABLE(slug text, name text, kind text, description text, enabled boolean, is_system boolean, sort_order smallint, spell_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
begin
  if not private.is_gm(auth.uid()) then raise exception 'GM_REQUIRED'; end if;

  return query
  select
    f.slug,f.name,f.kind,f.description,f.enabled,f.is_system,f.sort_order,
    count(sf.spell_id)::bigint
  from public.magic_families f
  left join public.spell_magic_families sf on sf.family_slug=f.slug
  group by f.slug
  order by
    case f.kind when 'element' then 1 when 'school' then 2 when 'function' then 3 else 4 end,
    f.sort_order,f.name;
end;
$function$;

CREATE OR REPLACE FUNCTION public.gm_save_magic_family(p_slug text, p_name text, p_kind text, p_description text, p_enabled boolean, p_sort_order smallint)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  normalized_slug text:=lower(btrim(coalesce(p_slug,'')));
begin
  if not private.is_gm(auth.uid()) then raise exception 'GM_REQUIRED'; end if;

  if normalized_slug='' or normalized_slug !~ '^[a-z0-9_]+$' then
    raise exception 'INVALID_MAGIC_FAMILY_SLUG';
  end if;

  if btrim(coalesce(p_name,''))='' then
    raise exception 'MAGIC_FAMILY_NAME_REQUIRED';
  end if;

  if p_kind not in ('element','school','function','other') then
    raise exception 'INVALID_MAGIC_FAMILY_KIND';
  end if;

  insert into public.magic_families(
    slug,name,kind,description,enabled,is_system,sort_order
  )
  values(
    normalized_slug,btrim(p_name),p_kind,coalesce(p_description,''),
    coalesce(p_enabled,true),false,coalesce(p_sort_order,0)
  )
  on conflict(slug) do update set
    name=excluded.name,
    kind=excluded.kind,
    description=excluded.description,
    enabled=excluded.enabled,
    sort_order=excluded.sort_order,
    updated_at=now();

  insert into public.gm_audit_log(
    actor_user_id,action,target_type,target_id,details
  )
  values(
    auth.uid(),'magic_family.save','magic_family',normalized_slug,
    jsonb_build_object('name',p_name,'kind',p_kind,'enabled',p_enabled)
  );

  return normalized_slug;
end;
$function$;

CREATE OR REPLACE FUNCTION public.gm_save_spell_definition_v3(p_id uuid, p_slug text, p_name text, p_description text, p_enabled boolean, p_spell_kind text, p_damage_type text, p_mana_cost integer, p_required_level integer, p_power_multiplier numeric, p_flat_power integer, p_status_effect_type text, p_status_effect_chance smallint, p_status_effect_turns smallint, p_status_effect_potency integer, p_support_effect_type text, p_support_value integer, p_support_turns smallint, p_family_slugs text[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  saved_id uuid;
  normalized_families text[];
begin
  if not private.is_gm(auth.uid()) then raise exception 'GM_REQUIRED'; end if;

  saved_id:=public.gm_save_spell_definition_v2(
    p_id,p_slug,p_name,p_description,p_enabled,p_spell_kind,p_damage_type,
    p_mana_cost,p_required_level,p_power_multiplier,p_flat_power,
    p_status_effect_type,p_status_effect_chance,p_status_effect_turns,p_status_effect_potency,
    p_support_effect_type,p_support_value,p_support_turns
  );

  select coalesce(array_agg(distinct lower(btrim(x))) filter(where btrim(x)<>''),'{}'::text[])
  into normalized_families
  from unnest(coalesce(p_family_slugs,'{}'::text[])) x;

  if cardinality(normalized_families)=0 then
    normalized_families:=case
      when p_spell_kind='damage' and p_damage_type is not null then array[p_damage_type]
      when p_spell_kind='heal' then array['healing']
      when p_spell_kind='guard' then array['protective']
      when p_spell_kind='cleanse' then array['cleansing']
      when p_spell_kind='buff' then array['enhancement']
      when p_spell_kind='taunt' then array['control']
      when p_spell_kind='sacrifice' then array['sacrifice']
      else '{}'::text[]
    end;
  end if;

  if exists(
    select 1
    from unnest(normalized_families) x
    left join public.magic_families f on f.slug=x and f.enabled
    where f.slug is null
  ) then
    raise exception 'UNKNOWN_MAGIC_FAMILY';
  end if;

  delete from public.spell_magic_families where spell_id=saved_id;

  insert into public.spell_magic_families(spell_id,family_slug)
  select saved_id,x
  from unnest(normalized_families) x;

  update public.gm_audit_log
  set details=coalesce(details,'{}'::jsonb)
      || jsonb_build_object('magic_families',normalized_families)
  where id=(
    select id
    from public.gm_audit_log
    where actor_user_id=auth.uid()
      and target_type='spell_definition'
      and target_id=saved_id::text
    order by created_at desc
    limit 1
  );

  return saved_id;
end;
$function$;

revoke all on function private.spell_has_magic_family(uuid,text) from public,anon,authenticated;
revoke all on function private.spell_magic_family_slugs(uuid) from public,anon,authenticated;

revoke all on function public.get_magic_family_catalog() from public,anon;
grant execute on function public.get_magic_family_catalog() to authenticated;

revoke all on function public.gm_list_magic_families() from public,anon;
grant execute on function public.gm_list_magic_families() to authenticated;

revoke all on function public.gm_save_magic_family(text,text,text,text,boolean,smallint) from public,anon;
grant execute on function public.gm_save_magic_family(text,text,text,text,boolean,smallint) to authenticated;

revoke all on function public.gm_delete_magic_family(text) from public,anon;
grant execute on function public.gm_delete_magic_family(text) to authenticated;

revoke all on function public.get_gm_spell_definitions_v2() from public,anon;
grant execute on function public.get_gm_spell_definitions_v2() to authenticated;

revoke all on function public.get_character_spells_v2(uuid) from public,anon;
grant execute on function public.get_character_spells_v2(uuid) to authenticated;

revoke all on function public.gm_save_spell_definition_v3(
  uuid,text,text,text,boolean,text,text,integer,integer,numeric,integer,
  text,smallint,smallint,integer,text,integer,smallint,text[]
) from public,anon;
grant execute on function public.gm_save_spell_definition_v3(
  uuid,text,text,text,boolean,text,text,integer,integer,numeric,integer,
  text,smallint,smallint,integer,text,integer,smallint,text[]
) to authenticated;
