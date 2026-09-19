import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import type {
  Character,
  ExpeditionEventInstance,
  GmMapSector,
  Profile,
  SectorContentType,
  SectorExpedition,
  SectorTerrain,
} from '../types'

type Props = {
  characters: Character[]
  profiles: Profile[]
}

const terrainOptions: Array<{ value: SectorTerrain; label: string }> = [
  { value: 'unassigned', label: 'Не определено' },
  { value: 'plains', label: 'Равнины' },
  { value: 'forest', label: 'Лес' },
  { value: 'swamp', label: 'Болота' },
  { value: 'desert', label: 'Пустыня' },
  { value: 'mountains', label: 'Горы' },
  { value: 'tundra', label: 'Тундра' },
  { value: 'coast', label: 'Побережье' },
  { value: 'sea', label: 'Море' },
  { value: 'riverlands', label: 'Речные земли' },
]

const contentOptions: Array<{ value: SectorContentType; label: string }> = [
  { value: 'unassigned', label: 'Не определено' },
  { value: 'wilderness', label: 'Дикая местность' },
  { value: 'settlement', label: 'Поселение' },
  { value: 'ruins', label: 'Руины' },
  { value: 'dungeon', label: 'Подземелье' },
  { value: 'resource', label: 'Ресурсная точка' },
  { value: 'npc', label: 'NPC' },
  { value: 'landmark', label: 'Достопримечательность' },
  { value: 'event', label: 'Событие' },
]

const mapUrl = supabase.storage
  .from('veira-assets')
  .getPublicUrl('eilar-map-original.png').data.publicUrl + '?v=original-1'

export function GmWorldEditor({ characters, profiles }: Props) {
  const [sectors, setSectors] = useState<GmMapSector[]>([])
  const [expeditions, setExpeditions] = useState<SectorExpedition[]>([])
  const [events, setEvents] = useState<ExpeditionEventInstance[]>([])
  const [selectedSectorId, setSelectedSectorId] = useState<number | null>(null)
  const [selectedCharacterId, setSelectedCharacterId] = useState('')
  const [discoveredIds, setDiscoveredIds] = useState<Set<number>>(new Set())
  const [form, setForm] = useState<GmMapSector | null>(null)
  const [eventResolutions, setEventResolutions] = useState<Record<string, string>>({})
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  const profileById = useMemo(
    () => new Map(profiles.map((entry) => [entry.user_id, entry])),
    [profiles],
  )

  const characterById = useMemo(
    () => new Map(characters.map((entry) => [entry.id, entry])),
    [characters],
  )

  async function loadWorld() {
    setLoading(true)
    setMessage('')

    const [mapResult, expeditionResult, eventResult] = await Promise.all([
      supabase.rpc('get_gm_map_state'),
      supabase
        .from('sector_expeditions')
        .select('id, character_id, sector_id, status, started_at, ends_at, completed_at, created_at')
        .in('status', ['active', 'awaiting_event'])
        .order('created_at', { ascending: false }),
      supabase
        .from('expedition_event_instances')
        .select('id, expedition_id, event_definition_id, character_id, sector_id, title, player_prompt, status, resolution_text, outcome, created_at, resolved_at, resolved_by')
        .eq('status', 'pending')
        .order('created_at', { ascending: true }),
    ])

    const error = mapResult.error ?? expeditionResult.error ?? eventResult.error

    if (error) {
      setMessage(error.message)
      setLoading(false)
      return
    }

    const nextSectors = (mapResult.data as GmMapSector[] | null) ?? []
    setSectors(nextSectors)
    setExpeditions((expeditionResult.data as SectorExpedition[] | null) ?? [])
    setEvents((eventResult.data as ExpeditionEventInstance[] | null) ?? [])

    if (!selectedSectorId && nextSectors[0]) {
      setSelectedSectorId(nextSectors[0].id)
      setForm(nextSectors[0])
    } else if (selectedSectorId) {
      const selected = nextSectors.find((sector) => sector.id === selectedSectorId) ?? null
      setForm(selected)
    }

    if (!selectedCharacterId && characters[0]) {
      setSelectedCharacterId(characters[0].id)
    }

    setLoading(false)
  }

  async function loadCharacterDiscoveries(characterId: string) {
    if (!characterId) {
      setDiscoveredIds(new Set())
      return
    }

    const { data, error } = await supabase
      .from('character_sector_discoveries')
      .select('sector_id')
      .eq('character_id', characterId)

    if (error) {
      setMessage(error.message)
      return
    }

    setDiscoveredIds(new Set((data ?? []).map((entry) => Number(entry.sector_id))))
  }

  useEffect(() => {
    void loadWorld()
  }, [])

  useEffect(() => {
    if (!selectedCharacterId && characters[0]) {
      setSelectedCharacterId(characters[0].id)
    }
  }, [characters, selectedCharacterId])

  useEffect(() => {
    void loadCharacterDiscoveries(selectedCharacterId)
  }, [selectedCharacterId])

  function selectSector(sectorId: number) {
    const sector = sectors.find((entry) => entry.id === sectorId) ?? null
    setSelectedSectorId(sectorId)
    setForm(sector ? { ...sector } : null)
  }

  async function saveSector() {
    if (!form) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('gm_update_sector', {
      p_sector_id: form.id,
      p_terrain_type: form.terrain_type,
      p_content_type: form.content_type,
      p_title: form.title ?? '',
      p_player_description: form.player_description,
      p_danger_level: form.danger_level,
      p_requires_gm: form.requires_gm,
      p_gm_notes: form.gm_notes,
      p_event_enabled: form.event_enabled,
      p_event_title: form.event_title,
      p_event_prompt: form.event_prompt,
      p_event_gm_notes: form.event_gm_notes,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    setMessage(`Сектор ${form.grid_col}:${form.grid_row} сохранён.`)
    await loadWorld()
    setBusy(false)
  }

  async function toggleDiscovery() {
    if (!selectedSectorId || !selectedCharacterId) return

    const willDiscover = !discoveredIds.has(selectedSectorId)

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('gm_set_sector_discovery', {
      p_character_id: selectedCharacterId,
      p_sector_id: selectedSectorId,
      p_discovered: willDiscover,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    await loadCharacterDiscoveries(selectedCharacterId)
    setMessage(willDiscover ? 'Сектор открыт персонажу.' : 'Сектор скрыт для персонажа.')
    setBusy(false)
  }

  async function finishExpedition(expeditionId: string) {
    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('gm_finish_expedition_now', {
      p_expedition_id: expeditionId,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    setMessage('Экспедиция завершена принудительно.')
    await loadWorld()
    if (selectedCharacterId) await loadCharacterDiscoveries(selectedCharacterId)
    setBusy(false)
  }

  async function resolveEvent(eventId: string, outcome: 'discovered' | 'blocked') {
    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('gm_resolve_expedition_event', {
      p_event_instance_id: eventId,
      p_resolution_text: eventResolutions[eventId] ?? '',
      p_outcome: outcome,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    setMessage(outcome === 'discovered'
      ? 'Событие завершено: сектор открыт.'
      : 'Событие завершено: экспедиция заблокирована.')

    await loadWorld()
    if (selectedCharacterId) await loadCharacterDiscoveries(selectedCharacterId)
    setBusy(false)
  }

  const configuredCount = sectors.filter(
    (sector) => sector.content_type !== 'unassigned' || sector.terrain_type !== 'unassigned',
  ).length

  const selectedCharacter = characterById.get(selectedCharacterId) ?? null
  const selectedOwner = selectedCharacter
    ? profileById.get(selectedCharacter.owner_user_id) ?? null
    : null

  if (loading && sectors.length === 0) {
    return (
      <section className="panel">
        <span className="eyebrow">GM · КАРТА МИРА</span>
        <h2>Загружаем 300 секторов…</h2>
      </section>
    )
  }

  return (
    <section className="gm-world-editor">
      {message && <p className="gm-notice" aria-live="polite">{message}</p>}

      <article className="panel gm-world-summary">
        <div>
          <span className="eyebrow">РЕДАКТОР ЭЙЛАРА</span>
          <h2>300 секторов мира</h2>
          <p className="muted">
            GM видит всю карту и скрытое содержимое. Игрок получает детали сектора только после открытия.
          </p>
        </div>
        <div className="gm-world-counters">
          <span><strong>{configuredCount}</strong><small>настроено</small></span>
          <span><strong>{expeditions.length}</strong><small>экспедиций</small></span>
          <span><strong>{events.length}</strong><small>ждут GM</small></span>
        </div>
      </article>

      <div className="gm-world-layout">
        <div className="gm-world-main">
          <div className="gm-map-frame">
            <div className="gm-map-stage">
              <img src={mapUrl} alt="Полная карта Эйлара для GM" draggable={false} />
              <div className="gm-sector-grid">
                {sectors.map((sector) => {
                  const selected = selectedSectorId === sector.id
                  const configured =
                    sector.content_type !== 'unassigned' ||
                    sector.terrain_type !== 'unassigned' ||
                    Boolean(sector.title)
                  const event = sector.event_enabled

                  return (
                    <button
                      key={sector.id}
                      type="button"
                      className={[
                        'gm-map-sector',
                        selected ? 'selected' : '',
                        configured ? 'configured' : '',
                        event ? 'has-event' : '',
                      ].filter(Boolean).join(' ')}
                      title={`${sector.grid_col}:${sector.grid_row} · ${sector.title ?? 'без названия'}`}
                      onClick={() => selectSector(sector.id)}
                    >
                      {event ? '!' : configured ? '·' : ''}
                    </button>
                  )
                })}
              </div>
            </div>
          </div>

          <article className="panel gm-character-map-control">
            <div className="section-heading">
              <div>
                <span className="eyebrow">ЛИЧНАЯ КАРТА ИГРОКА</span>
                <h3>Открыть или скрыть сектор вручную</h3>
              </div>
            </div>

            <div className="gm-character-map-row">
              <select
                value={selectedCharacterId}
                onChange={(event) => setSelectedCharacterId(event.target.value)}
              >
                {characters.map((character) => (
                  <option key={character.id} value={character.id}>
                    {character.name} · @{profileById.get(character.owner_user_id)?.display_name ?? 'unknown'}
                  </option>
                ))}
              </select>

              <div className="gm-character-map-status">
                {selectedCharacter ? (
                  <>
                    <strong>{selectedCharacter.name}</strong>
                    <span>@{selectedOwner?.display_name ?? 'unknown'}</span>
                  </>
                ) : (
                  <span>Нет персонажей</span>
                )}
              </div>

              <button
                className="ghost-button"
                type="button"
                disabled={busy || !selectedSectorId || !selectedCharacterId}
                onClick={() => void toggleDiscovery()}
              >
                {selectedSectorId && discoveredIds.has(selectedSectorId)
                  ? 'Скрыть сектор'
                  : 'Открыть сектор'}
              </button>
            </div>
          </article>
        </div>

        <aside className="panel gm-sector-editor-panel">
          {!form ? (
            <p className="muted">Выбери сектор на карте.</p>
          ) : (
            <>
              <div className="section-heading">
                <div>
                  <span className="eyebrow">СЕКТОР {form.grid_col}:{form.grid_row}</span>
                  <h2>{form.title || 'Без названия'}</h2>
                </div>
                <span className="badge">#{form.id}</span>
              </div>

              <div className="gm-sector-form">
                <label>
                  <span>Название</span>
                  <input
                    value={form.title ?? ''}
                    onChange={(event) => setForm({ ...form, title: event.target.value })}
                    placeholder="Например: Разрушенная башня"
                  />
                </label>

                <div className="gm-sector-form-grid">
                  <label>
                    <span>Местность</span>
                    <select
                      value={form.terrain_type}
                      onChange={(event) => setForm({
                        ...form,
                        terrain_type: event.target.value as SectorTerrain,
                      })}
                    >
                      {terrainOptions.map((option) => (
                        <option key={option.value} value={option.value}>{option.label}</option>
                      ))}
                    </select>
                  </label>

                  <label>
                    <span>Содержимое</span>
                    <select
                      value={form.content_type}
                      onChange={(event) => setForm({
                        ...form,
                        content_type: event.target.value as SectorContentType,
                      })}
                    >
                      {contentOptions.map((option) => (
                        <option key={option.value} value={option.value}>{option.label}</option>
                      ))}
                    </select>
                  </label>
                </div>

                <label>
                  <span>Опасность · {form.danger_level}/5</span>
                  <input
                    type="range"
                    min={0}
                    max={5}
                    value={form.danger_level}
                    onChange={(event) => setForm({
                      ...form,
                      danger_level: Number(event.target.value),
                    })}
                  />
                </label>

                <label>
                  <span>Описание для игрока после открытия</span>
                  <textarea
                    rows={5}
                    value={form.player_description}
                    onChange={(event) => setForm({
                      ...form,
                      player_description: event.target.value,
                    })}
                    placeholder="Что персонаж узнаёт об этой области после исследования?"
                  />
                </label>

                <label className="gm-check-row">
                  <input
                    type="checkbox"
                    checked={form.requires_gm}
                    onChange={(event) => setForm({
                      ...form,
                      requires_gm: event.target.checked,
                    })}
                  />
                  <span>Сектор предполагает GM/RP-вмешательство</span>
                </label>

                <label>
                  <span>Секретные заметки GM</span>
                  <textarea
                    rows={4}
                    value={form.gm_notes}
                    onChange={(event) => setForm({ ...form, gm_notes: event.target.value })}
                    placeholder="Игрок это не видит."
                  />
                </label>

                <div className="gm-sector-event-box">
                  <label className="gm-check-row">
                    <input
                      type="checkbox"
                      checked={form.event_enabled}
                      onChange={(event) => setForm({
                        ...form,
                        event_enabled: event.target.checked,
                      })}
                    />
                    <span>Остановить экспедицию на событии</span>
                  </label>

                  {form.event_enabled && (
                    <>
                      <label>
                        <span>Название события</span>
                        <input
                          value={form.event_title}
                          onChange={(event) => setForm({
                            ...form,
                            event_title: event.target.value,
                          })}
                          placeholder="Разрушенный мост"
                        />
                      </label>

                      <label>
                        <span>Что увидит игрок</span>
                        <textarea
                          rows={4}
                          value={form.event_prompt}
                          onChange={(event) => setForm({
                            ...form,
                            event_prompt: event.target.value,
                          })}
                          placeholder="Экспедиция остановилась перед..."
                        />
                      </label>

                      <label>
                        <span>Подсказка GM</span>
                        <textarea
                          rows={3}
                          value={form.event_gm_notes}
                          onChange={(event) => setForm({
                            ...form,
                            event_gm_notes: event.target.value,
                          })}
                          placeholder="Как можно разыграть эту сцену."
                        />
                      </label>
                    </>
                  )}
                </div>

                <button
                  className="primary-button"
                  type="button"
                  disabled={busy}
                  onClick={() => void saveSector()}
                >
                  {busy ? 'Сохраняем…' : 'Сохранить сектор'}
                </button>
              </div>
            </>
          )}
        </aside>
      </div>

      <article className="panel">
        <div className="section-heading">
          <div>
            <span className="eyebrow">ЭКСПЕДИЦИИ</span>
            <h2>Активные исследования</h2>
          </div>
          <span className="badge">{expeditions.length}</span>
        </div>

        <div className="gm-expedition-list">
          {expeditions.length === 0 && <p className="muted">Активных экспедиций сейчас нет.</p>}
          {expeditions.map((expedition) => {
            const character = characterById.get(expedition.character_id)
            return (
              <div className="gm-expedition-row" key={expedition.id}>
                <div>
                  <strong>{character?.name ?? 'Неизвестный персонаж'}</strong>
                  <span>
                    сектор #{expedition.sector_id} · {expedition.status === 'awaiting_event' ? 'ждёт события' : 'исследует'}
                  </span>
                </div>
                {expedition.status === 'active' && (
                  <button
                    className="ghost-button"
                    type="button"
                    disabled={busy}
                    onClick={() => void finishExpedition(expedition.id)}
                  >
                    Завершить сейчас
                  </button>
                )}
              </div>
            )
          })}
        </div>
      </article>

      <article className="panel gm-event-queue">
        <div className="section-heading">
          <div>
            <span className="eyebrow">GM TASKS</span>
            <h2>События, ожидающие решения</h2>
          </div>
          <span className="badge">{events.length}</span>
        </div>

        <div className="gm-event-list">
          {events.length === 0 && <p className="muted">Нерешённых событий нет.</p>}
          {events.map((event) => {
            const character = characterById.get(event.character_id)

            return (
              <article className="gm-event-task" key={event.id}>
                <div className="gm-event-task-heading">
                  <div>
                    <strong>{event.title}</strong>
                    <span>{character?.name ?? 'Неизвестный персонаж'} · сектор #{event.sector_id}</span>
                  </div>
                  <span className="badge">ожидает</span>
                </div>

                <p>{event.player_prompt || 'Описание события для игрока не задано.'}</p>

                <textarea
                  rows={3}
                  value={eventResolutions[event.id] ?? ''}
                  onChange={(changeEvent) => setEventResolutions({
                    ...eventResolutions,
                    [event.id]: changeEvent.target.value,
                  })}
                  placeholder="Запиши итог сцены или решение GM…"
                />

                <div className="gm-event-actions">
                  <button
                    className="primary-button"
                    type="button"
                    disabled={busy}
                    onClick={() => void resolveEvent(event.id, 'discovered')}
                  >
                    Разрешить и открыть сектор
                  </button>
                  <button
                    className="ghost-button"
                    type="button"
                    disabled={busy}
                    onClick={() => void resolveEvent(event.id, 'blocked')}
                  >
                    Заблокировать экспедицию
                  </button>
                </div>
              </article>
            )
          })}
        </div>
      </article>
    </section>
  )
}
