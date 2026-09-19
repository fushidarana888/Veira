import { useCallback, useEffect, useState } from 'react'
import type { User } from '@supabase/supabase-js'
import { AuthScreen } from './components/AuthScreen'
import { CharacterSetup } from './components/CharacterSetup'
import { GmHome } from './components/GmHome'
import { PlayerHome } from './components/PlayerHome'
import { supabase } from './lib/supabase'
import type { Character, Profile } from './types'

type AccountState = {
  user: User | null
  profile: Profile | null
  character: Character | null
  loading: boolean
  error: string
}

const initialState: AccountState = {
  user: null,
  profile: null,
  character: null,
  loading: true,
  error: '',
}

export function App() {
  const [state, setState] = useState<AccountState>(initialState)

  const loadAccount = useCallback(async (user: User | null) => {
    if (!user) {
      setState({ ...initialState, loading: false })
      return
    }

    setState((current) => ({ ...current, user, loading: true, error: '' }))

    const { data: profileData, error: profileError } = await supabase
      .from('profiles')
      .select('user_id, display_name, avatar_url, account_type')
      .eq('user_id', user.id)
      .single()

    if (profileError || !profileData) {
      setState({
        user,
        profile: null,
        character: null,
        loading: false,
        error: profileError?.message ?? 'Профиль аккаунта не найден.',
      })
      return
    }

    const profile = profileData as Profile

    if (profile.account_type === 'gm') {
      setState({ user, profile, character: null, loading: false, error: '' })
      return
    }

    const { data: characterData, error: characterError } = await supabase
      .from('characters')
      .select(`
        id,
        owner_user_id,
        name,
        race,
        bio,
        avatar_url,
        created_at,
        updated_at,
        character_progress (
          character_id,
          level,
          experience,
          hp_current,
          hp_max,
          strength,
          agility,
          intellect,
          vitality,
          luck,
          gold,
          updated_at
        )
      `)
      .eq('owner_user_id', user.id)
      .order('created_at', { ascending: true })
      .limit(1)
      .maybeSingle()

    if (characterError) {
      setState({
        user,
        profile,
        character: null,
        loading: false,
        error: characterError.message,
      })
      return
    }

    setState({
      user,
      profile,
      character: (characterData as Character | null) ?? null,
      loading: false,
      error: '',
    })
  }, [])

  useEffect(() => {
    let active = true

    supabase.auth.getUser().then(({ data }) => {
      if (active) void loadAccount(data.user)
    })

    const { data: authListener } = supabase.auth.onAuthStateChange((_event, session) => {
      if (active) void loadAccount(session?.user ?? null)
    })

    return () => {
      active = false
      authListener.subscription.unsubscribe()
    }
  }, [loadAccount])

  async function signOut() {
    await supabase.auth.signOut()
  }

  if (state.loading) {
    return (
      <main className="loading-screen">
        <div className="loading-mark">V</div>
        <p>Загружаем Veira…</p>
      </main>
    )
  }

  if (!state.user) return <AuthScreen />

  if (state.error) {
    return (
      <main className="shell">
        <section className="panel error-panel">
          <span className="eyebrow">ОШИБКА</span>
          <h1>Не удалось загрузить аккаунт</h1>
          <p className="muted">{state.error}</p>
          <div className="action-row">
            <button className="primary-button" type="button" onClick={() => void loadAccount(state.user)}>
              Повторить
            </button>
            <button className="ghost-button" type="button" onClick={() => void signOut()}>
              Выйти
            </button>
          </div>
        </section>
      </main>
    )
  }

  if (!state.profile) return null

  if (state.profile.account_type === 'gm') {
    return <GmHome profile={state.profile} onSignOut={signOut} />
  }

  if (!state.character) {
    return (
      <CharacterSetup
        userId={state.user.id}
        displayName={state.profile.display_name}
        onCreated={() => loadAccount(state.user)}
        onSignOut={signOut}
      />
    )
  }

  return (
    <PlayerHome
      profile={state.profile}
      character={state.character}
      onSignOut={signOut}
    />
  )
}
