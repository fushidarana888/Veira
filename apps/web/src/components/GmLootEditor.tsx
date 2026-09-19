import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import type {
  EnemyTemplate,
  GmMapSector,
  ItemDefinition,
  LootPoolEntry,
  SectorTerrain,
} from '../types'

const terrainOptions: Array<{ value: SectorTerrain; label: string }> = [
  { value: 'plains', label: 'Равнины' },
  { value: 'forest', label: 'Лес' },
  { value: 'swamp', label: 'Болото' },
  { value: 'desert', label: 'Пустыня' },
  { value: 'mountains', label: 'Горы' },
  { value: 'tundra', label: 'Тундра' },
  { value: 'coast', label: 'Побережье' },
  { value: 'sea', label: 'Море' },
  { value: 'riverlands', label: 'Речные земли' },
]

type Draft = {
  id: string | null
  source_type: 'enemy' | 'dungeon'
  enemy_template_id: string | null
  sector_id: number | null
  terrain_type: SectorTerrain | null
  min_danger: number
  max_danger: number
  item_definition_id: string
  chance_percent: number
  min_quantity: number
  max_quantity: number
  enabled: boolean
}

function emptyDraft(): Draft {
  return {
    id: null,
    source_type: 'enemy',
    enemy_template_id: null,
    sector_id: null,
    terrain_type: null,
    min_danger: 0,
    max_danger: 10,
    item_definition_id: '',
    chance_percent: 10,
    min_quantity: 1,
    max_quantity: 1,
    enabled: true,
  }
}

export function GmLootEditor() {
  const [entries, setEntries] = useState<LootPoolEntry[]>([])
  const [items, setItems] = useState<ItemDefinition[]>([])
  const [enemies, setEnemies] = useState<EnemyTemplate[]>([])
  const [dungeons, setDungeons] = useState<GmMapSector[]>([])
  const [draft, setDraft] = useState<Draft>(emptyDraft)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  async function loadData() {
    const [entryResult, itemResult, enemyResult, mapResult] = await Promise.all([
      supabase.rpc('get_gm_loot_entries'),
      supabase.rpc('get_gm_item_definitions'),
      supabase.rpc('get_gm_enemy_templates'),
      supabase.rpc('get_gm_map_state'),
    ])

    const error =
      entryResult.error ??
      itemResult.error ??
      enemyResult.error ??
      mapResult.error

    if (error) {
      setMessage(error.message)
      return
    }

    setEntries((entryResult.data as LootPoolEntry[] | null) ?? [])
    setItems((itemResult.data as ItemDefinition[] | null) ?? [])
    setEnemies((enemyResult.data as EnemyTemplate[] | null) ?? [])
    setDungeons(
      ((mapResult.data as GmMapSector[] | null) ?? [])
        .filter((sector) => sector.content_type === 'dungeon'),
    )
  }

  useEffect(() => {
    void loadData()
  }, [])

  const grouped = useMemo(() => {
    return {
      enemy: entries.filter((entry) => entry.source_type === 'enemy'),
      dungeon: entries.filter((entry) => entry.source_type === 'dungeon'),
    }
  }, [entries])

  function edit(entry: LootPoolEntry) {
    setDraft({
      id: entry.id,
      source_type: entry.source_type,
      enemy_template_id: entry.enemy_template_id,
      sector_id: entry.sector_id,
      terrain_type: entry.terrain_type,
      min_danger: entry.min_danger,
      max_danger: entry.max_danger,
      item_definition_id: entry.item_definition_id,
      chance_percent: Number(entry.chance_percent),
      min_quantity: entry.min_quantity,
      max_quantity: entry.max_quantity,
      enabled: entry.enabled,
    })
    setMessage('')
  }

  async function save() {
    if (!draft.item_definition_id) {
      setMessage('Выбери предмет для выпадения.')
      return
    }

    setBusy(true)
    setMessage('')

    const { data, error } = await supabase.rpc('gm_save_loot_entry', {
      p_id: draft.id,
      p_source_type: draft.source_type,
      p_enemy_template_id: draft.source_type === 'enemy' ? draft.enemy_template_id : null,
      p_sector_id: draft.source_type === 'dungeon' ? draft.sector_id : null,
      p_terrain_type: draft.terrain_type,
      p_min_danger: draft.min_danger,
      p_max_danger: draft.max_danger,
      p_item_definition_id: draft.item_definition_id,
      p_chance_percent: draft.chance_percent,
      p_min_quantity: draft.min_quantity,
      p_max_quantity: draft.max_quantity,
      p_enabled: draft.enabled,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    await loadData()
    if (!draft.id && data) {
      setDraft({ ...draft, id: String(data) })
    }
    setMessage(draft.id ? 'Правило лута обновлено.' : 'Правило лута создано.')
    setBusy(false)
  }

  async function remove() {
    if (!draft.id) return
    if (!window.confirm('Удалить это правило выпадения?')) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('gm_delete_loot_entry', {
      p_id: draft.id,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    setDraft(emptyDraft())
    await loadData()
    setMessage('Правило лута удалено.')
    setBusy(false)
  }

  function itemName(id: string) {
    return items.find((item) => item.id === id)?.name ?? 'Предмет'
  }

  return (
    <section className="gm-loot-editor">
      <article className="panel">
        <div className="section-heading">
          <div>
            <span className="eyebrow">ЛУТ</span>
            <h2>Таблицы добычи</h2>
            <p className="muted">
              Можно задавать общий лут по сложности и местности, а затем добавлять отдельные правила конкретным врагам или подземельям.
            </p>
          </div>
          <span className="badge">{entries.length}</span>
        </div>
        {message && <p className="gm-notice" aria-live="polite">{message}</p>}
      </article>

      <div className="gm-content-layout">
        <aside className="panel gm-content-list">
          <button className="primary-button" type="button" onClick={() => setDraft(emptyDraft())}>
            + Новое правило
          </button>

          <div className="gm-content-list-group">
            <strong>Враги · {grouped.enemy.length}</strong>
            {grouped.enemy.map((entry) => (
              <button
                type="button"
                key={entry.id}
                className={draft.id === entry.id ? 'active' : ''}
                onClick={() => edit(entry)}
              >
                <span>{entry.item_name}</span>
                <small>
                  {entry.enemy_name ?? entry.terrain_type ?? 'Любой враг'}
                  {' · '}{Number(entry.chance_percent)}%
                  {' · '}{entry.min_danger}–{entry.max_danger}/10
                </small>
              </button>
            ))}
          </div>

          <div className="gm-content-list-group">
            <strong>Подземелья · {grouped.dungeon.length}</strong>
            {grouped.dungeon.map((entry) => (
              <button
                type="button"
                key={entry.id}
                className={draft.id === entry.id ? 'active' : ''}
                onClick={() => edit(entry)}
              >
                <span>{entry.item_name}</span>
                <small>
                  {entry.sector_name ?? entry.terrain_type ?? 'Любое подземелье'}
                  {' · '}{Number(entry.chance_percent)}%
                  {' · '}{entry.min_danger}–{entry.max_danger}/10
                </small>
              </button>
            ))}
          </div>
        </aside>

        <article className="panel gm-content-form">
          <div className="section-heading">
            <div>
              <span className="eyebrow">ПРАВИЛО ВЫПАДЕНИЯ</span>
              <h2>{draft.id ? itemName(draft.item_definition_id) : 'Новое правило'}</h2>
            </div>
            <label className="gm-inline-check">
              <input
                type="checkbox"
                checked={draft.enabled}
                onChange={(event) => setDraft({ ...draft, enabled: event.target.checked })}
              />
              <span>Включено</span>
            </label>
          </div>

          <div className="gm-form-grid two">
            <label>
              <span>Источник</span>
              <select
                value={draft.source_type}
                onChange={(event) => setDraft({
                  ...draft,
                  source_type: event.target.value as 'enemy' | 'dungeon',
                  enemy_template_id: null,
                  sector_id: null,
                })}
              >
                <option value="enemy">Победа над врагом</option>
                <option value="dungeon">Финальная награда подземелья</option>
              </select>
            </label>

            <label>
              <span>Предмет</span>
              <select
                value={draft.item_definition_id}
                onChange={(event) => setDraft({ ...draft, item_definition_id: event.target.value })}
              >
                <option value="">Выбрать предмет</option>
                {items.map((item) => (
                  <option key={item.id} value={item.id}>
                    {item.name} · {item.rarity} · T{item.shop_tier}
                  </option>
                ))}
              </select>
            </label>
          </div>

          {draft.source_type === 'enemy' ? (
            <label>
              <span>Конкретный враг</span>
              <select
                value={draft.enemy_template_id ?? ''}
                onChange={(event) => setDraft({
                  ...draft,
                  enemy_template_id: event.target.value || null,
                })}
              >
                <option value="">Любой враг</option>
                {enemies.map((enemy) => (
                  <option key={enemy.id} value={enemy.id}>
                    {enemy.name}{enemy.is_boss ? ' · босс' : ''}
                  </option>
                ))}
              </select>
            </label>
          ) : (
            <label>
              <span>Конкретное подземелье</span>
              <select
                value={draft.sector_id ?? ''}
                onChange={(event) => setDraft({
                  ...draft,
                  sector_id: event.target.value ? Number(event.target.value) : null,
                })}
              >
                <option value="">Любое подземелье</option>
                {dungeons.map((sector) => (
                  <option key={sector.id} value={sector.id}>
                    {sector.title || 'Сектор #' + sector.id} · #{sector.id}
                  </option>
                ))}
              </select>
            </label>
          )}

          <label>
            <span>Ограничение по местности</span>
            <select
              value={draft.terrain_type ?? ''}
              onChange={(event) => setDraft({
                ...draft,
                terrain_type: event.target.value ? event.target.value as SectorTerrain : null,
              })}
            >
              <option value="">Любая местность</option>
              {terrainOptions.map((terrain) => (
                <option key={terrain.value} value={terrain.value}>{terrain.label}</option>
              ))}
            </select>
          </label>

          <div className="gm-form-grid four">
            <label>
              <span>Сложность от</span>
              <input
                type="number"
                min={0}
                max={10}
                value={draft.min_danger}
                onChange={(event) => setDraft({
                  ...draft,
                  min_danger: Math.max(0, Math.min(10, Number(event.target.value))),
                })}
              />
            </label>
            <label>
              <span>до</span>
              <input
                type="number"
                min={0}
                max={10}
                value={draft.max_danger}
                onChange={(event) => setDraft({
                  ...draft,
                  max_danger: Math.max(0, Math.min(10, Number(event.target.value))),
                })}
              />
            </label>
            <label>
              <span>Шанс %</span>
              <input
                type="number"
                min={0}
                max={100}
                step={0.5}
                value={draft.chance_percent}
                onChange={(event) => setDraft({
                  ...draft,
                  chance_percent: Math.max(0, Math.min(100, Number(event.target.value))),
                })}
              />
            </label>
            <label>
              <span>Количество</span>
              <div className="loot-quantity-pair">
                <input
                  type="number"
                  min={1}
                  max={999}
                  value={draft.min_quantity}
                  onChange={(event) => setDraft({
                    ...draft,
                    min_quantity: Math.max(1, Math.min(999, Number(event.target.value))),
                  })}
                />
                <span>—</span>
                <input
                  type="number"
                  min={1}
                  max={999}
                  value={draft.max_quantity}
                  onChange={(event) => setDraft({
                    ...draft,
                    max_quantity: Math.max(1, Math.min(999, Number(event.target.value))),
                  })}
                />
              </div>
            </label>
          </div>

          <div className="gm-editor-box loot-rule-help">
            <strong>Как складываются правила</strong>
            <p className="muted">
              Все подходящие правила бросаются отдельно. Например, общий шанс на хилку и отдельный шанс на клык конкретного зверя могут сработать одновременно.
            </p>
          </div>

          <div className="gm-form-actions">
            <button className="primary-button" type="button" disabled={busy} onClick={() => void save()}>
              {busy ? 'Сохраняем…' : draft.id ? 'Сохранить правило' : 'Создать правило'}
            </button>

            {draft.id && (
              <button className="ghost-button danger-button" type="button" disabled={busy} onClick={() => void remove()}>
                Удалить
              </button>
            )}
          </div>
        </article>
      </div>
    </section>
  )
}
