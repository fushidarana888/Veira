import { useState } from 'react'
import { GuildPanel } from './GuildPanel'

type Props = {
  characterId: string
  onBack: () => void
}

type CommunityView = 'guilds'

export function CommunitiesPanel({ characterId, onBack }: Props) {
  const [view, setView] = useState<CommunityView>('guilds')

  return (
    <section className="communities-section">
      <article className="panel communities-header-panel">
        <div>
          <span className="eyebrow">СООБЩЕСТВА</span>
          <h2>Объединения игроков</h2>
          <p className="muted">
            Здесь собраны постоянные социальные объединения Veira. Сейчас доступны гильдии;
            позже сюда можно добавить другие виды сообществ, не смешивая их с настройками аккаунта.
          </p>
        </div>
        <button className="ghost-button" type="button" onClick={onBack}>Назад</button>
      </article>

      <div className="subnav communities-subnav" aria-label="Разделы сообществ">
        <button
          type="button"
          className={view === 'guilds' ? 'active' : ''}
          onClick={() => setView('guilds')}
        >
          Гильдии
        </button>
      </div>

      {view === 'guilds' && (
        <GuildPanel characterId={characterId} embedded />
      )}
    </section>
  )
}
