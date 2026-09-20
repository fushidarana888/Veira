import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'

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

type PartyOverview = {
  party: {
    id: string
    leader_character_id: string
    member_count: number
  } | null
  members: Array<{
    character_id: string
    name: string
    is_leader: boolean
  }>
}

const emptyParty: PartyOverview = { party: null, members: [] }

export function EventBossesPanel({ characterId }: { characterId: string }) {
  const [kind, setKind] = useState<EventBossKind>('weekly')
  const [party, setParty] = useState<PartyOverview>(emptyParty)
  const copy = kindLabels[kind]

  useEffect(() => {
    let cancelled = false

    async function loadParty() {
      const { data, error } = await supabase.rpc('get_party_overview', {
        p_character_id: characterId,
      })

      if (!cancelled && !error) {
        setParty((data as PartyOverview | null) ?? emptyParty)
      }
    }

    void loadParty()
    const timer = window.setInterval(() => void loadParty(), 10000)

    return () => {
      cancelled = true
      window.clearInterval(timer)
    }
  }, [characterId])

  const partySize = party.party?.member_count ?? party.members.length
  const inParty = Boolean(party.party)
  const isLeader = party.party?.leader_character_id === characterId

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
          <strong>Соло или группа</strong>
          <span>Недельные и месячные боссы рассчитаны и на одиночный вход, и на существующую пати до 4 персонажей.</span>
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

      <div className="event-boss-party-state">
        <div>
          <span className="eyebrow">РЕЖИМ ВХОДА</span>
          <strong>{inParty ? `Текущая пати · ${partySize}/4` : 'Соло'}</strong>
          <small>
            {inParty
              ? isLeader
                ? 'Ты лидер группы. При групповом входе запуск события будет подтверждать лидер.'
                : 'Ты состоишь в группе. На группового босса вас запускает лидер.'
              : 'Можно идти одному или сначала создать группу в разделе выше.'}
          </small>
        </div>
        <div className="event-boss-entry-modes">
          <span className="active">Соло</span>
          <span className={inParty ? 'active' : ''}>Пати до 4</span>
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
