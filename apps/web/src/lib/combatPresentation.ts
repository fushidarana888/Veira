export function criticalHitCount(message: string | null | undefined): number {
  if (!message) return 0

  const explicit = message.match(/Критических попаданий:\s*(\d+)/i)
  if (explicit) {
    return Math.max(1, Number(explicit[1]) || 1)
  }

  return /\bкрит(?:ический|ическая|ическое|ические|ических)?\b|\(крит\b/i.test(message)
    ? 1
    : 0
}

export function isCriticalCombatMessage(message: string | null | undefined): boolean {
  return criticalHitCount(message) > 0
}
