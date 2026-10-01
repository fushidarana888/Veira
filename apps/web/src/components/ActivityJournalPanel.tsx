import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { userFacingError } from '../lib/userError'
import { useSmartRefresh } from '../lib/smartRefresh'

type ActivityBlocker = {
  kind: string
  title: string
  detail: string
  sector_id: number | null
  ends_at: string | null
}

type ActivityJournalEntry = {
  id: string
  kind: string
  title: string
  objective: string
  reward_hint: string
  sector_id: number | null
  ends_at: string | null
  progress_current: number
  progress_target: number
  status: string
  action_hint: string
}

type CampState = {
  sector_id: number
  camp_level: number
  access_mode: 'private' | 'party' | 'open'
  placed_at: string
  expires_at: string
  module_slots: number
  module_count: number
  storage_capacity: number
  storage_used: number
}

type ExplorationState = {
  discovered_count: number
  total_sectors: number
  next_milestone: number | null
  cartography_speed_percent: number
  next_reward: string | null
}

type ActivityJournal = {
  blocker: ActivityBlocker | null
  entries: ActivityJournalEntry[]
  camp: CampState | null
  exploration: ExplorationState
}

type Props = {
  characterId: string
  onProgressChanged?: () => Promise<unknown> | void
}

const kindLabels: Record<string, string> = {
  treasure: 'КАРТА СОКРОВИЩ',
  expedition: 'ЭКСПЕДИЦИЯ',
  treasure_expedition: 'ПОХОД К ТАЙНИКУ',
  dungeon: 'ПОДЗЕМЕЛЬЕ',
  settlement_quest: 'ПОРУЧЕНИЕ',
  religion_oath: 'КЛЯТВА',
  death_spirit: 'ДУХ',
  camp: 'ЛАГЕРЬ',
  hunting: 'ОХОТА',
  camp_action: 'ЛАГЕРНОЕ ДЕЙСТВИЕ',
  merchant: 'ТОРГОВЕЦ',
  rumor: 'СЛУХ',
}

function formatTime(value: string | null) {
  if (!value) return null
  return new Date(value).toLocaleString('ru-RU', {
    day: '2-digit',
    month: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  })
}

export function ActivityJournalPanel({ characterId, onProgressChanged }: Props) {
  const [journal, setJournal] = useState<ActivityJournal | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  const loadJournal = useCallback(async (silent = false) => {
    if (!silent) setLoading(true)

    const { data, error } = await supabase.rpc('get_character_activity_journal_v2', {
      p_character_id: characterId,
    })

    if (error) {
      if (!silent) setMessage(userFacingError(error.message, 'Не удалось загрузить журнал.'))
      if (!silent) setLoading(false)
      return
    }

    setJournal((data as ActivityJournal | null) ?? null)
    if (!silent) setLoading(false)
  }, [characterId])

  useEffect(() => {
    setJournal(null)
    setMessage('')
    void loadJournal()
  }, [loadJournal])

  useSmartRefresh(
    () => loadJournal(true),
    { enabled: Boolean(journal), minGapMs: 2500 },
  )

  async function removeCamp() {
    if (!journal?.camp || busy) return
    setBusy(true)
    setMessage('')

    const { data, error } = await supabase.rpc('remove_character_camp', {
      p_character_id: characterId,
    })

    if (error) {
      setMessage(userFacingError(error.message, 'Не удалось свернуть лагерь.'))
      setBusy(false)
      return
    }

    setMessage(data ? 'Лагерь свёрнут.' : 'Активного лагеря уже нет.')
    await Promise.all([
      loadJournal(true),
      Promise.resolve(onProgressChanged?.()),
    ])
    setBusy(false)
  }

  if (loading && !journal) {
    return <article className="panel"><p className="muted">Собираем активные дела…</p></article>
  }

  if (!journal) {
    return <article className="panel"><p className="muted">Журнал сейчас недоступен.</p></article>
  }

  const exploration = journal.exploration
  const progressPercent = Math.min(
    100,
    Math.round((exploration.discovered_count / Math.max(1, exploration.total_sectors)) * 100),
  )

  return (
    <section className="activity-journal">
      <article className="panel activity-journal-hero">
        <div className="section-heading">
          <div>
            <span className="eyebrow">ЖУРНАЛ</span>
            <h2>Активные дела</h2>
            <p className="muted">
              Всё, что сейчас требует внимания: походы, поручения, клятвы, карты, духи, лагерь и события мира.
            </p>
          </div>
          <span className="badge">{journal.entries.length}</span>
        </div>

        {journal.blocker ? (
          <div className="activity-blocker-card">
            <div>
              <span className="eyebrow">СЕЙЧАС ПЕРСОНАЖ ЗАНЯТ</span>
              <strong>{journal.blocker.title}</strong>
              <p>{journal.blocker.detail}</p>
            </div>
            <div className="activity-blocker-meta">
              {journal.blocker.sector_id && <span>сектор #{journal.blocker.sector_id}</span>}
              {journal.blocker.ends_at && <span>до {formatTime(journal.blocker.ends_at)}</span>}
            </div>
          </div>
        ) : (
          <div className="activity-free-card">
            <strong>Персонаж свободен</strong>
            <span>Можно начинать новое исследование, охоту, лагерь или другой поход.</span>
          </div>
        )}
      </article>

      {message && <p className="gm-notice" aria-live="polite">{message}</p>}

      <div className="activity-journal-summary">
        <article className="panel activity-cartography-card">
          <span className="eyebrow">КАРТОГРАФИЯ</span>
          <div className="activity-cartography-head">
            <h3>{exploration.discovered_count} / {exploration.total_sectors}</h3>
            <span className="badge ready">+{exploration.cartography_speed_percent}% к исследованиям</span>
          </div>
          <div className="activity-progress-track" aria-label={'Исследовано ' + progressPercent + '%'}>
            <span style={{ width: progressPercent + '%' }} />
          </div>
          {exploration.next_milestone ? (
            <p className="muted">
              Следующая веха: <b>{exploration.next_milestone} секторов</b>
              {exploration.next_reward ? <> · {exploration.next_reward}</> : null}
            </p>
          ) : (
            <p className="muted">Все текущие картографические вехи достигнуты.</p>
          )}
        </article>

        <article className="panel activity-camp-card">
          <span className="eyebrow">ЛАГЕРЬ</span>
          {journal.camp ? (
            <>
              <h3>Полевой лагерь · уровень {journal.camp.camp_level}</h3>
              <p className="muted">
                Сектор #{journal.camp.sector_id} · построек {journal.camp.module_count}/{journal.camp.module_slots}
                {' '}· склад {journal.camp.storage_used}/{journal.camp.storage_capacity}
                {' '}· ремонт до {formatTime(journal.camp.expires_at)}.
              </p>
              <button className="ghost-button" type="button" disabled={busy} onClick={() => void removeCamp()}>
                {busy ? 'Сворачиваем…' : 'Свернуть лагерь'}
              </button>
            </>
          ) : (
            <>
              <h3>Лагерь не установлен</h3>
              <p className="muted">Выбери открытый дикий сектор на карте и разбей полевую базу. Лагерь может стоять сколько угодно, но раз в 7 дней требует ремонта ресурсами.</p>
            </>
          )}
        </article>
      </div>

      <div className="activity-journal-list">
        {journal.entries.length === 0 ? (
          <article className="panel adventure-empty-folder">
            <span className="eyebrow">ТИХИЙ ДЕНЬ</span>
            <h3>Активных дел нет</h3>
            <p className="muted">Исследуй карту, возьми поручение или активируй карту сокровищ.</p>
          </article>
        ) : journal.entries.map((entry) => {
          const endsAt = formatTime(entry.ends_at)
          const progress = entry.progress_target > 0
            ? Math.min(100, Math.round(entry.progress_current / entry.progress_target * 100))
            : 0

          return (
            <article className={'panel activity-journal-entry activity-kind-' + entry.kind} key={entry.kind + ':' + entry.id}>
              <div className="activity-entry-head">
                <div>
                  <span className="eyebrow">{kindLabels[entry.kind] ?? entry.kind.toUpperCase()}</span>
                  <h3>{entry.title}</h3>
                </div>
                {entry.sector_id && <span className="badge">сектор #{entry.sector_id}</span>}
              </div>

              <p>{entry.objective}</p>

              {entry.progress_target > 1 && (
                <div className="activity-entry-progress">
                  <div className="activity-progress-track"><span style={{ width: progress + '%' }} /></div>
                  <small>{entry.progress_current} / {entry.progress_target}</small>
                </div>
              )}

              <div className="activity-entry-info">
                <span><small>Награда / смысл</small><b>{entry.reward_hint}</b></span>
                <span><small>Что делать</small><b>{entry.action_hint}</b></span>
                {endsAt && (
                  <span>
                    <small>{entry.kind === 'camp' ? 'Ремонт до' : 'Срок / возвращение'}</small>
                    <b>{endsAt}</b>
                  </span>
                )}
              </div>
            </article>
          )
        })}
      </div>
    </section>
  )
}
