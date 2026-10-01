update public.item_definitions
set effects=jsonb_build_array(jsonb_build_object(
  'type','trophy_passive',
  'defense_percent',2,
  'label','+2% к физической защите'
))
where slug='trophy_bell_core';

update public.item_definitions
set effects=jsonb_build_array(jsonb_build_object(
  'type','trophy_passive',
  'damage_bonuses',jsonb_build_object('water',3),
  'label','+3% урона водой'
))
where slug='trophy_bog_eye';

update public.item_definitions
set effects=jsonb_build_array(jsonb_build_object(
  'type','trophy_passive',
  'damage_bonuses',jsonb_build_object('earth',3),
  'label','+3% урона землёй'
))
where slug='trophy_glass_heart';

update public.item_definitions
set effects=jsonb_build_array(jsonb_build_object(
  'type','trophy_passive',
  'damage_bonuses',jsonb_build_object('slashing',2,'piercing',2,'blunt',2),
  'label','+2% физического урона'
))
where slug='trophy_moss_crown';

update public.item_definitions
set effects=jsonb_build_array(jsonb_build_object(
  'type','trophy_passive',
  'damage_bonuses',jsonb_build_object('ice',3),
  'label','+3% урона льдом'
))
where slug='trophy_pale_scale';

create or replace function private.character_trophy_damage_bonus(
  p_character_id uuid,
  p_damage_type text
)
returns integer
language sql
stable
security definer
set search_path to 'pg_catalog','public','private'
as $function$
  with owned_trophies as (
    select distinct d.id,d.effects
    from public.character_items ci
    join public.item_definitions d on d.id=ci.item_definition_id
    where ci.character_id=p_character_id
      and ci.death_spirit_id is null
      and ci.quantity>0
      and d.slug like 'trophy_%'
  ),
  passive_effects as (
    select e.value effect
    from owned_trophies t
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(t.effects)='array' then t.effects else '[]'::jsonb end
    ) e(value)
    where e.value->>'type'='trophy_passive'
  )
  select coalesce(sum(
    case
      when jsonb_typeof(effect->'damage_bonuses'->p_damage_type)='number'
        then (effect->'damage_bonuses'->>p_damage_type)::numeric::integer
      else 0
    end
  ),0)::integer
  from passive_effects;
$function$;

create or replace function private.character_trophy_defense_percent(
  p_character_id uuid
)
returns integer
language sql
stable
security definer
set search_path to 'pg_catalog','public','private'
as $function$
  with owned_trophies as (
    select distinct d.id,d.effects
    from public.character_items ci
    join public.item_definitions d on d.id=ci.item_definition_id
    where ci.character_id=p_character_id
      and ci.death_spirit_id is null
      and ci.quantity>0
      and d.slug like 'trophy_%'
  ),
  passive_effects as (
    select e.value effect
    from owned_trophies t
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(t.effects)='array' then t.effects else '[]'::jsonb end
    ) e(value)
    where e.value->>'type'='trophy_passive'
  )
  select coalesce(sum(
    case
      when jsonb_typeof(effect->'defense_percent')='number'
        then (effect->>'defense_percent')::numeric::integer
      else 0
    end
  ),0)::integer
  from passive_effects;
$function$;

do $$
declare
  definition text;
  dtype text;
  needle text;
  replacement text;
begin
  definition:=pg_get_functiondef('private.character_damage_bonuses(uuid)'::regprocedure);

  foreach dtype in array array[
    'slashing','piercing','blunt','fire','water','earth','air','lightning','ice'
  ]
  loop
    needle:=format('+private.race_damage_type_bonus(p_character_id,%L)',dtype);
    replacement:=needle||format('+private.character_trophy_damage_bonus(p_character_id,%L)',dtype);
    definition:=replace(definition,needle,replacement);
  end loop;

  execute definition;
end;
$$;

create or replace function private.character_defense_percent(p_character_id uuid)
returns integer
language sql
stable
security definer
set search_path to 'pg_catalog','public','private'
as $function$
  select greatest(
    -75,
    least(
      100,
      coalesce((
        select sum(
          case when jsonb_typeof(idf.stat_modifiers->'defense_percent')='number'
            then (idf.stat_modifiers->>'defense_percent')::numeric::integer
            else 0
          end
        )
        from public.character_equipment ce
        join public.character_items ci on ci.id=ce.character_item_id
        join public.item_definitions idf on idf.id=ci.item_definition_id
        where ce.character_id=p_character_id
      ),0)::integer
      + private.camp_preparation_bonus(p_character_id,'fortify')
      + private.character_trophy_defense_percent(p_character_id)
    )
  );
$function$;

drop function public.get_character_trophy_case(uuid);

create function public.get_character_trophy_case(p_character_id uuid)
returns table(
  slug text,
  name text,
  description text,
  quantity integer,
  bonus_text text
)
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $function$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;

  if not private.is_gm(auth.uid())
     and not exists(
       select 1 from public.characters c
       where c.id=p_character_id and c.owner_user_id=auth.uid()
     )
  then raise exception 'CHARACTER_NOT_OWNED'; end if;

  return query
  select
    d.slug,
    d.name,
    d.description,
    sum(ci.quantity)::integer,
    coalesce((
      select string_agg(e.value->>'label',' · ' order by e.ordinality)
      from jsonb_array_elements(
        case when jsonb_typeof(d.effects)='array' then d.effects else '[]'::jsonb end
      ) with ordinality e(value,ordinality)
      where e.value->>'type'='trophy_passive'
        and nullif(e.value->>'label','') is not null
    ),'')
  from public.character_items ci
  join public.item_definitions d on d.id=ci.item_definition_id
  where ci.character_id=p_character_id
    and ci.death_spirit_id is null
    and d.slug like 'trophy_%'
  group by d.id,d.slug,d.name,d.description,d.effects
  order by d.name;
end;
$function$;

revoke all on function public.get_character_trophy_case(uuid) from public, anon;
grant execute on function public.get_character_trophy_case(uuid) to authenticated;
