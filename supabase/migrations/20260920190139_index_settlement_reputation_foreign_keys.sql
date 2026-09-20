create index if not exists settlement_quest_definitions_target_item_idx
  on public.settlement_quest_definitions(target_item_definition_id)
  where target_item_definition_id is not null;

create index if not exists settlement_reputation_configs_reward_item_idx
  on public.settlement_reputation_configs(level10_reward_item_id)
  where level10_reward_item_id is not null;

create index if not exists settlement_reputation_events_sector_idx
  on public.settlement_reputation_events(sector_id);
