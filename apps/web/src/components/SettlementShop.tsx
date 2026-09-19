import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { DamageType, SettlementShopItem } from '../types'

type Props = {
  characterId: string
  sectorId: number
  onProgressChanged?: () => Promise<unknown> | void
  onInventoryChanged?: () => Promise<unknown> | void
}

const categoryLabels: Record<string, string> = {
  consumable: 'Расходники',
  weapon: 'Оружие',
  armor: 'Броня',
  accessory: 'Аксессуары',
  material: 'Материалы',
  quest: 'Особое',
}

const rarityLabels: Record<string, string> = {
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

const weaponScalingLabels: Record<'strength' | 'agility' | 'hybrid', string> = {
  strength: 'Силовое',
  agility: 'Ловкостное',
  hybrid: 'Гибридное',
}

const bowFamilyLabels: Record<'short_bow' | 'long_bow', string> = {
  short_bow: 'Короткий лук',
  long_bow: 'Длинный лук',
}

const statLabels: Record<string, string> = {
  strength: 'Сила',
  agility: 'Ловкость',
  intellect: 'Интеллект',
  vitality: 'Живучесть',
  luck: 'Удача',
}

export function SettlementShop({
  characterId,
  sectorId,
  onProgressChanged,
  onInventoryChanged,
}: Props) {
  const [items, setItems] = useState<SettlementShopItem[]>([])
  const [loading, setLoading] = useState(true)
  const [busyItemId, setBusyItemId] = useState<string | null>(null)
  const [message, setMessage] = useState('')

  async function loadShop() {
    setLoading(true)

    const { data, error } = await supabase.rpc('get_settlement_shop_v4', {
      p_character_id: characterId,
      p_sector_id: sectorId,
    })

    if (error) {
      setMessage(error.message)
      setItems([])
      setLoading(false)
      return
    }

    setItems((data as SettlementShopItem[] | null) ?? [])
    setLoading(false)
  }

  useEffect(() => {
    void loadShop()
  }, [characterId, sectorId])

  const settlementName = items[0]?.settlement_name ?? 'Поселение'
  const settlementLevel = items[0]?.settlement_level ?? 0

  const grouped = useMemo(() => {
    const map = new Map<string, SettlementShopItem[]>()

    for (const item of items) {
      const list = map.get(item.category) ?? []
      list.push(item)
      map.set(item.category, list)
    }

    return [...map.entries()]
  }, [items])

  async function buy(item: SettlementShopItem, quantity = 1) {
    setBusyItemId(item.item_id)
    setMessage('')

    const { error } = await supabase.rpc('buy_settlement_shop_item', {
      p_character_id: characterId,
      p_sector_id: sectorId,
      p_item_definition_id: item.item_id,
      p_quantity: quantity,
    })

    if (error) {
      const raw = error.message

      if (raw.includes('LEVEL_TOO_LOW')) {
        setMessage(`Для покупки «${item.item_name}» нужен уровень ${item.required_level}.`)
      } else if (raw.includes('NOT_ENOUGH_GOLD')) {
        setMessage('Недостаточно золота.')
      } else if (raw.includes('CHARACTER_BUSY')) {
        setMessage('Нельзя закупаться во время экспедиции, исследования или прохождения подземелья.')
      } else {
        setMessage(raw)
      }

      setBusyItemId(null)
      return
    }

    await Promise.all([
      Promise.resolve(onProgressChanged?.()),
      Promise.resolve(onInventoryChanged?.()),
    ])
    await loadShop()

    setMessage(
      quantity > 1
        ? `Куплено: ${item.item_name} ×${quantity}.`
        : `Куплено: ${item.item_name}.`,
    )
    setBusyItemId(null)
  }

  if (loading) {
    return (
      <article className="panel settlement-shop-panel">
        <span className="eyebrow">МАГАЗИН ПОСЕЛЕНИЯ</span>
        <h3>Проверяем ассортимент…</h3>
      </article>
    )
  }

  return (
    <article className="panel settlement-shop-panel">
      <div className="section-heading settlement-shop-heading">
        <div>
          <span className="eyebrow">МАГАЗИН ПОСЕЛЕНИЯ</span>
          <h3>{settlementName}</h3>
          <p className="muted">
            Уровень поселения {settlementLevel}/10. Чем выше уровень, тем шире и сильнее ассортимент.
          </p>
        </div>
        <span className="badge">ур. {settlementLevel}</span>
      </div>

      <div className="settlement-shop-rule">
        <strong>Экипировка имеет уровень персонажа.</strong>
        <span>
          Даже если накопить золото на топовую вещь в слабых данжах, купить её раньше требуемого уровня нельзя.
        </span>
      </div>

      {message && <p className="form-message" aria-live="polite">{message}</p>}

      <div className="settlement-shop-groups">
        {grouped.map(([category, categoryItems]) => (
          <section className="settlement-shop-group" key={category}>
            <div className="settlement-shop-group-heading">
              <h4>{categoryLabels[category] ?? category}</h4>
              <span>{categoryItems.length}</span>
            </div>

            <div className="settlement-shop-grid">
              {categoryItems.map((item) => {
                const modifiers = Object.entries(item.stat_modifiers ?? {})
                  .filter((entry): entry is [string, number] => typeof entry[1] === 'number')
                const resistances = Object.entries(item.damage_resistances ?? {})
                  .filter((entry): entry is [DamageType, number] => typeof entry[1] === 'number' && entry[1] !== 0)
                const damageBonuses = Object.entries(item.damage_bonuses ?? {})
                  .filter((entry): entry is [DamageType, number] => typeof entry[1] === 'number' && entry[1] > 0)
                const locked = !item.level_unlocked
                const busy = busyItemId === item.item_id

                return (
                  <article
                    className={[
                      'shop-item-card',
                      'rarity-' + item.rarity,
                      locked ? 'locked' : '',
                    ].filter(Boolean).join(' ')}
                    key={item.item_id}
                  >
                    <div className="shop-item-title-row">
                      <div>
                        <span className="rarity-label">{rarityLabels[item.rarity] ?? item.rarity}</span>
                        <h5>{item.item_name}</h5>
                      </div>
                      <span className="shop-item-tier">T{item.shop_tier}</span>
                    </div>

                    <p>{item.description}</p>

                    {item.heal_amount > 0 && (
                      <div className="shop-item-effect">+{item.heal_amount} HP</div>
                    )}

                    {item.scroll_mode && item.scroll_spell_name && (
                      <div className="shop-item-effect scroll-effect">
                        {item.scroll_mode === 'learn' ? 'Изучает' : 'Одноразово применяет'} · {item.scroll_spell_name}
                      </div>
                    )}

                    {item.damage_type && (
                      <div className="damage-type-chip">
                        Тип урона · {damageTypeLabels[item.damage_type]}
                      </div>
                    )}

                    {item.category === 'weapon' && (
                      <div className="modifier-list">
                        <span>Базовый урон +{item.weapon_base_damage ?? 0}</span>
                        <span>{weaponScalingLabels[item.weapon_scaling ?? 'strength']}</span>
                        {item.weapon_family && (
                          <span>{bowFamilyLabels[item.weapon_family]}</span>
                        )}
                        {item.weapon_family && item.bow_full_draw_armor_penetration_percent > 0 && (
                          <span>Полный натяг · пробитие брони {item.bow_full_draw_armor_penetration_percent}%</span>
                        )}
                        {item.bloodshed_chance_percent > 0 && (
                          <span>Кровопролитие · шанс {item.bloodshed_chance_percent}%</span>
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
                          <span key={'shop-damage-bonus-' + type}>
                            {damageTypeLabels[type]} урон +{value}%
                          </span>
                        ))}
                      </div>
                    )}

                    {modifiers.length > 0 && (
                      <div className="modifier-list">
                        {modifiers.map(([key, value]) => (
                          <span key={key}>
                            {statLabels[key] ?? key} {value >= 0 ? '+' : ''}{value}
                          </span>
                        ))}
                      </div>
                    )}

                    <div className="shop-item-meta">
                      <span>Цена <strong>{item.price.toLocaleString('ru-RU')}</strong></span>
                      <span className={locked ? 'locked-level' : ''}>
                        Ур. {item.required_level}
                      </span>
                    </div>

                    <div className="shop-item-actions">
                      <button
                        className="primary-button"
                        type="button"
                        disabled={busyItemId !== null || locked || !item.can_afford}
                        onClick={() => void buy(item, 1)}
                      >
                        {locked
                          ? `Нужен ур. ${item.required_level}`
                          : !item.can_afford
                            ? 'Не хватает золота'
                            : busy
                              ? 'Покупаем…'
                              : 'Купить'}
                      </button>

                      {item.category === 'consumable' && !locked && (
                        <button
                          className="ghost-button"
                          type="button"
                          disabled={busyItemId !== null}
                          onClick={() => void buy(item, 5)}
                        >
                          ×5
                        </button>
                      )}
                    </div>
                  </article>
                )
              })}
            </div>
          </section>
        ))}
      </div>
    </article>
  )
}
