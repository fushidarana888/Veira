import type { AccountType } from '@veira/game-core'

export type Profile = {
  user_id: string
  display_name: string
  avatar_url: string | null
  account_type: AccountType
  email_verified: boolean
  email_verified_at: string | null
}

export type CharacterProgress = {
  character_id: string
  level: number
  experience: number
  hp_current: number
  hp_max: number
  mana_current: number
  mana_max: number
  strength: number
  agility: number
  intellect: number
  vitality: number
  luck: number
  gold: number
  unspent_stat_points: number
  updated_at: string
  hp_regen_anchor_at?: string
  mana_regen_anchor_at?: string
}

export type RacePassiveType =
  | 'all_damage_bonus'
  | 'physical_damage_bonus'
  | 'magic_damage_bonus'
  | 'lifesteal'
  | 'mana_on_hit'
  | 'damage_vs_wounded'
  | 'guard_boost'
  | 'low_hp_damage_reduction'
  | 'boss_damage_bonus'

export type RaceDefinition = {
  id: string
  slug: string
  name: string
  category: string
  description: string
  sort_order: number
  playable: boolean
  stat_modifiers: Record<string, number>
  traits: unknown[]
  innate_magic_damage_type: ElementalDamageType
  access_mode: 'open' | 'gm_only'
  hp_bonus: number
  mana_bonus: number
  hp_regen_per_hour: number
  mana_regen_per_hour: number
  damage_resistances: Partial<Record<DamageType, number>>
  passive_type: RacePassiveType | null
  passive_value: number
  passive_name: string
  passive_description: string
  is_available?: boolean
}

export type Character = {
  id: string
  owner_user_id: string
  name: string
  race: string
  race_id: string
  bio: string
  avatar_url: string | null
  created_at: string
  updated_at: string
  character_progress: CharacterProgress | CharacterProgress[] | null
}

export type ItemCategory =
  | 'weapon'
  | 'armor'
  | 'accessory'
  | 'consumable'
  | 'material'
  | 'quest'

export type ItemRarity =
  | 'common'
  | 'uncommon'
  | 'rare'
  | 'epic'
  | 'legendary'
  | 'unique'

export type DamageType =
  | 'slashing'
  | 'piercing'
  | 'blunt'
  | 'fire'
  | 'water'
  | 'earth'
  | 'air'
  | 'lightning'
  | 'ice'

export type PhysicalDamageType = Extract<DamageType, 'slashing' | 'piercing' | 'blunt'>
export type ElementalDamageType = Extract<DamageType, 'fire' | 'water' | 'earth' | 'air' | 'lightning' | 'ice'>

export type CombatStatusEffectType =
  | 'burn'
  | 'bleed'
  | 'poison'
  | 'chill'
  | 'stun'
  | 'weaken'
  | 'vulnerable'

export type ItemEquipGroup =
  | 'weapon'
  | 'offhand'
  | 'head'
  | 'chest'
  | 'hands'
  | 'legs'
  | 'feet'
  | 'accessory'

export type EquipmentSlot =
  | 'weapon'
  | 'offhand'
  | 'head'
  | 'chest'
  | 'hands'
  | 'legs'
  | 'feet'
  | 'accessory_1'
  | 'accessory_2'

export type ItemDefinition = {
  id: string
  slug: string
  name: string
  description: string
  category: ItemCategory
  rarity: ItemRarity
  equip_group: ItemEquipGroup | null
  stackable: boolean
  max_stack: number
  icon_url: string | null
  stat_modifiers: Record<string, number>
  effects: unknown[]
  base_value: number
  required_level: number
  shop_tier: number
  shop_price: number
  shop_enabled: boolean
  damage_type: DamageType | null
  damage_resistances: Partial<Record<DamageType, number>>
  scroll_spell_id: string | null
  scroll_mode: 'learn' | 'cast' | null
  unique_property_name: string | null
  unique_property_description: string
  unique_effect_type: 'lifesteal' | 'mana_on_hit' | 'damage_vs_wounded' | 'guard_boost' | null
  unique_effect_value: number
}

export type CharacterItem = {
  id: string
  character_id: string
  item_definition_id: string
  quantity: number
  durability_current: number | null
  durability_max: number | null
  custom_name: string | null
  metadata: Record<string, unknown>
  acquired_at: string
  item_definitions: ItemDefinition | ItemDefinition[] | null
}

export type CharacterEquipment = {
  character_id: string
  slot: EquipmentSlot
  character_item_id: string
  equipped_at: string
}


export type MapSector = {
  id: number
  grid_col: number
  grid_row: number
  initially_known: boolean
  location_key: string | null
  location_name: string | null
  terrain: string | null
  metadata: Record<string, unknown>
}

export type CharacterSectorDiscovery = {
  character_id: string
  sector_id: number
  discovered_at: string
  source: string
}

export type SectorTerrain =
  | 'unassigned'
  | 'plains'
  | 'forest'
  | 'swamp'
  | 'desert'
  | 'mountains'
  | 'tundra'
  | 'coast'
  | 'sea'
  | 'riverlands'

export type SectorContentType =
  | 'unassigned'
  | 'wilderness'
  | 'settlement'
  | 'ruins'
  | 'dungeon'
  | 'resource'
  | 'npc'
  | 'landmark'
  | 'event'

export type CharacterMapSector = {
  id: number
  grid_col: number
  grid_row: number
  initially_known: boolean
  is_discovered: boolean
  discovered_at: string | null
  is_explorable: boolean
  title: string | null
  terrain_type: SectorTerrain | null
  content_type: SectorContentType | null
  player_description: string | null
  danger_level: number | null
  requires_gm: boolean
}

export type GmMapSector = {
  id: number
  grid_col: number
  grid_row: number
  initially_known: boolean
  title: string | null
  terrain_type: SectorTerrain
  content_type: SectorContentType
  player_description: string
  danger_level: number
  danger_configured: boolean
  settlement_level: number
  requires_gm: boolean
  gm_notes: string
  event_enabled: boolean
  event_title: string
  event_prompt: string
  event_gm_notes: string
}

export type SectorExpedition = {
  id: string
  character_id: string
  sector_id: number
  status: 'active' | 'awaiting_event' | 'completed' | 'cancelled'
  started_at: string
  ends_at: string
  completed_at: string | null
  created_at: string
}

export type ExpeditionEventInstance = {
  id: string
  expedition_id: string
  event_definition_id: string | null
  encounter_template_id: string | null
  source_kind: 'sector' | 'random'
  character_id: string
  sector_id: number
  title: string
  player_prompt: string
  gm_notes: string
  status: 'pending' | 'resolved'
  resolution_text: string
  outcome: 'discovered' | 'blocked' | null
  created_at: string
  resolved_at: string | null
  resolved_by: string | null
}

export type ExpeditionResult = {
  id: string
  expedition_id: string
  character_id: string
  sector_id: number
  source: 'standard' | 'random_event' | 'gm_event'
  result_type: SectorContentType
  title: string
  summary: string
  outcome: 'discovered' | 'blocked'
  encounter_template_id: string | null
  created_at: string
}

export type ExplorationEventTemplate = {
  id: string
  name: string
  enabled: boolean
  terrain_type: SectorTerrain | null
  content_type: SectorContentType | null
  min_danger: number
  max_danger: number
  chance_percent: number
  weight: number
  requires_gm: boolean
  title: string
  player_prompt: string
  automatic_result: string
  gm_notes: string
  created_at: string
  updated_at: string
}


export type SectorSiteProgress = {
  character_id: string
  sector_id: number
  site_type: 'ruins' | 'dungeon'
  status: 'explored' | 'scouted' | 'cleared'
  first_interacted_at: string
  completed_at: string
  updated_at: string
}

export type SectorSiteAction = {
  id: string
  character_id: string
  sector_id: number
  action_type: 'explore_ruins' | 'scout_dungeon'
  status: 'active' | 'completed' | 'cancelled'
  started_at: string
  ends_at: string
  completed_at: string | null
  result_title: string
  result_text: string
  created_at: string
}

export type DungeonRun = {
  id: string
  character_id: string
  sector_id: number
  status: 'active' | 'completed' | 'abandoned'
  current_stage: string
  rooms_cleared: number
  total_rooms: number
  reward_gold: number
  reward_experience: number
  started_at: string
  ended_at: string | null
  created_at: string
}

export type CharacterAdventureSite = {
  sector_id: number
  title: string
  content_type: 'ruins' | 'dungeon'
  site_status: 'explored' | 'scouted' | 'cleared' | null
  active_run_id: string | null
  run_status: 'active' | 'completed' | 'abandoned' | null
  run_stage: string | null
  run_started_at: string | null
  run_rooms_cleared: number | null
  run_total_rooms: number | null
  run_reward_gold: number | null
  run_reward_experience: number | null
}


export type CombatEncounter = {
  id: string
  dungeon_run_id: string
  character_id: string
  sector_id: number
  status: 'active' | 'victory' | 'defeat' | 'cancelled'
  round: number
  room_index: number
  is_boss: boolean
  enemy_template_id: string | null
  enemy_name: string
  enemy_level: number
  enemy_hp_current: number
  enemy_hp_max: number
  enemy_attack: number
  enemy_defense: number
  enemy_initiative: number
  enemy_damage_type: DamageType
  enemy_resistances: Partial<Record<DamageType, number>>
  player_physical_damage_type: PhysicalDamageType
  player_magic_damage_type: ElementalDamageType
  player_hp_current: number
  player_hp_max: number
  player_mana_current: number
  player_mana_max: number
  player_counter_bonus_percent: number
  player_counter_blocked_damage: number
  enemy_on_hit_effect_type: CombatStatusEffectType | null
  enemy_on_hit_effect_chance: number
  enemy_on_hit_effect_turns: number
  enemy_on_hit_effect_potency: number
  enemy_special_name: string
  enemy_special_kind: 'attack' | 'heal' | 'guard' | 'enrage' | 'cleanse'
  enemy_special_value: number
  enemy_special_damage_multiplier: number
  enemy_special_every_n: number
  enemy_special_damage_type: DamageType | null
  enemy_special_effect_type: CombatStatusEffectType | null
  enemy_special_effect_chance: number
  enemy_special_effect_turns: number
  enemy_special_effect_potency: number
  enemy_special_telegraph_text: string
  enemy_special_attack_text: string
  enemy_special_charging: boolean
  enemy_special_started_round: number | null
  enemy_guard_percent: number
  enemy_guard_hits: number
  enemy_attack_bonus_percent: number
  enemy_phase: number
  enemy_phase2_hp_percent: number
  enemy_phase2_name: string
  enemy_phase2_attack_bonus_percent: number
  enemy_phase2_defense_bonus_percent: number
  enemy_phase2_special_every_n: number
  created_at: string
  ended_at: string | null
}

export type CombatTurn = {
  id: number
  encounter_id: string
  round: number
  actor: 'player' | 'enemy' | 'system'
  action_type: string
  damage: number
  player_hp_after: number
  enemy_hp_after: number
  message: string
  created_at: string
}


export type SettlementShopItem = {
  settlement_name: string
  settlement_level: number
  item_id: string
  slug: string
  item_name: string
  description: string
  category: ItemCategory
  rarity: ItemRarity
  equip_group: ItemEquipGroup | null
  stat_modifiers: Record<string, number>
  damage_type: DamageType | null
  damage_resistances: Partial<Record<DamageType, number>>
  scroll_mode: 'learn' | 'cast' | null
  scroll_spell_id: string | null
  scroll_spell_name: string | null
  heal_amount: number
  price: number
  required_level: number
  shop_tier: number
  can_afford: boolean
  level_unlocked: boolean
}


export type EnemyAbility = {
  id: string
  enabled: boolean
  name: string
  kind: 'attack' | 'heal' | 'guard' | 'enrage' | 'cleanse'
  priority: number
  cooldown: number
  max_uses: number
  phase: 0 | 1 | 2
  min_enemy_hp_percent: number
  max_enemy_hp_percent: number
  min_player_hp_percent: number
  max_player_hp_percent: number
  min_debuffs: number
  value: number
  damage_multiplier: number
  damage_type: DamageType | null
  effect_type: CombatStatusEffectType | null
  effect_chance: number
  effect_turns: number
  effect_potency: number
  telegraph_text: string
  attack_text: string
}

export type EnemyTemplate = {
  id: string
  slug: string
  name: string
  description: string
  enabled: boolean
  terrain_type: SectorTerrain | null
  min_danger: number
  max_danger: number
  is_boss: boolean
  weight: number
  attack_damage_type: DamageType
  damage_resistances: Partial<Record<DamageType, number>>
  hp_multiplier: number
  attack_multiplier: number
  defense_multiplier: number
  initiative_multiplier: number
  on_hit_effect_type: CombatStatusEffectType | null
  on_hit_effect_chance: number
  on_hit_effect_turns: number
  on_hit_effect_potency: number
  special_name: string
  special_kind: 'attack' | 'heal' | 'guard' | 'enrage' | 'cleanse'
  special_value: number
  special_damage_multiplier: number
  special_every_n: number
  special_damage_type: DamageType | null
  special_effect_type: CombatStatusEffectType | null
  special_effect_chance: number
  special_effect_turns: number
  special_effect_potency: number
  special_telegraph_text: string
  special_attack_text: string
  phase2_hp_percent: number
  phase2_name: string
  phase2_attack_bonus_percent: number
  phase2_defense_bonus_percent: number
  phase2_special_every_n: number
  abilities: EnemyAbility[]
  created_at: string
  updated_at: string
}


export type SpellDefinition = {
  id: string
  slug: string
  name: string
  description: string
  enabled: boolean
  spell_kind: 'damage' | 'heal'
  damage_type: ElementalDamageType | null
  mana_cost: number
  required_level: number
  power_multiplier: number
  flat_power: number
  status_effect_type: CombatStatusEffectType | null
  status_effect_chance: number
  status_effect_turns: number
  status_effect_potency: number
  created_at: string
  updated_at: string
}

export type CharacterSpell = {
  id: string
  slug: string
  name: string
  description: string
  spell_kind: 'damage' | 'heal'
  damage_type: ElementalDamageType | null
  mana_cost: number
  required_level: number
  power_multiplier: number
  flat_power: number
  status_effect_type: CombatStatusEffectType | null
  status_effect_chance: number
  status_effect_turns: number
  status_effect_potency: number
  learned_at: string
  source: string
}


export type CombatStatusEffect = {
  id: string
  encounter_id: string
  target: 'player' | 'enemy'
  effect_type: CombatStatusEffectType
  potency: number
  remaining_turns: number
  source: string
  created_at: string
  updated_at: string
}


export type DungeonLootDrop = {
  drop_id: string
  source_type: 'enemy' | 'boss' | 'dungeon'
  item_id: string
  item_name: string
  item_slug: string
  category: ItemCategory
  rarity: ItemRarity
  quantity: number
  combat_encounter_id: string | null
  created_at: string
}

export type LootPoolEntry = {
  id: string
  source_type: 'enemy' | 'dungeon'
  enemy_template_id: string | null
  enemy_name: string | null
  sector_id: number | null
  sector_name: string | null
  terrain_type: SectorTerrain | null
  min_danger: number
  max_danger: number
  item_definition_id: string
  item_name: string
  item_rarity: ItemRarity
  chance_percent: number
  min_quantity: number
  max_quantity: number
  enabled: boolean
  created_at: string
  updated_at: string
}


export type ItemAffixInstance = {
  id: string
  slug: string
  name: string
  description: string
  stat_modifiers: Record<string, number>
  damage_resistances: Partial<Record<DamageType, number>>
}

export type CraftingIngredientState = {
  item_definition_id: string
  name: string
  rarity: ItemRarity
  required_quantity: number
  owned_quantity: number
}

export type CharacterCraftingRecipe = {
  recipe_id: string
  slug: string
  name: string
  description: string
  required_level: number
  gold_cost: number
  output_item_id: string
  output_item_name: string
  output_rarity: ItemRarity
  output_category: ItemCategory
  output_quantity: number
  affix_bonus: number
  level_unlocked: boolean
  can_afford_gold: boolean
  has_ingredients: boolean
  can_craft: boolean
  ingredients: CraftingIngredientState[]
}

export type GmCraftingRecipe = {
  id: string
  slug: string
  name: string
  description: string
  enabled: boolean
  required_level: number
  gold_cost: number
  output_item_definition_id: string
  output_item_name: string
  output_quantity: number
  affix_bonus: number
  sort_order: number
  ingredients: Array<{
    item_definition_id: string
    name: string
    quantity: number
  }>
  created_at: string
  updated_at: string
}

export type EquipmentAffix = {
  id: string
  slug: string
  name: string
  description: string
  enabled: boolean
  min_rarity_rank: number
  max_rarity_rank: number
  weight: number
  allowed_categories: Array<'weapon' | 'armor' | 'accessory'>
  allowed_equip_groups: ItemEquipGroup[]
  stat_modifiers: Record<string, number>
  damage_resistances: Partial<Record<DamageType, number>>
  created_at: string
  updated_at: string
}


export type RaceAccessGrant = {
  user_id: string
  display_name: string
  race_id: string
  race_name: string
  granted_at: string
  granted_by: string
}


export type AutobattleStrategy = 'conservative' | 'balanced' | 'aggressive'

export type AutobattleGuardMode = 'never' | 'low_hp' | 'interval' | 'low_hp_or_interval'

export type AutobattleSettings = {
  character_id: string
  strategy: AutobattleStrategy
  stop_hp_percent: number
  mana_reserve_percent: number
  use_learned_spells: boolean
  include_boss: boolean
  normal_allow_physical: boolean
  normal_allow_magic: boolean
  normal_allow_spells: boolean
  normal_guard_mode: AutobattleGuardMode
  normal_guard_hp_percent: number
  normal_guard_every_n: number
  boss_allow_physical: boolean
  boss_allow_magic: boolean
  boss_allow_spells: boolean
  boss_guard_mode: AutobattleGuardMode
  boss_guard_hp_percent: number
  boss_guard_every_n: number
  updated_at: string
}

export type AutobattleSpellRule = {
  spell_id: string
  spell_name: string
  normal_enabled: boolean
  normal_priority: number
  boss_enabled: boolean
  boss_priority: number
}

export type AutobattleResult = {
  status: 'active' | 'victory' | 'defeat' | 'completed' | 'abandoned' | 'stopped' | string
  reason: string
  actions: number
  encounter_id?: string
  run_id?: string
  rooms_cleared?: number
  player_hp?: number
  player_hp_max?: number
  player_mana?: number
  player_mana_max?: number
  hp_percent?: number
}
