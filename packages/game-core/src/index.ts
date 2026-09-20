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

export type WeaponScaling = 'strength' | 'agility' | 'hybrid'

export type WeaponAttackProfile = {
  baseDamage: number
  scaling: WeaponScaling
}

export type DerivedCombatStats = {
  physicalPower: number
  magicPower: number
  physicalDefense: number
  magicDefense: number
  /** @deprecated Legacy alias for physicalDefense. */
  defense: number
  initiative: number
  criticalChancePercent: number
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
  weapon: WeaponAttackProfile = { baseDamage: 0, scaling: 'strength' },
): DerivedCombatStats {
  const safeLevel = Math.max(1, Math.floor(level))
  const safeWeaponDamage = Math.max(0, Math.floor(weapon.baseDamage))
  const physicalStatPower = weapon.scaling === 'agility'
    ? stats.agility * 3 + stats.strength * 0.5
    : weapon.scaling === 'hybrid'
      ? stats.strength * 1.75 + stats.agility * 1.75
      : stats.strength * 3 + stats.agility * 0.5

  const physicalDefense = Math.max(
    0,
    Math.round(stats.vitality * 2 + stats.agility * 0.5 + safeLevel),
  )
  const magicDefense = stats.vitality + stats.intellect + safeLevel

  return {
    physicalPower: Math.max(0, Math.round(safeWeaponDamage + physicalStatPower + safeLevel * 2)),
    magicPower: stats.intellect * 3 + stats.luck + safeLevel * 2,
    physicalDefense,
    magicDefense,
    defense: physicalDefense,
    initiative: stats.agility * 2 + stats.luck,
    criticalChancePercent: Math.min(60, Math.max(0, 1 + stats.luck * 0.3)),
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
