
create or replace function public.character_hp_max(p_level integer,p_vitality integer)
returns integer
language sql
immutable strict
set search_path to 'pg_catalog'
as $$
  select greatest(1,70+greatest(0,p_vitality)*7+greatest(0,p_level-1)*5);
$$;

create or replace function public.character_mana_max(p_level integer,p_intellect integer)
returns integer
language sql
immutable
set search_path to 'pg_catalog','public'
as $$
  select greatest(
    20,
    round(30+greatest(0,p_intellect)*4.9+greatest(0,p_level-1)*4)::integer
  );
$$;

with caps as (
  select cp.character_id,
         private.race_hp_max(c.race_id,cp.level,cp.vitality) new_hp_max,
         private.race_mana_max(c.race_id,cp.level,cp.intellect) new_mana_max
  from public.character_progress cp
  join public.characters c on c.id=cp.character_id
)
update public.character_progress cp
set hp_current=case
      when cp.hp_current<=0 then 0
      else greatest(1,least(caps.new_hp_max,
        round(cp.hp_current*caps.new_hp_max::numeric/greatest(1,cp.hp_max))::integer))
    end,
    hp_max=caps.new_hp_max,
    mana_current=greatest(0,least(caps.new_mana_max,
      round(cp.mana_current*caps.new_mana_max::numeric/greatest(1,cp.mana_max))::integer)),
    mana_max=caps.new_mana_max
from caps
where caps.character_id=cp.character_id
  and (
    cp.hp_max<>caps.new_hp_max
    or cp.mana_max<>caps.new_mana_max
  );

