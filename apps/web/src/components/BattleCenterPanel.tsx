import { userFacingError } from '../lib/userError'
import { lazy, Suspense, useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useSmartRefresh } from '../lib/smartRefresh'

const AdventuresPanel = lazy(() => import('./AdventuresPanel').then((module) => ({ default: module.AdventuresPanel })))
const PartyPanel = lazy(() => import('./PartyPanel').then((module) => ({ default: module.PartyPanel })))
const PartyDungeonPanel = lazy(() => import('./PartyDungeonPanel').then((module) => ({ default: module.PartyDungeonPanel })))
const DuelPanel = lazy(() => import('./DuelPanel').then((module) => ({ default: module.DuelPanel })))

type Props = {
  characterId: string
  onProgressChanged?: () => Promise<unknown> | void
  onInventoryChanged?: () => Promise<unknown> | void
}

type BattleKind = 'solo' | 'party' | 'pvp'
type BattleTab = 'current' | 'group' | 'history' | 'duels'

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

type BattleLootItem = {
  item_definition_id: string | null
  name: string
  slug: string | null
  rarity: string | null
  quantity: number
  source_type: string | null
}

type BattleConsumableUsage = {
  item_definition_id: string | null
  name: string
  slug: string | null
  quantity: number
  usage_kind: string
}

type BattleReward = {
  tracked: boolean
  gold: number | null
  experience: number | null
  loot: BattleLootItem[]
}

type BattleEconomyDetail = {
  reward: BattleReward
  consumables: BattleConsumableUsage[]
  consumables_complete: boolean
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
  reward?: BattleReward
  consumables?: BattleConsumableUsage[]
  consumables_complete?: boolean
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
  const [heldFinishedKind, setHeldFinishedKind] = useState<BattleKind | null>(null)
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
      if (!silent) setMessage(userFacingError(error.message))
      if (!silent) setLoading(false)
      return
    }

    const nextOverview = (data as BattleOverview | null) ?? emptyOverview
    setOverview(nextOverview)

    if (
      tab === 'current'
      && (nextOverview.active_kind === 'solo' || nextOverview.active_kind === 'party')
    ) {
      setHeldFinishedKind(nextOverview.active_kind)
    }

    if (!silent) setLoading(false)
  }

  async function loadHistory() {
    setHistoryLoading(true)
    const { data, error } = await supabase.rpc('get_battle_history', {
      p_character_id: characterId,
      p_limit: 50,
    })

    if (error) {
      setMessage(userFacingError(error.message))
      setHistory([])
    } else {
      setHistory((data as BattleHistoryEntry[] | null) ?? [])
    }
    setHistoryLoading(false)
  }

  async function openDetail(entry: BattleHistoryEntry) {
    setDetailLoading(true)
    setSelected(null)

    const [detailResult, economyResult] = await Promise.all([
      supabase.rpc('get_battle_history_detail', {
        p_character_id: characterId,
        p_kind: entry.kind,
        p_battle_id: entry.battle_id,
      }),
      supabase.rpc('get_battle_history_economy', {
        p_character_id: characterId,
        p_kind: entry.kind,
        p_battle_id: entry.battle_id,
      }),
    ])

    if (detailResult.error) {
      setMessage(userFacingError(detailResult.error.message))
    } else if (economyResult.error) {
      setMessage(userFacingError(economyResult.error.message))
    } else {
      const detail = (detailResult.data as BattleDetail | null) ?? null
      const economy = (economyResult.data as BattleEconomyDetail | null) ?? null
      setSelected(detail && economy ? { ...detail, ...economy } : detail)
    }
    setDetailLoading(false)
  }

  useEffect(() => {
    setHeldFinishedKind(null)
  }, [characterId])

  useEffect(() => {
    if (tab === 'current' || tab === 'group') {
      void loadOverview()
    }
  }, [tab, characterId])

  useEffect(() => {
    if (tab !== 'current') setHeldFinishedKind(null)
  }, [tab])

  useSmartRefresh(
    () => loadOverview(true),
    {
      enabled: tab === 'current' || tab === 'group',
      intervalMs: overview.active_kind ? 6000 : 0,
      minGapMs: 1200,
    },
  )

  useEffect(() => {
    if (tab === 'history') void loadHistory()
  }, [tab, characterId])

  const pastBattles = useMemo(
    () => history.filter((entry) => entry.status !== 'active'),
    [history],
  )
  const currentKind = overview.active_kind ?? heldFinishedKind
  const showingFinishedResult = !overview.active_kind && heldFinishedKind !== null

  return (
    <section className="battle-center-section">
      <article className="panel battle-center-header">
        <div>
          <span className="eyebrow">БОЕВОЙ ЦЕНТР</span>
          <h2>Бои</h2>
          <p className="muted">
            Текущая битва, группа, кооперативные походы, история прохождений и дуэли теперь собраны в одном месте.
          </p>
        </div>
        <div className={'battle-live-indicator ' + (overview.active_kind ? 'active' : showingFinishedResult ? 'result' : '')}>
          <strong>{overview.active_kind ? 'LIVE' : showingFinishedResult ? 'ИТОГ' : '—'}</strong>
          <span>
            {overview.active_kind
              ? kindLabels[overview.active_kind]
              : showingFinishedResult && currentKind
                ? kindLabels[currentKind] + ' · завершён'
                : 'нет активного боя'}
          </span>
        </div>
      </article>

      <div className="battle-center-tabs" role="tablist" aria-label="Разделы боевого центра">
        <button className={tab === 'current' ? 'active' : ''} type="button" onClick={() => setTab('current')}>
          Сейчас
          {currentKind && <b>{overview.active_kind ? '1' : 'ИТОГ'}</b>}
        </button>
        <button className={tab === 'group' ? 'active' : ''} type="button" onClick={() => setTab('group')}>
          Группа
          {overview.party_active && <b>LIVE</b>}
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
          ) : !currentKind ? (
            <article className="panel battle-center-empty">
              <span className="eyebrow">СЕЙЧАС</span>
              <h3>Активного боя нет</h3>
              <p className="muted">
                Выбери подземелье в «Приключения → Места» или на карте. После входа всё прохождение автоматически остаётся здесь до победы, поражения или выхода.
              </p>
            </article>
          ) : (
            <Suspense fallback={<LoadingBattle />}>
              {currentKind === 'solo' && (
                <AdventuresPanel
                  characterId={characterId}
                  mode="battles"
                  onProgressChanged={onProgressChanged}
                  onInventoryChanged={onInventoryChanged}
                />
              )}
              {currentKind === 'party' && (
                <PartyDungeonPanel
                  characterId={characterId}
                  mode="combat"
                  onProgressChanged={onProgressChanged}
                  onInventoryChanged={onInventoryChanged}
                />
              )}
              {currentKind === 'pvp' && <DuelPanel characterId={characterId} />}
            </Suspense>
          )}
        </>
      )}

      {tab === 'group' && (
        <Suspense fallback={<LoadingBattle />}>
          <div className="battle-group-section">
            <PartyPanel characterId={characterId} />
            <PartyDungeonPanel
              characterId={characterId}
              mode="management"
              onOpenBattles={() => {
                void loadOverview().finally(() => setTab('current'))
              }}
              onProgressChanged={onProgressChanged}
              onInventoryChanged={onInventoryChanged}
            />
          </div>
        </Suspense>
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
            <p className="battle-history-retention-note">
              Хранятся 50 последних завершённых боёв. Более старые записи автоматически удаляются.
            </p>

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

                <div className="battle-history-economy">
                  <div className="battle-economy-card">
                    <div className="battle-economy-heading">
                      <span>НАГРАДА</span>
                      <strong>Итог боя</strong>
                    </div>

                    {selected.reward?.tracked === false ? (
                      <p className="battle-old-snapshot">
                        Для этого старого группового боя точная сумма золота и опыта ещё не сохранялась.
                      </p>
                    ) : (
                      <>
                        <div className="battle-reward-stats">
                          <span><b>{selected.reward?.gold ?? 0}</b> золота</span>
                          <span><b>{selected.reward?.experience ?? 0}</b> опыта</span>
                        </div>

                        {(selected.reward?.loot?.length ?? 0) > 0 ? (
                          <div className="battle-loot-list">
                            {selected.reward!.loot.map((item, index) => (
                              <div
                                className={'battle-loot-item ' + (item.rarity ? 'rarity-' + item.rarity : '')}
                                key={(item.item_definition_id ?? item.slug ?? item.name) + ':' + index}
                              >
                                <span>{item.name}</span>
                                <b>×{item.quantity}</b>
                              </div>
                            ))}
                          </div>
                        ) : (
                          <small className="battle-economy-empty">Лут не получен.</small>
                        )}
                      </>
                    )}
                  </div>

                  <div className="battle-economy-card">
                    <div className="battle-economy-heading">
                      <span>ПОТРАЧЕНО</span>
                      <strong>Расходники</strong>
                    </div>

                    {(selected.consumables?.length ?? 0) > 0 ? (
                      <div className="battle-consumable-list">
                        {selected.consumables!.map((item, index) => (
                          <div className="battle-consumable-item" key={(item.item_definition_id ?? item.slug ?? item.name) + ':' + index}>
                            <span>{item.name}</span>
                            <b>×{item.quantity}</b>
                          </div>
                        ))}
                      </div>
                    ) : (
                      <small className="battle-economy-empty">Расходники не использовались.</small>
                    )}

                    {selected.consumables_complete === false && (
                      <p className="battle-history-legacy-note">
                        Старый бой: расходники восстановлены по журналу ходов, поэтому траты между залами могли не сохраниться.
                      </p>
                    )}
                  </div>
                </div>

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
