export type BattleTurnLogEntry = {
  id: string
  room: number | null
  round: number
  actor_name: string
  target_name: string | null
  action_type: string
  action_name: string
  damage: number
  healing: number
  message: string
  created_at: string
}

export function BattleTurnLog({
  turns,
  compact = false,
}: {
  turns: BattleTurnLogEntry[]
  compact?: boolean
}) {
  if (turns.length === 0) {
    return <p className="muted">Для этого боя подробный журнал ходов не сохранился.</p>
  }

  return (
    <div className={'battle-turn-log' + (compact ? ' compact' : '')}>
      {turns.map((turn) => (
        <article className={'battle-turn-row' + (turn.damage > 0 ? ' dealt-damage' : '')} key={turn.id}>
          <div className="battle-turn-head">
            <span>
              {turn.room != null ? `Зал ${turn.room} · ` : ''}
              Раунд {turn.round}
            </span>
            <strong>{turn.action_name}</strong>
          </div>

          <div className="battle-turn-route">
            <b>{turn.actor_name}</b>
            {turn.target_name && (
              <>
                <span aria-hidden="true">→</span>
                <b>{turn.target_name}</b>
              </>
            )}
            {turn.damage > 0 && <em className="battle-turn-damage">-{turn.damage} ОЗ</em>}
            {turn.healing > 0 && <em className="battle-turn-healing">+{turn.healing} ОЗ</em>}
          </div>

          <p>{turn.message}</p>
        </article>
      ))}
    </div>
  )
}
