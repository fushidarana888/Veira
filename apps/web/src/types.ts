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
  strength: number
  agility: number
  intellect: number
  vitality: number
  luck: number
  gold: number
  updated_at: string
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
