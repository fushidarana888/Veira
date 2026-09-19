import { useEffect, useMemo, useState } from 'react'
import { addStatModifiers, calculateDerivedCombatStats, experienceForNextLevel, type StatKey } from '@veira/game-core'
import { supabase } from '../lib/supabase'
import { AdventuresPanel } from './AdventuresPanel'
import { WorldMap } from './WorldMap'
import type {
  Character,
  CharacterEquipment,
  CharacterItem,
  CharacterProgress,
  EquipmentSlot,
  ItemDefinition,
  Profile,
} from '../types'

type Props = {
  profile: Profile
  character: Character
  onSignOut: () => Promise<void> | void
}

type Tab = 'world' | 'character' | 'adventures' | 'community' | 'more'
type CharacterTab = 'overview' | 'inventory' | 'equipment'

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

const statLabels: Record<StatKey, string> = {
  strength: 'Сила',
  agility: 'Ловкость',
  intellect: 'Интеллект',
  vitality: 'Живучесть',
  luck: 'Удача',
}

function normalizeProgress(value: Character['character_progress']): CharacterProgress | null {
  if (Array.isArray(value)) return value[0] ?? null
  return value
}

function normalizeDefinition(value: CharacterItem['item_definitions']): ItemDefinition | null {
  if (Array.isArray(value)) return value[0] ?? null
  return value
}

export function PlayerHome({ profile, character, onSignOut }: Props) {
  const [tab, setTab] = useState<Tab>('character')
  const [characterTab, setCharacterTab] = useState<CharacterTab>('overview')
  const [items, setItems] = useState<CharacterItem[]>([])
  const [equipment, setEquipment] = useState<CharacterEquipment[]>([])
  const [inventoryBusy, setInventoryBusy] = useState(false)
  const [inventoryMessage, setInventoryMessage] = useState('')
  const [statBusy, setStatBusy] = useState(false)
  const [progressMessage, setProgressMessage] = useState('')
  const [progress, setProgress] = useState<CharacterProgress | null>(
    () => normalizeProgress(character.character_progress),
  )

  useEffect(() => {
    setProgress(normalizeProgress(character.character_progress))
  }, [character.character_progress])

  async function loadProgress() {
    const { data, error } = await supabase
      .from('character_progress')
      .select('character_id, level, experience, hp_current, hp_max, strength, agility, intellect, vitality, luck, gold, unspent_stat_points, updated_at')
      .eq('character_id', character.id)
      .single()

    if (error) {
      setProgressMessage(error.message)
      return null
    }

    const nextProgress = data as CharacterProgress
    setProgress(nextProgress)
    return nextProgress
  }

  async function loadInventory() {
    setInventoryBusy(true)
    setInventoryMessage('')

    const [{ data: itemData, error: itemError }, { data: equipmentData, error: equipmentError }] =
      await Promise.all([
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
              shop_enabled
            )
          `)
          .eq('character_id', character.id)
          .order('acquired_at', { ascending: true }),
        supabase
          .from('character_equipment')
          .select('character_id, slot, character_item_id, equipped_at')
          .eq('character_id', character.id),
      ])

    if (itemError || equipmentError) {
      setInventoryMessage(itemError?.message ?? equipmentError?.message ?? 'Не удалось загрузить инвентарь.')
      setInventoryBusy(false)
      return
    }

    setItems((itemData as CharacterItem[] | null) ?? [])
    setEquipment((equipmentData as CharacterEquipment[] | null) ?? [])
    setInventoryBusy(false)
  }

  useEffect(() => {
    void loadInventory()
  }, [character.id])

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

    const modifiers = equipment
      .map((entry) => itemById.get(entry.character_item_id))
      .map((item) => item ? normalizeDefinition(item.item_definitions) : null)
      .filter((definition): definition is ItemDefinition => Boolean(definition))
      .map((definition) => definition.stat_modifiers ?? {})

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
  }, [equipment, itemById, progress])

  const derivedCombatStats = useMemo(
    () => progress && effectiveStats
      ? calculateDerivedCombatStats(progress.level, effectiveStats)
      : null,
    [effectiveStats, progress],
  )

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
  const hpPercent = Math.min(100, Math.round((progress.hp_current / progress.hp_max) * 100))

  async function equipItem(item: CharacterItem) {
    const definition = normalizeDefinition(item.item_definitions)
    if (!definition?.equip_group) return

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
        setInventoryMessage(error.message)
      }
      setInventoryBusy(false)
      return
    }

    await loadInventory()
  }

  async function useHealingItem(item: CharacterItem) {
    const definition = normalizeDefinition(item.item_definitions)
    if (!definition) return

    setInventoryBusy(true)
    setInventoryMessage('')

    const { data, error } = await supabase.rpc('use_healing_consumable', {
      p_character_item_id: item.id,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('ALREADY_FULL_HEALTH')) {
        setInventoryMessage('Здоровье уже полное.')
      } else if (raw.includes('COMBAT_ACTIVE')) {
        setInventoryMessage('Во время активного боя использовать зелье из инвентаря нельзя.')
      } else {
        setInventoryMessage(raw)
      }
      setInventoryBusy(false)
      return
    }

    const healed = Array.isArray(data) ? Number(data[0]?.healed ?? 0) : 0
    await Promise.all([loadInventory(), loadProgress()])
    setInventoryMessage(healed > 0 ? `Восстановлено ${healed} HP.` : 'Зелье использовано.')
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
      setInventoryMessage(error.message)
      setInventoryBusy(false)
      return
    }

    await loadInventory()
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
      setProgressMessage(error.message)
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
          <div className="avatar-placeholder" aria-hidden="true">
            {character.name.slice(0, 1).toUpperCase()}
          </div>
          <div>
            <span className="eyebrow">{character.race}</span>
            <h1>{character.name}</h1>
            <p className="muted">@{profile.display_name}</p>
          </div>
        </div>

        <div className="top-actions">
          <span className="badge">LVL {progress.level}</span>
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
          </div>

          {characterTab === 'overview' && (
            <>
              <section className="dashboard-grid">
                <article className="panel vital-card">
                  <div className="card-heading">
                    <span>Здоровье</span>
                    <strong>{progress.hp_current} / {progress.hp_max}</strong>
                  </div>
                  <div className="meter"><span style={{ width: hpPercent + '%' }} /></div>
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
                  <span className="muted stat-note">Первая версия формул</span>
                </div>

                <div className="combat-stats-grid">
                  <CombatStat label="Физ. мощь" value={derivedCombatStats.physicalPower} />
                  <CombatStat label="Маг. мощь" value={derivedCombatStats.magicPower} />
                  <CombatStat label="Защита" value={derivedCombatStats.defense} />
                  <CombatStat label="Инициатива" value={derivedCombatStats.initiative} />
                </div>
              </section>

              <section className="panel">
                <span className="eyebrow">БИОГРАФИЯ</span>
                <p className="bio-text">{character.bio || 'Биография пока не заполнена.'}</p>
              </section>
            </>
          )}

          {characterTab === 'inventory' && (
            <InventoryPanel
              items={items}
              equippedItemIds={equippedItemIds}
              busy={inventoryBusy}
              message={inventoryMessage}
              onEquip={equipItem}
              onUseHealing={useHealingItem}
            />
          )}

          {characterTab === 'equipment' && (
            <EquipmentPanel
              equipment={equipment}
              itemById={itemById}
              busy={inventoryBusy}
              message={inventoryMessage}
              onUnequip={unequip}
            />
          )}
        </>
      )}

      {tab === 'world' && (
        <WorldMap
          characterId={character.id}
          onProgressChanged={loadProgress}
          onInventoryChanged={loadInventory}
        />
      )}
      {tab === 'adventures' && (
        <AdventuresPanel
          characterId={character.id}
          onProgressChanged={loadProgress}
        />
      )}
      {tab === 'community' && <Placeholder title="Сообщество" text="Здесь появятся гильдии, игроки и социальные механики." />}
      {tab === 'more' && <Placeholder title="Ещё" text="Настройки, достижения, журнал и другие разделы Veira." />}

      <nav className="bottom-nav" aria-label="Основная навигация">
        <NavButton active={tab === 'world'} onClick={() => setTab('world')}>Мир</NavButton>
        <NavButton active={tab === 'character'} onClick={() => setTab('character')}>Персонаж</NavButton>
        <NavButton active={tab === 'adventures'} onClick={() => setTab('adventures')}>Приключения</NavButton>
        <NavButton active={tab === 'community'} onClick={() => setTab('community')}>Сообщество</NavButton>
        <NavButton active={tab === 'more'} onClick={() => setTab('more')}>Ещё</NavButton>
      </nav>
    </main>
  )
}

function InventoryPanel({
  items,
  equippedItemIds,
  busy,
  message,
  onEquip,
  onUseHealing,
}: {
  items: CharacterItem[]
  equippedItemIds: Set<string>
  busy: boolean
  message: string
  onEquip: (item: CharacterItem) => Promise<void>
  onUseHealing: (item: CharacterItem) => Promise<void>
}) {
  return (
    <section className="panel">
      <div className="section-heading">
        <div>
          <span className="eyebrow">ИНВЕНТАРЬ</span>
          <h2>Предметы персонажа</h2>
        </div>
        <span className="badge">{items.length} ячеек</span>
      </div>

      {message && <p className="form-message" aria-live="polite">{message}</p>}

      {items.length === 0 ? (
        <p className="muted">Инвентарь пуст.</p>
      ) : (
        <div className="inventory-grid">
          {items.map((item) => {
            const definition = normalizeDefinition(item.item_definitions)
            if (!definition) return null

            const equipped = equippedItemIds.has(item.id)
            const modifiers = Object.entries(definition.stat_modifiers ?? {})
              .filter((entry): entry is [string, number] => typeof entry[1] === 'number')
            const healingAmount = getHealingAmount(definition)

            return (
              <article className={'item-card rarity-' + definition.rarity} key={item.id}>
                <div className="item-card-top">
                  <div className="item-icon" aria-hidden="true">
                    {getItemGlyph(definition.category)}
                  </div>
                  <div className="item-title">
                    <span className="rarity-label">{rarityLabels[definition.rarity]}</span>
                    <h3>{item.custom_name || definition.name}</h3>
                  </div>
                  {item.quantity > 1 && <span className="quantity">×{item.quantity}</span>}
                </div>

                <p>{definition.description}</p>

                {modifiers.length > 0 && (
                  <div className="modifier-list">
                    {modifiers.map(([key, value]) => (
                      <span key={key}>
                        {statLabels[key as StatKey] ?? key} {value >= 0 ? '+' : ''}{value}
                      </span>
                    ))}
                  </div>
                )}

                <div className="item-actions">
                  {definition.equip_group ? (
                    <>
                      <span className="muted item-state">Требуется ур. {definition.required_level}</span>
                      <button
                        className={equipped ? 'ghost-button' : 'primary-button'}
                        type="button"
                        disabled={busy || equipped}
                        onClick={() => void onEquip(item)}
                      >
                        {equipped ? 'Надето' : 'Экипировать'}
                      </button>
                    </>
                  ) : healingAmount > 0 ? (
                    <button
                      className="primary-button"
                      type="button"
                      disabled={busy}
                      onClick={() => void onUseHealing(item)}
                    >
                      Использовать · +{healingAmount} HP
                    </button>
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
  itemById,
  busy,
  message,
  onUnequip,
}: {
  equipment: CharacterEquipment[]
  itemById: Map<string, CharacterItem>
  busy: boolean
  message: string
  onUnequip: (slot: EquipmentSlot) => Promise<void>
}) {
  const bySlot = new Map(equipment.map((entry) => [entry.slot, entry]))

  return (
    <section className="panel">
      <div className="section-heading">
        <div>
          <span className="eyebrow">ЭКИПИРОВКА</span>
          <h2>Снаряжение</h2>
        </div>
      </div>

      {message && <p className="form-message" aria-live="polite">{message}</p>}

      <div className="equipment-grid">
        {(Object.keys(equipmentLabels) as EquipmentSlot[]).map((slot) => {
          const entry = bySlot.get(slot)
          const item = entry ? itemById.get(entry.character_item_id) : null
          const definition = item ? normalizeDefinition(item.item_definitions) : null

          return (
            <article className="equipment-slot" key={slot}>
              <span className="slot-label">{equipmentLabels[slot]}</span>

              {definition ? (
                <>
                  <strong>{item?.custom_name || definition.name}</strong>
                  <span className={'rarity-label rarity-text-' + definition.rarity}>
                    {rarityLabels[definition.rarity]}
                  </span>
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

function Stat({ label, value, base }: { label: string; value: number; base: number }) {
  const bonus = value - base

  return (
    <div className="stat-tile">
      <span>{label}</span>
      <strong>{value}</strong>
      {bonus !== 0 && <small>База {base} · {bonus > 0 ? '+' : ''}{bonus} от вещей</small>}
    </div>
  )
}

function CombatStat({ label, value }: { label: string; value: number }) {
  return (
    <div className="combat-stat-tile">
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  )
}

function Placeholder({ title, text }: { title: string; text: string }) {
  return (
    <section className="panel placeholder-panel">
      <span className="eyebrow">СКОРО</span>
      <h2>{title}</h2>
      <p className="muted">{text}</p>
    </section>
  )
}

function NavButton({
  active,
  onClick,
  children,
}: {
  active: boolean
  onClick: () => void
  children: string
}) {
  return (
    <button type="button" className={active ? 'active' : ''} onClick={onClick}>
      {children}
    </button>
  )
}

function getHealingAmount(definition: ItemDefinition) {
  for (const effect of definition.effects ?? []) {
    if (
      effect &&
      typeof effect === 'object' &&
      'type' in effect &&
      'amount' in effect &&
      (effect as { type?: unknown }).type === 'heal_hp'
    ) {
      const amount = Number((effect as { amount?: unknown }).amount)
      if (Number.isFinite(amount) && amount > 0) return amount
    }
  }

  return 0
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
