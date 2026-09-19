import { FormEvent, useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { RaceDefinition } from '../types'

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

const defaultStats: Record<InitialStatKey, number> = {
  strength: INITIAL_STAT_MIN,
  agility: INITIAL_STAT_MIN,
  intellect: INITIAL_STAT_MIN,
  vitality: INITIAL_STAT_MIN,
  luck: INITIAL_STAT_MIN,
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
      const { data, error } = await supabase
        .from('race_definitions')
        .select('id, slug, name, category, description, sort_order, playable, stat_modifiers, traits')
        .eq('playable', true)
        .order('sort_order', { ascending: true })

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

    const { error } = await supabase.from('characters').insert({
      owner_user_id: userId,
      name: name.trim(),
      race_id: raceId,
      bio: bio.trim(),
      initial_strength: stats.strength,
      initial_agility: stats.agility,
      initial_intellect: stats.intellect,
      initial_vitality: stats.vitality,
      initial_luck: stats.luck,
    })

    if (error) {
      const raw = error.message

      if (raw.includes('characters_initial_stats_total')) {
        setMessage('Нужно распределить ровно 10 свободных очков.')
      } else if (raw.includes('characters_initial_') && raw.includes('_range')) {
        setMessage('При создании каждая характеристика должна быть от 3 до 8.')
      } else if (raw.includes('characters_one_per_owner_idx')) {
        setMessage('На этом аккаунте уже есть персонаж.')
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
      setGmMessage('Введи одноразовый код GM.')
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
          setGmMessage('GM-аккаунт должен быть отдельным и не иметь игрового персонажа.')
        } else {
          setGmMessage(raw)
        }
        return
      }

      setGmMessage('GM-доступ активирован.')
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
                  <p className="muted">Раса выбирается из народов Эйлара. Характеристики и расовые особенности добавим позже.</p>
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
                      className={'race-card' + (race.id === raceId ? ' selected' : '')}
                      onClick={() => setRaceId(race.id)}
                    >
                      <div className="race-card-top">
                        <strong>{race.name}</strong>
                        {race.id === raceId && <span>✓</span>}
                      </div>
                      <small>{race.category}</small>
                      <p>{race.description}</p>
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
                placeholder="Кем был персонаж до начала игры?"
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
          <span className="eyebrow">ОТДЕЛЬНЫЙ GM-АККАУНТ</span>
          <h2>Вход для Game Master</h2>
          <p className="muted">
            Используй это только на отдельном аккаунте без персонажа. Код одноразовый и после активации больше не сработает.
          </p>

          <label className="gm-code-field">
            <span>Одноразовый код</span>
            <input
              value={gmCode}
              onChange={(event) => setGmCode(event.target.value)}
              placeholder="Вставь GM-код"
              autoComplete="off"
            />
          </label>

          <button
            className="ghost-button gm-claim-button"
            type="button"
            disabled={gmBusy}
            onClick={() => void claimGm()}
          >
            {gmBusy ? 'Проверяем…' : 'Активировать GM'}
          </button>

          {gmMessage && <p className="form-message" aria-live="polite">{gmMessage}</p>}
        </aside>
      </div>
    </main>
  )
}
