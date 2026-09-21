create index if not exists battle_consumable_usages_character_idx
  on private.battle_consumable_usages(character_id);

create index if not exists battle_consumable_usages_item_definition_idx
  on private.battle_consumable_usages(item_definition_id)
  where item_definition_id is not null;

create index if not exists battle_reward_snapshots_character_idx
  on private.battle_reward_snapshots(character_id);
