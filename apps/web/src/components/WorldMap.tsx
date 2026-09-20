import { memo, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useSmartRefresh } from '../lib/smartRefresh'
import { SettlementShop } from './SettlementShop'
import type {
  CharacterMapSector,
  DungeonRun,
  ExpeditionEventInstance,
  ExpeditionResult,
  SectorExpedition,
  SectorSiteAction,
  SectorSiteProgress,
  SectorContentType,
} from '../types'

type Props = {
  characterId: string
  onOpenBattles?: () => void
  onProgressChanged?: () => Promise<unknown> | void
  onInventoryChanged?: () => Promise<unknown> | void
}

type WorldStrongEnemy = {
  event_id: string
  slug: string
  name: string
  description: string
  sector_id: number
  grid_col: number
  grid_row: number
  starts_at: string
  ends_at: string
  recommended_level: number
  enemy_level: number
  enemy_hp: number
  enemy_attack: number
  enemy_defense: number
  enemy_initiative: number
  enemy_damage_type: string
  enemy_resistances: Record<string, number>
  phase2_hp_percent: number
  phase2_name: string
  mechanics: {
    wound_rupture?: {
      enabled?: boolean
      max_stacks?: number
      rupture_max_hp_percent?: number
    }
    rage_hunt?: {
      enabled?: boolean
      self_damage_max_hp_percent?: number
      dash_damage_percent?: number
      dash_chance_1?: number
      dash_chance_2?: number
      dash_chance_3?: number
      dash_chance_4?: number
    }
  }
  reward_name: string | null
  reward_description: string | null
  victories: number
  defeated: boolean
  solo_only: boolean
  run_id: string | null
  run_status: 'active' | 'completed' | 'abandoned' | null
  encounter_id: string | null
  encounter_status: 'active' | 'victory' | 'defeat' | 'cancelled' | null
  character_busy: boolean
}

type DeathSpiritMapEntry = {
  spirit_id: string
  owner_character_id: string
  owner_name: string
  sector_id: number
  grid_col: number
  grid_row: number
  is_own: boolean
  has_trophy: boolean
  trophy_name: string | null
  created_at: string
  expires_at: string
}

type WorldMapCacheEntry = {
  sectors: CharacterMapSector[]
  expeditions: SectorExpedition[]
  events: ExpeditionEventInstance[]
  results: ExpeditionResult[]
  siteActions: SectorSiteAction[]
  siteProgress: SectorSiteProgress[]
  dungeonRuns: DungeonRun[]
  deathSpirits: DeathSpiritMapEntry[]
  strongEnemies: WorldStrongEnemy[]
}

const worldMapCache = new Map<string, WorldMapCacheEntry>()

const TOTAL_SECTORS = 300
const EXPLORATION_HOURS = 4
const MAP_BASE_WIDTH = 1100
const MAP_MIN_ZOOM = 0.35
const MAP_MAX_ZOOM = 1.75
const MAP_ZOOM_STEP = 0.15

function initialMapZoom() {
  if (typeof window === 'undefined') return 1
  return window.matchMedia('(max-width: 760px)').matches ? 0.6 : 1
}

function clampMapZoom(value: number) {
  return Math.min(MAP_MAX_ZOOM, Math.max(MAP_MIN_ZOOM, Math.round(value * 100) / 100))
}

const ORIGINAL_MAP_URL = supabase.storage
  .from('veira-assets')
  .getPublicUrl('eilar-map-original.png').data.publicUrl + '?v=original-1'

const terrainLabels: Record<string, string> = {
  unassigned: 'Не определено',
  plains: 'Равнины',
  forest: 'Лес',
  swamp: 'Болота',
  desert: 'Пустыня',
  mountains: 'Горы',
  tundra: 'Тундра',
  coast: 'Побережье',
  sea: 'Море',
  riverlands: 'Речные земли',
}

const contentLabels: Record<string, string> = {
  unassigned: 'Ничего особого',
  wilderness: 'Дикая местность',
  settlement: 'Поселение',
  ruins: 'Руины',
  dungeon: 'Подземелье',
  resource: 'Ресурсная точка',
  npc: 'NPC',
  landmark: 'Достопримечательность',
  event: 'Событие',
}

type VisibleSectorContent = Exclude<SectorContentType, 'unassigned'>

const mapContentLegend: Array<{
  type: VisibleSectorContent
  label: string
}> = [
  { type: 'settlement', label: 'Поселение' },
  { type: 'ruins', label: 'Руины' },
  { type: 'dungeon', label: 'Подземелье' },
  { type: 'resource', label: 'Ресурс' },
  { type: 'npc', label: 'NPC' },
  { type: 'landmark', label: 'Особое место' },
  { type: 'event', label: 'Событие' },
]

function sectorContentClass(contentType: SectorContentType | null) {
  if (!contentType || contentType === 'unassigned') return ''
  return `content-${contentType}`
}

function SectorContentIcon({ type }: { type: VisibleSectorContent }) {
  const common = {
    viewBox: '0 0 24 24',
    'aria-hidden': true,
    focusable: false,
  } as const

  if (type === 'settlement') {
    return (
      <svg {...common}>
        <path d="M4 11 12 5l8 6v8H4z" />
        <path d="M9 19v-5h6v5" />
      </svg>
    )
  }

  if (type === 'ruins') {
    return (
      <svg {...common}>
        <path d="M5 7h14M7 7v11M12 7v11M17 7v11M5 18h14M4 5h16" />
      </svg>
    )
  }

  if (type === 'dungeon') {
    return (
      <svg {...common}>
        <path d="M5 20V11a7 7 0 0 1 14 0v9" />
        <path d="M9 20v-8a3 3 0 0 1 6 0v8M4 20h16" />
      </svg>
    )
  }

  if (type === 'wilderness') {
    return (
      <svg {...common}>
        <path d="m12 4-5 7h3l-4 6h12l-4-6h3zM12 17v3" />
      </svg>
    )
  }

  if (type === 'resource') {
    return (
      <svg {...common}>
        <path d="m12 3 6 6-6 12L6 9zM6 9h12M9 9l3 12 3-12" />
      </svg>
    )
  }

  if (type === 'npc') {
    return (
      <svg {...common}>
        <circle cx="12" cy="8" r="3" />
        <path d="M6 20c.5-4 2.5-6 6-6s5.5 2 6 6" />
      </svg>
    )
  }

  if (type === 'landmark') {
    return (
      <svg {...common}>
        <path d="M7 21V4M8 5h10l-2.5 3L18 11H8" />
      </svg>
    )
  }

  return (
    <svg {...common}>
      <path d="M12 4v10M12 18.5v.5" />
      <circle cx="12" cy="12" r="9" />
    </svg>
  )
}

const MapSectorButton = memo(function MapSectorButton({
  sector,
  active,
  awaitingEvent,
  selected,
  showGameplayOverlay,
  deathSpiritCount,
  strongEnemyCount,
  onSelect,
}: {
  sector: CharacterMapSector
  active: boolean
  awaitingEvent: boolean
  selected: boolean
  showGameplayOverlay: boolean
  deathSpiritCount: number
  strongEnemyCount: number
  onSelect: (sectorId: number) => void
}) {
  const contentType =
    sector.is_discovered
    && sector.content_type
    && sector.content_type !== 'unassigned'
    && sector.content_type !== 'wilderness'
      ? sector.content_type
      : null

  const classNames = [
    'fog-sector',
    sector.is_discovered ? 'discovered' : 'hidden',
    sector.is_explorable ? 'explorable' : '',
    contentType ? sectorContentClass(contentType) : '',
    active ? 'active-expedition' : '',
    awaitingEvent && active ? 'awaiting-event' : '',
    selected ? 'selected' : '',
    deathSpiritCount > 0 ? 'has-death-spirit' : '',
    strongEnemyCount > 0 ? 'has-strong-enemy' : '',
  ].filter(Boolean).join(' ')

  return (
    <button
      type="button"
      className={classNames}
      title={
        sector.is_discovered
          ? sector.title ?? `Открытый сектор ${sector.grid_col}:${sector.grid_row}`
          : sector.is_explorable
            ? `Исследовать сектор ${sector.grid_col}:${sector.grid_row}`
            : 'Неизведанная территория'
      }
      aria-label={
        sector.is_discovered
          ? sector.title ?? `Открытый сектор ${sector.grid_col}:${sector.grid_row}`
          : `Неизведанный сектор ${sector.grid_col}:${sector.grid_row}`
      }
      onClick={() => onSelect(sector.id)}
    >
      {active && (
        <span className="sector-expedition-mark">
          {awaitingEvent ? '!' : '⌛'}
        </span>
      )}
      {showGameplayOverlay && strongEnemyCount > 0 && (
        <span
          className="sector-strong-enemy-mark"
          title={strongEnemyCount > 1 ? `Сильные враги: ${strongEnemyCount}` : 'Сильный враг'}
          aria-label={strongEnemyCount > 1 ? `Сильные враги: ${strongEnemyCount}` : 'Сильный враг'}
        >
          ⚔
        </span>
      )}
      {showGameplayOverlay && deathSpiritCount > 0 && (
        <span
          className="sector-death-spirit-mark"
          title={deathSpiritCount > 1 ? `Духи погибших: ${deathSpiritCount}` : 'Дух погибшего'}
          aria-label={deathSpiritCount > 1 ? `Духи погибших: ${deathSpiritCount}` : 'Дух погибшего'}
        >
          ☠
        </span>
      )}
      {showGameplayOverlay && contentType && (
        <span
          className="sector-content-mark"
          title={contentLabels[contentType]}
        >
          <SectorContentIcon type={contentType} />
        </span>
      )}
      {!showGameplayOverlay && sector.is_discovered && sector.title && (
        <span className="sector-location-mark">◆</span>
      )}
    </button>
  )
})

function formatRemaining(milliseconds: number) {
  const safe = Math.max(0, milliseconds)
  const totalSeconds = Math.floor(safe / 1000)
  const hours = Math.floor(totalSeconds / 3600)
  const minutes = Math.floor((totalSeconds % 3600) / 60)
  const seconds = totalSeconds % 60

  return [hours, minutes, seconds]
    .map((value) => String(value).padStart(2, '0'))
    .join('')
    .replace(/^(..)(..)(..)$/, '$1:$2:$3')
}

function Countdown({ endsAt }: { endsAt: string }) {
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    const tick = () => {
      if (document.visibilityState === 'visible') setNow(Date.now())
    }
    const timer = window.setInterval(tick, 1000)
    document.addEventListener('visibilitychange', tick)
    return () => {
      window.clearInterval(timer)
      document.removeEventListener('visibilitychange', tick)
    }
  }, [])

  return <>{formatRemaining(new Date(endsAt).getTime() - now)}</>
}

export function WorldMap({
  characterId,
  onOpenBattles,
  onProgressChanged,
  onInventoryChanged,
}: Props) {
  const cachedMap = worldMapCache.get(characterId)
  const [sectors, setSectors] = useState<CharacterMapSector[]>(() => cachedMap?.sectors ?? [])
  const [expeditions, setExpeditions] = useState<SectorExpedition[]>(() => cachedMap?.expeditions ?? [])
  const [events, setEvents] = useState<ExpeditionEventInstance[]>(() => cachedMap?.events ?? [])
  const [results, setResults] = useState<ExpeditionResult[]>(() => cachedMap?.results ?? [])
  const [siteActions, setSiteActions] = useState<SectorSiteAction[]>(() => cachedMap?.siteActions ?? [])
  const [siteProgress, setSiteProgress] = useState<SectorSiteProgress[]>(() => cachedMap?.siteProgress ?? [])
  const [dungeonRuns, setDungeonRuns] = useState<DungeonRun[]>(() => cachedMap?.dungeonRuns ?? [])
  const [deathSpirits, setDeathSpirits] = useState<DeathSpiritMapEntry[]>(() => cachedMap?.deathSpirits ?? [])
  const [strongEnemies, setStrongEnemies] = useState<WorldStrongEnemy[]>(() => cachedMap?.strongEnemies ?? [])
  const [selectedSectorId, setSelectedSectorId] = useState<number | null>(null)
  const [loading, setLoading] = useState(() => !cachedMap)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const [mapSrc, setMapSrc] = useState(ORIGINAL_MAP_URL)
  const [showGameplayOverlay, setShowGameplayOverlay] = useState(true)
  const [mapZoom, setMapZoom] = useState(initialMapZoom)
  const mapFrameRef = useRef<HTMLDivElement | null>(null)
  const mapCenteredRef = useRef(false)

  async function loadMapData(silent = false) {
    if (!silent) {
      setLoading(true)
      setMessage('')
    }

    const [
      mapResult,
      expeditionResult,
      eventResult,
      resultResult,
      siteActionResult,
      siteProgressResult,
      dungeonRunResult,
      deathSpiritResult,
      strongEnemyResult,
    ] = await Promise.all([
      supabase.rpc('get_character_map_state', {
        p_character_id: characterId,
      }),
      supabase
        .from('sector_expeditions')
        .select('id, character_id, sector_id, status, started_at, ends_at, completed_at, created_at')
        .eq('character_id', characterId)
        .order('created_at', { ascending: false })
        .limit(20),
      supabase
        .from('expedition_event_instances')
        .select('id, expedition_id, event_definition_id, encounter_template_id, source_kind, character_id, sector_id, title, player_prompt, gm_notes, status, resolution_text, outcome, created_at, resolved_at, resolved_by')
        .eq('character_id', characterId)
        .order('created_at', { ascending: false })
        .limit(20),
      supabase
        .from('expedition_results')
        .select('id, expedition_id, character_id, sector_id, source, result_type, title, summary, outcome, encounter_template_id, created_at')
        .eq('character_id', characterId)
        .order('created_at', { ascending: false })
        .limit(20),
      supabase
        .from('sector_site_actions')
        .select('id, character_id, sector_id, action_type, status, started_at, ends_at, completed_at, result_title, result_text, created_at')
        .eq('character_id', characterId)
        .order('created_at', { ascending: false })
        .limit(20),
      supabase
        .from('character_sector_site_progress')
        .select('character_id, sector_id, site_type, status, first_interacted_at, completed_at, updated_at')
        .eq('character_id', characterId),
      supabase
        .from('dungeon_runs')
        .select('id, character_id, sector_id, status, current_stage, rooms_cleared, total_rooms, reward_gold, reward_experience, started_at, ended_at, created_at')
        .eq('character_id', characterId)
        .order('created_at', { ascending: false })
        .limit(20),
      supabase.rpc('get_visible_death_spirits', {
        p_character_id: characterId,
      }),
      supabase.rpc('get_visible_world_strong_enemies', {
        p_character_id: characterId,
      }),
    ])

    const error =
      mapResult.error ??
      expeditionResult.error ??
      eventResult.error ??
      resultResult.error ??
      siteActionResult.error ??
      siteProgressResult.error ??
      dungeonRunResult.error ??
      deathSpiritResult.error ??
      strongEnemyResult.error

    if (error) {
      if (!silent) setMessage(error.message)
      if (!silent) setLoading(false)
      return
    }

    const nextCache: WorldMapCacheEntry = {
      sectors: (mapResult.data as CharacterMapSector[] | null) ?? [],
      expeditions: (expeditionResult.data as SectorExpedition[] | null) ?? [],
      events: (eventResult.data as ExpeditionEventInstance[] | null) ?? [],
      results: (resultResult.data as ExpeditionResult[] | null) ?? [],
      siteActions: (siteActionResult.data as SectorSiteAction[] | null) ?? [],
      siteProgress: (siteProgressResult.data as SectorSiteProgress[] | null) ?? [],
      dungeonRuns: (dungeonRunResult.data as DungeonRun[] | null) ?? [],
      deathSpirits: (deathSpiritResult.data as DeathSpiritMapEntry[] | null) ?? [],
      strongEnemies: (strongEnemyResult.data as WorldStrongEnemy[] | null) ?? [],
    }

    worldMapCache.set(characterId, nextCache)
    setSectors(nextCache.sectors)
    setExpeditions(nextCache.expeditions)
    setEvents(nextCache.events)
    setResults(nextCache.results)
    setSiteActions(nextCache.siteActions)
    setSiteProgress(nextCache.siteProgress)
    setDungeonRuns(nextCache.dungeonRuns)
    setDeathSpirits(nextCache.deathSpirits)
    setStrongEnemies(nextCache.strongEnemies)
    if (!silent) setLoading(false)
  }

  useEffect(() => {
    mapCenteredRef.current = false
    setMapZoom(initialMapZoom())
    void loadMapData(Boolean(worldMapCache.get(characterId)))
  }, [characterId])

  useSmartRefresh(
    () => loadMapData(true),
    { enabled: sectors.length > 0, minGapMs: 1500 },
  )

  useEffect(() => {
    if (deathSpirits.length === 0) return

    const nextExpiry = Math.min(
      ...deathSpirits.map((spirit) => new Date(spirit.expires_at).getTime()),
    )
    const delay = Math.max(0, nextExpiry - Date.now() + 500)
    const timeout = window.setTimeout(() => {
      void loadMapData(true)
    }, delay)

    return () => window.clearTimeout(timeout)
  }, [deathSpirits])

  useEffect(() => {
    if (strongEnemies.length === 0) return

    const nextExpiry = Math.min(
      ...strongEnemies.map((enemy) => new Date(enemy.ends_at).getTime()),
    )
    const delay = Math.max(0, nextExpiry - Date.now() + 500)
    const timeout = window.setTimeout(() => {
      void loadMapData(true)
    }, delay)

    return () => window.clearTimeout(timeout)
  }, [strongEnemies])

  const sectorById = useMemo(
    () => new Map(sectors.map((sector) => [sector.id, sector])),
    [sectors],
  )

  const deathSpiritsBySector = useMemo(() => {
    const grouped = new Map<number, DeathSpiritMapEntry[]>()
    for (const spirit of deathSpirits) {
      const entries = grouped.get(spirit.sector_id) ?? []
      entries.push(spirit)
      grouped.set(spirit.sector_id, entries)
    }
    return grouped
  }, [deathSpirits])

  const strongEnemiesBySector = useMemo(() => {
    const grouped = new Map<number, WorldStrongEnemy[]>()
    for (const enemy of strongEnemies) {
      const entries = grouped.get(enemy.sector_id) ?? []
      entries.push(enemy)
      grouped.set(enemy.sector_id, entries)
    }
    return grouped
  }, [strongEnemies])

  const discoveredCount = useMemo(
    () => sectors.filter((sector) => sector.is_discovered).length,
    [sectors],
  )

  const discoveredMapCenter = useMemo(() => {
    const discovered = sectors.filter((sector) => sector.is_discovered)
    const visible = discovered.length > 0
      ? discovered
      : sectors.filter((sector) => sector.is_explorable)

    if (visible.length === 0) {
      return { x: 0.5, y: 0.5 }
    }

    const col = visible.reduce((sum, sector) => sum + sector.grid_col, 0) / visible.length
    const row = visible.reduce((sum, sector) => sum + sector.grid_row, 0) / visible.length

    return {
      x: Math.min(1, Math.max(0, (col - 0.5) / 20)),
      y: Math.min(1, Math.max(0, (row - 0.5) / 15)),
    }
  }, [sectors])

  function centerMapOnDiscovered(behavior: ScrollBehavior = 'smooth') {
    const frame = mapFrameRef.current
    if (!frame) return

    const left = discoveredMapCenter.x * frame.scrollWidth - frame.clientWidth / 2
    const top = discoveredMapCenter.y * frame.scrollHeight - frame.clientHeight / 2

    frame.scrollTo({
      left: Math.max(0, left),
      top: Math.max(0, top),
      behavior,
    })
  }

  function changeMapZoom(delta: number) {
    const frame = mapFrameRef.current
    const nextZoom = clampMapZoom(mapZoom + delta)
    if (nextZoom === mapZoom) return

    const centerX = frame && frame.scrollWidth > 0
      ? (frame.scrollLeft + frame.clientWidth / 2) / frame.scrollWidth
      : discoveredMapCenter.x
    const centerY = frame && frame.scrollHeight > 0
      ? (frame.scrollTop + frame.clientHeight / 2) / frame.scrollHeight
      : discoveredMapCenter.y

    setMapZoom(nextZoom)

    window.requestAnimationFrame(() => {
      window.requestAnimationFrame(() => {
        const nextFrame = mapFrameRef.current
        if (!nextFrame) return

        nextFrame.scrollTo({
          left: Math.max(0, centerX * nextFrame.scrollWidth - nextFrame.clientWidth / 2),
          top: Math.max(0, centerY * nextFrame.scrollHeight - nextFrame.clientHeight / 2),
          behavior: 'auto',
        })
      })
    })
  }

  useEffect(() => {
    if (loading || sectors.length === 0 || mapCenteredRef.current) return

    mapCenteredRef.current = true
    const frame = mapFrameRef.current
    if (!frame) return

    window.requestAnimationFrame(() => {
      window.requestAnimationFrame(() => centerMapOnDiscovered('auto'))
    })
  }, [loading, sectors, mapZoom, discoveredMapCenter.x, discoveredMapCenter.y])

  const activeExpedition =
    expeditions.find((entry) => entry.status === 'active') ?? null
  const waitingExpedition =
    expeditions.find((entry) => entry.status === 'awaiting_event') ?? null
  const openExpedition = activeExpedition ?? waitingExpedition
  const activeSector = openExpedition
    ? sectorById.get(openExpedition.sector_id) ?? null
    : null

  const pendingEvent =
    events.find((entry) => entry.status === 'pending') ?? null

  const latestResult = results[0] ?? null

  const activeSiteAction =
    siteActions.find((entry) => entry.status === 'active') ?? null
  const recentSiteResult =
    siteActions.find((entry) => entry.status === 'completed' && entry.result_text.trim()) ?? null
  const activeDungeonRun =
    dungeonRuns.find((entry) => entry.status === 'active') ?? null

  const siteProgressBySector = useMemo(
    () => new Map(siteProgress.map((entry) => [entry.sector_id, entry])),
    [siteProgress],
  )

  const anyBlockingActivity = Boolean(openExpedition || activeSiteAction || activeDungeonRun)

  const selectedSector = selectedSectorId
    ? sectorById.get(selectedSectorId) ?? null
    : null

  const selectedDeathSpirits = selectedSector
    ? deathSpiritsBySector.get(selectedSector.id) ?? []
    : []

  const selectedStrongEnemies = selectedSector
    ? strongEnemiesBySector.get(selectedSector.id) ?? []
    : []

  const selectSector = useCallback((sectorId: number) => {
    setSelectedSectorId(sectorId)
  }, [])

  useEffect(() => {
    const activeTimedAction = activeExpedition ?? activeSiteAction
    if (!activeTimedAction) return

    const endsAt = new Date(activeTimedAction.ends_at).getTime()
    const delay = Math.max(0, endsAt - Date.now() + 800)
    const timeout = window.setTimeout(() => {
      void loadMapData(true)
    }, delay)

    return () => window.clearTimeout(timeout)
  }, [activeExpedition?.id, activeExpedition?.ends_at, activeSiteAction?.id, activeSiteAction?.ends_at])

  async function cancelExploration(expeditionId: string) {
    if (!window.confirm('Отменить текущую экспедицию? Прогресс этого исследования будет потерян.')) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('cancel_sector_expedition', {
      p_expedition_id: expeditionId,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('EXPEDITION_NOT_CANCELLABLE')) {
        setMessage('Эту экспедицию уже нельзя отменить.')
      } else if (raw.includes('EXPEDITION_ALREADY_FINISHED_OR_RESOLVING')) {
        setMessage('Экспедиция уже завершает исследование. Обнови карту через несколько секунд.')
      } else {
        setMessage(raw)
      }

      setBusy(false)
      return
    }

    await loadMapData()
    setMessage('Экспедиция отменена. Можно выбрать другой сектор.')
    setBusy(false)
  }

  async function startExploration() {
    if (!selectedSector?.is_explorable) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('start_sector_exploration', {
      p_character_id: characterId,
      p_sector_id: selectedSector.id,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('PVP_DUEL_ACTIVE')) {
        setMessage('Сначала заверши активную дуэль.')
      } else if (raw.includes('EXPEDITION_ALREADY_ACTIVE')) {
        setMessage('У персонажа уже идёт экспедиция или ожидается решение события.')
      } else if (raw.includes('SECTOR_NOT_ADJACENT_TO_DISCOVERED')) {
        setMessage('Этот сектор пока нельзя исследовать: сначала открой соседнюю область.')
      } else if (raw.includes('PARTY_DUNGEON_ACTIVE')) {
        setMessage('Сначала заверши текущий групповой поход.')
      } else {
        setMessage(raw)
      }

      setBusy(false)
      return
    }

    setSelectedSectorId(null)
    await loadMapData()
    setBusy(false)
  }

  async function cancelSiteAction(actionId: string) {
    if (!window.confirm('Отменить это исследование? Уже прошедшее время будет потеряно.')) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('cancel_sector_site_action', {
      p_action_id: actionId,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('SITE_ACTION_NOT_CANCELLABLE')) {
        setMessage('Это исследование уже нельзя отменить.')
      } else if (raw.includes('SITE_ACTION_ALREADY_FINISHED_OR_RESOLVING')) {
        setMessage('Исследование уже завершает результат. Обнови карту через несколько секунд.')
      } else {
        setMessage(raw)
      }
      setBusy(false)
      return
    }

    await loadMapData()
    setMessage('Исследование отменено.')
    setBusy(false)
  }

  async function startSiteAction(actionType: 'explore_ruins' | 'scout_dungeon') {
    if (!selectedSector?.is_discovered) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('start_sector_site_action', {
      p_character_id: characterId,
      p_sector_id: selectedSector.id,
      p_action_type: actionType,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('PVP_DUEL_ACTIVE')) {
        setMessage('Сначала заверши активную дуэль.')
      } else if (raw.includes('EXPEDITION_ALREADY_ACTIVE')) {
        setMessage('Сначала заверши текущую экспедицию.')
      } else if (raw.includes('SITE_ACTION_ALREADY_ACTIVE')) {
        setMessage('Персонаж уже занят исследованием найденного места.')
      } else if (raw.includes('DUNGEON_RUN_ALREADY_ACTIVE')) {
        setMessage('Персонаж уже находится в подземелье.')
      } else if (raw.includes('RUINS_ALREADY_EXPLORED')) {
        setMessage('Эти руины уже исследованы.')
      } else if (raw.includes('DUNGEON_ALREADY_SCOUTED')) {
        setMessage('Вход в это подземелье уже разведан.')
      } else if (raw.includes('PARTY_DUNGEON_ACTIVE')) {
        setMessage('Сначала заверши текущий групповой поход.')
      } else {
        setMessage(raw)
      }

      setBusy(false)
      return
    }

    await loadMapData()
    setBusy(false)
  }

  async function startWorldStrongEnemy(enemy: WorldStrongEnemy) {
    if (enemy.run_status === 'active') {
      onOpenBattles?.()
      return
    }

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('start_event_boss', {
      p_character_id: characterId,
      p_event_id: enemy.event_id,
      p_mode: 'solo',
    })

    if (error) {
      const raw = error.message
      if (raw.includes('EVENT_BOSS_CHARACTER_LIMIT_REACHED')) {
        setMessage('Этот персонаж уже победил данного сильного врага. Повторная победа недоступна.')
      } else if (raw.includes('EVENT_BOSS_NOT_ACTIVE')) {
        setMessage('Это мировое событие уже закончилось.')
      } else if (raw.includes('EVENT_BOSS_SECTOR_NOT_DISCOVERED')) {
        setMessage('Сначала нужно открыть сектор с этим противником.')
      } else if (raw.includes('EVENT_BOSS_SOLO_ONLY')) {
        setMessage('Этого противника можно атаковать только в одиночку.')
      } else if (raw.includes('CHARACTER_BUSY') || raw.includes('DUNGEON_RUN_ALREADY_ACTIVE')) {
        setMessage('Персонаж уже занят другим боем или исследованием.')
      } else if (raw.includes('PVP_DUEL_ACTIVE')) {
        setMessage('Сначала заверши активную дуэль.')
      } else if (raw.includes('CHARACTER_HAS_NO_HP')) {
        setMessage('Перед боем восстанови хотя бы часть ОЗ.')
      } else {
        setMessage(raw)
      }
      setBusy(false)
      return
    }

    await Promise.all([
      loadMapData(true),
      Promise.resolve(onProgressChanged?.()),
    ])
    setBusy(false)
    onOpenBattles?.()
  }

  async function startDeathSpiritCombat(spirit: DeathSpiritMapEntry) {
    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('start_death_spirit_combat', {
      p_character_id: characterId,
      p_spirit_id: spirit.spirit_id,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('SPIRIT_ALREADY_CHALLENGED')) {
        setMessage('С этим духом уже сражается другой персонаж.')
      } else if (raw.includes('DEATH_SPIRIT_NOT_ACTIVE')) {
        setMessage('Этот дух уже исчез или был побеждён.')
      } else if (raw.includes('COMBAT_ALREADY_ACTIVE')) {
        setMessage('У персонажа уже идёт другой бой.')
      } else if (raw.includes('DUNGEON_RUN_ALREADY_ACTIVE') || raw.includes('PARTY_DUNGEON_ACTIVE')) {
        setMessage('Сначала заверши текущее прохождение подземелья.')
      } else if (raw.includes('PVP_DUEL_ACTIVE')) {
        setMessage('Сначала заверши активную дуэль.')
      } else {
        setMessage(raw)
      }
      setBusy(false)
      return
    }

    await loadMapData(true)
    setMessage('Бой с духом начат. Продолжай его в разделе «Бои».')
    setBusy(false)
  }

  async function enterDungeon() {
    if (!selectedSector?.is_discovered) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('start_dungeon_run', {
      p_character_id: characterId,
      p_sector_id: selectedSector.id,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('PVP_DUEL_ACTIVE')) {
        setMessage('Сначала заверши активную дуэль.')
      } else if (raw.includes('DUNGEON_NOT_SCOUTED')) {
        setMessage('Сначала разведай вход в подземелье.')
      } else if (raw.includes('DUNGEON_RUN_ALREADY_ACTIVE')) {
        setMessage('У персонажа уже есть активное прохождение подземелья.')
      } else if (raw.includes('EXPEDITION_ALREADY_ACTIVE') || raw.includes('SITE_ACTION_ALREADY_ACTIVE')) {
        setMessage('Сначала заверши текущее исследование.')
      } else if (raw.includes('PARTY_DUNGEON_ACTIVE')) {
        setMessage('Ты уже находишься в групповом походе. Управление им находится в «Приключениях».')
      } else {
        setMessage(raw)
      }

      setBusy(false)
      return
    }

    await loadMapData()
    setMessage('Прохождение подземелья начато. Продолжение доступно в разделе «Приключения».')
    setBusy(false)
  }

  if (loading && sectors.length === 0) {
    return (
      <section className="panel world-loading-panel">
        <span className="eyebrow">КАРТА ЭЙЛАРА</span>
        <h2>Разворачиваем карту…</h2>
      </section>
    )
  }

  return (
    <section className="world-section">
      <article className="panel world-header-card">
        <div>
          <span className="eyebrow">ЭЙЛАР · ЛИЧНАЯ КАРТА</span>
          <h2>Исследование мира</h2>
          <p className="muted">
            Карта разделена на {TOTAL_SECTORS} секторов. Неизведанный соседний сектор открывается за {EXPLORATION_HOURS} часов реального времени. Исследование пассивное: параллельно можно дуэлиться, крафтить и заниматься социальными или учебными активностями.
          </p>
        </div>

        <div className="world-progress">
          <strong>{discoveredCount} / {TOTAL_SECTORS}</strong>
          <span>открыто</span>
        </div>
      </article>

      {message && <p className="gm-notice" aria-live="polite">{message}</p>}

      {activeExpedition && activeSector && (
        <article className="panel expedition-status-card">
          <div>
            <span className="eyebrow">ЭКСПЕДИЦИЯ ИДЁТ</span>
            <h3>Сектор {activeSector.grid_col}:{activeSector.grid_row}</h3>
            <p className="muted">
              По окончании таймера сектор либо откроется, либо экспедиция может столкнуться с событием.
            </p>
          </div>
          <div className="expedition-timer">
            <span>Осталось</span>
            <strong><Countdown endsAt={activeExpedition.ends_at} /></strong>
            <button
              className="ghost-button danger-button expedition-cancel-button"
              type="button"
              disabled={busy}
              onClick={() => void cancelExploration(activeExpedition.id)}
            >
              Отменить экспедицию
            </button>
          </div>
        </article>
      )}

      {activeSiteAction && (
        <article className="panel expedition-status-card site-action-status-card">
          <div>
            <span className="eyebrow">
              {activeSiteAction.action_type === 'explore_ruins' ? 'ИССЛЕДОВАНИЕ РУИН' : 'РАЗВЕДКА ПОДЗЕМЕЛЬЯ'}
            </span>
            <h3>
              {activeSiteAction.action_type === 'explore_ruins'
                ? 'Подробный осмотр найденных руин'
                : 'Разведка входа и подходов'}
            </h3>
            <p className="muted">
              Сектор #{activeSiteAction.sector_id}. Это пассивное исследование: можно дуэлиться, заниматься ремеслом и другими делами. Нельзя начинать другое исследование или тяжёлые бои с противниками.
            </p>
          </div>
          <div className="expedition-timer">
            <span>Осталось</span>
            <strong><Countdown endsAt={activeSiteAction.ends_at} /></strong>
            <button
              className="ghost-button danger-button expedition-cancel-button"
              type="button"
              disabled={busy}
              onClick={() => void cancelSiteAction(activeSiteAction.id)}
            >
              Отменить исследование
            </button>
          </div>
        </article>
      )}

      {activeDungeonRun && (
        <article className="panel dungeon-active-card">
          <div>
            <span className="eyebrow">АКТИВНОЕ ПОДЗЕМЕЛЬЕ</span>
            <h3>Персонаж находится внутри</h3>
            <p className="muted">
              Сектор #{activeDungeonRun.sector_id}. Управление прохождением находится в разделе «Приключения».
            </p>
          </div>
          <span className="badge">у входа</span>
        </article>
      )}

      {waitingExpedition && pendingEvent && (
        <article className="panel expedition-event-card">
          <div>
            <span className="eyebrow">СОБЫТИЕ ЭКСПЕДИЦИИ</span>
            <h3>{pendingEvent.title}</h3>
            <p>{pendingEvent.player_prompt || 'Экспедиция столкнулась с ситуацией, требующей решения ГМ.'}</p>
          </div>
          <span className="badge event-waiting-badge">Ожидает ГМ</span>
        </article>
      )}

      {!activeSiteAction && recentSiteResult && (
        <article className="panel expedition-result-card site-result-card">
          <div>
            <span className="eyebrow">
              {recentSiteResult.action_type === 'explore_ruins' ? 'РУИНЫ ИССЛЕДОВАНЫ' : 'ВХОД РАЗВЕДАН'}
            </span>
            <h3>{recentSiteResult.result_title}</h3>
            <p>{recentSiteResult.result_text}</p>
          </div>
          <span className="badge">
            {recentSiteResult.action_type === 'explore_ruins' ? 'исследовано' : 'доступен вход'}
          </span>
        </article>
      )}

      {!pendingEvent && latestResult && (
        <article className="panel expedition-result-card">
          <div>
            <span className="eyebrow">
              {latestResult.source === 'random_event'
                ? 'СЛУЧАЙНОЕ СОБЫТИЕ'
                : latestResult.source === 'gm_event'
                  ? 'ИТОГ СОБЫТИЯ'
                  : 'ОТЧЁТ ЭКСПЕДИЦИИ'}
            </span>
            <h3>{latestResult.title}</h3>
            <p>{latestResult.summary}</p>
            <div className="sector-tags expedition-result-tags">
              <span>{contentLabels[latestResult.result_type] ?? 'Исследование'}</span>
              <span>Сектор #{latestResult.sector_id}</span>
            </div>
          </div>
          <span className="badge">
            {latestResult.outcome === 'discovered' ? 'Сектор открыт' : 'Экспедиция остановлена'}
          </span>
        </article>
      )}

      <div className="world-map-tools">
        <div className="world-map-control-row">
          <div className="world-map-mode" role="group" aria-label="Режим отображения карты">
            <button
              type="button"
              className={showGameplayOverlay ? 'active' : ''}
              onClick={() => setShowGameplayOverlay(true)}
            >
              Игровой слой
            </button>
            <button
              type="button"
              className={!showGameplayOverlay ? 'active' : ''}
              onClick={() => setShowGameplayOverlay(false)}
            >
              Чистая карта
            </button>
          </div>

          <div className="world-map-zoom" role="group" aria-label="Масштаб карты">
            <button
              type="button"
              aria-label="Уменьшить карту"
              title="Уменьшить"
              disabled={mapZoom <= MAP_MIN_ZOOM}
              onClick={() => changeMapZoom(-MAP_ZOOM_STEP)}
            >
              −
            </button>
            <span>{Math.round(mapZoom * 100)}%</span>
            <button
              type="button"
              aria-label="Приблизить карту"
              title="Приблизить"
              disabled={mapZoom >= MAP_MAX_ZOOM}
              onClick={() => changeMapZoom(MAP_ZOOM_STEP)}
            >
              +
            </button>
            <button
              className="map-center-button"
              type="button"
              onClick={() => centerMapOnDiscovered()}
            >
              К открытым
            </button>
          </div>
        </div>

        {showGameplayOverlay && (
          <div className="world-map-legend" aria-label="Легенда игровой карты">
            {mapContentLegend.map((entry) => (
              <span
                key={entry.type}
                className={`map-legend-item content-${entry.type}`}
              >
                <span className="map-legend-icon">
                  <SectorContentIcon type={entry.type} />
                </span>
                {entry.label}
              </span>
            ))}
            <span className="map-legend-item strong-enemy">
              <span className="map-legend-icon strong-enemy">⚔</span>
              Сильный враг
            </span>
          </div>
        )}
      </div>

      <div
        ref={mapFrameRef}
        className="eilar-map-frame"
        aria-label="Область просмотра карты. Карту можно перемещать прокруткой и менять её масштаб кнопками."
      >
        <div
          className="eilar-map-stage"
          style={{ width: `max(100%, ${Math.round(MAP_BASE_WIDTH * mapZoom)}px)` }}
        >
          <img
            src={mapSrc}
            alt="Карта Эйлара"
            decoding="async"
            fetchPriority="high"
            draggable={false}
            onError={() => {
              const fallback = import.meta.env.BASE_URL + 'eilar-map.webp?v=20260919-2'
              if (mapSrc !== fallback) setMapSrc(fallback)
            }}
          />

          <div
            className={`fog-grid ${showGameplayOverlay ? 'gameplay-overlay' : 'clean-overlay'}`}
            aria-label="Сектора карты Эйлара"
          >
            {sectors.map((sector) => (
              <MapSectorButton
                key={sector.id}
                sector={sector}
                active={openExpedition?.sector_id === sector.id}
                awaitingEvent={Boolean(waitingExpedition)}
                selected={selectedSectorId === sector.id}
                showGameplayOverlay={showGameplayOverlay}
                deathSpiritCount={deathSpiritsBySector.get(sector.id)?.length ?? 0}
                strongEnemyCount={strongEnemiesBySector.get(sector.id)?.length ?? 0}
                onSelect={selectSector}
              />
            ))}
          </div>
        </div>
      </div>

      <article className="panel sector-detail-card">
        {!selectedSector ? (
          <>
            <span className="eyebrow">СЕКТОР</span>
            <h3>Выбери область на карте</h3>
            <p className="muted">
              После открытия сектор получает собственную карточку: тип местности, найденное место, уровень опасности и описание.
            </p>
          </>
        ) : selectedSector.is_discovered ? (
          <>
            <div className="sector-detail-heading">
              <div>
                <span className="eyebrow">ОТКРЫТАЯ ТЕРРИТОРИЯ</span>
                <h3>{selectedSector.title ?? `Сектор ${selectedSector.grid_col}:${selectedSector.grid_row}`}</h3>
              </div>
              <span className="badge">
                Опасность {selectedSector.danger_level ?? 0}/10
              </span>
            </div>

            <div className="sector-tags">
              <span>{terrainLabels[selectedSector.terrain_type ?? 'unassigned'] ?? 'Не определено'}</span>
              <span>{contentLabels[selectedSector.content_type ?? 'unassigned'] ?? 'Не определено'}</span>
              {selectedSector.requires_gm && <span>ГМ-сцена</span>}
            </div>

            <p className="sector-description">
              {selectedSector.player_description ||
                'Этот сектор уже нанесён на карту, но подробное описание пока не задано.'}
            </p>

            {selectedStrongEnemies.length > 0 && (
              <div className="world-strong-enemy-list">
                {selectedStrongEnemies.map((enemy) => {
                  const wounds = enemy.mechanics.wound_rupture
                  const rage = enemy.mechanics.rage_hunt
                  const runActive = enemy.run_status === 'active'

                  return (
                    <div className={'world-strong-enemy-card ' + (enemy.defeated ? 'defeated' : '')} key={enemy.event_id}>
                      <div className="world-strong-enemy-head">
                        <div>
                          <span className="eyebrow">{enemy.defeated ? 'ПОБЕЖДЁН' : 'СИЛЬНЫЙ ВРАГ · ТОЛЬКО СОЛО'}</span>
                          <strong>{enemy.name}</strong>
                          <small>Исчезнет через <Countdown endsAt={enemy.ends_at} /></small>
                        </div>
                        <span className={'badge ' + (enemy.defeated ? 'ready' : '')}>
                          ур. {enemy.enemy_level}
                        </span>
                      </div>

                      <p>{enemy.description}</p>

                      <div className="world-strong-enemy-stats">
                        <span><small>ОЗ</small><b>{enemy.enemy_hp}</b></span>
                        <span><small>Атака</small><b>{enemy.enemy_attack}</b></span>
                        <span><small>Защита</small><b>{enemy.enemy_defense}</b></span>
                        <span><small>Рекомендация</small><b>ур. {enemy.recommended_level}+</b></span>
                      </div>

                      <div className="world-strong-enemy-mechanics">
                        {wounds?.enabled && (
                          <div>
                            <strong>Ранения → Разрыв</strong>
                            <span>
                              3 успешных удара накапливают Ранения. Следующая успешная атака вызывает Разрыв:
                              {' '}{wounds.rupture_max_hp_percent ?? 6}% макс. ОЗ. Разрыв нельзя заблокировать;
                              Ранения снимаются очищением.
                            </span>
                          </div>
                        )}
                        {rage?.enabled && (
                          <div>
                            <strong>{enemy.phase2_name || 'Вторая фаза'} · &lt;{enemy.phase2_hp_percent}% ОЗ</strong>
                            <span>
                              Каждый обычный удар отнимает у врага {rage.self_damage_max_hp_percent ?? 3}% его Max HP.
                              Шанс слабого Рывка растёт: {rage.dash_chance_1 ?? 20}% → {rage.dash_chance_2 ?? 35}% →
                              {' '}{rage.dash_chance_3 ?? 50}% → {rage.dash_chance_4 ?? 70}%. Рывок не создаёт Ранение,
                              но может вызвать Разрыв при 3 Ранениях.
                            </span>
                          </div>
                        )}
                      </div>

                      <div className="world-strong-enemy-reward">
                        <span className="eyebrow">ГАРАНТИРОВАНО ЗА ПЕРВУЮ ПОБЕДУ</span>
                        <strong>{enemy.reward_name ?? 'Особая награда'}</strong>
                        {enemy.reward_description && <small>{enemy.reward_description}</small>}
                      </div>

                      <button
                        className="primary-button"
                        type="button"
                        disabled={busy || enemy.defeated || (!runActive && enemy.character_busy)}
                        onClick={() => runActive ? onOpenBattles?.() : void startWorldStrongEnemy(enemy)}
                      >
                        {enemy.defeated
                          ? 'Уже побеждён'
                          : runActive
                            ? 'Продолжить бой'
                            : enemy.character_busy
                              ? 'Персонаж занят'
                              : 'Сразиться с сильным врагом'}
                      </button>
                    </div>
                  )
                })}
              </div>
            )}

            {selectedDeathSpirits.length > 0 && (
              <div className="death-spirit-sector-list">
                {selectedDeathSpirits.map((spirit) => (
                  <div className={`death-spirit-sector-card ${spirit.is_own ? 'own' : 'foreign'}`} key={spirit.spirit_id}>
                    <div>
                      <span className="eyebrow">{spirit.is_own ? 'ТВОЙ ДУХ' : 'ЧУЖОЙ ДУХ'}</span>
                      <strong>Дух {spirit.owner_name}</strong>
                      <small>
                        Исчезнет через <Countdown endsAt={spirit.expires_at} />
                      </small>
                      <p>
                        {spirit.is_own
                          ? spirit.has_trophy
                            ? `Удерживает: ${spirit.trophy_name ?? 'потерянное снаряжение'}. В бою дух использует 60% силы исходного персонажа.`
                            : 'У духа нет удерживаемого снаряжения. В бою он ослаблен на 30%.'
                          : spirit.has_trophy
                            ? 'Удерживает неизвестный трофей. Для чужого персонажа дух использует 160% силы исходного персонажа.'
                            : 'Трофея нет. Для чужого персонажа дух использует 160% силы исходного персонажа.'}
                      </p>
                    </div>
                    <button
                      className="primary-button death-spirit-fight-button"
                      type="button"
                      disabled={busy}
                      onClick={() => void startDeathSpiritCombat(spirit)}
                    >
                      {spirit.is_own ? 'Вернуть снаряжение' : 'Сразиться за трофей'}
                    </button>
                  </div>
                ))}
              </div>
            )}

            {selectedSector.content_type === 'ruins' && (() => {
              const progress = siteProgressBySector.get(selectedSector.id)
              const alreadyExplored = progress?.status === 'explored' || progress?.status === 'cleared'
              const thisActionActive =
                activeSiteAction?.sector_id === selectedSector.id &&
                activeSiteAction.action_type === 'explore_ruins'

              return (
                <div className="sector-site-actions">
                  <div className="sector-site-state">
                    <strong>Руины</strong>
                    <span>
                      {alreadyExplored
                        ? 'Подробно исследованы'
                        : thisActionActive
                          ? 'Исследование уже идёт'
                          : 'Обнаружены, но ещё не исследованы'}
                    </span>
                  </div>

                  {!alreadyExplored && !thisActionActive && (
                    <button
                      className="primary-button"
                      type="button"
                      disabled={busy || anyBlockingActivity}
                      onClick={() => void startSiteAction('explore_ruins')}
                    >
                      Исследовать руины · 2 часа
                    </button>
                  )}
                </div>
              )
            })()}

            {selectedSector.content_type === 'dungeon' && (() => {
              const progress = siteProgressBySector.get(selectedSector.id)
              const scouted = progress?.status === 'scouted' || progress?.status === 'cleared'
              const thisActionActive =
                activeSiteAction?.sector_id === selectedSector.id &&
                activeSiteAction.action_type === 'scout_dungeon'
              const thisRunActive =
                activeDungeonRun?.sector_id === selectedSector.id

              return (
                <div className="sector-site-actions">
                  <div className="sector-site-state">
                    <strong>Подземелье</strong>
                    <span>
                      {thisRunActive
                        ? 'Прохождение уже начато'
                        : scouted
                          ? 'Вход разведан — можно начинать прохождение'
                          : thisActionActive
                            ? 'Разведка входа уже идёт'
                            : 'Подземелье обнаружено, но вход ещё не разведан'}
                    </span>
                  </div>

                  {!scouted && !thisActionActive && (
                    <button
                      className="primary-button"
                      type="button"
                      disabled={busy || anyBlockingActivity}
                      onClick={() => void startSiteAction('scout_dungeon')}
                    >
                      Разведать вход · 1 час
                    </button>
                  )}

                  {scouted && !thisRunActive && (
                    <button
                      className="primary-button"
                      type="button"
                      disabled={busy || anyBlockingActivity}
                      onClick={() => void enterDungeon()}
                    >
                      Войти в подземелье
                    </button>
                  )}
                </div>
              )
            })()}
          </>
        ) : (
          <>
            <span className="eyebrow">НЕИЗВЕДАННАЯ ТЕРРИТОРИЯ</span>
            <h3>Сектор {selectedSector.grid_col}:{selectedSector.grid_row}</h3>
            <p className="muted">
              {selectedSector.is_explorable
                ? 'Он граничит с уже известной территорией и доступен для исследования.'
                : anyBlockingActivity
                  ? activeDungeonRun
                    ? 'Сначала нужно покинуть активное подземелье.'
                    : activeSiteAction
                      ? 'Сначала заверши текущее исследование найденного места.'
                      : 'Сначала нужно завершить текущую экспедицию или событие.'
                  : 'Пока слишком далеко от изученной части карты. Сначала открой соседние сектора.'}
            </p>

            {selectedSector.is_explorable && (
              <button
                className="primary-button sector-explore-button"
                type="button"
                disabled={busy || anyBlockingActivity}
                onClick={() => void startExploration()}
              >
                {busy ? 'Отправляемся…' : `Исследовать · ${EXPLORATION_HOURS} часов`}
              </button>
            )}
          </>
        )}
      </article>

      {selectedSector?.is_discovered && selectedSector.content_type === 'settlement' && (
        <SettlementShop
          characterId={characterId}
          sectorId={selectedSector.id}
          onProgressChanged={onProgressChanged}
          onInventoryChanged={onInventoryChanged}
        />
      )}
    </section>
  )
}
