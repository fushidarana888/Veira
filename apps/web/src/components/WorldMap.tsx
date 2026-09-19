import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import type {
  CharacterSectorDiscovery,
  MapSector,
  SectorExpedition,
} from '../types'

type Props = {
  characterId: string
}

const TOTAL_SECTORS = 300
const EXPLORATION_HOURS = 12

function isAdjacent(a: MapSector, b: MapSector) {
  return (
    Math.abs(a.grid_col - b.grid_col) <= 1 &&
    Math.abs(a.grid_row - b.grid_row) <= 1 &&
    !(a.grid_col === b.grid_col && a.grid_row === b.grid_row)
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
    .join(':')
}

export function WorldMap({ characterId }: Props) {
  const [sectors, setSectors] = useState<MapSector[]>([])
  const [discoveries, setDiscoveries] = useState<CharacterSectorDiscovery[]>([])
  const [expeditions, setExpeditions] = useState<SectorExpedition[]>([])
  const [selectedSectorId, setSelectedSectorId] = useState<number | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const [now, setNow] = useState(() => Date.now())

  async function loadMapData() {
    setLoading(true)
    setMessage('')

    const { error: completionError } = await supabase.rpc(
      'complete_character_sector_expeditions',
      { p_character_id: characterId },
    )

    if (completionError) {
      setMessage(completionError.message)
      setLoading(false)
      return
    }

    const [sectorResult, discoveryResult, expeditionResult] = await Promise.all([
      supabase
        .from('map_sectors')
        .select('id, grid_col, grid_row, initially_known, location_key, location_name, terrain, metadata')
        .order('id', { ascending: true }),
      supabase
        .from('character_sector_discoveries')
        .select('character_id, sector_id, discovered_at, source')
        .eq('character_id', characterId),
      supabase
        .from('sector_expeditions')
        .select('id, character_id, sector_id, status, started_at, ends_at, completed_at, created_at')
        .eq('character_id', characterId)
        .order('created_at', { ascending: false })
        .limit(20),
    ])

    const error = sectorResult.error ?? discoveryResult.error ?? expeditionResult.error

    if (error) {
      setMessage(error.message)
      setLoading(false)
      return
    }

    setSectors((sectorResult.data as MapSector[] | null) ?? [])
    setDiscoveries((discoveryResult.data as CharacterSectorDiscovery[] | null) ?? [])
    setExpeditions((expeditionResult.data as SectorExpedition[] | null) ?? [])
    setLoading(false)
  }

  useEffect(() => {
    void loadMapData()
  }, [characterId])

  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(timer)
  }, [])

  const discoveredIds = useMemo(
    () => new Set(discoveries.map((entry) => entry.sector_id)),
    [discoveries],
  )

  const sectorById = useMemo(
    () => new Map(sectors.map((sector) => [sector.id, sector])),
    [sectors],
  )

  const discoveredSectors = useMemo(
    () => sectors.filter((sector) => discoveredIds.has(sector.id)),
    [discoveredIds, sectors],
  )

  const activeExpedition = expeditions.find((entry) => entry.status === 'active') ?? null
  const activeSector = activeExpedition ? sectorById.get(activeExpedition.sector_id) ?? null : null
  const selectedSector = selectedSectorId ? sectorById.get(selectedSectorId) ?? null : null

  const explorableIds = useMemo(() => {
    const result = new Set<number>()

    if (activeExpedition) return result

    for (const target of sectors) {
      if (discoveredIds.has(target.id)) continue

      if (discoveredSectors.some((known) => isAdjacent(known, target))) {
        result.add(target.id)
      }
    }

    return result
  }, [activeExpedition, discoveredIds, discoveredSectors, sectors])

  useEffect(() => {
    if (!activeExpedition) return

    const endsAt = new Date(activeExpedition.ends_at).getTime()
    if (now < endsAt) return

    const timeout = window.setTimeout(() => {
      void loadMapData()
    }, 600)

    return () => window.clearTimeout(timeout)
  }, [activeExpedition, now])

  async function startExploration() {
    if (!selectedSector || !explorableIds.has(selectedSector.id)) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('start_sector_exploration', {
      p_character_id: characterId,
      p_sector_id: selectedSector.id,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('EXPEDITION_ALREADY_ACTIVE')) {
        setMessage('У персонажа уже идёт исследование другого сектора.')
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
          <strong>{discoveries.length} / {TOTAL_SECTORS}</strong>
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
              Завершится автоматически. Таймер на странице только показывает время — результат проверяет сервер.
            </p>
          </div>
          <div className="expedition-timer">
            <span>Осталось</span>
            <strong>{formatRemaining(remaining)}</strong>
          </div>
        </article>
      )}

      <div className="eilar-map-frame">
        <div className="eilar-map-stage">
          <img
            src={import.meta.env.BASE_URL + 'eilar-map.webp'}
            alt="Карта Эйлара"
            draggable={false}
          />

          <div className="fog-grid" aria-label="Сектора карты Эйлара">
            {sectors.map((sector) => {
              const discovered = discoveredIds.has(sector.id)
              const explorable = explorableIds.has(sector.id)
              const active = activeExpedition?.sector_id === sector.id
              const selected = selectedSectorId === sector.id

              const classNames = [
                'fog-sector',
                discovered ? 'discovered' : 'hidden',
                explorable ? 'explorable' : '',
                active ? 'active-expedition' : '',
                selected ? 'selected' : '',
              ].filter(Boolean).join(' ')

              const visibleName = discovered && sector.location_name
                ? sector.location_name
                : null

              return (
                <button
                  key={sector.id}
                  type="button"
                  className={classNames}
                  title={
                    discovered
                      ? visibleName ?? `Открытый сектор ${sector.grid_col}:${sector.grid_row}`
                      : explorable
                        ? `Исследовать сектор ${sector.grid_col}:${sector.grid_row}`
                        : 'Неизведанная территория'
                  }
                  aria-label={
                    discovered
                      ? visibleName ?? `Открытый сектор ${sector.grid_col}:${sector.grid_row}`
                      : `Неизведанный сектор ${sector.grid_col}:${sector.grid_row}`
                  }
                  onClick={() => setSelectedSectorId(sector.id)}
                >
                  {active && <span className="sector-expedition-mark">⌛</span>}
                  {visibleName && <span className="sector-location-mark">◆</span>}
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
              Светлые области уже исследованы. Секторы на границе тумана подсвечиваются при наведении и доступны для следующей экспедиции.
            </p>
          </>
        ) : discoveredIds.has(selectedSector.id) ? (
          <>
            <span className="eyebrow">ОТКРЫТАЯ ТЕРРИТОРИЯ</span>
            <h3>{selectedSector.location_name ?? `Сектор ${selectedSector.grid_col}:${selectedSector.grid_row}`}</h3>
            <p className="muted">
              Этот сектор уже нанесён на личную карту персонажа.
            </p>
          </>
        ) : (
          <>
            <span className="eyebrow">НЕИЗВЕДАННАЯ ТЕРРИТОРИЯ</span>
            <h3>Сектор {selectedSector.grid_col}:{selectedSector.grid_row}</h3>
            <p className="muted">
              {explorableIds.has(selectedSector.id)
                ? 'Он граничит с уже известной территорией и доступен для исследования.'
                : 'Пока слишком далеко от изученной части карты. Сначала открой соседние сектора.'}
            </p>

            {explorableIds.has(selectedSector.id) && (
              <button
                className="primary-button sector-explore-button"
                type="button"
                disabled={busy || Boolean(activeExpedition)}
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
