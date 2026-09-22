
create or replace function private.cleanup_combat_summons_for_encounter()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
  v_context text:=tg_argv[0];
  v_encounter_id uuid:=case when tg_op='DELETE' then old.id else new.id end;
begin
  if v_context not in ('solo','party') then
    raise exception 'INVALID_SUMMON_CONTEXT';
  end if;

  if tg_op='DELETE' then
    delete from private.combat_summons
    where context_type=v_context
      and encounter_id=v_encounter_id;
    return old;
  end if;

  if old.status='active' and new.status<>'active' then
    update private.combat_summons
    set status='dismissed',
        died_at=coalesce(died_at,now())
    where context_type=v_context
      and encounter_id=v_encounter_id
      and status='active';
  end if;

  return new;
end;
$$;

revoke all on function private.cleanup_combat_summons_for_encounter() from public;

drop trigger if exists cleanup_solo_combat_summons_on_end on public.combat_encounters;
create trigger cleanup_solo_combat_summons_on_end
after update of status or delete on public.combat_encounters
for each row
execute function private.cleanup_combat_summons_for_encounter('solo');

drop trigger if exists cleanup_party_combat_summons_on_end on public.party_combat_encounters;
create trigger cleanup_party_combat_summons_on_end
after update of status or delete on public.party_combat_encounters
for each row
execute function private.cleanup_combat_summons_for_encounter('party');
