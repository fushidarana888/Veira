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

export type DerivedCombatStats = {
  physicalPower: number
  magicPower: number
  defense: number
  initiative: number
}

export function experienceForNextLevel(level: number): number {
  const safeLevel = Math.max(1, Math.floor(level))
  return 100 * safeLevel * safeLevel
}

export function baseHpMax(level: number, vitality: number): number {
  const safeLevel = Math.max(1, Math.floor(level))
  const safeVitality = Math.max(0, Math.floor(vitality))
  return 70 + safeVitality * 10 + (safeLevel - 1) * 5
}

export function calculateDerivedCombatStats(
  level: number,
  stats: Record<StatKey, number>,
): DerivedCombatStats {
  const safeLevel = Math.max(1, Math.floor(level))

  return {
    physicalPower: stats.strength * 3 + stats.agility + safeLevel * 2,
    magicPower: stats.intellect * 3 + stats.luck + safeLevel * 2,
    defense: stats.vitality * 2 + stats.agility + safeLevel,
    initiative: stats.agility * 2 + stats.luck,
  }
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
