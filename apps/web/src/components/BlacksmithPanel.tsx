import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { BlacksmithWeapon, ItemRarity, WeaponFamily } from '../types'

type Props = {
  characterId: string
  sectorId: number
  settlementName: string
  settlementLevel: number
  onProgressChanged?: () => Promise<unknown> | void
  onInventoryChanged?: () => Promise<unknown> | void
}

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

function enhancementCap(level: number) {
  if (level <= 0) return 2
  if (level === 1) return 5
  if (level === 2) return 8
  if (level === 3) return 12
  if (level === 4) return 16
  return 20
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
  const [loading, setLoading] = useState(true)
  const [busyItemId, setBusyItemId] = useState<string | null>(null)
  const [message, setMessage] = useState('')

  const localCap = enhancementCap(settlementLevel)

  async function loadWeapons() {
    setLoading(true)

    const { data, error } = await supabase.rpc('get_settlement_blacksmith', {
      p_character_id: characterId,
      p_sector_id: sectorId,
    })

    if (error) {
      setMessage(error.message)
      setWeapons([])
      setLoading(false)
      return
    }

    setWeapons((data as BlacksmithWeapon[] | null) ?? [])
    setLoading(false)
  }

  useEffect(() => {
    void loadWeapons()
  }, [characterId, sectorId])

  async function enhance(weapon: BlacksmithWeapon) {
    setBusyItemId(weapon.character_item_id)
    setMessage('')

    const { data, error } = await supabase.rpc('enhance_weapon_at_blacksmith', {
      p_character_id: characterId,
      p_sector_id: sectorId,
      p_character_item_id: weapon.character_item_id,
    })

    if (error) {
      const raw = error.message

      if (raw.includes('NOT_ENOUGH_GOLD')) {
        setMessage('Недостаточно золота.')
      } else if (raw.includes('BLACKSMITH_LEVEL_TOO_LOW')) {
        setMessage('Этот кузнец не умеет усиливать оружие до следующего уровня.')
      } else if (raw.includes('MAX_ENHANCEMENT_REACHED')) {
        setMessage('Оружие уже заточено до +20.')
      } else if (raw.includes('CHARACTER_BUSY')) {
        setMessage('Нельзя пользоваться кузнецом во время экспедиции, исследования или подземелья.')
      } else {
        setMessage(raw)
      }

      setBusyItemId(null)
      return
    }

    const result = Array.isArray(data) ? data[0] : null
    await Promise.all([
      Promise.resolve(onProgressChanged?.()),
      Promise.resolve(onInventoryChanged?.()),
    ])
    await loadWeapons()

    const nextLevel = result?.new_enhancement_level ?? weapon.enhancement_level + 1
    const spent = result?.gold_spent ?? weapon.next_cost ?? 0
    setMessage(
      `${weapon.custom_name || weapon.item_name} усилен до +${nextLevel}. Потрачено ${Number(spent).toLocaleString('ru-RU')} золота.`,
    )
    setBusyItemId(null)
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
            Кузнец поселения ур. {settlementLevel} может точить оружие максимум до <strong>+{localCap}</strong>.
            Каждый уровень даёт +3% к базовому урону оружия.
          </p>
        </div>
        <span className="badge">до +{localCap}</span>
      </div>

      <div className="settlement-shop-rule">
        <strong>Заточка усиливает только оружейную базу.</strong>
        <span>
          Характеристики персонажа не умножаются. +20 даёт +60% к base damage оружия и остаётся редкой дорогой целью.
        </span>
      </div>

      {message && <p className="form-message" aria-live="polite">{message}</p>}

      {weapons.length === 0 ? (
        <div className="blacksmith-empty">
          В инвентаре нет оружия, которое можно отнести кузнецу.
        </div>
      ) : (
        <div className="blacksmith-grid">
          {weapons.map((weapon) => {
            const maxed = weapon.enhancement_level >= 20
            const townLocked = !maxed && !weapon.can_enhance_here
            const busy = busyItemId === weapon.character_item_id
            const currentMultiplier = 1 + weapon.enhancement_level * 0.03
            const nextMultiplier = weapon.next_enhancement_level == null
              ? currentMultiplier
              : 1 + weapon.next_enhancement_level * 0.03

            return (
              <article
                className={'blacksmith-card rarity-' + weapon.rarity}
                key={weapon.character_item_id}
              >
                <div className="blacksmith-title-row">
                  <div>
                    <div className="blacksmith-tags">
                      <span className="rarity-label">{rarityLabels[weapon.rarity]}</span>
                      {weapon.is_equipped && <span className="blacksmith-equipped">Экипировано</span>}
                    </div>
                    <h5>
                      {weapon.custom_name || weapon.item_name}
                      {weapon.enhancement_level > 0 ? ` +${weapon.enhancement_level}` : ''}
                    </h5>
                  </div>
                  <span className="blacksmith-level">+{weapon.enhancement_level}</span>
                </div>

                <div className="blacksmith-stats">
                  {weapon.weapon_family && (
                    <span>{familyLabels[weapon.weapon_family] ?? weapon.weapon_family}</span>
                  )}
                  <span>Base {weapon.weapon_base_damage}</span>
                  <span>Текущая база {Number(weapon.enhanced_base_damage).toFixed(2)}</span>
                  <span>×{currentMultiplier.toFixed(2)}</span>
                </div>

                {!maxed && weapon.next_enhancement_level != null && (
                  <div className="blacksmith-preview">
                    <span>Следующий уровень</span>
                    <strong>
                      +{weapon.next_enhancement_level} · ×{nextMultiplier.toFixed(2)}
                    </strong>
                  </div>
                )}

                <div className="blacksmith-footer">
                  {maxed ? (
                    <span className="blacksmith-maxed">Максимальная заточка +20</span>
                  ) : townLocked ? (
                    <span className="blacksmith-locked">
                      Нужен кузнец, который умеет точить до +{weapon.next_enhancement_level}
                    </span>
                  ) : (
                    <span>
                      Цена <strong>{Number(weapon.next_cost ?? 0).toLocaleString('ru-RU')}</strong>
                    </span>
                  )}

                  <button
                    className="primary-button"
                    type="button"
                    disabled={
                      busyItemId !== null
                      || maxed
                      || townLocked
                      || !weapon.can_afford
                    }
                    onClick={() => void enhance(weapon)}
                  >
                    {maxed
                      ? '+20'
                      : townLocked
                        ? 'Слишком слабый кузнец'
                        : !weapon.can_afford
                          ? 'Не хватает золота'
                          : busy
                            ? 'Куём…'
                            : `Заточить до +${weapon.next_enhancement_level}`}
                  </button>
                </div>
              </article>
            )
          })}
        </div>
      )}
    </section>
  )
}
