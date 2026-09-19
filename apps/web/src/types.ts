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

export type Character = {
  id: string
  owner_user_id: string
  name: string
  race: string
  bio: string
  avatar_url: string | null
  created_at: string
  updated_at: string
  character_progress: CharacterProgress | CharacterProgress[] | null
}
