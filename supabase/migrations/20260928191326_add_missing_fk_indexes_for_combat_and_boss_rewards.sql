-- Synced from live Supabase migration 20260928191326 (add_missing_fk_indexes_for_combat_and_boss_rewards)

create index if not exists combat_summons_summon_definition_id_idx
  on private.combat_summons(summon_definition_id);

create index if not exists event_boss_events_reward_material_item_id_idx
  on public.event_boss_events(reward_material_item_id);
