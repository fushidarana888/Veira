export type AccountType = 'player' | 'gm'

export type StatKey =
  | 'strength'
  | 'agility'
  | 'intellect'
  | 'vitality'
  | 'luck'

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

export type StatModifiers = Partial<Record<StatKey, number>>

export function experienceForNextLevel(level: number): number {
  const safeLevel = Math.max(1, Math.floor(level))
  return 100 * safeLevel * safeLevel
}

export function addStatModifiers(
  base: Record<StatKey, number>,
  modifiers: StatModifiers[],
): Record<StatKey, number> {
  const result = { ...base }

  for (const modifier of modifiers) {
    for (const key of Object.keys(modifier) as StatKey[]) {
      const value = modifier[key]
      if (typeof value === 'number' && Number.isFinite(value)) {
        result[key] += value
      }
    }
  }

  return result
}
