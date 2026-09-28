import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { userFacingError } from '../lib/userError'
import { useActionGate } from '../lib/actionGate'

type WorldPulseModifier = {
  slug: string
  name: string
  description: string
  theme: string
  enemy_hp_percent: number
  enemy_attack_percent: number
  enemy_defense_percent: number
  reward_gold_percent: number
  reward_xp_percent: number
}

type DungeonEventChoice = {
  slug: string
  label: string
}

type WorldPulseDungeonEvent = {
  id: string
  run_id: string
  event_slug: string
  name: string
  description: string
  room_index: number
  choices: DungeonEventChoice[]
}

type WorldPulseMap = {
  character_item_id: string
  slug: string
  name: string
  quantity: number
}

type TreasureHunt = {
  id: string
  target_sector_id: number
  target_name: string
  reward_tier: number
  status: string
  created_at: string
  ready: boolean
}

type MerchantOffer = {
  item_definition_id: string
  slug: string
  name: string
  description: string
  rarity: string
  price: number
  bought: boolean
}

type WanderingMerchant = {
  sector_id: number
  location_name: string
  offers: MerchantOffer[]
}

type WorldRumor = {
  slug: string
  title: string
  body: string
}

type Discovery = {
  category: string
  slug: string
  title: string
  description: string
  times_seen: number
  first_seen_at: string
  last_seen_at: string
}

type Trophy = {
  slug: string
  name: string
  description: string
  quantity: number
}

type LostSpirit = {
  id: string
  sector_id: number
  created_at: string
  expires_at: string
  item_name: string
  character_item_id: string | null
  anomaly: string | null
  anomaly_name: string | null
}

type WorldPulse = {
  merchant: WanderingMerchant | null
  rumors: WorldRumor[]
  maps: WorldPulseMap[]
  treasure_hunts: TreasureHunt[]
  discoveries: Discovery[]
  trophies: Trophy[]
  lost_spirits: LostSpirit[]
  discovery_count: number
  active_dungeon: {
    run_id: string
    sector_id: number
    modifier: WorldPulseModifier | null
    pending_event: WorldPulseDungeonEvent | null
    elite_room_ready: boolean
  } | null
}

type Props = {
  characterId: string
  onProgressChanged?: () => Promise<unknown> | void
  onInventoryChanged?: () => Promise<unknown> | void
  onAdventureChanged?: () => Promise<unknown> | void
  compact?: boolean
}

function signed(value: number, suffix = '%') {
  return `${value >= 0 ? '+' : ''}${value}${suffix}`
}

function discoveryCategoryLabel(category: string) {
  switch (category) {
    case 'rare_boss':
    case 'rare_boss_victory':
      return 'редкий враг'
    case 'enemy':
      return 'бестиарий'
    case 'dungeon_event':
      return 'событие'
    case 'mystery':
      return 'тайна'
    case 'treasure':
    case 'treasure_map':
      return 'сокровища'
    default:
      return 'открытие'
  }
}

function rarityLabel(rarity: string) {
  switch (rarity) {
    case 'unique': return 'уникальный'
    case 'legendary': return 'легендарный'
    case 'epic': return 'эпический'
    case 'rare': return 'редкий'
    case 'uncommon': return 'необычный'
    default: return 'обычный'
  }
}

export function WorldPulsePanel({
  characterId,
  onProgressChanged,
  onInventoryChanged,
  onAdventureChanged,
  compact = false,
}: Props) {
  const [pulse, setPulse] = useState<WorldPulse | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState<string | null>(null)
  const [message, setMessage] = useState('')
  const [expandedDiscoveries, setExpandedDiscoveries] = useState(false)
  const { beginAction, endAction } = useActionGate(setBusy, null, setMessage)

  async function loadPulse(silent = false) {
    if (!silent) setLoading(true)

    const { data, error } = await supabase.rpc('get_world_pulse', {
      p_character_id: characterId,
    })

    if (error) {
      if (!silent) setMessage(userFacingError(error.message, 'Не удалось обновить события мира.'))
      setLoading(false)
      return null
    }

    const next = (data as WorldPulse | null) ?? null
    setPulse(next)
    setLoading(false)
    return next
  }

  useEffect(() => {
    setPulse(null)
    setLoading(true)
    setMessage('')
    void loadPulse()
  }, [characterId])

  async function refreshAfterAction(inventory = false) {
    await Promise.all([
      loadPulse(true),
      Promise.resolve(onProgressChanged?.()),
      inventory ? Promise.resolve(onInventoryChanged?.()) : Promise.resolve(),
      Promise.resolve(onAdventureChanged?.()),
    ])
  }

  async function resolveDungeonEvent(runId: string, choiceSlug: string) {
    if (!beginAction('event:' + choiceSlug)) return
    setMessage('')

    const { data, error } = await supabase.rpc('resolve_dungeon_event', {
      p_run_id: runId,
      p_choice_slug: choiceSlug,
    })

    if (error) {
      const raw = error.message
      setMessage(
        raw.includes('NOT_ENOUGH_GOLD_FOR_EVENT')
          ? 'Для этого решения не хватает золота.'
          : userFacingError(raw, 'Событие не удалось разрешить.'),
      )
      endAction()
      return
    }

    const result = data as { result?: string } | null
    setMessage(result?.result || 'Решение принято. Путь дальше открыт.')
    await refreshAfterAction(true)
    endAction()
  }

  async function activateMap(item: WorldPulseMap) {
    if (!beginAction('map:' + item.character_item_id)) return
    setMessage('')

    const { data, error } = await supabase.rpc('activate_treasure_map', {
      p_character_id: characterId,
      p_character_item_id: item.character_item_id,
    })

    if (error) {
      const raw = error.message
      setMessage(
        raw.includes('TREASURE_HUNT_ALREADY_ACTIVE')
          ? 'Сначала найди тайник по уже активной карте.'
          : raw.includes('NO_DISCOVERED_SECTOR_FOR_TREASURE_MAP')
            ? 'На карте пока не из чего выбрать цель: исследуй больше мира.'
            : userFacingError(raw, 'Не удалось прочитать карту.'),
      )
      endAction()
      return
    }

    const result = data as { target_name?: string } | null
    setMessage(result?.target_name
      ? `Карта расшифрована. Тайник отмечен в районе «${result.target_name}».`
      : 'Карта расшифрована. Новая цель появилась в журнале.')
    await refreshAfterAction(true)
    endAction()
  }

  async function claimTreasure(hunt: TreasureHunt) {
    if (!hunt.ready || !beginAction('hunt:' + hunt.id)) return
    setMessage('')

    const { data, error } = await supabase.rpc('claim_treasure_hunt', {
      p_hunt_id: hunt.id,
    })

    if (error) {
      const raw = error.message
      setMessage(
        raw.includes('TREASURE_SECTOR_NOT_VISITED_AFTER_MAP')
          ? 'После активации карты нужно заново завершить экспедицию в отмеченный сектор.'
          : userFacingError(raw, 'Тайник пока не удалось забрать.'),
      )
      endAction()
      return
    }

    const result = data as {
      gold?: number
      experience?: number
      bonus_item?: string | null
      target_name?: string
    } | null

    setMessage(
      `Тайник найден: +${result?.gold ?? 0} золота, +${result?.experience ?? 0} опыта`
      + (result?.bonus_item ? ` · редкая находка: ${result.bonus_item}` : '')
      + '.',
    )
    await refreshAfterAction(true)
    endAction()
  }

  async function buyMerchantItem(offer: MerchantOffer) {
    if (offer.bought || !beginAction('merchant:' + offer.item_definition_id)) return
    setMessage('')

    const { data, error } = await supabase.rpc('buy_wandering_merchant_item', {
      p_character_id: characterId,
      p_item_definition_id: offer.item_definition_id,
    })

    if (error) {
      const raw = error.message
      setMessage(
        raw.includes('NOT_ENOUGH_GOLD')
          ? 'У странствующего торговца не получится торговаться в долг — не хватает золота.'
          : raw.includes('WANDERING_ITEM_ALREADY_BOUGHT')
            ? 'Сегодня ты уже забрал этот товар.'
            : userFacingError(raw, 'Покупка не удалась.'),
      )
      endAction()
      return
    }

    const result = data as { item_name?: string; price?: number } | null
    setMessage(`Куплено: ${result?.item_name ?? offer.name} за ${result?.price ?? offer.price} золота.`)
    await refreshAfterAction(true)
    endAction()
  }

  const visibleDiscoveries = useMemo(
    () => (expandedDiscoveries ? pulse?.discoveries ?? [] : (pulse?.discoveries ?? []).slice(0, 6)),
    [pulse?.discoveries, expandedDiscoveries],
  )

  if (!pulse) {
    return (
      <article className="panel world-pulse-panel world-pulse-loading" aria-busy={loading}>
        <span className="eyebrow">ЖИВОЙ МИР</span>
        <h3>{loading ? 'Собираем слухи и следы…' : 'Мировой пульс не ответил'}</h3>
        {!loading && message && <p className="muted" aria-live="polite">{message}</p>}
        {!loading && (
          <button className="ghost-button" type="button" onClick={() => void loadPulse()}>
            Повторить
          </button>
        )}
      </article>
    )
  }

  const modifier = pulse.active_dungeon?.modifier ?? null
  const dungeonEvent = pulse.active_dungeon?.pending_event ?? null

  return (
    <div className="world-pulse-stack">
      {!compact && (pulse.lost_spirits?.length ?? 0) > 0 && (
        <article className="panel lost-spirit-warning">
          <div className="section-heading">
            <div>
              <span className="eyebrow">ПОТЕРЯННОЕ СНАРЯЖЕНИЕ</span>
              <h3>Твои духи всё ещё существуют</h3>
              <p className="muted">Победи собственного духа до истечения времени, иначе удерживаемая вещь исчезнет навсегда.</p>
            </div>
            <span className="badge">{pulse.lost_spirits.length}</span>
          </div>
          <div className="lost-spirit-list">
            {pulse.lost_spirits.map((spirit) => (
              <div className="lost-spirit-entry" key={spirit.id}>
                <div>
                  <strong>{spirit.item_name}</strong>
                  <span>
                    {spirit.anomaly_name ? spirit.anomaly_name + ' · ' : ''}
                    дух в секторе #{spirit.sector_id}
                  </span>
                </div>
                <small>
                  исчезнет {new Date(spirit.expires_at).toLocaleString('ru-RU', {
                    day: '2-digit',
                    month: '2-digit',
                    hour: '2-digit',
                    minute: '2-digit',
                  })}
                </small>
              </div>
            ))}
          </div>
        </article>
      )}

      {(modifier || dungeonEvent) && (
        <article className={'panel world-pulse-dungeon ' + (dungeonEvent ? 'has-event' : '')}>
          <div className="section-heading">
            <div>
              <span className="eyebrow">ТЕКУЩИЙ ПОХОД</span>
              <h3>{dungeonEvent ? 'Между залами что-то произошло' : 'Подземелье изменилось'}</h3>
            </div>
            {modifier && <span className="badge">{modifier.name}</span>}
          </div>

          {modifier && (
            <div className="world-modifier-card">
              <div>
                <strong>{modifier.name}</strong>
                <p>{modifier.description}</p>
              </div>
              <div className="world-modifier-stats">
                {modifier.enemy_hp_percent !== 0 && <span>HP врагов {signed(modifier.enemy_hp_percent)}</span>}
                {modifier.enemy_attack_percent !== 0 && <span>атака врагов {signed(modifier.enemy_attack_percent)}</span>}
                {modifier.enemy_defense_percent !== 0 && <span>защита врагов {signed(modifier.enemy_defense_percent)}</span>}
                {modifier.reward_gold_percent !== 0 && <span>золото {signed(modifier.reward_gold_percent)}</span>}
                {modifier.reward_xp_percent !== 0 && <span>опыт {signed(modifier.reward_xp_percent)}</span>}
              </div>
            </div>
          )}

          {pulse.active_dungeon?.elite_room_ready && !dungeonEvent && (
            <div className="elite-room-ready">
              <span className="eyebrow">ОПАСНАЯ КОМНАТА</span>
              <strong>Печать арены сломана</strong>
              <p>Следующий противник будет значительно сильнее обычного. За победу гарантирована дополнительная редкая находка.</p>
            </div>
          )}

          {dungeonEvent && (
            <div className="world-dungeon-event">
              <span className="eyebrow">СОБЫТИЕ · ПОСЛЕ ЗАЛА {dungeonEvent.room_index}</span>
              <h3>{dungeonEvent.name}</h3>
              <p>{dungeonEvent.description}</p>
              <div className="world-event-actions">
                {dungeonEvent.choices.map((choice) => (
                  <button
                    className={choice.slug === 'leave' ? 'ghost-button' : 'primary-button'}
                    type="button"
                    key={choice.slug}
                    disabled={Boolean(busy)}
                    onClick={() => void resolveDungeonEvent(dungeonEvent.run_id, choice.slug)}
                  >
                    {busy === 'event:' + choice.slug ? 'Решаем…' : choice.label}
                  </button>
                ))}
              </div>
              <small>Следующий зал не откроется, пока решение не принято. Автобой выбирает безопасный вариант сам.</small>
            </div>
          )}
        </article>
      )}

      {message && <p className="gm-notice world-pulse-message" aria-live="polite">{message}</p>}

      {!compact && (
      <div className="world-pulse-grid">
        <article className="panel world-pulse-card treasure-board">
          <div className="section-heading">
            <div>
              <span className="eyebrow">КАРТЫ СОКРОВИЩ</span>
              <h3>Следы тайников</h3>
            </div>
            <span className="badge">{pulse.treasure_hunts.length > 0 ? 'активна' : pulse.maps.length + ' карт'}</span>
          </div>

          {pulse.treasure_hunts.length > 0 ? (
            <div className="treasure-hunt-list">
              {pulse.treasure_hunts.map((hunt) => (
                <div className="treasure-hunt-card" key={hunt.id}>
                  <span>{hunt.reward_tier >= 2 ? 'Золотая карта' : 'Старая карта'}</span>
                  <strong>{hunt.target_name}</strong>
                  <small>сектор #{hunt.target_sector_id} · после активации карты нужно завершить здесь новую экспедицию</small>
                  <button
                    className={hunt.ready ? 'primary-button' : 'ghost-button'}
                    type="button"
                    disabled={Boolean(busy) || !hunt.ready}
                    onClick={() => void claimTreasure(hunt)}
                  >
                    {busy === 'hunt:' + hunt.id
                      ? 'Открываем…'
                      : hunt.ready
                        ? 'Забрать тайник'
                        : 'Сначала доберись до сектора'}
                  </button>
                </div>
              ))}
            </div>
          ) : pulse.maps.length > 0 ? (
            <div className="treasure-map-list">
              {pulse.maps.map((map) => (
                <button
                  className="treasure-map-entry"
                  type="button"
                  key={map.character_item_id}
                  disabled={Boolean(busy)}
                  onClick={() => void activateMap(map)}
                >
                  <span>
                    <strong>{map.name}</strong>
                    <small>в инвентаре ×{map.quantity}</small>
                  </span>
                  <b>{busy === 'map:' + map.character_item_id ? 'Читаем…' : 'Активировать'}</b>
                </button>
              ))}
            </div>
          ) : (
            <p className="muted">Карты иногда лежат в финальных тайниках, странных комнатах и у путешественников.</p>
          )}
        </article>

        <article className="panel world-pulse-card wandering-merchant">
          <div className="section-heading">
            <div>
              <span className="eyebrow">СТРАНСТВУЮЩИЙ ТОРГОВЕЦ</span>
              <h3>{pulse.merchant?.location_name ?? 'Сегодня его никто не видел'}</h3>
            </div>
            {pulse.merchant && <span className="badge">сектор #{pulse.merchant.sector_id}</span>}
          </div>

          {pulse.merchant && pulse.merchant.offers.length > 0 ? (
            <div className="wandering-offer-list">
              {pulse.merchant.offers.map((offer) => (
                <div className={'wandering-offer rarity-' + offer.rarity} key={offer.item_definition_id}>
                  <div>
                    <span>{rarityLabel(offer.rarity)}</span>
                    <strong>{offer.name}</strong>
                    <small>{offer.description}</small>
                  </div>
                  <button
                    className="ghost-button"
                    type="button"
                    disabled={Boolean(busy) || offer.bought}
                    onClick={() => void buyMerchantItem(offer)}
                  >
                    {offer.bought
                      ? 'Куплено'
                      : busy === 'merchant:' + offer.item_definition_id
                        ? 'Покупаем…'
                        : offer.price + ' золота'}
                  </button>
                </div>
              ))}
            </div>
          ) : (
            <p className="muted">Он появляется только в уже открытых тобой поселениях и меняет ассортимент каждый день.</p>
          )}
        </article>
      </div>
      )}

      {!compact && (
      <div className="world-pulse-grid">
        <article className="panel world-pulse-card rumors-board">
          <div className="section-heading">
            <div>
              <span className="eyebrow">СЛУХИ</span>
              <h3>Что говорят в дороге</h3>
            </div>
            <span className="badge">сегодня</span>
          </div>
          <div className="world-rumor-list">
            {pulse.rumors.map((rumor) => (
              <div className="world-rumor" key={rumor.slug}>
                <strong>{rumor.title}</strong>
                <p>{rumor.body}</p>
              </div>
            ))}
          </div>
        </article>

        <article className="panel world-pulse-card discoveries-board">
          <div className="section-heading">
            <div>
              <span className="eyebrow">АРХИВ ОТКРЫТИЙ</span>
              <h3>Бестиарий, тайны и находки</h3>
            </div>
            <span className="badge">{pulse.discovery_count}</span>
          </div>

          {(pulse.trophies?.length ?? 0) > 0 && (
            <div className="trophy-case">
              <span className="eyebrow">ТРОФЕИ</span>
              <div className="trophy-case-grid">
                {pulse.trophies.map((trophy) => (
                  <div className="trophy-case-item" key={trophy.slug}>
                    <strong>{trophy.name}</strong>
                    <small>{trophy.description}</small>
                    {trophy.quantity > 1 && <b>×{trophy.quantity}</b>}
                  </div>
                ))}
              </div>
            </div>
          )}

          {visibleDiscoveries.length > 0 ? (
            <>
              <div className="discovery-list">
                {visibleDiscoveries.map((entry) => (
                  <div className="discovery-entry" key={entry.category + ':' + entry.slug}>
                    <span>{discoveryCategoryLabel(entry.category)}</span>
                    <div>
                      <strong>{entry.title}</strong>
                      {entry.description && <small>{entry.description}</small>}
                    </div>
                    {entry.times_seen > 1 && <b>×{entry.times_seen}</b>}
                  </div>
                ))}
              </div>
              {(pulse.discoveries?.length ?? 0) > 6 && (
                <button
                  className="ghost-button world-pulse-more"
                  type="button"
                  onClick={() => setExpandedDiscoveries((value) => !value)}
                >
                  {expandedDiscoveries ? 'Свернуть' : 'Показать ещё'}
                </button>
              )}
            </>
          ) : (
            <p className="muted">Новые враги, редкие боссы, странные события и найденные тайники будут сохраняться здесь.</p>
          )}
        </article>
      </div>
      )}
    </div>
  )
}
