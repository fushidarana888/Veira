update public.religion_oath_definitions
set
  description='Победи мирового, недельного, месячного или рейдового босса.',
  success_metadata=jsonb_build_object('major_boss',true)
where religion_slug='abyss'
  and slug='boss';

create or replace function private.religion_on_event_boss_completion()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'private'
as $function$
declare
  start_v integer:=0;
  i integer;
  v_boss_kind text;
  v_major_boss boolean:=false;
begin
  if tg_op='UPDATE' then
    start_v:=coalesce(old.victories,0);
  end if;

  select e.boss_kind
  into v_boss_kind
  from public.event_boss_events e
  where e.id=new.event_id;

  v_major_boss:=coalesce(
    v_boss_kind in ('world_enemy','weekly','monthly','raid'),
    false
  );

  if new.victories>start_v then
    for i in start_v+1..new.victories loop
      perform private.record_religion_event(
        new.character_id,
        'event_boss_victory',
        'event_boss:'||new.event_id::text||':victory:'||i::text,
        jsonb_build_object(
          'event_id',new.event_id,
          'victory_number',i,
          'boss_kind',v_boss_kind,
          'major_boss',v_major_boss
        )
      );
    end loop;
  end if;

  return new;
end;
$function$;

update public.religion_faith_events rfe
set metadata=rfe.metadata || jsonb_build_object(
  'boss_kind',e.boss_kind,
  'major_boss',coalesce(e.boss_kind in ('world_enemy','weekly','monthly','raid'),false)
)
from public.event_boss_events e
where rfe.event_type='event_boss_victory'
  and rfe.metadata->>'event_id'=e.id::text
  and not (rfe.metadata ? 'boss_kind');
