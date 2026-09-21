import { userFacingError } from '../lib/userError'
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
  reward_reputation: number
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

type SettlementReputation = {
  sector_id: number
  settlement_name: string
  reputation_points: number
  reputation_level: number
  current_level_points: number
  next_level_points: number
  daily_earned: number
  daily_cap: number
  daily_remaining: number
  shop_discount_percent: number
  quest_gold_bonus_percent: number
  quest_experience_bonus_percent: number
  current_perk_text: string
  next_perk_text: string
  level10_reward_item_id: string | null
  level10_reward_item_name: string | null
  level10_reward_item_description: string | null
  level10_reward_claimed: boolean
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
    case 'discover_sectors': return `Открыть новых секторов: ${quest.objective_target}`
    case 'complete_expeditions': return `Завершить экспедиций: ${quest.objective_target}`
    case 'complete_dungeons': return `Завершить подземелий: ${quest.objective_target}`
    case 'defeat_enemies': return `Победить противников: ${quest.objective_target}`
    case 'deliver_item': return `Принести: ${quest.target_item_name ?? 'предмет'} ×${quest.objective_target}`
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
  return userFacingError(raw)
}

export function SettlementQuestsPanel({
  characterId,
  sectorId,
  onProgressChanged,
  onInventoryChanged,
}: Props) {
  const [quests, setQuests] = useState<SettlementQuest[]>([])
  const [reputation, setReputation] = useState<SettlementReputation | null>(null)
  const [loading, setLoading] = useState(true)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [message, setMessage] = useState('')

  async function loadQuests() {
    setLoading(true)

    const [questResult, reputationResult] = await Promise.all([
      supabase.rpc('get_settlement_quests_v2', {
        p_character_id: characterId,
        p_sector_id: sectorId,
      }),
      supabase.rpc('get_settlement_reputation', {
        p_character_id: characterId,
        p_sector_id: sectorId,
      }),
    ])

    const error = questResult.error ?? reputationResult.error
    if (error) {
      setMessage(errorMessage(error.message))
      setQuests([])
      setReputation(null)
      setLoading(false)
      return
    }

    setQuests((questResult.data as SettlementQuest[] | null) ?? [])
    setReputation(((reputationResult.data as SettlementReputation[] | null) ?? [])[0] ?? null)
    setLoading(false)
  }

  useEffect(() => {
    setMessage('')
    void loadQuests()
  }, [characterId, sectorId])

  const activeCount = quests[0]?.active_quest_count ?? 0
  const settlementName = reputation?.settlement_name ?? quests[0]?.settlement_name ?? 'Поселение'
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

    await loadQuests()
    setMessage(`Поручение «${quest.title}» принято.`)
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

    await loadQuests()
    setMessage(`Поручение «${quest.title}» отменено.`)
    setBusyId(null)
  }

  async function complete(quest: SettlementQuest) {
    if (!quest.assignment_id) return

    const previousReputation = reputation?.reputation_points ?? 0
    const previousLevel = reputation?.reputation_level ?? 1

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

    await loadQuests()

    const { data: repData } = await supabase.rpc('get_settlement_reputation', {
      p_character_id: characterId,
      p_sector_id: sectorId,
    })
    const nextReputation = ((repData as SettlementReputation[] | null) ?? [])[0] ?? null
    if (nextReputation) setReputation(nextReputation)

    const repGain = Math.max(0, (nextReputation?.reputation_points ?? previousReputation) - previousReputation)
    const levelUp = (nextReputation?.reputation_level ?? previousLevel) > previousLevel

    setMessage(
      levelUp
        ? `Поручение выполнено. Репутация +${repGain}. Новый уровень репутации: ${nextReputation?.reputation_level}/10.`
        : `Поручение выполнено. Репутация +${repGain}. Награды начислены с учётом бонусов города.`,
    )
    setBusyId(null)
  }

  if (loading) {
    return <section className="settlement-quests"><p className="muted">Проверяем доску поручений…</p></section>
  }

  const reputationSpan = reputation
    ? Math.max(1, reputation.next_level_points - reputation.current_level_points)
    : 1
  const reputationProgress = reputation
    ? Math.min(100, Math.max(0, Math.round(
        ((reputation.reputation_points - reputation.current_level_points) / reputationSpan) * 100,
      )))
    : 0

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

      {reputation && (
        <article className="settlement-reputation-card">
          <div className="reputation-heading">
            <div>
              <span className="eyebrow">РЕПУТАЦИЯ ГОРОДА</span>
              <h5>Уровень {reputation.reputation_level}/10</h5>
            </div>
            <strong>{reputation.reputation_points}/2700</strong>
          </div>

          <div className="reputation-progress">
            <span style={{ width: `${reputation.reputation_level >= 10 ? 100 : reputationProgress}%` }} />
          </div>

          <div className="reputation-progress-labels">
            <span>
              {reputation.reputation_level >= 10
                ? 'Максимальная репутация'
                : `До следующего уровня: ${reputation.next_level_points - reputation.reputation_points}`}
            </span>
            <span>Сегодня {reputation.daily_earned}/{reputation.daily_cap}</span>
          </div>

          <div className="reputation-perks">
            <span>Магазин <strong>−{reputation.shop_discount_percent}%</strong></span>
            <span>Золото поручений <strong>+{reputation.quest_gold_bonus_percent}%</strong></span>
            <span>Опыт поручений <strong>+{reputation.quest_experience_bonus_percent}%</strong></span>
          </div>

          <p className="reputation-current-perk">{reputation.current_perk_text}</p>

          {reputation.reputation_level < 10 && (
            <p className="reputation-next-perk">
              <strong>Следующий уровень:</strong> {reputation.next_perk_text}
            </p>
          )}

          {reputation.level10_reward_item_name && (
            <div className="reputation-final-reward">
              <span>НАГРАДА 10 УРОВНЯ</span>
              <strong>{reputation.level10_reward_item_name}</strong>
              <small>
                {reputation.level10_reward_claimed
                  ? 'Получено.'
                  : reputation.level10_reward_item_description ?? 'Уникальная награда города.'}
              </small>
            </div>
          )}
        </article>
      )}

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
              <div className="quest-section-title"><h5>Активные</h5><span>{active.length}</span></div>
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
                        <span>Репутация <strong>+{quest.reward_reputation}</strong></span>
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
            <div className="quest-section-title"><h5>Доступные поручения</h5><span>{available.length}</span></div>
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
                        <span>Репутация <strong>+{quest.reward_reputation}</strong></span>
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
