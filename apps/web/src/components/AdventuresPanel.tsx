import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import type {
  CharacterAdventureSite,
  CombatEncounter,
  CombatTurn,
  DamageType,
} from '../types'

type Props = {
  characterId: string
  onProgressChanged?: () => Promise<unknown> | void
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

export function AdventuresPanel({ characterId, onProgressChanged }: Props) {
  const [sites, setSites] = useState<CharacterAdventureSite[]>([])
  const [encounters, setEncounters] = useState<CombatEncounter[]>([])
  const [turns, setTurns] = useState<CombatTurn[]>([])
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  async function loadAdventures() {
    setLoading(true)

    const [siteResult, encounterResult] = await Promise.all([
      supabase.rpc('get_character_adventures', {
        p_character_id: characterId,
      }),
      supabase
        .from('combat_encounters')
        .select('id, dungeon_run_id, character_id, sector_id, status, round, room_index, is_boss, enemy_template_id, enemy_name, enemy_level, enemy_hp_current, enemy_hp_max, enemy_attack, enemy_defense, enemy_initiative, enemy_damage_type, enemy_resistances, player_physical_damage_type, player_magic_damage_type, player_hp_current, player_hp_max, created_at, ended_at')
        .eq('character_id', characterId)
        .order('created_at', { ascending: false })
        .limit(20),
    ])

    const error = siteResult.error ?? encounterResult.error

    if (error) {
      setMessage(error.message)
      setLoading(false)
      return
    }

    const nextSites = (siteResult.data as CharacterAdventureSite[] | null) ?? []
    const nextEncounters = (encounterResult.data as CombatEncounter[] | null) ?? []

    setSites(nextSites)
    setEncounters(nextEncounters)

    const latestEncounter = nextEncounters[0] ?? null

    if (latestEncounter) {
      const { data: turnData, error: turnError } = await supabase
        .from('combat_turns')
        .select('id, encounter_id, round, actor, action_type, damage, player_hp_after, enemy_hp_after, message, created_at')
        .eq('encounter_id', latestEncounter.id)
        .order('id', { ascending: false })
        .limit(18)

      if (turnError) {
        setMessage(turnError.message)
      } else {
        setTurns(((turnData as CombatTurn[] | null) ?? []).reverse())
      }
    } else {
      setTurns([])
    }

    setLoading(false)
  }

  useEffect(() => {
    void loadAdventures()
  }, [characterId])

  const activeDungeon = useMemo(
    () => sites.find((site) => site.content_type === 'dungeon' && site.run_status === 'active') ?? null,
    [sites],
  )

  const ruins = useMemo(
    () => sites.filter((site) => site.content_type === 'ruins'),
    [sites],
  )

  const dungeons = useMemo(
    () => sites.filter((site) => site.content_type === 'dungeon'),
    [sites],
  )

  const latestCombat = encounters[0] ?? null
  const activeCombat = latestCombat?.status === 'active' ? latestCombat : null
  const latestCombatSite = latestCombat
    ? dungeons.find((site) => site.active_run_id === latestCombat.dungeon_run_id) ?? null
    : null

  async function startDungeon(site: CharacterAdventureSite) {
    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('start_dungeon_run', {
      p_character_id: characterId,
      p_sector_id: site.sector_id,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('DUNGEON_RUN_ALREADY_ACTIVE')) {
        setMessage('У персонажа уже есть активное прохождение подземелья.')
      } else if (raw.includes('DUNGEON_NOT_SCOUTED')) {
        setMessage('Сначала разведай вход через карту мира.')
      } else if (raw.includes('EXPEDITION_ALREADY_ACTIVE') || raw.includes('SITE_ACTION_ALREADY_ACTIVE')) {
        setMessage('Сначала заверши текущее исследование.')
      } else {
        setMessage(raw)
      }

      setBusy(false)
      return
    }

    await loadAdventures()
    setMessage('Прохождение начато.')
    setBusy(false)
  }

  async function startCombat(runId: string) {
    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('start_dungeon_combat', {
      p_run_id: runId,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('COMBAT_ALREADY_ACTIVE')) {
        setMessage('В этом подземелье уже идёт бой.')
      } else if (raw.includes('ROOM_COMBAT_ALREADY_EXISTS')) {
        setMessage('Этот зал уже был разыгран.')
      } else if (raw.includes('CHARACTER_HAS_NO_HP')) {
        setMessage('У персонажа нет здоровья для начала боя.')
      } else {
        setMessage(raw)
      }

      setBusy(false)
      return
    }

    await loadAdventures()
    setMessage('Следующий зал начат.')
    setBusy(false)
  }

  async function performCombatAction(action: 'physical' | 'magic' | 'guard') {
    if (!activeCombat) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('perform_combat_action', {
      p_encounter_id: activeCombat.id,
      p_action: action,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    await Promise.resolve(onProgressChanged?.())
    await loadAdventures()
    setBusy(false)
  }

  async function leaveDungeon(runId: string) {
    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('leave_dungeon_run', {
      p_run_id: runId,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    await loadAdventures()
    setMessage('Персонаж покинул подземелье. Его можно начать заново позже.')
    setBusy(false)
  }

  if (loading && sites.length === 0) {
    return (
      <section className="panel adventures-loading">
        <span className="eyebrow">ПРИКЛЮЧЕНИЯ</span>
        <h2>Проверяем найденные места…</h2>
      </section>
    )
  }

  const playerHpPercent = activeCombat
    ? Math.max(0, Math.min(100, Math.round((activeCombat.player_hp_current / activeCombat.player_hp_max) * 100)))
    : 0
  const enemyHpPercent = activeCombat
    ? Math.max(0, Math.min(100, Math.round((activeCombat.enemy_hp_current / activeCombat.enemy_hp_max) * 100)))
    : 0

  const clearedRooms = activeDungeon?.run_rooms_cleared ?? 0
  const totalRooms = activeDungeon?.run_total_rooms ?? 0
  const nextRoom = Math.min(totalRooms, clearedRooms + 1)
  const dungeonProgress = totalRooms > 0
    ? Math.round((clearedRooms / totalRooms) * 100)
    : 0
  const nextRoomIsBoss = totalRooms > 0 && nextRoom === totalRooms

  return (
    <section className="adventures-section">
      <article className="panel adventures-header">
        <div>
          <span className="eyebrow">ПРИКЛЮЧЕНИЯ</span>
          <h2>Руины и подземелья</h2>
          <p className="muted">
            Открытие сектора только обнаруживает место. Руины нужно исследовать отдельно, а вход в подземелье — сначала разведать.
          </p>
        </div>
        <div className="adventure-counters">
          <span><strong>{ruins.length}</strong><small>руин найдено</small></span>
          <span><strong>{dungeons.length}</strong><small>данжей найдено</small></span>
        </div>
      </article>

      {message && <p className="gm-notice" aria-live="polite">{message}</p>}

      {activeDungeon && activeDungeon.active_run_id && (
        <article className="panel active-dungeon-panel">
          <div className="section-heading">
            <div>
              <span className="eyebrow">АКТИВНОЕ ПРОХОЖДЕНИЕ</span>
              <h2>{activeDungeon.title}</h2>
            </div>
            <span className="badge">сектор #{activeDungeon.sector_id}</span>
          </div>

          <div className="dungeon-progress-block">
            <div className="dungeon-progress-head">
              <span>Пройдено залов</span>
              <strong>{clearedRooms} / {totalRooms}</strong>
            </div>
            <div className="dungeon-progress-meter">
              <span style={{ width: dungeonProgress + '%' }} />
            </div>
            <div className="dungeon-reward-preview">
              <span>За полную зачистку</span>
              <strong>
                {activeDungeon.run_reward_gold ?? 0} золота · {activeDungeon.run_reward_experience ?? 0} опыта
              </strong>
            </div>
          </div>

          {!activeCombat ? (
            <>
              <div className="dungeon-run-stage">
                <span>Следующий этап</span>
                <strong>
                  {nextRoomIsBoss
                    ? `Финальный зал · хранитель`
                    : `Зал ${nextRoom} из ${totalRooms}`}
                </strong>
                <p className="muted">
                  Здоровье между залами не восстанавливается автоматически. Можно продолжить или выйти и начать прохождение заново позже.
                </p>
              </div>

              <div className="dungeon-entry-actions">
                <button
                  className="primary-button"
                  type="button"
                  disabled={busy}
                  onClick={() => void startCombat(activeDungeon.active_run_id!)}
                >
                  {nextRoomIsBoss ? 'Войти к хранителю' : `Войти в зал ${nextRoom}`}
                </button>

                <button
                  className="ghost-button danger-button"
                  type="button"
                  disabled={busy}
                  onClick={() => void leaveDungeon(activeDungeon.active_run_id!)}
                >
                  Покинуть подземелье
                </button>
              </div>
            </>
          ) : (
            <div className="combat-shell">
              <div className="combat-heading">
                <div>
                  <span className="eyebrow">
                    {activeCombat.is_boss
                      ? `ХРАНИТЕЛЬ · РАУНД ${activeCombat.round + 1}`
                      : `ЗАЛ ${activeCombat.room_index} · РАУНД ${activeCombat.round + 1}`}
                  </span>
                  <h3>{activeCombat.enemy_name}</h3>
                  <span className="muted">
                    Уровень {activeCombat.enemy_level}
                    {activeCombat.is_boss ? ' · финальный противник' : ''}
                    {' · '}атака: {damageTypeLabels[activeCombat.enemy_damage_type]}
                  </span>
                </div>
                <span className="badge">
                  {activeCombat.room_index} / {totalRooms}
                </span>
              </div>

              <div className="combatants-grid">
                <div className="combatant-card">
                  <div className="combatant-head">
                    <span>Персонаж</span>
                    <strong>{activeCombat.player_hp_current} / {activeCombat.player_hp_max} HP</strong>
                  </div>
                  <div className="combat-hp-meter player"><span style={{ width: playerHpPercent + '%' }} /></div>
                </div>

                <div className="combatant-card enemy">
                  <div className="combatant-head">
                    <span>{activeCombat.enemy_name}</span>
                    <strong>{activeCombat.enemy_hp_current} / {activeCombat.enemy_hp_max} HP</strong>
                  </div>
                  <div className="combat-hp-meter enemy"><span style={{ width: enemyHpPercent + '%' }} /></div>
                  <div className="combat-resistance-summary">
                    {Object.entries(activeCombat.enemy_resistances ?? {})
                      .filter((entry): entry is [DamageType, number] => typeof entry[1] === 'number' && entry[1] !== 0)
                      .map(([type, value]) => (
                        <span className={value >= 0 ? 'positive' : 'negative'} key={type}>
                          {damageTypeLabels[type]} {value >= 0 ? '+' : ''}{value}%
                        </span>
                      ))}
                  </div>
                </div>
              </div>

              <div className="combat-actions">
                <button
                  className="primary-button"
                  type="button"
                  disabled={busy}
                  onClick={() => void performCombatAction('physical')}
                >
                  Физическая · {damageTypeLabels[activeCombat.player_physical_damage_type]}
                </button>

                <button
                  className="primary-button"
                  type="button"
                  disabled={busy}
                  onClick={() => void performCombatAction('magic')}
                >
                  Магическая · {damageTypeLabels[activeCombat.player_magic_damage_type]}
                </button>
                <button
                  className="ghost-button"
                  type="button"
                  disabled={busy}
                  onClick={() => void performCombatAction('guard')}
                >
                  Защита
                </button>
                <button
                  className="ghost-button danger-button"
                  type="button"
                  disabled={busy}
                  onClick={() => void leaveDungeon(activeDungeon.active_run_id!)}
                >
                  Отступить
                </button>
              </div>

              <div className="combat-log">
                {turns.map((turn) => (
                  <div className={'combat-log-row ' + turn.actor} key={turn.id}>
                    <span>{turn.actor === 'player' ? 'Ты' : turn.actor === 'enemy' ? 'Противник' : 'Система'}</span>
                    <p>{turn.message}</p>
                  </div>
                ))}
              </div>
            </div>
          )}
        </article>
      )}

      {!activeCombat && latestCombat && latestCombat.status !== 'active' && (
        <article className="panel combat-result-panel">
          <div>
            <span className="eyebrow">
              {latestCombat.status === 'victory'
                ? latestCombat.is_boss
                  ? 'ПОДЗЕМЕЛЬЕ ЗАЧИЩЕНО'
                  : `ЗАЛ ${latestCombat.room_index} ОЧИЩЕН`
                : latestCombat.status === 'defeat'
                  ? 'ПОРАЖЕНИЕ'
                  : 'БОЙ ПРЕКРАЩЁН'}
            </span>
            <h3>{latestCombat.enemy_name}</h3>
            <p className="muted">
              {latestCombat.status === 'victory'
                ? latestCombatSite?.run_status === 'completed'
                  ? `Полная зачистка завершена. Получено ${latestCombatSite.run_reward_gold ?? 0} золота и ${latestCombatSite.run_reward_experience ?? 0} опыта.`
                  : 'Противник повержен. Можно перейти к следующему залу.'
                : latestCombat.status === 'defeat'
                  ? 'Персонаж отступил из подземелья и остался с 1 HP.'
                  : 'Прохождение было прервано.'}
            </p>
          </div>
          <span className="badge">
            {latestCombat.status === 'victory'
              ? latestCombatSite?.run_status === 'completed'
                ? 'зачищено'
                : 'зал очищен'
              : latestCombat.status}
          </span>
        </article>
      )}

      <div className="adventure-site-grid">
        <article className="panel">
          <div className="section-heading">
            <div>
              <span className="eyebrow">РУИНЫ</span>
              <h2>Найденные руины</h2>
            </div>
            <span className="badge">{ruins.length}</span>
          </div>

          <div className="adventure-site-list">
            {ruins.length === 0 && (
              <p className="muted">Руины пока не обнаружены.</p>
            )}

            {ruins.map((site) => (
              <div className="adventure-site-row" key={'ruins-' + site.sector_id}>
                <div>
                  <strong>{site.title}</strong>
                  <span>сектор #{site.sector_id}</span>
                </div>
                <span className={'badge ' + (site.site_status === 'explored' || site.site_status === 'cleared' ? 'ready' : '')}>
                  {site.site_status === 'cleared'
                    ? 'зачищено'
                    : site.site_status === 'explored'
                      ? 'исследовано'
                      : 'требует исследования'}
                </span>
              </div>
            ))}
          </div>
        </article>

        <article className="panel">
          <div className="section-heading">
            <div>
              <span className="eyebrow">ПОДЗЕМЕЛЬЯ</span>
              <h2>Найденные входы</h2>
            </div>
            <span className="badge">{dungeons.length}</span>
          </div>

          <div className="adventure-site-list">
            {dungeons.length === 0 && (
              <p className="muted">Подземелья пока не обнаружены.</p>
            )}

            {dungeons.map((site) => {
              const scouted = site.site_status === 'scouted' || site.site_status === 'cleared'
              const active = site.run_status === 'active'

              return (
                <div className="adventure-site-row dungeon-row" key={'dungeon-' + site.sector_id}>
                  <div>
                    <strong>{site.title}</strong>
                    <span>сектор #{site.sector_id}</span>
                  </div>

                  <div className="adventure-site-actions">
                    <span className={'badge ' + (scouted ? 'ready' : '')}>
                      {site.site_status === 'cleared'
                        ? 'зачищено'
                        : scouted
                          ? 'вход разведан'
                          : 'вход не разведан'}
                    </span>

                    {scouted && !active && !activeDungeon && (
                      <button
                        className="primary-button"
                        type="button"
                        disabled={busy}
                        onClick={() => void startDungeon(site)}
                      >
                        {site.site_status === 'cleared' ? 'Пройти снова' : 'Войти'}
                      </button>
                    )}

                    {active && (
                      <span className="badge">
                        {(site.run_rooms_cleared ?? 0)} / {(site.run_total_rooms ?? 0)}
                      </span>
                    )}
                  </div>
                </div>
              )
            })}
          </div>
        </article>
      </div>
    </section>
  )
}
