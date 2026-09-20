import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import './settlementQuests.css'

type QuestTheme = 'general' | 'protection' | 'nature' | 'research' | 'arcane' | 'combat' | 'delivery'
type ObjectiveType = 'discover_sectors' | 'complete_expeditions' | 'complete_dungeons' | 'defeat_enemies' | 'deliver_item'

type GmQuest = {
  quest_id: string
  sector_id: number
  settlement_name: string
  title: string
  description: string
  theme: QuestTheme
  objective_type: ObjectiveType
  objective_target: number
  target_item_definition_id: string | null
  target_item_name: string | null
  reward_gold: number
  reward_experience: number
  min_level: number
  repeatable: boolean
  cooldown_hours: number
  enabled: boolean
  sort_order: number
  active_assignments: number
  total_completions: number
}

type Settlement = {
  id: number
  title: string | null
  content_type: string
  settlement_level: number
}

type DeliveryItem = {
  id: string
  name: string
  category: string
  stackable: boolean
}

type Draft = {
  id: string | null
  sectorId: number
  title: string
  description: string
  theme: QuestTheme
  objectiveType: ObjectiveType
  objectiveTarget: number
  targetItemId: string
  rewardGold: number
  rewardExperience: number
  minLevel: number
  repeatable: boolean
  cooldownHours: number
  enabled: boolean
  sortOrder: number
}

const themeLabels: Record<QuestTheme, string> = {
  general: 'Обычное',
  protection: 'Защита',
  nature: 'Природа',
  research: 'Исследование',
  arcane: 'Магия',
  combat: 'Бой',
  delivery: 'Доставка',
}

const objectiveLabels: Record<ObjectiveType, string> = {
  discover_sectors: 'Открыть новые сектора',
  complete_expeditions: 'Завершить экспедиции',
  complete_dungeons: 'Завершить подземелья',
  defeat_enemies: 'Победить противников',
  deliver_item: 'Принести предметы',
}

function emptyDraft(settlementId = 0): Draft {
  return {
    id: null,
    sectorId: settlementId,
    title: '',
    description: '',
    theme: 'general',
    objectiveType: 'discover_sectors',
    objectiveTarget: 1,
    targetItemId: '',
    rewardGold: 25,
    rewardExperience: 20,
    minLevel: 1,
    repeatable: true,
    cooldownHours: 12,
    enabled: true,
    sortOrder: 0,
  }
}

export function GmSettlementQuests() {
  const [quests, setQuests] = useState<GmQuest[]>([])
  const [settlements, setSettlements] = useState<Settlement[]>([])
  const [deliveryItems, setDeliveryItems] = useState<DeliveryItem[]>([])
  const [draft, setDraft] = useState<Draft>(() => emptyDraft())
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  async function loadData(clearMessage = true) {
    setLoading(true)
    if (clearMessage) setMessage('')

    const [questResult, worldResult, itemResult] = await Promise.all([
      supabase.rpc('gm_list_settlement_quests'),
      supabase.rpc('get_gm_map_state'),
      supabase
        .from('item_definitions')
        .select('id, name, category, stackable')
        .eq('stackable', true)
        .in('category', ['material', 'consumable', 'quest'])
        .order('name', { ascending: true }),
    ])

    const error = questResult.error ?? worldResult.error ?? itemResult.error
    if (error) {
      setMessage(error.message)
      setLoading(false)
      return
    }

    const nextSettlements = ((worldResult.data as Settlement[] | null) ?? [])
      .filter((sector) => sector.content_type === 'settlement')
      .sort((a, b) => a.id - b.id)

    setQuests((questResult.data as GmQuest[] | null) ?? [])
    setSettlements(nextSettlements)
    setDeliveryItems((itemResult.data as DeliveryItem[] | null) ?? [])

    setDraft((current) => current.sectorId
      ? current
      : emptyDraft(nextSettlements[0]?.id ?? 0))

    setLoading(false)
  }

  useEffect(() => {
    void loadData()
  }, [])

  const selectedSettlement = useMemo(
    () => settlements.find((entry) => entry.id === draft.sectorId) ?? null,
    [settlements, draft.sectorId],
  )

  function editQuest(quest: GmQuest) {
    setDraft({
      id: quest.quest_id,
      sectorId: quest.sector_id,
      title: quest.title,
      description: quest.description,
      theme: quest.theme,
      objectiveType: quest.objective_type,
      objectiveTarget: quest.objective_target,
      targetItemId: quest.target_item_definition_id ?? '',
      rewardGold: quest.reward_gold,
      rewardExperience: quest.reward_experience,
      minLevel: quest.min_level,
      repeatable: quest.repeatable,
      cooldownHours: quest.cooldown_hours,
      enabled: quest.enabled,
      sortOrder: quest.sort_order,
    })
    setMessage('')
    window.scrollTo({ top: 0, behavior: 'smooth' })
  }

  function newQuest() {
    setDraft(emptyDraft(settlements[0]?.id ?? 0))
    setMessage('')
  }

  async function saveQuest() {
    if (!draft.sectorId) {
      setMessage('Выбери поселение.')
      return
    }
    if (!draft.title.trim()) {
      setMessage('Нужно название поручения.')
      return
    }
    if (draft.objectiveType === 'deliver_item' && !draft.targetItemId) {
      setMessage('Для доставки нужно выбрать предмет.')
      return
    }

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('gm_save_settlement_quest', {
      p_id: draft.id,
      p_sector_id: draft.sectorId,
      p_title: draft.title.trim(),
      p_description: draft.description.trim(),
      p_theme: draft.theme,
      p_objective_type: draft.objectiveType,
      p_objective_target: Math.max(1, Math.floor(draft.objectiveTarget)),
      p_target_item_definition_id: draft.objectiveType === 'deliver_item' ? draft.targetItemId : null,
      p_reward_gold: Math.max(0, Math.floor(draft.rewardGold)),
      p_reward_experience: Math.max(0, Math.floor(draft.rewardExperience)),
      p_min_level: Math.max(1, Math.floor(draft.minLevel)),
      p_repeatable: draft.repeatable,
      p_cooldown_hours: Math.max(0, Math.floor(draft.cooldownHours)),
      p_enabled: draft.enabled,
      p_sort_order: Math.floor(draft.sortOrder),
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    const successMessage = draft.id ? 'Поручение обновлено.' : 'Поручение создано.'
    await loadData(false)
    setMessage(successMessage)
    setBusy(false)
  }

  async function toggleQuest(quest: GmQuest) {
    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('gm_set_settlement_quest_enabled', {
      p_quest_id: quest.quest_id,
      p_enabled: !quest.enabled,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    await loadData()
    setBusy(false)
  }

  if (loading) {
    return <section className="panel"><p className="muted">Загружаем поручения поселений…</p></section>
  }

  return (
    <div className="gm-quest-layout">
      <section className="panel gm-quest-editor">
        <div className="section-heading">
          <div>
            <span className="eyebrow">ПОРУЧЕНИЯ ПОСЕЛЕНИЙ</span>
            <h2>{draft.id ? 'Редактирование поручения' : 'Новое поручение'}</h2>
          </div>
          {draft.id && <button className="ghost-button" type="button" onClick={newQuest}>Новое</button>}
        </div>

        <p className="muted">
          Темы уже готовы для религий: природа, исследование, магия, защита и другие.
          Прогресс считается сервером по реальным действиям игрока после принятия поручения.
        </p>

        {message && <p className="gm-notice" aria-live="polite">{message}</p>}

        <div className="gm-quest-form">
          <label>
            <span>Поселение</span>
            <select
              value={draft.sectorId}
              onChange={(event) => setDraft((current) => ({ ...current, sectorId: Number(event.target.value) }))}
            >
              {settlements.map((sector) => (
                <option key={sector.id} value={sector.id}>
                  {sector.title || `Поселение #${sector.id}`} · сектор {sector.id} · ур. {sector.settlement_level}
                </option>
              ))}
            </select>
          </label>

          <label className="wide">
            <span>Название</span>
            <input
              value={draft.title}
              maxLength={100}
              onChange={(event) => setDraft((current) => ({ ...current, title: event.target.value }))}
              placeholder="Например: Разведка окрестностей"
            />
          </label>

          <label className="wide">
            <span>Описание</span>
            <textarea
              value={draft.description}
              maxLength={1200}
              onChange={(event) => setDraft((current) => ({ ...current, description: event.target.value }))}
              placeholder="Что именно просит поселение и зачем."
            />
          </label>

          <label>
            <span>Тема</span>
            <select
              value={draft.theme}
              onChange={(event) => setDraft((current) => ({ ...current, theme: event.target.value as QuestTheme }))}
            >
              {Object.entries(themeLabels).map(([value, label]) => (
                <option key={value} value={value}>{label}</option>
              ))}
            </select>
          </label>

          <label>
            <span>Цель</span>
            <select
              value={draft.objectiveType}
              onChange={(event) => setDraft((current) => ({
                ...current,
                objectiveType: event.target.value as ObjectiveType,
                targetItemId: event.target.value === 'deliver_item' ? current.targetItemId : '',
              }))}
            >
              {Object.entries(objectiveLabels).map(([value, label]) => (
                <option key={value} value={value}>{label}</option>
              ))}
            </select>
          </label>

          <label>
            <span>Количество</span>
            <input
              type="number"
              min={1}
              max={1000}
              value={draft.objectiveTarget}
              onChange={(event) => setDraft((current) => ({ ...current, objectiveTarget: Number(event.target.value) }))}
            />
          </label>

          {draft.objectiveType === 'deliver_item' && (
            <label>
              <span>Предмет для сдачи</span>
              <select
                value={draft.targetItemId}
                onChange={(event) => setDraft((current) => ({ ...current, targetItemId: event.target.value }))}
              >
                <option value="">Выбрать предмет</option>
                {deliveryItems.map((item) => (
                  <option key={item.id} value={item.id}>{item.name}</option>
                ))}
              </select>
            </label>
          )}

          <label>
            <span>Минимальный уровень</span>
            <input
              type="number"
              min={1}
              value={draft.minLevel}
              onChange={(event) => setDraft((current) => ({ ...current, minLevel: Number(event.target.value) }))}
            />
          </label>

          <label>
            <span>Золото</span>
            <input
              type="number"
              min={0}
              value={draft.rewardGold}
              onChange={(event) => setDraft((current) => ({ ...current, rewardGold: Number(event.target.value) }))}
            />
          </label>

          <label>
            <span>Опыт</span>
            <input
              type="number"
              min={0}
              value={draft.rewardExperience}
              onChange={(event) => setDraft((current) => ({ ...current, rewardExperience: Number(event.target.value) }))}
            />
          </label>

          <label>
            <span>Кулдаун, часов</span>
            <input
              type="number"
              min={0}
              max={720}
              value={draft.cooldownHours}
              disabled={!draft.repeatable}
              onChange={(event) => setDraft((current) => ({ ...current, cooldownHours: Number(event.target.value) }))}
            />
          </label>

          <label>
            <span>Порядок</span>
            <input
              type="number"
              value={draft.sortOrder}
              onChange={(event) => setDraft((current) => ({ ...current, sortOrder: Number(event.target.value) }))}
            />
          </label>

          <label className="quest-check">
            <input
              type="checkbox"
              checked={draft.repeatable}
              onChange={(event) => setDraft((current) => ({ ...current, repeatable: event.target.checked }))}
            />
            <span>Повторяемое</span>
          </label>

          <label className="quest-check">
            <input
              type="checkbox"
              checked={draft.enabled}
              onChange={(event) => setDraft((current) => ({ ...current, enabled: event.target.checked }))}
            />
            <span>Доступно игрокам</span>
          </label>
        </div>

        <div className="action-row">
          <button className="primary-button" type="button" disabled={busy} onClick={() => void saveQuest()}>
            {busy ? 'Сохраняем…' : draft.id ? 'Сохранить изменения' : 'Создать поручение'}
          </button>
          {selectedSettlement && <span className="badge">{selectedSettlement.title || `Сектор ${selectedSettlement.id}`}</span>}
        </div>
      </section>

      <section className="panel">
        <div className="section-heading">
          <div>
            <span className="eyebrow">КАТАЛОГ</span>
            <h2>Все поручения</h2>
          </div>
          <span className="badge">{quests.length}</span>
        </div>

        <div className="gm-quest-list">
          {quests.length === 0 && <p className="muted">Поручений пока нет.</p>}
          {quests.map((quest) => (
            <article className={`gm-quest-row ${quest.enabled ? '' : 'disabled'}`} key={quest.quest_id}>
              <div className="gm-quest-row-main">
                <div>
                  <span className={`quest-theme theme-${quest.theme}`}>{themeLabels[quest.theme]}</span>
                  <strong>{quest.title}</strong>
                  <small>{quest.settlement_name} · сектор {quest.sector_id}</small>
                </div>
                <div className="gm-quest-stats">
                  <span>Активно <strong>{quest.active_assignments}</strong></span>
                  <span>Выполнено <strong>{quest.total_completions}</strong></span>
                </div>
              </div>

              <p>{quest.description}</p>
              <div className="gm-quest-meta">
                <span>{objectiveLabels[quest.objective_type]} ×{quest.objective_target}</span>
                {quest.target_item_name && <span>{quest.target_item_name}</span>}
                <span>{quest.reward_gold} золота</span>
                <span>{quest.reward_experience} опыта</span>
                <span>УР. {quest.min_level}+</span>
                <span>{quest.repeatable ? `повтор · ${quest.cooldown_hours} ч` : 'одноразовое'}</span>
              </div>

              <div className="action-row">
                <button className="ghost-button" type="button" disabled={busy} onClick={() => editQuest(quest)}>
                  Редактировать
                </button>
                <button className="ghost-button" type="button" disabled={busy} onClick={() => void toggleQuest(quest)}>
                  {quest.enabled ? 'Скрыть' : 'Включить'}
                </button>
              </div>
            </article>
          ))}
        </div>
      </section>
    </div>
  )
}
