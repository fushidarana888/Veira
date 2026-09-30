import { userFacingError } from '../lib/userError'
import { Capacitor } from '@capacitor/core'
import { lazy, Suspense, useEffect, useMemo, useState } from 'react'
import { addStatModifiers, armorDamageReductionPercent, calculateDerivedCombatStats, experienceForNextLevel, type StatKey } from '@veira/game-core'
import { supabase } from '../lib/supabase'
import { scheduleIdle, useSmartRefresh } from '../lib/smartRefresh'

const AdventuresPanel = lazy(() => import('./AdventuresPanel').then((module) => ({ default: module.AdventuresPanel })))
const BattleCenterPanel = lazy(() => import('./BattleCenterPanel').then((module) => ({ default: module.BattleCenterPanel })))
const CraftingPanel = lazy(() => import('./CraftingPanel').then((module) => ({ default: module.CraftingPanel })))
const GuidePanel = lazy(() => import('./GuidePanel').then((module) => ({ default: module.GuidePanel })))
const CommunitiesPanel = lazy(() => import('./CommunitiesPanel').then((module) => ({ default: module.CommunitiesPanel })))
const MagicPanel = lazy(() => import('./MagicPanel').then((module) => ({ default: module.MagicPanel })))
const ReligionPanel = lazy(() => import('./ReligionPanel').then((module) => ({ default: module.ReligionPanel })))
const WorldMap = lazy(() => import('./WorldMap').then((module) => ({ default: module.WorldMap })))
import type {
  Character,
  CharacterEquipment,
  CharacterItem,
  CharacterProgress,
  EquipmentSlot,
  EquipmentSetState,
  DamageType,
  ItemDefinition,
  Profile,
  RaceDefinition,
  RaceTrait,
} from '../types'

type Props = {
  profile: Profile
  character: Character
  userEmail: string
  onSignOut: () => Promise<void> | void
}

type Tab = 'world' | 'character' | 'adventures' | 'battles' | 'more'
type CharacterTab = 'overview' | 'religion' | 'inventory' | 'equipment' | 'magic' | 'crafting'
type MoreView = 'menu' | 'guide' | 'communities'
type NavIconName = 'world' | 'character' | 'adventures' | 'battles' | 'more'

const playerTabs: Tab[] = ['world', 'character', 'adventures', 'battles', 'more']
const characterTabs: CharacterTab[] = ['overview', 'religion', 'inventory', 'equipment', 'magic', 'crafting']

const isNativeApp = Capacitor.isNativePlatform()
const appBuildNumber = import.meta.env.VITE_BUILD_NUMBER || ''
const appBuildSha = import.meta.env.VITE_BUILD_SHA || ''

function readStoredPlayerTab(): Tab {
  try {
    const value = window.sessionStorage.getItem('veira:player-tab') as Tab | null
    return value && playerTabs.includes(value) ? value : 'character'
  } catch {
    return 'character'
  }
}

function readStoredCharacterTab(): CharacterTab {
  try {
    const value = window.sessionStorage.getItem('veira:character-tab') as CharacterTab | null
    return value && characterTabs.includes(value) ? value : 'overview'
  } catch {
    return 'overview'
  }
}

type ItemHistoryEvent = {
  event_id: number
  lineage_id: string
  event_type: string
  title: string
  description: string
  owner_name: string
  metadata: Record<string, unknown>
  created_at: string
}

type CharacterCustomizationState = {
  character_id: string
  current_race_id: string
  current_race_name: string
  bio: string
  free_race_changes: number
  free_bio_changes: number
  race_change_cost: number
  bio_change_cost: number
  gold: number
  busy_for_race_change: boolean
}

const equipmentLabels: Record<EquipmentSlot, string> = {
  weapon: 'Оружие',
  offhand: 'Вторая рука',
  head: 'Голова',
  chest: 'Корпус',
  hands: 'Руки',
  legs: 'Ноги',
  feet: 'Обувь',
  accessory_1: 'Аксессуар I',
  accessory_2: 'Аксессуар II',
}

const rarityLabels: Record<ItemDefinition['rarity'], string> = {
  common: 'Обычный',
  uncommon: 'Необычный',
  rare: 'Редкий',
  epic: 'Эпический',
  legendary: 'Легендарный',
  unique: 'Уникальный',
}

const materialExchangeValues: Record<ItemDefinition['rarity'], number> = {
  common: 2,
  uncommon: 5,
  rare: 12,
  epic: 25,
  legendary: 50,
  unique: 100,
}

const equipmentExchangeValues: Record<ItemDefinition['rarity'], number> = {
  common: 5,
  uncommon: 12,
  rare: 30,
  epic: 70,
  legendary: 160,
  unique: 350,
}

function itemExchangeValue(definition: ItemDefinition) {
  if (definition.slug === 'ancient_relic_fragment_beta' || definition.slug.endsWith('_damaged')) return 0
  if (definition.category === 'material') {
    if (definition.rarity === 'unique') return 0
    return materialExchangeValues[definition.rarity]
  }
  if (['weapon', 'armor', 'accessory'].includes(definition.category)) {
    return equipmentExchangeValues[definition.rarity]
  }
  return 0
}

const damageTypeLabels: Record<DamageType, string> = {
  slashing: 'Режущий',
  piercing: 'Колющий',
  blunt: 'Дробящий',
  fire: 'Огненный',
  water: 'Водный',
  earth: 'Земляной',
  air: 'Воздушный',
  lightning: 'Электрический',
  ice: 'Ледяной',
  arcane: 'Арканный',
  star: 'Звёздный',
  gravity: 'Гравитационный',
  moon: 'Лунный',
}

const weaponScalingLabels: Record<NonNullable<ItemDefinition['weapon_scaling']>, string> = {
  strength: 'Силовое',
  agility: 'Ловкостное',
  hybrid: 'Гибридное',
}

const weaponFamilyLabels: Record<NonNullable<ItemDefinition['weapon_family']>, string> = {
  short_bow: 'Короткий лук',
  long_bow: 'Длинный лук',
  dagger: 'Кинжал',
  rapier: 'Рапира',
  sword: 'Меч',
  blade: 'Клинок',
  katana: 'Катана',
  spear: 'Копьё',
  axe: 'Топор',
  battleaxe: 'Секира',
  mace: 'Булава',
  hammer: 'Молот',
  club: 'Дубина',
  greatsword: 'Двуручный меч',
  staff: 'Боевой посох',
  wand: 'Магический жезл',
}

const weaponFamilyMechanicLabels: Partial<Record<NonNullable<ItemDefinition['weapon_family']>, string>> = {
  dagger: '×0,80 после физической защиты',
  rapier: 'Игнорирует 10% физической защиты',
  blade: 'Разброс физического урона всегда +4',
  katana: 'Нарастающий ритм · +8% за последовательную физическую атаку по той же цели · максимум +40%',
  spear: 'Физическая защита цели ×1,20 · повышенный базовый урон',
  axe: 'До +20% урона от макс. ОЗ цели',
  battleaxe: 'До +20% урона от макс. ОЗ цели',
  mace: 'Оглушение 8% соло/дуэль · 5% пати',
  hammer: 'Оглушение 8% соло/дуэль · 5% пати',
  club: 'Дробящий урон: уязвимость ×1,5 · сопротивление учитывается на 50%',
  greatsword: 'Некритический физический удар: +15 п.п. шанс крита · крит сбрасывает накопление · общий кап 75%',
}

const statLabels: Record<StatKey, string> = {
  strength: 'Сила',
  agility: 'Ловкость',
  intellect: 'Интеллект',
  vitality: 'Живучесть',
  luck: 'Удача',
}

const statUpgradeHints: Partial<Record<StatKey, string>> = {
  intellect: '+3 маг. мощи · +1 маг. броня',
}

function raceTraitNumber(traits: RaceTrait[] | undefined, type: string) {
  return (traits ?? []).reduce((sum, trait) => (
    trait.type === type && typeof trait.value === 'number'
      ? sum + trait.value
      : sum
  ), 0)
}

function raceStatEntries(race: RaceDefinition | null) {
  if (!race) return []
  return Object.entries(race.stat_modifiers ?? {})
    .filter((entry): entry is [string, number] => typeof entry[1] === 'number' && entry[1] !== 0)
}

function normalizeProgress(value: Character['character_progress']): CharacterProgress | null {
  if (Array.isArray(value)) return value[0] ?? null
  return value
}

function normalizeDefinition(value: CharacterItem['item_definitions']): ItemDefinition | null {
  if (Array.isArray(value)) return value[0] ?? null
  return value
}

const affixEffectLabels: Record<string, { label: string; percent: boolean }> = {
  lifesteal: { label: 'Вампиризм', percent: true },
  mana_on_hit: { label: 'Мана за удар', percent: false },
  damage_vs_wounded: { label: 'Урон по раненым', percent: true },
  guard_boost: { label: 'Усиление блока', percent: true },
  physical_damage_bonus: { label: 'Физический урон', percent: true },
  magic_damage_bonus: { label: 'Магический урон', percent: true },
  all_damage_bonus: { label: 'Весь прямой урон', percent: true },
  low_hp_damage_reduction: { label: 'Защита при низком ОЗ', percent: true },
  boss_damage_bonus: { label: 'Урон боссам', percent: true },
}

function itemAffixes(item: CharacterItem) {
  const value = item.metadata?.affixes
  if (!Array.isArray(value)) return []

  return value.filter((entry): entry is {
    name: string
    description?: string
    stat_modifiers?: Record<string, number>
    damage_resistances?: Partial<Record<DamageType, number>>
    unique_effect_type?: string | null
    unique_effect_value?: number
  } => Boolean(entry) && typeof entry === 'object' && 'name' in entry && typeof entry.name === 'string')
}

function affixEffectText(affix: ReturnType<typeof itemAffixes>[number]) {
  if (!affix.unique_effect_type || !affix.unique_effect_value) return ''
  const info = affixEffectLabels[affix.unique_effect_type]
  if (!info) return ''
  return `${info.label} +${affix.unique_effect_value}${info.percent ? '%' : ''}`
}

function affixStatModifiers(item: CharacterItem): Record<string, number> {
  const value = item.metadata?.affix_stat_modifiers
  return value && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, number>
    : {}
}

function religionItemStatModifiers(item: CharacterItem): Record<string, number> {
  const value = item.metadata?.religion_stat_modifiers
  return value && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, number>
    : {}
}

function religionCombatStatModifiers(value: Record<string, unknown>): Partial<Record<StatKey, number>> {
  const result: Partial<Record<StatKey, number>> = {}
  for (const stat of ['strength', 'agility', 'intellect', 'vitality', 'luck'] as StatKey[]) {
    const raw = value[stat]
    if (typeof raw === 'number' && raw !== 0) result[stat] = raw
  }
  return result
}

function combinedResistances(item: CharacterItem, definition: ItemDefinition) {
  const result: Partial<Record<DamageType, number>> = { ...(definition.damage_resistances ?? {}) }
  const extras = [
    item.metadata?.affix_damage_resistances,
    item.metadata?.religion_damage_resistances,
  ]

  for (const extra of extras) {
    if (!extra || typeof extra !== 'object' || Array.isArray(extra)) continue
    for (const [key, raw] of Object.entries(extra)) {
      if (typeof raw !== 'number') continue
      const type = key as DamageType
      result[type] = Math.max(-75, Math.min(75, (result[type] ?? 0) + raw))
    }
  }

  return result
}

function ancientRestorationInfo(definition: ItemDefinition) {
  const effects = Array.isArray(definition.effects) ? definition.effects : []
  const restoration = effects.find((effect) =>
    Boolean(effect)
    && typeof effect === 'object'
    && !Array.isArray(effect)
    && (effect as Record<string, unknown>).type === 'ancient_restoration'
  ) as Record<string, unknown> | undefined

  if (!restoration) return null

  return {
    targetSlug: typeof restoration.target_slug === 'string' ? restoration.target_slug : '',
    fragmentCost: Math.max(1, Number(restoration.fragment_cost ?? 1)),
  }
}

function itemStory(item: CharacterItem) {
  const title = typeof item.metadata?.story_title === 'string'
    ? item.metadata.story_title
    : ''
  const text = typeof item.metadata?.story_text === 'string'
    ? item.metadata.story_text
    : ''

  if (!text) return null
  return {
    title: title || 'История предмета',
    text,
  }
}

function itemIsInventoryLocked(item: CharacterItem) {
  return item.metadata?.inventory_locked === true
}

function itemIsRecent(item: CharacterItem) {
  const acquiredAt = new Date(item.acquired_at).getTime()
  return Number.isFinite(acquiredAt) && Date.now() - acquiredAt <= 24 * 60 * 60 * 1000
}

function itemAffixCount(item: CharacterItem) {
  return itemAffixes(item).length
}

function itemCanBeDismantled(item: CharacterItem, definition: ItemDefinition) {
  return ['weapon', 'armor', 'accessory'].includes(definition.category)
    && definition.rarity !== 'unique'
    && !definition.slug.startsWith('ancient_')
    && !definition.religion_origin_slug
    && !itemIsInventoryLocked(item)
}

function itemDismantleValue(item: CharacterItem, definition: ItemDefinition) {
  const base: Record<ItemDefinition['rarity'], number> = {
    common: 1,
    uncommon: 2,
    rare: 4,
    epic: 7,
    legendary: 12,
    unique: 0,
  }
  return Math.max(0, (base[definition.rarity] ?? 0) + Math.min(3, itemAffixCount(item)))
}

function itemCombinedCoreStats(item: CharacterItem, definition: ItemDefinition) {
  const result: Record<string, number> = { ...(definition.stat_modifiers ?? {}) }
  for (const source of [affixStatModifiers(item), religionItemStatModifiers(item)]) {
    for (const [key, value] of Object.entries(source)) {
      if (typeof value === 'number') result[key] = (result[key] ?? 0) + value
    }
  }
  return result
}

function itemComparisonSummary(
  item: CharacterItem,
  definition: ItemDefinition,
  equippedItem: CharacterItem | null,
) {
  if (!equippedItem || equippedItem.id === item.id) return null
  const equippedDefinition = normalizeDefinition(equippedItem.item_definitions)
  if (!equippedDefinition) return null

  const parts: string[] = []
  const currentStats = itemCombinedCoreStats(item, definition)
  const equippedStats = itemCombinedCoreStats(equippedItem, equippedDefinition)

  for (const key of ['strength', 'agility', 'vitality', 'intellect', 'luck'] as StatKey[]) {
    const diff = Number(currentStats[key] ?? 0) - Number(equippedStats[key] ?? 0)
    if (diff !== 0) parts.push(`${statLabels[key]} ${diff > 0 ? '+' : ''}${diff}`)
  }

  if (definition.category === 'weapon' && equippedDefinition.category === 'weapon') {
    const currentBase = Math.round(Number(definition.weapon_base_damage ?? 0) * (1 + item.enhancement_level * 0.03))
    const equippedBase = Math.round(Number(equippedDefinition.weapon_base_damage ?? 0) * (1 + equippedItem.enhancement_level * 0.03))
    const diff = currentBase - equippedBase
    if (diff !== 0) parts.push(`База урона ${diff > 0 ? '+' : ''}${diff}`)
  }

  const currentRes = combinedResistances(item, definition)
  const equippedRes = combinedResistances(equippedItem, equippedDefinition)
  for (const type of Object.keys({ ...currentRes, ...equippedRes }) as DamageType[]) {
    const diff = Number(currentRes[type] ?? 0) - Number(equippedRes[type] ?? 0)
    if (diff !== 0) parts.push(`${damageTypeLabels[type]} ${diff > 0 ? '+' : ''}${diff} п.п.`)
  }

  const affixDiff = itemAffixCount(item) - itemAffixCount(equippedItem)
  if (affixDiff !== 0) parts.push(`Аффиксы ${affixDiff > 0 ? '+' : ''}${affixDiff}`)

  return {
    name: equippedItem.custom_name || equippedDefinition.name,
    parts: parts.slice(0, 7),
  }
}

export function PlayerHome({ profile, character, userEmail, onSignOut }: Props) {
  const [tab, setTab] = useState<Tab>(readStoredPlayerTab)
  const [characterTab, setCharacterTab] = useState<CharacterTab>(readStoredCharacterTab)
  const [moreView, setMoreView] = useState<MoreView>('menu')
  const [items, setItems] = useState<CharacterItem[]>([])
  const [historyItem, setHistoryItem] = useState<CharacterItem | null>(null)
  const [historyEvents, setHistoryEvents] = useState<ItemHistoryEvent[]>([])
  const [historyBusy, setHistoryBusy] = useState(false)
  const [historyMessage, setHistoryMessage] = useState('')
  const [equipment, setEquipment] = useState<CharacterEquipment[]>([])
  const [equipmentSets, setEquipmentSets] = useState<EquipmentSetState[]>([])
  const [trophies, setTrophies] = useState<Array<{
    slug: string
    name: string
    description: string
    quantity: number
  }>>([])
  const [inventoryHydrated, setInventoryHydrated] = useState(false)
  const [inventoryBusy, setInventoryBusy] = useState(false)
  const [raceDefinition, setRaceDefinition] = useState<RaceDefinition | null>(null)
  const [inventoryMessage, setInventoryMessage] = useState('')
  const [statBusy, setStatBusy] = useState(false)
  const [progressMessage, setProgressMessage] = useState('')
  const [securityBusy, setSecurityBusy] = useState(false)
  const [securityMessage, setSecurityMessage] = useState('')
  const [customizationState, setCustomizationState] = useState<CharacterCustomizationState | null>(null)
  const [customizationRaces, setCustomizationRaces] = useState<RaceDefinition[]>([])
  const [selectedCustomizationRaceId, setSelectedCustomizationRaceId] = useState(character.race_id)
  const [customizationBio, setCustomizationBio] = useState(character.bio)
  const [characterBio, setCharacterBio] = useState(character.bio)
  const [characterRaceName, setCharacterRaceName] = useState(character.race)
  const [customizationBusy, setCustomizationBusy] = useState<'race' | 'bio' | null>(null)
  const [customizationMessage, setCustomizationMessage] = useState('')
  const [progress, setProgress] = useState<CharacterProgress | null>(
    () => normalizeProgress(character.character_progress),
  )
  const [religionCombatModifiers, setReligionCombatModifiers] = useState<Record<string, unknown>>({})

  useEffect(() => {
    setProgress(normalizeProgress(character.character_progress))
  }, [character.character_progress])

  useEffect(() => {
    setCharacterBio(character.bio)
    setCustomizationBio(character.bio)
    setCharacterRaceName(character.race)
    setSelectedCustomizationRaceId(character.race_id)
  }, [character.bio, character.race, character.race_id])

  async function loadRace() {
    const { data, error } = await supabase.rpc('get_character_race_state', {
      p_character_id: character.id,
    })

    if (error) {
      setProgressMessage(userFacingError(error.message, 'Не удалось обновить данные персонажа.'))
      return null
    }

    const race = (Array.isArray(data) ? data[0] : data) as RaceDefinition | null
    setRaceDefinition(race)
    return race
  }

  async function loadReligionModifiers() {
    const { data, error } = await supabase.rpc('get_religion_catalog_v2', {
      p_character_id: character.id,
    })

    if (error) {
      setProgressMessage(userFacingError(error.message, 'Не удалось обновить данные персонажа.'))
      return null
    }

    const catalog = (data as Array<{ is_current: boolean; combat_modifiers: Record<string, unknown> }> | null) ?? []
    const current = catalog.find((entry) => entry.is_current)
    const modifiers = current?.combat_modifiers ?? {}
    setReligionCombatModifiers(modifiers)
    return modifiers
  }

  async function loadProgress() {
    const { data, error } = await supabase.rpc('get_character_progress_state', {
      p_character_id: character.id,
    })

    if (error) {
      setProgressMessage(userFacingError(error.message, 'Не удалось обновить данные персонажа.'))
      return null
    }

    const nextProgress = (Array.isArray(data) ? data[0] : data) as CharacterProgress | null

    if (!nextProgress) {
      setProgressMessage('Прогресс персонажа не найден.')
      return null
    }

    setProgress(nextProgress)
    return nextProgress
  }

  async function loadTrophies() {
    const { data, error } = await supabase.rpc('get_character_trophy_case', {
      p_character_id: character.id,
    })

    if (error) return null

    const next = (data as Array<{
      slug: string
      name: string
      description: string
      quantity: number
    }> | null) ?? []

    setTrophies(next)
    return next
  }

  async function loadEquippedState() {
    const { data: equipmentData, error: equipmentError } = await supabase
      .from('character_equipment')
      .select('character_id, slot, character_item_id, equipped_at')
      .eq('character_id', character.id)

    if (equipmentError) {
      setInventoryMessage(userFacingError(equipmentError.message, 'Не удалось загрузить экипировку.'))
      return
    }

    const nextEquipment = (equipmentData as CharacterEquipment[] | null) ?? []
    const equippedIds = nextEquipment.map((entry) => entry.character_item_id)

    if (equippedIds.length === 0) {
      setEquipment([])
      return
    }

    const { data: itemData, error: itemError } = await supabase
      .from('character_items')
      .select(`
        id,
        character_id,
        item_definition_id,
        quantity,
        durability_current,
        durability_max,
        custom_name,
        metadata,
        enhancement_level,
        awakening_level,
        acquired_at,
        item_definitions (
          id,
          slug,
          name,
          description,
          category,
          rarity,
          equip_group,
          stackable,
          max_stack,
          icon_url,
          stat_modifiers,
          effects,
          base_value,
          required_level,
          shop_tier,
          shop_price,
          shop_enabled,
          damage_type,
          weapon_base_damage,
          weapon_scaling,
          weapon_family,
          echo_strike_chance_percent,
          damage_resistances,
          damage_bonuses,
          scroll_spell_id,
          scroll_mode,
          unique_property_name,
          unique_property_description,
          unique_effect_type,
          unique_effect_value,
          equipment_set_id
        )
      `)
      .in('id', equippedIds)

    if (itemError) {
      setInventoryMessage(userFacingError(itemError.message, 'Не удалось загрузить инвентарь.'))
      return
    }

    setEquipment(nextEquipment)
    const equippedItems = (itemData as CharacterItem[] | null) ?? []
    setItems((current) => {
      const merged = new Map(current.map((item) => [item.id, item]))
      for (const item of equippedItems) merged.set(item.id, item)
      return [...merged.values()]
    })
  }

  async function loadInventory() {
    setInventoryBusy(true)
    setInventoryMessage('')

    const [
      { data: itemData, error: itemError },
      { data: equipmentData, error: equipmentError },
      { data: setData, error: setError },
    ] = await Promise.all([
        supabase
          .from('character_items')
          .select(`
            id,
            character_id,
            item_definition_id,
            quantity,
            durability_current,
            durability_max,
            custom_name,
            metadata,
            enhancement_level,
            awakening_level,
            acquired_at,
            item_definitions (
              id,
              slug,
              name,
              description,
              category,
              rarity,
              equip_group,
              stackable,
              max_stack,
              icon_url,
              stat_modifiers,
              effects,
              base_value,
              required_level,
              shop_tier,
              shop_price,
              shop_enabled,
              damage_type,
              weapon_base_damage,
              weapon_scaling,
              weapon_family,
              echo_strike_chance_percent,
              damage_resistances,
              damage_bonuses,
              scroll_spell_id,
              scroll_mode,
              unique_property_name,
              unique_property_description,
              unique_effect_type,
              unique_effect_value,
              equipment_set_id,
              religion_origin_slug
            )
          `)
          .eq('character_id', character.id)
          .order('acquired_at', { ascending: true }),
        supabase
          .from('character_equipment')
          .select('character_id, slot, character_item_id, equipped_at')
          .eq('character_id', character.id),
        supabase.rpc('get_character_equipment_sets', {
          p_character_id: character.id,
        }),
      ])

    if (itemError || equipmentError || setError) {
      setInventoryMessage(userFacingError(itemError?.message ?? equipmentError?.message ?? setError?.message, 'Не удалось загрузить инвентарь.'))
      setInventoryBusy(false)
      return
    }

    setItems((itemData as CharacterItem[] | null) ?? [])
    setEquipment((equipmentData as CharacterEquipment[] | null) ?? [])
    setEquipmentSets((setData as EquipmentSetState[] | null) ?? [])
    setInventoryHydrated(true)
    setInventoryBusy(false)
  }

  useEffect(() => {
    setInventoryHydrated(false)
    setEquipmentSets([])
    void loadEquippedState()

    const cancelIdle = scheduleIdle(() => {
      void Promise.all([loadRace(), loadReligionModifiers(), loadTrophies()])
    })

    return cancelIdle
  }, [character.id])

  useEffect(() => {
    if (
      tab === 'character'
      && (characterTab === 'inventory' || characterTab === 'equipment')
    ) {
      void loadInventory()
    }
  }, [tab, characterTab, character.id])

  async function refreshInventoryState() {
    if (inventoryHydrated) return loadInventory()
    return loadEquippedState()
  }

  async function openItemHistory(item: CharacterItem) {
    setHistoryItem(item)
    setHistoryEvents([])
    setHistoryMessage('')
    setHistoryBusy(true)

    const { data, error } = await supabase.rpc('get_item_history', {
      p_character_item_id: item.id,
    })

    if (error) {
      setHistoryMessage(error.message.includes('ITEM_HISTORY_NOT_TRACKED')
        ? 'Для этого типа предмета история не ведётся.'
        : userFacingError(error.message))
      setHistoryBusy(false)
      return
    }

    setHistoryEvents((data as ItemHistoryEvent[] | null) ?? [])
    setHistoryBusy(false)
  }

  async function refreshVisiblePlayerData() {
    await Promise.all([
      loadProgress(),
      loadReligionModifiers(),
      tab === 'character' && characterTab === 'overview'
        ? loadTrophies()
        : Promise.resolve(),
      tab === 'character' && (characterTab === 'inventory' || characterTab === 'equipment')
        ? loadInventory()
        : loadEquippedState(),
    ])
  }

  useSmartRefresh(
    refreshVisiblePlayerData,
    { enabled: true, minGapMs: 1800 },
  )

  useEffect(() => {
    const connection = (navigator as Navigator & {
      connection?: { saveData?: boolean; effectiveType?: string }
    }).connection

    if (
      connection?.saveData
      || connection?.effectiveType === 'slow-2g'
      || connection?.effectiveType === '2g'
    ) return

    return scheduleIdle(() => {
      void import('./BattleCenterPanel')
      void import('./AdventuresPanel')
      void import('./WorldMap')
    }, 2600)
  }, [])

  const itemById = useMemo(
    () => new Map(items.map((item) => [item.id, item])),
    [items],
  )

  const equippedItemIds = useMemo(
    () => new Set(equipment.map((entry) => entry.character_item_id)),
    [equipment],
  )

  const effectiveStats = useMemo(() => {
    if (!progress) return null

    const modifiers = [
      raceDefinition?.stat_modifiers ?? {},
      religionCombatStatModifiers(religionCombatModifiers),
      ...equipment
        .map((entry) => itemById.get(entry.character_item_id))
        .filter((item): item is CharacterItem => Boolean(item))
        .flatMap((item) => {
          const definition = normalizeDefinition(item.item_definitions)
          if (!definition) return []
          return [
            definition.stat_modifiers ?? {},
            affixStatModifiers(item),
            religionItemStatModifiers(item),
          ]
        }),
    ]

    return addStatModifiers(
      {
        strength: progress.strength,
        agility: progress.agility,
        intellect: progress.intellect,
        vitality: progress.vitality,
        luck: progress.luck,
      },
      modifiers,
    )
  }, [equipment, itemById, progress, raceDefinition, religionCombatModifiers])

  const equipmentPercentModifiers = useMemo(() => {
    let maxHpPercent = 0
    let defensePercent = 0

    for (const entry of equipment) {
      const item = itemById.get(entry.character_item_id)
      const definition = item ? normalizeDefinition(item.item_definitions) : null
      if (!item || !definition) continue

      const religiousPenalty = religionItemStatModifiers(item)
      maxHpPercent += Number(definition.stat_modifiers?.max_hp_percent ?? 0)
        + Number(religiousPenalty.max_hp_percent ?? 0)
      defensePercent += Number(definition.stat_modifiers?.defense_percent ?? 0)
        + Number(religiousPenalty.defense_percent ?? 0)
    }

    return {
      maxHpPercent: Math.max(-80, Math.min(200, maxHpPercent)),
      defensePercent: Math.max(-75, Math.min(100, defensePercent)),
    }
  }, [equipment, itemById])

  const equippedWeaponProfile = useMemo(() => {
    const weaponEntry = equipment.find((entry) => entry.slot === 'weapon')
    const weaponItem = weaponEntry ? itemById.get(weaponEntry.character_item_id) : null
    const weaponDefinition = weaponItem ? normalizeDefinition(weaponItem.item_definitions) : null

    return {
      baseDamage: Math.max(
        0,
        Number(weaponDefinition?.weapon_base_damage ?? 0)
          + Number(weaponItem?.metadata?.religion_weapon_base_damage_penalty ?? 0),
      ),
      scaling: weaponDefinition?.weapon_scaling ?? 'strength',
      enhancementLevel: Math.min(20, Math.max(0, Number(weaponItem?.enhancement_level ?? 0))),
    }
  }, [equipment, itemById])

  const derivedCombatStats = useMemo(
    () => progress && effectiveStats
      ? calculateDerivedCombatStats(progress.level, effectiveStats, equippedWeaponProfile)
      : null,
    [effectiveStats, equippedWeaponProfile, progress],
  )

  const raceInitiativeBonus = raceTraitNumber(raceDefinition?.traits, 'initiative_flat')
  const raceCriticalChanceBonus = raceTraitNumber(raceDefinition?.traits, 'critical_chance_bonus')
  const racePhysicalDefensePercent = raceTraitNumber(raceDefinition?.traits, 'physical_defense_percent')

  if (!progress || !effectiveStats || !derivedCombatStats) {
    return (
      <main className="shell">
        <section className="panel">
          <h1>Прогресс персонажа не найден</h1>
          <p className="muted">Обнови страницу. Если ошибка останется, понадобится проверка базы.</p>
        </section>
      </main>
    )
  }

  const nextLevel = experienceForNextLevel(progress.level)
  const expPercent = Math.min(100, Math.round((progress.experience / nextLevel) * 100))
  const effectiveHpMax = Math.max(
    1,
    Math.round(
      progress.hp_max
        * (
          100
          + equipmentPercentModifiers.maxHpPercent
          + Number(religionCombatModifiers.max_hp_percent ?? 0)
        )
        / 100,
    ),
  )
  const effectiveHpCurrent = Math.min(
    effectiveHpMax,
    Math.max(
      0,
      Math.round(progress.hp_current * effectiveHpMax / Math.max(1, progress.hp_max)),
    ),
  )
  const hpPercent = Math.min(100, Math.round((effectiveHpCurrent / effectiveHpMax) * 100))
  const effectivePhysicalDefense = Math.max(
    0,
    Math.round(
      derivedCombatStats.physicalDefense
        * (100 + equipmentPercentModifiers.defensePercent + racePhysicalDefensePercent)
        / 100,
    ),
  )
  const effectiveMagicDefense = Math.max(
    0,
    Math.round(
      derivedCombatStats.magicDefense
        * (
          100
          + equipmentPercentModifiers.defensePercent
          + Number(religionCombatModifiers.magic_defense_percent ?? 0)
        )
        / 100,
    ),
  )
  const physicalArmorReduction = armorDamageReductionPercent(effectivePhysicalDefense)
  const magicArmorReduction = armorDamageReductionPercent(effectiveMagicDefense)

  async function equipItem(item: CharacterItem) {
    const definition = normalizeDefinition(item.item_definitions)
    if (!definition?.equip_group) return

    const characterLevel = progress?.level ?? 1
    if (characterLevel < definition.required_level) {
      setInventoryMessage(
        `«${definition.name}» пока нельзя надеть: нужен ${definition.required_level} уровень, сейчас ${characterLevel}.`,
      )
      return
    }

    let slot: EquipmentSlot

    if (definition.equip_group === 'accessory') {
      const firstOccupied = equipment.some((entry) => entry.slot === 'accessory_1')
      const secondOccupied = equipment.some((entry) => entry.slot === 'accessory_2')
      slot = !firstOccupied ? 'accessory_1' : !secondOccupied ? 'accessory_2' : 'accessory_1'
    } else {
      slot = definition.equip_group
    }

    setInventoryBusy(true)
    setInventoryMessage('')

    const { error } = await supabase.rpc('equip_owned_item', {
      p_character_item_id: item.id,
      p_slot: slot,
    })

    if (error) {
      if (error.message.includes('LEVEL_TOO_LOW')) {
        setInventoryMessage(`Недостаточный уровень персонажа для этой вещи. Требуется уровень ${definition.required_level}.`)
      } else {
        setInventoryMessage(userFacingError(error.message))
      }
      setInventoryBusy(false)
      return
    }

    await loadInventory()
  }

  async function useResourceItem(item: CharacterItem, fillToMax = false) {
    const definition = normalizeDefinition(item.item_definitions)
    if (!definition) return

    setInventoryBusy(true)
    setInventoryMessage('')

    const rpcName = fillToMax ? 'use_resource_consumable_to_full' : 'use_resource_consumable'
    const { data, error } = await supabase.rpc(rpcName, {
      p_character_item_id: item.id,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('ALREADY_FULL_RESOURCES')) {
        setInventoryMessage('ОЗ и мана уже полные.')
      } else if (raw.includes('COMBAT_ACTIVE')) {
        setInventoryMessage('Во время боя используй расходник прямо в интерфейсе боя.')
      } else if (raw.includes('ITEM_IS_NOT_RESOURCE_CONSUMABLE')) {
        setInventoryMessage('Этот предмет не восстанавливает ОЗ или ману.')
      } else {
        setInventoryMessage(userFacingError(raw))
      }
      setInventoryBusy(false)
      return
    }

    const row = Array.isArray(data) ? data[0] : data
    const healed = Number(row?.healed ?? 0)
    const manaRestored = Number(row?.mana_restored ?? 0)
    const itemsUsed = Number(row?.items_used ?? 1)
    await Promise.all([loadInventory(), loadProgress()])

    const restored = [
      healed > 0 ? `+${healed} ОЗ` : '',
      manaRestored > 0 ? `+${manaRestored} маны` : '',
    ].filter(Boolean).join(' · ')

    setInventoryMessage(
      restored
        ? `Восстановлено: ${restored}.${itemsUsed > 1 ? ` Использовано: ${itemsUsed} шт.` : ''}`
        : 'Расходник использован.',
    )
    setInventoryBusy(false)
  }

  async function exchangeItem(item: CharacterItem, quantity: number) {
    const definition = normalizeDefinition(item.item_definitions)
    if (!definition || itemExchangeValue(definition) <= 0) return

    const isEquipment = ['weapon', 'armor', 'accessory'].includes(definition.category)
    if (
      isEquipment
      && !window.confirm(`Обменять «${item.custom_name || definition.name}» на ${itemExchangeValue(definition)} золота? Вещь исчезнет без возможности восстановления.`)
    ) {
      return
    }

    setInventoryBusy(true)
    setInventoryMessage('')

    const { data, error } = await supabase.rpc('exchange_inventory_item', {
      p_character_item_id: item.id,
      p_quantity: quantity,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('UNIQUE_MATERIAL_PROTECTED')) {
        setInventoryMessage('Уникальные ресурсы и материалы нельзя обменять на золото.')
      } else if (raw.includes('PROTECTED_ITEM')) {
        setInventoryMessage('Этот особый предмет нельзя обменять на золото.')
      } else if (raw.includes('ITEM_IS_EQUIPPED')) {
        setInventoryMessage('Сначала сними вещь с персонажа.')
      } else if (raw.includes('COMBAT_ACTIVE')) {
        setInventoryMessage('Во время боя обменивать предметы нельзя.')
      } else if (raw.includes('NOT_ENOUGH_ITEMS')) {
        setInventoryMessage('В инвентаре уже нет такого количества предметов.')
      } else if (raw.includes('ITEM_IS_NOT_EXCHANGEABLE')) {
        setInventoryMessage('Этот предмет нельзя обменять на золото.')
      } else {
        setInventoryMessage(userFacingError(raw))
      }
      setInventoryBusy(false)
      return
    }

    const row = Array.isArray(data) ? data[0] : data
    const exchanged = Number(row?.quantity_exchanged ?? quantity)
    const gold = Number(row?.gold_received ?? 0)

    await Promise.all([loadInventory(), loadProgress()])
    setInventoryMessage(`Обменено: ${definition.name} ×${exchanged} · получено ${gold} золота.`)
    setInventoryBusy(false)
  }

  async function restoreAncientItem(item: CharacterItem) {
    const definition = normalizeDefinition(item.item_definitions)
    const restoration = definition ? ancientRestorationInfo(definition) : null
    if (!definition || !restoration) return

    if (equippedItemIds.has(item.id)) {
      setInventoryMessage('Сначала сними повреждённый древний предмет.')
      return
    }

    if (!window.confirm(
      `Восстановить «${definition.name}» за ${restoration.fragmentCost} Осколка древней реликвии?`,
    )) return

    setInventoryBusy(true)
    setInventoryMessage('')

    const { data, error } = await supabase.rpc('restore_ancient_item', {
      p_character_item_id: item.id,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('NOT_ENOUGH_RELIC_FRAGMENTS')) {
        setInventoryMessage(`Не хватает Осколков древней реликвии. Нужно: ${restoration.fragmentCost}.`)
      } else if (raw.includes('ITEM_IS_EQUIPPED')) {
        setInventoryMessage('Сначала сними повреждённый древний предмет.')
      } else if (raw.includes('COMBAT_ACTIVE')) {
        setInventoryMessage('Нельзя восстанавливать древнюю экипировку во время боя.')
      } else {
        setInventoryMessage(userFacingError(raw))
      }
      setInventoryBusy(false)
      return
    }

    const result = data as { restored_name?: string; fragment_cost?: number } | null
    await loadInventory()
    setInventoryMessage(
      `Восстановлено: ${result?.restored_name ?? 'древний предмет'} · потрачено ${result?.fragment_cost ?? restoration.fragmentCost} осколка.`,
    )
    setInventoryBusy(false)
  }

  async function learnSpellFromScroll(item: CharacterItem) {
    const definition = normalizeDefinition(item.item_definitions)
    if (!definition || definition.scroll_mode !== 'learn') return

    setInventoryBusy(true)
    setInventoryMessage('')

    const { error } = await supabase.rpc('use_learning_scroll', {
      p_character_item_id: item.id,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('LEVEL_TOO_LOW')) {
        setInventoryMessage(`Для изучения этого заклинания нужен уровень ${definition.required_level}.`)
      } else if (raw.includes('SPELL_ALREADY_LEARNED')) {
        setInventoryMessage('Это заклинание уже изучено.')
      } else if (raw.includes('COMBAT_ACTIVE')) {
        setInventoryMessage('Нельзя изучать заклинания во время боя.')
      } else {
        setInventoryMessage(userFacingError(raw))
      }
      setInventoryBusy(false)
      return
    }

    await loadInventory()
    setInventoryMessage(`Заклинание из «${definition.name}» изучено.`)
    setInventoryBusy(false)
  }

  async function unequip(slot: EquipmentSlot) {
    setInventoryBusy(true)
    setInventoryMessage('')

    const { error } = await supabase.rpc('unequip_owned_slot', {
      p_character_id: character.id,
      p_slot: slot,
    })

    if (error) {
      setInventoryMessage(userFacingError(error.message))
      setInventoryBusy(false)
      return
    }

    await loadInventory()
  }

  function customizationError(raw: string) {
    if (raw.includes('NOT_ENOUGH_GOLD')) return 'Не хватает золота.'
    if (raw.includes('RACE_UNCHANGED')) return 'Это уже текущая раса персонажа.'
    if (raw.includes('BIOGRAPHY_UNCHANGED')) return 'Новая биография совпадает с текущей.'
    if (raw.includes('BIOGRAPHY_REQUIRED')) return 'Биография не может быть пустой.'
    if (raw.includes('BIOGRAPHY_TOO_LONG')) return 'Биография не может быть длиннее 4000 символов.'
    if (raw.includes('RACE_REQUIRES_GM_ACCESS')) return 'Эта раса доступна только после разрешения ГМ.'
    if (raw.includes('RACE_NOT_PLAYABLE')) return 'Эта раса сейчас недоступна игрокам.'
    if (raw.includes('CHARACTER_BUSY')) return 'Нельзя менять расу во время боя, данжа, PvP или незавершённого активного действия.'
    return userFacingError(raw)
  }

  async function loadCustomization() {
    const [stateResult, racesResult] = await Promise.all([
      supabase.rpc('get_character_customization_state', {
        p_character_id: character.id,
      }),
      supabase.rpc('get_character_creation_races'),
    ])

    if (stateResult.error || racesResult.error) {
      setCustomizationMessage(
        customizationError(stateResult.error?.message ?? racesResult.error?.message ?? 'Не удалось загрузить настройки персонажа.'),
      )
      return
    }

    const nextState = stateResult.data as CharacterCustomizationState
    const nextRaces = (racesResult.data as RaceDefinition[] | null) ?? []

    setCustomizationState(nextState)
    setCustomizationRaces(nextRaces)
    setSelectedCustomizationRaceId((current) =>
      nextRaces.some((race) => race.id === current)
        ? current
        : nextState.current_race_id,
    )
    setCustomizationBio(nextState.bio)
  }

  useEffect(() => {
    if (tab === 'more') void loadCustomization()
  }, [tab, character.id])

  useEffect(() => {
    try {
      window.sessionStorage.setItem('veira:player-tab', tab)
      window.sessionStorage.setItem('veira:character-tab', characterTab)
    } catch {
      // Session storage is a convenience only; navigation must keep working without it.
    }
  }, [tab, characterTab])

  useEffect(() => {
    const frame = window.requestAnimationFrame(() => {
      window.scrollTo({ top: 0, behavior: 'auto' })
    })
    return () => window.cancelAnimationFrame(frame)
  }, [tab, characterTab, moreView])

  useEffect(() => {
    if (!historyItem) return

    const previousBodyOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'

    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setHistoryItem(null)
    }

    window.addEventListener('keydown', closeOnEscape)
    return () => {
      document.body.style.overflow = previousBodyOverflow
      window.removeEventListener('keydown', closeOnEscape)
    }
  }, [historyItem])

  useEffect(() => {
    const handleNativeBack = (event: Event) => {
      if (historyItem) {
        setHistoryItem(null)
        event.preventDefault()
        return
      }

      if (tab === 'more' && moreView !== 'menu') {
        setMoreView('menu')
        event.preventDefault()
        return
      }

      if (tab === 'character' && characterTab !== 'overview') {
        setCharacterTab('overview')
        event.preventDefault()
        return
      }

      if (tab !== 'character') {
        setTab('character')
        event.preventDefault()
      }
    }

    window.addEventListener('veira:native-back', handleNativeBack)
    return () => window.removeEventListener('veira:native-back', handleNativeBack)
  }, [characterTab, historyItem, moreView, tab])

  async function changeRace() {
    if (!customizationState) return

    if (selectedCustomizationRaceId === customizationState.current_race_id) {
      setCustomizationMessage('Сначала выбери другую расу.')
      return
    }

    const selectedRace = customizationRaces.find((race) => race.id === selectedCustomizationRaceId)
    if (!selectedRace) return

    const free = customizationState.free_race_changes > 0
    const costText = free
      ? `бесплатную смену расы? После неё останется ${customizationState.free_race_changes - 1} бесплатн.`
      : `смену расы за ${customizationState.race_change_cost} золота?`

    if (!window.confirm(`Сменить расу на «${selectedRace.name}» и использовать ${costText}`)) return

    setCustomizationBusy('race')
    setCustomizationMessage('')

    const { data, error } = await supabase.rpc('change_character_race', {
      p_character_id: character.id,
      p_race_id: selectedCustomizationRaceId,
    })

    if (error) {
      setCustomizationMessage(customizationError(error.message))
      setCustomizationBusy(null)
      return
    }

    const result = data as {
      race_name: string
      used_free: boolean
      gold_spent: number
      free_race_changes: number
      gold: number
    }

    setCharacterRaceName(result.race_name)
    await Promise.all([
      loadRace(),
      loadProgress(),
      loadCustomization(),
    ])

    setCustomizationMessage(
      result.used_free
        ? `Раса изменена на «${result.race_name}». Бесплатных смен осталось: ${result.free_race_changes}.`
        : `Раса изменена на «${result.race_name}». Списано ${result.gold_spent} золота.`,
    )
    setCustomizationBusy(null)
  }

  async function changeBio() {
    if (!customizationState) return

    const nextBio = customizationBio.trim()
    if (!nextBio) {
      setCustomizationMessage('Биография не может быть пустой.')
      return
    }

    if (nextBio === characterBio.trim()) {
      setCustomizationMessage('Новая биография совпадает с текущей.')
      return
    }

    const free = customizationState.free_bio_changes > 0
    const costText = free
      ? `бесплатное изменение? После него останется ${customizationState.free_bio_changes - 1} бесплатн.`
      : `изменение за ${customizationState.bio_change_cost} золота?`

    if (!window.confirm(`Сохранить новую биографию и использовать ${costText}`)) return

    setCustomizationBusy('bio')
    setCustomizationMessage('')

    const { data, error } = await supabase.rpc('change_character_bio', {
      p_character_id: character.id,
      p_bio: nextBio,
    })

    if (error) {
      setCustomizationMessage(customizationError(error.message))
      setCustomizationBusy(null)
      return
    }

    const result = data as {
      bio: string
      used_free: boolean
      gold_spent: number
      free_bio_changes: number
      gold: number
    }

    setCharacterBio(result.bio)
    setCustomizationBio(result.bio)
    await Promise.all([
      loadProgress(),
      loadCustomization(),
    ])

    setCustomizationMessage(
      result.used_free
        ? `Биография обновлена. Бесплатных изменений осталось: ${result.free_bio_changes}.`
        : `Биография обновлена. Списано ${result.gold_spent} золота.`,
    )
    setCustomizationBusy(null)
  }

  async function sendEmailVerification() {
    if (!userEmail || profile.email_verified) return

    setSecurityBusy(true)
    setSecurityMessage('')

    const redirectTo = window.location.origin + import.meta.env.BASE_URL
    const { error } = await supabase.auth.signInWithOtp({
      email: userEmail,
      options: {
        shouldCreateUser: false,
        emailRedirectTo: redirectTo,
      },
    })

    if (error) {
      setSecurityMessage(userFacingError(error.message, 'Не удалось обновить настройки безопасности.'))
      setSecurityBusy(false)
      return
    }

    setSecurityMessage(
      'Письмо отправлено. Открой ссылку в нём — после возвращения в Veira почта станет подтверждённой.',
    )
    setSecurityBusy(false)
  }

  async function allocateStatPoint(stat: StatKey) {
    if (!progress || progress.unspent_stat_points <= 0) return

    setStatBusy(true)
    setProgressMessage('')

    const { error } = await supabase.rpc('allocate_character_stat_point', {
      p_character_id: character.id,
      p_stat: stat,
    })

    if (error) {
      setProgressMessage(userFacingError(error.message, 'Не удалось обновить данные персонажа.'))
      setStatBusy(false)
      return
    }

    await loadProgress()
    setStatBusy(false)
  }

  return (
    <main className="shell game-shell">
      <header className="topbar">
        <div className="identity">
          <div className={'avatar-placeholder ' + (character.avatar_url ? 'has-image' : '')} aria-hidden="true">
            <span>{character.name.slice(0, 1).toUpperCase()}</span>
            {character.avatar_url && (
              <img
                src={character.avatar_url}
                alt=""
                draggable={false}
                onError={(event) => {
                  event.currentTarget.style.display = 'none'
                }}
              />
            )}
          </div>
          <div>
            <span className="eyebrow">{characterRaceName}</span>
            <h1>{character.name}</h1>
            <p className="muted">@{profile.display_name}</p>
          </div>
        </div>

        <div className="top-actions">
          <span className="badge">УР. {progress.level}</span>
          <button className="ghost-button" type="button" onClick={() => void onSignOut()}>
            Выйти
          </button>
        </div>
      </header>

      {tab === 'character' && (
        <>
          <div className="subnav" aria-label="Раздел персонажа">
            <button
              type="button"
              className={characterTab === 'overview' ? 'active' : ''}
              onClick={() => setCharacterTab('overview')}
            >
              Обзор
            </button>
            <button
              type="button"
              className={characterTab === 'religion' ? 'active' : ''}
              onClick={() => setCharacterTab('religion')}
            >
              Вера
            </button>
            <button
              type="button"
              className={characterTab === 'inventory' ? 'active' : ''}
              onClick={() => setCharacterTab('inventory')}
            >
              Инвентарь
            </button>
            <button
              type="button"
              className={characterTab === 'equipment' ? 'active' : ''}
              onClick={() => setCharacterTab('equipment')}
            >
              Экипировка
            </button>
            <button
              type="button"
              className={characterTab === 'magic' ? 'active' : ''}
              onClick={() => setCharacterTab('magic')}
            >
              Магия
            </button>
            <button
              type="button"
              className={characterTab === 'crafting' ? 'active' : ''}
              onClick={() => setCharacterTab('crafting')}
            >
              Ремесло
            </button>
          </div>

          {characterTab === 'overview' && (
            <>
              <section className="dashboard-grid">
                <article className="panel vital-card">
                  <div className="card-heading">
                    <span>Здоровье</span>
                    <strong>{effectiveHpCurrent} / {effectiveHpMax}</strong>
                  </div>
                  <div className="meter"><span style={{ width: hpPercent + '%' }} /></div>
                  <small className="passive-regen-note">
                    Пассивное восстановление: +{raceDefinition?.hp_regen_per_hour ?? 50} ОЗ в час вне активного боя
                  </small>
                </article>

                <article className="panel vital-card">
                  <div className="card-heading">
                    <span>Мана</span>
                    <strong>{progress.mana_current ?? 0} / {progress.mana_max ?? 0}</strong>
                  </div>
                  <div className="meter mana-meter">
                    <span
                      style={{
                        width: (progress.mana_max ?? 0) > 0
                          ? Math.round(((progress.mana_current ?? 0) / (progress.mana_max ?? 1)) * 100) + '%'
                          : '0%',
                      }}
                    />
                  </div>
                  <small className="passive-regen-note">
                    Пассивное восстановление: +{raceDefinition?.mana_regen_per_hour ?? 35} маны в час вне активного боя
                  </small>
                </article>

                <article className="panel vital-card">
                  <div className="card-heading">
                    <span>Опыт</span>
                    <strong>{progress.experience} / {nextLevel}</strong>
                  </div>
                  <div className="meter exp-meter"><span style={{ width: expPercent + '%' }} /></div>
                </article>

                <article className="panel currency-card">
                  <span>Золото</span>
                  <strong>{progress.gold.toLocaleString('ru-RU')}</strong>
                </article>
              </section>

              {trophies.length > 0 && (
                <section className="panel character-trophy-showcase">
                  <div className="section-heading">
                    <div>
                      <span className="eyebrow">ТРОФЕИ</span>
                      <h2>Витрина охотника</h2>
                      <p className="muted">Редкие хранители оставляют вещи, которые остаются частью истории персонажа.</p>
                    </div>
                    <span className="badge">{trophies.reduce((sum, trophy) => sum + trophy.quantity, 0)}</span>
                  </div>
                  <div className="character-trophy-grid">
                    {trophies.slice(0, 6).map((trophy) => (
                      <div className="character-trophy-item" key={trophy.slug}>
                        <strong>{trophy.name}</strong>
                        <small>{trophy.description}</small>
                        {trophy.quantity > 1 && <b>×{trophy.quantity}</b>}
                      </div>
                    ))}
                  </div>
                </section>
              )}

              {raceDefinition && (
                <section className="panel player-race-panel">
                  <div className="section-heading">
                    <div>
                      <span className="eyebrow">РАСА</span>
                      <h2>{raceDefinition.name}</h2>
                      <p className="muted">{raceDefinition.description}</p>
                    </div>
                    <span className="badge">
                      {damageTypeLabels[raceDefinition.innate_magic_damage_type]}
                    </span>
                  </div>

                  <div className="race-mechanic-grid">
                    <span><small>Макс. ОЗ</small><strong>{raceDefinition.hp_bonus >= 0 ? '+' : ''}{raceDefinition.hp_bonus}</strong></span>
                    <span><small>Макс. ОМ</small><strong>{raceDefinition.mana_bonus >= 0 ? '+' : ''}{raceDefinition.mana_bonus}</strong></span>
                    <span><small>Реген ОЗ/ч</small><strong>{raceDefinition.hp_regen_per_hour}</strong></span>
                    <span><small>Реген ОМ/ч</small><strong>{raceDefinition.mana_regen_per_hour}</strong></span>
                  </div>

                  {Object.entries(raceDefinition.damage_resistances ?? {})
                    .filter((entry): entry is [DamageType, number] => typeof entry[1] === 'number' && entry[1] !== 0)
                    .length > 0 && (
                      <div className="race-resistance-list">
                        {Object.entries(raceDefinition.damage_resistances ?? {})
                          .filter((entry): entry is [DamageType, number] => typeof entry[1] === 'number' && entry[1] !== 0)
                          .map(([type, value]) => (
                            <span className={value >= 0 ? 'positive' : 'negative'} key={type}>
                              {damageTypeLabels[type]} {value >= 0 ? '+' : ''}{value}%
                            </span>
                          ))}
                      </div>
                    )}

                  {raceStatEntries(raceDefinition).length > 0 && (
                    <div className="race-trait-list">
                      {raceStatEntries(raceDefinition).map(([stat, value]) => (
                        <span key={stat}>
                          {statLabels[stat as StatKey] ?? stat} {value > 0 ? '+' : ''}{value}
                        </span>
                      ))}
                    </div>
                  )}

                  {raceDefinition.passive_name && (
                    <div className="race-passive-card">
                      <strong>{raceDefinition.passive_name}</strong>
                      <p>{raceDefinition.passive_description}</p>
                    </div>
                  )}

                  {(raceDefinition.traits ?? []).filter((trait) => trait.name && trait.description).length > 0 && (
                    <div className="race-extra-traits">
                      {(raceDefinition.traits ?? [])
                        .filter((trait) => trait.name && trait.description)
                        .map((trait, index) => (
                          <div key={trait.type + ':' + index}>
                            <strong>{trait.name}</strong>
                            <p>{trait.description}</p>
                          </div>
                        ))}
                    </div>
                  )}
                </section>
              )}

              <section className="panel">
                <div className="section-heading">
                  <div>
                    <span className="eyebrow">ХАРАКТЕРИСТИКИ</span>
                    <h2>Основа персонажа</h2>
                  </div>
                  <span className="muted stat-note">Экипировка уже учитывается</span>
                </div>

                <div className="stats-grid">
                  <Stat label="Сила" value={effectiveStats.strength} base={progress.strength} />
                  <Stat label="Ловкость" value={effectiveStats.agility} base={progress.agility} />
                  <Stat label="Интеллект" value={effectiveStats.intellect} base={progress.intellect} />
                  <Stat label="Живучесть" value={effectiveStats.vitality} base={progress.vitality} />
                  <Stat label="Удача" value={effectiveStats.luck} base={progress.luck} />
                </div>
              </section>

              {progress.unspent_stat_points > 0 && (
                <section className="panel level-up-panel">
                  <div className="section-heading">
                    <div>
                      <span className="eyebrow">ПОВЫШЕНИЕ УРОВНЯ</span>
                      <h2>Свободные очки характеристик</h2>
                    </div>
                    <span className="badge stat-points-badge">
                      {progress.unspent_stat_points} очк.
                    </span>
                  </div>

                  <p className="muted level-up-copy">
                    За каждый новый уровень персонаж получает 2 очка. Здесь уже нет стартового лимита 8 — развивай нужные характеристики дальше.
                  </p>

                  {progressMessage && <p className="form-message" aria-live="polite">{progressMessage}</p>}

                  <div className="level-up-grid">
                    {(Object.keys(statLabels) as StatKey[]).map((stat) => (
                      <button
                        key={stat}
                        type="button"
                        disabled={statBusy || progress.unspent_stat_points <= 0}
                        onClick={() => void allocateStatPoint(stat)}
                      >
                        <span>
                          <strong>{statLabels[stat]}</strong>
                          <small>Сейчас {progress[stat]}</small>
                          {statUpgradeHints[stat] && <small className="stat-upgrade-hint">{statUpgradeHints[stat]}</small>}
                        </span>
                        <b>+1</b>
                      </button>
                    ))}
                  </div>
                </section>
              )}

              <section className="panel">
                <div className="section-heading">
                  <div>
                    <span className="eyebrow">БОЕВЫЕ ПАРАМЕТРЫ</span>
                    <h2>Производные характеристики</h2>
                  </div>
                </div>

                <div className="combat-stats-grid">
                  <CombatStat label="Физ. мощь" value={derivedCombatStats.physicalPower} />
                  <CombatStat label="Маг. мощь" value={derivedCombatStats.magicPower} />
                  <CombatStat
                    label="Физ. броня"
                    value={effectivePhysicalDefense + ' · ' + physicalArmorReduction.toFixed(1) + '%'}
                  />
                  <CombatStat
                    label="Маг. броня"
                    value={effectiveMagicDefense + ' · ' + magicArmorReduction.toFixed(1) + '%'}
                  />
                  <CombatStat
                    label="Инициатива"
                    value={Math.round(derivedCombatStats.initiative + raceInitiativeBonus)}
                    hint="Высокая инициатива копит темп для дополнительного полного действия"
                  />
                  <CombatStat
                    label="Шанс крита"
                    value={Math.min(75, derivedCombatStats.criticalChancePercent + raceCriticalChanceBonus).toFixed(1) + '%'}
                  />
                  <CombatStat label="Крит. урон" value="Физ. ×1.5 · Маг. ×1.4" />
                </div>
              </section>

              <section className="panel">
                <span className="eyebrow">БИОГРАФИЯ</span>
                <p className="bio-text">{characterBio || 'Биография пока не заполнена.'}</p>
              </section>
            </>
          )}

          {characterTab === 'religion' && (
            <Suspense fallback={<LazyPanelFallback title="Загружаем религии…" />}>
              <ReligionPanel
                characterId={character.id}
                onReligionChanged={loadReligionModifiers}
                onInventoryChanged={refreshInventoryState}
              />
            </Suspense>
          )}

          {characterTab === 'inventory' && (
            <InventoryPanel
              items={items}
              equippedItemIds={equippedItemIds}
              characterLevel={progress.level}
              busy={inventoryBusy}
              message={inventoryMessage}
              onEquip={equipItem}
              onUseResource={useResourceItem}
              onExchangeItem={exchangeItem}
              onLearnScroll={learnSpellFromScroll}
              onRestoreAncient={restoreAncientItem}
              onHistory={openItemHistory}
            />
          )}

          {characterTab === 'equipment' && (
            <EquipmentPanel
              equipment={equipment}
              equipmentSets={equipmentSets}
              itemById={itemById}
              busy={inventoryBusy}
              message={inventoryMessage}
              onUnequip={unequip}
            />
          )}

          {characterTab === 'magic' && (
            <Suspense fallback={<LazyPanelFallback title="Загружаем магию…" />}>
              <MagicPanel
                characterId={character.id}
                progress={progress}
              />
            </Suspense>
          )}

          {characterTab === 'crafting' && (
            <Suspense fallback={<LazyPanelFallback title="Загружаем ремесло…" />}>
              <CraftingPanel
                characterId={character.id}
                progress={progress}
                onProgressChanged={loadProgress}
                onInventoryChanged={refreshInventoryState}
              />
            </Suspense>
          )}
        </>
      )}

      {tab === 'world' && (
        <Suspense fallback={<LazyPanelFallback title="Загружаем карту…" />}>
          <WorldMap
            characterId={character.id}
            onOpenBattles={() => setTab('battles')}
            onProgressChanged={loadProgress}
            onInventoryChanged={refreshInventoryState}
          />
        </Suspense>
      )}
      {tab === 'adventures' && (
        <Suspense fallback={<LazyPanelFallback title="Загружаем приключения…" />}>
          <AdventuresPanel
            characterId={character.id}
            onOpenBattles={() => setTab('battles')}
            onProgressChanged={loadProgress}
            onInventoryChanged={refreshInventoryState}
          />
        </Suspense>
      )}
      {tab === 'battles' && (
        <Suspense fallback={<LazyPanelFallback title="Загружаем бои…" />}>
          <BattleCenterPanel
            characterId={character.id}
            onProgressChanged={loadProgress}
            onInventoryChanged={refreshInventoryState}
          />
        </Suspense>
      )}
      {tab === 'more' && moreView === 'guide' && (
        <Suspense fallback={<LazyPanelFallback title="Загружаем гид…" />}>
          <GuidePanel onBack={() => setMoreView('menu')} />
        </Suspense>
      )}
      {tab === 'more' && moreView === 'communities' && (
        <Suspense fallback={<LazyPanelFallback title="Загружаем сообщества…" />}>
          <CommunitiesPanel characterId={character.id} onBack={() => setMoreView('menu')} />
        </Suspense>
      )}
      {tab === 'more' && moreView === 'menu' && (
        <div className="more-section">
          <section className="panel communities-entry-panel">
            <div>
              <span className="eyebrow">СООБЩЕСТВА</span>
              <h2>Объединения игроков</h2>
              <p className="muted">
                Гильдии, участники, заявки и управление сообществами собраны в одном разделе.
              </p>
            </div>
            <button
              className="primary-button"
              type="button"
              onClick={() => setMoreView('communities')}
            >
              Открыть сообщества
            </button>
          </section>

          <section className="panel guide-entry-panel">
            <div>
              <span className="eyebrow">ГИД VEIRA</span>
              <h2>Механики, предметы и заклинания</h2>
              <p className="muted">
                Полный справочник по оружию, броне, аксессуарам, магии, баффам и дебаффам,
                аффиксам, заточке, пробуждению, Кровопролитию, подземельям и другим системам.
              </p>
            </div>
            <button
              className="primary-button"
              type="button"
              onClick={() => setMoreView('guide')}
            >
              Открыть гид
            </button>
          </section>
          <section className="panel account-security-panel">
            <div className="section-heading">
              <div>
                <span className="eyebrow">АККАУНТ</span>
                <h2>Безопасность и почта</h2>
              </div>
              <span className={'badge ' + (profile.email_verified ? 'ready' : '')}>
                {profile.email_verified ? 'почта подтверждена' : 'почта не подтверждена'}
              </span>
            </div>

            <div className="account-email-row">
              <div>
                <span>Почта аккаунта</span>
                <strong>{userEmail || 'не указана'}</strong>
              </div>

              {!profile.email_verified && userEmail && (
                <button
                  className="primary-button"
                  type="button"
                  disabled={securityBusy}
                  onClick={() => void sendEmailVerification()}
                >
                  {securityBusy ? 'Отправляем…' : 'Подтвердить почту'}
                </button>
              )}
            </div>

            {profile.email_verified ? (
              <p className="account-security-note verified">
                Эта почта подтверждена. Её можно использовать как доверенный способ восстановления доступа
                и для будущих чувствительных действий аккаунта.
              </p>
            ) : (
              <p className="account-security-note">
                Подтверждение добровольное: играть, создавать персонажа и пользоваться обычными механиками
                можно сразу. Проверенная почта понадобится для восстановления доступа и отдельных
                чувствительных действий, когда они появятся.
              </p>
            )}

            {securityMessage && (
              <p className="form-message" aria-live="polite">{securityMessage}</p>
            )}
          </section>

          {isNativeApp && (
            <section className="panel native-build-panel">
              <div>
                <span className="eyebrow">ANDROID</span>
                <h2>Veira для Android</h2>
                <p className="muted">
                  Нативная тестовая сборка. При сообщении о баге можно приложить номер сборки — так проще понять, какая версия установлена.
                </p>
              </div>
              <div className="native-build-meta">
                <span>Сборка <strong>{appBuildNumber || 'локальная'}</strong></span>
                {appBuildSha && <code>{appBuildSha.slice(0, 8)}</code>}
              </div>
            </section>
          )}

          <section className="panel character-customization-panel">
            <div className="section-heading">
              <div>
                <span className="eyebrow">ПЕРСОНАЖ</span>
                <h2>Изменить персонажа</h2>
                <p className="muted">
                  У каждого персонажа есть по 2 бесплатных изменения расы и биографии. После этого используются монеты.
                </p>
              </div>
              <span className="badge">
                {customizationState ? `${customizationState.gold.toLocaleString('ru-RU')} золота` : 'загрузка…'}
              </span>
            </div>

            {customizationMessage && (
              <p className="form-message" aria-live="polite">{customizationMessage}</p>
            )}

            <div className="character-customization-grid">
              <article className="character-customization-card">
                <div className="character-customization-card-head">
                  <div>
                    <span className="eyebrow">РАСА</span>
                    <strong>{customizationState?.current_race_name ?? characterRaceName}</strong>
                  </div>
                  <span className={'customization-free-count ' + ((customizationState?.free_race_changes ?? 0) > 0 ? 'ready' : '')}>
                    Бесплатно: {customizationState?.free_race_changes ?? '…'}
                  </span>
                </div>

                <p>
                  Первые две смены бесплатны. Затем каждая смена стоит <b>150 золота</b>.
                  Во время обычной экспедиции расу менять можно. Смена блокируется только во время боя, данжа, PvP и незавершённого активного действия.
                </p>

                <label>
                  <span>Новая раса</span>
                  <select
                    value={selectedCustomizationRaceId}
                    disabled={customizationBusy !== null || !customizationState}
                    onChange={(event) => setSelectedCustomizationRaceId(event.target.value)}
                  >
                    {customizationRaces.map((race) => (
                      <option
                        key={race.id}
                        value={race.id}
                        disabled={race.is_available === false}
                      >
                        {race.name}{race.is_available === false ? ' · нужен доступ ГМ' : ''}
                      </option>
                    ))}
                  </select>
                </label>

                {customizationRaces.find((race) => race.id === selectedCustomizationRaceId) && (
                  <small className="character-customization-preview">
                    {customizationRaces.find((race) => race.id === selectedCustomizationRaceId)?.description}
                  </small>
                )}

                <button
                  className="primary-button"
                  type="button"
                  disabled={
                    customizationBusy !== null
                    || !customizationState
                    || customizationState.busy_for_race_change
                    || customizationRaces.find((race) => race.id === selectedCustomizationRaceId)?.is_available === false
                  }
                  onClick={() => void changeRace()}
                >
                  {customizationBusy === 'race'
                    ? 'Меняем…'
                    : customizationState && selectedCustomizationRaceId === customizationState.current_race_id
                      ? 'Выбери другую расу'
                      : customizationState?.free_race_changes
                        ? `Сменить бесплатно · осталось ${customizationState.free_race_changes}`
                        : 'Сменить расу · 150 золота'}
                </button>
              </article>

              <article className="character-customization-card">
                <div className="character-customization-card-head">
                  <div>
                    <span className="eyebrow">БИОГРАФИЯ</span>
                    <strong>Переписать историю</strong>
                  </div>
                  <span className={'customization-free-count ' + ((customizationState?.free_bio_changes ?? 0) > 0 ? 'ready' : '')}>
                    Бесплатно: {customizationState?.free_bio_changes ?? '…'}
                  </span>
                </div>

                <p>
                  Первые два изменения бесплатны. Затем каждое сохранение новой биографии стоит <b>50 золота</b>.
                </p>

                <label>
                  <span>Новая биография</span>
                  <textarea
                    value={customizationBio}
                    maxLength={4000}
                    rows={8}
                    disabled={customizationBusy !== null || !customizationState}
                    onChange={(event) => setCustomizationBio(event.target.value)}
                  />
                </label>

                <small className="character-customization-preview">
                  {customizationBio.length} / 4000 символов
                </small>

                <button
                  className="primary-button"
                  type="button"
                  disabled={
                    customizationBusy !== null
                    || !customizationState
                    || !customizationBio.trim()
                  }
                  onClick={() => void changeBio()}
                >
                  {customizationBusy === 'bio'
                    ? 'Сохраняем…'
                    : customizationBio.trim() === characterBio.trim()
                      ? 'Внеси изменения в биографию'
                      : customizationState?.free_bio_changes
                        ? `Изменить бесплатно · осталось ${customizationState.free_bio_changes}`
                        : 'Изменить биографию · 50 золота'}
                </button>
              </article>
            </div>
          </section>

        </div>
      )}

      {historyItem && (
        <div className="item-history-overlay" role="presentation" onMouseDown={(event) => {
          if (event.currentTarget === event.target) setHistoryItem(null)
        }}>
          <section className="panel item-history-dialog" role="dialog" aria-modal="true" aria-label="История предмета">
            <div className="item-history-heading">
              <div>
                <span className="eyebrow">ХРОНИКА ПРЕДМЕТА</span>
                <h2>{historyItem.custom_name || normalizeDefinition(historyItem.item_definitions)?.name || 'Предмет'}</h2>
                <p className="muted">История относится именно к этому экземпляру и сохраняется при смене владельца.</p>
              </div>
              <button className="ghost-button" type="button" onClick={() => setHistoryItem(null)}>Закрыть</button>
            </div>

            {historyBusy ? (
              <p className="muted">Читаем хронику…</p>
            ) : historyMessage ? (
              <p className="form-message">{historyMessage}</p>
            ) : historyEvents.length === 0 ? (
              <p className="muted">У этого экземпляра пока нет записанных событий.</p>
            ) : (
              <div className="item-history-timeline">
                {historyEvents.map((event) => (
                  <article className={'item-history-event type-' + event.event_type} key={event.event_id}>
                    <span className="item-history-dot" aria-hidden="true" />
                    <div>
                      <div className="item-history-event-head">
                        <strong>{event.title}</strong>
                        <time dateTime={event.created_at}>
                          {new Date(event.created_at).toLocaleString('ru-RU')}
                        </time>
                      </div>
                      {event.description && <p>{event.description}</p>}
                      {event.owner_name && <small>Владелец: {event.owner_name}</small>}
                    </div>
                  </article>
                ))}
              </div>
            )}
          </section>
        </div>
      )}

      <nav className="bottom-nav" aria-label="Основная навигация">
        <NavButton icon="world" active={tab === 'world'} onClick={() => setTab('world')}>Мир</NavButton>
        <NavButton icon="character" active={tab === 'character'} onClick={() => setTab('character')}>Персонаж</NavButton>
        <NavButton icon="adventures" active={tab === 'adventures'} onClick={() => setTab('adventures')}>Приключения</NavButton>
        <NavButton icon="battles" active={tab === 'battles'} onClick={() => setTab('battles')}>Бои</NavButton>
        <NavButton
          icon="more"
          active={tab === 'more'}
          onClick={() => {
            setTab('more')
            setMoreView('menu')
          }}
        >
          Ещё
        </NavButton>
      </nav>
    </main>
  )
}

function LazyPanelFallback({ title }: { title: string }) {
  return (
    <section className="panel lazy-panel-fallback">
      <span className="eyebrow">VEIRA</span>
      <h3>{title}</h3>
    </section>
  )
}

type InventoryFilter = 'all' | 'weapon' | 'armor' | 'accessory' | 'consumable' | 'material' | 'other'
type InventorySort = 'rarity' | 'level' | 'name'

const inventoryRarityRank: Record<ItemDefinition['rarity'], number> = {
  common: 0,
  uncommon: 1,
  rare: 2,
  epic: 3,
  legendary: 4,
  unique: 5,
}

function InventoryPanel({
  items,
  equippedItemIds,
  characterLevel,
  busy,
  message,
  onEquip,
  onUseResource,
  onExchangeItem,
  onLearnScroll,
  onRestoreAncient,
  onHistory,
}: {
  items: CharacterItem[]
  equippedItemIds: Set<string>
  characterLevel: number
  busy: boolean
  message: string
  onEquip: (item: CharacterItem) => Promise<void>
  onUseResource: (item: CharacterItem, fillToMax?: boolean) => Promise<void>
  onExchangeItem: (item: CharacterItem, quantity: number) => Promise<void>
  onLearnScroll: (item: CharacterItem) => Promise<void>
  onRestoreAncient: (item: CharacterItem) => Promise<void>
  onHistory: (item: CharacterItem) => Promise<void>
}) {
  const [filter, setFilter] = useState<InventoryFilter>('all')
  const [query, setQuery] = useState('')
  const [sort, setSort] = useState<InventorySort>('rarity')

  const categoryCounts = useMemo(() => {
    const counts: Record<InventoryFilter, number> = {
      all: items.length,
      weapon: 0,
      armor: 0,
      accessory: 0,
      consumable: 0,
      material: 0,
      other: 0,
    }

    for (const item of items) {
      const definition = normalizeDefinition(item.item_definitions)
      if (!definition) continue
      if (definition.category === 'weapon') counts.weapon += 1
      else if (definition.category === 'armor') counts.armor += 1
      else if (definition.category === 'accessory') counts.accessory += 1
      else if (definition.category === 'consumable') counts.consumable += 1
      else if (definition.category === 'material') counts.material += 1
      else counts.other += 1
    }

    return counts
  }, [items])

  const visibleItems = useMemo(() => {
    const normalizedQuery = query.trim().toLocaleLowerCase('ru-RU')

    return items
      .filter((item) => {
        const definition = normalizeDefinition(item.item_definitions)
        if (!definition) return false

        const categoryMatches = filter === 'all'
          || (filter === 'other'
            ? !['weapon', 'armor', 'accessory', 'consumable', 'material'].includes(definition.category)
            : definition.category === filter)

        if (!categoryMatches) return false
        if (!normalizedQuery) return true

        return [
          item.custom_name ?? '',
          definition.name,
          definition.description,
          rarityLabels[definition.rarity],
          definition.weapon_family ? weaponFamilyLabels[definition.weapon_family] : '',
          ...itemAffixes(item).map((affix) => affix.name),
        ]
          .join(' ')
          .toLocaleLowerCase('ru-RU')
          .includes(normalizedQuery)
      })
      .sort((left, right) => {
        const leftDefinition = normalizeDefinition(left.item_definitions)
        const rightDefinition = normalizeDefinition(right.item_definitions)
        if (!leftDefinition || !rightDefinition) return 0

        if (sort === 'name') {
          return (left.custom_name || leftDefinition.name)
            .localeCompare(right.custom_name || rightDefinition.name, 'ru-RU')
        }

        if (sort === 'level') {
          return rightDefinition.required_level - leftDefinition.required_level
            || inventoryRarityRank[rightDefinition.rarity] - inventoryRarityRank[leftDefinition.rarity]
        }

        return inventoryRarityRank[rightDefinition.rarity] - inventoryRarityRank[leftDefinition.rarity]
          || rightDefinition.required_level - leftDefinition.required_level
          || (left.custom_name || leftDefinition.name)
            .localeCompare(right.custom_name || rightDefinition.name, 'ru-RU')
      })
  }, [filter, items, query, sort])

  const filters: Array<[InventoryFilter, string]> = [
    ['all', 'Все'],
    ['weapon', 'Оружие'],
    ['armor', 'Броня'],
    ['accessory', 'Аксессуары'],
    ['consumable', 'Расходники'],
    ['material', 'Ресурсы'],
    ['other', 'Прочее'],
  ]

  return (
    <section className="panel">
      <div className="section-heading">
        <div>
          <span className="eyebrow">ИНВЕНТАРЬ</span>
          <h2>Предметы персонажа</h2>
        </div>
        <span className="badge">{items.length} ячеек</span>
      </div>

      {message && <p className="form-message" role="status" aria-live="polite">{message}</p>}

      <div className="inventory-toolbar">
        <label className="inventory-search">
          <span>Поиск</span>
          <input
            type="search"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Название, редкость, аффикс…"
            aria-label="Поиск по инвентарю"
          />
        </label>
        <label className="inventory-sort">
          <span>Сортировка</span>
          <select value={sort} onChange={(event) => setSort(event.target.value as InventorySort)}>
            <option value="rarity">Сначала редкие</option>
            <option value="level">По уровню</option>
            <option value="name">По названию</option>
          </select>
        </label>
      </div>

      <div className="inventory-filter-tabs" role="tablist" aria-label="Фильтр инвентаря">
        {filters.map(([key, label]) => (
          <button
            className={filter === key ? 'active' : ''}
            type="button"
            role="tab"
            aria-selected={filter === key}
            key={key}
            onClick={() => setFilter(key)}
          >
            <span>{label}</span>
            <b>{categoryCounts[key]}</b>
          </button>
        ))}
      </div>

      {items.length === 0 ? (
        <p className="muted">Инвентарь пуст.</p>
      ) : visibleItems.length === 0 ? (
        <p className="muted">
          {query.trim() ? 'По этому запросу предметов не найдено.' : 'В этой категории пока ничего нет.'}
        </p>
      ) : (
        <div className="inventory-grid">
          {visibleItems.map((item) => {
            const definition = normalizeDefinition(item.item_definitions)
            if (!definition) return null

            const equipped = equippedItemIds.has(item.id)
            const lockedByLevel = definition.required_level > characterLevel
            const modifiers = Object.entries(definition.stat_modifiers ?? {})
              .filter((entry): entry is [string, number] =>
                typeof entry[1] === 'number'
                && !['first_physical_strike_multiplier', 'first_physical_bonus_damage_multiplier'].includes(entry[0]),
              )
            const resourceAmounts = getResourceAmounts(definition)
            const affixes = itemAffixes(item)
            const affixModifiers = Object.entries(affixStatModifiers(item))
              .filter((entry): entry is [string, number] => typeof entry[1] === 'number')
            const resistances = Object.entries(combinedResistances(item, definition))
              .filter((entry): entry is [DamageType, number] => typeof entry[1] === 'number' && entry[1] !== 0)
            const damageBonuses = Object.entries(definition.damage_bonuses ?? {})
              .filter((entry): entry is [DamageType, number] => typeof entry[1] === 'number' && entry[1] > 0)
            const story = itemStory(item)
            const restoration = ancientRestorationInfo(definition)
            const luckyAffixUpgrade = item.metadata?.lucky_affix_upgrade === true

            return (
              <article
                className={
                  'item-card rarity-' + definition.rarity
                  + (lockedByLevel ? ' level-locked' : '')
                  + (equipped ? ' is-equipped' : '')
                }
                key={item.id}
              >
                <div className="item-card-top">
                  <div className="item-icon" aria-hidden="true">
                    {getItemGlyph(definition.category)}
                  </div>
                  <div className="item-title">
                    <span className="rarity-label">{rarityLabels[definition.rarity]}</span>
                    <h3>
                      {item.custom_name || definition.name}
                      {item.enhancement_level > 0 ? ` +${item.enhancement_level}` : ''}
                      {item.awakening_level > 0 ? ` · ◆${['0','I','II','III','IV','V'][item.awakening_level] ?? item.awakening_level}` : ''}
                    </h3>
                  </div>
                  {item.quantity > 1 && <span className="quantity">×{item.quantity}</span>}
                </div>

                <p>{definition.description}</p>

                {definition.damage_type && (
                  <div className="damage-type-chip">
                    Тип урона · {damageTypeLabels[definition.damage_type]}
                  </div>
                )}

                {definition.category === 'weapon' && (
                  <div className="modifier-list">
                    <span>Базовый урон +{definition.weapon_base_damage ?? 0}</span>
                    {item.enhancement_level > 0 && (
                      <span>
                        Заточка +{item.enhancement_level} · оружейная база ×
                        {(1 + item.enhancement_level * 0.03).toFixed(2)}
                      </span>
                    )}
                    <span>
                      {weaponScalingLabels[definition.weapon_scaling ?? 'strength']}
                      {' · '}
                      {definition.weapon_scaling === 'agility'
                        ? 'ЛОВ ×3 + СИЛ ×0,5'
                        : definition.weapon_scaling === 'hybrid'
                          ? 'СИЛ ×1,75 + ЛОВ ×1,75'
                          : 'СИЛ ×3 + ЛОВ ×0,5'}
                    </span>
                    {definition.weapon_family && (
                      <span>{weaponFamilyLabels[definition.weapon_family]}</span>
                    )}
                    {definition.weapon_family && weaponFamilyMechanicLabels[definition.weapon_family] && (
                      <span>{weaponFamilyMechanicLabels[definition.weapon_family]}</span>
                    )}
                    {definition.echo_strike_chance_percent > 0 && (
                      <span>Эхо ударов · {definition.echo_strike_chance_percent}%</span>
                    )}
                  </div>
                )}

                {resistances.length > 0 && (
                  <div className="resistance-list">
                    {resistances.map(([type, value]) => (
                      <span className={value >= 0 ? 'positive' : 'negative'} key={type}>
                        {damageTypeLabels[type]} {value >= 0 ? '+' : ''}{value}%
                      </span>
                    ))}
                  </div>
                )}

                {damageBonuses.length > 0 && (
                  <div className="damage-bonus-list">
                    {damageBonuses.map(([type, value]) => (
                      <span key={'damage-bonus-' + type}>
                        {damageTypeLabels[type]} урон +{value}%
                      </span>
                    ))}
                  </div>
                )}

                {modifiers.length > 0 && (
                  <div className="modifier-list">
                    {modifiers.map(([key, value]) => (
                      <span key={key}>
                        {key === 'exploration_speed_percent' ? 'Скорость исследования' : statLabels[key as StatKey] ?? key} {value >= 0 ? '+' : ''}{value}{key === 'exploration_speed_percent' ? '%' : ''}
                      </span>
                    ))}
                  </div>
                )}

                {affixModifiers.length > 0 && (
                  <div className="modifier-list affix-modifiers">
                    {affixModifiers.map(([key, value]) => (
                      <span key={'affix-' + key}>
                        {key === 'exploration_speed_percent' ? 'Скорость исследования' : statLabels[key as StatKey] ?? key} {value >= 0 ? '+' : ''}{value}{key === 'exploration_speed_percent' ? '%' : ''}
                      </span>
                    ))}
                  </div>
                )}

                {affixes.length > 0 && (
                  <div className="item-affix-list">
                    {affixes.map((affix, index) => (
                      <span
                        key={affix.name + '-' + index}
                        title={[affix.description, affixEffectText(affix)].filter(Boolean).join(' · ') || affix.name}
                      >
                        {affix.name}
                        {affixEffectText(affix) ? ' · ' + affixEffectText(affix) : ''}
                      </span>
                    ))}
                  </div>
                )}

                {luckyAffixUpgrade && (
                  <div className="unique-property">
                    <strong>Удачная находка</strong>
                    <span>
                      Удача дала этому предмету дополнительный аффикс сверх обычного лимита его редкости.
                    </span>
                  </div>
                )}

                {definition.unique_property_name && (
                  <div className="unique-property">
                    <strong>{definition.unique_property_name}</strong>
                    <span>{definition.unique_property_description}</span>
                  </div>
                )}

                {restoration && (
                  <div className="unique-property">
                    <strong>Можно восстановить</strong>
                    <span>
                      Требуется {restoration.fragmentCost} Осколка древней реликвии.
                      После восстановления предмет получает полные характеристики и древнее свойство.
                    </span>
                  </div>
                )}

                {story && (
                  <div className="item-story-card">
                    <span className="eyebrow">СЛЕД ПРОШЛОГО</span>
                    <strong>{story.title}</strong>
                    <p>{story.text}</p>
                  </div>
                )}

                <div className="item-actions">
                  {definition.equip_group ? (
                    <>
                      <span className={'item-state ' + (lockedByLevel ? 'level-warning' : 'muted')}>
                        {equipped
                          ? 'Надето · сними для действий с предметом'
                          : lockedByLevel
                            ? `Нужен ${definition.required_level} ур. · сейчас ${characterLevel}`
                            : restoration
                              ? `Можно надеть · восстановление за ${restoration.fragmentCost} оск.`
                              : itemExchangeValue(definition) > 0
                                ? `Можно надеть · обмен ${itemExchangeValue(definition)} золота`
                                : 'Можно надеть · обмен недоступен'}
                      </span>
                      <button
                        className={equipped || lockedByLevel ? 'ghost-button' : 'primary-button'}
                        type="button"
                        disabled={busy || equipped || lockedByLevel}
                        aria-disabled={busy || equipped || lockedByLevel}
                        title={lockedByLevel ? `Нужен ${definition.required_level} уровень` : undefined}
                        onClick={() => void onEquip(item)}
                      >
                        {equipped ? 'Надето' : lockedByLevel ? `Нужен ${definition.required_level} ур.` : 'Экипировать'}
                      </button>
                      <button
                        className="ghost-button item-history-button"
                        type="button"
                        disabled={busy}
                        onClick={() => void onHistory(item)}
                      >
                        История
                      </button>
                      {restoration && (
                        <button
                          className="primary-button"
                          type="button"
                          disabled={busy || equipped}
                          title={equipped ? 'Сначала сними предмет' : undefined}
                          onClick={() => void onRestoreAncient(item)}
                        >
                          {equipped
                            ? 'Сначала сними'
                            : `Восстановить · ${restoration.fragmentCost} оск.`}
                        </button>
                      )}
                      {!equipped
                        && ['weapon', 'armor', 'accessory'].includes(definition.category)
                        && itemExchangeValue(definition) > 0
                        && (
                        <button
                          className="ghost-button"
                          type="button"
                          disabled={busy}
                          onClick={() => void onExchangeItem(item, 1)}
                        >
                          Обменять · {itemExchangeValue(definition)}
                        </button>
                      )}
                    </>
                  ) : definition.scroll_mode === 'learn' ? (
                    <button
                      className="primary-button"
                      type="button"
                      disabled={busy}
                      onClick={() => void onLearnScroll(item)}
                    >
                      Изучить заклинание
                    </button>
                  ) : definition.scroll_mode === 'cast' ? (
                    <span className="muted item-state">
                      Боевой свиток · используется во время боя
                    </span>
                  ) : definition.category === 'material' ? (
                    definition.slug === 'ancient_relic_fragment_beta' ? (
                      <span className="muted item-state">
                        Ресурс восстановления древней экипировки · обмен недоступен
                      </span>
                    ) : definition.rarity === 'unique' ? (
                      <span className="muted item-state">Уникальный ресурс · обмен недоступен</span>
                    ) : definition.slug === 'tempering_mark_iii' ? (
                      <span className="muted item-state">Особый ресурс · обмен недоступен</span>
                    ) : (
                      <div className="resource-item-actions material-exchange-actions">
                        <span className="material-exchange-value">
                          Обмен · {materialExchangeValues[definition.rarity]} золота за 1
                        </span>
                        <button
                          className="ghost-button"
                          type="button"
                          disabled={busy}
                          onClick={() => void onExchangeItem(item, 1)}
                        >
                          Обменять 1
                        </button>
                        {item.quantity > 1 && (
                          <button
                            className="ghost-button"
                            type="button"
                            disabled={busy}
                            onClick={() => void onExchangeItem(item, item.quantity)}
                          >
                            Обменять всё · {materialExchangeValues[definition.rarity] * item.quantity}
                          </button>
                        )}
                      </div>
                    )
                  ) : resourceAmounts.heal > 0 || resourceAmounts.mana > 0 ? (
                    <div className="resource-item-actions">
                      <button
                        className="primary-button"
                        type="button"
                        disabled={busy}
                        onClick={() => void onUseResource(item)}
                      >
                        Использовать
                        {resourceAmounts.heal > 0 ? ' · +' + resourceAmounts.heal + ' ОЗ' : ''}
                        {resourceAmounts.mana > 0 ? ' · +' + resourceAmounts.mana + ' ОМ' : ''}
                      </button>
                      {resourceAmounts.heal > 0 && item.quantity > 1 && (
                        <button
                          className="ghost-button"
                          type="button"
                          disabled={busy}
                          onClick={() => void onUseResource(item, true)}
                        >
                          Восстановить до максимума
                        </button>
                      )}
                    </div>
                  ) : (
                    <span className="muted item-state">
                      {definition.category === 'consumable' ? 'Расходник' : 'Не экипируется'}
                    </span>
                  )}
                </div>
              </article>
            )
          })}
        </div>
      )}
    </section>
  )
}

function EquipmentPanel({
  equipment,
  equipmentSets,
  itemById,
  busy,
  message,
  onUnequip,
}: {
  equipment: CharacterEquipment[]
  equipmentSets: EquipmentSetState[]
  itemById: Map<string, CharacterItem>
  busy: boolean
  message: string
  onUnequip: (slot: EquipmentSlot) => Promise<void>
}) {
  const bySlot = new Map(equipment.map((entry) => [entry.slot, entry]))
  const activeEquipmentSets = equipmentSets.filter((set) => set.equipped_pieces > 0)

  return (
    <section className="panel">
      <div className="section-heading">
        <div>
          <span className="eyebrow">ЭКИПИРОВКА</span>
          <h2>Снаряжение</h2>
        </div>
      </div>

      {message && <p className="form-message" aria-live="polite">{message}</p>}

      {activeEquipmentSets.length > 0 && (
        <div className="equipment-set-list">
          {activeEquipmentSets.map((set) => (
            <article className="equipment-set-card" key={set.set_id}>
              <div className="equipment-set-heading">
                <div>
                  <span className="eyebrow">КОМПЛЕКТ</span>
                  <strong>{set.name}</strong>
                  <p>{set.description}</p>
                </div>
                <span className="badge">{set.equipped_pieces}/{set.total_pieces}</span>
              </div>

              <div className="equipment-set-pieces">
                {set.pieces.map((piece) => (
                  <span
                    className={piece.equipped ? 'equipped' : piece.owned ? 'owned' : ''}
                    key={piece.item_definition_id}
                  >
                    {piece.name} · ур. {piece.required_level}
                  </span>
                ))}
              </div>

              <div className="equipment-set-bonuses">
                {set.bonuses.map((bonus) => (
                  <div className={bonus.active ? 'active' : ''} key={bonus.required_pieces + ':' + bonus.effect_type}>
                    <strong>{bonus.required_pieces}/{set.total_pieces} · {bonus.name}</strong>
                    <span>{bonus.description}</span>
                  </div>
                ))}
              </div>

              {set.current_low_hp_bonus > 0 && (
                <div className="equipment-set-current-bonus">
                  Текущая Ярость Берсерка: <strong>+{set.current_low_hp_bonus}% прямого урона</strong>
                </div>
              )}
            </article>
          ))}
        </div>
      )}

      <div className="equipment-grid">
        {(Object.keys(equipmentLabels) as EquipmentSlot[]).map((slot) => {
          const entry = bySlot.get(slot)
          const item = entry ? itemById.get(entry.character_item_id) : null
          const definition = item ? normalizeDefinition(item.item_definitions) : null
          const story = item ? itemStory(item) : null

          return (
            <article className="equipment-slot" key={slot}>
              <span className="slot-label">{equipmentLabels[slot]}</span>

              {definition ? (
                <>
                  <strong>
                    {item?.custom_name || definition.name}
                    {(item?.enhancement_level ?? 0) > 0 ? ` +${item?.enhancement_level}` : ''}
                    {(item?.awakening_level ?? 0) > 0 ? ` · ◆${['0','I','II','III','IV','V'][item?.awakening_level ?? 0] ?? item?.awakening_level}` : ''}
                  </strong>
                  <span className={'rarity-label rarity-text-' + definition.rarity}>
                    {rarityLabels[definition.rarity]}
                  </span>
                  {definition.damage_type && (
                    <span className="equipment-damage-type">
                      {damageTypeLabels[definition.damage_type]}
                    </span>
                  )}
                  {definition.category === 'weapon' && (
                    <div className="modifier-list compact">
                      <span>Базовый урон +{definition.weapon_base_damage ?? 0}</span>
                      {(item?.enhancement_level ?? 0) > 0 && (
                        <span>
                          Заточка +{item?.enhancement_level} · оружейная база ×
                          {(1 + (item?.enhancement_level ?? 0) * 0.03).toFixed(2)}
                        </span>
                      )}
                      <span>{weaponScalingLabels[definition.weapon_scaling ?? 'strength']}</span>
                      {definition.weapon_family && <span>{weaponFamilyLabels[definition.weapon_family]}</span>}
                      {definition.weapon_family && weaponFamilyMechanicLabels[definition.weapon_family] && (
                        <span>{weaponFamilyMechanicLabels[definition.weapon_family]}</span>
                      )}
                      {definition.echo_strike_chance_percent > 0 && (
                        <span>Эхо ударов · {definition.echo_strike_chance_percent}%</span>
                      )}
                    </div>
                  )}
                  {item && Object.entries(combinedResistances(item, definition))
                    .filter((entry): entry is [DamageType, number] => typeof entry[1] === 'number' && entry[1] !== 0)
                    .length > 0 && (
                      <div className="resistance-list">
                        {Object.entries(combinedResistances(item, definition))
                          .filter((entry): entry is [DamageType, number] => typeof entry[1] === 'number' && entry[1] !== 0)
                          .map(([type, value]) => (
                            <span className={value >= 0 ? 'positive' : 'negative'} key={type}>
                              {damageTypeLabels[type]} {value >= 0 ? '+' : ''}{value}%
                            </span>
                          ))}
                      </div>
                    )}
                  {Object.entries(definition.damage_bonuses ?? {})
                    .filter((entry): entry is [DamageType, number] => typeof entry[1] === 'number' && entry[1] > 0)
                    .length > 0 && (
                      <div className="damage-bonus-list compact">
                        {Object.entries(definition.damage_bonuses ?? {})
                          .filter((entry): entry is [DamageType, number] => typeof entry[1] === 'number' && entry[1] > 0)
                          .map(([type, value]) => (
                            <span key={'equipped-damage-bonus-' + type}>
                              {damageTypeLabels[type]} урон +{value}%
                            </span>
                          ))}
                      </div>
                    )}
                  {item && itemAffixes(item).length > 0 && (
                    <div className="item-affix-list compact">
                      {itemAffixes(item).map((affix, index) => (
                        <span
                          key={affix.name + '-' + index}
                          title={[affix.description, affixEffectText(affix)].filter(Boolean).join(' · ') || affix.name}
                        >
                          {affix.name}
                          {affixEffectText(affix) ? ' · ' + affixEffectText(affix) : ''}
                        </span>
                      ))}
                    </div>
                  )}
                  {definition.unique_property_name && (
                    <div className="unique-property compact">
                      <strong>{definition.unique_property_name}</strong>
                      <span>{definition.unique_property_description}</span>
                    </div>
                  )}
                  {story && (
                    <div className="item-story-card compact">
                      <span className="eyebrow">СЛЕД ПРОШЛОГО</span>
                      <strong>{story.title}</strong>
                      <p>{story.text}</p>
                    </div>
                  )}
                  <button
                    className="ghost-button"
                    type="button"
                    disabled={busy}
                    onClick={() => void onUnequip(slot)}
                  >
                    Снять
                  </button>
                </>
              ) : (
                <span className="muted">Пусто</span>
              )}
            </article>
          )
        })}
      </div>
    </section>
  )
}

function Stat({
  label,
  value,
  base,
  hint,
}: {
  label: string
  value: number
  base: number
  hint?: string
}) {
  const bonus = value - base

  return (
    <div className="stat-tile">
      <span>{label}</span>
      <strong>{value}</strong>
      {bonus !== 0 && <small>База {base} · {bonus > 0 ? '+' : ''}{bonus} от вещей</small>}
      {hint && <small>{hint}</small>}
    </div>
  )
}

function CombatStat({
  label,
  value,
  hint,
}: {
  label: string
  value: number | string
  hint?: string
}) {
  return (
    <div className="combat-stat-tile">
      <span>{label}</span>
      <strong>{value}</strong>
      {hint && <small>{hint}</small>}
    </div>
  )
}

function NavButton({
  active,
  onClick,
  icon,
  children,
}: {
  active: boolean
  onClick: () => void
  icon: NavIconName
  children: string
}) {
  return (
    <button
      type="button"
      className={active ? 'active' : ''}
      aria-current={active ? 'page' : undefined}
      onClick={onClick}
    >
      <NavIcon name={icon} />
      <span className="bottom-nav-label">{children}</span>
    </button>
  )
}

function NavIcon({ name }: { name: NavIconName }) {
  if (name === 'world') {
    return (
      <svg className="bottom-nav-icon" viewBox="0 0 24 24" aria-hidden="true">
        <circle cx="12" cy="12" r="8" />
        <path d="M15.7 8.3 13.5 13.5 8.3 15.7l2.2-5.2 5.2-2.2Z" />
      </svg>
    )
  }

  if (name === 'character') {
    return (
      <svg className="bottom-nav-icon" viewBox="0 0 24 24" aria-hidden="true">
        <circle cx="12" cy="8.5" r="3.2" />
        <path d="M5.8 19c.7-3.4 3-5.1 6.2-5.1s5.5 1.7 6.2 5.1" />
      </svg>
    )
  }

  if (name === 'adventures') {
    return (
      <svg className="bottom-nav-icon" viewBox="0 0 24 24" aria-hidden="true">
        <path d="m12 3 1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8L12 3Z" />
        <path d="m18.5 15 .7 2 .3.8.8.3 2 .7-2 .7-.8.3-.3.8-.7 2-.7-2-.3-.8-.8-.3-2-.7 2-.7.8-.3.3-.8.7-2Z" />
      </svg>
    )
  }

  if (name === 'battles') {
    return (
      <svg className="bottom-nav-icon" viewBox="0 0 24 24" aria-hidden="true">
        <path d="m7 4 10 16M17 4 7 20" />
        <path d="m5.5 3 3 1.5-2 2L5.5 3Zm13 0-3 1.5 2 2L18.5 3Z" />
      </svg>
    )
  }

  return (
    <svg className="bottom-nav-icon" viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="6" cy="12" r="1.4" />
      <circle cx="12" cy="12" r="1.4" />
      <circle cx="18" cy="12" r="1.4" />
    </svg>
  )
}

function getResourceAmounts(definition: ItemDefinition) {
  let heal = 0
  let mana = 0

  for (const effect of definition.effects ?? []) {
    if (!effect || typeof effect !== 'object' || !('type' in effect) || !('amount' in effect)) continue
    const type = String((effect as { type?: unknown }).type ?? '')
    const amount = Number((effect as { amount?: unknown }).amount)
    if (!Number.isFinite(amount) || amount <= 0) continue
    if (type === 'heal_hp') heal += amount
    if (type === 'restore_mana') mana += amount
  }

  return { heal, mana }
}

function getItemGlyph(category: ItemDefinition['category']) {
  switch (category) {
    case 'weapon':
      return '⚔'
    case 'armor':
      return '◈'
    case 'accessory':
      return '◇'
    case 'consumable':
      return '✦'
    case 'material':
      return '◆'
    case 'quest':
      return '☷'
    default:
      return '•'
  }
}
