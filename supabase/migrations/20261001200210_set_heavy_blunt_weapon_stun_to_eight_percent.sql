
create or replace function private.weapon_family_stun_chance_for_family(
  p_family text,
  p_party boolean default false
)
returns integer
language sql
immutable
set search_path to 'pg_catalog'
as $$
  select case
    when p_family in ('hammer','mace','club') then 8
    else 0
  end;
$$;

