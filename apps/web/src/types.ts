import type { AccountType } from '@veira/game-core'

export type Profile = {
  user_id: string
  display_name: string
  avatar_url: string | null
  account_type: AccountType
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
  enemy_on_hit_effect_type: CombatStatusEffectType | null
  enemy_on_hit_effect_chance: number
  enemy_on_hit_effect_turns: number
  enemy_on_hit_effect_potency: number
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
