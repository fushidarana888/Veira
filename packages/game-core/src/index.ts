export type AccountType = 'player' | 'gm'

export type CharacterStats = {
  level: number
  experience: number
  hpCurrent: number
  hpMax: number
  strength: number
  agility: number
  intellect: number
  vitality: number
  luck: number
  gold: number
}

export function experienceForNextLevel(level: number): number {
  const safeLevel = Math.max(1, Math.floor(level))
  return 100 * safeLevel * safeLevel
}
