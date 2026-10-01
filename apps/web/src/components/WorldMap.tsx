import { userFacingError } from '../lib/userError'
import { memo, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useActionGate } from '../lib/actionGate'
import { supabase } from '../lib/supabase'
import { useSmartRefresh } from '../lib/smartRefresh'
import { SettlementShop } from './SettlementShop'
import { CampPanel } from './CampPanel'
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

type WorldBossFeaturedLoot = {
  slug: string
  name: string
  description: string
  rarity: string
  required_level: number
  chance_percent: number
  craft_cost: number
  unique_property_name: string | null
  unique_property_description: string | null
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
    scheduled?: boolean
    world_boss?: boolean
    spawn_policy?: string
  }
  reward_name: string | null
  reward_description: string | null
  reward_material_name: string | null
  reward_material_quantity: number
  featured_loot: WorldBossFeaturedLoot[]
  reward_gold: number
  reward_experience: number
  victories: number
  defeated: boolean
  solo_only: boolean
  run_id: string | null
  run_status: 'active' | 'completed' | 'abandoned' | null
  encounter_id: string | null
  encounter_status: 'active' | 'victory' | 'defeat' | 'cancelled' | null
  character_busy: boolean
}

type HuntingState = {
  region_key: string | null
  pressure: number
  locked_until: string | null
  active: boolean
  next_pressure: number
  next_monster_chance: number
  resource_chance: number
  duration_seconds: number
  active_hunt: {
    attempt_id: string
    sector_id: number
    region_key: string
    pressure: number
    monster_chance: number
    focus: string
    started_at: string
    finishes_at: string
    ready: boolean
  } | null
  last_result: {
    attempt_id: string
    sector_id: number
    result: string
    resolved_at: string | null
    item_name: string | null
    quantity: number
    enemy_name: string | null
  } | null
}

type HuntResult = {
  result: 'pending' | 'resource' | 'tracks' | 'monster'
  attempt_id: string
  pressure: number
  monster_chance: number
  region_key?: string
  finishes_at?: string
  item_name?: string
  quantity?: number
  resource_type?: string
  hunting_table_bonus?: number
  enemy_name?: string
  run_id?: string
  encounter_id?: string
  experience?: number
}

type WorldAnomaly = {
  event_id: string
  event_slug: string
  boss_name: string
  title: string
  description: string
  sector_id: number
  grid_col: number
  grid_row: number
  starts_at: string
  ends_at: string
}

type WorldMarker = {
  id: string
  kind: 'treasure' | 'camp' | 'merchant' | 'quest'
  sector_id: number
  title: string
  detail: string
  stage?: number
  total_stages?: number
  risk_level?: number
  ends_at?: string
  camp_owner_character_id?: string
  is_own?: boolean
  access_mode?: 'private' | 'party' | 'open'
  camp_level?: number
}

type ActivityBlocker = {
  kind: string
  title: string
  detail: string
  sector_id: number | null
  ends_at: string | null
}

type SectorIncursion = {
  event_id: string
  name: string
  description: string
  sector_id: number
  grid_col: number
  grid_row: number
  ends_at: string
  enemy_level: number
  enemy_hp: number
  enemy_attack: number
  enemy_defense: number
  clear_count: number
  clear_target: number
  contributed: boolean
  party_id: string | null
  party_member_count: number
  is_party_leader: boolean
  solo_run_id: string | null
  solo_run_status: 'active' | 'completed' | 'abandoned' | null
  party_run_id: string | null
  party_run_status: 'active' | 'completed' | 'abandoned' | null
  character_busy: boolean
}

type ExplorationSpeedState = {
  speed_percent: number
  religion_percent: number
  accessory_percent: number
  sector_seconds: number
  ruins_seconds: number
  dungeon_scout_seconds: number
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
  huntingState: HuntingState | null
  incursions: SectorIncursion[]
  anomalies: WorldAnomaly[]
  worldMarkers: WorldMarker[]
  activityBlocker: ActivityBlocker | null
  explorationSpeed: ExplorationSpeedState
}

const worldMapCache = new Map<string, WorldMapCacheEntry>()

const TOTAL_SECTORS = 300
const BASE_EXPLORATION_SECONDS = 4 * 60 * 60

function formatDuration(seconds: number) {
  const totalMinutes = Math.max(1, Math.ceil(seconds / 60))
  const hours = Math.floor(totalMinutes / 60)
  const minutes = totalMinutes % 60
  if (hours === 0) return `${minutes} мин`
  if (minutes === 0) return `${hours} ч`
  return `${hours} ч ${minutes} мин`
}
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

const ruinsResultLabels: Record<string, string> = {
  material_cache: 'тайник',
  supplies: 'припасы',
  lost_knowledge: 'знание',
  relic_fragment: 'реликвия',
  sealed_reliquary: 'реликварий',
  ancient_equipment: 'древняя экипировка',
}

function ruinsBaseRewardRange(danger: number | null) {
  const value = Math.max(0, Math.min(10, danger ?? 0))
  return {
    goldMin: 20 + value * 10,
    goldMax: 30 + value * 12,
    experienceMin: 25 + value * 18,
    experienceMax: 40 + value * 21,
  }
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
  incursionCount,
  anomalyCount,
  worldMarkers,
  onSelect,
}: {
  sector: CharacterMapSector
  active: boolean
  awaitingEvent: boolean
  selected: boolean
  showGameplayOverlay: boolean
  deathSpiritCount: number
  strongEnemyCount: number
  incursionCount: number
  anomalyCount: number
  worldMarkers: WorldMarker[]
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
    incursionCount > 0 ? 'has-sector-incursion' : '',
    anomalyCount > 0 ? 'has-world-anomaly' : '',
    worldMarkers.length > 0 ? 'has-world-marker' : '',
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
      {showGameplayOverlay && incursionCount > 0 && (
        <span
          className="sector-incursion-mark"
          title={incursionCount > 1 ? `Захваченные события: ${incursionCount}` : 'Захваченный сектор'}
          aria-label={incursionCount > 1 ? `Захваченные события: ${incursionCount}` : 'Захваченный сектор'}
        >
          !
        </span>
      )}
      {showGameplayOverlay && anomalyCount > 0 && (
        <span
          className="sector-world-anomaly-mark"
          title={anomalyCount > 1 ? `Предвестники мировых угроз: ${anomalyCount}` : 'Предвестник мировой угрозы'}
          aria-label={anomalyCount > 1 ? `Предвестники мировых угроз: ${anomalyCount}` : 'Предвестник мировой угрозы'}
        >
          ✦
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
      {showGameplayOverlay && worldMarkers.length > 0 && (() => {
        const primary = worldMarkers[0]
        const symbol = primary.kind === 'treasure'
          ? '×'
          : primary.kind === 'camp'
            ? '⌂'
            : primary.kind === 'merchant'
              ? '¤'
              : '?'
        const label = worldMarkers.map((entry) => entry.title).join(' · ')
        return (
          <span
            className={'sector-world-marker-mark marker-' + primary.kind}
            title={label}
            aria-label={label}
          >
            {symbol}{worldMarkers.length > 1 ? worldMarkers.length : ''}
          </span>
        )
      })()}
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
  const [huntingState, setHuntingState] = useState<HuntingState | null>(() => cachedMap?.huntingState ?? null)
  const [incursions, setIncursions] = useState<SectorIncursion[]>(() => cachedMap?.incursions ?? [])
  const [anomalies, setAnomalies] = useState<WorldAnomaly[]>(() => cachedMap?.anomalies ?? [])
  const [worldMarkers, setWorldMarkers] = useState<WorldMarker[]>(() => cachedMap?.worldMarkers ?? [])
  const [activityBlocker, setActivityBlocker] = useState<ActivityBlocker | null>(() => cachedMap?.activityBlocker ?? null)
  const [explorationSpeed, setExplorationSpeed] = useState<ExplorationSpeedState>(
    () => cachedMap?.explorationSpeed ?? {
      speed_percent: 0,
      religion_percent: 0,
      accessory_percent: 0,
      sector_seconds: BASE_EXPLORATION_SECONDS,
      ruins_seconds: 2 * 60 * 60,
      dungeon_scout_seconds: 60 * 60,
    },
  )
  const [selectedSectorId, setSelectedSectorId] = useState<number | null>(null)
  const [loading, setLoading] = useState(() => !cachedMap)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  const { beginAction, endAction } = useActionGate(setBusy, false, setMessage)
  const [mapSrc, setMapSrc] = useState(ORIGINAL_MAP_URL)
  const [showGameplayOverlay, setShowGameplayOverlay] = useState(true)
  const [mapZoom, setMapZoom] = useState(initialMapZoom)
  const mapFrameRef = useRef<HTMLDivElement | null>(null)
  const mapCenteredRef = useRef(false)
  const siteRewardNotifiedRef = useRef<string | null>(
    cachedMap?.siteActions.find(
      (entry) => entry.status === 'completed' && entry.action_type === 'explore_ruins',
    )?.id ?? null,
  )
  const expeditionRewardNotifiedRef = useRef<string | null>(
    cachedMap?.results[0]?.id ?? null,
  )

  async function loadMapData(silent = false) {
    if (!silent) {
      setLoading(true)
      setMessage('')
    }

    const [
      mapResult,
      explorationSpeedResult,
      expeditionResult,
      eventResult,
      resultResult,
      siteActionResult,
      siteProgressResult,
      dungeonRunResult,
      deathSpiritResult,
      strongEnemyResult,
      huntingStateResult,
      incursionResult,
      anomalyResult,
      worldMarkerResult,
      activityJournalResult,
    ] = await Promise.all([
      supabase.rpc('get_character_map_state', {
        p_character_id: characterId,
      }),
      supabase.rpc('get_character_exploration_speed', {
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
        .select('id, character_id, sector_id, action_type, status, started_at, ends_at, completed_at, result_title, result_text, result_kind, reward_gold, reward_experience, reward_items, created_at')
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
      supabase.rpc('get_visible_world_strong_enemies_v2', {
        p_character_id: characterId,
      }),
      supabase.rpc('get_character_hunting_state_v2', {
        p_character_id: characterId,
      }),
      supabase.rpc('get_visible_sector_incursions', {
        p_character_id: characterId,
      }),
      supabase.rpc('get_visible_world_anomalies', {
        p_character_id: characterId,
      }),
      supabase.rpc('get_character_world_markers_v2', {
        p_character_id: characterId,
      }),
      supabase.rpc('get_character_activity_journal_v2', {
        p_character_id: characterId,
      }),
    ])

    const error =
      mapResult.error ??
      explorationSpeedResult.error ??
      expeditionResult.error ??
      eventResult.error ??
      resultResult.error ??
      siteActionResult.error ??
      siteProgressResult.error ??
      dungeonRunResult.error ??
      deathSpiritResult.error ??
      strongEnemyResult.error ??
      huntingStateResult.error ??
      incursionResult.error ??
      anomalyResult.error ??
      worldMarkerResult.error ??
      activityJournalResult.error

    if (error) {
      if (!silent) setMessage(userFacingError(error.message, 'Не удалось обновить карту.'))
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
      huntingState: (huntingStateResult.data as HuntingState | null) ?? null,
      incursions: (incursionResult.data as SectorIncursion[] | null) ?? [],
      anomalies: (anomalyResult.data as WorldAnomaly[] | null) ?? [],
      worldMarkers: (worldMarkerResult.data as WorldMarker[] | null) ?? [],
      activityBlocker: ((activityJournalResult.data as { blocker?: ActivityBlocker | null } | null)?.blocker ?? null),
      explorationSpeed: ((explorationSpeedResult.data as ExplorationSpeedState[] | null) ?? [])[0] ?? {
        speed_percent: 0,
        religion_percent: 0,
        accessory_percent: 0,
        sector_seconds: BASE_EXPLORATION_SECONDS,
        ruins_seconds: 2 * 60 * 60,
        dungeon_scout_seconds: 60 * 60,
      },
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
    setHuntingState(nextCache.huntingState)
    setIncursions(nextCache.incursions)
    setAnomalies(nextCache.anomalies)
    setWorldMarkers(nextCache.worldMarkers)
    setActivityBlocker(nextCache.activityBlocker)
    setExplorationSpeed(nextCache.explorationSpeed)
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

  useEffect(() => {
    if (!huntingState?.active || !huntingState.locked_until) return
    const delay = Math.max(0, new Date(huntingState.locked_until).getTime() - Date.now() + 500)
    const timeout = window.setTimeout(() => {
      void loadMapData(true)
    }, delay)
    return () => window.clearTimeout(timeout)
  }, [huntingState?.active, huntingState?.locked_until])

  useEffect(() => {
    if (!huntingState?.active_hunt?.finishes_at || huntingState.active_hunt.ready) return
    const delay = Math.max(0, new Date(huntingState.active_hunt.finishes_at).getTime() - Date.now() + 500)
    const timeout = window.setTimeout(() => {
      void loadMapData(true)
    }, delay)
    return () => window.clearTimeout(timeout)
  }, [huntingState?.active_hunt?.attempt_id, huntingState?.active_hunt?.finishes_at, huntingState?.active_hunt?.ready])

  useEffect(() => {
    if (incursions.length === 0) return
    const nextExpiry = Math.min(...incursions.map((entry) => new Date(entry.ends_at).getTime()))
    const delay = Math.max(0, nextExpiry - Date.now() + 500)
    const timeout = window.setTimeout(() => {
      void loadMapData(true)
    }, delay)
    return () => window.clearTimeout(timeout)
  }, [incursions])

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

  const incursionsBySector = useMemo(() => {
    const grouped = new Map<number, SectorIncursion[]>()
    for (const incursion of incursions) {
      const entries = grouped.get(incursion.sector_id) ?? []
      entries.push(incursion)
      grouped.set(incursion.sector_id, entries)
    }
    return grouped
  }, [incursions])

  const anomaliesBySector = useMemo(() => {
    const grouped = new Map<number, WorldAnomaly[]>()
    for (const anomaly of anomalies) {
      const entries = grouped.get(anomaly.sector_id) ?? []
      entries.push(anomaly)
      grouped.set(anomaly.sector_id, entries)
    }
    return grouped
  }, [anomalies])

  const worldMarkersBySector = useMemo(() => {
    const grouped = new Map<number, WorldMarker[]>()
    for (const marker of worldMarkers) {
      const entries = grouped.get(marker.sector_id) ?? []
      entries.push(marker)
      grouped.set(marker.sector_id, entries)
    }
    return grouped
  }, [worldMarkers])

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

  const anyBlockingActivity = Boolean(activityBlocker || openExpedition || activeSiteAction || activeDungeonRun)
  const blockingReason = activityBlocker
    ? activityBlocker.title + ': ' + activityBlocker.detail
    : activeDungeonRun
      ? 'Сначала заверши текущее подземелье.'
      : activeSiteAction
        ? 'Сначала заверши текущее исследование найденного места.'
        : openExpedition
          ? 'Сначала заверши текущую экспедицию.'
          : ''

  useEffect(() => {
    if (
      !recentSiteResult ||
      recentSiteResult.action_type !== 'explore_ruins' ||
      recentSiteResult.id === siteRewardNotifiedRef.current
    ) return

    siteRewardNotifiedRef.current = recentSiteResult.id
    void Promise.resolve(onProgressChanged?.())
    void Promise.resolve(onInventoryChanged?.())
  }, [recentSiteResult?.id, recentSiteResult?.action_type, onProgressChanged, onInventoryChanged])

  useEffect(() => {
    if (!latestResult || latestResult.id === expeditionRewardNotifiedRef.current) return

    expeditionRewardNotifiedRef.current = latestResult.id
    if (latestResult.source === 'random_event' || latestResult.source === 'gm_event') {
      void Promise.resolve(onProgressChanged?.())
      void Promise.resolve(onInventoryChanged?.())
    }
  }, [latestResult?.id, latestResult?.source, onProgressChanged, onInventoryChanged])

  const selectedSector = selectedSectorId
    ? sectorById.get(selectedSectorId) ?? null
    : null

  const selectedDeathSpirits = selectedSector
    ? deathSpiritsBySector.get(selectedSector.id) ?? []
    : []

  const selectedStrongEnemies = selectedSector
    ? strongEnemiesBySector.get(selectedSector.id) ?? []
    : []

  const selectedIncursions = selectedSector
    ? incursionsBySector.get(selectedSector.id) ?? []
    : []
  const selectedAnomalies = selectedSector
    ? anomaliesBySector.get(selectedSector.id) ?? []
    : []
  const selectedWorldMarkers = selectedSector
    ? worldMarkersBySector.get(selectedSector.id) ?? []
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

    if (!beginAction(true)) return
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
        setMessage(userFacingError(raw))
      }

      endAction()
      return
    }

    await loadMapData()
    setMessage('Экспедиция отменена. Можно выбрать другой сектор.')
    endAction()
  }

  async function startExploration() {
    if (!selectedSector?.is_explorable) return

    if (!beginAction(true)) return
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
        setMessage(userFacingError(raw))
      }

      endAction()
      return
    }

    setSelectedSectorId(null)
    await loadMapData()
    endAction()
  }

  async function cancelSiteAction(actionId: string) {
    if (!window.confirm('Отменить это исследование? Уже прошедшее время будет потеряно.')) return

    if (!beginAction(true)) return
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
        setMessage(userFacingError(raw))
      }
      endAction()
      return
    }

    await loadMapData()
    setMessage('Исследование отменено.')
    endAction()
  }

  async function startSiteAction(actionType: 'explore_ruins' | 'scout_dungeon') {
    if (!selectedSector?.is_discovered) return

    if (!beginAction(true)) return
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
        setMessage(userFacingError(raw))
      }

      endAction()
      return
    }

    await loadMapData()
    if (actionType === 'explore_ruins') {
      setMessage('Исследование руин начато. По завершении будут выданы золото, опыт и случайная находка.')
    }
    endAction()
  }

  async function startHunt() {
    if (!selectedSector?.is_discovered || selectedSector.content_type !== 'wilderness') return

    if (!beginAction(true)) return
    setMessage('')

    const { data, error } = await supabase.rpc('start_hunt_v2', {
      p_character_id: characterId,
      p_sector_id: selectedSector.id,
      p_focus: 'general',
    })

    if (error) {
      const raw = error.message
      if (raw.includes('HUNT_REGION_LOCKED')) {
        setMessage('Серия охоты уже привязана к другому региону. Дождись, пока 12-часовой след охоты остынет.')
      } else if (raw.includes('SECTOR_CAPTURED')) {
        setMessage('Сектор захвачен сильными противниками. Сначала его нужно зачистить.')
      } else if (raw.includes('CHARACTER_BUSY')) {
        setMessage('Персонаж занят другим боем, походом или исследованием.')
      } else if (raw.includes('HUNT_NOT_AVAILABLE_AT_SEA')) {
        setMessage('В морском секторе обычная охота недоступна.')
      } else {
        setMessage(userFacingError(raw))
      }
      endAction()
      return
    }

    const result = data as HuntResult
    await loadMapData(true)
    setMessage(
      `Охота началась · 10 минут. Давление региона: ${result.pressure}/6`
      + (result.monster_chance > 0 ? ` · шанс сильного монстра ${result.monster_chance}%` : '')
      + '.',
    )
    endAction()
  }

  async function finishHunt() {
    const activeHunt = huntingState?.active_hunt
    if (!activeHunt) return
    if (!beginAction(true)) return
    setMessage('')

    const { data, error } = await supabase.rpc('finish_hunt_v2', {
      p_character_id: characterId,
      p_attempt_id: activeHunt.attempt_id,
    })

    if (error) {
      setMessage(
        error.message.includes('HUNT_NOT_READY')
          ? 'Охота ещё не завершилась.'
          : userFacingError(error.message),
      )
      endAction()
      return
    }

    const result = data as HuntResult
    await loadMapData(true)

    if (result.result === 'resource') {
      await Promise.resolve(onInventoryChanged?.())
      setMessage(
        `Охота завершена: ${result.item_name ?? 'ресурс'} ×${result.quantity ?? 1}`
        + (result.hunting_table_bonus ? ' · охотничий стол дал +1 добычу' : '')
        + '.',
      )
      endAction()
      return
    }

    if (result.result === 'tracks') {
      await Promise.resolve(onProgressChanged?.())
      setMessage(`Добыча ушла, но выслеживание дало +${result.experience ?? 0} опыта.`)
      endAction()
      return
    }

    await Promise.resolve(onProgressChanged?.())
    setMessage(`Следы привели к сильному противнику: ${result.enemy_name ?? 'неизвестный зверь'}.`)
    endAction()
    onOpenBattles?.()
  }

  async function startSectorIncursion(incursion: SectorIncursion, mode: 'solo' | 'party') {
    const runActive = mode === 'solo'
      ? incursion.solo_run_status === 'active'
      : incursion.party_run_status === 'active'

    if (runActive) {
      onOpenBattles?.()
      return
    }

    if (!beginAction(true)) return
    setMessage('')

    const { error } = await supabase.rpc('start_event_boss', {
      p_character_id: characterId,
      p_event_id: incursion.event_id,
      p_mode: mode,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('EVENT_BOSS_CHARACTER_LIMIT_REACHED')) {
        setMessage('Твой личный вклад в зачистку этого сектора уже засчитан.')
      } else if (raw.includes('SECTOR_INCURSION_PARTY_NO_NEW_CONTRIBUTORS')) {
        setMessage('У всех участников этой пати вклад уже засчитан. Нужен хотя бы один новый персонаж.')
      } else if (raw.includes('PARTY_NOT_FOUND')) {
        setMessage('Для групповой зачистки сначала создай пати.')
      } else if (raw.includes('PARTY_LEADER_REQUIRED')) {
        setMessage('Групповую зачистку запускает лидер пати.')
      } else if (raw.includes('PARTY_NEEDS_TWO_MEMBERS')) {
        setMessage('Для групповой зачистки нужно минимум 2 персонажа.')
      } else if (raw.includes('PARTY_MEMBER_SECTOR_NOT_DISCOVERED')) {
        setMessage('У одного из участников пати этот сектор ещё не открыт.')
      } else if (raw.includes('EVENT_BOSS_NOT_ACTIVE')) {
        setMessage('Сектор уже освобождён или событие закончилось.')
      } else if (raw.includes('CHARACTER_BUSY') || raw.includes('PARTY_MEMBER_BUSY')) {
        setMessage('Один из участников сейчас занят другим тяжёлым действием.')
      } else {
        setMessage(userFacingError(raw))
      }
      endAction()
      return
    }

    await Promise.all([
      loadMapData(true),
      Promise.resolve(onProgressChanged?.()),
    ])
    endAction()
    onOpenBattles?.()
  }

  async function startWorldStrongEnemy(enemy: WorldStrongEnemy, mode: 'solo' | 'party') {
    if (mode === 'solo' && enemy.run_status === 'active') {
      onOpenBattles?.()
      return
    }

    if (!beginAction(true)) return
    setMessage('')

    const { error } = await supabase.rpc('start_event_boss', {
      p_character_id: characterId,
      p_event_id: enemy.event_id,
      p_mode: mode,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('EVENT_BOSS_NOT_ACTIVE')) {
        setMessage('Это мировое событие уже закончилось.')
      } else if (raw.includes('EVENT_BOSS_SECTOR_NOT_DISCOVERED')) {
        setMessage('Сначала нужно открыть сектор с этим противником.')
      } else if (raw.includes('PARTY_MEMBER_SECTOR_NOT_DISCOVERED')) {
        setMessage('У одного из участников пати этот сектор ещё не открыт.')
      } else if (raw.includes('PARTY_NOT_FOUND')) {
        setMessage('Для группового боя сначала создай пати.')
      } else if (raw.includes('PARTY_LEADER_REQUIRED')) {
        setMessage('Групповой бой с мировым боссом запускает лидер пати.')
      } else if (raw.includes('PARTY_NEEDS_TWO_MEMBERS')) {
        setMessage('Для группового боя нужно минимум 2 персонажа.')
      } else if (raw.includes('PARTY_TOO_LARGE')) {
        setMessage('В бой с мировым боссом можно войти группой максимум из 4 персонажей.')
      } else if (raw.includes('PARTY_DUNGEON_ALREADY_ACTIVE')) {
        setMessage('У этой пати уже идёт другой групповой бой.')
      } else if (raw.includes('PARTY_MEMBER_BUSY')) {
        setMessage('Один из участников пати занят другим тяжёлым действием.')
      } else if (raw.includes('CHARACTER_BUSY') || raw.includes('DUNGEON_RUN_ALREADY_ACTIVE')) {
        setMessage('Персонаж уже занят другим боем или исследованием.')
      } else if (raw.includes('PVP_DUEL_ACTIVE')) {
        setMessage('Сначала заверши активную дуэль.')
      } else if (raw.includes('CHARACTER_HAS_NO_HP') || raw.includes('PARTY_MEMBER_HAS_NO_HP')) {
        setMessage('Перед боем всем участникам нужно восстановить хотя бы часть ОЗ.')
      } else {
        setMessage(userFacingError(raw))
      }
      endAction()
      return
    }

    await Promise.all([
      loadMapData(true),
      Promise.resolve(onProgressChanged?.()),
    ])
    endAction()
    onOpenBattles?.()
  }

  async function startDeathSpiritCombat(spirit: DeathSpiritMapEntry) {
    if (!beginAction(true)) return
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
        setMessage(userFacingError(raw))
      }
      endAction()
      return
    }

    await loadMapData(true)
    setMessage('Бой с духом начат. Продолжай его в разделе «Бои».')
    endAction()
  }

  async function enterDungeon() {
    if (!selectedSector?.is_discovered) return

    if (!beginAction(true)) return
    setMessage('')

    const { data: runData, error } = await supabase.rpc('start_dungeon_run', {
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
        setMessage('Ты уже находишься в групповом походе.')
      } else {
        setMessage(userFacingError(raw))
      }

      endAction()
      return
    }

    const createdRun = runData as { id: string } | null
    if (!createdRun?.id) {
      setMessage('Не удалось открыть первый зал подземелья.')
      endAction()
      return
    }

    const { error: combatError } = await supabase.rpc('start_dungeon_combat', {
      p_run_id: createdRun.id,
    })

    if (combatError) {
      const raw = combatError.message
      if (raw.includes('PVP_DUEL_ACTIVE')) {
        setMessage('Сначала заверши активную дуэль.')
      } else if (raw.includes('COMBAT_ALREADY_ACTIVE')) {
        setMessage('В этом подземелье уже идёт бой.')
      } else if (raw.includes('CHARACTER_HAS_NO_HP')) {
        setMessage('У персонажа нет здоровья для начала боя.')
      } else {
        setMessage(userFacingError(raw))
      }

      await loadMapData(true)
      endAction()
      return
    }

    endAction()
    onOpenBattles?.()
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
            {TOTAL_SECTORS} секторов. Текущая скорость: {explorationSpeed.speed_percent > 0 ? `+${explorationSpeed.speed_percent}%` : 'без бонуса'}.
            Сектор — {formatDuration(explorationSpeed.sector_seconds)}, руины — {formatDuration(explorationSpeed.ruins_seconds)},
            разведка подземелья — {formatDuration(explorationSpeed.dungeon_scout_seconds)}.
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
              Сектор #{activeDungeonRun.sector_id}. Управление прохождением находится в «Бои → Сейчас».
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
        <article className={'panel expedition-result-card site-result-card ' + (recentSiteResult.action_type === 'explore_ruins' ? 'ruins-result-card' : '')}>
          <div>
            <span className="eyebrow">
              {recentSiteResult.action_type === 'explore_ruins' ? 'РУИНЫ ИССЛЕДОВАНЫ' : 'ВХОД РАЗВЕДАН'}
            </span>
            <h3>{recentSiteResult.result_title}</h3>
            <p>{recentSiteResult.result_text}</p>
            {recentSiteResult.action_type === 'explore_ruins' && (
              <div className="ruins-reward-summary">
                <span>+{recentSiteResult.reward_gold} золота</span>
                <span>+{recentSiteResult.reward_experience} опыта</span>
                {(recentSiteResult.reward_items ?? []).map((item) => (
                  <span className={'rarity-' + item.rarity} key={item.item_definition_id}>
                    {item.name} ×{item.quantity}
                  </span>
                ))}
              </div>
            )}
          </div>
          <span className="badge">
            {recentSiteResult.action_type === 'explore_ruins'
              ? ruinsResultLabels[recentSiteResult.result_kind] ?? 'исследовано'
              : 'доступен вход'}
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
            <span className="map-legend-item sector-incursion">
              <span className="map-legend-icon sector-incursion">!</span>
              Захваченный сектор
            </span>
            <span className="map-legend-item world-anomaly">
              <span className="map-legend-icon world-anomaly">✦</span>
              Предвестник мировой угрозы
            </span>
            <span className="map-legend-item death-spirit">
              <span className="map-legend-icon death-spirit">☠</span>
              Дух погибшего
            </span>
            <span className="map-legend-item world-marker">
              <span className="map-legend-icon world-marker">◆</span>
              Цель, лагерь или торговец
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
                incursionCount={incursionsBySector.get(sector.id)?.length ?? 0}
                anomalyCount={anomaliesBySector.get(sector.id)?.length ?? 0}
                worldMarkers={worldMarkersBySector.get(sector.id) ?? []}
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

            {selectedWorldMarkers.length > 0 && (
              <div className="world-marker-list">
                {selectedWorldMarkers.map((marker) => (
                  <div className={'world-marker-card marker-' + marker.kind} key={marker.kind + ':' + marker.id}>
                    <div>
                      <span className="eyebrow">
                        {marker.kind === 'treasure'
                          ? 'КАРТА СОКРОВИЩ'
                          : marker.kind === 'camp'
                            ? 'ЛАГЕРЬ'
                            : marker.kind === 'merchant'
                              ? 'СТРАНСТВУЮЩИЙ ТОРГОВЕЦ'
                              : 'ПОРУЧЕНИЕ'}
                      </span>
                      <strong>{marker.title}</strong>
                    </div>
                    <p>{marker.detail}</p>
                    {marker.kind === 'treasure' && marker.total_stages && (
                      <small>Этап {marker.stage ?? 1}/{marker.total_stages} · риск {marker.risk_level ?? 0}/3</small>
                    )}
                    {marker.ends_at && <small>Действует до {new Date(marker.ends_at).toLocaleString('ru-RU')}</small>}
                  </div>
                ))}
              </div>
            )}

            {selectedAnomalies.length > 0 && (
              <div className="world-anomaly-list">
                {selectedAnomalies.map((anomaly) => (
                  <div className="world-anomaly-card" key={anomaly.event_id + ':' + anomaly.sector_id}>
                    <div className="world-anomaly-head">
                      <div>
                        <span className="eyebrow">ПРЕДВЕСТНИК МИРОВОЙ УГРОЗЫ</span>
                        <strong>{anomaly.title}</strong>
                      </div>
                      <span className="badge">
                        через <Countdown endsAt={anomaly.starts_at} />
                      </span>
                    </div>
                    <p>{anomaly.description}</p>
                    <small>
                      Мир пока не называет источник прямо. Временная аномалия исчезнет, когда мировая угроза начнётся.
                    </small>
                  </div>
                ))}
              </div>
            )}

            {selectedIncursions.length > 0 && (
              <div className="sector-incursion-list">
                {selectedIncursions.map((incursion) => {
                  const soloActive = incursion.solo_run_status === 'active'
                  const partyActive = incursion.party_run_status === 'active'
                  const canPartyStart = Boolean(
                    incursion.party_id
                    && incursion.is_party_leader
                    && incursion.party_member_count >= 2
                    && incursion.party_member_count <= 4,
                  )

                  return (
                    <div className="sector-incursion-card" key={incursion.event_id}>
                      <div className="sector-incursion-head">
                        <div>
                          <span className="eyebrow">ЗАХВАЧЕННЫЙ СЕКТОР</span>
                          <strong>{incursion.name}</strong>
                          <small>Исчезнет через <Countdown endsAt={incursion.ends_at} /></small>
                        </div>
                        <span className="badge">
                          {incursion.clear_count} / {incursion.clear_target}
                        </span>
                      </div>

                      <p>{incursion.description}</p>

                      <div className="sector-incursion-progress" aria-label="Прогресс глобальной зачистки">
                        <span
                          style={{
                            width: Math.min(100, Math.round((incursion.clear_count / Math.max(1, incursion.clear_target)) * 100)) + '%',
                          }}
                        />
                      </div>

                      <div className="world-strong-enemy-stats">
                        <span><small>Уровень</small><b>{incursion.enemy_level}</b></span>
                        <span><small>ОЗ</small><b>{incursion.enemy_hp}</b></span>
                        <span><small>Атака</small><b>{incursion.enemy_attack}</b></span>
                        <span><small>Защита</small><b>{incursion.enemy_defense}</b></span>
                      </div>

                      <div className="sector-incursion-note">
                        <strong>{incursion.contributed ? 'Твой вклад уже засчитан' : 'Твой вклад ещё доступен'}</strong>
                        <span>
                          За личный засчитанный вклад: 100 опыта и 50 золота.
                          Когда сектор будет полностью освобождён, каждый участник с засчитанным вкладом дополнительно получит 150 опыта и 50 золота.
                          Каждый персонаж увеличивает глобальный счётчик максимум один раз; повторный вклад не даёт повторную награду.
                        </span>
                      </div>

                      <div className="sector-incursion-actions">
                        <button
                          className="primary-button"
                          type="button"
                          disabled={
                            busy
                            || (!soloActive && (incursion.contributed || incursion.character_busy))
                          }
                          onClick={() => void startSectorIncursion(incursion, 'solo')}
                        >
                          {soloActive
                            ? 'Продолжить соло-бой'
                            : incursion.contributed
                              ? 'Вклад уже засчитан'
                              : incursion.character_busy
                                ? 'Персонаж занят'
                                : 'Зачистить соло'}
                        </button>

                        <button
                          className="ghost-button"
                          type="button"
                          disabled={
                            busy
                            || (!partyActive && (!canPartyStart || incursion.character_busy))
                          }
                          onClick={() => void startSectorIncursion(incursion, 'party')}
                        >
                          {partyActive
                            ? 'Продолжить бой пати'
                            : !incursion.party_id
                              ? 'Сначала создай пати'
                              : !incursion.is_party_leader
                                ? 'Запускает лидер'
                                : incursion.party_member_count < 2
                                  ? 'Нужно 2+'
                                  : incursion.character_busy
                                    ? 'Персонаж занят'
                                    : `Зачистить пати · ${incursion.party_member_count}/4`}
                        </button>
                      </div>
                    </div>
                  )
                })}
              </div>
            )}

            {selectedSector.content_type === 'wilderness' && selectedSector.terrain_type !== 'sea' && (() => {
              const captured = selectedIncursions.length > 0
              const lockedElsewhere = Boolean(
                huntingState?.active
                && huntingState.region_key
                && huntingState.region_key !== selectedSector.terrain_type,
              )
              const sameRegion = Boolean(
                huntingState?.active
                && huntingState.region_key === selectedSector.terrain_type,
              )
              const nextPressure = sameRegion ? huntingState?.next_pressure ?? 1 : 1
              const nextMonsterChance = sameRegion ? huntingState?.next_monster_chance ?? 0 : 0
              const resourceChance = nextPressure >= 6 ? 0 : huntingState?.resource_chance ?? 70
              const activeHunt = huntingState?.active_hunt ?? null
              const selectedCampMarker = selectedWorldMarkers.find((entry) => entry.kind === 'camp') ?? null

              return (
                <div className="hunting-card">
                  <div className="hunting-card-head">
                    <div>
                      <span className="eyebrow">ОХОТА · 10 МИНУТ</span>
                      <strong>{terrainLabels[selectedSector.terrain_type ?? 'unassigned'] ?? selectedSector.terrain_type}</strong>
                    </div>
                    <span className={'badge ' + (nextPressure >= 6 ? 'danger' : '')}>
                      давление {sameRegion ? huntingState?.pressure ?? 0 : 0}/6
                    </span>
                  </div>

                  <p>
                    Охота больше не разрешается мгновенно. После 10 минут ты явно получишь результат:
                    региональный ресурс, опыт за следы или встречу с сильным противником.
                  </p>

                  <div className="hunting-pressure-grid">
                    <span><small>Следующая охота</small><b>{nextPressure}/6</b></span>
                    <span><small>Ресурс после выслеживания</small><b>{resourceChance}%</b></span>
                    <span><small>Сильный монстр</small><b>{nextMonsterChance}%</b></span>
                  </div>

                  {huntingState?.active && huntingState.locked_until && (
                    <div className={'hunting-region-lock ' + (lockedElsewhere ? 'blocked' : '')}>
                      <strong>
                        Серия привязана: {terrainLabels[huntingState.region_key ?? 'unassigned'] ?? huntingState.region_key}
                      </strong>
                      <span>
                        Сменить регион можно через <Countdown endsAt={huntingState.locked_until} />.
                        Каждая новая охота снова продлевает след региона на 12 часов.
                      </span>
                    </div>
                  )}

                  {nextPressure >= 6 && !lockedElsewhere && (
                    <div className="hunting-danger-note">
                      <strong>Регион перегрет охотой</strong>
                      <span>На 6/6 следующая охота гарантированно приводит к сильному монстру.</span>
                    </div>
                  )}

                  {captured && (
                    <div className="hunting-danger-note">
                      <strong>Охота заблокирована</strong>
                      <span>Этот сектор сейчас захвачен. Сначала освободи его через событие выше.</span>
                    </div>
                  )}

                  {activeHunt ? (
                    <div className="hunting-active-run">
                      <div>
                        <span className="eyebrow">ОХОТНИК В ПУТИ</span>
                        <strong>Сектор #{activeHunt.sector_id} · давление {activeHunt.pressure}/6</strong>
                        <small>
                          {activeHunt.ready
                            ? 'Охота завершена. Результат уже можно забрать.'
                            : <>Возвращение через <Countdown endsAt={activeHunt.finishes_at} /></>}
                        </small>
                      </div>
                      <button
                        className="primary-button"
                        type="button"
                        disabled={busy || !activeHunt.ready}
                        onClick={() => void finishHunt()}
                      >
                        {activeHunt.ready ? 'Забрать результат охоты' : 'Охота идёт'}
                      </button>
                    </div>
                  ) : (
                    <button
                      className="primary-button"
                      type="button"
                      disabled={busy || anyBlockingActivity || captured || lockedElsewhere}
                      title={anyBlockingActivity ? blockingReason : captured ? 'Сначала освободи сектор.' : lockedElsewhere ? 'Охотничья серия привязана к другому региону.' : ''}
                      onClick={() => void startHunt()}
                    >
                      {captured
                        ? 'Сектор захвачен'
                        : lockedElsewhere
                          ? 'Привязан другой регион'
                          : anyBlockingActivity
                            ? 'Персонаж занят'
                            : nextPressure >= 6
                              ? 'Начать охоту · сильный монстр'
                              : 'Начать охоту · 10 минут'}
                    </button>
                  )}

                  <CampPanel
                    characterId={characterId}
                    sectorId={selectedSector.id}
                    campOwnerCharacterId={selectedCampMarker?.camp_owner_character_id ?? null}
                    canPlace={selectedSector.is_discovered}
                    blocked={anyBlockingActivity}
                    blockingReason={blockingReason}
                    onChanged={() => loadMapData(true)}
                    onInventoryChanged={onInventoryChanged}
                  />
                </div>
              )
            })()}

            {selectedStrongEnemies.length > 0 && (
              <div className="world-strong-enemy-list">
                {selectedStrongEnemies.map((enemy) => {
                  const scheduledWorldBoss = Boolean(enemy.mechanics?.scheduled && enemy.mechanics?.world_boss)
                  const runActive = enemy.run_status === 'active'

                  return (
                    <div className={'world-strong-enemy-card ' + (enemy.defeated ? 'defeated' : '')} key={enemy.event_id}>
                      <div className="world-strong-enemy-head">
                        <div>
                          <span className="eyebrow">
                            {scheduledWorldBoss
                              ? enemy.defeated
                                ? 'МИРОВОЙ БОСС · ПЕРВАЯ НАГРАДА ПОЛУЧЕНА'
                                : 'МИРОВОЙ БОСС · СОЛО ИЛИ ПАТИ'
                              : enemy.defeated
                                ? 'ПЕРВАЯ НАГРАДА ПОЛУЧЕНА'
                                : 'СИЛЬНЫЙ ВРАГ · СОЛО ИЛИ ПАТИ'}
                          </span>
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

                      <div className="world-strong-enemy-reward">
                        <span className="eyebrow">
                          {scheduledWorldBoss
                            ? 'ДОБЫЧА МИРОВОГО БОССА'
                            : enemy.defeated
                              ? 'ПОВТОРНЫЕ ПОБЕДЫ'
                              : 'ПЕРВАЯ ПОБЕДА'}
                        </span>

                        {scheduledWorldBoss ? (
                          <>
                            {enemy.reward_material_name && (
                              <strong>
                                Каждая победа: {enemy.reward_material_name} ×{enemy.reward_material_quantity}
                              </strong>
                            )}
                            <small>
                              {enemy.defeated
                                ? 'Золото и опыт за первую победу уже получены, но материал и шанс уникальной добычи остаются.'
                                : 'Первая победа: ' + enemy.reward_experience + ' опыта · ' + enemy.reward_gold + ' золота.'}
                            </small>
                            {enemy.featured_loot?.map((loot) => (
                              <div className="world-boss-loot-line" key={loot.slug}>
                                <b>{loot.name}</b>
                                <span>{loot.chance_percent}% сразу · гарант за {loot.craft_cost} материалов</span>
                                <small>{loot.unique_property_description || loot.description}</small>
                              </div>
                            ))}
                          </>
                        ) : enemy.defeated ? (
                          <>
                            <strong>Без золота и опыта</strong>
                            <small>Первую награду ты уже получил. Сражаться с боссом можно сколько угодно.</small>
                          </>
                        ) : (
                          <>
                            <strong>{enemy.reward_experience} опыта · {enemy.reward_gold} золота</strong>
                            {enemy.reward_name && (
                              <>
                                <small>Особая награда: {enemy.reward_name}</small>
                                {enemy.reward_description && <small>{enemy.reward_description}</small>}
                              </>
                            )}
                          </>
                        )}
                      </div>

                      <div className="world-strong-enemy-actions">
                        <button
                          className="primary-button"
                          type="button"
                          disabled={busy || (!runActive && enemy.character_busy)}
                          onClick={() => runActive ? onOpenBattles?.() : void startWorldStrongEnemy(enemy, 'solo')}
                        >
                          {runActive
                            ? 'Продолжить бой'
                            : enemy.character_busy
                              ? 'Персонаж занят'
                              : enemy.defeated
                                ? 'Сразиться снова · соло'
                                : 'Сразиться · соло'}
                        </button>
                        <button
                          className="ghost-button"
                          type="button"
                          disabled={busy || runActive || enemy.character_busy}
                          onClick={() => void startWorldStrongEnemy(enemy, 'party')}
                        >
                          {enemy.character_busy
                            ? 'Пати сейчас недоступно'
                            : enemy.defeated
                              ? 'Сразиться снова · пати 2–4'
                              : 'Сразиться · пати 2–4'}
                        </button>
                      </div>
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
              const previousResult = siteActions.find(
                (entry) =>
                  entry.sector_id === selectedSector.id &&
                  entry.action_type === 'explore_ruins' &&
                  entry.status === 'completed',
              ) ?? null
              const rewardRange = ruinsBaseRewardRange(selectedSector.danger_level)

              return (
                <div className="sector-site-actions ruins-site-actions">
                  <div className="sector-site-state">
                    <strong>Руины</strong>
                    <span>
                      {alreadyExplored
                        ? 'Полностью исследованы — награда за эти руины уже получена'
                        : thisActionActive
                          ? 'Исследование уже идёт'
                          : 'Одноразовое глубокое исследование с гарантированной наградой и случайной находкой'}
                    </span>
                  </div>

                  {!alreadyExplored && (
                    <div className="ruins-reward-preview">
                      <div>
                        <strong>Гарантировано</strong>
                        <span>
                          {rewardRange.goldMin}–{rewardRange.goldMax} золота · {rewardRange.experienceMin}–{rewardRange.experienceMax} опыта
                        </span>
                      </div>
                      <div className="ruins-chance-grid">
                        <span><b>40%</b> материалы</span>
                        <span><b>25%</b> припасы</span>
                        <span><b>17%</b> свитки</span>
                        <span><b>13%</b> осколок реликвии · опасность 3+</span>
                        <span><b>5%</b> реликварий · опасность 6+</span>
                      </div>
                      <small>
                        На низкой опасности шанс недоступной редкой находки превращается в шанс найти дополнительный свиток.
                        Более опасные руины дают больше золота и опыта, а редкие реликварии — ещё и крупный бонус сверху.
                      </small>
                    </div>
                  )}

                  {alreadyExplored && previousResult?.result_text && (
                    <div className="ruins-previous-result">
                      <span className="eyebrow">НАЙДЕНО РАНЕЕ</span>
                      <strong>{previousResult.result_title}</strong>
                      <div className="ruins-reward-summary">
                        <span>+{previousResult.reward_gold} золота</span>
                        <span>+{previousResult.reward_experience} опыта</span>
                        {(previousResult.reward_items ?? []).map((item) => (
                          <span className={'rarity-' + item.rarity} key={item.item_definition_id}>
                            {item.name} ×{item.quantity}
                          </span>
                        ))}
                      </div>
                    </div>
                  )}

                  {!alreadyExplored && !thisActionActive && (
                    <button
                      className="primary-button"
                      type="button"
                      disabled={busy || anyBlockingActivity}
                      onClick={() => void startSiteAction('explore_ruins')}
                    >
                      Исследовать руины · {formatDuration(explorationSpeed.ruins_seconds)}
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
                      Разведать вход · {formatDuration(explorationSpeed.dungeon_scout_seconds)}
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
                  ? blockingReason || 'Сначала заверши текущее действие.'
                  : 'Пока слишком далеко от изученной части карты. Сначала открой соседние сектора.'}
            </p>

            {selectedSector.is_explorable && (
              <button
                className="primary-button sector-explore-button"
                type="button"
                disabled={busy || anyBlockingActivity}
                title={anyBlockingActivity ? blockingReason : ''}
                onClick={() => void startExploration()}
              >
                {busy ? 'Отправляемся…' : `Исследовать · ${formatDuration(explorationSpeed.sector_seconds)}`}
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
