import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { userFacingError } from '../lib/userError'
import { WorldPulsePanel } from './WorldPulsePanel'
import './newcomer.css'

type JourneyState = {
  available: boolean
  stage?: number
  approach?: string | null
  preparation?: string | null
  trial_hp?: number
  trial_hp_max?: number
  boss_hp?: number
  boss_hp_max?: number
  clue_power?: number
  round?: number
  battle_log?: string[]
  completed_at?: string | null
  dismissed_at?: string | null
  reward_claimed?: boolean
  reward_name?: string
}

type Props = {
  characterId: string
  onChanged?: () => Promise<unknown> | void
  onOpenAdventures?: () => void
  onOpenWorld?: () => void
}

const approachCards = [
  {
    id: 'tracks',
    title: 'Пойти по следам',
    text: 'Ищешь маршрут каравана сам. В бою получишь небольшой бонус к своему урону.',
  },
  {
    id: 'witness',
    title: 'Выслушать выжившего',
    text: 'Собираешь детали про чужой голос. Это может открыть особое действие в бою.',
  },
  {
    id: 'cargo',
    title: 'Осмотреть груз',
    text: 'Ищешь причину нападения среди оставленных вещей. Начнёшь испытание с запасом стойкости.',
  },
]

const prepCards = [
  {
    id: 'ambush',
    title: 'Подготовить засаду',
    text: 'Рискованный вариант: противник начнёт бой уже раненым.',
  },
  {
    id: 'ward',
    title: 'Укрепить защиту',
    text: 'Больше ОЗ испытания. Хорошо, если не уверен в своём уроне.',
  },
  {
    id: 'listen',
    title: 'Запомнить ритм эха',
    text: 'Открывает безопасный удар по слабому месту.',
  },
]

export function NewcomerJourney({ characterId, onChanged, onOpenAdventures, onOpenWorld }: Props) {
  const [state, setState] = useState<JourneyState | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  async function load() {
    const { data, error } = await supabase.rpc('get_newcomer_journey', { p_character_id: characterId })
    if (error) {
      setMessage(userFacingError(error.message, 'Не удалось загрузить первое приключение.'))
      setLoading(false)
      return
    }
    setState((data ?? null) as JourneyState | null)
    setLoading(false)
  }

  useEffect(() => {
    void load()
  }, [characterId])

  async function choose(choice: string) {
    setBusy(true)
    setMessage('')
    const { data, error } = await supabase.rpc('choose_newcomer_journey', {
      p_character_id: characterId,
      p_choice: choice,
    })
    if (error) {
      setMessage(userFacingError(error.message, 'Не удалось продолжить приключение.'))
      setBusy(false)
      return
    }
    setState(data as JourneyState)
    setBusy(false)
  }

  async function act(action: string) {
    setBusy(true)
    setMessage('')
    const { data, error } = await supabase.rpc('perform_newcomer_journey_action', {
      p_character_id: characterId,
      p_action: action,
    })
    if (error) {
      setMessage(userFacingError(error.message, 'Не удалось выполнить действие.'))
      setBusy(false)
      return
    }
    setState(data as JourneyState)
    await onChanged?.()
    setBusy(false)
  }

  async function dismiss() {
    setBusy(true)
    const { data, error } = await supabase.rpc('dismiss_newcomer_journey', {
      p_character_id: characterId,
    })
    if (!error) setState(data as JourneyState)
    setBusy(false)
  }

  if (loading || !state?.available || state.dismissed_at) return null

  const hp = Math.max(0, state.trial_hp ?? 0)
  const hpMax = Math.max(1, state.trial_hp_max ?? 1)
  const bossHp = Math.max(0, state.boss_hp ?? 0)
  const bossMax = Math.max(1, state.boss_hp_max ?? 1)

  return (
    <section className="panel newcomer-journey">
      <div className="newcomer-heading">
        <div>
          <span className="eyebrow">ПЕРВОЕ ПРИКЛЮЧЕНИЕ</span>
          <h2>Эхо дороги</h2>
        </div>
        <span className="badge">{state.stage === 3 ? 'завершено' : '15–25 мин'}</span>
      </div>

      {message && <p className="form-message" role="status">{message}</p>}

      {state.stage === 0 && (
        <>
          <p className="newcomer-story">
            У северной дороги в Варден вернулся единственный человек из небольшого каравана.
            Он клянётся, что ночью из леса ему отвечал его собственный голос. Остальные не вернулись.
          </p>
          <p className="muted">Это не учебное меню: выбор немного меняет само испытание и запись в хронике.</p>
          <div className="newcomer-choice-grid">
            {approachCards.map((choice) => (
              <button key={choice.id} type="button" disabled={busy} onClick={() => void choose(choice.id)}>
                <strong>{choice.title}</strong>
                <span>{choice.text}</span>
              </button>
            ))}
          </div>
        </>
      )}

      {state.stage === 1 && (
        <>
          <p className="newcomer-story">
            След приводит к месту, где лес внезапно становится слишком тихим. Между деревьями повторяются обрывки чужих фраз,
            но источник звука всё время оказывается в другом месте.
          </p>
          <div className="newcomer-choice-grid">
            {prepCards.map((choice) => (
              <button key={choice.id} type="button" disabled={busy} onClick={() => void choose(choice.id)}>
                <strong>{choice.title}</strong>
                <span>{choice.text}</span>
              </button>
            ))}
          </div>
        </>
      )}

      {state.stage === 2 && (
        <>
          <div className="newcomer-boss-title">
            <div>
              <span className="eyebrow">МИНИ-БОСС</span>
              <h3>Отзвук дороги</h3>
            </div>
            <span>раунд {state.round ?? 1}</span>
          </div>

          <div className="newcomer-duel-bars">
            <div>
              <span>Ты</span>
              <strong>{hp} / {hpMax}</strong>
              <i><b style={{ width: Math.round(hp / hpMax * 100) + '%' }} /></i>
            </div>
            <div>
              <span>Отзвук</span>
              <strong>{bossHp} / {bossMax}</strong>
              <i><b style={{ width: Math.round(bossHp / bossMax * 100) + '%' }} /></i>
            </div>
          </div>

          <div className="newcomer-combat-actions">
            <button className="primary-button" type="button" disabled={busy} onClick={() => void act('strike')}>
              Атаковать
            </button>
            <button className="ghost-button" type="button" disabled={busy} onClick={() => void act('guard')}>
              Защититься
            </button>
            {(state.clue_power ?? 0) > 0 && (
              <button className="ghost-button" type="button" disabled={busy} onClick={() => void act('insight')}>
                Использовать закономерность
              </button>
            )}
          </div>

          <div className="newcomer-battle-log">
            {(state.battle_log ?? []).slice(-5).map((line, index) => <p key={index}>{line}</p>)}
          </div>
          <small className="muted">Поражение ничего не отнимает: испытание просто начнётся заново.</small>
        </>
      )}

      {state.stage === 3 && (
        <>
          <div className="newcomer-finish">
            <span className="eyebrow">ТВОЯ ИСТОРИЯ В ЭЙЛАРЕ НАЧАЛАСЬ</span>
            <h3>Первая запись добавлена в хронику</h3>
            <p>
              За «Эхо дороги» ты получил <b>{state.reward_name ?? 'Знак первой дороги'}</b> и <b>120 золота</b>.
              Выбранный путь сохранён в архиве открытий персонажа.
            </p>
          </div>

          <div className="newcomer-next-actions">
            {onOpenWorld && <button className="ghost-button" type="button" onClick={onOpenWorld}>Открыть карту</button>}
            {onOpenAdventures && <button className="primary-button" type="button" onClick={onOpenAdventures}>Посмотреть, что происходит в мире</button>}
          </div>

          <div className="newcomer-pulse-preview">
            <span className="eyebrow">МИР УЖЕ ЖИВЁТ</span>
            <WorldPulsePanel
              characterId={characterId}
              compact
              embedded
              dungeonEventMode="summary"
            />
          </div>

          <button className="newcomer-dismiss" type="button" disabled={busy} onClick={() => void dismiss()}>
            Убрать пролог с главного экрана
          </button>
        </>
      )}
    </section>
  )
}
