import { FormEvent, useState } from 'react'
import { supabase } from '../lib/supabase'

export function AuthScreen() {
  const [mode, setMode] = useState<'login' | 'register'>('login')
  const [displayName, setDisplayName] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setMessage('')

    if (!email.trim() || password.length < 6) {
      setMessage('Укажи почту и пароль минимум из 6 символов.')
      return
    }

    if (mode === 'register' && !displayName.trim()) {
      setMessage('Укажи имя игрового аккаунта.')
      return
    }

    setBusy(true)

    if (mode === 'register') {
      const { data, error } = await supabase.auth.signUp({
        email: email.trim(),
        password,
        options: {
          data: { display_name: displayName.trim() },
        },
      })

      if (error) {
        setMessage(error.message)
      } else if (!data.session) {
        setMessage('Аккаунт создан. Если подтверждение почты включено, открой письмо от Veira.')
      } else {
        setMessage('Аккаунт создан.')
      }
    } else {
      const { error } = await supabase.auth.signInWithPassword({
        email: email.trim(),
        password,
      })

      if (error) setMessage(error.message)
    }

    setBusy(false)
  }

  return (
    <main className="auth-layout">
      <section className="auth-copy">
        <span className="eyebrow">VEIRA GAME</span>
        <h1>Войди в Эйлар</h1>
        <p>
          Один аккаунт хранит твоих персонажей и весь игровой прогресс.
          GM-аккаунты создаются отдельно и не получают игровых персонажей.
        </p>
      </section>

      <section className="auth-card">
        <div className="segmented" aria-label="Режим авторизации">
          <button
            type="button"
            className={mode === 'login' ? 'active' : ''}
            onClick={() => { setMode('login'); setMessage('') }}
          >
            Вход
          </button>
          <button
            type="button"
            className={mode === 'register' ? 'active' : ''}
            onClick={() => { setMode('register'); setMessage('') }}
          >
            Регистрация
          </button>
        </div>

        <form onSubmit={submit} className="form-stack">
          {mode === 'register' && (
            <label>
              <span>Имя аккаунта</span>
              <input
                value={displayName}
                onChange={(event) => setDisplayName(event.target.value)}
                maxLength={40}
                autoComplete="nickname"
                placeholder="Например, Fushi"
              />
            </label>
          )}

          <label>
            <span>Почта</span>
            <input
              type="email"
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              autoComplete="email"
              placeholder="you@example.com"
            />
          </label>

          <label>
            <span>Пароль</span>
            <input
              type="password"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              autoComplete={mode === 'login' ? 'current-password' : 'new-password'}
              placeholder="Минимум 6 символов"
            />
          </label>

          <button className="primary-button" type="submit" disabled={busy}>
            {busy ? 'Подожди…' : mode === 'login' ? 'Войти' : 'Создать аккаунт'}
          </button>
        </form>

        {message && <p className="form-message" aria-live="polite">{message}</p>}
      </section>
    </main>
  )
}
