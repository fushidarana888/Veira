import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'

type EventBossKind = 'weekly' | 'monthly'

type PartyOverview = {
  party: {
    id: string
    leader_character_id: string
    member_count: number
  } | null
  members: Array<{
    character_id: string
    name: string
    is_leader: boolean
  }>
}

type EventBoss = {
  event_id: string
  slug: string
  boss_kind: EventBossKind
  name: string
  description: string
  starts_at: string
  ends_at: string
  recommended_level: number
  enemy_level: number
  enemy_hp: number
  enemy_attack: number
  enemy_defense: number
  enemy_damage_type: string
  enemy_resistances: Record<string, number>
  special_name: string
  special_every_n: number
  phase2_hp_percent: number
  phase2_name: string
  special_reward_name: string | null
  special_reward_description: string | null
  first_reward_gold: number
  first_reward_experience: number
  repeat_reward_gold: number
  repeat_reward_experience: number
  victories: number
  special_reward_claimed: boolean
  solo_run_id: string | null
  solo_run_status: 'active' | 'completed' | 'abandoned' | null
  solo_encounter_id: string | null
  solo_encounter_status: 'active' | 'victory' | 'defeat' | 'cancelled' | null
  party_id: string | null
  party_member_count: number
  is_party_leader: boolean
  party_run_id: string | null
  party_run_status: 'active' | 'completed' | 'abandoned' | null
  party_encounter_id: string | null
  party_encounter_status: 'active' | 'victory' | 'defeat' | 'cancelled' | null
  character_busy: boolean
}

type Props = {
  characterId: string
  onChanged?: () => Promise<unknown> | void
}

const emptyParty: PartyOverview = { party: null, members: [] }

const kindLabels: Record<EventBossKind, { title: string; eyebrow: string; description: string }> = {
  weekly: {
    title: 'Недельные боссы',
    eyebrow: 'НЕДЕЛЬНАЯ УГРОЗА',
    description: 'Временные боссы с полезными наградами. Особая награда выдаётся один раз за текущую недельную ротацию.',
  },
  monthly: {
    title: 'Месячные боссы',
    eyebrow: 'МЕСЯЧНАЯ УГРОЗА',
    description: 'Более редкие и сложные противники с долгой ротацией. Первый месячный босс пока не объявлен.',
  },
}

const damageLabels: Record<string, string> = {
  slashing: 'режущий',
  piercing: 'колющий',
  blunt: 'дробящий',
  fire: 'огонь',
  water: 'вода',
  earth: 'земля',
  air: 'воздух',
  lightning: 'молния',
  ice: 'лёд',
}

function bossError(raw: string) {
  if (raw.includes('CHARACTER_BUSY')) return 'Персонаж уже занят экспедицией, другим боем, подземельем или дуэлью.'
  if (raw.includes('PARTY_MEMBER_BUSY')) return 'Один из участников пати сейчас занят и не может войти в событие.'
  if (raw.includes('PARTY_NOT_FOUND')) return 'Сначала создай пати.'
  if (raw.includes('PARTY_LEADER_REQUIRED')) return 'Групповой бой может запустить только лидер пати.'
  if (raw.includes('PARTY_NEEDS_TWO_MEMBERS')) return 'Для группового входа нужно минимум 2 персонажа.'
  if (raw.includes('PARTY_TOO_LARGE')) return 'В событие можно войти группой максимум из 4 персонажей.'
  if (raw.includes('PARTY_DUNGEON_ALREADY_ACTIVE')) return 'У этой пати уже идёт другой групповой бой.'
  if (raw.includes('EVENT_BOSS_NOT_ACTIVE')) return 'Эта ротация уже закончилась или ещё не началась.'
  if (raw.includes('CHARACTER_HAS_NO_HP') || raw.includes('PARTY_MEMBER_HAS_NO_HP')) return 'Перед входом хотя бы немного восстанови HP.'
  return raw
}

function formatEndsAt(value: string) {
  return new Intl.DateTimeFormat('ru-RU', {
    day: '2-digit',
    month: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  }).format(new Date(value))
}

export function EventBossesPanel({ characterId, onChanged }: Props) {
  const [kind, setKind] = useState<EventBossKind>('weekly')
  const [party, setParty] = useState<PartyOverview>(emptyParty)
  const [bosses, setBosses] = useState<EventBoss[]>([])
  const [loading, setLoading] = useState(true)
  const [busyMode, setBusyMode] = useState<'solo' | 'party' | null>(null)
  const [message, setMessage] = useState('')

  async function loadData(silent = false) {
    if (!silent) setLoading(true)

    const [partyResult, bossResult] = await Promise.all([
      supabase.rpc('get_party_overview', { p_character_id: characterId }),
      supabase.rpc('get_event_bosses', { p_character_id: characterId }),
    ])

    if (!partyResult.error) {
      setParty((partyResult.data as PartyOverview | null) ?? emptyParty)
    }

    if (bossResult.error) {
      setMessage(bossError(bossResult.error.message))
    } else {
      setBosses((bossResult.data as EventBoss[] | null) ?? [])
    }

    if (!silent) setLoading(false)
  }

  useEffect(() => {
    void loadData()

    const timer = window.setInterval(() => {
      void loadData(true)
    }, 10000)

    return () => window.clearInterval(timer)
  }, [characterId])

  const copy = kindLabels[kind]
  const visibleBosses = useMemo(
    () => bosses.filter((boss) => boss.boss_kind === kind),
    [bosses, kind],
  )

  const partySize = party.party?.member_count ?? party.members.length
  const inParty = Boolean(party.party)
  const isLeader = party.party?.leader_character_id === characterId

  async function startBoss(boss: EventBoss, mode: 'solo' | 'party') {
    setBusyMode(mode)
    setMessage('')

    const { error } = await supabase.rpc('start_event_boss', {
      p_character_id: characterId,
      p_event_id: boss.event_id,
      p_mode: mode,
    })

    if (error) {
      setMessage(bossError(error.message))
      setBusyMode(null)
      return
    }

    await Promise.all([
      loadData(true),
      Promise.resolve(onChanged?.()),
    ])

    setMessage(
      mode === 'party'
        ? 'Пепельный Кузнец ждёт группу. Бой открыт для всех участников текущей пати.'
        : 'Бой с Пепельным Кузнецом начат. Поле боя появилось ниже в «Приключениях».',
    )
    setBusyMode(null)
  }

  return (
    <article className="panel event-bosses-panel">
      <div className="section-heading event-bosses-heading">
        <div>
          <span className="eyebrow">ОСОБЫЕ УГРОЗЫ</span>
          <h2>Временные боссы</h2>
          <p className="muted">
            Эти боссы не находятся на карте. Когда ротация активна, к ним можно перейти прямо из «Приключений».
          </p>
        </div>
        <span className="badge">события</span>
      </div>

      <div className="event-boss-rules">
        <div>
          <strong>Соло или группа</strong>
          <span>Можно идти одному или существующей пати из 2–4 персонажей. Групповой бой запускает лидер.</span>
        </div>
        <div>
          <strong>Особая награда</strong>
          <span>Главная награда ротации выдаётся персонажу только за первую победу. Повторные убийства дают небольшую обычную награду.</span>
        </div>
        <div>
          <strong>Без карты</strong>
          <span>Не нужно открывать сектор, разведывать вход или тратить время экспедиции. Активная экспедиция, однако, блокирует вход.</span>
        </div>
      </div>

      <div className="event-boss-party-state">
        <div>
          <span className="eyebrow">РЕЖИМ ВХОДА</span>
          <strong>{inParty ? `Текущая пати · ${partySize}/4` : 'Соло'}</strong>
          <small>
            {inParty
              ? isLeader
                ? 'Ты лидер группы и можешь запустить совместный бой.'
                : 'Ты состоишь в группе. Совместный бой запускает лидер.'
              : 'Можно идти одному или сначала создать группу в разделе выше.'}
          </small>
        </div>
        <div className="event-boss-entry-modes">
          <span className="active">Соло</span>
          <span className={inParty ? 'active' : ''}>Пати до 4</span>
        </div>
      </div>

      <div className="event-boss-tabs" role="tablist" aria-label="Тип временного босса">
        {(Object.keys(kindLabels) as EventBossKind[]).map((entry) => (
          <button
            key={entry}
            className={kind === entry ? 'active' : ''}
            type="button"
            role="tab"
            aria-selected={kind === entry}
            onClick={() => setKind(entry)}
          >
            {entry === 'weekly' ? 'Недельные' : 'Месячные'}
          </button>
        ))}
      </div>

      {message && <p className="form-message" aria-live="polite">{message}</p>}

      {loading ? (
        <section className="event-boss-empty">
          <div className="event-boss-empty-mark" aria-hidden="true">◆</div>
          <strong>Проверяем активные угрозы…</strong>
        </section>
      ) : visibleBosses.length === 0 ? (
        <section className="event-boss-empty" aria-live="polite">
          <div className="event-boss-empty-mark" aria-hidden="true">◆</div>
          <span className="eyebrow">{copy.eyebrow}</span>
          <h3>{copy.title}</h3>
          <p>{copy.description}</p>
          <div className="event-boss-empty-state">
            <strong>Сейчас активных боссов нет</strong>
            <span>Когда появится новая ротация, здесь будут показаны срок события, сложность, особая добыча и кнопка входа.</span>
          </div>
        </section>
      ) : (
        <div className="event-boss-list">
          {visibleBosses.map((boss) => {
            const soloActive = boss.solo_run_status === 'active'
            const partyActive = boss.party_run_status === 'active'
            const anyActive = soloActive || partyActive
            const canParty = inParty && isLeader && partySize >= 2 && partySize <= 4 && !partyActive
            const resistances = Object.entries(boss.enemy_resistances ?? {}).filter(([, value]) => Number(value) !== 0)

            return (
              <section className="event-boss-card" key={boss.event_id}>
                <div className="event-boss-card-head">
                  <div>
                    <span className="eyebrow">{copy.eyebrow}</span>
                    <h3>{boss.name}</h3>
                    <p>{boss.description}</p>
                  </div>
                  <div className="event-boss-deadline">
                    <span>До</span>
                    <strong>{formatEndsAt(boss.ends_at)}</strong>
                  </div>
                </div>

                <div className="event-boss-stat-grid">
                  <span><small>Рекомендация</small><strong>LVL {boss.recommended_level}+</strong></span>
                  <span><small>Соло HP</small><strong>{boss.enemy_hp}</strong></span>
                  <span><small>ATK</small><strong>{boss.enemy_attack}</strong></span>
                  <span><small>DEF</small><strong>{boss.enemy_defense}</strong></span>
                  <span><small>Тип атаки</small><strong>{damageLabels[boss.enemy_damage_type] ?? boss.enemy_damage_type}</strong></span>
                </div>

                {resistances.length > 0 && (
                  <div className="event-boss-resistances">
                    {resistances.map(([type, value]) => (
                      <span className={Number(value) < 0 ? 'weak' : 'resist'} key={type}>
                        {damageLabels[type] ?? type} {Number(value) > 0 ? '+' : ''}{value}%
                      </span>
                    ))}
                  </div>
                )}

                <div className="event-boss-mechanics">
                  <div>
                    <strong>{boss.special_name}</strong>
                    <span>
                      Тяжёлый телеграфируемый удар каждые {boss.special_every_n} хода врага. Защита перед ударом сильно повышает шанс пережить его.
                    </span>
                  </div>
                  <div>
                    <strong>{boss.phase2_name}</strong>
                    <span>
                      Ниже {boss.phase2_hp_percent}% HP горн разгорается, и Кузнец начинает бить сильнее.
                    </span>
                  </div>
                </div>

                <div className={'event-boss-reward ' + (boss.special_reward_claimed ? 'claimed' : '')}>
                  <div>
                    <span className="eyebrow">ПЕРВАЯ ПОБЕДА РОТАЦИИ</span>
                    <strong>{boss.special_reward_name ?? 'Особая награда'}</strong>
                    <p>{boss.special_reward_description}</p>
                  </div>
                  <div className="event-boss-reward-values">
                    <span>{boss.first_reward_gold} золота</span>
                    <span>{boss.first_reward_experience} опыта</span>
                    <span>{boss.special_reward_claimed ? 'особая награда уже получена' : 'особая награда доступна'}</span>
                  </div>
                </div>

                <div className="event-boss-repeat-reward">
                  Повторная победа: {boss.repeat_reward_gold} золота · {boss.repeat_reward_experience} опыта.
                  {boss.victories > 0 ? ` Побед этой ротации: ${boss.victories}.` : ''}
                </div>

                <div className="event-boss-actions">
                  <button
                    className="primary-button"
                    type="button"
                    disabled={busyMode !== null || anyActive || boss.character_busy}
                    onClick={() => void startBoss(boss, 'solo')}
                  >
                    {soloActive
                      ? 'Соло-бой уже идёт'
                      : boss.character_busy
                        ? 'Персонаж занят'
                        : busyMode === 'solo'
                          ? 'Входим…'
                          : 'Войти одному'}
                  </button>

                  <button
                    className="ghost-button"
                    type="button"
                    disabled={busyMode !== null || anyActive || !canParty || boss.character_busy}
                    onClick={() => void startBoss(boss, 'party')}
                  >
                    {partyActive
                      ? 'Пати уже в бою'
                      : !inParty
                        ? 'Сначала создай пати'
                        : !isLeader
                          ? 'Запускает лидер'
                          : partySize < 2
                            ? 'Нужно 2+'
                            : busyMode === 'party'
                              ? 'Собираем пати…'
                              : `Войти пати · ${partySize}/4`}
                  </button>
                </div>
              </section>
            )
          })}
        </div>
      )}
    </article>
  )
}
