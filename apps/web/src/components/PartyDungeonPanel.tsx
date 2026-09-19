import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'

type PartySummary = {
  id: string
  leader_character_id: string
  member_count: number
  created_at: string
}

type PartyOverview = {
  party: PartySummary | null
  members: unknown[]
  incoming_invites: unknown[]
  outgoing_invites: unknown[]
}

type DungeonOption = {
  sector_id: number
  title: string
  danger_level: number
  terrain_type: string
}

type PartyRun = {
  id: string
  party_id: string
  leader_character_id: string
  sector_id: number
  title: string
  danger_level: number
  status: 'active' | 'completed' | 'abandoned'
  current_stage: string
  rooms_cleared: number
  total_rooms: number
  reward_gold: number
  reward_experience: number
  member_count: number
  escape_attempt_stage: number | null
  started_at: string
}

type PartyEncounter = {
  id: string
  room_index: number
  is_boss: boolean
  status: 'active' | 'victory' | 'defeat' | 'cancelled'
  round: number
  enemy_name: string
  enemy_level: number
  enemy_hp_current: number
  enemy_hp_max: number
  enemy_attack: number
  enemy_defense: number
  enemy_damage_type: string
  acted_character_ids: string[]
  created_at: string
  ended_at: string | null
}

type PartyCombatMember = {
  character_id: string
  name: string
  display_name: string
  race: string
  level: number
  hp_current: number
  hp_max: number
  mana_current: number
  mana_max: number
  downed: boolean
  guard_percent: number
  acted: boolean
  is_leader: boolean
  joined_order: number
}

type PartyTurn = {
  id: number
  round: number
  actor_type: 'player' | 'enemy' | 'system'
  actor_character_id: string | null
  target_character_id: string | null
  action_type: string
  damage: number
  message: string
  created_at: string
}

type PartyLoot = {
  id: string
  source_type: 'enemy' | 'boss' | 'dungeon'
  item_definition_id: string
  item_name: string
  rarity: string
  quantity: number
  created_at: string
}

type PartyDungeonState = {
  run: PartyRun | null
  encounter: PartyEncounter | null
  members: PartyCombatMember[]
  turns: PartyTurn[]
  loot: PartyLoot[]
}

type Props = {
  characterId: string
  onProgressChanged?: () => Promise<unknown> | void
  onInventoryChanged?: () => Promise<unknown> | void
}

const emptyState: PartyDungeonState = {
  run: null,
  encounter: null,
  members: [],
  turns: [],
  loot: [],
}

const damageLabels: Record<string, string> = {
  slashing: 'режущий',
  piercing: 'колющий',
  blunt: 'дробящий',
  fire: 'огонь',
  water: 'вода',
  earth: 'земля',
  air: 'воздух',
  lightning: 'молния',
  ice: 'лёд',
}

const terrainLabels: Record<string, string> = {
  plains: 'равнины',
  forest: 'лес',
  swamp: 'болота',
  desert: 'пустыня',
  mountains: 'горы',
  tundra: 'тундра',
  coast: 'побережье',
  sea: 'море',
  riverlands: 'речные земли',
}

function coopError(raw: string) {
  if (raw.includes('PARTY_NEEDS_TWO_MEMBERS')) return 'Для группового похода нужно минимум 2 персонажа.'
  if (raw.includes('PARTY_DUNGEON_NOT_AVAILABLE_TO_ALL')) return 'Не у всех участников открыт и разведан этот вход.'
  if (raw.includes('PARTY_MEMBER_BUSY')) return 'Один из участников занят другой тяжёлой активностью. Группа пока не может войти.'
  if (raw.includes('PARTY_DUNGEON_ALREADY_ACTIVE')) return 'У этой группы уже идёт совместный поход.'
  if (raw.includes('PARTY_LEADER_REQUIRED')) return 'Начинать зал и принимать решение о побеге может только лидер группы.'
  if (raw.includes('PARTY_ACTION_ALREADY_USED_THIS_ROUND')) return 'Ты уже сделал действие в этом раунде. Ждём остальных участников.'
  if (raw.includes('PARTY_MEMBER_DOWNED')) return 'Персонаж выведен из строя до конца этого боя.'
  if (raw.includes('PARTY_ESCAPE_ALREADY_ATTEMPTED_THIS_STAGE')) return 'Попытка побега на этом этапе уже использована.'
  if (raw.includes('PARTY_COMBAT_ALREADY_ACTIVE')) return 'Бой в этом зале уже идёт.'
  if (raw.includes('PARTY_ROOM_COMBAT_ALREADY_EXISTS')) return 'Этот зал уже был разыгран.'
  if (raw.includes('PARTY_DUNGEON_ACTIVE')) return 'Сначала заверши текущий групповой поход.'
  return raw
}

function hpPercent(current: number, max: number) {
  if (max <= 0) return 0
  return Math.max(0, Math.min(100, Math.round(current / max * 100)))
}

export function PartyDungeonPanel({
  characterId,
  onProgressChanged,
  onInventoryChanged,
}: Props) {
  const [party, setParty] = useState<PartySummary | null>(null)
  const [options, setOptions] = useState<DungeonOption[]>([])
  const [state, setState] = useState<PartyDungeonState>(emptyState)
  const [selectedSectorId, setSelectedSectorId] = useState<number | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  async function loadState(silent = false) {
    if (!silent) setLoading(true)

    const [partyResult, optionResult, dungeonResult] = await Promise.all([
      supabase.rpc('get_party_overview', {
        p_character_id: characterId,
      }),
      supabase.rpc('get_party_dungeon_options', {
        p_character_id: characterId,
      }),
      supabase.rpc('get_party_dungeon_state', {
        p_character_id: characterId,
      }),
    ])

    const error = partyResult.error ?? optionResult.error ?? dungeonResult.error
    if (error) {
      if (!silent) setMessage(coopError(error.message))
      if (!silent) setLoading(false)
      return
    }

    const overview = (partyResult.data as PartyOverview | null)
    const nextOptions = (optionResult.data as DungeonOption[] | null) ?? []
    const nextState = (dungeonResult.data as PartyDungeonState | null) ?? emptyState

    setParty(overview?.party ?? null)
    setOptions(nextOptions)
    setState(nextState)

    if (
      selectedSectorId == null
      || !nextOptions.some((entry) => entry.sector_id === selectedSectorId)
    ) {
      setSelectedSectorId(nextOptions[0]?.sector_id ?? null)
    }

    if (!silent) setLoading(false)
  }

  useEffect(() => {
    void loadState()

    const timer = window.setInterval(() => {
      void loadState(true)
    }, 3500)

    return () => window.clearInterval(timer)
  }, [characterId])

  async function refreshPlayer() {
    await Promise.all([
      Promise.resolve(onProgressChanged?.()),
      Promise.resolve(onInventoryChanged?.()),
    ])
  }

  async function startRun() {
    if (!selectedSectorId) return

    setBusy(true)
    setMessage('Собираем группу у входа…')

    const { error } = await supabase.rpc('start_party_dungeon_run', {
      p_character_id: characterId,
      p_sector_id: selectedSectorId,
    })

    if (error) {
      setMessage(coopError(error.message))
      setBusy(false)
      return
    }

    await Promise.all([loadState(true), refreshPlayer()])
    setMessage('Группа вошла в подземелье. Лидер может открыть первый зал.')
    setBusy(false)
  }

  async function startRoom() {
    if (!state.run) return

    setBusy(true)
    setMessage('Открываем следующий зал…')

    const { error } = await supabase.rpc('start_party_dungeon_combat', {
      p_character_id: characterId,
      p_run_id: state.run.id,
    })

    if (error) {
      setMessage(coopError(error.message))
      setBusy(false)
      return
    }

    await Promise.all([loadState(true), refreshPlayer()])
    setMessage('Бой начался. Каждый живой участник получает одно действие в раунде.')
    setBusy(false)
  }

  async function performAction(action: 'physical' | 'magic' | 'guard') {
    if (!state.encounter) return

    setBusy(true)
    setMessage('')

    const { data, error } = await supabase.rpc('perform_party_combat_action', {
      p_character_id: characterId,
      p_encounter_id: state.encounter.id,
      p_action: action,
    })

    if (error) {
      setMessage(coopError(error.message))
      setBusy(false)
      await loadState(true)
      return
    }

    const result = data as { status?: string; run_status?: string; enemy_acted?: boolean } | null

    await Promise.all([loadState(true), refreshPlayer()])

    if (result?.status === 'victory') {
      setMessage(
        result.run_status === 'completed'
          ? 'Хранитель повержен. Группа полностью зачистила подземелье.'
          : 'Зал очищен. Лидер может открыть следующий.',
      )
    } else if (result?.status === 'defeat') {
      setMessage('Вся группа выведена из строя. Поход завершён поражением.')
    } else if (result?.enemy_acted) {
      setMessage('Раунд завершён: после действий группы противник ответил атакой.')
    } else {
      setMessage('Ход принят. Ждём остальных участников группы.')
    }

    setBusy(false)
  }

  async function attemptEscape() {
    if (!state.run) return

    if (!window.confirm(
      'Попытаться вывести всю группу из подземелья? Шанс успеха — 80%. При провале HP ВСЕХ участников упадёт до 1, а повторить побег на этом этапе нельзя.',
    )) return

    setBusy(true)
    setMessage('Группа пытается отступить…')

    const { data, error } = await supabase.rpc('attempt_leave_party_dungeon_run', {
      p_character_id: characterId,
      p_run_id: state.run.id,
    })

    if (error) {
      setMessage(coopError(error.message))
      setBusy(false)
      await loadState(true)
      return
    }

    const result = data as { escaped?: boolean; message?: string } | null
    await Promise.all([loadState(true), refreshPlayer()])

    setMessage(
      result?.escaped
        ? 'Групповой побег удался. Отряд покинул подземелье.'
        : 'Побег провален. Все участники остаются внутри с 1 HP.',
    )
    setBusy(false)
  }

  const run = state.run
  const encounter = state.encounter
  const activeRun = run?.status === 'active' ? run : null
  const activeEncounter = activeRun && encounter?.status === 'active' ? encounter : null
  const me = state.members.find((member) => member.character_id === characterId) ?? null
  const isLeader = Boolean(party && party.leader_character_id === characterId)
  const canStartGroup = Boolean(party && party.member_count >= 2)
  const canAct = Boolean(
    activeEncounter
    && me
    && !me.downed
    && !me.acted
    && !busy,
  )
  const escapeLocked = Boolean(
    activeRun
    && activeRun.escape_attempt_stage != null
    && activeRun.escape_attempt_stage === activeRun.rooms_cleared,
  )
  const nextRoom = activeRun
    ? Math.min(activeRun.total_rooms, activeRun.rooms_cleared + 1)
    : 0

  const orderedTurns = useMemo(
    () => [...state.turns].reverse(),
    [state.turns],
  )

  if (loading) {
    return (
      <article className="panel party-dungeon-panel">
        <span className="eyebrow">КООПЕРАТИВНЫЙ ДАНЖ</span>
        <h3>Проверяем состояние отряда…</h3>
      </article>
    )
  }

  if (!party) return null

  return (
    <article className="panel party-dungeon-panel">
      <div className="section-heading">
        <div>
          <span className="eyebrow">КООПЕРАТИВ · 2–4 ИГРОКА</span>
          <h2>{activeRun ? activeRun.title : 'Групповой поход'}</h2>
          <p className="muted">
            Каждый участник управляет своим персонажем. За раунд каждый живой герой делает одно действие, затем противник отвечает.
          </p>
        </div>
        <span className="badge">
          {activeRun ? activeRun.member_count + ' в походе' : party.member_count + ' / 4'}
        </span>
      </div>

      {message && <p className="form-message" aria-live="polite">{message}</p>}

      {!activeRun && (
        <>
          {run && run.status !== 'active' && (
            <div className={'party-dungeon-last-result ' + run.status}>
              <div>
                <strong>
                  {run.status === 'completed' ? 'Последний поход завершён' : 'Последний поход прерван'}
                </strong>
                <span>
                  {run.title} · залов {run.rooms_cleared}/{run.total_rooms}
                </span>
              </div>
              <span className="badge">
                {run.status === 'completed' ? 'зачищено' : 'покинуто'}
              </span>
            </div>
          )}

          {!canStartGroup ? (
            <div className="party-dungeon-empty">
              <strong>Нужен хотя бы ещё один участник</strong>
              <p className="muted">
                Когда в группе будет 2–4 персонажа, здесь появятся подземелья, которые открыты и разведаны у всех участников.
              </p>
            </div>
          ) : options.length === 0 ? (
            <div className="party-dungeon-empty">
              <strong>Нет общего разведанного подземелья</strong>
              <p className="muted">
                Для совместного входа один и тот же данж должен быть открыт и разведан каждым участником группы.
              </p>
            </div>
          ) : (
            <div className="party-dungeon-start">
              <label>
                <span>Общий вход</span>
                <select
                  value={selectedSectorId ?? ''}
                  disabled={busy || !isLeader}
                  onChange={(event) => setSelectedSectorId(Number(event.target.value))}
                >
                  {options.map((option) => (
                    <option key={option.sector_id} value={option.sector_id}>
                      {option.title} · опасность {option.danger_level}/10 · {terrainLabels[option.terrain_type] ?? option.terrain_type}
                    </option>
                  ))}
                </select>
              </label>

              {isLeader ? (
                <button
                  className="primary-button"
                  type="button"
                  disabled={busy || !selectedSectorId}
                  onClick={() => void startRun()}
                >
                  {busy ? 'Собираем группу…' : 'Начать групповой поход'}
                </button>
              ) : (
                <div className="party-dungeon-waiting">
                  Лидер выбирает подземелье и запускает поход.
                </div>
              )}
            </div>
          )}
        </>
      )}

      {activeRun && (
        <>
          <div className="party-dungeon-progress">
            <div>
              <span>Пройдено залов</span>
              <strong>{activeRun.rooms_cleared} / {activeRun.total_rooms}</strong>
            </div>
            <div className="party-dungeon-progress-meter">
              <span style={{
                width: activeRun.total_rooms > 0
                  ? Math.round(activeRun.rooms_cleared / activeRun.total_rooms * 100) + '%'
                  : '0%',
              }} />
            </div>
            <div className="party-dungeon-reward">
              <span>Каждому за полную зачистку</span>
              <strong>{activeRun.reward_gold} золота · {activeRun.reward_experience} опыта</strong>
            </div>
          </div>

          <div className="party-combat-members">
            {state.members.map((member) => (
              <div
                className={[
                  'party-combat-member',
                  member.character_id === characterId ? 'self' : '',
                  member.downed ? 'downed' : '',
                ].filter(Boolean).join(' ')}
                key={member.character_id}
              >
                <div className="party-combat-member-head">
                  <div>
                    <strong>{member.name}</strong>
                    <span>
                      @{member.display_name} · LVL {member.level}
                      {member.character_id === characterId ? ' · ты' : ''}
                    </span>
                  </div>
                  <span className="badge">
                    {member.downed
                      ? 'выведен'
                      : activeEncounter && member.acted
                        ? 'походил'
                        : member.is_leader
                          ? 'лидер'
                          : 'готов'}
                  </span>
                </div>

                <div className="party-resource-row">
                  <span>HP {member.hp_current}/{member.hp_max}</span>
                  <div className="party-resource-meter hp">
                    <span style={{ width: hpPercent(member.hp_current, member.hp_max) + '%' }} />
                  </div>
                </div>
                <div className="party-resource-row">
                  <span>MP {member.mana_current}/{member.mana_max}</span>
                  <div className="party-resource-meter mana">
                    <span style={{ width: hpPercent(member.mana_current, member.mana_max) + '%' }} />
                  </div>
                </div>

                {member.guard_percent > 0 && (
                  <small className="party-guard-state">Защита −{member.guard_percent}% следующего удара</small>
                )}
              </div>
            ))}
          </div>

          {!activeEncounter ? (
            <div className="party-dungeon-between-rooms">
              <div>
                <span className="eyebrow">СЛЕДУЮЩИЙ ЭТАП</span>
                <strong>
                  {nextRoom === activeRun.total_rooms
                    ? 'Финальный зал · хранитель'
                    : 'Зал ' + nextRoom + ' из ' + activeRun.total_rooms}
                </strong>
                <p className="muted">
                  HP и мана сохраняются между залами. После победы можно немного подождать пассивного восстановления или идти дальше.
                </p>
              </div>

              <div className="party-dungeon-actions">
                {isLeader ? (
                  <button className="primary-button" type="button" disabled={busy} onClick={() => void startRoom()}>
                    {nextRoom === activeRun.total_rooms ? 'Войти к хранителю' : 'Открыть зал ' + nextRoom}
                  </button>
                ) : (
                  <span className="party-dungeon-waiting">Ждём, когда лидер откроет следующий зал.</span>
                )}

                {isLeader && (
                  <button
                    className="ghost-button danger-button"
                    type="button"
                    disabled={busy || escapeLocked}
                    title={escapeLocked
                      ? 'Попытка побега на этом этапе уже использована.'
                      : '80% успеха. При провале HP всей группы станет 1.'}
                    onClick={() => void attemptEscape()}
                  >
                    {escapeLocked ? 'Побег уже использован' : 'Групповой побег · 80%'}
                  </button>
                )}
              </div>
            </div>
          ) : (
            <div className="party-combat-shell">
              <div className="party-enemy-card">
                <div className="party-enemy-head">
                  <div>
                    <span className="eyebrow">
                      {activeEncounter.is_boss ? 'ХРАНИТЕЛЬ' : 'ПРОТИВНИК'} · РАУНД {activeEncounter.round}
                    </span>
                    <h3>{activeEncounter.enemy_name}</h3>
                    <p className="muted">
                      LVL {activeEncounter.enemy_level} · атака: {damageLabels[activeEncounter.enemy_damage_type] ?? activeEncounter.enemy_damage_type}
                    </p>
                  </div>
                  <strong>{activeEncounter.enemy_hp_current} / {activeEncounter.enemy_hp_max} HP</strong>
                </div>
                <div className="party-enemy-hp-meter">
                  <span style={{ width: hpPercent(activeEncounter.enemy_hp_current, activeEncounter.enemy_hp_max) + '%' }} />
                </div>
              </div>

              <div className="party-turn-status">
                {me?.downed
                  ? 'Ты выведен из строя до конца этого боя. Наблюдай за товарищами.'
                  : me?.acted
                    ? 'Твоё действие принято. Ждём остальных живых участников.'
                    : 'Твой ход в этом раунде.'}
              </div>

              <div className="party-combat-actions">
                <button
                  className="primary-button"
                  type="button"
                  disabled={!canAct}
                  onClick={() => void performAction('physical')}
                >
                  Физическая атака
                </button>
                <button
                  className="primary-button"
                  type="button"
                  disabled={!canAct}
                  onClick={() => void performAction('magic')}
                >
                  Врождённая магия
                </button>
                <button
                  className="ghost-button"
                  type="button"
                  disabled={!canAct}
                  onClick={() => void performAction('guard')}
                >
                  Защита
                </button>

                {isLeader && (
                  <button
                    className="ghost-button danger-button"
                    type="button"
                    disabled={busy || escapeLocked}
                    onClick={() => void attemptEscape()}
                  >
                    {escapeLocked ? 'Побег недоступен' : 'Групповой побег · 80%'}
                  </button>
                )}
              </div>

              <small className="party-coop-note">
                Первая версия кооп-боя использует физическую атаку, врождённую магию и защиту. Заклинания, лечение союзников и полноценные роли пати добавим следующим слоем.
              </small>

              <div className="party-combat-log">
                {orderedTurns.map((turn) => (
                  <div className={'party-combat-log-row ' + turn.actor_type} key={turn.id}>
                    <span>
                      {turn.actor_type === 'player'
                        ? 'Игрок'
                        : turn.actor_type === 'enemy'
                          ? 'Враг'
                          : 'Система'}
                    </span>
                    <p>{turn.message}</p>
                  </div>
                ))}
              </div>
            </div>
          )}

          {state.loot.length > 0 && (
            <div className="party-personal-loot">
              <div className="party-subheading">
                <strong>Твоя личная добыча</strong>
                <span>уже в инвентаре</span>
              </div>
              <div className="party-personal-loot-grid">
                {state.loot.map((drop) => (
                  <div className={'party-loot-item rarity-' + drop.rarity} key={drop.id}>
                    <div>
                      <strong>{drop.item_name}</strong>
                      <span>
                        {drop.source_type === 'dungeon'
                          ? 'финальный тайник'
                          : drop.source_type === 'boss'
                            ? 'хранитель'
                            : 'враг'}
                      </span>
                    </div>
                    <b>×{drop.quantity}</b>
                  </div>
                ))}
              </div>
            </div>
          )}
        </>
      )}

      {!activeRun && run?.status === 'completed' && state.loot.length > 0 && (
        <div className="party-personal-loot">
          <div className="party-subheading">
            <strong>Добыча последнего группового похода</strong>
            <span>личная</span>
          </div>
          <div className="party-personal-loot-grid">
            {state.loot.map((drop) => (
              <div className={'party-loot-item rarity-' + drop.rarity} key={drop.id}>
                <strong>{drop.item_name}</strong>
                <b>×{drop.quantity}</b>
              </div>
            ))}
          </div>
        </div>
      )}
    </article>
  )
}
