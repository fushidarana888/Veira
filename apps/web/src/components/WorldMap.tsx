import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import type {
  CharacterMapSector,
  ExpeditionEventInstance,
  SectorExpedition,
} from '../types'

type Props = {
  characterId: string
}

const TOTAL_SECTORS = 300
const EXPLORATION_HOURS = 12

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

export function WorldMap({ characterId }: Props) {
  const [sectors, setSectors] = useState<CharacterMapSector[]>([])
  const [expeditions, setExpeditions] = useState<SectorExpedition[]>([])
  const [events, setEvents] = useState<ExpeditionEventInstance[]>([])
  const [selectedSectorId, setSelectedSectorId] = useState<number | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const [now, setNow] = useState(() => Date.now())
  const [mapSrc, setMapSrc] = useState(ORIGINAL_MAP_URL)

  async function loadMapData() {
    setLoading(true)
    setMessage('')

    const [mapResult, expeditionResult, eventResult] = await Promise.all([
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
        .select('id, expedition_id, event_definition_id, character_id, sector_id, title, player_prompt, status, resolution_text, outcome, created_at, resolved_at, resolved_by')
        .eq('character_id', characterId)
        .order('created_at', { ascending: false })
        .limit(20),
    ])

    const error = mapResult.error ?? expeditionResult.error ?? eventResult.error

    if (error) {
      setMessage(error.message)
      setLoading(false)
      return
    }

    setSectors((mapResult.data as CharacterMapSector[] | null) ?? [])
    setExpeditions((expeditionResult.data as SectorExpedition[] | null) ?? [])
    setEvents((eventResult.data as ExpeditionEventInstance[] | null) ?? [])
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

  const recentResolvedEvent =
    events.find((entry) => entry.status === 'resolved' && entry.resolution_text.trim()) ?? null

  const selectedSector = selectedSectorId
    ? sectorById.get(selectedSectorId) ?? null
    : null

  useEffect(() => {
    if (!activeExpedition) return

    const endsAt = new Date(activeExpedition.ends_at).getTime()
    if (now < endsAt) return

    const timeout = window.setTimeout(() => {
      void loadMapData()
    }, 700)

    return () => window.clearTimeout(timeout)
  }, [activeExpedition, now])

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
      if (raw.includes('EXPEDITION_ALREADY_ACTIVE')) {
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

  return (
    <section className="world-section">
      <article className="panel world-header-card">
        <div>
          <span className="eyebrow">ЭЙЛАР · ЛИЧНАЯ КАРТА</span>
          <h2>Исследование мира</h2>
          <p className="muted">
            Карта разделена на {TOTAL_SECTORS} секторов. Неизведанный соседний сектор открывается за {EXPLORATION_HOURS} часов реального времени.
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
          </div>
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

      {!pendingEvent && recentResolvedEvent && (
        <article className="panel expedition-result-card">
          <div>
            <span className="eyebrow">ИТОГ ПОСЛЕДНЕГО СОБЫТИЯ</span>
            <h3>{recentResolvedEvent.title}</h3>
            <p>{recentResolvedEvent.resolution_text}</p>
          </div>
          <span className="badge">
            {recentResolvedEvent.outcome === 'discovered' ? 'Сектор открыт' : 'Экспедиция остановлена'}
          </span>
        </article>
      )}

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

          <div className="fog-grid" aria-label="Сектора карты Эйлара">
            {sectors.map((sector) => {
              const active = openExpedition?.sector_id === sector.id
              const selected = selectedSectorId === sector.id

              const classNames = [
                'fog-sector',
                sector.is_discovered ? 'discovered' : 'hidden',
                sector.is_explorable ? 'explorable' : '',
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
                  {sector.is_discovered && sector.title && (
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
                Опасность {selectedSector.danger_level ?? 0}/5
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
          </>
        ) : (
          <>
            <span className="eyebrow">НЕИЗВЕДАННАЯ ТЕРРИТОРИЯ</span>
            <h3>Сектор {selectedSector.grid_col}:{selectedSector.grid_row}</h3>
            <p className="muted">
              {selectedSector.is_explorable
                ? 'Он граничит с уже известной территорией и доступен для исследования.'
                : openExpedition
                  ? 'Сначала нужно завершить текущую экспедицию или событие.'
                  : 'Пока слишком далеко от изученной части карты. Сначала открой соседние сектора.'}
            </p>

            {selectedSector.is_explorable && (
              <button
                className="primary-button sector-explore-button"
                type="button"
                disabled={busy || Boolean(openExpedition)}
                onClick={() => void startExploration()}
              >
                {busy ? 'Отправляемся…' : 'Исследовать · 12 часов'}
              </button>
            )}
          </>
        )}
      </article>
    </section>
  )
}
