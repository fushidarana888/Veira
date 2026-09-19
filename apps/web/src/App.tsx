import { useEffect, useState } from 'react'
import type { AccountType } from '@veira/game-core'
import { supabase } from './lib/supabase'

type Profile = {
  user_id: string
  display_name: string
  avatar_url: string | null
  account_type: AccountType
}

export function App() {
  const [profile, setProfile] = useState<Profile | null>(null)
  const [status, setStatus] = useState('Проверяем сессию…')

  useEffect(() => {
    let alive = true

    async function load() {
      const { data: { user } } = await supabase.auth.getUser()
      if (!alive) return

      if (!user) {
        setStatus('Вход не выполнен')
        return
      }

      const { data, error } = await supabase
        .from('profiles')
        .select('user_id, display_name, avatar_url, account_type')
        .eq('user_id', user.id)
        .single()

      if (!alive) return
      if (error) {
        setStatus('Не удалось загрузить профиль')
        return
      }

      setProfile(data as Profile)
      setStatus('')
    }

    load()
    return () => { alive = false }
  }, [])

  return (
    <main className="shell">
      <header className="topbar">
        <div>
          <span className="eyebrow">VEIRA GAME</span>
          <h1>{profile ? 'Добро пожаловать, ' + profile.display_name : 'Veira'}</h1>
        </div>
        <span className="badge">{profile?.account_type === 'gm' ? 'GM' : 'PLAYER'}</span>
      </header>

      <section className="hero">
        <p>{status || 'Фундамент аккаунтов подключён. Следующий модуль — персонажи и игровой профиль.'}</p>
      </section>

      <nav className="bottom-nav" aria-label="Основная навигация">
        <button type="button">Мир</button>
        <button type="button">Персонаж</button>
        <button type="button">Приключения</button>
        <button type="button">Сообщество</button>
        <button type="button">Ещё</button>
      </nav>
    </main>
  )
}
