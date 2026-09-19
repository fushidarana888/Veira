import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { BowDistance, BowProfile } from '../types'

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
  sacrifice_scroll_used: boolean
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
  enemy_bloodshed_stacks: number
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
  dead: boolean
  lost: boolean
  lost_reason: string | null
  incoming_damage_reduction_percent: number
  incoming_damage_reduction_rounds: number
  guard_percent: number
  damage_bonus_percent: number
  damage_bonus_hits: number
  taunt_chance: number
  bow_distance: BowDistance
  bow_draw_pending: boolean
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

type PartySpell = {
  id: string
  slug: string
  name: string
  description: string
  spell_kind: 'damage' | 'heal' | 'guard' | 'cleanse' | 'buff' | 'taunt'
  damage_type: string | null
  mana_cost: number
  required_level: number
  power_multiplier: number
  flat_power: number
  learned_at: string
  source: string
}

type PartyStatus = {
  id: number
  target_type: 'enemy' | 'member'
  target_character_id: string | null
  effect_type: 'burn' | 'bleed' | 'poison' | 'stun' | 'chill' | 'weaken' | 'vulnerable'
  potency: number
  remaining_turns: number
  source: string
}

type PartyDungeonState = {
  run: PartyRun | null
  encounter: PartyEncounter | null
  members: PartyCombatMember[]
  statuses: PartyStatus[]
  turns: PartyTurn[]
  loot: PartyLoot[]
  sacrifice_scroll_count: number
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
  statuses: [],
  turns: [],
  loot: [],
  sacrifice_scroll_count: 0,
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

const statusLabels: Record<PartyStatus['effect_type'], string> = {
  burn: 'Ожог',
  bleed: 'Кровотечение',
  poison: 'Яд',
  stun: 'Оглушение',
  chill: 'Охлаждение',
  weaken: 'Ослабление',
  vulnerable: 'Уязвимость',
}

function statusDetail(status: PartyStatus) {
  if (status.effect_type === 'stun') return status.remaining_turns + ' ход.'
  if (['burn', 'bleed', 'poison'].includes(status.effect_type)) {
    return status.potency + ' урона · ' + status.remaining_turns + ' ход.'
  }
  return status.potency + '% · ' + status.remaining_turns + ' ход.'
}

function coopError(raw: string) {
  if (raw.includes('PARTY_NEEDS_TWO_MEMBERS')) return 'Для группового похода нужно минимум 2 персонажа.'
  if (raw.includes('PARTY_DUNGEON_NOT_AVAILABLE_TO_ALL')) return 'Не у всех участников открыт и разведан этот вход.'
  if (raw.includes('PARTY_MEMBER_BUSY')) return 'Один из участников занят другой тяжёлой активностью. Группа пока не может войти.'
  if (raw.includes('PARTY_DUNGEON_ALREADY_ACTIVE')) return 'У этой группы уже идёт совместный поход.'
  if (raw.includes('PARTY_LEADER_REQUIRED')) return 'Начинать зал и принимать решение о побеге может только лидер группы.'
  if (raw.includes('PARTY_ACTION_ALREADY_USED_THIS_ROUND')) return 'Ты уже сделал действие в этом раунде. Ждём остальных участников.'
  if (raw.includes('PARTY_MEMBER_DOWNED')) return 'Персонаж мёртв и не может действовать, пока его не воскресят.'
  if (raw.includes('PARTY_TARGET_LOST')) return 'Потерянного персонажа нельзя воскресить или выбрать целью поддержки до конца этого боя.'
  if (raw.includes('SACRIFICE_ALREADY_USED_THIS_RUN')) return '«Последняя жертва» уже была использована в этом бою-походе.'
  if (raw.includes('SACRIFICE_REQUIRES_OVER_200_HP')) return 'Для «Последней жертвы» нужно больше 200 текущего HP.'
  if (raw.includes('SACRIFICE_SCROLL_NOT_AVAILABLE')) return 'Боевого свитка «Последняя жертва» больше нет в инвентаре.'
  if (raw.includes('SACRIFICE_NO_LIVING_ALLIES')) return 'Нет живых союзников, которых этот свиток мог бы спасти.'
  if (raw.includes('PARTY_NO_ACTIVE_MEMBERS')) return 'В отряде не осталось персонажей, способных продолжать бой.'
  if (raw.includes('PARTY_ESCAPE_ALREADY_ATTEMPTED_THIS_STAGE')) return 'Попытка побега на этом этапе уже использована.'
  if (raw.includes('PARTY_COMBAT_ALREADY_ACTIVE')) return 'Битва в этом зале уже идёт.'
  if (raw.includes('PARTY_ROOM_COMBAT_ALREADY_EXISTS')) return 'Этот зал уже был разыгран.'
  if (raw.includes('PARTY_DUNGEON_ACTIVE')) return 'Сначала заверши текущий групповой поход.'
  if (raw.includes('NOT_ENOUGH_MANA')) return 'Недостаточно маны для этого заклинания.'
  if (raw.includes('SPELL_NOT_LEARNED')) return 'Это заклинание не изучено персонажем.'
  if (raw.includes('ALREADY_FULL_HEALTH')) return 'У выбранного союзника уже полное здоровье.'
  if (raw.includes('PARTY_TARGET_DOWNED')) return 'На мёртвого союзника сейчас можно применить только лечение-воскрешение.'
  if (raw.includes('PARTY_MEMBER_STUNNED')) return 'Персонаж оглушён. В этом раунде действие будет пропущено.'
  if (raw.includes('BOW_FULL_DRAW_LOCKED')) return 'Полный натяг уже подготовлен: следующий доступный ход обязан быть выстрелом.'
  if (raw.includes('BOW_DISTANCE_LOCKED')) return 'Во время полного натяга дистанцию менять нельзя.'
  if (raw.includes('PARTY_MEMBER_NOT_STUNNED')) return 'Оглушение уже прошло.'
  if (raw.includes('PARTY_SPELL_NOT_SUPPORTED')) return 'Это заклинание пока не поддерживается в групповом бою.'
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
  const [spells, setSpells] = useState<PartySpell[]>([])
  const [bowProfile, setBowProfile] = useState<BowProfile | null>(null)
  const [spellTargets, setSpellTargets] = useState<Record<string, string>>({})
  const [selectedSectorId, setSelectedSectorId] = useState<number | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  async function loadState(silent = false) {
    if (!silent) setLoading(true)

    const [partyResult, optionResult, dungeonResult, spellResult, bowProfileResult] = await Promise.all([
      supabase.rpc('get_party_overview', {
        p_character_id: characterId,
      }),
      supabase.rpc('get_party_dungeon_options', {
        p_character_id: characterId,
      }),
      supabase.rpc('get_party_dungeon_state', {
        p_character_id: characterId,
      }),
      supabase.rpc('get_character_spells', {
        p_character_id: characterId,
      }),
      supabase.rpc('get_character_bow_profile', {
        p_character_id: characterId,
      }),
    ])

    const error = partyResult.error ?? optionResult.error ?? dungeonResult.error ?? spellResult.error ?? bowProfileResult.error
    if (error) {
      if (!silent) setMessage(coopError(error.message))
      if (!silent) setLoading(false)
      return
    }

    const overview = (partyResult.data as PartyOverview | null)
    const nextOptions = (optionResult.data as DungeonOption[] | null) ?? []
    const rawState = (dungeonResult.data as Partial<PartyDungeonState> | null) ?? {}
    const nextState: PartyDungeonState = {
      ...emptyState,
      ...rawState,
      members: Array.isArray(rawState.members) ? rawState.members : [],
      statuses: Array.isArray(rawState.statuses) ? rawState.statuses : [],
      turns: Array.isArray(rawState.turns) ? rawState.turns : [],
      loot: Array.isArray(rawState.loot) ? rawState.loot : [],
      sacrifice_scroll_count: Number(rawState.sacrifice_scroll_count ?? 0),
    }

    setParty(overview?.party ?? null)
    setOptions(nextOptions)
    setState(nextState)
    setSpells(
      ((spellResult.data as PartySpell[] | null) ?? [])
        .filter((spell) => ['damage', 'heal', 'guard', 'cleanse', 'buff', 'taunt'].includes(spell.spell_kind)),
    )
    setBowProfile((bowProfileResult.data as BowProfile | null) ?? null)

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
    setMessage('Битва началась. Каждый живой участник получает одно действие в раунде.')
    setBusy(false)
  }

  async function performAction(action: 'physical' | 'bow_draw' | 'magic' | 'guard') {
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
          : 'Битва завершена. Зал очищен, лидер может открыть следующий.',
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

  async function setBowDistance(distance: BowDistance) {
    if (!state.encounter || !me || !bowProfile?.weapon_family || me.bow_draw_pending || me.acted) return
    setBusy(true)
    setMessage('')
    const { error } = await supabase.rpc('set_party_bow_distance', {
      p_character_id: characterId,
      p_encounter_id: state.encounter.id,
      p_distance: distance,
    })
    if (error) setMessage(coopError(error.message))
    await loadState(true)
    setBusy(false)
  }

  async function castPartySpell(spell: PartySpell) {
    if (!state.encounter) return

    const support = spell.spell_kind !== 'damage'
    const targetId = support
      ? spellTargets[spell.id] ?? characterId
      : null

    setBusy(true)
    setMessage('')

    const { data, error } = await supabase.rpc('cast_party_character_spell', {
      p_character_id: characterId,
      p_encounter_id: state.encounter.id,
      p_spell_id: spell.id,
      p_target_character_id: targetId,
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
          ? 'Заклинание добивает хранителя. Групповой поход завершён победой.'
          : 'Заклинание завершает битву. Зал очищен.',
      )
    } else if (result?.status === 'defeat') {
      setMessage('После хода противника вся группа выведена из строя.')
    } else if (result?.enemy_acted) {
      setMessage('Заклинание применено. Все участники походили, поэтому противник ответил.')
    } else {
      setMessage('Заклинание применено. Ждём ходы остальных участников.')
    }

    setBusy(false)
  }

  async function useLastSacrificeScroll() {
    if (!state.encounter || !state.run || !me) return

    if (!window.confirm(
      'Использовать «Последнюю жертву»? Ты станешь Потерянным до конца всего похода и не сможешь быть воскрешён. Все остальные ЖИВЫЕ союзники полностью восстановят HP и получат −30% входящего урона на 3 раунда. Свиток исчезнет.',
    )) return

    setBusy(true)
    setMessage('Свиток требует последней жертвы…')

    const { data, error } = await supabase.rpc('use_party_sacrifice_scroll', {
      p_character_id: characterId,
      p_encounter_id: state.encounter.id,
    })

    if (error) {
      setMessage(coopError(error.message))
      setBusy(false)
      await loadState(true)
      return
    }

    const result = data as { status?: string; run_status?: string; enemy_acted?: boolean } | null
    await Promise.all([loadState(true), refreshPlayer()])

    if (result?.status === 'defeat') {
      setMessage('Последняя жертва была принесена, но оставшиеся участники погибли. Бой завершён поражением.')
    } else if (result?.enemy_acted) {
      setMessage('Последняя жертва принесена. Союзники исцелены и защищены; противник завершил раунд атакой.')
    } else {
      setMessage('Последняя жертва принесена. Ты Потерян до конца похода; живые союзники полностью исцелены и защищены на 3 раунда.')
    }

    setBusy(false)
  }

  async function skipStunnedTurn() {
    if (!state.encounter) return

    setBusy(true)
    setMessage('Оглушение не даёт действовать…')

    const { data, error } = await supabase.rpc('skip_party_stunned_turn', {
      p_character_id: characterId,
      p_encounter_id: state.encounter.id,
    })

    if (error) {
      setMessage(coopError(error.message))
      setBusy(false)
      await loadState(true)
      return
    }

    const result = data as { status?: string; enemy_acted?: boolean; enemy_stunned?: boolean } | null
    await Promise.all([loadState(true), refreshPlayer()])

    if (result?.status === 'defeat') {
      setMessage('После пропущенного хода группа потерпела поражение.')
    } else if (result?.enemy_stunned) {
      setMessage('Ты пропускаешь ход из-за оглушения, но противник тоже оглушён и не атакует.')
    } else if (result?.enemy_acted) {
      setMessage('Ты пропускаешь ход из-за оглушения. После действий группы противник атакует.')
    } else {
      setMessage('Ход пропущен из-за оглушения. Ждём остальных участников.')
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
  const myStatuses = state.statuses.filter(
    (status) => status.target_type === 'member' && status.target_character_id === characterId,
  )
  const enemyStatuses = state.statuses.filter((status) => status.target_type === 'enemy')
  const meStunned = myStatuses.some((status) => status.effect_type === 'stun')
  const isLeader = Boolean(party && party.leader_character_id === characterId)
  const canStartGroup = Boolean(party && party.member_count >= 2)
  const canAct = Boolean(
    activeEncounter
    && me
    && !me.downed
    && !me.lost
    && !me.acted
    && !meStunned
    && !busy,
  )
  const canSkipStun = Boolean(
    activeEncounter
    && me
    && !me.downed
    && !me.lost
    && !me.acted
    && meStunned
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
            Бой — весь поход по подземелью. Битва — отдельный зал. За раунд каждый живой герой делает одно действие, затем противник отвечает.
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
                  member.lost ? 'lost' : member.dead ? 'dead' : '',
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
                    {member.lost
                      ? 'потерян'
                      : member.dead
                        ? 'мёртв'
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

                {member.lost && (
                  <small className="party-buff-state">
                    Потерян до конца текущего боя-похода · воскресить нельзя
                  </small>
                )}
                {member.incoming_damage_reduction_rounds > 0 && member.incoming_damage_reduction_percent > 0 && !member.lost && (
                  <small className="party-buff-state">
                    Благословение жертвы · −{member.incoming_damage_reduction_percent}% входящего урона · {member.incoming_damage_reduction_rounds} раунд.
                  </small>
                )}
                {member.guard_percent > 0 && (
                  <small className="party-guard-state">Защита −{member.guard_percent}% следующего удара</small>
                )}
                {member.damage_bonus_hits > 0 && member.damage_bonus_percent > 0 && (
                  <small className="party-buff-state">
                    Боевой фокус +{member.damage_bonus_percent}% · атак {member.damage_bonus_hits}
                  </small>
                )}
                {member.taunt_chance > 0 && !member.downed && !member.lost && (
                  <small className="party-buff-state">
                    Провокация · {member.taunt_chance}% шанс стать целью
                  </small>
                )}
                {state.statuses.some(
                  (status) => status.target_type === 'member' && status.target_character_id === member.character_id,
                ) && (
                  <div className="party-status-list member">
                    {state.statuses
                      .filter((status) => status.target_type === 'member' && status.target_character_id === member.character_id)
                      .map((status) => (
                        <span className={'party-status-chip ' + status.effect_type} key={status.id}>
                          {statusLabels[status.effect_type]} · {statusDetail(status)}
                        </span>
                      ))}
                  </div>
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
                    disabled={busy || escapeLocked || Boolean(me?.bow_draw_pending)}
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
                {enemyStatuses.length > 0 && (
                  <div className="party-status-list enemy">
                    {enemyStatuses.map((status) => (
                      <span className={'party-status-chip ' + status.effect_type} key={status.id}>
                        {statusLabels[status.effect_type]} · {statusDetail(status)}
                      </span>
                    ))}
                  </div>
                )}
              </div>

              <div className="party-turn-status">
                {me?.downed
                  ? 'Ты выведен из строя. Союзник с лечащим заклинанием может вернуть тебя в бой.'
                  : me?.acted
                    ? 'Твоё действие принято. Ждём остальных живых участников.'
                    : meStunned
                      ? 'Ты оглушён и не можешь действовать в этом раунде.'
                      : 'Твой ход в этом раунде.'}
              </div>

              {bowProfile?.weapon_family && me && (
                <div className="party-turn-status">
                  <strong>Дистанция:</strong>{' '}
                  {([
                    ['close', 'Ближняя · +10% урон · +3% dodge'],
                    ['medium', 'Средняя · +9% dodge'],
                    ['far', 'Дальняя · −10% урон · +15% dodge'],
                  ] as Array<[BowDistance, string]>).map(([distance, label]) => (
                    <button
                      className={me.bow_distance === distance ? 'primary-button' : 'ghost-button'}
                      type="button"
                      key={distance}
                      disabled={!canAct || me.bow_draw_pending}
                      onClick={() => void setBowDistance(distance)}
                    >
                      {label}
                    </button>
                  ))}
                  {me.bow_draw_pending && <span> · Натяг подготовлен, дистанция зафиксирована.</span>}
                  {(activeEncounter.enemy_bloodshed_stacks ?? 0) > 0 && (
                    <span> · Кровопролитие на враге: {activeEncounter.enemy_bloodshed_stacks}</span>
                  )}
                </div>
              )}

              <div className="party-combat-actions">
                {bowProfile?.weapon_family ? (
                  me?.bow_draw_pending ? (
                    <button className="primary-button" type="button" disabled={!canAct} onClick={() => void performAction('physical')}>
                      Выпустить стрелу · полный натяг
                    </button>
                  ) : (
                    <>
                      {bowProfile.weapon_family === 'short_bow' && (
                        <button className="primary-button" type="button" disabled={!canAct} onClick={() => void performAction('physical')}>
                          Быстрый выстрел
                        </button>
                      )}
                      <button className="primary-button" type="button" disabled={!canAct} onClick={() => void performAction('bow_draw')}>
                        Полный натяг · пробитие {bowProfile.full_draw_armor_penetration_percent}%
                      </button>
                    </>
                  )
                ) : (
                  <button
                    className="primary-button"
                    type="button"
                    disabled={!canAct}
                    onClick={() => void performAction('physical')}
                  >
                    Физическая атака
                  </button>
                )}
                <button
                  className="primary-button"
                  type="button"
                  disabled={!canAct || Boolean(me?.bow_draw_pending)}
                  onClick={() => void performAction('magic')}
                >
                  Врождённая магия
                </button>
                <button
                  className="ghost-button"
                  type="button"
                  disabled={!canAct || Boolean(me?.bow_draw_pending)}
                  onClick={() => void performAction('guard')}
                >
                  Защита
                </button>

                {canSkipStun && (
                  <button
                    className="ghost-button stunned-skip-button"
                    type="button"
                    disabled={busy}
                    onClick={() => void skipStunnedTurn()}
                  >
                    Пропустить ход · оглушение
                  </button>
                )}

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

              {state.sacrifice_scroll_count > 0 && (
                <div className="party-spell-section party-sacrifice-section">
                  <div className="party-subheading">
                    <strong>Редкий боевой свиток</strong>
                    <span>одноразовый · только 1 раз за весь бой</span>
                  </div>
                  <div className="party-spell-grid">
                    <div className="party-spell-card sacrifice">
                      <div>
                        <strong>Последняя жертва</strong>
                        <span>×{state.sacrifice_scroll_count} · требует &gt;200 текущего HP</span>
                      </div>
                      <p className="muted">
                        Ты становишься Потерянным до конца похода. Все остальные живые союзники полностью лечатся и получают −30% входящего урона на 3 раунда. Мёртвых не воскрешает.
                      </p>
                      <button
                        className="danger-button"
                        type="button"
                        disabled={
                          !canAct
                          || Boolean(me?.bow_draw_pending)
                          || state.run?.sacrifice_scroll_used
                          || (me?.hp_current ?? 0) <= 200
                        }
                        title={
                          state.run?.sacrifice_scroll_used
                            ? 'Этот эффект уже использован в текущем бою-походе.'
                            : (me?.hp_current ?? 0) <= 200
                              ? 'Нужно больше 200 текущего HP.'
                              : 'Необратимо исключает твоего персонажа до конца текущего похода.'
                        }
                        onClick={() => void useLastSacrificeScroll()}
                      >
                        {state.run?.sacrifice_scroll_used
                          ? 'Уже использовано в этом бою'
                          : (me?.hp_current ?? 0) <= 200
                            ? 'Нужно >200 HP'
                            : 'Принести последнюю жертву'}
                      </button>
                    </div>
                  </div>
                </div>
              )}

              {spells.length > 0 && (
                <div className="party-spell-section">
                  <div className="party-subheading">
                    <strong>Изученные заклинания</strong>
                    <span>каждое занимает твой ход</span>
                  </div>

                  <div className="party-spell-grid">
                    {spells.map((spell) => {
                      const support = spell.spell_kind !== 'damage'
                      const targetId = spellTargets[spell.id] ?? characterId
                      const target = state.members.find((member) => member.character_id === targetId) ?? me
                      const noMana = (me?.mana_current ?? 0) < spell.mana_cost
                      const targetInvalid = Boolean(
                        support
                        && target
                        && (
                          target.lost
                          || (target.downed && spell.spell_kind !== 'heal')
                        ),
                      )
                      const fullHeal = Boolean(
                        spell.spell_kind === 'heal'
                        && target
                        && !target.downed
                        && !target.lost
                        && target.hp_current >= target.hp_max,
                      )

                      return (
                        <div className={'party-spell-card ' + spell.spell_kind} key={spell.id}>
                          <div>
                            <strong>{spell.name}</strong>
                            <span>
                              {spell.spell_kind === 'damage'
                                ? (damageLabels[spell.damage_type ?? ''] ?? spell.damage_type ?? 'магия')
                                : spell.spell_kind === 'heal'
                                  ? 'лечение / поднятие'
                                  : spell.spell_kind === 'guard'
                                    ? 'щит союзника'
                                    : spell.spell_kind === 'cleanse'
                                      ? 'очищение'
                                      : spell.spell_kind === 'taunt'
                                        ? 'провокация союзника'
                                        : 'усиление урона'}
                              {' · '}{spell.mana_cost} MP
                            </span>
                          </div>

                          {support && (
                            <select
                              value={targetId}
                              disabled={!canAct || Boolean(me?.bow_draw_pending)}
                              onChange={(event) => setSpellTargets((current) => ({
                                ...current,
                                [spell.id]: event.target.value,
                              }))}
                            >
                              {state.members.map((member) => (
                                <option
                                  key={member.character_id}
                                  value={member.character_id}
                                  disabled={member.lost || (member.downed && spell.spell_kind !== 'heal')}
                                >
                                  {member.name}
                                  {member.character_id === characterId ? ' · ты' : ''}
                                  {member.lost ? ' · потерян' : member.dead ? ' · мёртв' : ''}
                                </option>
                              ))}
                            </select>
                          )}

                          <button
                            className={spell.spell_kind === 'damage' ? 'primary-button' : 'ghost-button'}
                            type="button"
                            disabled={!canAct || Boolean(me?.bow_draw_pending) || noMana || targetInvalid || fullHeal}
                            onClick={() => void castPartySpell(spell)}
                          >
                            {noMana
                              ? 'Не хватает маны'
                              : fullHeal
                                ? 'HP полное'
                                : spell.spell_kind === 'damage'
                                  ? 'Применить'
                                  : 'На выбранного'}
                          </button>
                        </div>
                      )
                    })}
                  </div>
                </div>
              )}

              <small className="party-coop-note">
                Мёртвого союзника можно воскресить лечением; Потерянного — нельзя до конца всего похода. Щит и Боевой фокус можно направлять на товарищей. «Провокация» действует до смерти цели или конца текущей битвы. Ожог, кровотечение, яд, оглушение, охлаждение, ослабление и уязвимость работают в групповой битве; «Очищение» снимает негативные эффекты с выбранного участника.
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
