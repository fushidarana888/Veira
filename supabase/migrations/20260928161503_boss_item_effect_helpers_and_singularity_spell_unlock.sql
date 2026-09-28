-- Synced from live Supabase migration 20260928161503 (boss_item_effect_helpers_and_singularity_spell_unlock)


create or replace function private.character_equipped_effect_config(
  p_character_id uuid,
  p_effect_type text
) returns jsonb
language sql
stable
security definer
set search_path='pg_catalog','public','private'
as $$
  select coalesce((
    select effect
    from public.character_equipment ce
    join public.character_items ci on ci.id=ce.character_item_id
    join public.item_definitions i on i.id=ci.item_definition_id
    cross join lateral jsonb_array_elements(i.effects) effect
    where ce.character_id=p_character_id
      and i.unique_effect_type=p_effect_type
      and effect->>'type'=p_effect_type
    order by ce.equipped_at
    limit 1
  ),'{}'::jsonb);
$$;

create or replace function private.character_has_equipped_effect(
  p_character_id uuid,
  p_effect_type text
) returns boolean
language sql
stable
security definer
set search_path='pg_catalog','public','private'
as $$
  select exists(
    select 1
    from public.character_equipment ce
    join public.character_items ci on ci.id=ce.character_item_id
    join public.item_definitions i on i.id=ci.item_definition_id
    where ce.character_id=p_character_id
      and i.unique_effect_type=p_effect_type
  );
$$;

create or replace function private.character_equipped_effect_number(
  p_character_id uuid,
  p_effect_type text,
  p_key text,
  p_default numeric default 0
) returns numeric
language sql
stable
security definer
set search_path='pg_catalog','public','private'
as $$
  select coalesce(
    case
      when jsonb_typeof(private.character_equipped_effect_config(p_character_id,p_effect_type)->p_key)='number'
      then (private.character_equipped_effect_config(p_character_id,p_effect_type)->>p_key)::numeric
      else null
    end,
    p_default
  );
$$;

create or replace function private.character_spell_equipped(
  p_character_id uuid,
  p_spell_id uuid
) returns boolean
language sql
stable
security definer
set search_path='pg_catalog','public','private'
as $$
  select
    exists(
      select 1
      from public.character_combat_spells ccs
      where ccs.character_id=p_character_id
        and ccs.spell_id=p_spell_id
    )
    or exists(
      select 1
      from public.character_equipment ce
      join public.character_items ci on ci.id=ce.character_item_id
      join public.item_definitions i on i.id=ci.item_definition_id
      cross join lateral jsonb_array_elements(i.effects) e
      join public.spell_definitions s on s.slug=e->>'spell_slug'
      where ce.character_id=p_character_id
        and i.unique_effect_type='grant_spell'
        and e->>'type'='grant_spell'
        and s.id=p_spell_id
    );
$$;

create or replace function public.cast_character_spell(
  p_encounter_id uuid,
  p_spell_id uuid
) returns public.combat_encounters
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  v_kind text;
  v_character_id uuid;
begin
  select ce.character_id into v_character_id
  from public.combat_encounters ce
  join public.characters c on c.id=ce.character_id
  where ce.id=p_encounter_id and c.owner_user_id=auth.uid();

  if v_character_id is null then raise exception 'COMBAT_NOT_FOUND'; end if;

  select s.spell_kind into v_kind
  from public.spell_definitions s
  where s.id=p_spell_id
    and s.enabled
    and (
      exists(
        select 1 from public.character_spells cs
        where cs.character_id=v_character_id and cs.spell_id=s.id
      )
      or private.character_spell_equipped(v_character_id,s.id)
    )
  limit 1;

  if v_kind is null then raise exception 'SPELL_NOT_LEARNED'; end if;

  return private.perform_combat_action_internal(
    p_encounter_id,
    case when v_kind in ('guard','cleanse','buff') then 'support_spell' else 'learned_spell' end,
    p_spell_id,
    null
  );
end;
$$;

create or replace function public.get_character_spells_v2(p_character_id uuid)
returns table(
  id uuid,slug text,name text,description text,spell_kind text,damage_type text,
  mana_cost integer,required_level integer,power_multiplier numeric,flat_power integer,
  status_effect_type text,status_effect_chance smallint,status_effect_turns smallint,
  status_effect_potency integer,magic_families jsonb,learned_at timestamptz,source text,combat_slot smallint
)
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare caller uuid:=auth.uid();
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.is_gm(caller)
     and not exists(select 1 from public.characters c where c.id=p_character_id and c.owner_user_id=caller)
  then raise exception 'CHARACTER_NOT_OWNED'; end if;

  return query
  with owned as (
    select cs.spell_id,cs.learned_at,cs.source,ccs.slot
    from public.character_spells cs
    left join public.character_combat_spells ccs
      on ccs.character_id=cs.character_id and ccs.spell_id=cs.spell_id
    where cs.character_id=p_character_id

    union

    select s.id,now(),'equipped_item'::text,0::smallint
    from public.character_equipment ce
    join public.character_items ci on ci.id=ce.character_item_id
    join public.item_definitions i on i.id=ci.item_definition_id
    cross join lateral jsonb_array_elements(i.effects) e
    join public.spell_definitions s on s.slug=e->>'spell_slug'
    where ce.character_id=p_character_id
      and i.unique_effect_type='grant_spell'
      and e->>'type'='grant_spell'
  )
  select
    s.id,s.slug,s.name,s.description,s.spell_kind,s.damage_type,
    private.character_effective_spell_mana_cost(p_character_id,s.id),
    s.required_level,s.power_multiplier,s.flat_power,
    s.status_effect_type,s.status_effect_chance,s.status_effect_turns,s.status_effect_potency,
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'slug',f.slug,'name',f.name,'kind',f.kind,'description',f.description
      ) order by case f.kind when 'element' then 1 when 'school' then 2 when 'function' then 3 else 4 end,f.sort_order,f.name)
      from public.spell_magic_families sf
      join public.magic_families f on f.slug=sf.family_slug
      where sf.spell_id=s.id and f.enabled
    ),'[]'::jsonb),
    o.learned_at,o.source,o.slot
  from owned o
  join public.spell_definitions s on s.id=o.spell_id
  where s.enabled
  order by o.slot nulls last,s.required_level,s.name;
end;
$$;

revoke all on function private.character_equipped_effect_config(uuid,text) from public;
revoke all on function private.character_has_equipped_effect(uuid,text) from public;
revoke all on function private.character_equipped_effect_number(uuid,text,text,numeric) from public;

