import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { CharacterAdventureSite } from '../types'

type Props = {
  characterId: string
}

export function AdventuresPanel({ characterId }: Props) {
  const [sites, setSites] = useState<CharacterAdventureSite[]>([])
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  async function loadAdventures() {
    setLoading(true)

    const { data, error } = await supabase.rpc('get_character_adventures', {
      p_character_id: characterId,
    })

    if (error) {
      setMessage(error.message)
      setLoading(false)
      return
    }

    setSites((data as CharacterAdventureSite[] | null) ?? [])
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

          <div className="dungeon-run-stage">
            <span>Текущий этап</span>
            <strong>Вход в подземелье</strong>
            <p className="muted">
              Прохождение создано и закреплено за персонажем. Следующим слоем сюда подключаются комнаты, противники и боевая система.
            </p>
          </div>

          <button
            className="ghost-button danger-button"
            type="button"
            disabled={busy}
            onClick={() => void leaveDungeon(activeDungeon.active_run_id!)}
          >
            Покинуть подземелье
          </button>
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
                        Войти
                      </button>
                    )}

                    {active && <span className="badge">внутри</span>}
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
