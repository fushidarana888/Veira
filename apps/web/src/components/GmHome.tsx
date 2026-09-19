import type { Profile } from '../types'

type Props = {
  profile: Profile
  onSignOut: () => Promise<void> | void
}

export function GmHome({ profile, onSignOut }: Props) {
  return (
    <main className="shell">
      <header className="topbar">
        <div>
          <span className="eyebrow">VEIRA GAME MASTER</span>
          <h1>Панель мира</h1>
          <p className="muted">{profile.display_name}</p>
        </div>
        <div className="top-actions">
          <span className="badge gm-badge">GM</span>
          <button className="ghost-button" type="button" onClick={() => void onSignOut()}>
            Выйти
          </button>
        </div>
      </header>

      <section className="gm-grid">
        <article className="panel">
          <span className="eyebrow">ЖИВОЙ МИР</span>
          <h2>Активные события</h2>
          <p className="muted">Позже здесь будут экспедиции, данжи и рейды, в которые можно вмешаться вручную.</p>
        </article>

        <article className="panel">
          <span className="eyebrow">КОНТЕНТ</span>
          <h2>Редактор мира</h2>
          <p className="muted">Сектора, события, NPC, предметы, таблицы лута, боссы и данжи.</p>
        </article>

        <article className="panel">
          <span className="eyebrow">КОНТРОЛЬ</span>
          <h2>Журнал GM</h2>
          <p className="muted">Все административные действия будут записываться в защищённый audit log.</p>
        </article>
      </section>
    </main>
  )
}
