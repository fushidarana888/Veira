import { userFacingError } from '../lib/userError'
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
      const normalizedEmail = email.trim().toLowerCase()

      const { data: registrationData, error: registrationError } = await supabase.functions.invoke(
        'register-user',
        {
          body: {
            email: normalizedEmail,
            password,
            displayName: displayName.trim(),
          },
        },
      )

      if (registrationError) {
        setMessage('Не удалось создать аккаунт. Попробуй ещё раз чуть позже.')
        setBusy(false)
        return
      }

      const registrationCode =
        registrationData && typeof registrationData === 'object' && 'error' in registrationData
          ? String((registrationData as { error?: unknown }).error ?? '')
          : ''

      if (registrationCode) {
        if (registrationCode === 'EMAIL_ALREADY_REGISTERED') {
          setMessage('Аккаунт с такой почтой уже существует.')
        } else if (registrationCode === 'RATE_LIMITED') {
          setMessage('Слишком много регистраций за короткое время. Попробуй позже.')
        } else if (registrationCode === 'INVALID_PASSWORD') {
          setMessage('Пароль должен содержать от 6 до 72 символов.')
        } else {
          setMessage('Не удалось создать аккаунт. Проверь данные и попробуй ещё раз.')
        }
        setBusy(false)
        return
      }

      const { error: signInError } = await supabase.auth.signInWithPassword({
        email: normalizedEmail,
        password,
      })

      if (signInError) {
        setMessage('Аккаунт создан. Войди с указанной почтой и паролем.')
      }
    } else {
      const { error } = await supabase.auth.signInWithPassword({
        email: email.trim(),
        password,
      })

      if (error) setMessage(userFacingError(error.message, 'Не удалось выполнить вход.'))
    }

    setBusy(false)
  }

  return (
    <main className="auth-layout">
      <section className="auth-copy">
        <span className="eyebrow">VEIRA · ИГРА</span>
        <h1>Войди в Эйлар</h1>
        <p>
          Один аккаунт хранит твоих персонажей и весь игровой прогресс.
          При регистрации письмо подтверждать не нужно — играть можно сразу.
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

          {mode === 'register' && (
            <p className="auth-register-note">
              Почта станет подтверждённой только после отдельной проверки из настроек аккаунта.
              Это не мешает сразу создать персонажа и играть.
            </p>
          )}
        </form>

        {message && <p className="form-message" aria-live="polite">{message}</p>}
      </section>
    </main>
  )
}
