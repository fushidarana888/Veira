import { FormEvent, useState } from 'react'
import { supabase } from '../lib/supabase'

type Props = {
  userId: string
  displayName: string
  onCreated: () => Promise<void> | void
  onSignOut: () => Promise<void> | void
}

export function CharacterSetup({ userId, displayName, onCreated, onSignOut }: Props) {
  const [name, setName] = useState('')
  const [race, setRace] = useState('Человек')
  const [bio, setBio] = useState('')
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

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

      <section className="panel character-create">
        <form className="form-stack" onSubmit={submit}>
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
    </main>
  )
}
