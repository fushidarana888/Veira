import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useSmartRefresh } from '../lib/smartRefresh'
import { userFacingError } from '../lib/userError'

type Props = {
  characterId: string
  onProgressChanged?: () => Promise<unknown> | void
}

type ArenaSeason = {
  id: string
  slug: string
  name: string
  starts_at: string
  ends_at: string
  active: boolean
}

type ArenaRating = {
  mmr: number
  peak_mmr: number
  matches: number
  wins: number
  losses: number
  draws: number
  rank_slug: string
  rank_name: string
  placement_remaining: number
  season_reward_gold?: number
  enabled?: boolean
  next_rank?: {
    slug: string
    name: string
    min_mmr: number
  } | null
}

type ArenaRank = {
  slug: string
  name: string
  min_mmr: number
  milestone_gold: number
  season_gold: number
}

type ArenaHistoryEntry = {
  id: string
  created_at: string
  winner_character_id: string | null
  opponent_id: string
  opponent_name: string
  result: 'win' | 'loss' | 'draw'
  mmr_before: number
  mmr_after: number
  rounds: number
}

type ArenaLeaderboardEntry = {
  character_id: string
  name: string
  level: number
  mmr: number
  matches: number
  wins: number
  rank_slug: string
  rank_name: string
}

type ArenaOverview = {
  season: ArenaSeason | null
  solo: ArenaRating | null
  party: ArenaRating | null
  ranks: ArenaRank[]
  history: ArenaHistoryEntry[]
  leaderboard: ArenaLeaderboardEntry[]
}

type ArenaLogEntry = {
  turn: number
  actor_id: string
  actor_name: string
  action: string
  label: string
  damage: number
  healing: number
  actor_hp: number
  actor_mana: number
  target_hp: number
}

type ArenaMatchResult = {
  match_id: string
  season_id: string
  winner_character_id: string | null
  result: 'win' | 'loss' | 'draw'
  opponent: {
    character_id: string
    name: string
    level: number
    avatar_url: string | null
  }
  mmr_before: number
  mmr_after: number
  mmr_delta: number
  rank_before: string
  rank_after: string
  rank_name: string
  rank_reward_gold: number
  rounds: number
  challenger_final_hp: number
  challenger_hp_max: number
  opponent_final_hp: number
  opponent_hp_max: number
  log: ArenaLogEntry[]
}

const emptyOverview: ArenaOverview = {
  season: null,
  solo: null,
  party: null,
  ranks: [],
  history: [],
  leaderboard: [],
}

const resultLabels: Record<ArenaMatchResult['result'], string> = {
  win: 'Победа',
  loss: 'Поражение',
  draw: 'Ничья',
}

const historyLabels: Record<ArenaHistoryEntry['result'], string> = {
  win: 'Победа',
  loss: 'Поражение',
  draw: 'Ничья',
}

function arenaError(raw: string) {
  if (raw.includes('NO_ARENA_OPPONENT')) return 'Сейчас не нашлось доступного соперника. Попробуй немного позже.'
  if (raw.includes('ARENA_COOLDOWN')) return 'Матчмейкинг ещё обновляет прошлый бой. Повтори через пару секунд.'
  if (raw.includes('ARENA_SEASON_INACTIVE')) return 'Сейчас между сезонами. Рейтинговые бои временно закрыты.'
  if (raw.includes('CHARACTER_NOT_FOUND')) return 'Не удалось подтвердить персонажа для арены.'
  return userFacingError(raw)
}

function formatArenaDate(value: string) {
  return new Intl.DateTimeFormat('ru-RU', {
    day: 'numeric',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
  }).format(new Date(value))
}

function seasonRemaining(endsAt: string) {
  const ms = new Date(endsAt).getTime() - Date.now()
  if (ms <= 0) return 'сезон завершён'
  const days = Math.floor(ms / 86_400_000)
  const hours = Math.floor((ms % 86_400_000) / 3_600_000)
  if (days > 0) return `${days} д ${hours} ч`
  return `${Math.max(1, hours)} ч`
}

function hpPercent(current: number, max: number) {
  return max > 0 ? Math.max(0, Math.min(100, Math.round(current * 100 / max))) : 0
}

export function ArenaPanel({ characterId, onProgressChanged }: Props) {
  const [overview, setOverview] = useState<ArenaOverview>(emptyOverview)
  const [lastMatch, setLastMatch] = useState<ArenaMatchResult | null>(null)
  const [loading, setLoading] = useState(true)
  const [fighting, setFighting] = useState(false)
  const [message, setMessage] = useState('')

  async function loadOverview(silent = false) {
    if (!silent) setLoading(true)

    const { data, error } = await supabase.rpc('get_arena_overview', {
      p_character_id: characterId,
    })

    if (error) {
      setMessage(arenaError(error.message))
    } else {
      setOverview((data as ArenaOverview | null) ?? emptyOverview)
    }

    if (!silent) setLoading(false)
  }

  useEffect(() => {
    void loadOverview()
  }, [characterId])

  useSmartRefresh(
    () => loadOverview(true),
    { enabled: true, intervalMs: 20_000, minGapMs: 2_000 },
  )

  async function findSoloMatch() {
    if (fighting) return
    setFighting(true)
    setMessage('')

    const { data, error } = await supabase.rpc('play_solo_arena_match', {
      p_character_id: characterId,
    })

    if (error) {
      setMessage(arenaError(error.message))
    } else {
      const result = data as ArenaMatchResult
      setLastMatch(result)
      await Promise.all([
        loadOverview(true),
        Promise.resolve(onProgressChanged?.()),
      ])
      if (result.rank_reward_gold > 0) {
        setMessage(`Новый ранг! Награда: +${result.rank_reward_gold} золота.`)
      }
    }

    setFighting(false)
  }

  const solo = overview.solo
  const season = overview.season
  const record = solo ? `${solo.wins}–${solo.losses}–${solo.draws}` : '—'
  const nextRankProgress = useMemo(() => {
    if (!solo || !solo.next_rank || solo.placement_remaining > 0) return null
    const currentRank = [...overview.ranks]
      .filter((rank) => rank.min_mmr <= solo.mmr)
      .sort((a, b) => b.min_mmr - a.min_mmr)[0]
    const start = currentRank?.min_mmr ?? 0
    const span = Math.max(1, solo.next_rank.min_mmr - start)
    return Math.max(0, Math.min(100, Math.round((solo.mmr - start) * 100 / span)))
  }, [solo, overview.ranks])

  if (loading) {
    return (
      <section className="panel arena-loading">
        <span className="eyebrow">АРЕНА</span>
        <h3>Поднимаем ворота арены…</h3>
        <p className="muted">Загружаем сезон, рейтинг и соперников.</p>
      </section>
    )
  }

  return (
    <div className="arena-section">
      <section className="panel arena-hero">
        <div className="arena-hero-copy">
          <span className="eyebrow">РЕЙТИНГОВАЯ АРЕНА · АВТОБОЙ</span>
          <h2>{season?.name ?? 'Арена'}</h2>
          <p className="muted">
            Система подбирает соперника по MMR. Оба персонажа сражаются автоматически,
            используя текущий билд и настройки автобоя. Обычные дуэли на рейтинг не влияют.
          </p>
        </div>
        <div className="arena-season-chip">
          <span>До конца сезона</span>
          <strong>{season ? seasonRemaining(season.ends_at) : '—'}</strong>
          {season && <small>{formatArenaDate(season.ends_at)}</small>}
        </div>
      </section>

      {message && <p className="gm-notice arena-notice" role="status" aria-live="polite">{message}</p>}

      <div className="arena-rating-grid">
        <section className="panel arena-rating-card active">
          <div className="arena-rating-head">
            <div>
              <span className="eyebrow">SOLO MMR</span>
              <h3>{solo?.rank_name ?? '—'}</h3>
            </div>
            <div className="arena-mmr">
              <strong>{solo?.mmr ?? '—'}</strong>
              <span>MMR</span>
            </div>
          </div>

          {solo && solo.placement_remaining > 0 ? (
            <div className="arena-calibration">
              <strong>Калибровка</strong>
              <span>Осталось боёв: {solo.placement_remaining}</span>
              <div className="arena-placement-dots" aria-label={`Калибровка: ${solo.matches} из 5`}>
                {Array.from({ length: 5 }, (_, index) => (
                  <i className={index < solo.matches ? 'done' : ''} key={index} />
                ))}
              </div>
            </div>
          ) : solo?.next_rank ? (
            <div className="arena-rank-progress">
              <div>
                <span>Следующий ранг</span>
                <strong>{solo.next_rank.name} · {solo.next_rank.min_mmr}</strong>
              </div>
              <div className="arena-progress-track">
                <span style={{ width: `${nextRankProgress ?? 0}%` }} />
              </div>
            </div>
          ) : (
            <p className="arena-max-rank">Высший ранг сезона достигнут.</p>
          )}

          <div className="arena-record">
            <span><b>{record}</b><small>Победы · поражения · ничьи</small></span>
            <span><b>{solo?.peak_mmr ?? '—'}</b><small>Пиковый MMR</small></span>
            <span><b>{solo?.season_reward_gold ?? 0}</b><small>Награда сезона</small></span>
          </div>

          <button
            className="primary-button arena-search-button"
            type="button"
            disabled={fighting || !season?.active}
            onClick={() => void findSoloMatch()}
          >
            {fighting ? 'Идёт автобой…' : solo?.placement_remaining ? 'Найти калибровочный бой' : 'Найти рейтинговый бой'}
          </button>
          <small className="arena-search-note">
            Соперника выбирает система. Результат считается на сервере и сразу меняет MMR обоих персонажей.
          </small>
        </section>

        <section className="panel arena-rating-card future">
          <div className="arena-rating-head">
            <div>
              <span className="eyebrow">PARTY MMR</span>
              <h3>{overview.party?.rank_name ?? 'Калибровка'}</h3>
            </div>
            <div className="arena-mmr">
              <strong>{overview.party?.mmr ?? 1000}</strong>
              <span>MMR</span>
            </div>
          </div>
          <p>
            Командный рейтинг уже отделён от solo MMR. Когда включим party arena,
            совместные бои не будут менять личный рейтинг.
          </p>
          <div className="arena-future-tag">Командные матчи · следующий этап</div>
          <small>
            Guild MMR тоже заложен отдельно: рейтинг гильдии не будет суммой рейтингов её участников.
          </small>
        </section>
      </div>

      {lastMatch && (
        <section className={'panel arena-result ' + lastMatch.result}>
          <div className="arena-result-head">
            <div>
              <span className="eyebrow">ПОСЛЕДНИЙ БОЙ</span>
              <h3>{resultLabels[lastMatch.result]} · против {lastMatch.opponent.name}</h3>
              <p className="muted">
                {lastMatch.rounds} действий · соперник {lastMatch.opponent.level} ур.
              </p>
            </div>
            <div className={'arena-mmr-delta ' + (lastMatch.mmr_delta > 0 ? 'positive' : lastMatch.mmr_delta < 0 ? 'negative' : '')}>
              <strong>{lastMatch.mmr_delta > 0 ? '+' : ''}{lastMatch.mmr_delta}</strong>
              <span>{lastMatch.mmr_before} → {lastMatch.mmr_after}</span>
            </div>
          </div>

          <div className="arena-result-fighters">
            <ArenaHp
              label="Ты"
              current={lastMatch.challenger_final_hp}
              max={lastMatch.challenger_hp_max}
            />
            <span className="arena-result-vs">VS</span>
            <ArenaHp
              label={lastMatch.opponent.name}
              current={lastMatch.opponent_final_hp}
              max={lastMatch.opponent_hp_max}
            />
          </div>

          {lastMatch.rank_before !== lastMatch.rank_after && (
            <div className="arena-rank-up">
              Новый ранг: <strong>{lastMatch.rank_name}</strong>
              {lastMatch.rank_reward_gold > 0 && <> · +{lastMatch.rank_reward_gold} золота</>}
            </div>
          )}

          <details className="arena-combat-log">
            <summary>Показать ход автобоя</summary>
            <div>
              {lastMatch.log.map((entry) => (
                <article key={entry.turn}>
                  <span>#{entry.turn}</span>
                  <div>
                    <strong>{entry.actor_name} · {entry.label}</strong>
                    <small>
                      {entry.damage > 0 ? `${entry.damage} урона` : entry.healing > 0 ? `+${entry.healing} ОЗ` : 'подготовка'}
                      {' · '}ОЗ {entry.actor_hp} · ОМ {entry.actor_mana}
                    </small>
                  </div>
                </article>
              ))}
            </div>
          </details>
        </section>
      )}

      <div className="arena-lower-grid">
        <section className="panel arena-leaderboard">
          <div className="section-heading">
            <div>
              <span className="eyebrow">ТАБЛИЦА СЕЗОНА</span>
              <h3>Solo-рейтинг</h3>
            </div>
            <button className="ghost-button" type="button" onClick={() => void loadOverview()}>
              Обновить
            </button>
          </div>

          <div className="arena-leaderboard-list">
            {overview.leaderboard.map((entry, index) => (
              <div className={'arena-leaderboard-row ' + (entry.character_id === characterId ? 'self' : '')} key={entry.character_id}>
                <b>{index + 1}</b>
                <div>
                  <strong>{entry.name}</strong>
                  <small>{entry.level} ур. · {entry.rank_name}</small>
                </div>
                <span>{entry.mmr}</span>
              </div>
            ))}
          </div>
        </section>

        <section className="panel arena-history">
          <span className="eyebrow">ИСТОРИЯ</span>
          <h3>Последние матчи</h3>
          {overview.history.length === 0 ? (
            <p className="muted">Рейтинговых боёв пока не было.</p>
          ) : (
            <div className="arena-history-list">
              {overview.history.map((entry) => {
                const delta = entry.mmr_after - entry.mmr_before
                return (
                  <article className={'arena-history-row ' + entry.result} key={entry.id}>
                    <div>
                      <strong>{historyLabels[entry.result]} · {entry.opponent_name}</strong>
                      <small>{formatArenaDate(entry.created_at)} · {entry.rounds} действий</small>
                    </div>
                    <span>{delta > 0 ? '+' : ''}{delta}</span>
                  </article>
                )
              })}
            </div>
          )}
        </section>
      </div>

      <section className="panel arena-ranks">
        <div className="section-heading">
          <div>
            <span className="eyebrow">РАНГИ И НАГРАДЫ</span>
            <h3>Лестница сезона</h3>
          </div>
          <p className="muted">Награда за ранг выдаётся один раз при первом достижении за сезон.</p>
        </div>
        <div className="arena-rank-list">
          {overview.ranks.map((rank) => (
            <article className={'arena-rank-row rank-' + rank.slug} key={rank.slug}>
              <div>
                <strong>{rank.name}</strong>
                <span>от {rank.min_mmr} MMR</span>
              </div>
              <div>
                <span>Достижение <b>+{rank.milestone_gold}</b></span>
                <span>Конец сезона <b>+{rank.season_gold}</b></span>
              </div>
            </article>
          ))}
        </div>
      </section>
    </div>
  )
}

function ArenaHp({ label, current, max }: { label: string, current: number, max: number }) {
  return (
    <div className="arena-hp">
      <div>
        <strong>{label}</strong>
        <span>{current} / {max}</span>
      </div>
      <div className="arena-hp-track">
        <span style={{ width: `${hpPercent(current, max)}%` }} />
      </div>
    </div>
  )
}
