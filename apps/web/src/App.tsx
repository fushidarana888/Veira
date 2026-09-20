import { lazy, Suspense, useCallback, useEffect, useRef, useState } from 'react'
import type { User } from '@supabase/supabase-js'
import { AuthScreen } from './components/AuthScreen'
import { supabase } from './lib/supabase'
import type { Character, Profile } from './types'

const CharacterSetup = lazy(() => import('./components/CharacterSetup').then((module) => ({ default: module.CharacterSetup })))
const GmHome = lazy(() => import('./components/GmHome').then((module) => ({ default: module.GmHome })))
const PlayerHome = lazy(() => import('./components/PlayerHome').then((module) => ({ default: module.PlayerHome })))

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
  const loadedUserIdRef = useRef<string | null>(null)

  const loadAccount = useCallback(async (user: User | null) => {
    if (!user) {
      loadedUserIdRef.current = null
      setState({ ...initialState, loading: false })
      return
    }

    setState((current) => ({ ...current, user, loading: true, error: '' }))

    // If this session was created through an email OTP / magic-link flow,
    // trust it as proof that the user controls the mailbox.
    await supabase.rpc('mark_email_verified_from_otp')

    const { data: profileData, error: profileError } = await supabase
      .from('profiles')
      .select('user_id, display_name, avatar_url, account_type, email_verified, email_verified_at')
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
        race_id,
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
          mana_current,
          mana_max,
          strength,
          agility,
          intellect,
          vitality,
          luck,
          gold,
          unspent_stat_points,
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

    loadedUserIdRef.current = user.id
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

    const { data: authListener } = supabase.auth.onAuthStateChange((event, session) => {
      if (!active) return

      if (event === 'SIGNED_OUT') {
        loadedUserIdRef.current = null
        void loadAccount(null)
        return
      }

      if (event === 'TOKEN_REFRESHED') {
        if (session?.user) {
          setState((current) => current.user?.id === session.user.id
            ? { ...current, user: session.user }
            : current)
        }
        return
      }

      if (event === 'INITIAL_SESSION') return

      const nextUser = session?.user ?? null
      if (
        event === 'SIGNED_IN'
        && nextUser
        && loadedUserIdRef.current === nextUser.id
      ) return

      if (event === 'SIGNED_IN' || event === 'USER_UPDATED' || event === 'PASSWORD_RECOVERY') {
        void loadAccount(nextUser)
      }
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
    return (
      <Suspense fallback={<AppSectionLoading />}>
        <GmHome profile={state.profile} onSignOut={signOut} />
      </Suspense>
    )
  }

  if (!state.character) {
    return (
      <Suspense fallback={<AppSectionLoading />}>
        <CharacterSetup
          userId={state.user.id}
          displayName={state.profile.display_name}
          onCreated={() => loadAccount(state.user)}
          onSignOut={signOut}
        />
      </Suspense>
    )
  }

  return (
    <Suspense fallback={<AppSectionLoading />}>
      <PlayerHome
        profile={state.profile}
        character={state.character}
        userEmail={state.user.email ?? ''}
        onSignOut={signOut}
      />
    </Suspense>
  )
}

function AppSectionLoading() {
  return (
    <main className="loading-screen">
      <div className="loading-mark">V</div>
      <p>Открываем раздел…</p>
    </main>
  )
}
