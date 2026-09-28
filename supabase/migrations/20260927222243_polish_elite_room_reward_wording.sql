-- Synced from live Supabase migration 20260927222243 (polish_elite_room_reward_wording)


update public.dungeon_event_definitions
set choices=jsonb_set(
  choices,
  '{0,result}',
  to_jsonb('Печать ломается. В следующем зале тебя ждёт элитный противник и гарантированная дополнительная редкая находка.'::text)
),
updated_at=now()
where slug='sealed_arena';

