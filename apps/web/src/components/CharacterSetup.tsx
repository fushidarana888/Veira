import { FormEvent, useState } from 'react'
import { supabase } from '../lib/supabase'

type Props = {
  userId: string
  displayName: string
  onCreated: () => Promise<void> | void
  onSignOut: () => Promise<void> | void
}

async function sha256Hex(value: string) {
  const bytes = new TextEncoder().encode(value)
  const digest = await crypto.subtle.digest('SHA-256', bytes)
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('')
}

export function CharacterSetup({ userId, displayName, onCreated, onSignOut }: Props) {
  const [name, setName] = useState('')
  const [race, setRace] = useState('Человек')
  const [bio, setBio] = useState('')
  const [gmCode, setGmCode] = useState('')
  const [busy, setBusy] = useState(false)
  const [gmBusy, setGmBusy] = useState(false)
  const [message, setMessage] = useState('')
  const [gmMessage, setGmMessage] = useState('')

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setMessage('')

    if (!name.trim() || !race.trim()) {
      setMessage('Имя и раса обязательны.')
      return
    }

    setBusy(true)

    const { error } = await supabase.from('characters').insert({
      owner_user_id: userId,
      name: name.trim(),
      race: race.trim(),
      bio: bio.trim(),
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    await onCreated()
    setBusy(false)
  }

  async function claimGm() {
    const code = gmCode.trim()
    setGmMessage('')

    if (!code) {
      setGmMessage('Введи одноразовый код GM.')
      return
    }

    setGmBusy(true)

    try {
      const tokenHash = await sha256Hex(code)
      const { error } = await supabase.from('gm_claim_requests').insert({
        user_id: userId,
        token_hash: tokenHash,
      })

      if (error) {
        const raw = error.message
        if (raw.includes('INVALID_OR_EXPIRED_GM_CODE')) {
          setGmMessage('Код неверный, уже использован или истёк.')
        } else if (raw.includes('GM_ACCOUNT_MUST_NOT_HAVE_CHARACTER')) {
          setGmMessage('GM-аккаунт должен быть отдельным и не иметь игрового персонажа.')
        } else {
          setGmMessage(raw)
        }
        return
      }

      setGmMessage('GM-доступ активирован.')
      await onCreated()
    } finally {
      setGmBusy(false)
    }
  }

  return (
    <main className="shell">
      <header className="topbar">
        <div>
          <span className="eyebrow">ПЕРВЫЙ ВХОД</span>
          <h1>Создай персонажа</h1>
          <p className="muted">Аккаунт: {displayName}</p>
        </div>
        <button className="ghost-button" type="button" onClick={() => void onSignOut()}>
          Выйти
        </button>
      </header>

      <div className="setup-grid">
        <section className="panel character-create">
          <span className="eyebrow">ИГРОВОЙ АККАУНТ</span>
          <h2>Новый персонаж</h2>

          <form className="form-stack setup-form" onSubmit={submit}>
            <label>
              <span>Имя персонажа</span>
              <input
                value={name}
                onChange={(event) => setName(event.target.value)}
                maxLength={60}
                placeholder="Имя, под которым его знает мир"
              />
            </label>

            <label>
              <span>Раса</span>
              <input
                value={race}
                onChange={(event) => setRace(event.target.value)}
                maxLength={60}
                placeholder="Можно указать свою расу"
              />
            </label>

            <label>
              <span>Короткая биография</span>
              <textarea
                value={bio}
                onChange={(event) => setBio(event.target.value)}
                maxLength={4000}
                rows={7}
                placeholder="Кем был персонаж до начала игры?"
              />
            </label>

            <button className="primary-button" type="submit" disabled={busy}>
              {busy ? 'Создаём…' : 'Начать игру'}
            </button>
          </form>

          {message && <p className="form-message" aria-live="polite">{message}</p>}
        </section>

        <aside className="panel gm-claim-card">
          <span className="eyebrow">ОТДЕЛЬНЫЙ GM-АККАУНТ</span>
          <h2>Вход для Game Master</h2>
          <p className="muted">
            Используй это только на отдельном аккаунте без персонажа. Код одноразовый и после активации больше не сработает.
          </p>

          <label className="gm-code-field">
            <span>Одноразовый код</span>
            <input
              value={gmCode}
              onChange={(event) => setGmCode(event.target.value)}
              placeholder="Вставь GM-код"
              autoComplete="off"
            />
          </label>

          <button
            className="ghost-button gm-claim-button"
            type="button"
            disabled={gmBusy}
            onClick={() => void claimGm()}
          >
            {gmBusy ? 'Проверяем…' : 'Активировать GM'}
          </button>

          {gmMessage && <p className="form-message" aria-live="polite">{gmMessage}</p>}
        </aside>
      </div>
    </main>
  )
}
