-- Synced from live Supabase migration 20261001053608 (exclude_treasure_expeditions_from_religion)

create or replace function private.religion_on_expedition_completed()
returns trigger
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  content text;
begin
  if new.status='completed'
     and old.status is distinct from 'completed'
     and new.treasure_hunt_id is null
  then
    select content_type
    into content
    from public.sector_details
    where sector_id=new.sector_id;

    if content='wilderness' then
      perform private.record_religion_event(
        new.character_id,
        'wilderness_expedition_completed',
        'expedition:'||new.id::text,
        jsonb_build_object('sector_id',new.sector_id,'content_type','wilderness')
      );
    end if;
  end if;

  return new;
end;
$$;

revoke execute on function private.religion_on_expedition_completed()
  from public, anon, authenticated;
