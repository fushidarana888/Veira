import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { userFacingError } from '../lib/userError'

type StoryChoice = {
  id: string
  title: string
  description: string
}

type JourneyState = {
  stage: number
  first_choice: string | null
  second_choice: string | null
  final_choice: string | null
  completed_at: string | null
  title: string
  text: string
  choices: StoryChoice[]
  reward: {
    gold: number
    experience: number
    item_name: string
  }
}

type ActivityEntry = {
  kind: 'boss' | 'chronicle' | 'discovery'
  title: string
  text: string
  occurred_at: string
}

type Props = {
  characterId: string
  accountCreatedAt: string
  onOpenGuide: () => void
  onProgressChanged?: () => Promise<unknown> | void
}

const THREE_DAYS = 3 * 24 * 60 * 60 * 1000

const statCards = [
  ['СИЛ', 'Силовое оружие, немного ОЗ и эффективность блока.'],
  ['ЛОВ', 'Ловкостное оружие, инициатива и немного физической брони.'],
  ['ИНТ', 'Магическая мощь и магическая броня.'],
  ['ЖИВ', 'Главный источник физической защиты и выживаемости.'],
  ['УДА', 'Криты, качество находок и более удачный разброс урона.'],
]

const buildCards = [
  ['Силовой боец', 'СИЛ + ЖИВ. Мечи, топоры, молоты, двуручное оружие. Сильные прямые удары и блок.'],
  ['Ловкостной керри', 'ЛОВ + немного СИЛ/УДА. Луки, рапиры, кинжалы. Темп, инициатива и серии атак.'],
  ['Маг', 'ИНТ + УДА/ЖИВ. Заклинания дают сильные кнопки за ману, контроль и стихийный урон.'],
  ['Танк / саппорт', 'ЖИВ + нужная вторичная характеристика. Щиты, провокация, защита, лечение и баффы союзников.'],
  ['Гибрид', 'СИЛ + ЛОВ или смешанный набор эффектов. Катаны и копья позволяют собирать необычные связки.'],
]

export function NewcomerPanel({
  characterId,
  accountCreatedAt,
  onOpenGuide,
  onProgressChanged,
}: Props) {
  const [journey, setJourney] = useState<JourneyState | null>(null)
  const [activity, setActivity] = useState<ActivityEntry[]>([])
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  const newcomer = useMemo(() => {
    const created = new Date(accountCreatedAt).getTime()
    return Number.isFinite(created) && Date.now() - created < THREE_DAYS
  }, [accountCreatedAt])

  async function load() {
    const [{ data: journeyData, error: journeyError }, { data: activityData }] = await Promise.all([
      supabase.rpc('get_first_journey', { p_character_id: characterId }),
      supabase.rpc('get_newcomer_world_activity', { p_character_id: characterId }),
    ])

    if (journeyError) {
      setMessage(userFacingError(journeyError.message, 'Не удалось загрузить первое приключение.'))
      return
    }

    setJourney(journeyData as JourneyState)
    setActivity((activityData as ActivityEntry[] | null) ?? [])
  }

  useEffect(() => {
    void load()
  }, [characterId])

  async function choose(choiceId: string) {
    if (busy) return
    setBusy(true)
    setMessage('')

    const { data, error } = await supabase.rpc('advance_first_journey', {
      p_character_id: characterId,
      p_choice: choiceId,
    })

    if (error) {
      setMessage(userFacingError(error.message, 'Не удалось продолжить историю.'))
      setBusy(false)
      return
    }

    const next = data as JourneyState
    setJourney(next)

    if (next.stage >= 3) {
      await Promise.resolve(onProgressChanged?.())
      const { data: activityData } = await supabase.rpc('get_newcomer_world_activity', {
        p_character_id: characterId,
      })
      setActivity((activityData as ActivityEntry[] | null) ?? [])
    }

    setBusy(false)
  }

  if (!journey) {
    if (!newcomer && !message) return null
    return message ? <p className="form-message">{message}</p> : null
  }

  const journeyOpen = journey.stage < 3
  if (!newcomer && !journeyOpen) return null

  return (
    <section className="newcomer-stack" aria-label="Старт в Veira">
      {newcomer && (
        <article className="panel newcomer-guide-card">
          <div className="newcomer-guide-head">
            <div>
              <span className="eyebrow">ПЕРВЫЕ 3 ДНЯ</span>
              <h2>Пособие новичка</h2>
              <p className="muted">
                Veira — это RPG про исследование Эйлара, развитие собственного билда, подземелья,
                редкие находки и совместные бои. Класса навсегда нет: роль определяют характеристики,
                оружие, экипировка, заклинания и твои решения.
              </p>
            </div>
            <button className="ghost-button" type="button" onClick={onOpenGuide}>
              Полный гид
            </button>
          </div>

          <details className="newcomer-guide-details" open>
            <summary>Что важно понять сразу</summary>
            <div className="newcomer-quick-grid">
              <div>
                <strong>Главный цикл</strong>
                <span>Исследуй карту → находи руины и данжи → собирай экипировку → усиливай билд → иди в более опасный контент.</span>
              </div>
              <div>
                <strong>Физический урон</strong>
                <span>Режущий, колющий и дробящий. Его сдерживают физическая броня и сопротивление конкретному типу.</span>
              </div>
              <div>
                <strong>Магический урон</strong>
                <span>Огонь, вода, земля, воздух, молния, лёд и редкие школы. Важны магическая броня и стихийные сопротивления.</span>
              </div>
              <div>
                <strong>Пати важнее соло-цифр</strong>
                <span>Танк, саппорт, дебаффер и керри могут готовить сильные окна урона вместо четырёх одинаковых атак.</span>
              </div>
            </div>
          </details>

          <details className="newcomer-guide-details">
            <summary>Характеристики</summary>
            <div className="newcomer-stat-grid">
              {statCards.map(([name, text]) => (
                <div key={name}><strong>{name}</strong><span>{text}</span></div>
              ))}
            </div>
          </details>

          <details className="newcomer-guide-details">
            <summary>Какие билды можно делать</summary>
            <div className="newcomer-build-grid">
              {buildCards.map(([name, text]) => (
                <div key={name}><strong>{name}</strong><span>{text}</span></div>
              ))}
            </div>
          </details>

          <div className="newcomer-first-steps">
            <b>Первые шаги:</b>
            <span>заверши «Эхо дороги» → посмотри экипировку → исследуй соседний сектор → попробуй данж → найди людей для пати.</span>
          </div>
        </article>
      )}

      {journeyOpen ? (
        <article className="panel first-journey-card">
          <div className="first-journey-heading">
            <div>
              <span className="eyebrow">ПЕРВАЯ ГЛАВА · {Math.min(3, journey.stage + 1)}/3</span>
              <h2>{journey.title}</h2>
            </div>
            <span className="badge">15–20 минут</span>
          </div>

          <p className="first-journey-story">{journey.text}</p>

          <div className="first-journey-choices">
            {journey.choices.map((choice) => (
              <button
                type="button"
                key={choice.id}
                disabled={busy}
                onClick={() => void choose(choice.id)}
              >
                <strong>{choice.title}</strong>
                <span>{choice.description}</span>
              </button>
            ))}
          </div>

          <div className="first-journey-reward">
            <span>Награда за главу</span>
            <b>{journey.reward.gold} золота · {journey.reward.experience} опыта · {journey.reward.item_name}</b>
          </div>
          {message && <p className="form-message" aria-live="polite">{message}</p>}
        </article>
      ) : newcomer ? (
        <article className="panel first-journey-complete">
          <span className="eyebrow">ХРОНИКА НАЧАТА</span>
          <h2>Твоя история в Эйларе началась</h2>
          <p>{journey.text}</p>
          <div className="first-journey-reward ready">
            <span>Получено</span>
            <b>{journey.reward.gold} золота · {journey.reward.experience} опыта · {journey.reward.item_name}</b>
          </div>
        </article>
      ) : null}

      {newcomer && activity.length > 0 && (
        <article className="panel newcomer-world-pulse">
          <div className="section-heading">
            <div>
              <span className="eyebrow">МИР УЖЕ ДВИЖЕТСЯ</span>
              <h2>Что происходит в Veira</h2>
            </div>
            <span className="badge">живой мир</span>
          </div>
          <div className="newcomer-activity-list">
            {activity.slice(0, 5).map((entry, index) => (
              <div key={entry.occurred_at + ':' + index}>
                <span className={'newcomer-activity-mark ' + entry.kind} aria-hidden="true" />
                <div>
                  <strong>{entry.title}</strong>
                  <span>{entry.text}</span>
                  <small>{new Date(entry.occurred_at).toLocaleString('ru-RU')}</small>
                </div>
              </div>
            ))}
          </div>
        </article>
      )}
    </section>
  )
}
