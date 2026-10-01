import { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { userFacingError } from '../lib/userError'

type CampModuleType = 'scout_post' | 'hunting_table' | 'training_yard' | 'trading_post' | 'field_kitchen'
type AccessMode = 'private' | 'party' | 'open'
type HuntFocus = 'meat' | 'hide' | 'herbs' | 'supplies'

type CampState = {
  camp: null | {
    owner_character_id: string
    owner_name: string
    sector_id: number
    camp_level: number
    access_mode: AccessMode
    camp_name: string
    placed_at: string
    expires_at: string
    module_slots: number
    storage_capacity: number
    is_owner: boolean
  }
  modules: Array<{ module_type: CampModuleType; built_at: string }>
  active_action: null | {
    id: string
    action_type: 'rest' | 'scout'
    target_sector_id: number | null
    started_at: string
    ends_at: string
  }
  preparation: null | {
    preparation_type: 'physical' | 'magic' | 'fortify'
    bonus_percent: number
    expires_at: string
  }
  scout_reports: Array<{
    id: string
    sector_id: number
    terrain_type: string
    content_hint: string
    danger_level: number
    expires_at: string
  }>
  scout_targets: Array<{ sector_id: number }>
  storage: Array<{
    id: string
    item_definition_id: string
    item_name: string
    rarity: string
    quantity: number
    custom_name: string | null
    enhancement_level: number
    awakening_level: number
  }>
  trade_offers: Array<{
    id: string
    offered_by_character_id: string
    offered_by_name: string
    offered_item_definition_id: string
    offered_item_name: string
    offered_quantity: number
    offered_rarity: string
    offered_custom_name: string | null
    requested_item_definition_id: string
    requested_item_name: string
    requested_quantity: number
    expires_at: string
    is_mine: boolean
  }>
  resources: {
    field_timber: number
    field_fiber: number
    smithing_scrap: number
  }
  daily_event: null | {
    kind: string
    title: string
    claimed: boolean
  }
}

type InventoryItem = {
  id: string
  item_definition_id: string
  quantity: number
  custom_name: string | null
  metadata: Record<string, unknown>
  enhancement_level: number
  awakening_level: number
  bound_to_character_id: string | null
  item_definitions: {
    id: string
    slug: string
    name: string
    category: string
    rarity: string
    stackable: boolean
    trade_policy: 'tradeable' | 'bind_on_equip' | 'bound'
  } | Array<{
    id: string
    slug: string
    name: string
    category: string
    rarity: string
    stackable: boolean
    trade_policy: 'tradeable' | 'bind_on_equip' | 'bound'
  }>
}

type ItemDefinition = {
  id: string
  name: string
  category: string
  rarity: string
  stackable: boolean
  trade_policy: 'tradeable' | 'bind_on_equip' | 'bound'
}

type Props = {
  characterId: string
  sectorId: number
  campOwnerCharacterId?: string | null
  canPlace: boolean
  blocked?: boolean
  blockingReason?: string
  onChanged?: () => Promise<unknown> | void
  onInventoryChanged?: () => Promise<unknown> | void
}

const moduleInfo: Record<CampModuleType, { name: string; description: string; cost: string }> = {
  scout_post: {
    name: 'Разведывательный пост',
    description: '20 минут на разведку соседнего закрытого сектора без его полного открытия.',
    cost: '4 леса · 2 волокна',
  },
  hunting_table: {
    name: 'Охотничий стол',
    description: 'Открывает направленную охоту и добавляет +1 к найденной добыче.',
    cost: '3 леса · 2 волокна',
  },
  training_yard: {
    name: 'Тренировочная площадка',
    description: 'Выбери полевую подготовку на 45 минут: физический урон, магический урон или защита.',
    cost: '5 леса · 2 кузнечного лома',
  },
  trading_post: {
    name: 'Торговый навес',
    description: 'Локальный безопасный бартер предмет на предмет через серверный эскроу.',
    cost: '4 леса · 3 волокна',
  },
  field_kitchen: {
    name: 'Полевая кухня',
    description: 'Мясо + трава превращаются в полевое рагу для восстановления ОЗ и маны.',
    cost: '3 леса · 3 волокна',
  },
}

const moduleOrder = Object.keys(moduleInfo) as CampModuleType[]

const focusLabels: Record<HuntFocus, string> = {
  meat: 'Мясо',
  hide: 'Шкуры',
  herbs: 'Травы',
  supplies: 'Стройматериалы',
}

const accessLabels: Record<AccessMode, string> = {
  private: 'Личный',
  party: 'Только пати',
  open: 'Открытый',
}

function definitionOf(item: InventoryItem) {
  return Array.isArray(item.item_definitions) ? item.item_definitions[0] : item.item_definitions
}

function timeLabel(value: string) {
  return new Date(value).toLocaleString('ru-RU', {
    day: '2-digit',
    month: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  })
}

function campError(raw: string) {
  const pairs: Array<[string, string]> = [
    ['NOT_ENOUGH_INGREDIENTS', 'Не хватает лагерных материалов. Их можно добыть охотой.'],
    ['CAMP_ALREADY_ACTIVE', 'У тебя уже есть лагерь. Сначала сверни его, если хочешь перенести базу.'],
    ['CAMP_MODULE_SLOTS_FULL', 'Все места под постройки заняты. Улучши лагерь или разбери один из модулей.'],
    ['CAMP_STORAGE_FULL', 'Лагерный склад заполнен.'],
    ['CAMP_ACCESS_DENIED', 'Этот лагерь сейчас закрыт для тебя.'],
    ['CAMP_ACTION_NOT_READY', 'Это действие ещё не завершилось.'],
    ['CHARACTER_BUSY', 'Персонаж сейчас занят другим походом, боем или действием.'],
    ['HUNTING_TABLE_REQUIRED', 'Для направленной охоты нужен доступный охотничий стол в этом секторе.'],
    ['CAMP_COOKING_NEEDS_MEAT', 'Для рагу нужна хотя бы одна единица мяса или рыбы с охоты.'],
    ['CAMP_COOKING_NEEDS_HERBS', 'Для рагу нужны охотничьи травы.'],
    ['ITEM_NOT_TRADEABLE', 'Этот предмет нельзя обменивать.'],
    ['REQUESTED_ITEM_NOT_TRADEABLE', 'Этот предмет нельзя запрашивать в бартере.'],
    ['REQUESTED_ITEM_NOT_AVAILABLE', 'У тебя нет подходящего предмета для этого обмена.'],
    ['TRADE_OFFER_NOT_OPEN', 'Предложение уже закрыто или истекло.'],
    ['CAMP_EVENT_ALREADY_RESOLVED', 'Сегодня ты уже разобрался с лагерным событием.'],
  ]
  return pairs.find(([key]) => raw.includes(key))?.[1] ?? userFacingError(raw)
}

export function CampPanel({
  characterId,
  sectorId,
  campOwnerCharacterId,
  canPlace,
  blocked = false,
  blockingReason = '',
  onChanged,
  onInventoryChanged,
}: Props) {
  const ownerId = campOwnerCharacterId ?? characterId
  const [state, setState] = useState<CampState | null>(null)
  const [inventory, setInventory] = useState<InventoryItem[]>([])
  const [equippedIds, setEquippedIds] = useState<Set<string>>(new Set())
  const [definitions, setDefinitions] = useState<ItemDefinition[]>([])
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const [tick, setTick] = useState(Date.now())
  const [storageItemId, setStorageItemId] = useState('')
  const [storageQty, setStorageQty] = useState(1)
  const [offerItemId, setOfferItemId] = useState('')
  const [offerQty, setOfferQty] = useState(1)
  const [requestDefinitionId, setRequestDefinitionId] = useState('')
  const [requestQty, setRequestQty] = useState(1)

  const load = useCallback(async (silent = false) => {
    if (!silent) setLoading(true)
    const [stateResult, itemsResult, equipmentResult, definitionsResult] = await Promise.all([
      supabase.rpc('get_camp_state', {
        p_character_id: characterId,
        p_camp_owner_character_id: ownerId,
      }),
      supabase
        .from('character_items')
        .select(`
          id,item_definition_id,quantity,custom_name,metadata,enhancement_level,awakening_level,bound_to_character_id,
          item_definitions(id,slug,name,category,rarity,stackable,trade_policy)
        `)
        .eq('character_id', characterId)
        .order('acquired_at', { ascending: true }),
      supabase
        .from('character_equipment')
        .select('character_item_id')
        .eq('character_id', characterId),
      supabase
        .from('item_definitions')
        .select('id,name,category,rarity,stackable,trade_policy')
        .neq('trade_policy', 'bound')
        .order('name'),
    ])

    const error = stateResult.error ?? itemsResult.error ?? equipmentResult.error ?? definitionsResult.error
    if (error) {
      if (!silent) setMessage(campError(error.message))
      if (!silent) setLoading(false)
      return
    }

    setState((stateResult.data as CampState | null) ?? null)
    setInventory((itemsResult.data as InventoryItem[] | null) ?? [])
    setEquippedIds(new Set(((equipmentResult.data as Array<{ character_item_id: string }> | null) ?? []).map((x) => x.character_item_id)))
    setDefinitions((definitionsResult.data as ItemDefinition[] | null) ?? [])
    if (!silent) setLoading(false)
  }, [characterId, ownerId])

  useEffect(() => {
    void load()
  }, [load])

  useEffect(() => {
    const id = window.setInterval(() => setTick(Date.now()), 1000)
    return () => window.clearInterval(id)
  }, [])

  const moduleTypes = useMemo(
    () => new Set((state?.modules ?? []).map((entry) => entry.module_type)),
    [state?.modules],
  )

  const inventoryCandidates = useMemo(
    () => inventory.filter((item) => !equippedIds.has(item.id)),
    [inventory, equippedIds],
  )

  const tradeCandidates = useMemo(
    () => inventoryCandidates.filter((item) => {
      const def = definitionOf(item)
      if (!def || def.trade_policy === 'bound') return false
      if (def.trade_policy === 'bind_on_equip' && item.bound_to_character_id) return false
      return item.metadata?.inventory_locked !== true
    }),
    [inventoryCandidates],
  )

  async function run(
    action: () => PromiseLike<{ error: { message: string } | null }>,
    success: string,
    inventoryChanged = false,
  ) {
    if (busy) return
    setBusy(true)
    setMessage('')
    const { error } = await action()
    if (error) {
      setMessage(campError(error.message))
      setBusy(false)
      return
    }
    if (inventoryChanged) await Promise.resolve(onInventoryChanged?.())
    await Promise.all([load(true), Promise.resolve(onChanged?.())])
    setMessage(success)
    setBusy(false)
  }

  async function place() {
    await run(
      () => supabase.rpc('place_character_camp', {
        p_character_id: characterId,
        p_sector_id: sectorId,
        p_specialization: 'base',
      }),
      'Лагерь разбит. Теперь это полевая база: развивай её ресурсами и выбирай постройки.',
    )
  }

  async function upgrade() {
    await run(
      () => supabase.rpc('upgrade_character_camp', { p_character_id: characterId }),
      'Лагерь улучшен.',
      true,
    )
  }

  async function repair() {
    await run(
      () => supabase.rpc('repair_character_camp', { p_character_id: characterId }),
      'Лагерь отремонтирован. Следующий ремонт понадобится через 7 дней.',
      true,
    )
  }

  async function buildModule(type: CampModuleType) {
    await run(
      () => supabase.rpc('build_camp_module', { p_character_id: characterId, p_module_type: type }),
      `Постройка «${moduleInfo[type].name}» готова.`,
      true,
    )
  }

  async function removeModule(type: CampModuleType) {
    await run(
      () => supabase.rpc('remove_camp_module', { p_character_id: characterId, p_module_type: type }),
      'Постройка разобрана. Часть материалов возвращена.',
      true,
    )
  }

  async function setAccess(access: AccessMode) {
    await run(
      () => supabase.rpc('set_camp_access', { p_character_id: characterId, p_access_mode: access }),
      `Доступ к лагерю: ${accessLabels[access].toLowerCase()}.`,
    )
  }

  async function startAction(actionType: 'rest' | 'scout', target?: number) {
    await run(
      () => supabase.rpc('start_camp_action', {
        p_character_id: characterId,
        p_camp_owner_character_id: state?.camp?.owner_character_id ?? ownerId,
        p_action_type: actionType,
        p_target_sector_id: target ?? null,
      }),
      actionType === 'rest' ? 'Отдых начался · 30 минут.' : 'Разведчики вышли из лагеря · 20 минут.',
    )
  }

  async function finishAction() {
    if (!state?.active_action) return
    await run(
      () => supabase.rpc('finish_camp_action', {
        p_character_id: characterId,
        p_action_id: state.active_action!.id,
      }),
      'Лагерное действие завершено.',
      true,
    )
  }

  async function prepare(type: 'physical' | 'magic' | 'fortify') {
    const labels = { physical: 'Физическая подготовка', magic: 'Магическая настройка', fortify: 'Стойкость' }
    await run(
      () => supabase.rpc('prepare_at_camp', {
        p_character_id: characterId,
        p_camp_owner_character_id: state?.camp?.owner_character_id ?? ownerId,
        p_preparation_type: type,
      }),
      `${labels[type]} активна на 45 минут.`,
    )
  }

  async function cook() {
    await run(
      () => supabase.rpc('cook_at_camp', {
        p_character_id: characterId,
        p_camp_owner_character_id: state?.camp?.owner_character_id ?? ownerId,
      }),
      'Приготовлено полевое рагу.',
      true,
    )
  }

  async function focusedHunt(focus: HuntFocus) {
    await run(
      () => supabase.rpc('start_hunt_v2', {
        p_character_id: characterId,
        p_sector_id: state?.camp?.sector_id ?? sectorId,
        p_focus: focus,
      }),
      `Охота началась: цель — ${focusLabels[focus].toLowerCase()}. Возвращение через 10 минут.`,
    )
  }

  async function deposit() {
    if (!storageItemId) return
    await run(
      () => supabase.rpc('deposit_camp_storage', {
        p_character_id: characterId,
        p_character_item_id: storageItemId,
        p_quantity: Math.max(1, storageQty),
      }),
      'Предмет оставлен на лагерном складе.',
      true,
    )
  }

  async function withdraw(id: string) {
    await run(
      () => supabase.rpc('withdraw_camp_storage', {
        p_character_id: characterId,
        p_storage_item_id: id,
      }),
      'Предмет возвращён в инвентарь.',
      true,
    )
  }

  async function createOffer() {
    if (!offerItemId || !requestDefinitionId) return
    await run(
      () => supabase.rpc('create_camp_trade_offer', {
        p_character_id: characterId,
        p_camp_owner_character_id: state?.camp?.owner_character_id ?? ownerId,
        p_character_item_id: offerItemId,
        p_offered_quantity: Math.max(1, offerQty),
        p_requested_item_definition_id: requestDefinitionId,
        p_requested_quantity: Math.max(1, requestQty),
      }),
      'Бартер выставлен на 24 часа. Предложенный предмет находится в безопасном эскроу.',
      true,
    )
  }

  async function cancelOffer(id: string) {
    await run(
      () => supabase.rpc('cancel_camp_trade_offer', {
        p_character_id: characterId,
        p_offer_id: id,
      }),
      'Предложение снято, предмет возвращён.',
      true,
    )
  }

  async function acceptOffer(offer: CampState['trade_offers'][number]) {
    const payment = tradeCandidates.find((item) => (
      item.item_definition_id === offer.requested_item_definition_id
      && item.quantity >= offer.requested_quantity
    ))
    if (!payment) {
      setMessage(`Для обмена нужен предмет «${offer.requested_item_name}» ×${offer.requested_quantity}.`)
      return
    }
    await run(
      () => supabase.rpc('accept_camp_trade_offer', {
        p_character_id: characterId,
        p_offer_id: offer.id,
        p_requested_character_item_id: payment.id,
      }),
      'Обмен завершён. Оба предмета переданы атомарно.',
      true,
    )
  }

  async function resolveEvent() {
    await run(
      () => supabase.rpc('resolve_camp_daily_event', {
        p_character_id: characterId,
        p_camp_owner_character_id: state?.camp?.owner_character_id ?? ownerId,
      }),
      'Лагерное событие завершено.',
      true,
    )
  }

  async function dismantle() {
    if (!window.confirm('Свернуть лагерь? Склад и открытые обмены безопасно вернутся владельцам, часть строительных материалов будет возвращена.')) return
    await run(
      () => supabase.rpc('remove_character_camp', { p_character_id: characterId }),
      'Лагерь свёрнут.',
      true,
    )
  }

  if (loading && !state) {
    return <div className="camp-system-card"><p className="muted">Осматриваем стоянку…</p></div>
  }

  const camp = state?.camp ?? null

  if (!camp) {
    return (
      <div className="camp-system-card">
        <span className="eyebrow">ПОЛЕВАЯ БАЗА</span>
        <h4>Разбить лагерь</h4>
        <p className="muted">
          Лагерь ставится бесплатно и может стоять сколько угодно. Раз в 7 дней его нужно чинить лагерными ресурсами, иначе база будет разобрана автоматически. Сам по себе лагерь не даёт боевых бонусов: возможности появляются через постройки и действия.
        </p>
        {message && <p className="form-message">{message}</p>}
        <button
          className="primary-button"
          type="button"
          disabled={busy || blocked || !canPlace}
          title={blocked ? blockingReason : ''}
          onClick={() => void place()}
        >
          {busy ? 'Разбиваем…' : 'Разбить лагерь'}
        </button>
      </div>
    )
  }

  if (camp.is_owner && camp.sector_id !== sectorId) {
    return (
      <div className="camp-system-card">
        <span className="eyebrow">ТВОЙ ЛАГЕРЬ</span>
        <h4>Сектор #{camp.sector_id} · уровень {camp.camp_level}</h4>
        <p className="muted">У тебя уже есть полевая база. Чтобы поставить её в другом месте, сначала сверни старую.</p>
        {message && <p className="form-message">{message}</p>}
        <button className="ghost-button" type="button" disabled={busy} onClick={() => void dismantle()}>
          Свернуть текущий лагерь
        </button>
      </div>
    )
  }

  const isOwner = camp.is_owner
  const activeActionReady = state?.active_action
    ? new Date(state.active_action.ends_at).getTime() <= tick
    : false
  const moduleCount = state?.modules.length ?? 0
  const resources = state?.resources ?? { field_timber: 0, field_fiber: 0, smithing_scrap: 0 }
  const repairCost = camp.camp_level <= 1
    ? { timber: 3, fiber: 2 }
    : camp.camp_level === 2
      ? { timber: 5, fiber: 3 }
      : { timber: 7, fiber: 5 }
  const repairDueMs = new Date(camp.expires_at).getTime()
  const repairUrgent = repairDueMs - tick <= 24 * 60 * 60 * 1000

  return (
    <div className="camp-system-card">
      <div className="camp-system-head">
        <div>
          <span className="eyebrow">{isOwner ? 'ТВОЯ ПОЛЕВАЯ БАЗА' : 'ЧУЖОЙ ЛАГЕРЬ'}</span>
          <h4>{camp.owner_name} · уровень {camp.camp_level}</h4>
          <p className="muted">
            Сектор #{camp.sector_id} · следующий ремонт до {timeLabel(camp.expires_at)} · построек {moduleCount}/{camp.module_slots}
          </p>
        </div>
        <span className="badge">{accessLabels[camp.access_mode]}</span>
      </div>

      {message && <p className="form-message">{message}</p>}

      {isOwner && (
        <>
          <div className="camp-resource-strip">
            <span>Полевой лес <b>{resources.field_timber}</b></span>
            <span>Волокно <b>{resources.field_fiber}</b></span>
            <span>Кузнечный лом <b>{resources.smithing_scrap}</b></span>
          </div>

          <div className={'camp-maintenance-card ' + (repairUrgent ? 'urgent' : '')}>
            <div>
              <span className="eyebrow">ОБСЛУЖИВАНИЕ ЛАГЕРЯ</span>
              <strong>{repairUrgent ? 'Нужен ремонт' : 'Лагерь в порядке'}</strong>
              <small>
                Следующий ремонт до {timeLabel(camp.expires_at)} · стоимость: {repairCost.timber} полевого леса + {repairCost.fiber} прочного волокна.
              </small>
            </div>
            <button
              className={repairUrgent ? 'primary-button' : 'ghost-button'}
              type="button"
              disabled={busy || resources.field_timber < repairCost.timber || resources.field_fiber < repairCost.fiber}
              onClick={() => void repair()}
            >
              Вложить ресурсы в ремонт · +7 дней
            </button>
          </div>

          <div className="camp-owner-actions">
            <label>
              <span>Доступ</span>
              <select value={camp.access_mode} disabled={busy} onChange={(e) => void setAccess(e.target.value as AccessMode)}>
                <option value="private">Личный</option>
                <option value="party">Только пати</option>
                <option value="open">Открытый</option>
              </select>
            </label>
            {camp.camp_level < 3 && (
              <button className="ghost-button" type="button" disabled={busy} onClick={() => void upgrade()}>
                Улучшить до ур. {camp.camp_level + 1}
              </button>
            )}
            <button className="danger-button" type="button" disabled={busy} onClick={() => void dismantle()}>
              Свернуть
            </button>
          </div>
          <small className="muted">
            Улучшение 2: 6 леса + 4 волокна · улучшение 3: 10 леса + 6 волокон + 2 лома. Ремонт не накапливает недели вперёд: после каждого ремонта новый срок считается на 7 дней от текущего момента.
          </small>
        </>
      )}

      <div className="camp-section">
        <span className="eyebrow">КОСТЁР И ОТДЫХ</span>
        {state?.active_action ? (
          <div className="camp-action-active">
            <strong>{state.active_action.action_type === 'rest' ? 'Отдых' : 'Разведка'}</strong>
            <span>до {timeLabel(state.active_action.ends_at)}</span>
            <button className="primary-button" type="button" disabled={busy || !activeActionReady} onClick={() => void finishAction()}>
              {activeActionReady ? 'Забрать результат' : 'Ещё не готово'}
            </button>
          </div>
        ) : (
          <button className="ghost-button" type="button" disabled={busy || blocked} title={blockingReason} onClick={() => void startAction('rest')}>
            Отдохнуть · 30 минут · полное ОЗ и мана
          </button>
        )}
      </div>

      <div className="camp-section">
        <div className="camp-section-heading">
          <span className="eyebrow">ПОСТРОЙКИ</span>
          <small>{moduleCount}/{camp.module_slots}</small>
        </div>
        <div className="camp-module-grid">
          {moduleOrder.map((type) => {
            const built = moduleTypes.has(type)
            const info = moduleInfo[type]
            return (
              <div className={'camp-module-card ' + (built ? 'built' : '')} key={type}>
                <strong>{info.name}</strong>
                <p>{info.description}</p>
                <small>{built ? 'Построено' : info.cost}</small>
                {isOwner && (
                  <button
                    className="ghost-button"
                    type="button"
                    disabled={busy || (!built && moduleCount >= camp.module_slots)}
                    onClick={() => void (built ? removeModule(type) : buildModule(type))}
                  >
                    {built ? 'Разобрать' : 'Построить'}
                  </button>
                )}
              </div>
            )
          })}
        </div>
      </div>

      {moduleTypes.has('scout_post') && (
        <div className="camp-section">
          <span className="eyebrow">РАЗВЕДКА</span>
          <p className="muted">Разведка не открывает сектор, а заранее сообщает местность, опасность и заметные признаки.</p>
          {!state?.active_action && (
            <div className="camp-inline-actions">
              {state?.scout_targets.slice(0, 8).map((target) => (
                <button className="ghost-button" type="button" disabled={busy || blocked} key={target.sector_id} onClick={() => void startAction('scout', target.sector_id)}>
                  Разведать #{target.sector_id}
                </button>
              ))}
              {state?.scout_targets.length === 0 && <small>Соседних неизвестных секторов нет.</small>}
            </div>
          )}
          {(state?.scout_reports.length ?? 0) > 0 && (
            <div className="camp-report-list">
              {state!.scout_reports.slice(0, 5).map((report) => (
                <div key={report.id}>
                  <strong>Сектор #{report.sector_id}</strong>
                  <span>{report.terrain_type} · опасность {report.danger_level}/10 · {report.content_hint}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {moduleTypes.has('hunting_table') && (
        <div className="camp-section">
          <span className="eyebrow">ОХОТНИЧИЙ СТОЛ</span>
          <p className="muted">Направленная охота длится 10 минут. Выбранный тип добычи встречается заметно чаще; при ресурсе стол добавляет +1 предмет.</p>
          <div className="camp-inline-actions">
            {(Object.keys(focusLabels) as HuntFocus[]).map((focus) => (
              <button className="ghost-button" type="button" disabled={busy || blocked} key={focus} onClick={() => void focusedHunt(focus)}>
                {focusLabels[focus]}
              </button>
            ))}
          </div>
        </div>
      )}

      {moduleTypes.has('training_yard') && (
        <div className="camp-section">
          <span className="eyebrow">ТРЕНИРОВОЧНАЯ ПЛОЩАДКА</span>
          {state?.preparation && (
            <p className="muted">
              Активно: {state.preparation.preparation_type} +{state.preparation.bonus_percent}% · до {timeLabel(state.preparation.expires_at)}
            </p>
          )}
          <div className="camp-inline-actions">
            <button className="ghost-button" type="button" disabled={busy || blocked} onClick={() => void prepare('physical')}>+6% физ. урона</button>
            <button className="ghost-button" type="button" disabled={busy || blocked} onClick={() => void prepare('magic')}>+6% маг. урона</button>
            <button className="ghost-button" type="button" disabled={busy || blocked} onClick={() => void prepare('fortify')}>+6% физ. защиты</button>
          </div>
        </div>
      )}

      {moduleTypes.has('field_kitchen') && (
        <div className="camp-section">
          <span className="eyebrow">ПОЛЕВАЯ КУХНЯ</span>
          <p className="muted">1 охотничье мясо/рыба + 1 трава → полевое рагу (+60 ОЗ, +40 маны).</p>
          <button className="ghost-button" type="button" disabled={busy} onClick={() => void cook()}>Приготовить рагу</button>
        </div>
      )}

      {isOwner && (
        <div className="camp-section">
          <span className="eyebrow">СКЛАД · {state?.storage.length ?? 0}/{camp.storage_capacity}</span>
          <div className="camp-storage-controls">
            <select value={storageItemId} onChange={(e) => setStorageItemId(e.target.value)}>
              <option value="">Выбери предмет</option>
              {inventoryCandidates.map((item) => {
                const def = definitionOf(item)
                if (!def) return null
                return <option value={item.id} key={item.id}>{item.custom_name || def.name} ×{item.quantity}</option>
              })}
            </select>
            <input type="number" min={1} value={storageQty} onChange={(e) => setStorageQty(Math.max(1, Number(e.target.value) || 1))} />
            <button className="ghost-button" type="button" disabled={busy || !storageItemId} onClick={() => void deposit()}>Оставить</button>
          </div>
          <div className="camp-storage-list">
            {state?.storage.map((item) => (
              <div key={item.id}>
                <span>{item.custom_name || item.item_name} ×{item.quantity}</span>
                <button className="ghost-button" type="button" disabled={busy} onClick={() => void withdraw(item.id)}>Забрать</button>
              </div>
            ))}
          </div>
        </div>
      )}

      {moduleTypes.has('trading_post') && (
        <div className="camp-section">
          <span className="eyebrow">ТОРГОВЫЙ НАВЕС</span>
          <p className="muted">
            Только бартер. Уникальные, религиозные, персональные и боссовые предметы не передаются; редкая экипировка привязывается после первого надевания.
          </p>
          <div className="camp-trade-create">
            <select value={offerItemId} onChange={(e) => setOfferItemId(e.target.value)}>
              <option value="">Что отдаёшь</option>
              {tradeCandidates.map((item) => {
                const def = definitionOf(item)
                if (!def) return null
                return <option value={item.id} key={item.id}>{item.custom_name || def.name} ×{item.quantity}</option>
              })}
            </select>
            <input type="number" min={1} value={offerQty} onChange={(e) => setOfferQty(Math.max(1, Number(e.target.value) || 1))} />
            <select value={requestDefinitionId} onChange={(e) => setRequestDefinitionId(e.target.value)}>
              <option value="">Что хочешь получить</option>
              {definitions.map((def) => <option value={def.id} key={def.id}>{def.name}</option>)}
            </select>
            <input type="number" min={1} value={requestQty} onChange={(e) => setRequestQty(Math.max(1, Number(e.target.value) || 1))} />
            <button className="primary-button" type="button" disabled={busy || !offerItemId || !requestDefinitionId} onClick={() => void createOffer()}>
              Выставить бартер
            </button>
          </div>
          <div className="camp-trade-list">
            {state?.trade_offers.map((offer) => {
              const hasPayment = tradeCandidates.some((item) => (
                item.item_definition_id === offer.requested_item_definition_id
                && item.quantity >= offer.requested_quantity
              ))
              return (
                <div className="camp-trade-offer" key={offer.id}>
                  <div>
                    <strong>{offer.offered_custom_name || offer.offered_item_name} ×{offer.offered_quantity}</strong>
                    <span>за {offer.requested_item_name} ×{offer.requested_quantity}</span>
                    <small>{offer.offered_by_name} · до {timeLabel(offer.expires_at)}</small>
                  </div>
                  {offer.is_mine ? (
                    <button className="ghost-button" type="button" disabled={busy} onClick={() => void cancelOffer(offer.id)}>Снять</button>
                  ) : (
                    <button className="ghost-button" type="button" disabled={busy || !hasPayment} onClick={() => void acceptOffer(offer)}>
                      {hasPayment ? 'Обменять' : 'Нет нужного предмета'}
                    </button>
                  )}
                </div>
              )
            })}
          </div>
        </div>
      )}

      {state?.daily_event && (
        <div className="camp-section camp-daily-event">
          <span className="eyebrow">СЕГОДНЯ У ЛАГЕРЯ</span>
          <strong>{state.daily_event.title}</strong>
          <button className="ghost-button" type="button" disabled={busy || state.daily_event.claimed} onClick={() => void resolveEvent()}>
            {state.daily_event.claimed ? 'Уже завершено' : 'Разобраться'}
          </button>
        </div>
      )}
    </div>
  )
}
