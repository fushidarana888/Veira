import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import type {
  BlacksmithAffix,
  BlacksmithDuplicate,
  BlacksmithWeapon,
  ItemRarity,
  WeaponFamily,
} from '../types'

type Props = {
  characterId: string
  sectorId: number
  settlementName: string
  settlementLevel: number
  onProgressChanged?: () => Promise<unknown> | void
  onInventoryChanged?: () => Promise<unknown> | void
}

type ForgeTab = 'enhance' | 'awaken' | 'affixes'

const rarityLabels: Record<ItemRarity, string> = {
  common: 'Обычный',
  uncommon: 'Необычный',
  rare: 'Редкий',
  epic: 'Эпический',
  legendary: 'Легендарный',
  unique: 'Уникальный',
}

const familyLabels: Partial<Record<WeaponFamily, string>> = {
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

const statLabels: Record<string, string> = {
  strength: 'STR',
  agility: 'AGI',
  intellect: 'INT',
  vitality: 'VIT',
  luck: 'LUCK',
}

const effectLabels: Record<string, string> = {
  lifesteal: 'Вампиризм',
  mana_on_hit: 'Мана за удар',
  damage_vs_wounded: 'Урон по раненым',
  guard_boost: 'Усиление блока',
  physical_damage_bonus: 'Физический урон',
  magic_damage_bonus: 'Магический урон',
  all_damage_bonus: 'Прямой урон',
  low_hp_damage_reduction: 'Защита при низком HP',
  boss_damage_bonus: 'Урон боссам',
}

function roman(value: number) {
  return ['0', 'I', 'II', 'III', 'IV', 'V'][Math.max(0, Math.min(5, value))] ?? String(value)
}

function blacksmithError(raw: string) {
  if (raw.includes('NOT_ENOUGH_GOLD')) return 'Недостаточно золота.'
  if (raw.includes('BLACKSMITH_LEVEL_TOO_LOW')) return 'Уровень этого кузнеца недостаточен.'
  if (raw.includes('CHARACTER_BUSY')) return 'Сейчас персонаж занят боем, подземельем или исследованием.'
  if (raw.includes('AFFIX_SERVICE_LOCKED')) return 'Наложение аффиксов открывается у кузнеца поселения 2 уровня.'
  if (raw.includes('AFFIX_REROLL_LOCKED')) return 'Перековка аффиксов открывается у кузнеца поселения 3 уровня.'
  if (raw.includes('AWAKENING_SERVICE_LOCKED')) return 'Пробуждение открывается у кузнеца поселения 3 уровня.'
  if (raw.includes('AFFIX_SLOTS_FULL')) return 'Все слоты аффиксов уже заняты.'
  if (raw.includes('ITEM_HAS_NO_AFFIX_SLOTS')) return 'У этого оружия нет слотов под аффиксы.'
  if (raw.includes('NO_ELIGIBLE_AFFIX')) return 'Для этого оружия сейчас нет подходящего аффикса.'
  if (raw.includes('NO_ALTERNATIVE_AFFIX')) return 'Не найден другой подходящий аффикс для перековки.'
  if (raw.includes('SOURCE_ITEM_EQUIPPED')) return 'Нельзя поглотить экипированную копию оружия.'
  if (raw.includes('ITEMS_NOT_IDENTICAL')) return 'Для пробуждения нужна точно такая же модель оружия.'
  if (raw.includes('MAX_AWAKENING_REACHED')) return 'Оружие уже пробуждено до V ступени.'
  if (raw.includes('MAX_ENHANCEMENT_REACHED')) return 'Оружие уже заточено до +20.'
  if (raw.includes('TEMPERING_MARK_NOT_AVAILABLE')) return 'Клеймо закалки III не найдено в инвентаре.'
  if (raw.includes('MARK_NOT_NEEDED')) return 'Клеймо можно применить только к оружию ниже +3.'
  return raw
}

function affixSummary(affix: BlacksmithAffix) {
  const parts: string[] = []

  for (const [key, value] of Object.entries(affix.stat_modifiers ?? {})) {
    if (typeof value === 'number' && value !== 0) {
      parts.push(`${statLabels[key] ?? key} ${value > 0 ? '+' : ''}${value}`)
    }
  }

  for (const [key, value] of Object.entries(affix.damage_resistances ?? {})) {
    if (typeof value === 'number' && value !== 0) {
      parts.push(`${key} resist ${value > 0 ? '+' : ''}${value}%`)
    }
  }

  if (affix.unique_effect_type && affix.unique_effect_value) {
    const unit = affix.unique_effect_type === 'mana_on_hit' ? '' : '%'
    parts.push(`${effectLabels[affix.unique_effect_type] ?? affix.unique_effect_type} +${affix.unique_effect_value}${unit}`)
  }

  return parts.join(' · ') || affix.description
}

function duplicateLabel(source: BlacksmithDuplicate) {
  const parts = ['Копия']
  if (source.enhancement_level > 0) parts.push(`+${source.enhancement_level}`)
  if (source.awakening_level > 0) parts.push(`Пробуждение ${roman(source.awakening_level)}`)
  if (source.affix_count > 0) parts.push(`аффиксов: ${source.affix_count}`)
  if (source.custom_name) parts.push(`«${source.custom_name}»`)
  return parts.join(' · ')
}

export function BlacksmithPanel({
  characterId,
  sectorId,
  settlementName,
  settlementLevel,
  onProgressChanged,
  onInventoryChanged,
}: Props) {
  const [weapons, setWeapons] = useState<BlacksmithWeapon[]>([])
  const [tab, setTab] = useState<ForgeTab>('enhance')
  const [loading, setLoading] = useState(true)
  const [busyKey, setBusyKey] = useState<string | null>(null)
  const [message, setMessage] = useState('')
  const [temperingMarks, setTemperingMarks] = useState(0)
  const [awakeningSources, setAwakeningSources] = useState<Record<string, string>>({})

  async function loadWeapons(silent = false) {
    if (!silent) setLoading(true)

    const [weaponResult, markResult] = await Promise.all([
      supabase.rpc('get_settlement_blacksmith_v2', {
        p_character_id: characterId,
        p_sector_id: sectorId,
      }),
      supabase.rpc('get_tempering_mark_iii_count', {
        p_character_id: characterId,
      }),
    ])

    if (weaponResult.error) {
      setMessage(blacksmithError(weaponResult.error.message))
      setWeapons([])
      if (!silent) setLoading(false)
      return
    }

    setWeapons((weaponResult.data as BlacksmithWeapon[] | null) ?? [])
    if (!markResult.error) {
      setTemperingMarks(Number(markResult.data ?? 0))
    }
    if (!silent) setLoading(false)
  }

  useEffect(() => {
    setTab('enhance')
    setMessage('')
    setAwakeningSources({})
    void loadWeapons()
  }, [characterId, sectorId])

  const rules = useMemo(() => ({
    maxEnhancement: weapons[0]?.max_enhancement ?? 0,
    affixApply: weapons[0]?.affix_apply_unlocked ?? settlementLevel >= 2,
    affixReroll: weapons[0]?.affix_reroll_unlocked ?? settlementLevel >= 3,
    awakening: weapons[0]?.awakening_unlocked ?? settlementLevel >= 3,
  }), [weapons, settlementLevel])

  async function refreshAfterMutation(copy: string) {
    await Promise.all([
      Promise.resolve(onProgressChanged?.()),
      Promise.resolve(onInventoryChanged?.()),
    ])
    await loadWeapons(true)
    setMessage(copy)
    setBusyKey(null)
  }

  async function enhanceTo(weapon: BlacksmithWeapon, targetLevel: number) {
    const key = `enhance:${weapon.character_item_id}`
    setBusyKey(key)
    setMessage('')

    let quotedCost = Number(weapon.next_cost ?? 0)

    if (targetLevel > weapon.enhancement_level + 1) {
      const quote = await supabase.rpc('quote_weapon_enhancement_at_blacksmith', {
        p_character_id: characterId,
        p_sector_id: sectorId,
        p_character_item_id: weapon.character_item_id,
        p_target_level: targetLevel,
      })

      if (quote.error) {
        setMessage(blacksmithError(quote.error.message))
        setBusyKey(null)
        return
      }

      const row = Array.isArray(quote.data) ? quote.data[0] : null
      quotedCost = Number(row?.total_cost ?? 0)

      if (!row?.can_afford) {
        setMessage(`Для заточки до +${targetLevel} нужно ${quotedCost.toLocaleString('ru-RU')} золота.`)
        setBusyKey(null)
        return
      }

      if (!window.confirm(
        `Заточить «${weapon.custom_name || weapon.item_name}» с +${weapon.enhancement_level} до +${targetLevel} за ${quotedCost.toLocaleString('ru-RU')} золота?`,
      )) {
        setBusyKey(null)
        return
      }
    }

    const { data, error } = await supabase.rpc('enhance_weapon_at_blacksmith_to_level', {
      p_character_id: characterId,
      p_sector_id: sectorId,
      p_character_item_id: weapon.character_item_id,
      p_target_level: targetLevel,
    })

    if (error) {
      setMessage(blacksmithError(error.message))
      setBusyKey(null)
      return
    }

    const result = Array.isArray(data) ? data[0] : null
    const spent = Number(result?.gold_spent ?? quotedCost)
    await refreshAfterMutation(
      `${weapon.custom_name || weapon.item_name} заточен до +${targetLevel}. Потрачено ${spent.toLocaleString('ru-RU')} золота.`,
    )
  }

  async function applyAffix(weapon: BlacksmithWeapon) {
    const key = `affix:${weapon.character_item_id}`
    setBusyKey(key)
    setMessage('')

    const { data, error } = await supabase.rpc('apply_weapon_affix_at_blacksmith', {
      p_character_id: characterId,
      p_sector_id: sectorId,
      p_character_item_id: weapon.character_item_id,
    })

    if (error) {
      setMessage(blacksmithError(error.message))
      setBusyKey(null)
      return
    }

    const row = Array.isArray(data) ? data[0] : null
    const affix = row?.added_affix as BlacksmithAffix | undefined
    await refreshAfterMutation(
      affix
        ? `На «${weapon.custom_name || weapon.item_name}» наложен аффикс «${affix.name}».`
        : 'Аффикс наложен.',
    )
  }

  async function rerollAffix(weapon: BlacksmithWeapon, affix: BlacksmithAffix, slotIndex: number) {
    const quote = weapon.reroll_costs.find((entry) => Number(entry.slot) === slotIndex + 1)
    const cost = Number(quote?.cost ?? 0)

    if (!window.confirm(
      `Перековать аффикс «${affix.name}» за ${cost.toLocaleString('ru-RU')} золота? Остальные аффиксы сохранятся.`,
    )) return

    const key = `reroll:${weapon.character_item_id}:${affix.id}`
    setBusyKey(key)
    setMessage('')

    const { data, error } = await supabase.rpc('reroll_weapon_affix_at_blacksmith', {
      p_character_id: characterId,
      p_sector_id: sectorId,
      p_character_item_id: weapon.character_item_id,
      p_affix_id: affix.id,
    })

    if (error) {
      setMessage(blacksmithError(error.message))
      setBusyKey(null)
      return
    }

    const row = Array.isArray(data) ? data[0] : null
    const next = row?.new_affix as BlacksmithAffix | undefined
    await refreshAfterMutation(
      next ? `«${affix.name}» перекован в «${next.name}».` : 'Аффикс перекован.',
    )
  }

  async function useTemperingMark(weapon: BlacksmithWeapon) {
    if (weapon.enhancement_level >= 3) return
    if (!window.confirm(
      `Использовать «Клеймо закалки III» на «${weapon.custom_name || weapon.item_name}»? Оружие сразу станет +3, золото не расходуется.`,
    )) return

    const key = `mark:${weapon.character_item_id}`
    setBusyKey(key)
    setMessage('')

    const { error } = await supabase.rpc('use_tempering_mark_iii_at_blacksmith', {
      p_character_id: characterId,
      p_sector_id: sectorId,
      p_character_item_id: weapon.character_item_id,
    })

    if (error) {
      setMessage(blacksmithError(error.message))
      setBusyKey(null)
      return
    }

    await refreshAfterMutation(
      `Клеймо закалки III использовано: ${weapon.custom_name || weapon.item_name} теперь +3 без затрат золота.`,
    )
  }

  async function awaken(weapon: BlacksmithWeapon) {
    const sourceId = awakeningSources[weapon.character_item_id]
      ?? weapon.duplicate_candidates[0]?.id

    if (!sourceId) {
      setMessage('Нет свободной копии этого оружия для пробуждения.')
      return
    }

    const source = weapon.duplicate_candidates.find((entry) => entry.id === sourceId)
    if (!source) return

    const sourceWarning = source.enhancement_level > 0 || source.awakening_level > 0 || source.affix_count > 0
      ? `\n\nВнимание: выбранная копия улучшена (${duplicateLabel(source)}). Она будет уничтожена полностью.`
      : ''

    if (!window.confirm(
      `Пробудить «${weapon.custom_name || weapon.item_name}» до ${roman(weapon.awakening_level + 1)}? Выбранная одинаковая копия будет уничтожена.${sourceWarning}`,
    )) return

    const key = `awaken:${weapon.character_item_id}`
    setBusyKey(key)
    setMessage('')

    const { error } = await supabase.rpc('awaken_weapon_at_blacksmith', {
      p_character_id: characterId,
      p_sector_id: sectorId,
      p_target_item_id: weapon.character_item_id,
      p_source_item_id: sourceId,
    })

    if (error) {
      setMessage(blacksmithError(error.message))
      setBusyKey(null)
      return
    }

    setAwakeningSources((current) => {
      const next = { ...current }
      delete next[weapon.character_item_id]
      return next
    })

    await refreshAfterMutation(
      `${weapon.custom_name || weapon.item_name}: Пробуждение ${roman(weapon.awakening_level + 1)}.`,
    )
  }

  if (loading) {
    return (
      <section className="blacksmith-panel">
        <div className="blacksmith-intro">
          <strong>Кузнец готовит инструменты…</strong>
        </div>
      </section>
    )
  }

  return (
    <section className="blacksmith-panel">
      <div className="blacksmith-intro">
        <div>
          <span className="eyebrow">КУЗНЕЦ</span>
          <h4>{settlementName}</h4>
          <p>
            Заточка повышает базовый урон, пробуждение использует одинаковые копии оружия,
            а аффиксы позволяют собирать собственный билд.
          </p>
        </div>
        <span className="badge">поселение ур. {settlementLevel}</span>
      </div>

      <div className="blacksmith-service-summary">
        <span className="ready">Заточка до +{rules.maxEnhancement}</span>
        <span className={rules.affixApply ? 'ready' : ''}>Аффиксы · ур. 2+</span>
        <span className={rules.awakening ? 'ready' : ''}>Пробуждение · ур. 3+</span>
        <span className={rules.affixReroll ? 'ready' : ''}>Перековка · ур. 3+</span>
      </div>

      <div className="blacksmith-tabs" role="tablist" aria-label="Услуги кузнеца">
        <button className={tab === 'enhance' ? 'active' : ''} type="button" onClick={() => setTab('enhance')}>
          Заточка
        </button>
        <button className={tab === 'awaken' ? 'active' : ''} type="button" onClick={() => setTab('awaken')}>
          Пробуждение
        </button>
        <button className={tab === 'affixes' ? 'active' : ''} type="button" onClick={() => setTab('affixes')}>
          Аффиксы
        </button>
      </div>

      {message && <p className="form-message" aria-live="polite">{message}</p>}

      {weapons.length === 0 ? (
        <div className="blacksmith-empty">В инвентаре нет оружия для работы кузнеца.</div>
      ) : tab === 'enhance' ? (
        <>
          <div className="settlement-shop-rule">
            <strong>Каждый +1 = +3% к base damage оружия.</strong>
            <span>Максимум +20. Высокие уровни заточки становятся заметно дороже и требуют сильного кузнеца.</span>
          </div>

          {temperingMarks > 0 && (
            <div className="blacksmith-special-material">
              <div>
                <span className="eyebrow">ОСОБАЯ НАГРАДА</span>
                <strong>Клеймо закалки III ×{temperingMarks}</strong>
                <small>Поднимает любое выбранное оружие ниже +3 сразу до +3 без золота.</small>
              </div>
              <span className="badge">weekly</span>
            </div>
          )}

          <div className="blacksmith-grid">
            {weapons.map((weapon) => {
              const globalMax = weapon.enhancement_level >= 20
              const townMax = Math.min(20, Number(weapon.max_enhancement))
              const townLocked = !globalMax && weapon.enhancement_level >= townMax
              const busy = busyKey === `enhance:${weapon.character_item_id}`
              const currentMultiplier = 1 + weapon.enhancement_level * 0.03
              const canJump = weapon.enhancement_level + 1 < townMax

              return (
                <article className={'blacksmith-card rarity-' + weapon.rarity} key={weapon.character_item_id}>
                  <div className="blacksmith-title-row">
                    <div>
                      <div className="blacksmith-tags">
                        <span className="rarity-label">{rarityLabels[weapon.rarity]}</span>
                        {weapon.is_equipped && <span className="blacksmith-equipped">Экипировано</span>}
                        {weapon.awakening_level > 0 && (
                          <span className="blacksmith-awakened">Пробуждение {roman(weapon.awakening_level)}</span>
                        )}
                      </div>
                      <h5>{weapon.custom_name || weapon.item_name} {weapon.enhancement_level > 0 ? `+${weapon.enhancement_level}` : ''}</h5>
                    </div>
                    <span className="blacksmith-level">+{weapon.enhancement_level}</span>
                  </div>

                  <div className="blacksmith-stats">
                    {weapon.weapon_family && <span>{familyLabels[weapon.weapon_family] ?? weapon.weapon_family}</span>}
                    <span>Base {weapon.weapon_base_damage}</span>
                    <span>После заточки {Number(weapon.enhanced_base_damage).toFixed(2)}</span>
                    <span>×{currentMultiplier.toFixed(2)}</span>
                  </div>

                  <div className="blacksmith-footer">
                    {globalMax ? (
                      <span className="blacksmith-maxed">Максимальная заточка +20</span>
                    ) : townLocked ? (
                      <span className="blacksmith-locked">Предел этого кузнеца: +{townMax}</span>
                    ) : (
                      <span>
                        Следующий +{weapon.next_enhancement_level} · <strong>{Number(weapon.next_cost ?? 0).toLocaleString('ru-RU')}</strong> золота
                      </span>
                    )}

                    <div className="blacksmith-action-row">
                      <button
                        className="primary-button"
                        type="button"
                        disabled={busyKey !== null || globalMax || townLocked || !weapon.can_afford}
                        onClick={() => void enhanceTo(weapon, weapon.enhancement_level + 1)}
                      >
                        {busy ? 'Куём…' : weapon.can_afford ? `+${weapon.enhancement_level + 1}` : 'Не хватает золота'}
                      </button>

                      {canJump && (
                        <button
                          className="ghost-button"
                          type="button"
                          disabled={busyKey !== null}
                          onClick={() => void enhanceTo(weapon, townMax)}
                        >
                          До +{townMax}
                        </button>
                      )}
                    </div>

                    {temperingMarks > 0 && weapon.enhancement_level < 3 && (
                      <button
                        className="blacksmith-mark-button"
                        type="button"
                        disabled={busyKey !== null}
                        onClick={() => void useTemperingMark(weapon)}
                      >
                        {busyKey === `mark:${weapon.character_item_id}` ? 'Ставим клеймо…' : 'Клеймо закалки III → +3 бесплатно'}
                      </button>
                    )}
                  </div>
                </article>
              )
            })}
          </div>
        </>
      ) : tab === 'awaken' ? (
        <>
          <div className="settlement-shop-rule">
            <strong>Пробуждение I–V не усиливает семейную механику.</strong>
            <span>Каждая ступень поглощает одну выбранную копию того же оружия и усиливает только свойство самого предмета.</span>
          </div>

          {!rules.awakening ? (
            <div className="blacksmith-service-locked">
              Пробуждение доступно в поселениях <strong>3 уровня и выше</strong>.
            </div>
          ) : (
            <div className="blacksmith-grid">
              {weapons.map((weapon) => {
                const maxed = weapon.awakening_level >= weapon.max_awakening
                const sourceId = awakeningSources[weapon.character_item_id]
                  ?? weapon.duplicate_candidates[0]?.id
                  ?? ''
                const busy = busyKey === `awaken:${weapon.character_item_id}`

                return (
                  <article className={'blacksmith-card rarity-' + weapon.rarity} key={weapon.character_item_id}>
                    <div className="blacksmith-title-row">
                      <div>
                        <div className="blacksmith-tags">
                          <span className="rarity-label">{rarityLabels[weapon.rarity]}</span>
                          {weapon.is_equipped && <span className="blacksmith-equipped">Экипировано</span>}
                        </div>
                        <h5>{weapon.custom_name || weapon.item_name}</h5>
                      </div>
                      <span className="blacksmith-level">◆ {roman(weapon.awakening_level)}</span>
                    </div>

                    <div className="blacksmith-awakening-progress">
                      {Array.from({ length: 5 }, (_, index) => (
                        <span className={index < weapon.awakening_level ? 'filled' : ''} key={index}>◆</span>
                      ))}
                    </div>

                    <div className="blacksmith-awakening-effect">
                      <span>Эффект пробуждения</span>
                      <strong>{weapon.awakening_effect_text}</strong>
                    </div>

                    {maxed ? (
                      <div className="blacksmith-maxed">Пробуждение V достигнуто.</div>
                    ) : weapon.duplicate_count === 0 ? (
                      <div className="blacksmith-locked">Нужна ещё одна такая же копия оружия.</div>
                    ) : (
                      <>
                        <label className="blacksmith-source-select">
                          <span>Поглотить копию</span>
                          <select
                            value={sourceId}
                            onChange={(event) => setAwakeningSources((current) => ({
                              ...current,
                              [weapon.character_item_id]: event.target.value,
                            }))}
                          >
                            {weapon.duplicate_candidates.map((source) => (
                              <option value={source.id} key={source.id}>{duplicateLabel(source)}</option>
                            ))}
                          </select>
                        </label>

                        <button
                          className="primary-button"
                          type="button"
                          disabled={busyKey !== null || !sourceId}
                          onClick={() => void awaken(weapon)}
                        >
                          {busy ? 'Пробуждаем…' : `Пробудить до ${roman(weapon.awakening_level + 1)}`}
                        </button>
                      </>
                    )}
                  </article>
                )
              })}
            </div>
          )}
        </>
      ) : (
        <>
          <div className="settlement-shop-rule">
            <strong>Слоты аффиксов зависят только от редкости.</strong>
            <span>Common 0 · Uncommon 1 · Rare 2 · Epic 3 · Unique 4 · Legendary 5. Перековка меняет один выбранный аффикс и сохраняет остальные.</span>
          </div>

          {!rules.affixApply ? (
            <div className="blacksmith-service-locked">
              Работа с аффиксами доступна в поселениях <strong>2 уровня и выше</strong>.
            </div>
          ) : (
            <div className="blacksmith-grid">
              {weapons.map((weapon) => {
                const busy = busyKey?.includes(weapon.character_item_id) ?? false
                return (
                  <article className={'blacksmith-card blacksmith-affix-card rarity-' + weapon.rarity} key={weapon.character_item_id}>
                    <div className="blacksmith-title-row">
                      <div>
                        <div className="blacksmith-tags">
                          <span className="rarity-label">{rarityLabels[weapon.rarity]}</span>
                          {weapon.is_equipped && <span className="blacksmith-equipped">Экипировано</span>}
                        </div>
                        <h5>{weapon.custom_name || weapon.item_name}</h5>
                      </div>
                      <span className="blacksmith-level">{weapon.affix_count}/{weapon.affix_slots}</span>
                    </div>

                    <div className="blacksmith-slot-row" aria-label={`Аффиксы ${weapon.affix_count} из ${weapon.affix_slots}`}>
                      {weapon.affix_slots === 0
                        ? <span className="no-slots">Нет слотов</span>
                        : Array.from({ length: weapon.affix_slots }, (_, index) => (
                          <span className={index < weapon.affix_count ? 'filled' : ''} key={index}>◆</span>
                        ))}
                    </div>

                    {weapon.affixes.length > 0 && (
                      <div className="blacksmith-affix-list">
                        {weapon.affixes.map((affix, index) => {
                          const rerollQuote = weapon.reroll_costs.find((entry) => Number(entry.slot) === index + 1)
                          return (
                            <div className="blacksmith-affix-row" key={affix.id}>
                              <div>
                                <strong>{affix.name}</strong>
                                <span>{affixSummary(affix)}</span>
                              </div>
                              {rules.affixReroll && (
                                <button
                                  className="ghost-button"
                                  type="button"
                                  disabled={busyKey !== null}
                                  onClick={() => void rerollAffix(weapon, affix, index)}
                                >
                                  Перековать · {Number(rerollQuote?.cost ?? 0).toLocaleString('ru-RU')}
                                </button>
                              )}
                            </div>
                          )
                        })}
                      </div>
                    )}

                    {weapon.affix_slots === 0 ? (
                      <div className="blacksmith-locked">Обычное оружие не имеет слотов аффиксов.</div>
                    ) : weapon.affix_count < weapon.affix_slots ? (
                      <button
                        className="primary-button"
                        type="button"
                        disabled={busyKey !== null || !weapon.can_add_affix || !weapon.can_afford_affix}
                        onClick={() => void applyAffix(weapon)}
                      >
                        {busy
                          ? 'Накладываем…'
                          : !weapon.can_afford_affix
                            ? `Нужно ${Number(weapon.next_affix_cost ?? 0).toLocaleString('ru-RU')} золота`
                            : `Наложить аффикс · ${Number(weapon.next_affix_cost ?? 0).toLocaleString('ru-RU')}`}
                      </button>
                    ) : (
                      <div className="blacksmith-maxed">
                        Все {weapon.affix_slots} слота заполнены.
                        {!rules.affixReroll && ' Перековка откроется у кузнеца 3 уровня.'}
                      </div>
                    )}

                    {weapon.affix_reroll_count > 0 && (
                      <small className="blacksmith-reroll-note">
                        Перековок этого предмета: {weapon.affix_reroll_count}. Повторные перековки постепенно дорожают.
                      </small>
                    )}
                  </article>
                )
              })}
            </div>
          )}
        </>
      )}
    </section>
  )
}
