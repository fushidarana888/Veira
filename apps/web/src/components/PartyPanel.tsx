import { userFacingError } from '../lib/userError'
import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useSmartRefresh } from '../lib/smartRefresh'

type PartyInfo = {
  id: string
  leader_character_id: string
  member_count: number
  created_at: string
}

type PartyMember = {
  character_id: string
  name: string
  race: string
  display_name: string
  level: number
  hp_current: number
  hp_max: number
  joined_at: string
  is_leader: boolean
}

type IncomingInvite = {
  id: string
  party_id: string
  inviter_character_id: string
  inviter_name: string
  inviter_display_name: string
  party_size: number
  created_at: string
  expires_at: string
}

type OutgoingInvite = {
  id: string
  target_character_id: string
  target_name: string
  target_display_name: string
  created_at: string
  expires_at: string
}

type PartyCandidate = {
  character_id: string
  name: string
  race: string
  display_name: string
  level: number
  in_party: boolean
}

type PartyOverview = {
  party: PartyInfo | null
  members: PartyMember[]
  incoming_invites: IncomingInvite[]
  outgoing_invites: OutgoingInvite[]
}

type Props = {
  characterId: string
}

const emptyOverview: PartyOverview = {
  party: null,
  members: [],
  incoming_invites: [],
  outgoing_invites: [],
}

function partyError(raw: string) {
  if (raw.includes('PARTY_FULL')) return 'В группе уже 4 персонажа.'
  if (raw.includes('TARGET_ALREADY_IN_PARTY')) return 'Этот персонаж уже состоит в другой группе.'
  if (raw.includes('PARTY_INVITE_ALREADY_PENDING')) return 'Приглашение этому персонажу уже отправлено.'
  if (raw.includes('CHARACTER_ALREADY_IN_PARTY')) return 'Персонаж уже состоит в группе.'
  if (raw.includes('PARTY_INVITE_EXPIRED')) return 'Приглашение уже истекло.'
  if (raw.includes('PARTY_INVITE_NOT_PENDING')) return 'Это приглашение уже обработано.'
  if (raw.includes('PARTY_NOT_ACTIVE')) return 'Эта группа уже распущена.'
  if (raw.includes('PARTY_LEADER_REQUIRED')) return 'Это действие доступно только лидеру группы.'
  return userFacingError(raw)
}

export function PartyPanel({ characterId }: Props) {
  const [overview, setOverview] = useState<PartyOverview>(emptyOverview)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const [query, setQuery] = useState('')
  const [candidates, setCandidates] = useState<PartyCandidate[]>([])
  const [searching, setSearching] = useState(false)

  async function loadParty(silent = false) {
    if (!silent) setLoading(true)

    const { data, error } = await supabase.rpc('get_party_overview', {
      p_character_id: characterId,
    })

    if (error) {
      setMessage(partyError(error.message))
      if (!silent) setLoading(false)
      return
    }

    setOverview((data as PartyOverview | null) ?? emptyOverview)
    if (!silent) setLoading(false)
  }

  useEffect(() => {
    void loadParty()
  }, [characterId])

  useSmartRefresh(
    () => loadParty(true),
    { enabled: true, intervalMs: 15000, minGapMs: 1400 },
  )

  async function createParty() {
    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('create_party', {
      p_character_id: characterId,
    })

    if (error) {
      setMessage(partyError(error.message))
      setBusy(false)
      return
    }

    await loadParty(true)
    setMessage('Группа создана. Теперь можно пригласить до трёх персонажей.')
    setBusy(false)
  }

  async function searchCandidates() {
    const trimmed = query.trim()

    if (trimmed.length < 2) {
      setMessage('Для поиска введи хотя бы 2 символа.')
      setCandidates([])
      return
    }

    setSearching(true)
    setMessage('')

    const { data, error } = await supabase.rpc('search_party_candidates', {
      p_character_id: characterId,
      p_query: trimmed,
    })

    if (error) {
      setMessage(partyError(error.message))
      setCandidates([])
      setSearching(false)
      return
    }

    setCandidates((data as PartyCandidate[] | null) ?? [])
    setSearching(false)
  }

  async function invite(targetCharacterId: string) {
    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('invite_character_to_party', {
      p_character_id: characterId,
      p_target_character_id: targetCharacterId,
    })

    if (error) {
      setMessage(partyError(error.message))
      setBusy(false)
      return
    }

    await loadParty(true)
    setCandidates((current) => current.filter((entry) => entry.character_id !== targetCharacterId))
    setMessage('Приглашение отправлено.')
    setBusy(false)
  }

  async function respond(inviteId: string, accept: boolean) {
    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('respond_to_party_invite', {
      p_invite_id: inviteId,
      p_accept: accept,
    })

    if (error) {
      setMessage(partyError(error.message))
      setBusy(false)
      await loadParty(true)
      return
    }

    await loadParty(true)
    setMessage(accept ? 'Ты вступил в группу.' : 'Приглашение отклонено.')
    setBusy(false)
  }

  async function cancelInvite(inviteId: string) {
    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('cancel_party_invite', {
      p_character_id: characterId,
      p_invite_id: inviteId,
    })

    if (error) {
      setMessage(partyError(error.message))
      setBusy(false)
      return
    }

    await loadParty(true)
    setMessage('Приглашение отменено.')
    setBusy(false)
  }

  async function kick(member: PartyMember) {
    if (!window.confirm(`Исключить «${member.name}» из группы?`)) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('kick_party_member', {
      p_character_id: characterId,
      p_member_character_id: member.character_id,
    })

    if (error) {
      setMessage(partyError(error.message))
      setBusy(false)
      return
    }

    await loadParty(true)
    setMessage(`${member.name} исключён из группы.`)
    setBusy(false)
  }

  async function leaveParty() {
    const leader = overview.party?.leader_character_id === characterId
    const copy = leader && overview.members.length > 1
      ? 'Ты лидер. После выхода лидерство автоматически перейдёт следующему участнику.'
      : 'Выйти из группы?'

    if (!window.confirm(copy)) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('leave_party', {
      p_character_id: characterId,
    })

    if (error) {
      setMessage(partyError(error.message))
      setBusy(false)
      return
    }

    setCandidates([])
    setQuery('')
    await loadParty(true)
    setMessage('Ты вышел из группы.')
    setBusy(false)
  }

  async function disbandParty() {
    if (!window.confirm('Распустить группу полностью? Все участники будут исключены, а приглашения отменены.')) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('disband_party', {
      p_character_id: characterId,
    })

    if (error) {
      setMessage(partyError(error.message))
      setBusy(false)
      return
    }

    setCandidates([])
    setQuery('')
    await loadParty(true)
    setMessage('Группа распущена.')
    setBusy(false)
  }

  const party = overview.party
  const isLeader = party?.leader_character_id === characterId
  const full = (party?.member_count ?? 0) >= 4

  if (loading) {
    return (
      <article className="panel party-panel">
        <span className="eyebrow">ГРУППА</span>
        <h3>Проверяем состав…</h3>
      </article>
    )
  }

  return (
    <article className="panel party-panel">
      <div className="section-heading">
        <div>
          <span className="eyebrow">ГРУППА · ОСНОВА КООПЕРАТИВА</span>
          <h2>{party ? `Отряд ${party.member_count} / 4` : 'Собери отряд'}</h2>
          <p className="muted">
            Группа рассчитана на 2–4 персонажа. Лидер приглашает участников и управляет составом.
          </p>
        </div>
        {party && <span className="badge">{isLeader ? 'лидер' : 'участник'}</span>}
      </div>

      {message && <p className="form-message" aria-live="polite">{message}</p>}

      {overview.incoming_invites.length > 0 && (
        <div className="party-invites-block">
          <div className="party-subheading">
            <strong>Входящие приглашения</strong>
            <span>{overview.incoming_invites.length}</span>
          </div>

          <div className="party-invite-list">
            {overview.incoming_invites.map((invite) => (
              <div className="party-invite-row" key={invite.id}>
                <div>
                  <strong>{invite.inviter_name}</strong>
                  <span>@{invite.inviter_display_name} · в группе {invite.party_size}/4</span>
                </div>
                <div className="party-inline-actions">
                  <button
                    className="primary-button"
                    type="button"
                    disabled={busy || Boolean(party)}
                    onClick={() => void respond(invite.id, true)}
                  >
                    Принять
                  </button>
                  <button
                    className="ghost-button"
                    type="button"
                    disabled={busy}
                    onClick={() => void respond(invite.id, false)}
                  >
                    Отклонить
                  </button>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {!party ? (
        <div className="party-empty-state">
          <div>
            <strong>Сейчас ты без группы</strong>
            <p className="muted">
              Создай группу, после чего сможешь найти персонажа по имени или нику аккаунта и отправить приглашение.
            </p>
          </div>
          <button className="primary-button" type="button" disabled={busy} onClick={() => void createParty()}>
            Создать группу
          </button>
        </div>
      ) : (
        <>
          <div className="party-member-grid">
            {overview.members.map((member) => {
              const hpPercent = member.hp_max > 0
                ? Math.max(0, Math.min(100, Math.round(member.hp_current / member.hp_max * 100)))
                : 0

              return (
                <div className="party-member-card" key={member.character_id}>
                  <div className="party-member-head">
                    <div>
                      <strong>{member.name}</strong>
                      <span>@{member.display_name} · {member.race}</span>
                    </div>
                    <span className="badge">{member.is_leader ? 'лидер' : 'УР. ' + member.level}</span>
                  </div>

                  <div className="party-hp-row">
                    <span>ОЗ {member.hp_current} / {member.hp_max}</span>
                    <div className="party-hp-meter"><span style={{ width: hpPercent + '%' }} /></div>
                  </div>

                  {isLeader && !member.is_leader && (
                    <button
                      className="ghost-button danger-button party-kick-button"
                      type="button"
                      disabled={busy}
                      onClick={() => void kick(member)}
                    >
                      Исключить
                    </button>
                  )}
                </div>
              )
            })}
          </div>

          {isLeader && (
            <div className="party-recruit-block">
              <div className="party-subheading">
                <strong>Пригласить персонажа</strong>
                <span>{full ? 'группа заполнена' : 'свободно ' + (4 - (party.member_count ?? 0))}</span>
              </div>

              <div className="party-search-row">
                <input
                  value={query}
                  disabled={full || busy}
                  placeholder="Имя персонажа или ник аккаунта"
                  onChange={(event) => setQuery(event.target.value)}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter') void searchCandidates()
                  }}
                />
                <button
                  className="ghost-button"
                  type="button"
                  disabled={full || busy || searching}
                  onClick={() => void searchCandidates()}
                >
                  {searching ? 'Ищем…' : 'Найти'}
                </button>
              </div>

              {candidates.length > 0 && (
                <div className="party-candidate-list">
                  {candidates.map((candidate) => (
                    <div className="party-candidate-row" key={candidate.character_id}>
                      <div>
                        <strong>{candidate.name}</strong>
                        <span>@{candidate.display_name} · {candidate.race} · УР. {candidate.level}</span>
                      </div>
                      <button
                        className="primary-button"
                        type="button"
                        disabled={busy || full || candidate.in_party}
                        onClick={() => void invite(candidate.character_id)}
                      >
                        {candidate.in_party ? 'Уже в группе' : 'Пригласить'}
                      </button>
                    </div>
                  ))}
                </div>
              )}

              {overview.outgoing_invites.length > 0 && (
                <div className="party-outgoing-list">
                  {overview.outgoing_invites.map((invite) => (
                    <div className="party-outgoing-row" key={invite.id}>
                      <span>Ожидаем <strong>{invite.target_name}</strong> · @{invite.target_display_name}</span>
                      <button
                        className="ghost-button"
                        type="button"
                        disabled={busy}
                        onClick={() => void cancelInvite(invite.id)}
                      >
                        Отменить
                      </button>
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}

          <div className="party-footer-actions">
            <button className="ghost-button danger-button" type="button" disabled={busy} onClick={() => void leaveParty()}>
              Выйти из группы
            </button>
            {isLeader && (
              <button className="ghost-button danger-button" type="button" disabled={busy} onClick={() => void disbandParty()}>
                Распустить группу
              </button>
            )}
          </div>
        </>
      )}
    </article>
  )
}
