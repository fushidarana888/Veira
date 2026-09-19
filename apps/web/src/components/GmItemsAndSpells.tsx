import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { GmCraftingEditor } from './GmCraftingEditor'
import { GmAffixEditor } from './GmAffixEditor'
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

const spellKindLabels: Record<SpellDefinition['spell_kind'], string> = {
  damage: 'Урон',
  heal: 'Лечение',
  guard: 'Защита',
  cleanse: 'Очищение',
  buff: 'Усиление',
  taunt: 'Провокация',
  sacrifice: 'Последняя жертва',
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

const cyrillicSlugMap: Record<string, string> = {
  а: 'a',
  б: 'b',
  в: 'v',
  г: 'g',
  д: 'd',
  е: 'e',
  ё: 'yo',
  ж: 'zh',
  з: 'z',
  и: 'i',
  й: 'y',
  к: 'k',
  л: 'l',
  м: 'm',
  н: 'n',
  о: 'o',
  п: 'p',
  р: 'r',
  с: 's',
  т: 't',
  у: 'u',
  ф: 'f',
  х: 'h',
  ц: 'ts',
  ч: 'ch',
  ш: 'sh',
  щ: 'sch',
  ъ: '',
  ы: 'y',
  ь: '',
  э: 'e',
  ю: 'yu',
  я: 'ya',
}

function itemSlugFromName(value: string) {
  return value
    .trim()
    .toLowerCase()
    .split('')
    .map((char) => cyrillicSlugMap[char] ?? char)
    .join('')
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .replace(/_+/g, '_')
}

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
  damage_bonuses: Partial<Record<DamageType, number>>
  scroll_spell_id: string | null
  scroll_mode: 'learn' | 'cast' | null
  unique_property_name: string
  unique_property_description: string
  unique_effect_type: 'lifesteal' | 'mana_on_hit' | 'damage_vs_wounded' | 'guard_boost' | 'taunt' | null
  unique_effect_value: number
}

type SpellDraft = {
  id: string | null
  slug: string
  name: string
  description: string
  enabled: boolean
  spell_kind: 'damage' | 'heal' | 'guard' | 'cleanse' | 'buff' | 'taunt' | 'sacrifice'
  damage_type: ElementalDamageType | null
  mana_cost: number
  required_level: number
  power_multiplier: number
  flat_power: number
  status_effect_type: CombatStatusEffectType | null
  status_effect_chance: number
  status_effect_turns: number
  status_effect_potency: number
  support_effect_type: 'guard' | 'cleanse' | 'empower' | 'taunt' | 'sacrifice' | null
  support_value: number
  support_turns: number
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
    damage_bonuses: {},
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
    support_effect_type: null,
    support_value: 0,
    support_turns: 0,
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
  const [section, setSection] = useState<'items' | 'spells' | 'affixes' | 'loot' | 'crafting'>('items')
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
      damage_bonuses: item.damage_bonuses ?? {},
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
      support_effect_type: spell.support_effect_type,
      support_value: spell.support_value,
      support_turns: spell.support_turns,
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

  function updatePercentStat(key: 'max_hp_percent' | 'defense_percent', raw: string) {
    const limits = key === 'max_hp_percent' ? [-80, 200] : [-75, 100]
    const value = Math.max(limits[0], Math.min(limits[1], Number(raw) || 0))
    const next = { ...itemDraft.stat_modifiers }
    if (value === 0) delete next[key]
    else next[key] = value
    setItemDraft({ ...itemDraft, stat_modifiers: next })
  }

  function updateFirstStrikeMultiplier(
    key: 'first_physical_strike_multiplier' | 'first_physical_bonus_damage_multiplier',
    raw: string,
  ) {
    const limits = key === 'first_physical_strike_multiplier' ? [1, 3] : [1, 2]
    const parsed = Number(raw)
    const value = Math.max(limits[0], Math.min(limits[1], Number.isFinite(parsed) ? parsed : 1))
    const next = { ...itemDraft.stat_modifiers }

    if (value <= 1) delete next[key]
    else next[key] = Math.round(value * 10) / 10

    setItemDraft({ ...itemDraft, stat_modifiers: next })
  }

  function updateResistance(type: DamageType, raw: string) {
    const value = Math.max(-75, Math.min(75, Number(raw) || 0))
    const next = { ...itemDraft.damage_resistances }
    if (value === 0) delete next[type]
    else next[type] = value
    setItemDraft({ ...itemDraft, damage_resistances: next })
  }

  function updateDamageBonus(type: DamageType, raw: string) {
    const value = Math.max(0, Math.min(75, Number(raw) || 0))
    const next = { ...itemDraft.damage_bonuses }
    if (value === 0) delete next[type]
    else next[type] = value
    setItemDraft({ ...itemDraft, damage_bonuses: next })
  }

  function changeItemCategory(category: ItemCategory) {
    const defaultEquipGroup: ItemEquipGroup | null =
      category === 'weapon'
        ? 'weapon'
        : category === 'armor'
          ? 'chest'
          : category === 'accessory'
            ? 'accessory'
            : null

    setItemDraft((current) => ({
      ...current,
      category,
      equip_group: defaultEquipGroup,
      stackable: defaultEquipGroup ? false : current.stackable,
      max_stack: defaultEquipGroup ? 1 : current.max_stack,
      damage_type: category === 'weapon' ? current.damage_type ?? 'slashing' : null,
      damage_resistances: defaultEquipGroup ? current.damage_resistances : {},
      damage_bonuses: defaultEquipGroup ? current.damage_bonuses : {},
      unique_effect_type: defaultEquipGroup ? current.unique_effect_type : null,
      unique_effect_value: defaultEquipGroup ? current.unique_effect_value : 0,
      unique_property_name: defaultEquipGroup ? current.unique_property_name : '',
      unique_property_description: defaultEquipGroup ? current.unique_property_description : '',
      heal_amount: category === 'consumable' ? current.heal_amount : 0,
      mana_amount: category === 'consumable' ? current.mana_amount : 0,
      scroll_spell_id: category === 'consumable' ? current.scroll_spell_id : null,
      scroll_mode: category === 'consumable' ? current.scroll_mode : null,
    }))
  }

  const itemEquipGroups = itemDraft.category === 'weapon'
    ? equipGroups.filter((entry) => entry.value === 'weapon' || entry.value === 'offhand')
    : itemDraft.category === 'armor'
      ? equipGroups.filter((entry) => ['offhand', 'head', 'chest', 'hands', 'legs', 'feet'].includes(entry.value))
      : itemDraft.category === 'accessory'
        ? equipGroups.filter((entry) => entry.value === 'accessory')
        : []

  async function saveItem() {
    setBusy(true)
    setMessage('')

    const normalizedSlug = itemSlugFromName(itemDraft.slug || itemDraft.name)

    if (!normalizedSlug) {
      setMessage('Укажи название предмета — техническое имя создастся автоматически.')
      setBusy(false)
      return
    }

    const { data, error } = await supabase.rpc('gm_save_item_definition_v2', {
      p_id: itemDraft.id,
      p_slug: normalizedSlug,
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
      p_damage_bonuses: itemDraft.damage_bonuses,
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
    setItemDraft((current) => ({
      ...current,
      id: current.id ?? savedId,
      slug: normalizedSlug,
    }))
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

    const { data, error } = await supabase.rpc('gm_save_spell_definition_v2', {
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
      p_support_effect_type: spellDraft.support_effect_type,
      p_support_value: spellDraft.support_value,
      p_support_turns: spellDraft.support_turns,
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
              className={section === 'affixes' ? 'active' : ''}
              onClick={() => setSection('affixes')}
            >
              Аффиксы
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
              <label>
                <span>Название</span>
                <input
                  value={itemDraft.name}
                  onChange={(e) => {
                    const name = e.target.value
                    setItemDraft((current) => {
                      const oldAutoSlug = itemSlugFromName(current.name)
                      const shouldAutoGenerate =
                        !current.id
                        && (!current.slug || current.slug === oldAutoSlug)

                      return {
                        ...current,
                        name,
                        slug: shouldAutoGenerate ? itemSlugFromName(name) : current.slug,
                      }
                    })
                  }}
                />
              </label>
              <label>
                <span>Slug · техническое имя</span>
                <input
                  value={itemDraft.slug}
                  placeholder={itemDraft.name ? itemSlugFromName(itemDraft.name) : 'sozdaetsya_avtomaticheski'}
                  onChange={(e) => setItemDraft({
                    ...itemDraft,
                    slug: itemSlugFromName(e.target.value),
                  })}
                />
                <small className="gm-field-hint">
                  Создаётся из названия автоматически. Меняй вручную только если это действительно нужно.
                </small>
              </label>
            </div>

            <label><span>Описание</span><textarea rows={3} value={itemDraft.description} onChange={(e) => setItemDraft({ ...itemDraft, description: e.target.value })} /></label>

            <div className="gm-form-grid three">
              <label>
                <span>Категория</span>
                <select value={itemDraft.category} onChange={(e) => changeItemCategory(e.target.value as ItemCategory)}>
                  {categories.map((v) => <option key={v.value} value={v.value}>{v.label}</option>)}
                </select>
                <small className="gm-field-hint">Что это за предмет в инвентаре.</small>
              </label>
              <label>
                <span>Редкость</span>
                <select value={itemDraft.rarity} onChange={(e) => setItemDraft({ ...itemDraft, rarity: e.target.value as ItemRarity })}>
                  {rarities.map((v) => <option key={v.value} value={v.value}>{v.label}</option>)}
                </select>
              </label>
              <label>
                <span>Слот экипировки</span>
                <select
                  value={itemDraft.equip_group ?? ''}
                  disabled={itemEquipGroups.length === 0}
                  onChange={(e) => setItemDraft({
                    ...itemDraft,
                    equip_group: e.target.value ? e.target.value as ItemEquipGroup : null,
                  })}
                >
                  {itemEquipGroups.length === 0
                    ? <option value="">Не экипируется</option>
                    : itemEquipGroups.map((v) => <option key={v.value} value={v.value}>{v.label}</option>)}
                </select>
                <small className="gm-field-hint">
                  Куда предмет надевается. Категория и слот — разные вещи.
                </small>
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

            {itemDraft.equip_group && (
              <div className="gm-editor-box">
                <div>
                  <strong>Процентные модификаторы</strong>
                  <small>Меняют итоговый максимум HP и обе защиты персонажа</small>
                </div>
                <div className="gm-form-grid two">
                  <label>
                    <span>Максимальное HP %</span>
                    <input
                      type="number"
                      min={-80}
                      max={200}
                      value={itemDraft.stat_modifiers.max_hp_percent ?? 0}
                      onChange={(e) => updatePercentStat('max_hp_percent', e.target.value)}
                    />
                  </label>
                  <label>
                    <span>Вся защита %</span>
                    <input
                      type="number"
                      min={-75}
                      max={100}
                      value={itemDraft.stat_modifiers.defense_percent ?? 0}
                      onChange={(e) => updatePercentStat('defense_percent', e.target.value)}
                    />
                  </label>
                </div>
                <p className="muted">
                  «Вся защита» одинаково масштабирует физическую и магическую защиту. Отрицательное значение является штрафом.
                </p>
              </div>
            )}

            {itemDraft.category === 'weapon' && (
              <>
                <div className="gm-form-grid two">
                  <label>
                    <span>Тип урона оружия</span>
                    <select value={itemDraft.damage_type ?? ''} onChange={(e) => setItemDraft({ ...itemDraft, damage_type: e.target.value ? e.target.value as DamageType : null })}>
                      <option value="">Нет</option>
                      {damageTypes.filter((type) => ['slashing', 'piercing', 'blunt'].includes(type)).map((type) => (
                        <option key={type} value={type}>{damageLabels[type]}</option>
                      ))}
                    </select>
                  </label>
                </div>

                <div className="gm-editor-box">
                  <div>
                    <strong>Первый физический удар</strong>
                    <small>Отдельные множители базы и бонусной части первой физической атаки в битве</small>
                  </div>
                  <div className="gm-form-grid two">
                    <label>
                      <span>first_physical_strike_multiplier</span>
                      <input
                        type="number"
                        min={1}
                        max={3}
                        step={0.1}
                        value={itemDraft.stat_modifiers.first_physical_strike_multiplier ?? 1}
                        onChange={(e) => updateFirstStrikeMultiplier('first_physical_strike_multiplier', e.target.value)}
                      />
                    </label>
                    <label>
                      <span>first_physical_bonus_damage_multiplier</span>
                      <input
                        type="number"
                        min={1}
                        max={2}
                        step={0.1}
                        value={itemDraft.stat_modifiers.first_physical_bonus_damage_multiplier ?? 1}
                        onChange={(e) => updateFirstStrikeMultiplier('first_physical_bonus_damage_multiplier', e.target.value)}
                      />
                    </label>
                  </div>
                  <p className="muted">
                    Значение 1 выключает соответствующее усиление. Магия, заклинания, защита и расходники не расходуют первый физический удар.
                  </p>
                </div>
              </>
            )}

            {itemDraft.equip_group && (
              <>
                <div className="gm-editor-box">
                  <div>
                    <strong>Бонус к наносимому урону</strong>
                    <small>Суммируется с другими вещами, максимум +75% на один тип</small>
                  </div>
                  <div className="gm-form-grid three">
                    {damageTypes.map((type) => (
                      <label key={'damage-bonus-' + type}>
                        <span>{damageLabels[type]}</span>
                        <input
                          type="number"
                          min={0}
                          max={75}
                          value={itemDraft.damage_bonuses[type] ?? 0}
                          onChange={(e) => updateDamageBonus(type, e.target.value)}
                        />
                      </label>
                    ))}
                  </div>
                </div>

                <div className="gm-editor-box">
                  <div>
                    <strong>Сопротивления / уязвимости</strong>
                    <small>Получаемый урон · от −75% до +75%</small>
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
              </>
            )}

            {itemDraft.category === 'consumable' && itemDraft.scroll_mode == null && (
              <div className="gm-editor-box">
                <div>
                  <strong>Восстановление ресурсов</strong>
                  <small>Для зелий и других одноразовых расходников</small>
                </div>
                <div className="gm-form-grid two">
                  <label>
                    <span>Лечение HP</span>
                    <input
                      type="number"
                      min={0}
                      value={itemDraft.heal_amount}
                      onChange={(e) => setItemDraft({ ...itemDraft, heal_amount: Math.max(0, Number(e.target.value)) })}
                    />
                  </label>
                  <label>
                    <span>Восстановление маны</span>
                    <input
                      type="number"
                      min={0}
                      value={itemDraft.mana_amount}
                      onChange={(e) => setItemDraft({ ...itemDraft, mana_amount: Math.max(0, Number(e.target.value)) })}
                    />
                  </label>
                </div>
              </div>
            )}

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
                      <option value="taunt">Провокация · шанс стать целью в группе</option>
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
                  {spell.damage_type ? damageLabels[spell.damage_type] : spellKindLabels[spell.spell_kind]}
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
                <select
                  value={spellDraft.spell_kind}
                  onChange={(e) => {
                    const kind = e.target.value as SpellDraft['spell_kind']
                    setSpellDraft({
                      ...spellDraft,
                      spell_kind: kind,
                      damage_type: kind === 'damage' ? spellDraft.damage_type ?? 'fire' : null,
                      status_effect_type: kind === 'damage' ? spellDraft.status_effect_type : null,
                      status_effect_chance: kind === 'damage' ? spellDraft.status_effect_chance : 0,
                      status_effect_turns: kind === 'damage' ? spellDraft.status_effect_turns : 0,
                      status_effect_potency: kind === 'damage' ? spellDraft.status_effect_potency : 0,
                      support_effect_type:
                        kind === 'guard' ? 'guard'
                          : kind === 'cleanse' ? 'cleanse'
                            : kind === 'buff' ? 'empower'
                              : kind === 'taunt' ? 'taunt'
                                : kind === 'sacrifice' ? 'sacrifice'
                                  : null,
                      support_value:
                        kind === 'guard' ? Math.max(70, spellDraft.support_value)
                          : kind === 'buff' ? Math.max(20, spellDraft.support_value)
                            : kind === 'taunt' ? Math.max(90, spellDraft.support_value)
                              : kind === 'sacrifice' ? 30
                                : 0,
                      support_turns:
                        kind === 'buff' ? Math.max(2, spellDraft.support_turns)
                          : kind === 'guard' ? 1
                            : kind === 'sacrifice' ? 3
                              : 0,
                      mana_cost: kind === 'sacrifice' ? 0 : spellDraft.mana_cost,
                    })
                  }}
                >
                  <option value="damage">Урон</option>
                  <option value="heal">Лечение</option>
                  <option value="guard">Магическая защита</option>
                  <option value="cleanse">Очищение дебаффов</option>
                  <option value="buff">Усиление урона</option>
                  <option value="taunt">Провокация союзника</option>
                  <option value="sacrifice">Последняя жертва · только боевой свиток</option>
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
              <label><span>Множитель силы</span><input type="number" min={0} max={10} step={0.05} disabled={!['damage', 'heal'].includes(spellDraft.spell_kind)} value={spellDraft.power_multiplier} onChange={(e) => setSpellDraft({ ...spellDraft, power_multiplier: Math.max(0, Number(e.target.value)) })} /></label>
              <label><span>Плоский бонус</span><input type="number" min={0} disabled={!['damage', 'heal'].includes(spellDraft.spell_kind)} value={spellDraft.flat_power} onChange={(e) => setSpellDraft({ ...spellDraft, flat_power: Math.max(0, Number(e.target.value)) })} /></label>
            </div>

            {spellDraft.spell_kind === 'damage' && (
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
  
            )}

            {spellDraft.spell_kind === 'sacrifice' && (
              <div className="gm-editor-box">
                <div>
                  <strong>Последняя жертва</strong>
                  <small>Фиксированная эндгейм-механика одноразового группового свитка</small>
                </div>
                <div className="gm-form-grid three">
                  <label><span>Мана</span><input disabled value="0" /></label>
                  <label><span>Снижение входящего урона</span><input disabled value="30%" /></label>
                  <label><span>Длительность</span><input disabled value="3 раунда" /></label>
                </div>
                <p className="muted">
                  Условие применения — больше 200 текущего HP. Использующий становится Потерянным до конца всего похода. Эффект можно активировать только один раз за бой-поход.
                </p>
              </div>
            )}

            {['guard', 'buff', 'taunt'].includes(spellDraft.spell_kind) && (
              <div className="gm-editor-box">
                <div>
                  <strong>
                    {spellDraft.spell_kind === 'guard'
                      ? 'Магический щит'
                      : spellDraft.spell_kind === 'taunt'
                        ? 'Провокация'
                        : 'Боевое усиление'}
                  </strong>
                  <small>
                    {spellDraft.spell_kind === 'guard'
                      ? 'Процент снижения следующего входящего удара'
                      : spellDraft.spell_kind === 'taunt'
                        ? 'Шанс, с которым враг выберет отмеченного союзника целью'
                        : 'Бонус к прямому урону и число усиленных атак'}
                  </small>
                </div>
                <div className="gm-form-grid two">
                  <label>
                    <span>
                      {spellDraft.spell_kind === 'guard'
                        ? 'Снижение урона %'
                        : spellDraft.spell_kind === 'taunt'
                          ? 'Шанс стать целью %'
                          : 'Бонус урона %'}
                    </span>
                    <input
                      type="number"
                      min={spellDraft.spell_kind === 'guard' ? 55 : 1}
                      max={spellDraft.spell_kind === 'guard' ? 85 : 100}
                      value={spellDraft.support_value}
                      onChange={(e) => setSpellDraft({
                        ...spellDraft,
                        support_value: Math.max(
                          spellDraft.spell_kind === 'guard' ? 55 : 1,
                          Math.min(spellDraft.spell_kind === 'guard' ? 85 : 100, Number(e.target.value)),
                        ),
                      })}
                    />
                  </label>
                  {spellDraft.spell_kind === 'buff' ? (
                    <label>
                      <span>Атак</span>
                      <input
                        type="number"
                        min={1}
                        max={10}
                        value={spellDraft.support_turns}
                        onChange={(e) => setSpellDraft({
                          ...spellDraft,
                          support_turns: Math.max(1, Math.min(10, Number(e.target.value))),
                        })}
                      />
                    </label>
                  ) : (
                    <label>
                      <span>Длительность</span>
                      <input
                        disabled
                        value={spellDraft.spell_kind === 'taunt' ? 'до конца битвы / смерти цели' : '1 входящий удар'}
                      />
                    </label>
                  )}
                </div>
              </div>
            )}


            <p className="muted">
              {spellDraft.spell_kind === 'heal'
                ? 'Лечение тратит ход и ману и масштабируется от магической силы.'
                : spellDraft.spell_kind === 'guard'
                  ? 'Щит действует на следующий входящий удар и складывается с бонусом блока экипировки, но итоговая защита ограничена 85%.'
                  : spellDraft.spell_kind === 'cleanse'
                    ? 'Очищение снимает все текущие негативные эффекты. Если персонаж уже оглушён, он пропускает ход и не успевает применить очищение.'
                    : spellDraft.spell_kind === 'buff'
                      ? 'Усиление повышает прямой физический и магический урон на заданное число следующих атак.'
                      : spellDraft.spell_kind === 'taunt'
                        ? 'Провокация работает только в групповой битве: выбранный живой союзник становится целью врага с указанным шансом до своей смерти или конца текущей битвы.'
                        : spellDraft.spell_kind === 'sacrifice'
                          ? '«Последняя жертва» существует только в одноразовом боевом свитке: >200 HP, использующий становится Потерянным до конца всего похода; живые союзники полностью лечатся и получают −30% входящего урона на 3 раунда. Мёртвых не воскрешает.'
                          : 'Базовая магическая атака остаётся стихией расы. Это заклинание использует собственную стихию и расходует ману.'}
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
      ) : section === 'affixes' ? (
        <GmAffixEditor />
      ) : section === 'crafting' ? (
        <GmCraftingEditor />
      ) : (
        <GmLootEditor />
      )}
    </section>
  )
}
