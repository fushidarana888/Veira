import { lazy, Suspense, useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'

const AdventuresPanel = lazy(() => import('./AdventuresPanel').then((module) => ({ default: module.AdventuresPanel })))
const PartyDungeonPanel = lazy(() => import('./PartyDungeonPanel').then((module) => ({ default: module.PartyDungeonPanel })))
const DuelPanel = lazy(() => import('./DuelPanel').then((module) => ({ default: module.DuelPanel })))

type Props = {
  characterId: string
  onProgressChanged?: () => Promise<unknown> | void
  onInventoryChanged?: () => Promise<unknown> | void
}

type BattleKind = 'solo' | 'party' | 'pvp'
type BattleTab = 'current' | 'history' | 'duels'

type BattleOverview = {
  active_kind: BattleKind | null
  solo_active: boolean
  party_active: boolean
  pvp_active: boolean
  history_count: number
}

type BattleHistoryEntry = {
  battle_id: string
  kind: BattleKind
  title: string
  status: string
  started_at: string
  ended_at: string | null
  sort_at: string
  sector_id: number | null
  rooms_cleared: number
  total_rooms: number
  participant_count: number
  total_damage: number
  final_hp: number | null
  final_hp_max: number | null
}

type BattleEquipment = {
  slot: string
  name: string
  base_name: string
  rarity: string
  enhancement_level: number
  awakening_level: number
  weapon_family: string | null
  affixes: Array<{ name?: string }>
}

type BattleParticipant = {
  character_id: string
  name: string
  damage: number
  healing?: number
  final_hp: number | null
  hp_max: number | null
  dead?: boolean
  lost?: boolean
  equipment: BattleEquipment[] | null
}

type BattleEncounterSummary = {
  id: string
  room: number
  enemy: string
  status: string
  rounds: number
  is_boss: boolean
  ended_at: string | null
}

type BattleDetail = {
  battle_id: string
  kind: BattleKind
  title: string
  status: string
  started_at: string
  ended_at: string | null
  rooms_cleared?: number
  total_rooms?: number
  winner_character_id?: string | null
  participants: BattleParticipant[]
  encounters?: BattleEncounterSummary[]
  unattributed_effect_damage?: number
}

const emptyOverview: BattleOverview = {
  active_kind: null,
  solo_active: false,
  party_active: false,
  pvp_active: false,
  history_count: 0,
}

const kindLabels: Record<BattleKind, string> = {
  solo: 'Соло',
  party: 'Группа',
  pvp: 'Дуэль',
}

const statusLabels: Record<string, string> = {
  active: 'идёт сейчас',
  completed: 'победа',
  victory: 'победа',
  defeat: 'поражение',
  abandoned: 'прерван',
  cancelled: 'отменён',
  declined: 'отклонён',
}

const slotLabels: Record<string, string> = {
  weapon: 'Оружие',
  offhand: 'Вторая рука',
  head: 'Голова',
  chest: 'Корпус',
  hands: 'Руки',
  legs: 'Ноги',
  feet: 'Обувь',
  accessory_1: 'Аксессуар I',
  accessory_2: 'Аксессуар II',
}

function formatDate(value: string | null) {
  if (!value) return 'сейчас'
  return new Intl.DateTimeFormat('ru-RU', {
    day: '2-digit',
    month: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  }).format(new Date(value))
}

function LoadingBattle() {
  return (
    <article className="panel battle-center-loading">
      <span className="eyebrow">БОИ</span>
      <h3>Загружаем поле боя…</h3>
    </article>
  )
}

export function BattleCenterPanel({
  characterId,
  onProgressChanged,
  onInventoryChanged,
}: Props) {
  const [tab, setTab] = useState<BattleTab>('current')
  const [overview, setOverview] = useState<BattleOverview>(emptyOverview)
  const [history, setHistory] = useState<BattleHistoryEntry[]>([])
  const [selected, setSelected] = useState<BattleDetail | null>(null)
  const [loading, setLoading] = useState(true)
  const [historyLoading, setHistoryLoading] = useState(false)
  const [detailLoading, setDetailLoading] = useState(false)
  const [message, setMessage] = useState('')

  async function loadOverview(silent = false) {
    if (!silent) setLoading(true)
    const { data, error } = await supabase.rpc('get_battle_center_overview', {
      p_character_id: characterId,
    })

    if (error) {
      if (!silent) setMessage(error.message)
      if (!silent) setLoading(false)
      return
    }

    setOverview((data as BattleOverview | null) ?? emptyOverview)
    if (!silent) setLoading(false)
  }

  async function loadHistory() {
    setHistoryLoading(true)
    const { data, error } = await supabase.rpc('get_battle_history', {
      p_character_id: characterId,
      p_limit: 40,
    })

    if (error) {
      setMessage(error.message)
      setHistory([])
    } else {
      setHistory((data as BattleHistoryEntry[] | null) ?? [])
    }
    setHistoryLoading(false)
  }

  async function openDetail(entry: BattleHistoryEntry) {
    setDetailLoading(true)
    setSelected(null)

    const { data, error } = await supabase.rpc('get_battle_history_detail', {
      p_character_id: characterId,
      p_kind: entry.kind,
      p_battle_id: entry.battle_id,
    })

    if (error) {
      setMessage(error.message)
    } else {
      setSelected((data as BattleDetail | null) ?? null)
    }
    setDetailLoading(false)
  }

  useEffect(() => {
    void loadOverview()
  }, [characterId])

  useEffect(() => {
    if (tab !== 'current') return

    const timer = window.setInterval(() => {
      if (document.visibilityState === 'visible') void loadOverview(true)
    }, 8000)

    return () => window.clearInterval(timer)
  }, [characterId, tab])

  useEffect(() => {
    if (tab === 'history' && history.length === 0) void loadHistory()
  }, [tab, characterId])

  const pastBattles = useMemo(
    () => history.filter((entry) => entry.status !== 'active'),
    [history],
  )

  return (
    <section className="battle-center-section">
      <article className="panel battle-center-header">
        <div>
          <span className="eyebrow">БОЕВОЙ ЦЕНТР</span>
          <h2>Бои</h2>
          <p className="muted">
            Текущая битва, подробная история прохождений и дуэли теперь собраны в одном месте.
          </p>
        </div>
        <div className={'battle-live-indicator ' + (overview.active_kind ? 'active' : '')}>
          <strong>{overview.active_kind ? 'LIVE' : '—'}</strong>
          <span>{overview.active_kind ? kindLabels[overview.active_kind] : 'нет активного боя'}</span>
        </div>
      </article>

      <div className="battle-center-tabs" role="tablist" aria-label="Разделы боевого центра">
        <button className={tab === 'current' ? 'active' : ''} type="button" onClick={() => setTab('current')}>
          Сейчас
          {overview.active_kind && <b>1</b>}
        </button>
        <button className={tab === 'history' ? 'active' : ''} type="button" onClick={() => setTab('history')}>
          История
          {overview.history_count > 0 && <b>{overview.history_count}</b>}
        </button>
        <button className={tab === 'duels' ? 'active' : ''} type="button" onClick={() => setTab('duels')}>
          Дуэли
        </button>
      </div>

      {message && <p className="gm-notice" aria-live="polite">{message}</p>}

      {tab === 'current' && (
        <>
          {loading ? (
            <LoadingBattle />
          ) : !overview.active_kind ? (
            <article className="panel battle-center-empty">
              <span className="eyebrow">СЕЙЧАС</span>
              <h3>Активного боя нет</h3>
              <p className="muted">
                Войти в подземелье или собрать групповой поход можно через «Приключения». Когда начинается битва, она появляется здесь.
              </p>
            </article>
          ) : (
            <Suspense fallback={<LoadingBattle />}>
              {overview.active_kind === 'solo' && (
                <AdventuresPanel
                  characterId={characterId}
                  mode="battles"
                  onProgressChanged={onProgressChanged}
                  onInventoryChanged={onInventoryChanged}
                />
              )}
              {overview.active_kind === 'party' && (
                <PartyDungeonPanel
                  characterId={characterId}
                  mode="combat"
                  onProgressChanged={onProgressChanged}
                  onInventoryChanged={onInventoryChanged}
                />
              )}
              {overview.active_kind === 'pvp' && <DuelPanel characterId={characterId} />}
            </Suspense>
          )}
        </>
      )}

      {tab === 'history' && (
        <div className="battle-history-layout">
          <article className="panel battle-history-list">
            <div className="section-heading">
              <div>
                <span className="eyebrow">АРХИВ</span>
                <h3>Прошлые бои</h3>
              </div>
              <button className="ghost-button" type="button" disabled={historyLoading} onClick={() => void loadHistory()}>
                Обновить
              </button>
            </div>

            {historyLoading && pastBattles.length === 0 && <p className="muted">Загружаем историю…</p>}
            {!historyLoading && pastBattles.length === 0 && <p className="muted">Завершённых боёв пока нет.</p>}

            <div className="battle-history-cards">
              {pastBattles.map((entry) => (
                <button
                  type="button"
                  className={'battle-history-card ' + (selected?.battle_id === entry.battle_id ? 'selected' : '')}
                  key={entry.kind + ':' + entry.battle_id}
                  onClick={() => void openDetail(entry)}
                >
                  <div>
                    <span>{kindLabels[entry.kind]} · {formatDate(entry.ended_at ?? entry.started_at)}</span>
                    <strong>{entry.title}</strong>
                    <small>
                      {entry.kind !== 'pvp' ? entry.rooms_cleared + '/' + entry.total_rooms + ' залов · ' : ''}
                      {entry.participant_count} уч. · {entry.total_damage} урона
                    </small>
                  </div>
                  <b>{statusLabels[entry.status] ?? entry.status}</b>
                </button>
              ))}
            </div>
          </article>

          <article className="panel battle-history-detail">
            {detailLoading ? (
              <p className="muted">Собираем статистику боя…</p>
            ) : !selected ? (
              <>
                <span className="eyebrow">ПОДРОБНОСТИ</span>
                <h3>Выбери бой слева</h3>
                <p className="muted">Здесь будут участники, урон, итоговое ОЗ и экипировка на момент начала боя.</p>
              </>
            ) : (
              <>
                <div className="section-heading">
                  <div>
                    <span className="eyebrow">{kindLabels[selected.kind]} · {statusLabels[selected.status] ?? selected.status}</span>
                    <h3>{selected.title}</h3>
                    <p className="muted">{formatDate(selected.started_at)} → {formatDate(selected.ended_at)}</p>
                  </div>
                </div>

                <div className="battle-participant-list">
                  {selected.participants.map((participant) => {
                    const hpPercent = participant.hp_max && participant.final_hp != null
                      ? Math.max(0, Math.min(100, Math.round(participant.final_hp * 100 / Math.max(1, participant.hp_max))))
                      : null

                    return (
                      <div className="battle-participant-card" key={participant.character_id}>
                        <div className="battle-participant-head">
                          <div>
                            <strong>{participant.name}</strong>
                            <span>{participant.damage} урона{participant.healing ? ' · ' + participant.healing + ' лечения' : ''}</span>
                          </div>
                          <b>
                            {participant.final_hp == null || participant.hp_max == null
                              ? 'ОЗ —'
                              : participant.final_hp + ' / ' + participant.hp_max + ' ОЗ'}
                          </b>
                        </div>

                        {hpPercent != null && (
                          <div className="combat-hp-meter player"><span style={{ width: hpPercent + '%' }} /></div>
                        )}

                        {participant.lost && <span className="battle-state-chip lost">Потерян</span>}
                        {participant.dead && !participant.lost && <span className="battle-state-chip dead">Выведен из строя</span>}

                        {participant.equipment === null ? (
                          <p className="battle-old-snapshot">
                            Этот бой был сыгран до появления исторических снимков экипировки.
                          </p>
                        ) : participant.equipment.length === 0 ? (
                          <p className="battle-old-snapshot">На момент боя экипировка не была надета.</p>
                        ) : (
                          <div className="battle-equipment-grid">
                            {participant.equipment.map((item) => (
                              <div className={'battle-equipment-item rarity-' + item.rarity} key={item.slot}>
                                <span>{slotLabels[item.slot] ?? item.slot}</span>
                                <strong>{item.name}</strong>
                                <small>
                                  {item.enhancement_level > 0 ? '+' + item.enhancement_level : ''}
                                  {item.awakening_level > 0 ? (item.enhancement_level > 0 ? ' · ' : '') + 'Пробуждение ' + item.awakening_level : ''}
                                  {item.affixes?.length > 0
                                    ? ((item.enhancement_level > 0 || item.awakening_level > 0) ? ' · ' : '') + item.affixes.map((affix) => affix.name).filter(Boolean).join(', ')
                                    : ''}
                                </small>
                              </div>
                            ))}
                          </div>
                        )}
                      </div>
                    )
                  })}
                </div>

                {(selected.unattributed_effect_damage ?? 0) > 0 && (
                  <p className="battle-effect-damage">
                    Общий урон эффектов группы без однозначного автора: <b>{selected.unattributed_effect_damage}</b>
                  </p>
                )}

                {(selected.encounters?.length ?? 0) > 0 && (
                  <div className="battle-encounter-list">
                    <strong>Ход прохождения</strong>
                    {selected.encounters!.map((encounter) => (
                      <span key={encounter.id}>
                        Зал {encounter.room} · {encounter.enemy} · {encounter.rounds} раунд.
                        {encounter.is_boss ? ' · хранитель' : ''}
                      </span>
                    ))}
                  </div>
                )}
              </>
            )}
          </article>
        </div>
      )}

      {tab === 'duels' && (
        <Suspense fallback={<LoadingBattle />}>
          <DuelPanel characterId={characterId} />
        </Suspense>
      )}
    </section>
  )
}
