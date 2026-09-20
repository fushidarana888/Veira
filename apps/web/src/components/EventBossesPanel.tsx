import { useState } from 'react'

type EventBossKind = 'weekly' | 'monthly'

const kindLabels: Record<EventBossKind, { title: string; eyebrow: string; description: string }> = {
  weekly: {
    title: 'Недельные боссы',
    eyebrow: 'НЕДЕЛЬНАЯ УГРОЗА',
    description: 'Временные боссы с полезными наградами и особыми предметами. Ротация меняется каждую неделю.',
  },
  monthly: {
    title: 'Месячные боссы',
    eyebrow: 'МЕСЯЧНАЯ УГРОЗА',
    description: 'Более редкие и сложные противники с особенно ценными наградами и долгой ротацией.',
  },
}

export function EventBossesPanel() {
  const [kind, setKind] = useState<EventBossKind>('weekly')
  const copy = kindLabels[kind]

  return (
    <article className="panel event-bosses-panel">
      <div className="section-heading event-bosses-heading">
        <div>
          <span className="eyebrow">ОСОБЫЕ УГРОЗЫ</span>
          <h2>Временные боссы</h2>
          <p className="muted">
            Эти боссы не находятся на карте. Когда событие активно, к нему можно перейти прямо из «Приключений».
          </p>
        </div>
        <span className="badge">события</span>
      </div>

      <div className="event-boss-rules">
        <div>
          <strong>Доступ</strong>
          <span>Можно отправиться к боссу в любой момент, если персонаж сейчас не находится в экспедиции.</span>
        </div>
        <div>
          <strong>Особая добыча</strong>
          <span>У каждой ротации может быть собственная награда: заточка, материалы, аффиксы, пробуждение или уникальные предметы.</span>
        </div>
        <div>
          <strong>Не связаны с картой</strong>
          <span>Открывать сектор или искать вход не нужно. Активные события появляются здесь автоматически.</span>
        </div>
      </div>

      <div className="event-boss-tabs" role="tablist" aria-label="Тип временного босса">
        {(Object.keys(kindLabels) as EventBossKind[]).map((entry) => (
          <button
            key={entry}
            className={kind === entry ? 'active' : ''}
            type="button"
            role="tab"
            aria-selected={kind === entry}
            onClick={() => setKind(entry)}
          >
            {entry === 'weekly' ? 'Недельные' : 'Месячные'}
          </button>
        ))}
      </div>

      <section className="event-boss-empty" aria-live="polite">
        <div className="event-boss-empty-mark" aria-hidden="true">◆</div>
        <span className="eyebrow">{copy.eyebrow}</span>
        <h3>{copy.title}</h3>
        <p>{copy.description}</p>
        <div className="event-boss-empty-state">
          <strong>Сейчас активных боссов нет</strong>
          <span>Когда появится новая ротация, здесь будут показаны срок события, сложность, особая добыча и кнопка входа.</span>
        </div>
      </section>
    </article>
  )
}
