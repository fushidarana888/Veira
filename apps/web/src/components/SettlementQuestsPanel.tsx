import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import './settlementQuests.css'

type Props = {
  characterId: string
  sectorId: number
  onProgressChanged?: () => Promise<unknown> | void
  onInventoryChanged?: () => Promise<unknown> | void
}

type SettlementQuest = {
  quest_id: string
  sector_id: number
  settlement_name: string
  title: string
  description: string
  theme: 'general' | 'protection' | 'nature' | 'research' | 'arcane' | 'combat' | 'delivery'
  objective_type: 'discover_sectors' | 'complete_expeditions' | 'complete_dungeons' | 'defeat_enemies' | 'deliver_item'
  objective_target: number
  target_item_definition_id: string | null
  target_item_name: string | null
  reward_gold: number
  reward_experience: number
  min_level: number
  repeatable: boolean
  cooldown_hours: number
  enabled: boolean
  assignment_id: string | null
  assignment_status: 'active' | null
  accepted_at: string | null
  progress: number
  can_complete: boolean
  can_accept: boolean
  cooldown_remaining_seconds: number
  active_quest_count: number
}

const themeLabels: Record<SettlementQuest['theme'], string> = {
  general: 'Обычное',
  protection: 'Защита',
  nature: 'Природа',
  research: 'Исследование',
  arcane: 'Магия',
  combat: 'Бой',
  delivery: 'Доставка',
}

function objectiveText(quest: SettlementQuest) {
  switch (quest.objective_type) {
    case 'discover_sectors':
      return `Открыть новых секторов: ${quest.objective_target}`
    case 'complete_expeditions':
      return `Завершить экспедиций: ${quest.objective_target}`
    case 'complete_dungeons':
      return `Завершить подземелий: ${quest.objective_target}`
    case 'defeat_enemies':
      return `Победить противников: ${quest.objective_target}`
    case 'deliver_item':
      return `Принести: ${quest.target_item_name ?? 'предмет'} ×${quest.objective_target}`
  }
}

function formatCooldown(seconds: number) {
  if (seconds <= 0) return ''
  const hours = Math.floor(seconds / 3600)
  const minutes = Math.ceil((seconds % 3600) / 60)
  if (hours > 0) return `${hours} ч ${minutes > 0 ? `${minutes} мин` : ''}`.trim()
  return `${minutes} мин`
}

function errorMessage(raw: string) {
  if (raw.includes('TOO_MANY_ACTIVE_QUESTS')) return 'Одновременно можно держать не больше трёх поручений.'
  if (raw.includes('QUEST_COOLDOWN')) return 'Это поручение пока на перезарядке.'
  if (raw.includes('LEVEL_TOO_LOW')) return 'Уровень персонажа пока слишком низкий.'
  if (raw.includes('QUEST_NOT_COMPLETE')) return 'Условия поручения ещё не выполнены.'
  if (raw.includes('QUEST_ITEMS_MISSING')) return 'Не хватает предметов для сдачи.'
  if (raw.includes('QUEST_ALREADY_COMPLETED')) return 'Это одноразовое поручение уже выполнено.'
  return raw
}

export function SettlementQuestsPanel({
  characterId,
  sectorId,
  onProgressChanged,
  onInventoryChanged,
}: Props) {
  const [quests, setQuests] = useState<SettlementQuest[]>([])
  const [loading, setLoading] = useState(true)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [message, setMessage] = useState('')

  async function loadQuests() {
    setLoading(true)
    const { data, error } = await supabase.rpc('get_settlement_quests', {
      p_character_id: characterId,
      p_sector_id: sectorId,
    })

    if (error) {
      setMessage(errorMessage(error.message))
      setQuests([])
      setLoading(false)
      return
    }

    setQuests((data as SettlementQuest[] | null) ?? [])
    setLoading(false)
  }

  useEffect(() => {
    setMessage('')
    void loadQuests()
  }, [characterId, sectorId])

  const activeCount = quests[0]?.active_quest_count ?? 0
  const settlementName = quests[0]?.settlement_name ?? 'Поселение'
  const active = useMemo(() => quests.filter((quest) => quest.assignment_id), [quests])
  const available = useMemo(() => quests.filter((quest) => !quest.assignment_id), [quests])

  async function accept(quest: SettlementQuest) {
    setBusyId(quest.quest_id)
    setMessage('')

    const { error } = await supabase.rpc('accept_settlement_quest', {
      p_character_id: characterId,
      p_quest_id: quest.quest_id,
    })

    if (error) {
      setMessage(errorMessage(error.message))
      setBusyId(null)
      return
    }

    setMessage(`Поручение «${quest.title}» принято.`)
    await loadQuests()
    setBusyId(null)
  }

  async function abandon(quest: SettlementQuest) {
    if (!quest.assignment_id) return
    if (!window.confirm(`Отказаться от поручения «${quest.title}»?`)) return

    setBusyId(quest.quest_id)
    setMessage('')

    const { error } = await supabase.rpc('abandon_settlement_quest', {
      p_character_id: characterId,
      p_assignment_id: quest.assignment_id,
    })

    if (error) {
      setMessage(errorMessage(error.message))
      setBusyId(null)
      return
    }

    setMessage(`Поручение «${quest.title}» отменено.`)
    await loadQuests()
    setBusyId(null)
  }

  async function complete(quest: SettlementQuest) {
    if (!quest.assignment_id) return

    setBusyId(quest.quest_id)
    setMessage('')

    const { error } = await supabase.rpc('complete_settlement_quest', {
      p_character_id: characterId,
      p_assignment_id: quest.assignment_id,
    })

    if (error) {
      setMessage(errorMessage(error.message))
      setBusyId(null)
      return
    }

    await Promise.all([
      Promise.resolve(onProgressChanged?.()),
      Promise.resolve(onInventoryChanged?.()),
    ])

    setMessage(
      `Поручение выполнено. Награда: ${quest.reward_gold.toLocaleString('ru-RU')} золота · ${quest.reward_experience.toLocaleString('ru-RU')} опыта.`,
    )
    await loadQuests()
    setBusyId(null)
  }

  if (loading) {
    return (
      <section className="settlement-quests">
        <p className="muted">Проверяем доску поручений…</p>
      </section>
    )
  }

  return (
    <section className="settlement-quests">
      <div className="quest-board-heading">
        <div>
          <span className="eyebrow">ДОСКА ПОРУЧЕНИЙ</span>
          <h4>{settlementName}</h4>
          <p className="muted">Можно держать до трёх активных поручений одновременно.</p>
        </div>
        <span className="badge">{activeCount}/3 активно</span>
      </div>

      {message && <p className="form-message" aria-live="polite">{message}</p>}

      {quests.length === 0 ? (
        <div className="quest-empty">
          <strong>Сейчас поручений нет.</strong>
          <span>Загляни позже — ГМ может добавить новые задачи для этого поселения.</span>
        </div>
      ) : (
        <>
          {active.length > 0 && (
            <div className="quest-section">
              <div className="quest-section-title">
                <h5>Активные</h5>
                <span>{active.length}</span>
              </div>

              <div className="quest-grid">
                {active.map((quest) => {
                  const percent = Math.min(100, Math.round((quest.progress / quest.objective_target) * 100))
                  return (
                    <article className="quest-card active" key={quest.quest_id}>
                      <div className="quest-card-top">
                        <div>
                          <span className={`quest-theme theme-${quest.theme}`}>{themeLabels[quest.theme]}</span>
                          <h5>{quest.title}</h5>
                        </div>
                        <span className="quest-level">УР. {quest.min_level}+</span>
                      </div>

                      <p>{quest.description}</p>

                      <div className="quest-objective">
                        <strong>{objectiveText(quest)}</strong>
                        <span>{quest.progress}/{quest.objective_target}</span>
                      </div>
                      <div className="quest-progress" aria-label={`Прогресс ${percent}%`}>
                        <span style={{ width: `${percent}%` }} />
                      </div>

                      <div className="quest-reward-row">
                        <span>Золото <strong>{quest.reward_gold.toLocaleString('ru-RU')}</strong></span>
                        <span>Опыт <strong>{quest.reward_experience.toLocaleString('ru-RU')}</strong></span>
                      </div>

                      <div className="quest-actions">
                        <button
                          className="primary-button"
                          type="button"
                          disabled={!quest.can_complete || busyId !== null}
                          onClick={() => void complete(quest)}
                        >
                          {busyId === quest.quest_id
                            ? 'Проверяем…'
                            : quest.can_complete
                              ? 'Сдать поручение'
                              : 'Условия не выполнены'}
                        </button>
                        <button
                          className="ghost-button"
                          type="button"
                          disabled={busyId !== null}
                          onClick={() => void abandon(quest)}
                        >
                          Отказаться
                        </button>
                      </div>
                    </article>
                  )
                })}
              </div>
            </div>
          )}

          <div className="quest-section">
            <div className="quest-section-title">
              <h5>Доступные поручения</h5>
              <span>{available.length}</span>
            </div>

            {available.length === 0 ? (
              <p className="muted">Других поручений сейчас нет.</p>
            ) : (
              <div className="quest-grid">
                {available.map((quest) => {
                  const cooldown = formatCooldown(quest.cooldown_remaining_seconds)
                  const permanentlyDone = quest.cooldown_remaining_seconds < 0

                  return (
                    <article className="quest-card" key={quest.quest_id}>
                      <div className="quest-card-top">
                        <div>
                          <span className={`quest-theme theme-${quest.theme}`}>{themeLabels[quest.theme]}</span>
                          <h5>{quest.title}</h5>
                        </div>
                        <span className="quest-level">УР. {quest.min_level}+</span>
                      </div>

                      <p>{quest.description}</p>
                      <div className="quest-objective"><strong>{objectiveText(quest)}</strong></div>

                      <div className="quest-reward-row">
                        <span>Золото <strong>{quest.reward_gold.toLocaleString('ru-RU')}</strong></span>
                        <span>Опыт <strong>{quest.reward_experience.toLocaleString('ru-RU')}</strong></span>
                      </div>

                      <button
                        className="primary-button quest-accept"
                        type="button"
                        disabled={!quest.can_accept || busyId !== null}
                        onClick={() => void accept(quest)}
                      >
                        {busyId === quest.quest_id
                          ? 'Принимаем…'
                          : permanentlyDone
                            ? 'Уже выполнено'
                            : cooldown
                              ? `Снова через ${cooldown}`
                              : activeCount >= 3
                                ? 'Лимит 3/3'
                                : 'Принять поручение'}
                      </button>
                    </article>
                  )
                })}
              </div>
            )}
          </div>
        </>
      )}
    </section>
  )
}
