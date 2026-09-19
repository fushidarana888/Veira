import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { GmCraftingEditor } from './GmCraftingEditor'
import { GmLootEditor } from './GmLootEditor'
import type {
  CombatStatusEffectType,
  DamageType,
  ElementalDamageType,
  ItemCategory,
  ItemDefinition,
  ItemEquipGroup,
  ItemRarity,
  SpellDefinition,
} from '../types'

const damageTypes: DamageType[] = [
  'slashing', 'piercing', 'blunt',
  'fire', 'water', 'earth', 'air', 'lightning', 'ice',
]

const elementalTypes: ElementalDamageType[] = [
  'fire', 'water', 'earth', 'air', 'lightning', 'ice',
]

const statusEffectOptions: Array<{ value: CombatStatusEffectType; label: string }> = [
  { value: 'burn', label: 'Горение' },
  { value: 'bleed', label: 'Кровотечение' },
  { value: 'poison', label: 'Яд' },
  { value: 'chill', label: 'Охлаждение' },
  { value: 'stun', label: 'Оглушение' },
  { value: 'weaken', label: 'Ослабление' },
  { value: 'vulnerable', label: 'Уязвимость' },
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

const categories: Array<{ value: ItemCategory; label: string }> = [
  { value: 'weapon', label: 'Оружие' },
  { value: 'armor', label: 'Броня' },
  { value: 'accessory', label: 'Аксессуар' },
  { value: 'consumable', label: 'Расходник' },
  { value: 'material', label: 'Материал' },
  { value: 'quest', label: 'Особый' },
]

const rarities: Array<{ value: ItemRarity; label: string }> = [
  { value: 'common', label: 'Обычный' },
  { value: 'uncommon', label: 'Необычный' },
  { value: 'rare', label: 'Редкий' },
  { value: 'epic', label: 'Эпический' },
  { value: 'legendary', label: 'Легендарный' },
  { value: 'unique', label: 'Уникальный' },
]

const equipGroups: Array<{ value: ItemEquipGroup; label: string }> = [
  { value: 'weapon', label: 'Оружие' },
  { value: 'offhand', label: 'Вторая рука' },
  { value: 'head', label: 'Голова' },
  { value: 'chest', label: 'Корпус' },
  { value: 'hands', label: 'Руки' },
  { value: 'legs', label: 'Ноги' },
  { value: 'feet', label: 'Обувь' },
  { value: 'accessory', label: 'Аксессуар' },
]

const statKeys = ['strength', 'agility', 'intellect', 'vitality', 'luck'] as const
const statLabels: Record<(typeof statKeys)[number], string> = {
  strength: 'Сила',
  agility: 'Ловкость',
  intellect: 'Интеллект',
  vitality: 'Живучесть',
  luck: 'Удача',
}

type ItemDraft = {
  id: string | null
  slug: string
  name: string
  description: string
  category: ItemCategory
  rarity: ItemRarity
  equip_group: ItemEquipGroup | null
  stackable: boolean
  max_stack: number
  stat_modifiers: Record<string, number>
  heal_amount: number
  mana_amount: number
  base_value: number
  required_level: number
  shop_tier: number
  shop_price: number
  shop_enabled: boolean
  damage_type: DamageType | null
  damage_resistances: Partial<Record<DamageType, number>>
  scroll_spell_id: string | null
  scroll_mode: 'learn' | 'cast' | null
  unique_property_name: string
  unique_property_description: string
  unique_effect_type: 'lifesteal' | 'mana_on_hit' | 'damage_vs_wounded' | 'guard_boost' | null
  unique_effect_value: number
}

type SpellDraft = {
  id: string | null
  slug: string
  name: string
  description: string
  enabled: boolean
  spell_kind: 'damage' | 'heal'
  damage_type: ElementalDamageType | null
  mana_cost: number
  required_level: number
  power_multiplier: number
  flat_power: number
  status_effect_type: CombatStatusEffectType | null
  status_effect_chance: number
  status_effect_turns: number
  status_effect_potency: number
}

function emptyItem(): ItemDraft {
  return {
    id: null,
    slug: '',
    name: '',
    description: '',
    category: 'weapon',
    rarity: 'common',
    equip_group: 'weapon',
    stackable: false,
    max_stack: 1,
    stat_modifiers: {},
    heal_amount: 0,
    mana_amount: 0,
    base_value: 0,
    required_level: 1,
    shop_tier: 0,
    shop_price: 0,
    shop_enabled: false,
    damage_type: 'slashing',
    damage_resistances: {},
    scroll_spell_id: null,
    scroll_mode: null,
    unique_property_name: '',
    unique_property_description: '',
    unique_effect_type: null,
    unique_effect_value: 0,
  }
}

function emptySpell(): SpellDraft {
  return {
    id: null,
    slug: '',
    name: '',
    description: '',
    enabled: true,
    spell_kind: 'damage',
    damage_type: 'fire',
    mana_cost: 15,
    required_level: 1,
    power_multiplier: 1,
    flat_power: 0,
    status_effect_type: null,
    status_effect_chance: 0,
    status_effect_turns: 0,
    status_effect_potency: 0,
  }
}

function resourceAmount(item: ItemDefinition, type: 'heal_hp' | 'restore_mana') {
  let total = 0
  for (const effect of item.effects ?? []) {
    if (
      effect &&
      typeof effect === 'object' &&
      'type' in effect &&
      'amount' in effect &&
      (effect as { type?: unknown }).type === type
    ) {
      total += Math.max(0, Number((effect as { amount?: unknown }).amount) || 0)
    }
  }
  return total
}

function healingAmount(item: ItemDefinition) {
  return resourceAmount(item, 'heal_hp')
}

function manaAmount(item: ItemDefinition) {
  return resourceAmount(item, 'restore_mana')
}

export function GmItemsAndSpells() {
  const [section, setSection] = useState<'items' | 'spells' | 'loot' | 'crafting'>('items')
  const [items, setItems] = useState<ItemDefinition[]>([])
  const [spells, setSpells] = useState<SpellDefinition[]>([])
  const [itemDraft, setItemDraft] = useState<ItemDraft>(emptyItem)
  const [spellDraft, setSpellDraft] = useState<SpellDraft>(emptySpell)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  async function loadData() {
    const [itemResult, spellResult] = await Promise.all([
      supabase.rpc('get_gm_item_definitions'),
      supabase.rpc('get_gm_spell_definitions'),
    ])

    const error = itemResult.error ?? spellResult.error
    if (error) {
      setMessage(error.message)
      return
    }

    setItems((itemResult.data as ItemDefinition[] | null) ?? [])
    setSpells((spellResult.data as SpellDefinition[] | null) ?? [])
  }

  useEffect(() => {
    void loadData()
  }, [])

  const itemByCategory = useMemo(() => {
    const result = new Map<ItemCategory, ItemDefinition[]>()
    for (const item of items) {
      const list = result.get(item.category) ?? []
      list.push(item)
      result.set(item.category, list)
    }
    return result
  }, [items])

  function editItem(item: ItemDefinition) {
    setItemDraft({
      id: item.id,
      slug: item.slug,
      name: item.name,
      description: item.description,
      category: item.category,
      rarity: item.rarity,
      equip_group: item.equip_group,
      stackable: item.stackable,
      max_stack: item.max_stack,
      stat_modifiers: item.stat_modifiers ?? {},
      heal_amount: healingAmount(item),
      mana_amount: manaAmount(item),
      base_value: item.base_value,
      required_level: item.required_level,
      shop_tier: item.shop_tier,
      shop_price: item.shop_price,
      shop_enabled: item.shop_enabled,
      damage_type: item.damage_type,
      damage_resistances: item.damage_resistances ?? {},
      scroll_spell_id: item.scroll_spell_id,
      scroll_mode: item.scroll_mode,
      unique_property_name: item.unique_property_name ?? '',
      unique_property_description: item.unique_property_description ?? '',
      unique_effect_type: item.unique_effect_type,
      unique_effect_value: item.unique_effect_value ?? 0,
    })
    setMessage('')
  }

  function editSpell(spell: SpellDefinition) {
    setSpellDraft({
      id: spell.id,
      slug: spell.slug,
      name: spell.name,
      description: spell.description,
      enabled: spell.enabled,
      spell_kind: spell.spell_kind,
      damage_type: spell.damage_type,
      mana_cost: spell.mana_cost,
      required_level: spell.required_level,
      power_multiplier: Number(spell.power_multiplier),
      flat_power: spell.flat_power,
      status_effect_type: spell.status_effect_type,
      status_effect_chance: spell.status_effect_chance,
      status_effect_turns: spell.status_effect_turns,
      status_effect_potency: spell.status_effect_potency,
    })
    setMessage('')
  }

  function updateStat(key: string, raw: string) {
    const value = Math.max(-99, Math.min(99, Number(raw) || 0))
    const next = { ...itemDraft.stat_modifiers }
    if (value === 0) delete next[key]
    else next[key] = value
    setItemDraft({ ...itemDraft, stat_modifiers: next })
  }

  function updateResistance(type: DamageType, raw: string) {
    const value = Math.max(-75, Math.min(75, Number(raw) || 0))
    const next = { ...itemDraft.damage_resistances }
    if (value === 0) delete next[type]
    else next[type] = value
    setItemDraft({ ...itemDraft, damage_resistances: next })
  }

  async function saveItem() {
    setBusy(true)
    setMessage('')

    const { data, error } = await supabase.rpc('gm_save_item_definition', {
      p_id: itemDraft.id,
      p_slug: itemDraft.slug.trim(),
      p_name: itemDraft.name.trim(),
      p_description: itemDraft.description,
      p_category: itemDraft.category,
      p_rarity: itemDraft.rarity,
      p_equip_group: itemDraft.equip_group,
      p_stackable: itemDraft.stackable,
      p_max_stack: itemDraft.max_stack,
      p_stat_modifiers: itemDraft.stat_modifiers,
      p_heal_amount: itemDraft.heal_amount,
      p_base_value: itemDraft.base_value,
      p_required_level: itemDraft.required_level,
      p_shop_tier: itemDraft.shop_tier,
      p_shop_price: itemDraft.shop_price,
      p_shop_enabled: itemDraft.shop_enabled,
      p_damage_type: itemDraft.damage_type,
      p_damage_resistances: itemDraft.damage_resistances,
      p_scroll_spell_id: itemDraft.scroll_spell_id,
      p_scroll_mode: itemDraft.scroll_mode,
      p_unique_property_name: itemDraft.unique_property_name || null,
      p_unique_property_description: itemDraft.unique_property_description,
      p_unique_effect_type: itemDraft.unique_effect_type,
      p_unique_effect_value: itemDraft.unique_effect_value,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    const savedId = data ? String(data) : itemDraft.id

    if (!savedId) {
      setMessage('Предмет сохранён, но не удалось получить его ID.')
      setBusy(false)
      return
    }

    if (itemDraft.category === 'consumable') {
      const { error: manaError } = await supabase.rpc('gm_set_item_mana_restore', {
        p_item_id: savedId,
        p_mana_amount: itemDraft.mana_amount,
      })

      if (manaError) {
        setMessage(manaError.message)
        setBusy(false)
        return
      }
    }

    await loadData()
    if (!itemDraft.id) setItemDraft({ ...itemDraft, id: savedId })
    setMessage(itemDraft.id ? 'Предмет обновлён.' : 'Предмет создан.')
    setBusy(false)
  }

  async function deleteItem() {
    if (!itemDraft.id) return
    if (!window.confirm(`Удалить предмет «${itemDraft.name}»?`)) return

    setBusy(true)
    setMessage('')
    const { error } = await supabase.rpc('gm_delete_item_definition', { p_id: itemDraft.id })

    if (error) {
      setMessage(
        error.message.includes('ITEM_IN_USE')
          ? 'Предмет уже существует у игроков. Его нельзя удалить — отключи продажу вместо этого.'
          : error.message,
      )
      setBusy(false)
      return
    }

    setItemDraft(emptyItem())
    await loadData()
    setMessage('Предмет удалён.')
    setBusy(false)
  }

  async function saveSpell() {
    setBusy(true)
    setMessage('')

    const { data, error } = await supabase.rpc('gm_save_spell_definition', {
      p_id: spellDraft.id,
      p_slug: spellDraft.slug.trim(),
      p_name: spellDraft.name.trim(),
      p_description: spellDraft.description,
      p_enabled: spellDraft.enabled,
      p_spell_kind: spellDraft.spell_kind,
      p_damage_type: spellDraft.spell_kind === 'damage' ? spellDraft.damage_type : null,
      p_mana_cost: spellDraft.mana_cost,
      p_required_level: spellDraft.required_level,
      p_power_multiplier: spellDraft.power_multiplier,
      p_flat_power: spellDraft.flat_power,
      p_status_effect_type: spellDraft.status_effect_type,
      p_status_effect_chance: spellDraft.status_effect_chance,
      p_status_effect_turns: spellDraft.status_effect_turns,
      p_status_effect_potency: spellDraft.status_effect_potency,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    await loadData()
    if (!spellDraft.id && data) setSpellDraft({ ...spellDraft, id: String(data) })
    setMessage(spellDraft.id ? 'Заклинание обновлено.' : 'Заклинание создано.')
    setBusy(false)
  }

  async function deleteSpell() {
    if (!spellDraft.id) return
    if (!window.confirm(`Удалить заклинание «${spellDraft.name}»?`)) return

    setBusy(true)
    setMessage('')
    const { error } = await supabase.rpc('gm_delete_spell_definition', { p_id: spellDraft.id })

    if (error) {
      setMessage(
        error.message.includes('SPELL_IN_USE')
          ? 'Заклинание уже связано со свитками или изучено персонажами. Его можно отключить, но не удалить.'
          : error.message,
      )
      setBusy(false)
      return
    }

    setSpellDraft(emptySpell())
    await loadData()
    setMessage('Заклинание удалено.')
    setBusy(false)
  }

  return (
    <section className="gm-content-editor">
      <article className="panel">
        <div className="section-heading">
          <div>
            <span className="eyebrow">КОНТЕНТ RPG</span>
            <h2>Предметы и магия</h2>
          </div>
          <div className="gm-editor-switch">
            <button
              type="button"
              className={section === 'items' ? 'active' : ''}
              onClick={() => setSection('items')}
            >
              Предметы · {items.length}
            </button>
            <button
              type="button"
              className={section === 'spells' ? 'active' : ''}
              onClick={() => setSection('spells')}
            >
              Заклинания · {spells.length}
            </button>
            <button
              type="button"
              className={section === 'crafting' ? 'active' : ''}
              onClick={() => setSection('crafting')}
            >
              Ремесло
            </button>
            <button
              type="button"
              className={section === 'loot' ? 'active' : ''}
              onClick={() => setSection('loot')}
            >
              Лут
            </button>
          </div>
        </div>

        {message && <p className="gm-notice" aria-live="polite">{message}</p>}
      </article>

      {section === 'items' ? (
        <div className="gm-content-layout">
          <aside className="panel gm-content-list">
            <button className="primary-button" type="button" onClick={() => setItemDraft(emptyItem())}>
              + Новый предмет
            </button>

            {categories.map((category) => {
              const list = itemByCategory.get(category.value) ?? []
              if (list.length === 0) return null

              return (
                <div className="gm-content-list-group" key={category.value}>
                  <strong>{category.label}</strong>
                  {list.map((item) => (
                    <button
                      type="button"
                      key={item.id}
                      className={itemDraft.id === item.id ? 'active' : ''}
                      onClick={() => editItem(item)}
                    >
                      <span>{item.name}</span>
                      <small>T{item.shop_tier} · ур. {item.required_level}</small>
                    </button>
                  ))}
                </div>
              )
            })}
          </aside>

          <article className="panel gm-content-form">
            <div className="section-heading">
              <div>
                <span className="eyebrow">ПРЕДМЕТ</span>
                <h2>{itemDraft.id ? itemDraft.name || 'Редактирование' : 'Новый предмет'}</h2>
              </div>
              {itemDraft.id && <span className="badge">{itemDraft.slug}</span>}
            </div>

            <div className="gm-form-grid two">
              <label><span>Название</span><input value={itemDraft.name} onChange={(e) => setItemDraft({ ...itemDraft, name: e.target.value })} /></label>
              <label><span>Slug</span><input value={itemDraft.slug} onChange={(e) => setItemDraft({ ...itemDraft, slug: e.target.value })} /></label>
            </div>

            <label><span>Описание</span><textarea rows={3} value={itemDraft.description} onChange={(e) => setItemDraft({ ...itemDraft, description: e.target.value })} /></label>

            <div className="gm-form-grid three">
              <label>
                <span>Категория</span>
                <select value={itemDraft.category} onChange={(e) => setItemDraft({ ...itemDraft, category: e.target.value as ItemCategory })}>
                  {categories.map((v) => <option key={v.value} value={v.value}>{v.label}</option>)}
                </select>
              </label>
              <label>
                <span>Редкость</span>
                <select value={itemDraft.rarity} onChange={(e) => setItemDraft({ ...itemDraft, rarity: e.target.value as ItemRarity })}>
                  {rarities.map((v) => <option key={v.value} value={v.value}>{v.label}</option>)}
                </select>
              </label>
              <label>
                <span>Слот</span>
                <select value={itemDraft.equip_group ?? ''} onChange={(e) => setItemDraft({ ...itemDraft, equip_group: e.target.value ? e.target.value as ItemEquipGroup : null })}>
                  <option value="">Не экипируется</option>
                  {equipGroups.map((v) => <option key={v.value} value={v.value}>{v.label}</option>)}
                </select>
              </label>
            </div>

            <div className="gm-form-grid four">
              <label><span>Требуемый уровень</span><input type="number" min={1} value={itemDraft.required_level} onChange={(e) => setItemDraft({ ...itemDraft, required_level: Math.max(1, Number(e.target.value)) })} /></label>
              <label><span>Тир магазина</span><input type="number" min={0} max={10} value={itemDraft.shop_tier} onChange={(e) => setItemDraft({ ...itemDraft, shop_tier: Math.max(0, Math.min(10, Number(e.target.value))) })} /></label>
              <label><span>Цена</span><input type="number" min={0} value={itemDraft.shop_price} onChange={(e) => setItemDraft({ ...itemDraft, shop_price: Math.max(0, Number(e.target.value)) })} /></label>
              <label><span>Базовая ценность</span><input type="number" min={0} value={itemDraft.base_value} onChange={(e) => setItemDraft({ ...itemDraft, base_value: Math.max(0, Number(e.target.value)) })} /></label>
            </div>

            <div className="gm-check-strip">
              <label><input type="checkbox" checked={itemDraft.shop_enabled} onChange={(e) => setItemDraft({ ...itemDraft, shop_enabled: e.target.checked })} /><span>Продаётся в магазинах</span></label>
              <label><input type="checkbox" checked={itemDraft.stackable} onChange={(e) => setItemDraft({ ...itemDraft, stackable: e.target.checked, max_stack: e.target.checked ? Math.max(2, itemDraft.max_stack) : 1 })} /><span>Складывается в стак</span></label>
              {itemDraft.stackable && (
                <label><span>Макс.</span><input type="number" min={2} max={999} value={itemDraft.max_stack} onChange={(e) => setItemDraft({ ...itemDraft, max_stack: Math.max(2, Math.min(999, Number(e.target.value))) })} /></label>
              )}
            </div>

            <div className="gm-editor-box">
              <strong>Характеристики</strong>
              <div className="gm-form-grid five">
                {statKeys.map((key) => (
                  <label key={key}>
                    <span>{statLabels[key]}</span>
                    <input type="number" min={-99} max={99} value={itemDraft.stat_modifiers[key] ?? 0} onChange={(e) => updateStat(key, e.target.value)} />
                  </label>
                ))}
              </div>
            </div>

            <div className="gm-form-grid three">
              <label>
                <span>Тип урона оружия</span>
                <select value={itemDraft.damage_type ?? ''} onChange={(e) => setItemDraft({ ...itemDraft, damage_type: e.target.value ? e.target.value as DamageType : null })}>
                  <option value="">Нет</option>
                  {damageTypes.map((type) => <option key={type} value={type}>{damageLabels[type]}</option>)}
                </select>
              </label>
              <label>
                <span>Лечение HP</span>
                <input
                  type="number"
                  min={0}
                  disabled={itemDraft.category !== 'consumable' || itemDraft.scroll_mode != null}
                  value={itemDraft.heal_amount}
                  onChange={(e) => setItemDraft({ ...itemDraft, heal_amount: Math.max(0, Number(e.target.value)) })}
                />
              </label>
              <label>
                <span>Восстановление маны</span>
                <input
                  type="number"
                  min={0}
                  disabled={itemDraft.category !== 'consumable' || itemDraft.scroll_mode != null}
                  value={itemDraft.mana_amount}
                  onChange={(e) => setItemDraft({ ...itemDraft, mana_amount: Math.max(0, Number(e.target.value)) })}
                />
              </label>
            </div>

            <div className="gm-editor-box">
              <div>
                <strong>Сопротивления / уязвимости</strong>
                <small>От −75% до +75%</small>
              </div>
              <div className="gm-form-grid three">
                {damageTypes.map((type) => (
                  <label key={type}>
                    <span>{damageLabels[type]}</span>
                    <input type="number" min={-75} max={75} value={itemDraft.damage_resistances[type] ?? 0} onChange={(e) => updateResistance(type, e.target.value)} />
                  </label>
                ))}
              </div>
            </div>

            {itemDraft.category === 'consumable' && (
              <div className="gm-editor-box">
                <strong>Свиток заклинания</strong>
                <div className="gm-form-grid two">
                  <label>
                    <span>Режим</span>
                    <select
                      value={itemDraft.scroll_mode ?? ''}
                      onChange={(e) => setItemDraft({
                        ...itemDraft,
                        scroll_mode: e.target.value ? e.target.value as 'learn' | 'cast' : null,
                        scroll_spell_id: e.target.value ? itemDraft.scroll_spell_id : null,
                        heal_amount: e.target.value ? 0 : itemDraft.heal_amount,
                        mana_amount: e.target.value ? 0 : itemDraft.mana_amount,
                      })}
                    >
                      <option value="">Не свиток</option>
                      <option value="learn">Изучает навсегда</option>
                      <option value="cast">Одноразовый боевой каст</option>
                    </select>
                  </label>
                  <label>
                    <span>Заклинание</span>
                    <select
                      value={itemDraft.scroll_spell_id ?? ''}
                      disabled={!itemDraft.scroll_mode}
                      onChange={(e) => setItemDraft({ ...itemDraft, scroll_spell_id: e.target.value || null })}
                    >
                      <option value="">Выбрать</option>
                      {spells.map((spell) => <option key={spell.id} value={spell.id}>{spell.name}</option>)}
                    </select>
                  </label>
                </div>
              </div>
            )}

            {itemDraft.equip_group && (
              <div className="gm-editor-box">
                <div>
                  <strong>Уникальное свойство</strong>
                  <small>Фиксированный эффект предмета, не случайный аффикс</small>
                </div>

                <div className="gm-form-grid two">
                  <label>
                    <span>Тип эффекта</span>
                    <select
                      value={itemDraft.unique_effect_type ?? ''}
                      onChange={(e) => setItemDraft({
                        ...itemDraft,
                        unique_effect_type: e.target.value
                          ? e.target.value as ItemDraft['unique_effect_type']
                          : null,
                        unique_effect_value: e.target.value ? itemDraft.unique_effect_value : 0,
                        unique_property_name: e.target.value ? itemDraft.unique_property_name : '',
                        unique_property_description: e.target.value ? itemDraft.unique_property_description : '',
                      })}
                    >
                      <option value="">Нет</option>
                      <option value="lifesteal">Вампиризм · % от прямого урона</option>
                      <option value="mana_on_hit">Мана при попадании · фикс.</option>
                      <option value="damage_vs_wounded">Добивание · % урона при HP ≤30%</option>
                      <option value="guard_boost">Усиление защиты · процентные пункты</option>
                    </select>
                  </label>

                  <label>
                    <span>Значение</span>
                    <input
                      type="number"
                      min={0}
                      max={100}
                      disabled={!itemDraft.unique_effect_type}
                      value={itemDraft.unique_effect_value}
                      onChange={(e) => setItemDraft({
                        ...itemDraft,
                        unique_effect_value: Math.max(0, Math.min(100, Number(e.target.value))),
                      })}
                    />
                  </label>
                </div>

                <div className="gm-form-grid two">
                  <label>
                    <span>Название свойства</span>
                    <input
                      disabled={!itemDraft.unique_effect_type}
                      value={itemDraft.unique_property_name}
                      onChange={(e) => setItemDraft({ ...itemDraft, unique_property_name: e.target.value })}
                      placeholder="Жажда жизни"
                    />
                  </label>
                  <label>
                    <span>Описание</span>
                    <input
                      disabled={!itemDraft.unique_effect_type}
                      value={itemDraft.unique_property_description}
                      onChange={(e) => setItemDraft({ ...itemDraft, unique_property_description: e.target.value })}
                      placeholder="Восстанавливает часть нанесённого урона как HP"
                    />
                  </label>
                </div>
              </div>
            )}

            <div className="gm-form-actions">
              <button className="primary-button" type="button" disabled={busy} onClick={() => void saveItem()}>
                {busy ? 'Сохраняем…' : itemDraft.id ? 'Сохранить предмет' : 'Создать предмет'}
              </button>
              {itemDraft.id && (
                <button className="ghost-button danger-button" type="button" disabled={busy} onClick={() => void deleteItem()}>
                  Удалить
                </button>
              )}
            </div>
          </article>
        </div>
      ) : section === 'spells' ? (
        <div className="gm-content-layout">
          <aside className="panel gm-content-list">
            <button className="primary-button" type="button" onClick={() => setSpellDraft(emptySpell())}>
              + Новое заклинание
            </button>

            {spells.map((spell) => (
              <button
                type="button"
                key={spell.id}
                className={spellDraft.id === spell.id ? 'active' : ''}
                onClick={() => editSpell(spell)}
              >
                <span>{spell.name}</span>
                <small>
                  {spell.damage_type ? damageLabels[spell.damage_type] : spell.spell_kind}
                  {' · '}{spell.mana_cost} MP
                </small>
              </button>
            ))}
          </aside>

          <article className="panel gm-content-form">
            <div className="section-heading">
              <div>
                <span className="eyebrow">ЗАКЛИНАНИЕ</span>
                <h2>{spellDraft.id ? spellDraft.name || 'Редактирование' : 'Новое заклинание'}</h2>
              </div>
              <label className="gm-inline-check">
                <input type="checkbox" checked={spellDraft.enabled} onChange={(e) => setSpellDraft({ ...spellDraft, enabled: e.target.checked })} />
                <span>Включено</span>
              </label>
            </div>

            <div className="gm-form-grid two">
              <label><span>Название</span><input value={spellDraft.name} onChange={(e) => setSpellDraft({ ...spellDraft, name: e.target.value })} /></label>
              <label><span>Slug</span><input value={spellDraft.slug} onChange={(e) => setSpellDraft({ ...spellDraft, slug: e.target.value })} /></label>
            </div>

            <label><span>Описание</span><textarea rows={4} value={spellDraft.description} onChange={(e) => setSpellDraft({ ...spellDraft, description: e.target.value })} /></label>

            <div className="gm-form-grid three">
              <label>
                <span>Тип</span>
                <select value={spellDraft.spell_kind} onChange={(e) => setSpellDraft({ ...spellDraft, spell_kind: e.target.value as 'damage' | 'heal', damage_type: e.target.value === 'damage' ? spellDraft.damage_type ?? 'fire' : null })}>
                  <option value="damage">Урон</option>
                  <option value="heal">Лечение (заготовка)</option>
                </select>
              </label>
              <label>
                <span>Стихия</span>
                <select disabled={spellDraft.spell_kind !== 'damage'} value={spellDraft.damage_type ?? ''} onChange={(e) => setSpellDraft({ ...spellDraft, damage_type: e.target.value as ElementalDamageType })}>
                  {elementalTypes.map((type) => <option key={type} value={type}>{damageLabels[type]}</option>)}
                </select>
              </label>
              <label><span>Мана</span><input type="number" min={0} value={spellDraft.mana_cost} onChange={(e) => setSpellDraft({ ...spellDraft, mana_cost: Math.max(0, Number(e.target.value)) })} /></label>
            </div>

            <div className="gm-form-grid three">
              <label><span>Требуемый уровень</span><input type="number" min={1} value={spellDraft.required_level} onChange={(e) => setSpellDraft({ ...spellDraft, required_level: Math.max(1, Number(e.target.value)) })} /></label>
              <label><span>Множитель силы</span><input type="number" min={0} max={10} step={0.05} value={spellDraft.power_multiplier} onChange={(e) => setSpellDraft({ ...spellDraft, power_multiplier: Math.max(0, Number(e.target.value)) })} /></label>
              <label><span>Плоский бонус</span><input type="number" min={0} value={spellDraft.flat_power} onChange={(e) => setSpellDraft({ ...spellDraft, flat_power: Math.max(0, Number(e.target.value)) })} /></label>
            </div>

            <div className="gm-editor-box">
              <div>
                <strong>Дополнительный боевой эффект</strong>
                <small>Накладывается поверх основного урона заклинания</small>
              </div>

              <div className="gm-form-grid four">
                <label>
                  <span>Эффект</span>
                  <select
                    value={spellDraft.status_effect_type ?? ''}
                    onChange={(e) => setSpellDraft({
                      ...spellDraft,
                      status_effect_type: e.target.value ? e.target.value as CombatStatusEffectType : null,
                      status_effect_chance: e.target.value ? Math.max(1, spellDraft.status_effect_chance || 25) : 0,
                      status_effect_turns: e.target.value ? Math.max(1, spellDraft.status_effect_turns || 1) : 0,
                      status_effect_potency: e.target.value ? spellDraft.status_effect_potency : 0,
                    })}
                  >
                    <option value="">Нет</option>
                    {statusEffectOptions.map((effect) => (
                      <option key={effect.value} value={effect.value}>{effect.label}</option>
                    ))}
                  </select>
                </label>

                <label>
                  <span>Шанс %</span>
                  <input
                    type="number"
                    min={0}
                    max={100}
                    disabled={!spellDraft.status_effect_type}
                    value={spellDraft.status_effect_chance}
                    onChange={(e) => setSpellDraft({
                      ...spellDraft,
                      status_effect_chance: Math.max(0, Math.min(100, Number(e.target.value))),
                    })}
                  />
                </label>

                <label>
                  <span>Ходов</span>
                  <input
                    type="number"
                    min={0}
                    max={10}
                    disabled={!spellDraft.status_effect_type}
                    value={spellDraft.status_effect_turns}
                    onChange={(e) => setSpellDraft({
                      ...spellDraft,
                      status_effect_turns: Math.max(0, Math.min(10, Number(e.target.value))),
                    })}
                  />
                </label>

                <label>
                  <span>Сила эффекта</span>
                  <input
                    type="number"
                    min={0}
                    max={1000}
                    disabled={!spellDraft.status_effect_type}
                    value={spellDraft.status_effect_potency}
                    onChange={(e) => setSpellDraft({
                      ...spellDraft,
                      status_effect_potency: Math.max(0, Number(e.target.value)),
                    })}
                  />
                </label>
              </div>

              <p className="muted">
                Горение, кровотечение и яд используют силу как урон за ход. Охлаждение и ослабление — как процент снижения урона. Уязвимость — как процент дополнительного входящего урона. Для оглушения сила не нужна.
              </p>
            </div>

            <p className="muted">
              {spellDraft.spell_kind === 'heal'
                ? 'Лечащее заклинание тратит ход и ману, восстанавливает HP по формуле от магической силы и не наносит урон.'
                : 'Базовая магическая атака остаётся стихией расы. Это заклинание использует свою стихию и расходует ману.'}
            </p>

            <div className="gm-form-actions">
              <button className="primary-button" type="button" disabled={busy} onClick={() => void saveSpell()}>
                {busy ? 'Сохраняем…' : spellDraft.id ? 'Сохранить заклинание' : 'Создать заклинание'}
              </button>
              {spellDraft.id && (
                <button className="ghost-button danger-button" type="button" disabled={busy} onClick={() => void deleteSpell()}>
                  Удалить
                </button>
              )}
            </div>
          </article>
        </div>
      ) : section === 'crafting' ? (
        <GmCraftingEditor />
      ) : (
        <GmLootEditor />
      )}
    </section>
  )
}
