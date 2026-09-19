import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import type {
  Character,
  ExpeditionEventInstance,
  ExplorationEventTemplate,
  GmMapSector,
  Profile,
  SectorContentType,
  SectorExpedition,
  SectorSiteAction,
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

const createEmptyEventTemplateDraft = () => ({
  id: null as string | null,
  name: '',
  enabled: true,
  terrain_type: null as SectorTerrain | null,
  content_type: null as SectorContentType | null,
  min_danger: 0,
  max_danger: 5,
  chance_percent: 25,
  weight: 1,
  requires_gm: true,
  title: '',
  player_prompt: '',
  automatic_result: '',
  gm_notes: '',
})

const mapUrl = supabase.storage
  .from('veira-assets')
  .getPublicUrl('eilar-map-original.png').data.publicUrl + '?v=original-1'

export function GmWorldEditor({ characters, profiles }: Props) {
  const [sectors, setSectors] = useState<GmMapSector[]>([])
  const [expeditions, setExpeditions] = useState<SectorExpedition[]>([])
  const [events, setEvents] = useState<ExpeditionEventInstance[]>([])
  const [siteActions, setSiteActions] = useState<SectorSiteAction[]>([])
  const [eventTemplates, setEventTemplates] = useState<ExplorationEventTemplate[]>([])
  const [eventTemplateDraft, setEventTemplateDraft] = useState(createEmptyEventTemplateDraft)
  const [selectedSectorId, setSelectedSectorId] = useState<number | null>(null)
  const [unconfiguredHighlightMode, setUnconfiguredHighlightMode] = useState<'off' | 'terrain' | 'danger' | 'content'>('off')
  const [attributeHighlightMode, setAttributeHighlightMode] = useState<'off' | 'terrain' | 'danger' | 'content'>('off')
  const [attributeHighlightValue, setAttributeHighlightValue] = useState('')
  const [selectionMode, setSelectionMode] = useState<'single' | 'multi' | 'rectangle'>('single')
  const [selectedSectorIds, setSelectedSectorIds] = useState<Set<number>>(new Set())
  const [rectangleAnchorId, setRectangleAnchorId] = useState<number | null>(null)
  const [bulkApply, setBulkApply] = useState({
    terrain: false,
    content: false,
    danger: false,
    requiresGm: false,
    playerDescription: false,
    gmNotes: false,
    event: false,
  })
  const [bulkValues, setBulkValues] = useState({
    terrain_type: 'unassigned' as SectorTerrain,
    content_type: 'unassigned' as SectorContentType,
    danger_level: 0,
    requires_gm: false,
    player_description: '',
    gm_notes: '',
    event_enabled: false,
    event_title: '',
    event_prompt: '',
    event_gm_notes: '',
  })
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

    const [mapResult, expeditionResult, eventResult, siteActionResult, templateResult] = await Promise.all([
      supabase.rpc('get_gm_map_state'),
      supabase
        .from('sector_expeditions')
        .select('id, character_id, sector_id, status, started_at, ends_at, completed_at, created_at')
        .in('status', ['active', 'awaiting_event'])
        .order('created_at', { ascending: false }),
      supabase
        .from('expedition_event_instances')
        .select('id, expedition_id, event_definition_id, encounter_template_id, source_kind, character_id, sector_id, title, player_prompt, gm_notes, status, resolution_text, outcome, created_at, resolved_at, resolved_by')
        .eq('status', 'pending')
        .order('created_at', { ascending: true }),
      supabase
        .from('sector_site_actions')
        .select('id, character_id, sector_id, action_type, status, started_at, ends_at, completed_at, result_title, result_text, created_at')
        .eq('status', 'active')
        .order('created_at', { ascending: false }),
      supabase.rpc('get_gm_exploration_event_templates'),
    ])

    const error =
      mapResult.error ??
      expeditionResult.error ??
      eventResult.error ??
      siteActionResult.error ??
      templateResult.error

    if (error) {
      setMessage(error.message)
      setLoading(false)
      return
    }

    const nextSectors = (mapResult.data as GmMapSector[] | null) ?? []
    setSectors(nextSectors)
    setExpeditions((expeditionResult.data as SectorExpedition[] | null) ?? [])
    setEvents((eventResult.data as ExpeditionEventInstance[] | null) ?? [])
    setSiteActions((siteActionResult.data as SectorSiteAction[] | null) ?? [])
    setEventTemplates((templateResult.data as ExplorationEventTemplate[] | null) ?? [])

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

  function setMapSelectionMode(mode: 'single' | 'multi' | 'rectangle') {
    setSelectionMode(mode)
    setRectangleAnchorId(null)

    if (mode === 'single') {
      setSelectedSectorIds(new Set())
    }
  }

  function handleMapSectorClick(sectorId: number) {
    if (selectionMode === 'single') {
      selectSector(sectorId)
      return
    }

    if (selectionMode === 'multi') {
      setSelectedSectorIds((current) => {
        const next = new Set(current)
        if (next.has(sectorId)) next.delete(sectorId)
        else next.add(sectorId)
        return next
      })
      return
    }

    if (rectangleAnchorId === null) {
      setRectangleAnchorId(sectorId)
      setSelectedSectorIds(new Set([sectorId]))
      setMessage('Выбран первый угол области. Нажми второй сектор.')
      return
    }

    const start = sectors.find((entry) => entry.id === rectangleAnchorId)
    const end = sectors.find((entry) => entry.id === sectorId)

    if (!start || !end) {
      setRectangleAnchorId(null)
      return
    }

    const minCol = Math.min(start.grid_col, end.grid_col)
    const maxCol = Math.max(start.grid_col, end.grid_col)
    const minRow = Math.min(start.grid_row, end.grid_row)
    const maxRow = Math.max(start.grid_row, end.grid_row)

    const next = new Set(
      sectors
        .filter((sector) =>
          sector.grid_col >= minCol &&
          sector.grid_col <= maxCol &&
          sector.grid_row >= minRow &&
          sector.grid_row <= maxRow,
        )
        .map((sector) => sector.id),
    )

    setSelectedSectorIds(next)
    setRectangleAnchorId(null)
    setMessage(`Выбрано секторов: ${next.size}.`)
  }

  function clearGroupSelection() {
    setSelectedSectorIds(new Set())
    setRectangleAnchorId(null)
  }

  function copyCurrentSectorToBulk() {
    if (!form) return

    setBulkValues({
      terrain_type: form.terrain_type,
      content_type: form.content_type,
      danger_level: form.danger_level,
      requires_gm: form.requires_gm,
      player_description: form.player_description,
      gm_notes: form.gm_notes,
      event_enabled: form.event_enabled,
      event_title: form.event_title,
      event_prompt: form.event_prompt,
      event_gm_notes: form.event_gm_notes,
    })

    setBulkApply({
      terrain: true,
      content: true,
      danger: true,
      requiresGm: true,
      playerDescription: false,
      gmNotes: false,
      event: false,
    })
  }

  async function applyBulkSectorValues() {
    if (selectedSectorIds.size === 0) {
      setMessage('Сначала выбери несколько секторов на карте.')
      return
    }

    const patch: Record<string, unknown> = {}

    if (bulkApply.terrain) patch.terrain_type = bulkValues.terrain_type
    if (bulkApply.content) patch.content_type = bulkValues.content_type
    if (bulkApply.danger) patch.danger_level = bulkValues.danger_level
    if (bulkApply.requiresGm) patch.requires_gm = bulkValues.requires_gm
    if (bulkApply.playerDescription) patch.player_description = bulkValues.player_description
    if (bulkApply.gmNotes) patch.gm_notes = bulkValues.gm_notes

    if (bulkApply.event) {
      patch.event_enabled = bulkValues.event_enabled
      patch.event_title = bulkValues.event_title
      patch.event_prompt = bulkValues.event_prompt
      patch.event_gm_notes = bulkValues.event_gm_notes
    }

    if (Object.keys(patch).length === 0) {
      setMessage('Отметь хотя бы один показатель, который нужно изменить у группы.')
      return
    }

    setBusy(true)
    setMessage('')

    const { data, error } = await supabase.rpc('gm_bulk_update_sectors', {
      p_sector_ids: Array.from(selectedSectorIds),
      p_patch: patch,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    setMessage(`Одинаковые параметры применены к ${Number(data ?? selectedSectorIds.size)} секторам.`)
    await loadWorld()
    setBusy(false)
  }

  function editEventTemplate(template: ExplorationEventTemplate) {
    setEventTemplateDraft({
      id: template.id,
      name: template.name,
      enabled: template.enabled,
      terrain_type: template.terrain_type,
      content_type: template.content_type,
      min_danger: template.min_danger,
      max_danger: template.max_danger,
      chance_percent: template.chance_percent,
      weight: template.weight,
      requires_gm: template.requires_gm,
      title: template.title,
      player_prompt: template.player_prompt,
      automatic_result: template.automatic_result,
      gm_notes: template.gm_notes,
    })
  }

  function newEventTemplate() {
    setEventTemplateDraft(createEmptyEventTemplateDraft())
  }

  async function saveEventTemplate() {
    if (!eventTemplateDraft.name.trim()) {
      setMessage('Задай внутреннее название шаблона события.')
      return
    }

    if (!eventTemplateDraft.title.trim()) {
      setMessage('Задай название события для игрока.')
      return
    }

    setBusy(true)
    setMessage('')

    const { data, error } = await supabase.rpc('gm_save_exploration_event_template', {
      p_id: eventTemplateDraft.id,
      p_name: eventTemplateDraft.name.trim(),
      p_enabled: eventTemplateDraft.enabled,
      p_terrain_type: eventTemplateDraft.terrain_type,
      p_content_type: eventTemplateDraft.content_type,
      p_min_danger: eventTemplateDraft.min_danger,
      p_max_danger: eventTemplateDraft.max_danger,
      p_chance_percent: eventTemplateDraft.chance_percent,
      p_weight: eventTemplateDraft.weight,
      p_requires_gm: eventTemplateDraft.requires_gm,
      p_title: eventTemplateDraft.title.trim(),
      p_player_prompt: eventTemplateDraft.player_prompt,
      p_automatic_result: eventTemplateDraft.automatic_result,
      p_gm_notes: eventTemplateDraft.gm_notes,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    const wasEditing = Boolean(eventTemplateDraft.id)
    const savedId = data ? String(data) : eventTemplateDraft.id

    if (!eventTemplateDraft.id && savedId) {
      setEventTemplateDraft({
        ...eventTemplateDraft,
        id: savedId,
      })
    }

    await loadWorld()
    setMessage(wasEditing ? 'Шаблон события обновлён.' : 'Шаблон события создан.')
    setBusy(false)
  }

  async function deleteEventTemplate(templateId: string) {
    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('gm_delete_exploration_event_template', {
      p_id: templateId,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    if (eventTemplateDraft.id === templateId) {
      setEventTemplateDraft(createEmptyEventTemplateDraft())
    }

    await loadWorld()
    setMessage('Шаблон события удалён.')
    setBusy(false)
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

  async function finishSiteAction(actionId: string) {
    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('gm_finish_site_action_now', {
      p_action_id: actionId,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    setMessage('Исследование места завершено принудительно.')
    await loadWorld()
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
          <div className="gm-map-selection-toolbar">
            <div className="gm-map-selection-modes">
              <button
                className={selectionMode === 'single' ? 'ghost-button active' : 'ghost-button'}
                type="button"
                onClick={() => setMapSelectionMode('single')}
              >
                Один сектор
              </button>
              <button
                className={selectionMode === 'multi' ? 'ghost-button active' : 'ghost-button'}
                type="button"
                onClick={() => setMapSelectionMode('multi')}
              >
                Несколько
              </button>
              <button
                className={selectionMode === 'rectangle' ? 'ghost-button active' : 'ghost-button'}
                type="button"
                onClick={() => setMapSelectionMode('rectangle')}
              >
                Прямоугольник
              </button>
            </div>

            <div className="gm-map-selection-status">
              <label className="gm-unconfigured-filter">
                <span>Подсветить без:</span>
                <select
                  value={unconfiguredHighlightMode}
                  onChange={(event) => setUnconfiguredHighlightMode(
                    event.target.value as 'off' | 'terrain' | 'danger' | 'content',
                  )}
                >
                  <option value="off">Выключено</option>
                  <option value="terrain">Местности</option>
                  <option value="danger">Опасности</option>
                  <option value="content">Содержимого</option>
                </select>
              </label>

              <label className="gm-unconfigured-filter gm-attribute-highlight-filter">
                <span>Подсветить по:</span>
                <select
                  value={attributeHighlightMode}
                  onChange={(event) => {
                    const mode = event.target.value as 'off' | 'terrain' | 'danger' | 'content'
                    setAttributeHighlightMode(mode)
                    setAttributeHighlightValue('')
                  }}
                >
                  <option value="off">Выключено</option>
                  <option value="terrain">Местности</option>
                  <option value="content">Наполненности</option>
                  <option value="danger">Сложности</option>
                </select>

                {attributeHighlightMode === 'terrain' && (
                  <select
                    value={attributeHighlightValue}
                    onChange={(event) => setAttributeHighlightValue(event.target.value)}
                    aria-label="Какая местность подсвечивается"
                  >
                    <option value="">Выбрать</option>
                    {terrainOptions
                      .filter((option) => option.value !== 'unassigned')
                      .map((option) => (
                        <option key={option.value} value={option.value}>{option.label}</option>
                      ))}
                  </select>
                )}

                {attributeHighlightMode === 'content' && (
                  <select
                    value={attributeHighlightValue}
                    onChange={(event) => setAttributeHighlightValue(event.target.value)}
                    aria-label="Какое содержимое подсвечивается"
                  >
                    <option value="">Выбрать</option>
                    {contentOptions
                      .filter((option) => option.value !== 'unassigned')
                      .map((option) => (
                        <option key={option.value} value={option.value}>{option.label}</option>
                      ))}
                  </select>
                )}

                {attributeHighlightMode === 'danger' && (
                  <select
                    value={attributeHighlightValue}
                    onChange={(event) => setAttributeHighlightValue(event.target.value)}
                    aria-label="Какая сложность подсвечивается"
                  >
                    <option value="">Выбрать</option>
                    {[0, 1, 2, 3, 4, 5].map((level) => (
                      <option key={level} value={String(level)}>Опасность {level}/5</option>
                    ))}
                  </select>
                )}
              </label>
              <strong>{selectedSectorIds.size}</strong>
              <span>выбрано</span>
              <button
                className="ghost-button"
                type="button"
                disabled={selectedSectorIds.size === 0}
                onClick={clearGroupSelection}
              >
                Очистить
              </button>
            </div>
          </div>

          <div className="gm-map-frame">
            <div className="gm-map-stage">
              <img src={mapUrl} alt="Полная карта Эйлара для GM" draggable={false} />
              <div className="gm-sector-grid">
                {sectors.map((sector) => {
                  const selected = selectedSectorId === sector.id
                  const groupSelected = selectedSectorIds.has(sector.id)
                  const rectangleAnchor = rectangleAnchorId === sector.id
                  const configured =
                    sector.content_type !== 'unassigned' ||
                    sector.terrain_type !== 'unassigned' ||
                    Boolean(sector.title)
                  const event = sector.event_enabled
                  const unconfiguredHighlighted =
                    (unconfiguredHighlightMode === 'terrain' && sector.terrain_type === 'unassigned') ||
                    (unconfiguredHighlightMode === 'content' && sector.content_type === 'unassigned') ||
                    (unconfiguredHighlightMode === 'danger' && sector.danger_level === 0)

                  const attributeHighlighted =
                    Boolean(attributeHighlightValue) &&
                    (
                      (attributeHighlightMode === 'terrain' && sector.terrain_type === attributeHighlightValue) ||
                      (attributeHighlightMode === 'content' && sector.content_type === attributeHighlightValue) ||
                      (attributeHighlightMode === 'danger' && sector.danger_level === Number(attributeHighlightValue))
                    )

                  return (
                    <button
                      key={sector.id}
                      type="button"
                      className={[
                        'gm-map-sector',
                        selected && selectionMode === 'single' ? 'selected' : '',
                        groupSelected ? 'group-selected' : '',
                        rectangleAnchor ? 'rectangle-anchor' : '',
                        configured ? 'configured' : '',
                        unconfiguredHighlighted ? 'unconfigured-highlight' : '',
                        attributeHighlighted ? 'attribute-highlight' : '',
                        event ? 'has-event' : '',
                      ].filter(Boolean).join(' ')}
                      title={`${sector.grid_col}:${sector.grid_row} · ${sector.title ?? 'без названия'}`}
                      onClick={() => handleMapSectorClick(sector.id)}
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
          {selectionMode !== 'single' ? (
            <div className="gm-bulk-sector-editor">
              <div className="section-heading">
                <div>
                  <span className="eyebrow">ГРУППОВОЕ РЕДАКТИРОВАНИЕ</span>
                  <h2>{selectedSectorIds.size} секторов</h2>
                </div>
                <span className="badge">
                  {selectionMode === 'rectangle' ? 'область' : 'выбор'}
                </span>
              </div>

              <p className="muted gm-bulk-help">
                Отметь только те параметры, которые нужно сделать одинаковыми. Остальные данные выбранных клеток не изменятся.
              </p>

              {form && (
                <button
                  className="ghost-button"
                  type="button"
                  onClick={copyCurrentSectorToBulk}
                >
                  Взять основные параметры из последнего сектора
                </button>
              )}

              <div className="gm-bulk-fields">
                <div className="gm-bulk-field-row">
                  <label className="gm-check-row">
                    <input
                      type="checkbox"
                      checked={bulkApply.terrain}
                      onChange={(event) => setBulkApply({ ...bulkApply, terrain: event.target.checked })}
                    />
                    <span>Местность</span>
                  </label>
                  <select
                    value={bulkValues.terrain_type}
                    disabled={!bulkApply.terrain}
                    onChange={(event) => setBulkValues({
                      ...bulkValues,
                      terrain_type: event.target.value as SectorTerrain,
                    })}
                  >
                    {terrainOptions.map((option) => (
                      <option key={option.value} value={option.value}>{option.label}</option>
                    ))}
                  </select>
                </div>

                <div className="gm-bulk-field-row">
                  <label className="gm-check-row">
                    <input
                      type="checkbox"
                      checked={bulkApply.content}
                      onChange={(event) => setBulkApply({ ...bulkApply, content: event.target.checked })}
                    />
                    <span>Содержимое</span>
                  </label>
                  <select
                    value={bulkValues.content_type}
                    disabled={!bulkApply.content}
                    onChange={(event) => setBulkValues({
                      ...bulkValues,
                      content_type: event.target.value as SectorContentType,
                    })}
                  >
                    {contentOptions.map((option) => (
                      <option key={option.value} value={option.value}>{option.label}</option>
                    ))}
                  </select>
                </div>

                <div className="gm-bulk-field-row">
                  <label className="gm-check-row">
                    <input
                      type="checkbox"
                      checked={bulkApply.danger}
                      onChange={(event) => setBulkApply({ ...bulkApply, danger: event.target.checked })}
                    />
                    <span>Опасность</span>
                  </label>
                  <div className="gm-bulk-range">
                    <input
                      type="range"
                      min={0}
                      max={5}
                      disabled={!bulkApply.danger}
                      value={bulkValues.danger_level}
                      onChange={(event) => setBulkValues({
                        ...bulkValues,
                        danger_level: Number(event.target.value),
                      })}
                    />
                    <strong>{bulkValues.danger_level}/5</strong>
                  </div>
                </div>

                <div className="gm-bulk-field-row">
                  <label className="gm-check-row">
                    <input
                      type="checkbox"
                      checked={bulkApply.requiresGm}
                      onChange={(event) => setBulkApply({ ...bulkApply, requiresGm: event.target.checked })}
                    />
                    <span>GM/RP-сцена</span>
                  </label>
                  <select
                    value={bulkValues.requires_gm ? 'yes' : 'no'}
                    disabled={!bulkApply.requiresGm}
                    onChange={(event) => setBulkValues({
                      ...bulkValues,
                      requires_gm: event.target.value === 'yes',
                    })}
                  >
                    <option value="no">Нет</option>
                    <option value="yes">Да</option>
                  </select>
                </div>

                <label className="gm-bulk-text-field">
                  <span className="gm-bulk-text-heading">
                    <input
                      type="checkbox"
                      checked={bulkApply.playerDescription}
                      onChange={(event) => setBulkApply({
                        ...bulkApply,
                        playerDescription: event.target.checked,
                      })}
                    />
                    Одинаковое описание для игрока
                  </span>
                  <textarea
                    rows={4}
                    disabled={!bulkApply.playerDescription}
                    value={bulkValues.player_description}
                    onChange={(event) => setBulkValues({
                      ...bulkValues,
                      player_description: event.target.value,
                    })}
                  />
                </label>

                <label className="gm-bulk-text-field">
                  <span className="gm-bulk-text-heading">
                    <input
                      type="checkbox"
                      checked={bulkApply.gmNotes}
                      onChange={(event) => setBulkApply({
                        ...bulkApply,
                        gmNotes: event.target.checked,
                      })}
                    />
                    Одинаковые заметки GM
                  </span>
                  <textarea
                    rows={3}
                    disabled={!bulkApply.gmNotes}
                    value={bulkValues.gm_notes}
                    onChange={(event) => setBulkValues({
                      ...bulkValues,
                      gm_notes: event.target.value,
                    })}
                  />
                </label>

                <div className="gm-sector-event-box">
                  <label className="gm-check-row">
                    <input
                      type="checkbox"
                      checked={bulkApply.event}
                      onChange={(event) => setBulkApply({ ...bulkApply, event: event.target.checked })}
                    />
                    <span>Одинаковое событие экспедиции</span>
                  </label>

                  {bulkApply.event && (
                    <>
                      <label className="gm-check-row">
                        <input
                          type="checkbox"
                          checked={bulkValues.event_enabled}
                          onChange={(event) => setBulkValues({
                            ...bulkValues,
                            event_enabled: event.target.checked,
                          })}
                        />
                        <span>Событие включено</span>
                      </label>

                      <input
                        value={bulkValues.event_title}
                        onChange={(event) => setBulkValues({
                          ...bulkValues,
                          event_title: event.target.value,
                        })}
                        placeholder="Название события"
                      />

                      <textarea
                        rows={3}
                        value={bulkValues.event_prompt}
                        onChange={(event) => setBulkValues({
                          ...bulkValues,
                          event_prompt: event.target.value,
                        })}
                        placeholder="Текст для игрока"
                      />

                      <textarea
                        rows={3}
                        value={bulkValues.event_gm_notes}
                        onChange={(event) => setBulkValues({
                          ...bulkValues,
                          event_gm_notes: event.target.value,
                        })}
                        placeholder="Подсказка GM"
                      />
                    </>
                  )}
                </div>
              </div>

              <button
                className="primary-button"
                type="button"
                disabled={busy || selectedSectorIds.size === 0}
                onClick={() => void applyBulkSectorValues()}
              >
                {busy
                  ? 'Применяем…'
                  : `Применить к ${selectedSectorIds.size || 0} секторам`}
              </button>
            </div>
          ) : !form ? (
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

      <article className="panel gm-event-pool-panel">
        <div className="section-heading">
          <div>
            <span className="eyebrow">ПУЛЫ ЭКСПЕДИЦИЙ</span>
            <h2>Случайные события исследования</h2>
          </div>
          <span className="badge">{eventTemplates.length}</span>
        </div>

        <p className="muted gm-event-pool-intro">
          После 12 часов сначала проверяется закреплённое за сектором событие, затем один подходящий шаблон из этого пула.
          Шаблоны фильтруются по местности, содержимому и опасности. Если событие требует GM, экспедиция остановится и попадёт в очередь ниже.
        </p>

        <div className="gm-event-pool-layout">
          <div className="gm-event-template-list">
            <button
              className="ghost-button"
              type="button"
              onClick={newEventTemplate}
            >
              + Новый шаблон
            </button>

            {eventTemplates.length === 0 && (
              <p className="muted">
                Пул пока пуст. Без шаблонов экспедиции просто получают обычный отчёт по типу сектора.
              </p>
            )}

            {eventTemplates.map((template) => (
              <button
                key={template.id}
                type="button"
                className={[
                  'gm-event-template-card',
                  eventTemplateDraft.id === template.id ? 'active' : '',
                  !template.enabled ? 'disabled' : '',
                ].filter(Boolean).join(' ')}
                onClick={() => editEventTemplate(template)}
              >
                <span className="gm-event-template-card-head">
                  <strong>{template.name}</strong>
                  <small>{template.enabled ? 'включено' : 'выключено'}</small>
                </span>
                <span>
                  {template.terrain_type
                    ? terrainOptions.find((option) => option.value === template.terrain_type)?.label
                    : 'любая местность'}
                  {' · '}
                  {template.content_type
                    ? contentOptions.find((option) => option.value === template.content_type)?.label
                    : 'любое содержимое'}
                </span>
                <span>
                  опасность {template.min_danger}–{template.max_danger} · шанс {template.chance_percent}% · вес {template.weight}
                </span>
              </button>
            ))}
          </div>

          <div className="gm-event-template-editor">
            <div className="gm-event-template-editor-head">
              <div>
                <span className="eyebrow">
                  {eventTemplateDraft.id ? 'РЕДАКТИРОВАНИЕ' : 'НОВОЕ СОБЫТИЕ'}
                </span>
                <h3>{eventTemplateDraft.name || 'Шаблон события'}</h3>
              </div>
              <label className="gm-check-row compact">
                <input
                  type="checkbox"
                  checked={eventTemplateDraft.enabled}
                  onChange={(event) => setEventTemplateDraft({
                    ...eventTemplateDraft,
                    enabled: event.target.checked,
                  })}
                />
                <span>Включено</span>
              </label>
            </div>

            <div className="gm-event-template-fields">
              <label>
                <span>Название шаблона для GM</span>
                <input
                  value={eventTemplateDraft.name}
                  onChange={(event) => setEventTemplateDraft({
                    ...eventTemplateDraft,
                    name: event.target.value,
                  })}
                  placeholder="Например: Засада на лесной дороге"
                />
              </label>

              <div className="gm-sector-form-grid">
                <label>
                  <span>Местность</span>
                  <select
                    value={eventTemplateDraft.terrain_type ?? ''}
                    onChange={(event) => setEventTemplateDraft({
                      ...eventTemplateDraft,
                      terrain_type: event.target.value
                        ? event.target.value as SectorTerrain
                        : null,
                    })}
                  >
                    <option value="">Любая</option>
                    {terrainOptions
                      .filter((option) => option.value !== 'unassigned')
                      .map((option) => (
                        <option key={option.value} value={option.value}>{option.label}</option>
                      ))}
                  </select>
                </label>

                <label>
                  <span>Содержимое сектора</span>
                  <select
                    value={eventTemplateDraft.content_type ?? ''}
                    onChange={(event) => setEventTemplateDraft({
                      ...eventTemplateDraft,
                      content_type: event.target.value
                        ? event.target.value as SectorContentType
                        : null,
                    })}
                  >
                    <option value="">Любое</option>
                    {contentOptions
                      .filter((option) => option.value !== 'unassigned')
                      .map((option) => (
                        <option key={option.value} value={option.value}>{option.label}</option>
                      ))}
                  </select>
                </label>
              </div>

              <div className="gm-event-template-numbers">
                <label>
                  <span>Опасность от</span>
                  <input
                    type="number"
                    min={0}
                    max={5}
                    value={eventTemplateDraft.min_danger}
                    onChange={(event) => setEventTemplateDraft({
                      ...eventTemplateDraft,
                      min_danger: Math.max(0, Math.min(5, Number(event.target.value))),
                    })}
                  />
                </label>

                <label>
                  <span>до</span>
                  <input
                    type="number"
                    min={0}
                    max={5}
                    value={eventTemplateDraft.max_danger}
                    onChange={(event) => setEventTemplateDraft({
                      ...eventTemplateDraft,
                      max_danger: Math.max(0, Math.min(5, Number(event.target.value))),
                    })}
                  />
                </label>

                <label>
                  <span>Шанс %</span>
                  <input
                    type="number"
                    min={0}
                    max={100}
                    value={eventTemplateDraft.chance_percent}
                    onChange={(event) => setEventTemplateDraft({
                      ...eventTemplateDraft,
                      chance_percent: Math.max(0, Math.min(100, Number(event.target.value))),
                    })}
                  />
                </label>

                <label>
                  <span>Вес</span>
                  <input
                    type="number"
                    min={1}
                    max={1000}
                    value={eventTemplateDraft.weight}
                    onChange={(event) => setEventTemplateDraft({
                      ...eventTemplateDraft,
                      weight: Math.max(1, Math.min(1000, Number(event.target.value))),
                    })}
                  />
                </label>
              </div>

              <label className="gm-check-row">
                <input
                  type="checkbox"
                  checked={eventTemplateDraft.requires_gm}
                  onChange={(event) => setEventTemplateDraft({
                    ...eventTemplateDraft,
                    requires_gm: event.target.checked,
                  })}
                />
                <span>Остановить экспедицию и передать событие GM</span>
              </label>

              <label>
                <span>Название, которое увидит игрок</span>
                <input
                  value={eventTemplateDraft.title}
                  onChange={(event) => setEventTemplateDraft({
                    ...eventTemplateDraft,
                    title: event.target.value,
                  })}
                  placeholder="Шорох в чаще"
                />
              </label>

              <label>
                <span>Что происходит</span>
                <textarea
                  rows={4}
                  value={eventTemplateDraft.player_prompt}
                  onChange={(event) => setEventTemplateDraft({
                    ...eventTemplateDraft,
                    player_prompt: event.target.value,
                  })}
                  placeholder="Текст, который игрок увидит при срабатывании события."
                />
              </label>

              {!eventTemplateDraft.requires_gm && (
                <label>
                  <span>Автоматический итог</span>
                  <textarea
                    rows={3}
                    value={eventTemplateDraft.automatic_result}
                    onChange={(event) => setEventTemplateDraft({
                      ...eventTemplateDraft,
                      automatic_result: event.target.value,
                    })}
                    placeholder="Чем закончилось событие. После этого сектор откроется автоматически."
                  />
                </label>
              )}

              <label>
                <span>Секретная подсказка GM</span>
                <textarea
                  rows={3}
                  value={eventTemplateDraft.gm_notes}
                  onChange={(event) => setEventTemplateDraft({
                    ...eventTemplateDraft,
                    gm_notes: event.target.value,
                  })}
                  placeholder="Игрок это не видит."
                />
              </label>
            </div>

            <div className="gm-event-template-actions">
              <button
                className="primary-button"
                type="button"
                disabled={busy}
                onClick={() => void saveEventTemplate()}
              >
                {busy ? 'Сохраняем…' : eventTemplateDraft.id ? 'Сохранить изменения' : 'Создать шаблон'}
              </button>

              {eventTemplateDraft.id && (
                <button
                  className="ghost-button danger"
                  type="button"
                  disabled={busy}
                  onClick={() => void deleteEventTemplate(eventTemplateDraft.id!)}
                >
                  Удалить
                </button>
              )}
            </div>
          </div>
        </div>
      </article>

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

      <article className="panel">
        <div className="section-heading">
          <div>
            <span className="eyebrow">ЛОКАЛЬНЫЕ ИССЛЕДОВАНИЯ</span>
            <h2>Руины и разведка входов</h2>
          </div>
          <span className="badge">{siteActions.length}</span>
        </div>

        <div className="gm-expedition-list">
          {siteActions.length === 0 && (
            <p className="muted">Активных исследований руин или входов сейчас нет.</p>
          )}

          {siteActions.map((action) => {
            const character = characterById.get(action.character_id)
            return (
              <div className="gm-expedition-row" key={action.id}>
                <div>
                  <strong>{character?.name ?? 'Неизвестный персонаж'}</strong>
                  <span>
                    сектор #{action.sector_id} · {action.action_type === 'explore_ruins'
                      ? 'исследует руины'
                      : 'разведывает вход в подземелье'}
                  </span>
                </div>

                <button
                  className="ghost-button"
                  type="button"
                  disabled={busy}
                  onClick={() => void finishSiteAction(action.id)}
                >
                  Завершить сейчас
                </button>
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
                  <span className="badge">
                    {event.source_kind === 'random' ? 'случайное' : 'секторное'}
                  </span>
                </div>

                <p>{event.player_prompt || 'Описание события для игрока не задано.'}</p>
                {event.gm_notes && (
                  <p className="gm-event-secret-note">
                    <strong>GM:</strong> {event.gm_notes}
                  </p>
                )}

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
