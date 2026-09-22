import { userFacingError } from '../lib/userError'
import { criticalHitCount } from '../lib/combatPresentation'
import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useSmartRefresh } from '../lib/smartRefresh'
import type { BowDistance, BowProfile, CharacterSpell, CombatStatusEffectType } from '../types'

function isBowProfile(profile: BowProfile | null | undefined): profile is BowProfile & { weapon_family: 'short_bow' | 'long_bow' } {
  return profile?.weapon_family === 'short_bow' || profile?.weapon_family === 'long_bow'
}

type Props = {
  characterId: string
}

type DuelPlayer = {
  character_id: string
  name: string
  race: string
  avatar_url: string | null
  display_name: string
  level: number
  busy: boolean
}

type DuelSummary = {
  id: string
  status: 'pending' | 'active' | 'completed' | 'declined' | 'cancelled'
  challenger_character_id: string
  opponent_character_id: string
  winner_character_id: string | null
  current_turn_character_id: string | null
  round: number
  finish_reason: string
  created_at: string
  started_at: string | null
  ended_at: string | null
  turn_started_at: string | null
  challenger_name: string
  challenger_display_name: string
  opponent_name: string
  opponent_display_name: string
  winner_name: string | null
}

type DuelOverview = {
  players: DuelPlayer[]
  duels: DuelSummary[]
}

type DuelParticipant = {
  character_id: string
  side: 'challenger' | 'opponent'
  name: string
  race: string
  avatar_url: string | null
  display_name: string
  level: number
  hp_current: number
  hp_max: number
  mana_current: number
  mana_max: number
  physical_power: number
  magic_power: number
  defense: number
  physical_defense: number
  magic_defense: number
  initiative: number
  initiative_meter: number
  weapon_damage_type: string
  magic_damage_type: string
  guard_reduction_percent: number
  counter_bonus_percent: number
  spell_damage_bonus_percent: number
  spell_damage_bonus_hits: number
  bow_distance: BowDistance
  bow_draw_pending: boolean
  bloodshed_stacks: number
}

type DuelTurn = {
  id: number
  round: number
  actor_character_id: string | null
  action_type: string
  damage: number
  healing: number
  message: string
  created_at: string
  actor_name: string | null
}

type DuelStatus = {
  id: string
  target_character_id: string
  effect_type: CombatStatusEffectType
  potency: number
  remaining_turns: number
  source_character_id: string | null
}

type DuelDetails = {
  duel: {
    id: string
    status: DuelSummary['status']
    challenger_character_id: string
    opponent_character_id: string
    winner_character_id: string | null
    current_turn_character_id: string | null
    round: number
    finish_reason: string
    created_at: string
    started_at: string | null
    ended_at: string | null
    turn_started_at: string | null
  }
  participants: DuelParticipant[]
  turns: DuelTurn[]
  statuses: DuelStatus[]
}

const statusLabels: Record<CombatStatusEffectType, string> = {
  burn: 'Горение',
  bleed: 'Кровотечение',
  poison: 'Яд',
  chill: 'Охлаждение',
  stun: 'Оглушение',
  weaken: 'Ослабление',
  vulnerable: 'Уязвимость',
}

function duelError(raw: string) {
  if (raw.includes('CHALLENGER_BUSY')) return 'Сначала заверши активное подземелье, бой с противником или другую дуэль.'
  if (raw.includes('OPPONENT_BUSY')) return 'Этот персонаж сейчас в подземелье, бою с противником или другой дуэли.'
  if (raw.includes('PLAYER_BUSY')) return 'Один из участников занят тяжёлым боем или другой дуэлью. Обнови список и попробуй позже.'
  if (raw.includes('DUEL_ALREADY_PENDING')) return 'Между вами уже есть необработанный вызов.'
  if (raw.includes('TOO_MANY_PENDING_DUELS')) return 'Слишком много исходящих вызовов. Отмени часть из них.'
  if (raw.includes('CANNOT_DUEL_SELF')) return 'Нельзя вызвать на дуэль самого себя.'
  if (raw.includes('NOT_YOUR_TURN')) return 'Сейчас ход соперника.'
  if (raw.includes('NOT_ENOUGH_MANA')) return 'Недостаточно маны.'
  if (raw.includes('ALREADY_FULL_HEALTH')) return 'Здоровье уже полное.'
  if (raw.includes('SPELL_NOT_IN_LOADOUT')) return 'Это заклинание не входит в текущий боевой набор.'
  if (raw.includes('SPELL_NOT_LEARNED')) return 'Это заклинание не изучено.'
  if (raw.includes('DUEL_NOT_ACTIVE')) return 'Эта дуэль уже завершена.'
  if (raw.includes('DUEL_NOT_PENDING')) return 'Этот вызов уже обработан.'
  return userFacingError(raw)
}

function spellKindLabel(kind: CharacterSpell['spell_kind']) {
  if (kind === 'heal') return 'лечение'
  if (kind === 'guard') return 'щит'
  if (kind === 'cleanse') return 'очищение'
  if (kind === 'buff') return 'усиление'
  return 'атака'
}

function hpPercent(current: number, max: number) {
  return max > 0 ? Math.max(0, Math.min(100, Math.round(current * 100 / max))) : 0
}

function duelResultLabel(duel: DuelSummary, characterId: string) {
  if (duel.status === 'completed') {
    return duel.winner_character_id === characterId ? 'Победа' : 'Поражение'
  }
  if (duel.status === 'declined') return 'Отклонена'
  if (duel.status === 'cancelled') return 'Отменена'
  return duel.status
}

export function DuelPanel({ characterId }: Props) {
  const [overview, setOverview] = useState<DuelOverview>({ players: [], duels: [] })
  const [details, setDetails] = useState<DuelDetails | null>(null)
  const [spells, setSpells] = useState<CharacterSpell[]>([])
  const [bowProfile, setBowProfile] = useState<BowProfile | null>(null)
  const [query, setQuery] = useState('')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState('')
  const [message, setMessage] = useState('')

  async function loadStaticCombatData() {
    const [spellsResult, bowProfileResult] = await Promise.all([
      supabase.rpc('get_character_spells', { p_character_id: characterId }),
      supabase.rpc('get_character_bow_profile', { p_character_id: characterId }),
    ])

    const error = spellsResult.error ?? bowProfileResult.error
    if (error) {
      setMessage(duelError(error.message))
      return
    }

    setSpells(
      ((spellsResult.data as CharacterSpell[] | null) ?? [])
        .filter((spell) => (
          spell.combat_slot !== null
          && ['damage', 'heal', 'guard', 'cleanse', 'buff'].includes(spell.spell_kind)
        )),
    )
    setBowProfile((bowProfileResult.data as BowProfile | null) ?? null)
  }

  async function loadDynamic(silent = false) {
    if (!silent) setLoading(true)

    const overviewResult = await supabase.rpc('get_duel_overview', {
      p_character_id: characterId,
    })

    if (overviewResult.error) {
      setMessage(duelError(overviewResult.error.message))
      if (!silent) setLoading(false)
      return
    }

    const nextOverview = (overviewResult.data as DuelOverview | null) ?? { players: [], duels: [] }
    setOverview(nextOverview)

    const active = nextOverview.duels.find((duel) => duel.status === 'active') ?? null
    if (active) {
      const detailResult = await supabase.rpc('get_pvp_duel', { p_duel_id: active.id })
      if (detailResult.error) {
        setMessage(duelError(detailResult.error.message))
      } else {
        setDetails((detailResult.data as DuelDetails | null) ?? null)
      }
    } else {
      setDetails(null)
    }

    if (!silent) setLoading(false)
  }

  useEffect(() => {
    setLoading(true)
    void Promise.all([
      loadStaticCombatData(),
      loadDynamic(true),
    ]).finally(() => setLoading(false))
  }, [characterId])

  useSmartRefresh(
    () => loadDynamic(true),
    {
      enabled: true,
      intervalMs: details?.duel?.status === 'active' ? 3500 : 12000,
      minGapMs: details?.duel?.status === 'active' ? 700 : 1800,
    },
  )

  const activeSummary = overview.duels.find((duel) => duel.status === 'active') ?? null
  const incoming = overview.duels.filter(
    (duel) => duel.status === 'pending' && duel.opponent_character_id === characterId,
  )
  const outgoing = overview.duels.filter(
    (duel) => duel.status === 'pending' && duel.challenger_character_id === characterId,
  )
  const history = overview.duels.filter(
    (duel) => ['completed', 'declined', 'cancelled'].includes(duel.status),
  )

  const pendingPlayerIds = useMemo(() => {
    const ids = new Set<string>()
    for (const duel of [...incoming, ...outgoing]) {
      ids.add(
        duel.challenger_character_id === characterId
          ? duel.opponent_character_id
          : duel.challenger_character_id,
      )
    }
    return ids
  }, [incoming, outgoing, characterId])

  const filteredPlayers = useMemo(() => {
    const needle = query.trim().toLocaleLowerCase('ru-RU')
    if (!needle) return overview.players

    return overview.players.filter((player) =>
      [player.name, player.display_name, player.race]
        .some((value) => value.toLocaleLowerCase('ru-RU').includes(needle)),
    )
  }, [overview.players, query])

  const mine = details?.participants.find((participant) => participant.character_id === characterId) ?? null
  const opponent = details?.participants.find((participant) => participant.character_id !== characterId) ?? null
  const myTurn = details?.duel.status === 'active'
    && details.duel.current_turn_character_id === characterId

  const myStatuses = details?.statuses.filter((status) => status.target_character_id === characterId) ?? []
  const opponentStatuses = opponent
    ? details?.statuses.filter((status) => status.target_character_id === opponent.character_id) ?? []
    : []

  async function challenge(player: DuelPlayer) {
    setBusy('challenge-' + player.character_id)
    setMessage('')

    const { error } = await supabase.rpc('challenge_character_to_duel', {
      p_challenger_character_id: characterId,
      p_opponent_character_id: player.character_id,
    })

    if (error) {
      setMessage(duelError(error.message))
    } else {
      setMessage('Вызов отправлен.')
      await loadDynamic(true)
    }

    setBusy('')
  }

  async function respond(duelId: string, accept: boolean) {
    setBusy((accept ? 'accept-' : 'decline-') + duelId)
    setMessage('')

    const { error } = await supabase.rpc('respond_to_duel', {
      p_duel_id: duelId,
      p_accept: accept,
    })

    if (error) {
      setMessage(duelError(error.message))
    } else {
      setMessage(accept ? 'Дуэль началась.' : 'Вызов отклонён.')
      await loadDynamic(true)
    }

    setBusy('')
  }

  async function cancelInvite(duelId: string) {
    setBusy('cancel-' + duelId)
    setMessage('')

    const { error } = await supabase.rpc('cancel_duel_invite', {
      p_duel_id: duelId,
    })

    if (error) {
      setMessage(duelError(error.message))
    } else {
      setMessage('Вызов отменён.')
      await loadDynamic(true)
    }

    setBusy('')
  }

  async function act(action: 'physical' | 'bow_draw' | 'magic' | 'guard' | 'spell', spellId: string | null = null) {
    if (!details || !myTurn) return

    setBusy('action')
    setMessage('')

    const { data, error } = await supabase.rpc('perform_pvp_duel_action', {
      p_duel_id: details.duel.id,
      p_action: action,
      p_spell_id: spellId,
    })

    if (error) {
      setMessage(duelError(error.message))
    } else {
      setDetails((data as DuelDetails | null) ?? null)
      await loadDynamic(true)
    }

    setBusy('')
  }

  async function setBowDistance(distance: BowDistance) {
    if (!details || !myTurn || !mine || !isBowProfile(bowProfile) || mine.bow_draw_pending) return

    setBusy('action')
    setMessage('')
    const { data, error } = await supabase.rpc('set_pvp_bow_distance', {
      p_duel_id: details.duel.id,
      p_distance: distance,
    })

    if (error) setMessage(duelError(error.message))
    else setDetails((data as DuelDetails | null) ?? null)

    setBusy('')
  }

  async function surrender() {
    if (!details) return

    setBusy('surrender')
    setMessage('')

    const { error } = await supabase.rpc('surrender_pvp_duel', {
      p_duel_id: details.duel.id,
    })

    if (error) {
      setMessage(duelError(error.message))
    } else {
      setMessage('Вы признали поражение.')
      await loadDynamic(true)
    }

    setBusy('')
  }

  if (loading) {
    return (
      <section className="panel duel-panel">
        <span className="eyebrow">ДУЭЛИ</span>
        <p className="muted">Загружаем игроков и вызовы…</p>
      </section>
    )
  }

  return (
    <div className="duel-section">
      <section className="panel duel-intro">
        <div className="section-heading">
          <div>
            <span className="eyebrow">ИГРОК ПРОТИВ ИГРОКА · ДУЭЛИ</span>
            <h2>Поединки между персонажами</h2>
            <p className="muted">
              Дуэль начинается только после согласия второго игрока. Используются текущие характеристики,
              экипировка, сопротивления и изученные заклинания.
            </p>
          </div>
          <span className={'badge ' + (activeSummary ? 'ready' : '')}>
            {activeSummary ? 'идёт бой' : 'свободен'}
          </span>
        </div>

        <p className="duel-safe-note">
          Дуэль изолирована от приключений: бой начинается с полных дуэльных ОЗ/ОМ, не меняет реальное здоровье
          и ману, не расходует предметы и не выдаёт золото, опыт или лут.
        </p>

        {message && <p className="form-message" aria-live="polite">{message}</p>}
      </section>

      {details?.duel.status === 'active' && mine && opponent && (
        <section className="panel duel-arena">
          <div className="duel-arena-heading">
            <div>
              <span className="eyebrow">АКТИВНАЯ ДУЭЛЬ · ХОД {details.duel.round}</span>
              <h2>{mine.name} <span>vs</span> {opponent.name}</h2>
            </div>
            <span className={'badge ' + (myTurn ? 'ready' : '')}>
              {myTurn ? 'ваш ход' : 'ход соперника'}
            </span>
          </div>

          <div className="duel-fighters">
            <DuelFighter participant={mine} statuses={myStatuses} own />
            <div className="duel-vs">VS</div>
            <DuelFighter participant={opponent} statuses={opponentStatuses} />
          </div>

          {isBowProfile(bowProfile) && (
            <div className="duel-turn-help">
              <strong>Дистанция лучника:</strong>{' '}
              {([
                ['close', 'Ближняя · +10% урон · +3% dodge'],
                ['medium', 'Средняя · +9% dodge'],
                ['far', 'Дальняя · −10% урон · +15% dodge'],
              ] as Array<[BowDistance, string]>).map(([distance, label]) => (
                <button
                  className={mine.bow_distance === distance ? 'primary-button' : 'ghost-button'}
                  type="button"
                  key={distance}
                  disabled={!myTurn || busy === 'action' || mine.bow_draw_pending}
                  onClick={() => void setBowDistance(distance)}
                >
                  {label}
                </button>
              ))}
              {mine.bow_draw_pending && <span> · Натяг подготовлен, дистанция зафиксирована.</span>}
            </div>
          )}

          <div className="duel-actions">
            {isBowProfile(bowProfile) ? (
              mine.bow_draw_pending ? (
                <button className="primary-button" type="button" disabled={!myTurn || busy === 'action'} onClick={() => void act('physical')}>
                  Выпустить стрелу · полный натяг
                </button>
              ) : (
                <>
                  {bowProfile.weapon_family === 'short_bow' && (
                    <button className="primary-button" type="button" disabled={!myTurn || busy === 'action'} onClick={() => void act('physical')}>
                      Быстрый выстрел
                    </button>
                  )}
                  <button className="primary-button" type="button" disabled={!myTurn || busy === 'action'} onClick={() => void act('bow_draw')}>
                    Полный натяг · пробитие {bowProfile.full_draw_armor_penetration_percent}%
                  </button>
                </>
              )
            ) : (
              <button
                className="primary-button"
                type="button"
                disabled={!myTurn || busy === 'action'}
                onClick={() => void act('physical')}
              >
                Физическая атака
              </button>
            )}
            <button
              className="primary-button"
              type="button"
              disabled={!myTurn || busy === 'action' || mine.bow_draw_pending}
              onClick={() => void act('magic')}
            >
              Врождённая магия
            </button>
            <button
              className="ghost-button"
              type="button"
              disabled={!myTurn || busy === 'action' || mine.bow_draw_pending}
              onClick={() => void act('guard')}
            >
              Защита
            </button>
          </div>

          {spells.length > 0 && (
            <div className="duel-spells">
              <strong>Изученные заклинания</strong>
              <div>
                {spells.map((spell) => (
                  <button
                    className="spell-action-button"
                    type="button"
                    key={spell.id}
                    disabled={!myTurn || busy === 'action' || mine.bow_draw_pending || (mine.mana_current < spell.mana_cost)}
                    onClick={() => void act('spell', spell.id)}
                  >
                    <span>{spell.name}</span>
                    <small>{spellKindLabel(spell.spell_kind)} · {spell.mana_cost} ОМ</small>
                  </button>
                ))}
              </div>
            </div>
          )}

          <div className="duel-turn-help">
            {myTurn
              ? 'Выбери действие. Оглушение автоматически съест текущий ход, если эффект ещё активен.'
              : 'Интерфейс обновляется автоматически — ход появится здесь, когда соперник ответит.'}
          </div>

          <div className="duel-log">
            <div className="section-heading">
              <div>
                <span className="eyebrow">ЖУРНАЛ</span>
                <h3>Последние действия</h3>
              </div>
            </div>
            {[...details.turns].reverse().map((turn) => {
              const criticalHits = criticalHitCount(turn.message)
              return (
                <div className={'duel-log-row' + (criticalHits > 0 ? ' critical-hit' : '')} key={turn.id}>
                  <span>#{turn.round}</span>
                  <div className="combat-log-message">
                    {criticalHits > 0 && (
                      <b className="critical-hit-badge">КРИТ{criticalHits > 1 ? ' ×' + criticalHits : ''}</b>
                    )}
                    <p>{turn.message}</p>
                  </div>
                </div>
              )
            })}
          </div>

          <button
            className="ghost-button duel-surrender"
            type="button"
            disabled={busy === 'surrender'}
            onClick={() => void surrender()}
          >
            Признать поражение
          </button>
        </section>
      )}

      {incoming.length > 0 && (
        <section className="panel">
          <div className="section-heading">
            <div>
              <span className="eyebrow">ВХОДЯЩИЕ</span>
              <h2>Вызовы на дуэль</h2>
            </div>
            <span className="badge">{incoming.length}</span>
          </div>

          <div className="duel-request-list">
            {incoming.map((duel) => (
              <article className="duel-request-card" key={duel.id}>
                <div>
                  <strong>{duel.challenger_name}</strong>
                  <span>@{duel.challenger_display_name}</span>
                </div>
                <div className="duel-request-actions">
                  <button
                    className="primary-button"
                    type="button"
                    disabled={Boolean(activeSummary) || busy !== ''}
                    onClick={() => void respond(duel.id, true)}
                  >
                    Принять
                  </button>
                  <button
                    className="ghost-button"
                    type="button"
                    disabled={busy !== ''}
                    onClick={() => void respond(duel.id, false)}
                  >
                    Отклонить
                  </button>
                </div>
              </article>
            ))}
          </div>
        </section>
      )}

      {outgoing.length > 0 && (
        <section className="panel">
          <div className="section-heading">
            <div>
              <span className="eyebrow">ИСХОДЯЩИЕ</span>
              <h2>Ожидают ответа</h2>
            </div>
            <span className="badge">{outgoing.length}</span>
          </div>

          <div className="duel-request-list">
            {outgoing.map((duel) => (
              <article className="duel-request-card" key={duel.id}>
                <div>
                  <strong>{duel.opponent_name}</strong>
                  <span>@{duel.opponent_display_name}</span>
                </div>
                <button
                  className="ghost-button"
                  type="button"
                  disabled={busy !== ''}
                  onClick={() => void cancelInvite(duel.id)}
                >
                  Отменить вызов
                </button>
              </article>
            ))}
          </div>
        </section>
      )}

      <section className="panel duel-players-panel">
        <div className="section-heading">
          <div>
            <span className="eyebrow">ИГРОКИ</span>
            <h2>Кого вызвать</h2>
          </div>
          <span className="badge">{overview.players.length}</span>
        </div>

        <input
          className="duel-search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Имя персонажа, аккаунт или раса"
        />

        {filteredPlayers.length === 0 ? (
          <p className="muted">
            {overview.players.length === 0
              ? 'Пока нет других персонажей, которых можно показать.'
              : 'По этому запросу никого не найдено.'}
          </p>
        ) : (
          <div className="duel-player-grid">
            {filteredPlayers.map((player) => {
              const pending = pendingPlayerIds.has(player.character_id)
              return (
                <article className="duel-player-card" key={player.character_id}>
                  <div className="duel-player-identity">
                    <div className="avatar-placeholder" aria-hidden="true">
                      {player.name.slice(0, 1).toUpperCase()}
                    </div>
                    <div>
                      <strong>{player.name}</strong>
                      <span>@{player.display_name} · {player.race}</span>
                    </div>
                  </div>

                  <div className="duel-player-meta">
                    <span>УР. {player.level}</span>
                    <span className={player.busy ? 'busy' : 'ready'}>
                      {player.busy ? 'занят' : 'свободен'}
                    </span>
                  </div>

                  <button
                    className="primary-button"
                    type="button"
                    disabled={player.busy || pending || Boolean(activeSummary) || busy !== ''}
                    onClick={() => void challenge(player)}
                  >
                    {pending ? 'Вызов отправлен' : player.busy ? 'Сейчас недоступен' : 'Вызвать на дуэль'}
                  </button>
                </article>
              )
            })}
          </div>
        )}
      </section>

      {history.length > 0 && (
        <section className="panel">
          <div className="section-heading">
            <div>
              <span className="eyebrow">ИСТОРИЯ</span>
              <h2>Последние дуэли</h2>
            </div>
          </div>

          <div className="duel-history">
            {history.slice(0, 12).map((duel) => {
              const opponentName = duel.challenger_character_id === characterId
                ? duel.opponent_name
                : duel.challenger_name
              const label = duelResultLabel(duel, characterId)

              return (
                <div className="duel-history-row" key={duel.id}>
                  <div>
                    <strong>{opponentName}</strong>
                    <span>{new Date(duel.created_at).toLocaleString('ru-RU')}</span>
                  </div>
                  <b className={
                    label === 'Победа' ? 'win'
                      : label === 'Поражение' ? 'loss'
                        : ''
                  }>
                    {label}
                  </b>
                </div>
              )
            })}
          </div>
        </section>
      )}
    </div>
  )
}

function DuelFighter({
  participant,
  statuses,
  own = false,
}: {
  participant: DuelParticipant
  statuses: DuelStatus[]
  own?: boolean
}) {
  return (
    <article className={'duel-fighter-card ' + (own ? 'own' : '')}>
      <div className="duel-fighter-name">
        <div>
          <strong>{participant.name}</strong>
          <span>@{participant.display_name} · УР. {participant.level}</span>
        </div>
        {participant.counter_bonus_percent > 0 && (
          <span className="duel-counter">контратака +{participant.counter_bonus_percent}%</span>
        )}
      </div>

      <div className="duel-resource">
        <div><span>ОЗ</span><strong>{participant.hp_current} / {participant.hp_max}</strong></div>
        <div className="meter"><span style={{ width: hpPercent(participant.hp_current, participant.hp_max) + '%' }} /></div>
      </div>

      <div className="duel-resource">
        <div><span>ОМ</span><strong>{participant.mana_current} / {participant.mana_max}</strong></div>
        <div className="meter mana-meter"><span style={{ width: hpPercent(participant.mana_current, participant.mana_max) + '%' }} /></div>
      </div>

      <div className="duel-combat-mini">
        <span>Физ. урон {participant.physical_power}</span>
        <span>Маг. урон {participant.magic_power}</span>
        <span>Физ. защ. {participant.physical_defense}</span>
        <span>Маг. защ. {participant.magic_defense}</span>
        <span>Иниц. {participant.initiative}</span>

        <span>Дистанция {participant.bow_distance === 'close' ? 'ближняя' : participant.bow_distance === 'far' ? 'дальняя' : 'средняя'}</span>
        {participant.bloodshed_stacks > 0 && <span>Кровопролитие ×{participant.bloodshed_stacks}</span>}
      </div>

      <div className="initiative-tempo compact duel-tempo">
        <div className="initiative-tempo-head">
          <span>Темп инициативы</span>
          <strong>{participant.initiative_meter ?? 0} / 100</strong>
        </div>
        <div className="initiative-tempo-meter">
          <span style={{ width: Math.max(0, Math.min(100, participant.initiative_meter ?? 0)) + '%' }} />
        </div>
      </div>

      {participant.guard_reduction_percent > 0 && (
        <div className="duel-guard-ready">
          Защита готова · -{participant.guard_reduction_percent}% следующего удара
        </div>
      )}

      {participant.spell_damage_bonus_percent > 0 && participant.spell_damage_bonus_hits > 0 && (
        <div className="duel-guard-ready">
          Боевой фокус · +{participant.spell_damage_bonus_percent}% · {participant.spell_damage_bonus_hits} атак
        </div>
      )}

      {statuses.length > 0 && (
        <div className="duel-status-list">
          {statuses.map((status) => (
            <span key={status.id}>
              {statusLabels[status.effect_type]} · {status.remaining_turns} х.
            </span>
          ))}
        </div>
      )}
    </article>
  )
}
