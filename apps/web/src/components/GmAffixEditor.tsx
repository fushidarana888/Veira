import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type {
  DamageType,
  EquipmentAffix,
  EquipmentAffixEffectType,
  ItemEquipGroup,
} from '../types'

const statKeys = ['strength', 'agility', 'intellect', 'vitality', 'luck'] as const
const statLabels: Record<(typeof statKeys)[number], string> = {
  strength: 'Сила',
  agility: 'Ловкость',
  intellect: 'Интеллект',
  vitality: 'Живучесть',
  luck: 'Удача',
}

const damageTypes: DamageType[] = [
  'slashing', 'piercing', 'blunt',
  'fire', 'water', 'earth', 'air', 'lightning', 'ice',
]

const damageLabels: Record<DamageType, string> = {
  slashing: 'Режущий',
  piercing: 'Колющий',
  blunt: 'Дробящий',
  fire: 'Огонь',
  water: 'Вода',
  earth: 'Земля',
  air: 'Воздух',
  lightning: 'Молния',
  ice: 'Лёд',
}

const groups: ItemEquipGroup[] = [
  'weapon', 'offhand', 'head', 'chest', 'hands', 'legs', 'feet', 'accessory',
]

const groupLabels: Record<ItemEquipGroup, string> = {
  weapon: 'Оружие',
  offhand: 'Левая рука',
  head: 'Голова',
  chest: 'Тело',
  hands: 'Руки',
  legs: 'Ноги',
  feet: 'Ступни',
  accessory: 'Аксессуары',
}

const effectOptions: Array<{ value: EquipmentAffixEffectType; label: string }> = [
  { value: 'lifesteal', label: 'Вампиризм · %' },
  { value: 'mana_on_hit', label: 'Мана за попадание' },
  { value: 'damage_vs_wounded', label: 'Урон по раненым · %' },
  { value: 'guard_boost', label: 'Усиление блока · %' },
  { value: 'physical_damage_bonus', label: 'Физический урон · %' },
  { value: 'magic_damage_bonus', label: 'Магический урон · %' },
  { value: 'all_damage_bonus', label: 'Весь прямой урон · %' },
  { value: 'low_hp_damage_reduction', label: 'Защита при низком HP · %' },
  { value: 'boss_damage_bonus', label: 'Урон боссам · %' },
]

type Draft = Omit<EquipmentAffix, 'id' | 'created_at' | 'updated_at'> & { id: string | null }

function emptyDraft(): Draft {
  return {
    id: null,
    slug: '',
    name: '',
    description: '',
    enabled: true,
    min_rarity_rank: 2,
    max_rarity_rank: 5,
    weight: 100,
    allowed_categories: ['weapon', 'armor', 'accessory'],
    allowed_equip_groups: [],
    stat_modifiers: {},
    damage_resistances: {},
    unique_effect_type: null,
    unique_effect_value: 0,
  }
}

export function GmAffixEditor() {
  const [affixes, setAffixes] = useState<EquipmentAffix[]>([])
  const [draft, setDraft] = useState<Draft>(emptyDraft)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  async function load() {
    const { data, error } = await supabase.rpc('get_gm_equipment_affixes')
    if (error) {
      setMessage(error.message)
      return
    }
    setAffixes((data as EquipmentAffix[] | null) ?? [])
  }

  useEffect(() => { void load() }, [])

  function edit(affix: EquipmentAffix) {
    setDraft({
      id: affix.id,
      slug: affix.slug,
      name: affix.name,
      description: affix.description,
      enabled: affix.enabled,
      min_rarity_rank: affix.min_rarity_rank,
      max_rarity_rank: affix.max_rarity_rank,
      weight: affix.weight,
      allowed_categories: affix.allowed_categories ?? [],
      allowed_equip_groups: affix.allowed_equip_groups ?? [],
      stat_modifiers: affix.stat_modifiers ?? {},
      damage_resistances: affix.damage_resistances ?? {},
      unique_effect_type: affix.unique_effect_type,
      unique_effect_value: affix.unique_effect_value ?? 0,
    })
    setMessage('')
  }

  function toggleCategory(category: 'weapon' | 'armor' | 'accessory') {
    const exists = draft.allowed_categories.includes(category)
    const next = exists
      ? draft.allowed_categories.filter((value) => value !== category)
      : [...draft.allowed_categories, category]
    setDraft({ ...draft, allowed_categories: next })
  }

  function toggleGroup(group: ItemEquipGroup) {
    const exists = draft.allowed_equip_groups.includes(group)
    const next = exists
      ? draft.allowed_equip_groups.filter((value) => value !== group)
      : [...draft.allowed_equip_groups, group]
    setDraft({ ...draft, allowed_equip_groups: next })
  }

  function updateStat(key: string, raw: string) {
    const value = Math.max(-99, Math.min(99, Number(raw) || 0))
    const next = { ...draft.stat_modifiers }
    if (value === 0) delete next[key]
    else next[key] = value
    setDraft({ ...draft, stat_modifiers: next })
  }

  function updateResistance(type: DamageType, raw: string) {
    const value = Math.max(-75, Math.min(75, Number(raw) || 0))
    const next = { ...draft.damage_resistances }
    if (value === 0) delete next[type]
    else next[type] = value
    setDraft({ ...draft, damage_resistances: next })
  }

  async function save() {
    if (draft.allowed_categories.length === 0) {
      setMessage('Выбери хотя бы одну категорию предметов.')
      return
    }

    setBusy(true)
    setMessage('')

    const { data, error } = await supabase.rpc('gm_save_equipment_affix_v2', {
      p_id: draft.id,
      p_slug: draft.slug.trim(),
      p_name: draft.name.trim(),
      p_description: draft.description,
      p_enabled: draft.enabled,
      p_min_rarity_rank: draft.min_rarity_rank,
      p_max_rarity_rank: draft.max_rarity_rank,
      p_weight: draft.weight,
      p_allowed_categories: draft.allowed_categories,
      p_allowed_equip_groups: draft.allowed_equip_groups,
      p_stat_modifiers: draft.stat_modifiers,
      p_damage_resistances: draft.damage_resistances,
      p_unique_effect_type: draft.unique_effect_type,
      p_unique_effect_value: draft.unique_effect_value,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    await load()
    if (!draft.id && data) setDraft({ ...draft, id: String(data) })
    setMessage(draft.id ? 'Аффикс обновлён.' : 'Аффикс создан.')
    setBusy(false)
  }

  async function remove() {
    if (!draft.id) return
    if (!window.confirm(`Удалить аффикс «${draft.name}»?`)) return

    setBusy(true)
    const { error } = await supabase.rpc('gm_delete_equipment_affix', { p_id: draft.id })
    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    setDraft(emptyDraft())
    await load()
    setMessage('Аффикс удалён.')
    setBusy(false)
  }

  return (
    <div className="gm-content-layout">
      <aside className="panel gm-content-list">
        <button className="primary-button" type="button" onClick={() => setDraft(emptyDraft())}>
          + Новый аффикс
        </button>
        <div className="gm-content-list-group">
          <strong>Аффиксы · {affixes.length}</strong>
          {affixes.map((affix) => (
            <button
              type="button"
              key={affix.id}
              className={draft.id === affix.id ? 'active' : ''}
              onClick={() => edit(affix)}
            >
              <span>{affix.name}</span>
              <small>
                R{affix.min_rarity_rank}–{affix.max_rarity_rank}
                {affix.unique_effect_type ? ' · боевая пассивка' : ''}
              </small>
            </button>
          ))}
        </div>
      </aside>

      <article className="panel gm-content-form">
        <div className="section-heading">
          <div>
            <span className="eyebrow">АФФИКСЫ ЭКИПИРОВКИ</span>
            <h2>{draft.id ? draft.name || 'Редактирование' : 'Новый аффикс'}</h2>
            <p className="muted">
              Аффиксы бросаются при создании редкой экипировки. Они могут менять статы, сопротивления и теперь — сам стиль боя.
            </p>
          </div>
          <label className="gm-inline-check">
            <input type="checkbox" checked={draft.enabled} onChange={(event) => setDraft({ ...draft, enabled: event.target.checked })} />
            <span>Включён</span>
          </label>
        </div>

        {message && <p className="gm-notice" aria-live="polite">{message}</p>}

        <div className="gm-form-grid two">
          <label><span>Название</span><input value={draft.name} onChange={(e) => setDraft({ ...draft, name: e.target.value })} /></label>
          <label><span>Slug</span><input value={draft.slug} onChange={(e) => setDraft({ ...draft, slug: e.target.value })} /></label>
        </div>

        <label><span>Описание</span><textarea rows={3} value={draft.description} onChange={(e) => setDraft({ ...draft, description: e.target.value })} /></label>

        <div className="gm-form-grid three">
          <label><span>Редкость от</span><input type="number" min={1} max={6} value={draft.min_rarity_rank} onChange={(e) => setDraft({ ...draft, min_rarity_rank: Math.max(1, Math.min(6, Number(e.target.value))) })} /></label>
          <label><span>до</span><input type="number" min={1} max={6} value={draft.max_rarity_rank} onChange={(e) => setDraft({ ...draft, max_rarity_rank: Math.max(1, Math.min(6, Number(e.target.value))) })} /></label>
          <label><span>Вес выпадения</span><input type="number" min={1} value={draft.weight} onChange={(e) => setDraft({ ...draft, weight: Math.max(1, Number(e.target.value)) })} /></label>
        </div>

        <div className="gm-editor-box">
          <strong>Категории</strong>
          <div className="autobattle-checks">
            {(['weapon', 'armor', 'accessory'] as const).map((category) => (
              <label key={category}>
                <input type="checkbox" checked={draft.allowed_categories.includes(category)} onChange={() => toggleCategory(category)} />
                <span>{category === 'weapon' ? 'Оружие' : category === 'armor' ? 'Броня' : 'Аксессуары'}</span>
              </label>
            ))}
          </div>
        </div>

        <div className="gm-editor-box">
          <div><strong>Слоты</strong><small>Пустой выбор = любой подходящий слот</small></div>
          <div className="autobattle-checks">
            {groups.map((group) => (
              <label key={group}>
                <input type="checkbox" checked={draft.allowed_equip_groups.includes(group)} onChange={() => toggleGroup(group)} />
                <span>{groupLabels[group]}</span>
              </label>
            ))}
          </div>
        </div>

        <div className="gm-editor-box">
          <strong>Характеристики</strong>
          <div className="gm-form-grid five">
            {statKeys.map((key) => (
              <label key={key}>
                <span>{statLabels[key]}</span>
                <input type="number" min={-99} max={99} value={draft.stat_modifiers[key] ?? 0} onChange={(e) => updateStat(key, e.target.value)} />
              </label>
            ))}
          </div>
        </div>

        <div className="gm-editor-box">
          <strong>Сопротивления</strong>
          <div className="gm-form-grid three">
            {damageTypes.map((type) => (
              <label key={type}>
                <span>{damageLabels[type]}</span>
                <input type="number" min={-75} max={75} value={draft.damage_resistances[type] ?? 0} onChange={(e) => updateResistance(type, e.target.value)} />
              </label>
            ))}
          </div>
        </div>

        <div className="gm-editor-box">
          <div><strong>Боевая пассивка</strong><small>Можно оставить пустой и использовать обычные статы/резисты</small></div>
          <div className="gm-form-grid two">
            <label>
              <span>Эффект</span>
              <select
                value={draft.unique_effect_type ?? ''}
                onChange={(e) => setDraft({
                  ...draft,
                  unique_effect_type: e.target.value ? e.target.value as EquipmentAffixEffectType : null,
                  unique_effect_value: e.target.value ? Math.max(1, draft.unique_effect_value || 1) : 0,
                })}
              >
                <option value="">Нет</option>
                {effectOptions.map((effect) => <option key={effect.value} value={effect.value}>{effect.label}</option>)}
              </select>
            </label>
            <label>
              <span>Сила</span>
              <input
                type="number"
                min={0}
                max={100}
                disabled={!draft.unique_effect_type}
                value={draft.unique_effect_value}
                onChange={(e) => setDraft({ ...draft, unique_effect_value: Math.max(0, Math.min(100, Number(e.target.value))) })}
              />
            </label>
          </div>
        </div>

        <div className="gm-form-actions">
          <button className="primary-button" type="button" disabled={busy} onClick={() => void save()}>
            {busy ? 'Сохраняем…' : draft.id ? 'Сохранить аффикс' : 'Создать аффикс'}
          </button>
          {draft.id && (
            <button className="ghost-button danger-button" type="button" disabled={busy} onClick={() => void remove()}>
              Удалить
            </button>
          )}
        </div>
      </article>
    </div>
  )
}
