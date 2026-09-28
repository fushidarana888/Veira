-- Synced from live Supabase migration 20260928185159 (adaptive_boss_telegraph_foundation)


alter table public.party_combat_encounters
  add column if not exists enemy_ai_state jsonb not null default '{}'::jsonb;

update public.event_boss_events
set mechanics=coalesce(mechanics,'{}'::jsonb)
  || jsonb_build_object(
    'adaptive_telegraph',
    jsonb_build_object(
      'enabled',true,
      'delay_chance_percent',
        case boss_kind
          when 'monthly' then 35
          when 'world_enemy' then 35
          else 25
        end,
      'defensive_delay_chance_percent',
        case boss_kind
          when 'monthly' then 78
          when 'world_enemy' then 72
          else 60
        end,
      'break_threshold_max_hp_percent',
        case boss_kind
          when 'monthly' then 7
          when 'world_enemy' then 8
          else 10
        end,
      'break_special_reduction_percent',
        case boss_kind
          when 'monthly' then 25
          when 'world_enemy' then 25
          else 20
        end,
      'stored_guard_decay_percent',
        case boss_kind
          when 'monthly' then 38
          when 'world_enemy' then 35
          else 30
        end,
      'max_delay_actions',1
    )
  )
where enabled
  and boss_kind in ('weekly','monthly','world_enemy')
  and coalesce(mechanics->>'scheduled','false')='true';

