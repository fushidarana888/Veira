-- Remove the short-lived duplicate onboarding implementation while preserving
-- any completed state by mapping it into the canonical newcomer journey.

do $migration$
begin
  if to_regclass('public.character_first_journeys') is not null then
    insert into public.character_newcomer_journeys(
      character_id,started_at,completed_at,dismissed_at,stage,approach,preparation,
      trial_hp,trial_hp_max,boss_hp,boss_hp_max,guard_active,clue_power,round,
      battle_log,reward_claimed,updated_at
    )
    select
      f.character_id,
      f.created_at,
      f.completed_at,
      null,
      f.stage,
      case f.first_choice
        when 'tracks' then 'tracks'
        when 'survivor' then 'witness'
        when 'cargo' then 'cargo'
        else null
      end,
      case f.second_choice
        when 'trap' then 'ambush'
        when 'voice' then 'listen'
        when 'silence' then 'ward'
        else null
      end,
      case when f.stage=3 then 1 else 0 end,
      case when f.stage=3 then 1 else 0 end,
      0,0,false,0,
      case when f.stage=3 then 1 else 0 end,
      case
        when f.stage=3 then jsonb_build_array('Первая версия «Эха дороги» завершена до объединения пролога.')
        else '[]'::jsonb
      end,
      (f.stage=3),
      f.updated_at
    from public.character_first_journeys f
    on conflict(character_id) do nothing;
  end if;
end
$migration$;

drop function if exists public.get_newcomer_world_activity(uuid);
drop function if exists public.advance_first_journey(uuid,text);
drop function if exists public.get_first_journey(uuid);
drop table if exists public.character_first_journeys;
