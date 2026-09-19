import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
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
  onProgressChanged?: () => Promise<unknown> | void
  onInventoryChanged?: () => Promise<unknown> | void
}

const TOTAL_SECTORS = 300
const EXPLORATION_HOURS = 8

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

export function WorldMap({
  characterId,
  onProgressChanged,
  onInventoryChanged,
}: Props) {
  const [sectors, setSectors] = useState<CharacterMapSector[]>([])
  const [expeditions, setExpeditions] = useState<SectorExpedition[]>([])
  const [events, setEvents] = useState<ExpeditionEventInstance[]>([])
  const [results, setResults] = useState<ExpeditionResult[]>([])
  const [siteActions, setSiteActions] = useState<SectorSiteAction[]>([])
  const [siteProgress, setSiteProgress] = useState<SectorSiteProgress[]>([])
  const [dungeonRuns, setDungeonRuns] = useState<DungeonRun[]>([])
  const [selectedSectorId, setSelectedSectorId] = useState<number | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const [now, setNow] = useState(() => Date.now())
  const [mapSrc, setMapSrc] = useState(ORIGINAL_MAP_URL)
  const [showGameplayOverlay, setShowGameplayOverlay] = useState(true)

  async function loadMapData() {
    setLoading(true)
    setMessage('')

    const [
      mapResult,
      expeditionResult,
      eventResult,
      resultResult,
      siteActionResult,
      siteProgressResult,
      dungeonRunResult,
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
    ])

    const error =
      mapResult.error ??
      expeditionResult.error ??
      eventResult.error ??
      resultResult.error ??
      siteActionResult.error ??
      siteProgressResult.error ??
      dungeonRunResult.error

    if (error) {
      setMessage(error.message)
      setLoading(false)
      return
    }

    setSectors((mapResult.data as CharacterMapSector[] | null) ?? [])
    setExpeditions((expeditionResult.data as SectorExpedition[] | null) ?? [])
    setEvents((eventResult.data as ExpeditionEventInstance[] | null) ?? [])
    setResults((resultResult.data as ExpeditionResult[] | null) ?? [])
    setSiteActions((siteActionResult.data as SectorSiteAction[] | null) ?? [])
    setSiteProgress((siteProgressResult.data as SectorSiteProgress[] | null) ?? [])
    setDungeonRuns((dungeonRunResult.data as DungeonRun[] | null) ?? [])
    setLoading(false)
  }

  useEffect(() => {
    void loadMapData()
  }, [characterId])

  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(timer)
  }, [])

  const sectorById = useMemo(
    () => new Map(sectors.map((sector) => [sector.id, sector])),
    [sectors],
  )

  const discoveredCount = useMemo(
    () => sectors.filter((sector) => sector.is_discovered).length,
    [sectors],
  )

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

  useEffect(() => {
    const activeTimedAction = activeExpedition ?? activeSiteAction
    if (!activeTimedAction) return

    const endsAt = new Date(activeTimedAction.ends_at).getTime()
    if (now < endsAt) return

    const timeout = window.setTimeout(() => {
      void loadMapData()
    }, 700)

    return () => window.clearTimeout(timeout)
  }, [activeExpedition, activeSiteAction, now])

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
      } else {
        setMessage(raw)
      }

      setBusy(false)
      return
    }

    await loadMapData()
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

  const remaining = activeExpedition
    ? new Date(activeExpedition.ends_at).getTime() - now
    : 0

  const siteActionRemaining = activeSiteAction
    ? new Date(activeSiteAction.ends_at).getTime() - now
    : 0

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
            <strong>{formatRemaining(remaining)}</strong>
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
              Сектор #{activeSiteAction.sector_id}. Это пассивное исследование: можно дуэлиться, заниматься ремеслом и другими делами. Нельзя начинать другое исследование или тяжёлый PvE-контент.
            </p>
          </div>
          <div className="expedition-timer">
            <span>Осталось</span>
            <strong>{formatRemaining(siteActionRemaining)}</strong>
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
            <p>{pendingEvent.player_prompt || 'Экспедиция столкнулась с ситуацией, требующей решения GM.'}</p>
          </div>
          <span className="badge event-waiting-badge">Ожидает GM</span>
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
          </div>
        )}
      </div>

      <div className="eilar-map-frame">
        <div className="eilar-map-stage">
          <img
            src={mapSrc}
            alt="Карта Эйлара"
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
            {sectors.map((sector) => {
              const active = openExpedition?.sector_id === sector.id
              const selected = selectedSectorId === sector.id

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
                waitingExpedition && active ? 'awaiting-event' : '',
                selected ? 'selected' : '',
              ].filter(Boolean).join(' ')

              return (
                <button
                  key={sector.id}
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
                  onClick={() => setSelectedSectorId(sector.id)}
                >
                  {active && (
                    <span className="sector-expedition-mark">
                      {waitingExpedition ? '!' : '⌛'}
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
            })}
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
              {selectedSector.requires_gm && <span>GM-сцена</span>}
            </div>

            <p className="sector-description">
              {selectedSector.player_description ||
                'Этот сектор уже нанесён на карту, но подробное описание пока не задано.'}
            </p>

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
                {busy ? 'Отправляемся…' : 'Исследовать · 8 часов'}
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
