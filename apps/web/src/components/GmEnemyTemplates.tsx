import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { DamageType, EnemyTemplate, SectorTerrain } from '../types'

const damageTypes: DamageType[] = [
  'slashing',
  'piercing',
  'blunt',
  'fire',
  'water',
  'earth',
  'air',
  'lightning',
  'ice',
]

const damageLabels: Record<DamageType, string> = {
  slashing: 'Режущий',
  piercing: 'Колющий',
  blunt: 'Дробящий',
  fire: 'Огненный',
  water: 'Водный',
  earth: 'Земляной',
  air: 'Воздушный',
  lightning: 'Электрический',
  ice: 'Ледяной',
}

const terrains: Array<{ value: SectorTerrain; label: string }> = [
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
  slug: string
  name: string
  description: string
  enabled: boolean
  terrain_type: SectorTerrain | null
  min_danger: number
  max_danger: number
  is_boss: boolean
  weight: number
  attack_damage_type: DamageType
  damage_resistances: Partial<Record<DamageType, number>>
  hp_multiplier: number
  attack_multiplier: number
  defense_multiplier: number
  initiative_multiplier: number
}

function emptyDraft(): Draft {
  return {
    id: null,
    slug: '',
    name: '',
    description: '',
    enabled: true,
    terrain_type: null,
    min_danger: 0,
    max_danger: 10,
    is_boss: false,
    weight: 1,
    attack_damage_type: 'slashing',
    damage_resistances: {},
    hp_multiplier: 1,
    attack_multiplier: 1,
    defense_multiplier: 1,
    initiative_multiplier: 1,
  }
}

export function GmEnemyTemplates() {
  const [templates, setTemplates] = useState<EnemyTemplate[]>([])
  const [draft, setDraft] = useState<Draft>(emptyDraft)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  async function loadTemplates() {
    const { data, error } = await supabase.rpc('get_gm_enemy_templates')

    if (error) {
      setMessage(error.message)
      return
    }

    setTemplates((data as EnemyTemplate[] | null) ?? [])
  }

  useEffect(() => {
    void loadTemplates()
  }, [])

  function edit(template: EnemyTemplate) {
    setDraft({
      id: template.id,
      slug: template.slug,
      name: template.name,
      description: template.description,
      enabled: template.enabled,
      terrain_type: template.terrain_type,
      min_danger: template.min_danger,
      max_danger: template.max_danger,
      is_boss: template.is_boss,
      weight: template.weight,
      attack_damage_type: template.attack_damage_type,
      damage_resistances: template.damage_resistances ?? {},
      hp_multiplier: Number(template.hp_multiplier),
      attack_multiplier: Number(template.attack_multiplier),
      defense_multiplier: Number(template.defense_multiplier),
      initiative_multiplier: Number(template.initiative_multiplier),
    })
    setMessage('')
  }

  async function save() {
    if (!draft.slug.trim() || !draft.name.trim()) {
      setMessage('Нужно задать slug и название врага.')
      return
    }

    setBusy(true)
    setMessage('')

    const { data, error } = await supabase.rpc('gm_save_enemy_template', {
      p_id: draft.id,
      p_slug: draft.slug.trim(),
      p_name: draft.name.trim(),
      p_description: draft.description,
      p_enabled: draft.enabled,
      p_terrain_type: draft.terrain_type,
      p_min_danger: draft.min_danger,
      p_max_danger: draft.max_danger,
      p_is_boss: draft.is_boss,
      p_weight: draft.weight,
      p_attack_damage_type: draft.attack_damage_type,
      p_damage_resistances: draft.damage_resistances,
      p_hp_multiplier: draft.hp_multiplier,
      p_attack_multiplier: draft.attack_multiplier,
      p_defense_multiplier: draft.defense_multiplier,
      p_initiative_multiplier: draft.initiative_multiplier,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    const savedId = data ? String(data) : draft.id
    await loadTemplates()
    if (!draft.id && savedId) setDraft({ ...draft, id: savedId })
    setMessage(draft.id ? 'Шаблон врага обновлён.' : 'Шаблон врага создан.')
    setBusy(false)
  }

  async function remove() {
    if (!draft.id) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('gm_delete_enemy_template', {
      p_id: draft.id,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    setDraft(emptyDraft())
    await loadTemplates()
    setMessage('Шаблон врага удалён.')
    setBusy(false)
  }

  function setResistance(type: DamageType, raw: string) {
    const value = Math.max(-75, Math.min(75, Number(raw) || 0))
    const next = { ...draft.damage_resistances }

    if (value === 0) {
      delete next[type]
    } else {
      next[type] = value
    }

    setDraft({ ...draft, damage_resistances: next })
  }

  return (
    <article className="panel gm-enemy-templates">
      <div className="section-heading">
        <div>
          <span className="eyebrow">ШАБЛОНЫ ВРАГОВ</span>
          <h2>Типы урона и сопротивления</h2>
          <p className="muted">
            Один и тот же шаблон всегда имеет один тип атаки и одинаковый набор сопротивлений/уязвимостей.
          </p>
        </div>
        <span className="badge">{templates.length}</span>
      </div>

      {message && <p className="gm-notice" aria-live="polite">{message}</p>}

      <div className="gm-enemy-layout">
        <div className="gm-enemy-list">
          <button className="ghost-button" type="button" onClick={() => setDraft(emptyDraft())}>
            + Новый шаблон
          </button>

          {templates.map((template) => (
            <button
              type="button"
              key={template.id}
              className={[
                'gm-enemy-card',
                draft.id === template.id ? 'active' : '',
                !template.enabled ? 'disabled' : '',
              ].filter(Boolean).join(' ')}
              onClick={() => edit(template)}
            >
              <div>
                <strong>{template.name}</strong>
                <span>{template.is_boss ? 'Босс' : 'Обычный'}</span>
              </div>
              <small>
                {damageLabels[template.attack_damage_type]} · {template.min_danger}–{template.max_danger}/10
              </small>
            </button>
          ))}
        </div>

        <div className="gm-enemy-editor">
          <div className="gm-sector-form-grid">
            <label>
              <span>Название</span>
              <input
                value={draft.name}
                onChange={(event) => setDraft({ ...draft, name: event.target.value })}
                placeholder="Каменный страж"
              />
            </label>
            <label>
              <span>Slug</span>
              <input
                value={draft.slug}
                onChange={(event) => setDraft({ ...draft, slug: event.target.value })}
                placeholder="stone_sentry"
              />
            </label>
          </div>

          <label>
            <span>Описание</span>
            <textarea
              rows={3}
              value={draft.description}
              onChange={(event) => setDraft({ ...draft, description: event.target.value })}
            />
          </label>

          <div className="gm-sector-form-grid">
            <label>
              <span>Местность</span>
              <select
                value={draft.terrain_type ?? ''}
                onChange={(event) => setDraft({
                  ...draft,
                  terrain_type: event.target.value
                    ? event.target.value as SectorTerrain
                    : null,
                })}
              >
                <option value="">Любая</option>
                {terrains.map((terrain) => (
                  <option key={terrain.value} value={terrain.value}>{terrain.label}</option>
                ))}
              </select>
            </label>

            <label>
              <span>Тип атаки</span>
              <select
                value={draft.attack_damage_type}
                onChange={(event) => setDraft({
                  ...draft,
                  attack_damage_type: event.target.value as DamageType,
                })}
              >
                {damageTypes.map((type) => (
                  <option key={type} value={type}>{damageLabels[type]}</option>
                ))}
              </select>
            </label>
          </div>

          <div className="gm-enemy-number-grid">
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
              <span>Вес спавна</span>
              <input
                type="number"
                min={1}
                max={1000}
                value={draft.weight}
                onChange={(event) => setDraft({
                  ...draft,
                  weight: Math.max(1, Math.min(1000, Number(event.target.value))),
                })}
              />
            </label>
          </div>

          <div className="gm-enemy-toggle-row">
            <label className="gm-check-row">
              <input
                type="checkbox"
                checked={draft.enabled}
                onChange={(event) => setDraft({ ...draft, enabled: event.target.checked })}
              />
              <span>Включён</span>
            </label>
            <label className="gm-check-row">
              <input
                type="checkbox"
                checked={draft.is_boss}
                onChange={(event) => setDraft({ ...draft, is_boss: event.target.checked })}
              />
              <span>Шаблон босса</span>
            </label>
          </div>

          <div className="gm-enemy-multipliers">
            <label>
              <span>HP ×</span>
              <input type="number" min={0.25} max={5} step={0.05} value={draft.hp_multiplier}
                onChange={(event) => setDraft({ ...draft, hp_multiplier: Number(event.target.value) })} />
            </label>
            <label>
              <span>Атака ×</span>
              <input type="number" min={0.25} max={5} step={0.05} value={draft.attack_multiplier}
                onChange={(event) => setDraft({ ...draft, attack_multiplier: Number(event.target.value) })} />
            </label>
            <label>
              <span>Защита ×</span>
              <input type="number" min={0.25} max={5} step={0.05} value={draft.defense_multiplier}
                onChange={(event) => setDraft({ ...draft, defense_multiplier: Number(event.target.value) })} />
            </label>
            <label>
              <span>Инициатива ×</span>
              <input type="number" min={0.25} max={5} step={0.05} value={draft.initiative_multiplier}
                onChange={(event) => setDraft({ ...draft, initiative_multiplier: Number(event.target.value) })} />
            </label>
          </div>

          <div className="gm-enemy-resistances">
            <div>
              <strong>Сопротивления / уязвимости</strong>
              <span>+% уменьшает урон, −% увеличивает. Диапазон −75…+75.</span>
            </div>
            <div className="gm-enemy-resistance-grid">
              {damageTypes.map((type) => (
                <label key={type}>
                  <span>{damageLabels[type]}</span>
                  <input
                    type="number"
                    min={-75}
                    max={75}
                    value={draft.damage_resistances[type] ?? 0}
                    onChange={(event) => setResistance(type, event.target.value)}
                  />
                </label>
              ))}
            </div>
          </div>

          <div className="gm-event-template-actions">
            <button className="primary-button" type="button" disabled={busy} onClick={() => void save()}>
              {busy ? 'Сохраняем…' : draft.id ? 'Сохранить шаблон' : 'Создать шаблон'}
            </button>
            {draft.id && (
              <button className="ghost-button danger" type="button" disabled={busy} onClick={() => void remove()}>
                Удалить
              </button>
            )}
          </div>
        </div>
      </div>
    </article>
  )
}
