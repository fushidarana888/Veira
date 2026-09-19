import { useEffect, useMemo, useState } from 'react'
import { addStatModifiers, calculateDerivedCombatStats, experienceForNextLevel, type StatKey } from '@veira/game-core'
import { supabase } from '../lib/supabase'
import { AdventuresPanel } from './AdventuresPanel'
import { CraftingPanel } from './CraftingPanel'
import { DuelPanel } from './DuelPanel'
import { MagicPanel } from './MagicPanel'
import { WorldMap } from './WorldMap'
import type {
  Character,
  CharacterEquipment,
  CharacterItem,
  CharacterProgress,
  EquipmentSlot,
  DamageType,
  ItemDefinition,
  Profile,
  RaceDefinition,
} from '../types'

type Props = {
  profile: Profile
  character: Character
  userEmail: string
  onSignOut: () => Promise<void> | void
}

type Tab = 'world' | 'character' | 'adventures' | 'community' | 'more'
type CharacterTab = 'overview' | 'inventory' | 'equipment' | 'magic' | 'crafting'

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

const affixEffectLabels: Record<string, { label: string; percent: boolean }> = {
  lifesteal: { label: 'Вампиризм', percent: true },
  mana_on_hit: { label: 'Мана за удар', percent: false },
  damage_vs_wounded: { label: 'Урон по раненым', percent: true },
  guard_boost: { label: 'Усиление блока', percent: true },
  physical_damage_bonus: { label: 'Физический урон', percent: true },
  magic_damage_bonus: { label: 'Магический урон', percent: true },
  all_damage_bonus: { label: 'Весь прямой урон', percent: true },
  low_hp_damage_reduction: { label: 'Защита при низком HP', percent: true },
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

function combinedResistances(item: CharacterItem, definition: ItemDefinition) {
  const result: Partial<Record<DamageType, number>> = { ...(definition.damage_resistances ?? {}) }
  const extra = item.metadata?.affix_damage_resistances

  if (extra && typeof extra === 'object' && !Array.isArray(extra)) {
    for (const [key, raw] of Object.entries(extra)) {
      if (typeof raw !== 'number') continue
      const type = key as DamageType
      result[type] = Math.max(-75, Math.min(75, (result[type] ?? 0) + raw))
    }
  }

  return result
}

export function PlayerHome({ profile, character, userEmail, onSignOut }: Props) {
  const [tab, setTab] = useState<Tab>('character')
  const [characterTab, setCharacterTab] = useState<CharacterTab>('overview')
  const [items, setItems] = useState<CharacterItem[]>([])
  const [equipment, setEquipment] = useState<CharacterEquipment[]>([])
  const [inventoryBusy, setInventoryBusy] = useState(false)
  const [raceDefinition, setRaceDefinition] = useState<RaceDefinition | null>(null)
  const [inventoryMessage, setInventoryMessage] = useState('')
  const [statBusy, setStatBusy] = useState(false)
  const [progressMessage, setProgressMessage] = useState('')
  const [securityBusy, setSecurityBusy] = useState(false)
  const [securityMessage, setSecurityMessage] = useState('')
  const [progress, setProgress] = useState<CharacterProgress | null>(
    () => normalizeProgress(character.character_progress),
  )

  useEffect(() => {
    setProgress(normalizeProgress(character.character_progress))
  }, [character.character_progress])

  async function loadRace() {
    const { data, error } = await supabase.rpc('get_character_race_state', {
      p_character_id: character.id,
    })

    if (error) {
      setProgressMessage(error.message)
      return null
    }

    const race = (Array.isArray(data) ? data[0] : data) as RaceDefinition | null
    setRaceDefinition(race)
    return race
  }

  async function loadProgress() {
    const { data, error } = await supabase.rpc('get_character_progress_state', {
      p_character_id: character.id,
    })

    if (error) {
      setProgressMessage(error.message)
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
              shop_enabled,
              damage_type,
              damage_resistances,
              scroll_spell_id,
              scroll_mode,
              unique_property_name,
              unique_property_description,
              unique_effect_type,
              unique_effect_value
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
    void loadProgress()
    void loadInventory()
    void loadRace()
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
      .filter((item): item is CharacterItem => Boolean(item))
      .flatMap((item) => {
        const definition = normalizeDefinition(item.item_definitions)
        if (!definition) return []
        return [
          definition.stat_modifiers ?? {},
          affixStatModifiers(item),
        ]
      })

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

  async function useResourceItem(item: CharacterItem) {
    const definition = normalizeDefinition(item.item_definitions)
    if (!definition) return

    setInventoryBusy(true)
    setInventoryMessage('')

    const { data, error } = await supabase.rpc('use_resource_consumable', {
      p_character_item_id: item.id,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('ALREADY_FULL_RESOURCES')) {
        setInventoryMessage('HP и мана уже полные.')
      } else if (raw.includes('COMBAT_ACTIVE')) {
        setInventoryMessage('Во время боя используй расходник прямо в интерфейсе боя.')
      } else if (raw.includes('ITEM_IS_NOT_RESOURCE_CONSUMABLE')) {
        setInventoryMessage('Этот предмет не восстанавливает HP или ману.')
      } else {
        setInventoryMessage(raw)
      }
      setInventoryBusy(false)
      return
    }

    const row = Array.isArray(data) ? data[0] : data
    const healed = Number(row?.healed ?? 0)
    const manaRestored = Number(row?.mana_restored ?? 0)
    await Promise.all([loadInventory(), loadProgress()])

    const restored = [
      healed > 0 ? `+${healed} HP` : '',
      manaRestored > 0 ? `+${manaRestored} маны` : '',
    ].filter(Boolean).join(' · ')

    setInventoryMessage(restored ? `Восстановлено: ${restored}.` : 'Расходник использован.')
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
        setInventoryMessage(raw)
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
      setInventoryMessage(error.message)
      setInventoryBusy(false)
      return
    }

    await loadInventory()
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
      setSecurityMessage(error.message)
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
                    <strong>{progress.hp_current} / {progress.hp_max}</strong>
                  </div>
                  <div className="meter"><span style={{ width: hpPercent + '%' }} /></div>
                  <small className="passive-regen-note">
                    Пассивное восстановление: +{raceDefinition?.hp_regen_per_hour ?? 8} HP в час вне активного боя
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
                    Пассивное восстановление: +{raceDefinition?.mana_regen_per_hour ?? 10} маны в час вне активного боя
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
                    <span><small>Макс. HP</small><strong>{raceDefinition.hp_bonus >= 0 ? '+' : ''}{raceDefinition.hp_bonus}</strong></span>
                    <span><small>Макс. MP</small><strong>{raceDefinition.mana_bonus >= 0 ? '+' : ''}{raceDefinition.mana_bonus}</strong></span>
                    <span><small>Реген HP/ч</small><strong>{raceDefinition.hp_regen_per_hour}</strong></span>
                    <span><small>Реген MP/ч</small><strong>{raceDefinition.mana_regen_per_hour}</strong></span>
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

                  {raceDefinition.passive_name && (
                    <div className="race-passive-card">
                      <strong>{raceDefinition.passive_name}</strong>
                      <p>{raceDefinition.passive_description}</p>
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
                  <CombatStat label="Физ. защита" value={derivedCombatStats.physicalDefense} />
                  <CombatStat label="Маг. защита" value={derivedCombatStats.magicDefense} />
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
              onUseResource={useResourceItem}
              onLearnScroll={learnSpellFromScroll}
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

          {characterTab === 'magic' && (
            <MagicPanel
              characterId={character.id}
              progress={progress}
            />
          )}

          {characterTab === 'crafting' && (
            <CraftingPanel
              characterId={character.id}
              progress={progress}
              onProgressChanged={loadProgress}
              onInventoryChanged={loadInventory}
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
          onInventoryChanged={loadInventory}
        />
      )}
      {tab === 'community' && <DuelPanel characterId={character.id} />}
      {tab === 'more' && (
        <div className="more-section">
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

          <Placeholder title="Ещё" text="Здесь позже появятся достижения, журнал и остальные настройки Veira." />
        </div>
      )}

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
  onUseResource,
  onLearnScroll,
}: {
  items: CharacterItem[]
  equippedItemIds: Set<string>
  busy: boolean
  message: string
  onEquip: (item: CharacterItem) => Promise<void>
  onUseResource: (item: CharacterItem) => Promise<void>
  onLearnScroll: (item: CharacterItem) => Promise<void>
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
            const resourceAmounts = getResourceAmounts(definition)
            const affixes = itemAffixes(item)
            const affixModifiers = Object.entries(affixStatModifiers(item))
              .filter((entry): entry is [string, number] => typeof entry[1] === 'number')
            const resistances = Object.entries(combinedResistances(item, definition))
              .filter((entry): entry is [DamageType, number] => typeof entry[1] === 'number' && entry[1] !== 0)

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

                {definition.damage_type && (
                  <div className="damage-type-chip">
                    Тип урона · {damageTypeLabels[definition.damage_type]}
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

                {modifiers.length > 0 && (
                  <div className="modifier-list">
                    {modifiers.map(([key, value]) => (
                      <span key={key}>
                        {statLabels[key as StatKey] ?? key} {value >= 0 ? '+' : ''}{value}
                      </span>
                    ))}
                  </div>
                )}

                {affixModifiers.length > 0 && (
                  <div className="modifier-list affix-modifiers">
                    {affixModifiers.map(([key, value]) => (
                      <span key={'affix-' + key}>
                        {statLabels[key as StatKey] ?? key} {value >= 0 ? '+' : ''}{value}
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

                {definition.unique_property_name && (
                  <div className="unique-property">
                    <strong>{definition.unique_property_name}</strong>
                    <span>{definition.unique_property_description}</span>
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
                  ) : resourceAmounts.heal > 0 || resourceAmounts.mana > 0 ? (
                    <button
                      className="primary-button"
                      type="button"
                      disabled={busy}
                      onClick={() => void onUseResource(item)}
                    >
                      Использовать
                      {resourceAmounts.heal > 0 ? ' · +' + resourceAmounts.heal + ' HP' : ''}
                      {resourceAmounts.mana > 0 ? ' · +' + resourceAmounts.mana + ' MP' : ''}
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
                  {definition.damage_type && (
                    <span className="equipment-damage-type">
                      {damageTypeLabels[definition.damage_type]}
                    </span>
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
