import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useSmartRefresh } from '../lib/smartRefresh'
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
  is_event_boss: boolean
  event_boss_id: string | null
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
  reward_exhausted: boolean
  reward_attempt_number: number | null
  reward_cycle_ends_at: string | null
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
  combat_slot: number | null
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

function isBowProfile(profile: BowProfile | null | undefined): profile is BowProfile & { weapon_family: 'short_bow' | 'long_bow' } {
  return profile?.weapon_family === 'short_bow' || profile?.weapon_family === 'long_bow'
}

type Props = {
  characterId: string
  mode?: 'all' | 'management' | 'combat'
  onOpenBattles?: () => void
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
  arcane: 'аркана',
  star: 'звёзды',
  gravity: 'гравитация',
  moon: 'луна',
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
  if (raw.includes('SACRIFICE_REQUIRES_OVER_200_HP')) return 'Для «Последней жертвы» нужно больше 200 текущего ОЗ.'
  if (raw.includes('SACRIFICE_SCROLL_NOT_AVAILABLE')) return 'Боевого свитка «Последняя жертва» больше нет в инвентаре.'
  if (raw.includes('SACRIFICE_NO_LIVING_ALLIES')) return 'Нет живых союзников, которых этот свиток мог бы спасти.'
  if (raw.includes('PARTY_NO_ACTIVE_MEMBERS')) return 'В отряде не осталось персонажей, способных продолжать бой.'
  if (raw.includes('PARTY_ESCAPE_ALREADY_ATTEMPTED_THIS_STAGE')) return 'Попытка побега на этом этапе уже использована.'
  if (raw.includes('PARTY_COMBAT_ALREADY_ACTIVE')) return 'Битва в этом зале уже идёт.'
  if (raw.includes('PARTY_ROOM_COMBAT_ALREADY_EXISTS')) return 'Этот зал уже был разыгран.'
  if (raw.includes('PARTY_DUNGEON_ACTIVE')) return 'Сначала заверши текущий групповой поход.'
  if (raw.includes('NOT_ENOUGH_MANA')) return 'Недостаточно маны для этого заклинания.'
  if (raw.includes('SPELL_NOT_IN_LOADOUT')) return 'Это заклинание не входит в текущий боевой набор.'
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

function dungeonZeroExperience(level: number) {
  if (level <= 1) return 15
  if (level === 2) return 11
  if (level === 3) return 6
  if (level === 4) return 2
  return 1
}

function dungeonRecommendedLevel(danger: number) {
  if (danger <= 0) return 1
  return danger * 2 + 2
}

function dungeonRewardMultiplier(danger: number, level: number, kind: 'xp' | 'gold') {
  if (danger <= 0) return 100
  const over = level - dungeonRecommendedLevel(danger)
  if (over <= 0) return 100
  if (kind === 'xp') {
    if (over === 1) return 75
    if (over === 2) return 50
    if (over === 3) return 25
    if (over === 4) return 10
    return 5
  }
  if (over === 1) return 90
  if (over === 2) return 75
  if (over === 3) return 60
  if (over === 4) return 50
  return 35
}

function scaledPartyDungeonReward(base: number, danger: number, level: number, kind: 'xp' | 'gold') {
  if (danger === 0) return kind === 'xp' ? dungeonZeroExperience(level) : 40
  return Math.max(1, Math.round(base * dungeonRewardMultiplier(danger, level, kind) / 100))
}

export function PartyDungeonPanel({
  characterId,
  mode = 'all',
  onOpenBattles,
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

  function normalizeState(raw: Partial<PartyDungeonState> | null): PartyDungeonState {
    const value = raw ?? {}
    return {
      run: value.run ?? null,
      encounter: value.encounter ?? null,
      members: Array.isArray(value.members) ? value.members : [],
      statuses: Array.isArray(value.statuses) ? value.statuses : [],
      turns: Array.isArray(value.turns) ? value.turns : [],
      loot: Array.isArray(value.loot) ? value.loot : [],
      sacrifice_scroll_count: Number(value.sacrifice_scroll_count ?? 0),
    }
  }

  async function loadStaticCombatData() {
    const [spellResult, bowProfileResult] = await Promise.all([
      supabase.rpc('get_character_spells', {
        p_character_id: characterId,
      }),
      supabase.rpc('get_character_bow_profile', {
        p_character_id: characterId,
      }),
    ])

    const error = spellResult.error ?? bowProfileResult.error
    if (error) {
      setMessage(coopError(error.message))
      return
    }

    setSpells(
      ((spellResult.data as PartySpell[] | null) ?? [])
        .filter((spell) => spell.combat_slot !== null && ['damage', 'heal', 'guard', 'cleanse', 'buff', 'taunt'].includes(spell.spell_kind)),
    )
    setBowProfile((bowProfileResult.data as BowProfile | null) ?? null)
  }

  async function loadDynamicState(silent = false) {
    if (!silent) setLoading(true)

    const dungeonPromise = supabase.rpc('get_party_dungeon_state', {
      p_character_id: characterId,
    })

    if (mode === 'combat') {
      const dungeonResult = await dungeonPromise
      if (dungeonResult.error) {
        if (!silent) setMessage(coopError(dungeonResult.error.message))
        if (!silent) setLoading(false)
        return
      }

      setState(normalizeState(dungeonResult.data as Partial<PartyDungeonState> | null))
      if (!silent) setLoading(false)
      return
    }

    const [partyResult, optionResult, dungeonResult] = await Promise.all([
      supabase.rpc('get_party_overview', {
        p_character_id: characterId,
      }),
      supabase.rpc('get_party_dungeon_options', {
        p_character_id: characterId,
      }),
      dungeonPromise,
    ])

    const error = partyResult.error ?? optionResult.error ?? dungeonResult.error
    if (error) {
      if (!silent) setMessage(coopError(error.message))
      if (!silent) setLoading(false)
      return
    }

    const overview = partyResult.data as PartyOverview | null
    const nextOptions = (optionResult.data as DungeonOption[] | null) ?? []

    setParty(overview?.party ?? null)
    setOptions(nextOptions)
    setState(normalizeState(dungeonResult.data as Partial<PartyDungeonState> | null))

    if (
      selectedSectorId == null
      || !nextOptions.some((entry) => entry.sector_id === selectedSectorId)
    ) {
      setSelectedSectorId(nextOptions[0]?.sector_id ?? null)
    }

    if (!silent) setLoading(false)
  }

  useEffect(() => {
    setLoading(true)
    void Promise.all([
      mode === 'management' ? Promise.resolve() : loadStaticCombatData(),
      loadDynamicState(true),
    ]).finally(() => setLoading(false))
  }, [characterId, mode])

  useSmartRefresh(
    () => loadDynamicState(true),
    {
      enabled: true,
      intervalMs: state.run?.status === 'active'
        ? (mode === 'combat' ? 3000 : 10000)
        : 0,
      minGapMs: mode === 'combat' ? 800 : 1500,
    },
  )

  async function refreshPlayer(includeInventory = false) {
    await Promise.all([
      Promise.resolve(onProgressChanged?.()),
      includeInventory ? Promise.resolve(onInventoryChanged?.()) : Promise.resolve(),
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

    await loadDynamicState(true)
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

    await loadDynamicState(true)
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
      await loadDynamicState(true)
      return
    }

    const result = data as { status?: string; run_status?: string; enemy_acted?: boolean } | null

    await Promise.all([
      loadDynamicState(true),
      refreshPlayer(result?.status === 'victory' || result?.status === 'defeat'),
    ])

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
    if (!state.encounter || !me || !isBowProfile(bowProfile) || me.bow_draw_pending || me.acted) return
    setBusy(true)
    setMessage('')
    const { error } = await supabase.rpc('set_party_bow_distance', {
      p_character_id: characterId,
      p_encounter_id: state.encounter.id,
      p_distance: distance,
    })
    if (error) setMessage(coopError(error.message))
    await loadDynamicState(true)
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
      await loadDynamicState(true)
      return
    }

    const result = data as { status?: string; run_status?: string; enemy_acted?: boolean } | null
    await Promise.all([
      loadDynamicState(true),
      refreshPlayer(result?.status === 'victory' || result?.status === 'defeat'),
    ])

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
      'Использовать «Последнюю жертву»? Ты станешь Потерянным до конца всего похода и не сможешь быть воскрешён. Все остальные ЖИВЫЕ союзники полностью восстановят ОЗ и получат −30% входящего урона на 3 раунда. Свиток исчезнет.',
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
      await loadDynamicState(true)
      return
    }

    const result = data as { status?: string; run_status?: string; enemy_acted?: boolean } | null
    await Promise.all([
      loadDynamicState(true),
      refreshPlayer(true),
    ])

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
      await loadDynamicState(true)
      return
    }

    const result = data as { status?: string; enemy_acted?: boolean; enemy_stunned?: boolean } | null
    await Promise.all([
      loadDynamicState(true),
      refreshPlayer(result?.status === 'victory' || result?.status === 'defeat'),
    ])

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

  async function abandonEventBossParty() {
    if (!window.confirm('Отступить всей группой от Пепельного Кузнеца? Текущая попытка завершится без награды.')) return

    setBusy(true)
    setMessage('Группа отступает от недельного босса…')

    const { error } = await supabase.rpc('abandon_event_boss', {
      p_character_id: characterId,
      p_mode: 'party',
    })

    if (error) {
      setMessage(coopError(error.message))
      setBusy(false)
      return
    }

    await Promise.all([
      loadDynamicState(true),
      Promise.resolve(onProgressChanged?.()),
    ])
    setMessage('Группа отступила. До конца ротации Пепельного Кузнеца можно вызвать снова.')
    setBusy(false)
  }

  async function attemptEscape() {
    if (!state.run) return

    if (!window.confirm(
      'Попытаться вывести всю группу из подземелья? Шанс успеха — 80%. При провале ОЗ ВСЕХ участников упадёт до 1, а повторить побег на этом этапе нельзя.',
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
      await loadDynamicState(true)
      return
    }

    const result = data as { escaped?: boolean; message?: string } | null
    await Promise.all([loadDynamicState(true), refreshPlayer(false)])

    setMessage(
      result?.escaped
        ? 'Групповой побег удался. Отряд покинул подземелье.'
        : 'Побег провален. Все участники остаются внутри с 1 ОЗ.',
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

  if (mode === 'management' && state.encounter?.status === 'active') {
    return (
      <article className="panel party-dungeon-panel battle-moved-panel">
        <span className="eyebrow">ГРУППОВОЙ БОЙ ИДЁТ</span>
        <h3>{state.encounter.enemy_name}</h3>
        <p className="muted">
          Управление текущей битвой перенесено в нижний раздел «Бои». Состав группы и сам поход остаются в «Приключениях».
        </p>
        <button className="primary-button" type="button" onClick={onOpenBattles}>
          Открыть групповой бой
        </button>
      </article>
    )
  }

  if (mode === 'combat' && state.encounter?.status !== 'active') return null

  return (
    <article className="panel party-dungeon-panel">
      <div className="section-heading">
        <div>
          <span className="eyebrow">
            {activeRun?.is_event_boss ? 'НЕДЕЛЬНЫЙ БОСС · ПАТИ 2–4' : 'КООПЕРАТИВ · 2–4 ИГРОКА'}
          </span>
          <h2>{activeRun ? activeRun.title : 'Групповой поход'}</h2>
          <p className="muted">
            {activeRun?.is_event_boss
              ? 'Один общий бой. Каждый живой участник делает по одному действию за раунд, затем Пепельный Кузнец отвечает.'
              : 'Бой — весь поход по подземелью. Битва — отдельный зал. За раунд каждый живой герой делает одно действие, затем противник отвечает.'}
          </p>
        </div>
        <span className="badge">
          {activeRun ? activeRun.member_count + ' в походе' : party.member_count + ' / 4'}
        </span>
      </div>

      {message && <p className="form-message" aria-live="polite">{message}</p>}

      {!activeRun && (
        <p className="muted party-dungeon-exhaustion-note">
          Для каждого данжа действует личный 18-часовой цикл. Первые 25 попыток дают награды по обычной шкале; с 26-й попытки можно заходить сколько угодно, но без опыта, золота и личного лута. После окончания 18 часов цикл начинается заново.
        </p>
      )}

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
              <div className="party-dungeon-waiting">
                Твой боевой набор: {spells.length}/3 · {spells.length > 0 ? spells.map((spell) => spell.name).join(' · ') : 'без заклинаний'}.
                {spells.length === 1 ? ' Концентрация активна.' : ''} После начала похода изменить его нельзя.
              </div>

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
          {activeRun.is_event_boss ? (
            <div className="event-active-run-note">
              <strong>Особая награда считается отдельно для каждого участника.</strong>
              <span>Клеймо закалки III выдаётся персонажу только за его первую победу текущей недельной ротации. Повторные победы дают небольшое золото и опыт.</span>
            </div>
          ) : (
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
                <span>
                  {activeRun.danger_level === 0
                    ? 'За полную зачистку · стартовая аварийная награда'
                    : `За полную зачистку · рекомендованный уровень ≤ ${dungeonRecommendedLevel(activeRun.danger_level)}`}
                </span>
                <strong>
                  {me?.reward_exhausted
                    ? 0
                    : me
                      ? scaledPartyDungeonReward(activeRun.reward_gold, activeRun.danger_level, me.level, 'gold')
                      : activeRun.reward_gold} золота · {me?.reward_exhausted
                    ? 0
                    : me
                      ? scaledPartyDungeonReward(activeRun.reward_experience, activeRun.danger_level, me.level, 'xp')
                      : activeRun.reward_experience} опыта тебе
                </strong>
                {me?.reward_exhausted ? (
                  <small>Личный лимит наград исчерпан: это попытка №{me.reward_attempt_number ?? 26} текущего 18-часового цикла. Вход и прохождение доступны, награда — 0.</small>
                ) : activeRun.danger_level === 0 ? (
                  <small>ОПЫТ: УР. 1 — 15 · УР. 2 — 11 · УР. 3 — 6 · УР. 4 — 2 · УР. 5+ — 1. Золото всегда 40.</small>
                ) : (
                  <small>Если перерасти данж, награда постепенно снижается, но не ниже 5% опыта и 35% золота.</small>
                )}
              </div>
            </div>
          )}

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
                      @{member.display_name} · УР. {member.level}
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
                  <span>ОЗ {member.hp_current}/{member.hp_max}</span>
                  <div className="party-resource-meter hp">
                    <span style={{ width: hpPercent(member.hp_current, member.hp_max) + '%' }} />
                  </div>
                </div>
                <div className="party-resource-row">
                  <span>ОМ {member.mana_current}/{member.mana_max}</span>
                  <div className="party-resource-meter mana">
                    <span style={{ width: hpPercent(member.mana_current, member.mana_max) + '%' }} />
                  </div>
                </div>

                {member.reward_exhausted && (
                  <small className="party-buff-state">
                    Лимит наград исчерпан · попытка №{member.reward_attempt_number ?? 26} · этот поход без опыта, золота и личного лута
                  </small>
                )}
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
                  ОЗ и мана сохраняются между залами. После победы можно немного подождать пассивного восстановления или идти дальше.
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
                      : '80% успеха. При провале ОЗ всей группы станет 1.'}
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
                      {activeRun.is_event_boss ? 'НЕДЕЛЬНЫЙ БОСС' : activeEncounter.is_boss ? 'ХРАНИТЕЛЬ' : 'ПРОТИВНИК'} · РАУНД {activeEncounter.round}
                    </span>
                    <h3>{activeEncounter.enemy_name}</h3>
                    <p className="muted">
                      УР. {activeEncounter.enemy_level} · атака: {damageLabels[activeEncounter.enemy_damage_type] ?? activeEncounter.enemy_damage_type}
                    </p>
                  </div>
                  <strong>{activeEncounter.enemy_hp_current} / {activeEncounter.enemy_hp_max} ОЗ</strong>
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

              {isBowProfile(bowProfile) && me && (
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
                {isBowProfile(bowProfile) ? (
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
                  activeRun.is_event_boss ? (
                    <button
                      className="ghost-button danger-button"
                      type="button"
                      disabled={busy}
                      onClick={() => void abandonEventBossParty()}
                    >
                      Отступить всей группой
                    </button>
                  ) : (
                    <button
                      className="ghost-button danger-button"
                      type="button"
                      disabled={busy || escapeLocked}
                      onClick={() => void attemptEscape()}
                    >
                      {escapeLocked ? 'Побег недоступен' : 'Групповой побег · 80%'}
                    </button>
                  )
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
                        <span>×{state.sacrifice_scroll_count} · требует &gt;200 текущего ОЗ</span>
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
                              ? 'Нужно больше 200 текущего ОЗ.'
                              : 'Необратимо исключает твоего персонажа до конца текущего похода.'
                        }
                        onClick={() => void useLastSacrificeScroll()}
                      >
                        {state.run?.sacrifice_scroll_used
                          ? 'Уже использовано в этом бою'
                          : (me?.hp_current ?? 0) <= 200
                            ? 'Нужно >200 ОЗ'
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
                              {' · '}{spell.mana_cost} ОМ
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
                                ? 'ОЗ полностью восстановлено'
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
