import { FormEvent, useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { DamageType, RaceDefinition, RaceTrait } from '../types'

type Props = {
  userId: string
  displayName: string
  onCreated: () => Promise<void> | void
  onSignOut: () => Promise<void> | void
}

type InitialStatKey = 'strength' | 'agility' | 'intellect' | 'vitality' | 'luck'

const INITIAL_STAT_MIN = 3
const INITIAL_STAT_MAX = 8
const FREE_STAT_POINTS = 10

const statLabels: Record<InitialStatKey, { name: string; description: string }> = {
  strength: {
    name: 'Сила',
    description: 'Физическая мощь персонажа.',
  },
  agility: {
    name: 'Ловкость',
    description: 'Скорость, реакция и точность движений.',
  },
  intellect: {
    name: 'Интеллект',
    description: 'Умственные способности и работа с магией.',
  },
  vitality: {
    name: 'Живучесть',
    description: 'Выносливость и способность переносить урон.',
  },
  luck: {
    name: 'Удача',
    description: 'Влияние случайности в пользу персонажа.',
  },
}

const damageTypeLabels: Record<DamageType, string> = {
  slashing: 'Режущий',
  piercing: 'Колющий',
  blunt: 'Дробящий',
  fire: 'Огонь',
  water: 'Вода',
  earth: 'Земля',
  air: 'Воздух',
  lightning: 'Молния',
  ice: 'Лёд',
}

const defaultStats: Record<InitialStatKey, number> = {
  strength: INITIAL_STAT_MIN,
  agility: INITIAL_STAT_MIN,
  intellect: INITIAL_STAT_MIN,
  vitality: INITIAL_STAT_MIN,
  luck: INITIAL_STAT_MIN,
}

function raceTraitLines(traits: RaceTrait[] | undefined) {
  return (traits ?? []).filter((trait) => trait.name && trait.description)
}

function raceStatLines(race: RaceDefinition) {
  return Object.entries(race.stat_modifiers ?? {})
    .filter((entry): entry is [string, number] => typeof entry[1] === 'number' && entry[1] !== 0)
}

async function sha256Hex(value: string) {
  const bytes = new TextEncoder().encode(value)
  const digest = await crypto.subtle.digest('SHA-256', bytes)
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('')
}

export function CharacterSetup({ userId, displayName, onCreated, onSignOut }: Props) {
  const [name, setName] = useState('')
  const [bio, setBio] = useState('')
  const [races, setRaces] = useState<RaceDefinition[]>([])
  const [raceId, setRaceId] = useState('')
  const [raceQuery, setRaceQuery] = useState('')
  const [raceCategory, setRaceCategory] = useState('Все')
  const [raceLoading, setRaceLoading] = useState(true)
  const [stats, setStats] = useState<Record<InitialStatKey, number>>(defaultStats)
  const [gmCode, setGmCode] = useState('')
  const [busy, setBusy] = useState(false)
  const [gmBusy, setGmBusy] = useState(false)
  const [message, setMessage] = useState('')
  const [gmMessage, setGmMessage] = useState('')

  useEffect(() => {
    let active = true

    async function loadRaces() {
      const { data, error } = await supabase.rpc('get_character_creation_races')

      if (!active) return

      if (error) {
        setMessage('Не удалось загрузить список рас: ' + error.message)
        setRaceLoading(false)
        return
      }

      const nextRaces = (data as RaceDefinition[] | null) ?? []
      setRaces(nextRaces)

      const human = nextRaces.find((race) => race.slug === 'human')
      if (human) setRaceId(human.id)

      setRaceLoading(false)
    }

    void loadRaces()
    return () => { active = false }
  }, [])

  const categories = useMemo(
    () => ['Все', ...Array.from(new Set(races.map((race) => race.category)))],
    [races],
  )

  const filteredRaces = useMemo(() => {
    const query = raceQuery.trim().toLocaleLowerCase('ru-RU')

    return races.filter((race) => {
      const categoryMatches = raceCategory === 'Все' || race.category === raceCategory
      const queryMatches =
        !query ||
        race.name.toLocaleLowerCase('ru-RU').includes(query) ||
        race.description.toLocaleLowerCase('ru-RU').includes(query)

      return categoryMatches && queryMatches
    })
  }, [races, raceQuery, raceCategory])

  const selectedRace = races.find((race) => race.id === raceId) ?? null
  const spentStatPoints = Object.values(stats).reduce(
    (sum, value) => sum + (value - INITIAL_STAT_MIN),
    0,
  )
  const remainingStatPoints = FREE_STAT_POINTS - spentStatPoints

  function changeStat(stat: InitialStatKey, delta: number) {
    setStats((current) => {
      const nextValue = current[stat] + delta

      if (nextValue < INITIAL_STAT_MIN || nextValue > INITIAL_STAT_MAX) return current
      if (delta > 0 && remainingStatPoints <= 0) return current

      return {
        ...current,
        [stat]: nextValue,
      }
    })
  }

  function resetStats() {
    setStats({ ...defaultStats })
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setMessage('')

    if (!name.trim()) {
      setMessage('Укажи имя персонажа.')
      return
    }

    if (!raceId) {
      setMessage('Выбери расу персонажа.')
      return
    }

    if (remainingStatPoints !== 0) {
      setMessage(`Распредели все очки характеристик. Осталось: ${remainingStatPoints}.`)
      return
    }

    setBusy(true)

    if (!bio.trim()) {
      setMessage('Короткая биография обязательна.')
      setBusy(false)
      return
    }

    const { error } = await supabase.rpc('create_player_character', {
      p_name: name.trim(),
      p_race_id: raceId,
      p_bio: bio.trim(),
      p_strength: stats.strength,
      p_agility: stats.agility,
      p_intellect: stats.intellect,
      p_vitality: stats.vitality,
      p_luck: stats.luck,
    })

    if (error) {
      const raw = error.message

      if (raw.includes('INITIAL_STATS_MUST_SPEND_TEN')) {
        setMessage('Нужно распределить ровно 10 свободных очков.')
      } else if (raw.includes('INITIAL_STAT_OUT_OF_RANGE')) {
        setMessage('При создании каждая характеристика должна быть от 3 до 8.')
      } else if (raw.includes('CHARACTER_ALREADY_EXISTS')) {
        setMessage('На этом аккаунте уже есть персонаж.')
      } else if (raw.includes('RACE_REQUIRES_GM_ACCESS')) {
        setMessage('Эта раса доступна только после разрешения ГМ.')
      } else if (raw.includes('BIOGRAPHY_REQUIRED')) {
        setMessage('Короткая биография обязательна.')
      } else {
        setMessage(raw)
      }

      setBusy(false)
      return
    }

    await onCreated()
    setBusy(false)
  }

  async function claimGm() {
    const code = gmCode.trim()
    setGmMessage('')

    if (!code) {
      setGmMessage('Введи одноразовый код ГМ.')
      return
    }

    setGmBusy(true)

    try {
      const tokenHash = await sha256Hex(code)
      const { error } = await supabase.from('gm_claim_requests').insert({
        user_id: userId,
        token_hash: tokenHash,
      })

      if (error) {
        const raw = error.message
        if (raw.includes('INVALID_OR_EXPIRED_GM_CODE')) {
          setGmMessage('Код неверный, уже использован или истёк.')
        } else if (raw.includes('GM_ACCOUNT_MUST_NOT_HAVE_CHARACTER')) {
          setGmMessage('ГМ-аккаунт должен быть отдельным и не иметь игрового персонажа.')
        } else {
          setGmMessage(raw)
        }
        return
      }

      setGmMessage('ГМ-доступ активирован.')
      await onCreated()
    } finally {
      setGmBusy(false)
    }
  }

  return (
    <main className="shell">
      <header className="topbar">
        <div>
          <span className="eyebrow">ПЕРВЫЙ ВХОД</span>
          <h1>Создай персонажа</h1>
          <p className="muted">Аккаунт: {displayName}</p>
        </div>
        <button className="ghost-button" type="button" onClick={() => void onSignOut()}>
          Выйти
        </button>
      </header>

      <div className="setup-grid">
        <section className="panel character-create">
          <span className="eyebrow">ИГРОВОЙ АККАУНТ</span>
          <h2>Новый персонаж</h2>

          <form className="form-stack setup-form" onSubmit={submit}>
            <label>
              <span>Имя персонажа</span>
              <input
                value={name}
                onChange={(event) => setName(event.target.value)}
                maxLength={60}
                placeholder="Имя, под которым его знает мир"
              />
            </label>

            <div className="race-picker-block">
              <div className="race-picker-heading">
                <div>
                  <span className="form-label">Раса</span>
                  <p className="muted">Раса влияет на характеристики, ОЗ/ОМ, восстановление, сопротивления, стихию и собственные боевые особенности.</p>
                </div>
                {selectedRace && <span className="selected-race-badge">Выбрано: {selectedRace.name}</span>}
              </div>

              <input
                className="race-search"
                value={raceQuery}
                onChange={(event) => setRaceQuery(event.target.value)}
                placeholder="Поиск расы…"
                aria-label="Поиск расы"
              />

              <div className="race-category-tabs" aria-label="Категории рас">
                {categories.map((category) => (
                  <button
                    key={category}
                    type="button"
                    className={raceCategory === category ? 'active' : ''}
                    onClick={() => setRaceCategory(category)}
                  >
                    {category}
                  </button>
                ))}
              </div>

              {raceLoading ? (
                <div className="race-loading">Загружаем народы Эйлара…</div>
              ) : (
                <div className="race-grid" role="radiogroup" aria-label="Выбор расы">
                  {filteredRaces.map((race) => (
                    <button
                      key={race.id}
                      type="button"
                      role="radio"
                      aria-checked={race.id === raceId}
                      aria-disabled={race.is_available === false}
                      className={
                        'race-card'
                        + (race.id === raceId ? ' selected' : '')
                        + (race.is_available === false ? ' locked' : '')
                      }
                      onClick={() => {
                        if (race.is_available !== false) setRaceId(race.id)
                      }}
                    >
                      <div className="race-card-top">
                        <strong>{race.name}</strong>
                        {race.id === raceId ? <span>✓</span> : null}
                      </div>
                      <small>{race.category}</small>
                      <p>{race.description}</p>
                      <div className="race-card-mechanics">
                        <span>{damageTypeLabels[race.innate_magic_damage_type]} · врождённая магия</span>
                        {race.hp_bonus !== 0 && <span>ОЗ {race.hp_bonus > 0 ? '+' : ''}{race.hp_bonus}</span>}
                        {race.mana_bonus !== 0 && <span>ОМ {race.mana_bonus > 0 ? '+' : ''}{race.mana_bonus}</span>}
                        {race.passive_name && <span>{race.passive_name}</span>}
                      </div>
                    </button>
                  ))}

                  {filteredRaces.length === 0 && (
                    <div className="race-empty">
                      <strong>Ничего не найдено</strong>
                      <span>Попробуй другую категорию или запрос.</span>
                    </div>
                  )}
                </div>
              )}
            </div>

            {selectedRace && (
              <div className="selected-race-details">
                <div className="section-heading">
                  <div>
                    <span className="eyebrow">РАСОВЫЕ ОСОБЕННОСТИ</span>
                    <h3>{selectedRace.name}</h3>
                  </div>
                  <span className="badge">
                    {damageTypeLabels[selectedRace.innate_magic_damage_type]}
                  </span>
                </div>

                <div className="race-mechanic-grid">
                  <span><small>Макс. ОЗ</small><strong>{selectedRace.hp_bonus >= 0 ? '+' : ''}{selectedRace.hp_bonus}</strong></span>
                  <span><small>Макс. ОМ</small><strong>{selectedRace.mana_bonus >= 0 ? '+' : ''}{selectedRace.mana_bonus}</strong></span>
                  <span><small>Реген ОЗ/ч</small><strong>{selectedRace.hp_regen_per_hour}</strong></span>
                  <span><small>Реген ОМ/ч</small><strong>{selectedRace.mana_regen_per_hour}</strong></span>
                </div>

                {Object.entries(selectedRace.damage_resistances ?? {})
                  .filter((entry): entry is [DamageType, number] => typeof entry[1] === 'number' && entry[1] !== 0)
                  .length > 0 && (
                    <div className="race-resistance-list">
                      {Object.entries(selectedRace.damage_resistances ?? {})
                        .filter((entry): entry is [DamageType, number] => typeof entry[1] === 'number' && entry[1] !== 0)
                        .map(([type, value]) => (
                          <span className={value >= 0 ? 'positive' : 'negative'} key={type}>
                            {damageTypeLabels[type]} {value >= 0 ? '+' : ''}{value}%
                          </span>
                        ))}
                    </div>
                  )}

                {raceStatLines(selectedRace).length > 0 && (
                  <div className="race-trait-list">
                    {raceStatLines(selectedRace).map(([stat, value]) => (
                      <span key={stat}>
                        {statLabels[stat as InitialStatKey]?.name ?? stat} {value > 0 ? '+' : ''}{value}
                      </span>
                    ))}
                  </div>
                )}

                {selectedRace.passive_name && (
                  <div className="race-passive-card">
                    <strong>{selectedRace.passive_name}</strong>
                    <p>{selectedRace.passive_description}</p>
                  </div>
                )}

                {raceTraitLines(selectedRace.traits).length > 0 && (
                  <div className="race-extra-traits">
                    {raceTraitLines(selectedRace.traits).map((trait, index) => (
                      <div key={trait.type + ':' + index}>
                        <strong>{trait.name}</strong>
                        <p>{trait.description}</p>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            )}

            <div className="stat-allocation-block">
              <div className="stat-allocation-heading">
                <div>
                  <span className="form-label">Характеристики</span>
                  <p className="muted">
                    Каждая характеристика начинается с 3. Распредели ещё 10 очков. При создании максимум — 8.
                  </p>
                </div>
                <div className={'stat-points-counter' + (remainingStatPoints === 0 ? ' complete' : '')}>
                  <span>Осталось</span>
                  <strong>{remainingStatPoints}</strong>
                </div>
              </div>

              <div className="initial-stats-grid">
                {(Object.keys(statLabels) as InitialStatKey[]).map((stat) => (
                  <article className="initial-stat-card" key={stat}>
                    <div className="initial-stat-copy">
                      <strong>{statLabels[stat].name}</strong>
                      <span>{statLabels[stat].description}</span>
                    </div>

                    <div className="stat-stepper">
                      <button
                        type="button"
                        aria-label={'Уменьшить ' + statLabels[stat].name}
                        disabled={stats[stat] <= INITIAL_STAT_MIN}
                        onClick={() => changeStat(stat, -1)}
                      >
                        −
                      </button>
                      <strong>{stats[stat]}</strong>
                      <button
                        type="button"
                        aria-label={'Увеличить ' + statLabels[stat].name}
                        disabled={stats[stat] >= INITIAL_STAT_MAX || remainingStatPoints <= 0}
                        onClick={() => changeStat(stat, 1)}
                      >
                        +
                      </button>
                    </div>
                  </article>
                ))}
              </div>

              <div className="stat-allocation-footer">
                <span>
                  Распределено: <strong>{spentStatPoints} / {FREE_STAT_POINTS}</strong>
                </span>
                <button
                  className="ghost-button stat-reset-button"
                  type="button"
                  disabled={spentStatPoints === 0}
                  onClick={resetStats}
                >
                  Сбросить очки
                </button>
              </div>
            </div>

            <label>
              <span>Короткая биография</span>
              <textarea
                value={bio}
                onChange={(event) => setBio(event.target.value)}
                maxLength={4000}
                rows={7}
                placeholder="Кем был персонаж до начала игры? Биография обязательна."
              />
            </label>

            <button
              className="primary-button"
              type="submit"
              disabled={busy || raceLoading || !raceId || remainingStatPoints !== 0}
            >
              {busy ? 'Создаём…' : remainingStatPoints === 0 ? 'Начать игру' : `Распредели ещё ${remainingStatPoints}`}
            </button>
          </form>

          {message && <p className="form-message" aria-live="polite">{message}</p>}
        </section>

        <aside className="panel gm-claim-card">
          <span className="eyebrow">ОТДЕЛЬНЫЙ ГМ-АККАУНТ</span>
          <h2>Вход для Game Master</h2>
          <p className="muted">
            Используй это только на отдельном аккаунте без персонажа. Код одноразовый и после активации больше не сработает.
          </p>

          <label className="gm-code-field">
            <span>Одноразовый код</span>
            <input
              value={gmCode}
              onChange={(event) => setGmCode(event.target.value)}
              placeholder="Вставь код ГМ"
              autoComplete="off"
            />
          </label>

          <button
            className="ghost-button gm-claim-button"
            type="button"
            disabled={gmBusy}
            onClick={() => void claimGm()}
          >
            {gmBusy ? 'Проверяем…' : 'Активировать ГМ'}
          </button>

          {gmMessage && <p className="form-message" aria-live="polite">{gmMessage}</p>}
        </aside>
      </div>
    </main>
  )
}
