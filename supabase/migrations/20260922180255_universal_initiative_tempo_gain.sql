create or replace function private.initiative_tempo_gain(
  p_actor_initiative integer,
  p_reference_initiative integer
)
returns smallint
language sql
immutable
set search_path to 'pg_catalog'
as $$
  select least(
    25,
    greatest(
      6,
      floor(
        6.0
        + 9.0
          * greatest(0,coalesce(p_actor_initiative,0))::numeric
          / greatest(10,coalesce(p_reference_initiative,10))::numeric
      )::integer
    )
  )::smallint;
$$;

comment on function private.initiative_tempo_gain(integer,integer) is
'Soft action-tempo gain. Every living actor gains tempo after a full action; higher initiative gains it faster relative to the opponent. Gain is clamped to 6..25 per action, so extra full turns happen occasionally rather than doubling action frequency.';
