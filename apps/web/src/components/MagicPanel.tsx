import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { CharacterProgress, CharacterSpell, CombatStatusEffectType, DamageType } from '../types'

type Props = {
  characterId: string
  progress: CharacterProgress
}

const statusEffectLabels: Record<CombatStatusEffectType, string> = {
  burn: 'Горение',
  bleed: 'Кровотечение',
  poison: 'Яд',
  chill: 'Охлаждение',
  stun: 'Оглушение',
  weaken: 'Ослабление',
  vulnerable: 'Уязвимость',
}

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

export function MagicPanel({ characterId, progress }: Props) {
  const [spells, setSpells] = useState<CharacterSpell[]>([])
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  async function loadSpells() {
    setLoading(true)
    const { data, error } = await supabase.rpc('get_character_spells', {
      p_character_id: characterId,
    })

    if (error) {
      setMessage(error.message)
      setLoading(false)
      return
    }

    setSpells((data as CharacterSpell[] | null) ?? [])
    setLoading(false)
  }

  useEffect(() => {
    void loadSpells()
  }, [characterId])

  async function toggleCombatSpell(spell: CharacterSpell) {
    const selected = spells
      .filter((item) => item.combat_slot !== null)
      .sort((a, b) => (a.combat_slot ?? 99) - (b.combat_slot ?? 99))

    const isSelected = spell.combat_slot !== null
    const nextIds = isSelected
      ? selected.filter((item) => item.id !== spell.id).map((item) => item.id)
      : [...selected.map((item) => item.id), spell.id]

    if (!isSelected && nextIds.length > 3) {
      setMessage('В боевой набор можно взять максимум 3 заклинания.')
      return
    }

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('set_character_combat_spells', {
      p_character_id: characterId,
      p_spell_ids: nextIds,
    })

    if (error) {
      const raw = error.message
      setMessage(
        raw.includes('SPELL_LOADOUT_LOCKED')
          ? 'Боевой набор уже зафиксирован: сначала закончи текущий бой, данж или дуэль.'
          : raw.includes('SPELL_LOADOUT_LIMIT')
            ? 'В боевой набор можно взять максимум 3 заклинания.'
            : raw.includes('SPELL_NOT_LEARNED')
              ? 'Одно из выбранных заклинаний больше недоступно персонажу.'
              : raw,
      )
      setBusy(false)
      return
    }

    await loadSpells()
    setMessage(isSelected ? 'Заклинание убрано из боевого набора.' : 'Заклинание добавлено в боевой набор.')
    setBusy(false)
  }

  const selectedSpells = spells
    .filter((spell) => spell.combat_slot !== null)
    .sort((a, b) => (a.combat_slot ?? 99) - (b.combat_slot ?? 99))

  const concentrationActive = selectedSpells.length === 1

  const manaPercent = progress.mana_max > 0
    ? Math.max(0, Math.min(100, Math.round((progress.mana_current / progress.mana_max) * 100)))
    : 0

  return (
    <section className="magic-panel-section">
      <article className="panel magic-summary-card">
        <div>
          <span className="eyebrow">МАГИЯ</span>
          <h2>Книга заклинаний</h2>
          <p className="muted">
            Базовая магическая атака использует врождённую стихию расы. Из всех изученных заклинаний в бой можно заранее взять максимум три; свитки и врождённая магия в эти слоты не входят.
          </p>
        </div>

        <div className="mana-summary">
          <div className="card-heading">
            <span>Мана</span>
            <strong>{progress.mana_current} / {progress.mana_max}</strong>
          </div>
          <div className="meter mana-meter"><span style={{ width: manaPercent + '%' }} /></div>
          <small>Пассивное восстановление: +10 маны в час вне активного боя</small>
        </div>
      </article>

      {message && <p className="form-message" aria-live="polite">{message}</p>}

      <article className="panel">
        <div className="section-heading">
          <div>
            <span className="eyebrow">ПОДГОТОВКА</span>
            <h2>Боевой набор · {selectedSpells.length}/3</h2>
          </div>
          <span className="badge">{selectedSpells.length}/3</span>
        </div>

        <p className="muted">
          Этот набор используется в боях, данжах и дуэлях. Во время активного боя или похода менять его нельзя.
        </p>

        {concentrationActive && (
          <>
            <div className="spell-stats">
              <span>Концентрация <strong>активна</strong></span>
              <span>Урон и лечение <strong>+30%</strong></span>
              <span>Урон со временем <strong>+20%</strong></span>
              <span>Щиты и % баффы <strong>+15%</strong></span>
              <span>Мягкие дебаффы <strong>+10%</strong></span>
            </div>
            <p className="muted">
              Шанс срабатывания, длительность, стан, провокация, очищение и стоимость маны не усиливаются.
            </p>
          </>
        )}

        {selectedSpells.length > 1 && (
          <p className="muted">
            Концентрация неактивна: она включается только когда занят ровно один из трёх слотов.
          </p>
        )}

        {selectedSpells.length === 0 ? (
          <div className="empty-state magic-empty-state">
            <strong>Боевой набор пуст</strong>
            <span>Можно идти и без заклинаний или выбрать до трёх ниже.</span>
          </div>
        ) : (
          <div className="spell-stats">
            {selectedSpells.map((spell) => (
              <span key={spell.id}>
                Слот {spell.combat_slot} · <strong>{spell.name}</strong>
              </span>
            ))}
          </div>
        )}
      </article>

      <article className="panel">
        <div className="section-heading">
          <div>
            <span className="eyebrow">ИЗУЧЕНО</span>
            <h2>Заклинания персонажа</h2>
          </div>
          <span className="badge">{spells.length}</span>
        </div>

        {loading ? (
          <p className="muted">Загружаем заклинания…</p>
        ) : spells.length === 0 ? (
          <div className="empty-state magic-empty-state">
            <strong>Заклинаний пока нет</strong>
            <span>Найди или купи свиток изучения и используй его из инвентаря.</span>
          </div>
        ) : (
          <div className="spell-grid">
            {spells.map((spell) => (
              <article className="spell-card" key={spell.id}>
                <div className="spell-card-heading">
                  <div>
                    <span className="eyebrow">УР. {spell.required_level}</span>
                    <h3>{spell.name}</h3>
                  </div>
                  {spell.spell_kind === 'heal' ? (
                    <span className="damage-type-chip healing">Лечение</span>
                  ) : spell.damage_type ? (
                    <span className="damage-type-chip">{damageLabels[spell.damage_type]}</span>
                  ) : null}
                </div>

                <p>{spell.description}</p>

                <div className="spell-stats">
                  <span>Мана <strong>{spell.mana_cost}</strong></span>
                  <span>{spell.spell_kind === 'heal' ? 'Лечение' : 'Сила'} <strong>×{Number(spell.power_multiplier).toFixed(2)}</strong></span>
                  {spell.flat_power > 0 && (
                    <span>{spell.spell_kind === 'heal' ? 'База' : 'Бонус'} <strong>+{spell.flat_power}</strong></span>
                  )}
                  {spell.status_effect_type && (
                    <span className="spell-effect-stat">
                      {statusEffectLabels[spell.status_effect_type]}
                      {' '}<strong>{spell.status_effect_chance}%</strong>
                      {' · '}{spell.status_effect_turns} х.
                    </span>
                  )}
                </div>

                {concentrationActive && spell.combat_slot !== null && (
                  <div className="spell-stats">
                    <span>Концентрация <strong>усиливает это заклинание</strong></span>
                  </div>
                )}

                <button
                  className="ghost-button"
                  type="button"
                  disabled={busy || spell.spell_kind === 'sacrifice'}
                  onClick={() => void toggleCombatSpell(spell)}
                >
                  {spell.spell_kind === 'sacrifice'
                    ? 'Используется отдельно через свиток'
                    : spell.combat_slot !== null
                      ? `Убрать из набора · слот ${spell.combat_slot}`
                      : selectedSpells.length >= 3
                        ? 'Набор заполнен'
                        : 'Взять в бой'}
                </button>
              </article>
            ))}
          </div>
        )}
      </article>
    </section>
  )
}
