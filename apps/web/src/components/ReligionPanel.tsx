import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import './religionPanel.css'

type Props = {
  characterId: string
  onReligionChanged?: () => Promise<unknown> | void
  onInventoryChanged?: () => Promise<unknown> | void
}

type Religion = {
  slug: string
  name: string
  short_motto: string
  description: string
  praise_text: string
  taboo_text: string
  is_current: boolean
  faith_points: number
  religion_level: number
  favor: number
  current_level_points: number
  next_level_points: number
  daily_earned: number
  daily_cap: number
  reward_item_id: string | null
  reward_item_name: string | null
  reward_item_description: string | null
  reward_claimed: boolean
  combat_modifiers: Record<string, unknown>
}

type ReligionPerk = {
  level: number
  title: string
  description: string
  modifiers: Record<string, unknown>
  unlocked: boolean
}

type ReligionOath = {
  oath_id: string
  name: string
  description: string
  target_count: number
  progress_count: number
  faith_reward: number
  favor_reward: number
  status: 'available' | 'active' | 'completed' | 'failed' | 'abandoned'
  active_assignment_id: string | null
  cooldown_remaining_seconds: number
}

type ReligiousItem = {
  character_item_id: string
  item_name: string
  religion_slug: string
  religion_name: string
  weakened: boolean
  equipped: boolean
  equip_slot: string | null
}

type SacrificeItem = {
  character_item_id: string
  item_name: string
  rarity: string
  quantity: number
}

const rarityLabels: Record<string, string> = {
  rare: 'Редкий',
  epic: 'Эпический',
  legendary: 'Легендарный',
  unique: 'Уникальный',
}

function formatTime(seconds: number) {
  if (seconds <= 0) return ''
  const days = Math.floor(seconds / 86400)
  const hours = Math.ceil((seconds % 86400) / 3600)
  if (days > 0) return `${days} д. ${hours > 0 ? `${hours} ч.` : ''}`.trim()
  return `${hours} ч.`
}

function errorText(raw: string) {
  if (raw.includes('CHARACTER_BUSY')) return 'Нельзя менять религию во время боя, экспедиции или подземелья.'
  if (raw.includes('OATH_ALREADY_ACTIVE')) return 'Сначала заверши или нарушь текущую клятву.'
  if (raw.includes('OATH_COOLDOWN')) return 'Эту клятву можно будет дать снова позже.'
  if (raw.includes('ACTIVE_OATH_NOT_FOUND')) return 'Активная клятва уже завершена.'
  if (raw.includes('ABYSS_RELIGION_REQUIRED')) return 'Жертвоприношения доступны только последователям Бездны.'
  if (raw.includes('SACRIFICE_REQUIRES_RARE_ITEM')) return 'Бездна принимает предметы редкости Rare и выше.'
  if (raw.includes('ITEM_IS_EQUIPPED')) return 'Сначала сними предмет.'
  return raw
}

export function ReligionPanel({
  characterId,
  onReligionChanged,
  onInventoryChanged,
}: Props) {
  const [religions, setReligions] = useState<Religion[]>([])
  const [selectedSlug, setSelectedSlug] = useState('')
  const [perks, setPerks] = useState<ReligionPerk[]>([])
  const [oaths, setOaths] = useState<ReligionOath[]>([])
  const [religiousItems, setReligiousItems] = useState<ReligiousItem[]>([])
  const [sacrificeItems, setSacrificeItems] = useState<SacrificeItem[]>([])
  const [selectedSacrificeId, setSelectedSacrificeId] = useState('')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  async function loadCore(preferredSlug?: string) {
    setLoading(true)

    const [catalogResult, relicResult] = await Promise.all([
      supabase.rpc('get_religion_catalog', { p_character_id: characterId }),
      supabase.rpc('get_character_religious_items', { p_character_id: characterId }),
    ])

    const error = catalogResult.error ?? relicResult.error
    if (error) {
      setMessage(errorText(error.message))
      setLoading(false)
      return
    }

    const nextReligions = (catalogResult.data as Religion[] | null) ?? []
    const nextItems = (relicResult.data as ReligiousItem[] | null) ?? []
    const current = nextReligions.find((religion) => religion.is_current)
    const nextSelected = preferredSlug
      && nextReligions.some((religion) => religion.slug === preferredSlug)
      ? preferredSlug
      : current?.slug ?? selectedSlug ?? nextReligions[0]?.slug ?? ''

    setReligions(nextReligions)
    setReligiousItems(nextItems)
    setSelectedSlug(nextSelected)

    const [perkResult, oathResult] = await Promise.all([
      nextSelected
        ? supabase.rpc('get_religion_perks', {
            p_character_id: characterId,
            p_religion_slug: nextSelected,
          })
        : Promise.resolve({ data: [], error: null }),
      current
        ? supabase.rpc('get_character_religion_oaths', { p_character_id: characterId })
        : Promise.resolve({ data: [], error: null }),
    ])

    if (perkResult.error || oathResult.error) {
      setMessage(errorText(perkResult.error?.message ?? oathResult.error?.message ?? 'Не удалось загрузить религию.'))
      setLoading(false)
      return
    }

    setPerks((perkResult.data as ReligionPerk[] | null) ?? [])
    setOaths((oathResult.data as ReligionOath[] | null) ?? [])

    if (current?.slug === 'abyss') {
      const sacrificeResult = await supabase.rpc('get_abyss_sacrifice_items', {
        p_character_id: characterId,
      })
      if (!sacrificeResult.error) {
        const options = (sacrificeResult.data as SacrificeItem[] | null) ?? []
        setSacrificeItems(options)
        setSelectedSacrificeId((value) =>
          options.some((item) => item.character_item_id === value)
            ? value
            : options[0]?.character_item_id ?? '')
      }
    } else {
      setSacrificeItems([])
      setSelectedSacrificeId('')
    }

    setLoading(false)
  }

  useEffect(() => {
    setMessage('')
    void loadCore()
  }, [characterId])

  useEffect(() => {
    if (!selectedSlug || loading) return
    void (async () => {
      const { data, error } = await supabase.rpc('get_religion_perks', {
        p_character_id: characterId,
        p_religion_slug: selectedSlug,
      })
      if (error) {
        setMessage(errorText(error.message))
        return
      }
      setPerks((data as ReligionPerk[] | null) ?? [])
    })()
  }, [selectedSlug])

  const currentReligion = useMemo(
    () => religions.find((religion) => religion.is_current) ?? null,
    [religions],
  )
  const selectedReligion = useMemo(
    () => religions.find((religion) => religion.slug === selectedSlug) ?? null,
    [religions, selectedSlug],
  )
  const activeOath = oaths.find((oath) => oath.status === 'active') ?? null

  async function changeReligion(slug: string | null) {
    const target = religions.find((religion) => religion.slug === slug)
    const wording = slug
      ? currentReligion
        ? `Сменить «${currentReligion.name}» на «${target?.name ?? slug}»? Активная клятва будет нарушена, старые религиозные бафы исчезнут, а реликвии прежней религии ослабнут на 20%.`
        : `Принять религию «${target?.name ?? slug}»?`
      : `Покинуть «${currentReligion?.name ?? 'религию'}»? Активные религиозные бафы исчезнут, клятва будет нарушена, а полученные реликвии ослабнут на 20%.`

    if (!window.confirm(wording)) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('change_character_religion', {
      p_character_id: characterId,
      p_religion_slug: slug,
    })

    if (error) {
      setMessage(errorText(error.message))
      setBusy(false)
      return
    }

    await Promise.all([
      Promise.resolve(onReligionChanged?.()),
      Promise.resolve(onInventoryChanged?.()),
    ])
    await loadCore(slug ?? undefined)

    setMessage(slug
      ? `Теперь персонаж следует религии «${target?.name ?? slug}».`
      : 'Персонаж больше не исповедует религию.')
    setBusy(false)
  }

  async function acceptOath(oath: ReligionOath) {
    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('accept_religion_oath', {
      p_character_id: characterId,
      p_oath_id: oath.oath_id,
    })

    if (error) {
      setMessage(errorText(error.message))
      setBusy(false)
      return
    }

    await loadCore(currentReligion?.slug)
    setMessage(`Клятва «${oath.name}» дана.`)
    setBusy(false)
  }

  async function abandonOath(oath: ReligionOath) {
    if (!oath.active_assignment_id) return
    if (!window.confirm(`Нарушить «${oath.name}»? Вера и благосклонность уменьшатся.`)) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('abandon_religion_oath', {
      p_character_id: characterId,
      p_assignment_id: oath.active_assignment_id,
    })

    if (error) {
      setMessage(errorText(error.message))
      setBusy(false)
      return
    }

    await loadCore(currentReligion?.slug)
    setMessage('Клятва нарушена. Религия это запомнила.')
    setBusy(false)
  }

  async function sacrifice() {
    const item = sacrificeItems.find((entry) => entry.character_item_id === selectedSacrificeId)
    if (!item) return
    if (!window.confirm(`Пожертвовать «${item.item_name}» Бездне? Предмет будет уничтожен без возврата.`)) return

    setBusy(true)
    setMessage('')

    const { data, error } = await supabase.rpc('sacrifice_item_to_abyss', {
      p_character_id: characterId,
      p_character_item_id: item.character_item_id,
    })

    if (error) {
      setMessage(errorText(error.message))
      setBusy(false)
      return
    }

    await Promise.all([
      Promise.resolve(onInventoryChanged?.()),
      loadCore('abyss'),
    ])
    setMessage(`Бездна приняла жертву: ${String(data)}.`)
    setBusy(false)
  }

  if (loading) {
    return <section className="panel"><p className="muted">Загружаем веру персонажа…</p></section>
  }

  const faithSpan = selectedReligion
    ? Math.max(1, selectedReligion.next_level_points - selectedReligion.current_level_points)
    : 1
  const faithPercent = selectedReligion
    ? selectedReligion.religion_level >= 10
      ? 100
      : Math.max(0, Math.min(100, Math.round(
          ((selectedReligion.faith_points - selectedReligion.current_level_points) / faithSpan) * 100,
        )))
    : 0

  return (
    <div className="religion-layout">
      <section className="panel religion-intro">
        <div className="section-heading">
          <div>
            <span className="eyebrow">ВЕРА</span>
            <h2>{currentReligion ? currentReligion.name : 'Религия не выбрана'}</h2>
            <p className="muted">
              {currentReligion
                ? currentReligion.short_motto
                : 'Религия находится выше расы: она отражает убеждения персонажа и может быть изменена.'}
            </p>
          </div>
          {currentReligion && <span className="badge">УР. {currentReligion.religion_level}/10</span>}
        </div>

        {currentReligion && (
          <div className="religion-current-summary">
            <div>
              <small>Вера</small>
              <strong>{currentReligion.faith_points}/2200</strong>
            </div>
            <div>
              <small>Благосклонность</small>
              <strong>{currentReligion.favor > 0 ? '+' : ''}{currentReligion.favor}</strong>
            </div>
            <div>
              <small>Обычная вера сегодня</small>
              <strong>{currentReligion.daily_earned}/{currentReligion.daily_cap}</strong>
            </div>
          </div>
        )}

        {message && <p className="form-message" aria-live="polite">{message}</p>}

        {currentReligion && (
          <button
            className="ghost-button religion-leave"
            type="button"
            disabled={busy}
            onClick={() => void changeReligion(null)}
          >
            Покинуть религию
          </button>
        )}
      </section>

      <section className="religion-card-grid" aria-label="Религии Veira">
        {religions.map((religion) => (
          <button
            className={`religion-choice-card ${selectedSlug === religion.slug ? 'selected' : ''} ${religion.is_current ? 'current' : ''}`}
            type="button"
            key={religion.slug}
            onClick={() => setSelectedSlug(religion.slug)}
          >
            <span>{religion.is_current ? 'ТЕКУЩАЯ ВЕРА' : 'РЕЛИГИЯ'}</span>
            <strong>{religion.name}</strong>
            <small>{religion.short_motto}</small>
            <b>УР. {religion.religion_level}/10 · {religion.faith_points} веры</b>
          </button>
        ))}
      </section>

      {selectedReligion && (
        <section className="panel religion-detail">
          <div className="section-heading">
            <div>
              <span className="eyebrow">{selectedReligion.name.toUpperCase()}</span>
              <h2>{selectedReligion.short_motto}</h2>
            </div>
            {!selectedReligion.is_current && (
              <button
                className="primary-button"
                type="button"
                disabled={busy}
                onClick={() => void changeReligion(selectedReligion.slug)}
              >
                {currentReligion ? 'Сменить религию' : 'Принять веру'}
              </button>
            )}
          </div>

          <p>{selectedReligion.description}</p>

          <div className="religion-code-grid">
            <article>
              <span>ПОЧИТАЕТ</span>
              <p>{selectedReligion.praise_text}</p>
            </article>
            <article className="taboo">
              <span>ТАБУ</span>
              <p>{selectedReligion.taboo_text}</p>
            </article>
          </div>

          <div className="religion-faith-block">
            <div className="religion-faith-heading">
              <strong>Уровень {selectedReligion.religion_level}/10</strong>
              <span>{selectedReligion.faith_points}/2200</span>
            </div>
            <div className="religion-faith-meter"><span style={{ width: `${faithPercent}%` }} /></div>
            <div className="religion-faith-caption">
              <span>
                {selectedReligion.religion_level >= 10
                  ? 'Максимальный уровень'
                  : `До следующего: ${selectedReligion.next_level_points - selectedReligion.faith_points}`}
              </span>
              <span>Обычная вера сегодня {selectedReligion.daily_earned}/{selectedReligion.daily_cap}</span>
            </div>
          </div>

          {selectedReligion.reward_item_name && (
            <div className="religion-max-reward">
              <span>РЕЛИКВИЯ 10 УРОВНЯ</span>
              <strong>{selectedReligion.reward_item_name}</strong>
              <p>{selectedReligion.reward_item_description}</p>
              {selectedReligion.reward_claimed && <b>Получено</b>}
            </div>
          )}
        </section>
      )}

      {selectedReligion && (
        <section className="panel">
          <div className="section-heading">
            <div>
              <span className="eyebrow">10 УРОВНЕЙ ВЕРЫ</span>
              <h2>Благословения</h2>
            </div>
            <span className="badge">{selectedReligion.religion_level}/10</span>
          </div>

          <div className="religion-perk-list">
            {perks.map((perk) => (
              <article className={`religion-perk ${perk.unlocked ? 'unlocked' : 'locked'}`} key={perk.level}>
                <span>{perk.level}</span>
                <div>
                  <strong>{perk.title}</strong>
                  <p>{perk.description}</p>
                </div>
                <b>{perk.unlocked ? 'Активно' : 'Закрыто'}</b>
              </article>
            ))}
          </div>
        </section>
      )}

      {currentReligion && (
        <section className="panel">
          <div className="section-heading">
            <div>
              <span className="eyebrow">{currentReligion.slug === 'abyss' ? 'СДЕЛКИ' : 'КЛЯТВЫ'}</span>
              <h2>{activeOath ? activeOath.name : 'Выбери обязательство'}</h2>
            </div>
            {activeOath && <span className="badge">{activeOath.progress_count}/{activeOath.target_count}</span>}
          </div>

          <p className="muted">
            Одновременно можно держать только одну клятву. Обычными действиями можно получить до 60 веры в сутки,
            а выполненными клятвами — ещё до 100 веры за скользящие 7 дней. При идеальном фарме 10 уровень занимает примерно месяц.
            Нарушение или смена религии уменьшает веру и благосклонность.
          </p>

          <div className="religion-oath-grid">
            {oaths.map((oath) => {
              const cooling = oath.cooldown_remaining_seconds > 0
              return (
                <article className={`religion-oath ${oath.status === 'active' ? 'active' : ''}`} key={oath.oath_id}>
                  <div>
                    <strong>{oath.name}</strong>
                    <span>+{oath.faith_reward} веры · +{oath.favor_reward} благосклонности</span>
                  </div>
                  <p>{oath.description}</p>

                  {oath.status === 'active' ? (
                    <>
                      <div className="oath-progress">
                        <span style={{ width: `${Math.min(100, oath.progress_count / oath.target_count * 100)}%` }} />
                      </div>
                      <button
                        className="ghost-button"
                        type="button"
                        disabled={busy}
                        onClick={() => void abandonOath(oath)}
                      >
                        Нарушить
                      </button>
                    </>
                  ) : (
                    <button
                      className="ghost-button"
                      type="button"
                      disabled={busy || Boolean(activeOath) || cooling}
                      onClick={() => void acceptOath(oath)}
                    >
                      {cooling ? `Снова через ${formatTime(oath.cooldown_remaining_seconds)}` : 'Дать клятву'}
                    </button>
                  )}
                </article>
              )
            })}
          </div>
        </section>
      )}

      {currentReligion?.slug === 'abyss' && (
        <section className="panel abyss-sacrifice">
          <div className="section-heading">
            <div>
              <span className="eyebrow">ЦЕНА</span>
              <h2>Жертва Бездне</h2>
            </div>
          </div>
          <p className="muted">
            Можно уничтожить неэкипированный предмет Rare или выше. Чем выше редкость, тем больше вера и благосклонность.
          </p>
          {sacrificeItems.length > 0 ? (
            <div className="sacrifice-controls">
              <select
                value={selectedSacrificeId}
                onChange={(event) => setSelectedSacrificeId(event.target.value)}
              >
                {sacrificeItems.map((item) => (
                  <option key={item.character_item_id} value={item.character_item_id}>
                    {item.item_name} · {rarityLabels[item.rarity] ?? item.rarity} · ×{item.quantity}
                  </option>
                ))}
              </select>
              <button className="primary-button" type="button" disabled={busy} onClick={() => void sacrifice()}>
                Пожертвовать
              </button>
            </div>
          ) : (
            <p className="muted">Подходящих предметов сейчас нет.</p>
          )}
        </section>
      )}

      {religiousItems.length > 0 && (
        <section className="panel">
          <div className="section-heading">
            <div>
              <span className="eyebrow">РЕЛИГИОЗНЫЕ РЕЛИКВИИ</span>
              <h2>Полученные предметы</h2>
            </div>
          </div>

          <div className="religious-item-list">
            {religiousItems.map((item) => (
              <article key={item.character_item_id} className={item.weakened ? 'weakened' : ''}>
                <div>
                  <strong>{item.item_name}</strong>
                  <small>{item.religion_name}{item.equipped ? ' · экипировано' : ''}</small>
                </div>
                <span>{item.weakened ? '80% силы' : 'Полная сила'}</span>
              </article>
            ))}
          </div>
        </section>
      )}
    </div>
  )
}
