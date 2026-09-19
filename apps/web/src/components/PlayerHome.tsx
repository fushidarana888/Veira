import { useMemo, useState } from 'react'
import { experienceForNextLevel } from '@veira/game-core'
import type { Character, CharacterProgress, Profile } from '../types'

type Props = {
  profile: Profile
  character: Character
  onSignOut: () => Promise<void> | void
}

type Tab = 'world' | 'character' | 'adventures' | 'community' | 'more'

function normalizeProgress(value: Character['character_progress']): CharacterProgress | null {
  if (Array.isArray(value)) return value[0] ?? null
  return value
}

export function PlayerHome({ profile, character, onSignOut }: Props) {
  const [tab, setTab] = useState<Tab>('character')
  const progress = useMemo(() => normalizeProgress(character.character_progress), [character.character_progress])

  if (!progress) {
    return (
      <main className="shell">
        <section className="panel">
          <h1>Прогресс персонажа не найден</h1>
          <p className="muted">Обнови страницу. Если ошибка останется, понадобится проверка базы.</p>
        </section>
      </main>
    )
  }

  const nextLevel = experienceForNextLevel(progress.level)
  const expPercent = Math.min(100, Math.round((progress.experience / nextLevel) * 100))
  const hpPercent = Math.min(100, Math.round((progress.hp_current / progress.hp_max) * 100))

  return (
    <main className="shell game-shell">
      <header className="topbar">
        <div className="identity">
          <div className="avatar-placeholder" aria-hidden="true">
            {character.name.slice(0, 1).toUpperCase()}
          </div>
          <div>
            <span className="eyebrow">{character.race}</span>
            <h1>{character.name}</h1>
            <p className="muted">@{profile.display_name}</p>
          </div>
        </div>

        <div className="top-actions">
          <span className="badge">LVL {progress.level}</span>
          <button className="ghost-button" type="button" onClick={() => void onSignOut()}>
            Выйти
          </button>
        </div>
      </header>

      {tab === 'character' && (
        <>
          <section className="dashboard-grid">
            <article className="panel vital-card">
              <div className="card-heading">
                <span>Здоровье</span>
                <strong>{progress.hp_current} / {progress.hp_max}</strong>
              </div>
              <div className="meter"><span style={{ width: hpPercent + '%' }} /></div>
            </article>

            <article className="panel vital-card">
              <div className="card-heading">
                <span>Опыт</span>
                <strong>{progress.experience} / {nextLevel}</strong>
              </div>
              <div className="meter exp-meter"><span style={{ width: expPercent + '%' }} /></div>
            </article>

            <article className="panel currency-card">
              <span>Золото</span>
              <strong>{progress.gold.toLocaleString('ru-RU')}</strong>
            </article>
          </section>

          <section className="panel">
            <div className="section-heading">
              <div>
                <span className="eyebrow">ХАРАКТЕРИСТИКИ</span>
                <h2>Основа персонажа</h2>
              </div>
            </div>

            <div className="stats-grid">
              <Stat label="Сила" value={progress.strength} />
              <Stat label="Ловкость" value={progress.agility} />
              <Stat label="Интеллект" value={progress.intellect} />
              <Stat label="Живучесть" value={progress.vitality} />
              <Stat label="Удача" value={progress.luck} />
            </div>
          </section>

          <section className="panel">
            <span className="eyebrow">БИОГРАФИЯ</span>
            <p className="bio-text">{character.bio || 'Биография пока не заполнена.'}</p>
          </section>
        </>
      )}

      {tab === 'world' && <Placeholder title="Мир" text="Здесь появится личная карта Эйлара, исследованные сектора и экспедиции." />}
      {tab === 'adventures' && <Placeholder title="Приключения" text="Здесь будут пати, данжи, боссы и активные прохождения." />}
      {tab === 'community' && <Placeholder title="Сообщество" text="Здесь появятся гильдии, игроки и социальные механики." />}
      {tab === 'more' && <Placeholder title="Ещё" text="Настройки, достижения, журнал и другие разделы Veira." />}

      <nav className="bottom-nav" aria-label="Основная навигация">
        <NavButton active={tab === 'world'} onClick={() => setTab('world')}>Мир</NavButton>
        <NavButton active={tab === 'character'} onClick={() => setTab('character')}>Персонаж</NavButton>
        <NavButton active={tab === 'adventures'} onClick={() => setTab('adventures')}>Приключения</NavButton>
        <NavButton active={tab === 'community'} onClick={() => setTab('community')}>Сообщество</NavButton>
        <NavButton active={tab === 'more'} onClick={() => setTab('more')}>Ещё</NavButton>
      </nav>
    </main>
  )
}

function Stat({ label, value }: { label: string; value: number }) {
  return (
    <div className="stat-tile">
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  )
}

function Placeholder({ title, text }: { title: string; text: string }) {
  return (
    <section className="panel placeholder-panel">
      <span className="eyebrow">СКОРО</span>
      <h2>{title}</h2>
      <p className="muted">{text}</p>
    </section>
  )
}

function NavButton({
  active,
  onClick,
  children,
}: {
  active: boolean
  onClick: () => void
  children: string
}) {
  return (
    <button type="button" className={active ? 'active' : ''} onClick={onClick}>
      {children}
    </button>
  )
}
