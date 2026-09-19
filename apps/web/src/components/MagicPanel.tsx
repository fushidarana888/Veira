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
            Базовая магическая атака использует врождённую стихию расы. Изученные заклинания могут наносить стихийный урон или лечить персонажа прямо в бою.
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
              </article>
            ))}
          </div>
        )}
      </article>
    </section>
  )
}
