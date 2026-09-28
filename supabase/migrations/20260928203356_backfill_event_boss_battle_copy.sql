-- Synced from live Supabase migration 20260928203356 (backfill_event_boss_battle_copy)

update public.party_combat_turns t
set message='Группа вступает в бой с боссом «'||ebe.name||'». У каждого участника по одному действию за раунд.'
from public.party_combat_encounters ce
join public.party_dungeon_runs pr on pr.id=ce.run_id
join public.event_boss_events ebe on ebe.id=pr.event_boss_id
where t.encounter_id=ce.id
  and t.action_type='event_boss_start'
  and ebe.boss_kind<>'sector_incursion'
  and t.message ilike '%временн%угроз%';

update public.party_combat_turns t
set message='Босс «'||ebe.name||'» повержен. Личная награда каждого участника рассчитана отдельно; повторный вклад одного и того же персонажа не засчитывается.'
from public.party_combat_encounters ce
join public.party_dungeon_runs pr on pr.id=ce.run_id
join public.event_boss_events ebe on ebe.id=pr.event_boss_id
where t.encounter_id=ce.id
  and t.action_type='event_boss_victory'
  and ebe.boss_kind<>'sector_incursion'
  and t.message ilike '%временн%угроз%';

update public.combat_turns t
set message='Босс «'||ebe.name||'» повержен. Награда уже начислена.'
from public.combat_encounters ce
join public.dungeon_runs dr on dr.id=ce.dungeon_run_id
join public.event_boss_events ebe on ebe.id=dr.event_boss_id
where t.encounter_id=ce.id
  and t.action_type='event_boss_victory'
  and ebe.boss_kind<>'sector_incursion'
  and t.message ilike 'Событие завершено победой.%';
