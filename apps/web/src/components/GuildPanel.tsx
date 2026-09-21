import { userFacingError } from '../lib/userError'
import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'

type GuildRole = 'founder' | 'officer' | 'member'

type GuildSummary = {
  id: string
  name: string
  tag: string
  description: string
  founder_character_id: string
  member_limit: number
  member_count: number
  created_at: string
  role: GuildRole
}

type GuildMember = {
  character_id: string
  name: string
  race: string
  avatar_url: string | null
  role: GuildRole
  joined_at: string
  level: number
}

type GuildApplication = {
  id: string
  character_id: string
  name: string
  race: string
  level: number
  message: string
  created_at: string
}

type OwnApplication = {
  id: string
  guild_id: string
  guild_name: string
  guild_tag: string
  message: string
  created_at: string
}

type GuildDirectoryEntry = {
  id: string
  name: string
  tag: string
  description: string
  member_limit: number
  member_count: number
  founder_name: string
  created_at: string
}

type GuildHub = {
  guild: GuildSummary | null
  members: GuildMember[]
  applications: GuildApplication[]
  own_applications: OwnApplication[]
  directory: GuildDirectoryEntry[]
}

type Props = {
  characterId: string
  onBack?: () => void
  embedded?: boolean
}

const roleLabels: Record<GuildRole, string> = {
  founder: 'Основатель',
  officer: 'Офицер',
  member: 'Участник',
}

function guildError(raw: string) {
  if (raw.includes('GUILD_NAME_OR_TAG_TAKEN')) return 'Гильдия с таким названием или тегом уже существует.'
  if (raw.includes('GUILD_NAME_LENGTH')) return 'Название гильдии должно содержать от 3 до 40 символов.'
  if (raw.includes('GUILD_TAG_INVALID')) return 'Тег должен содержать 2–6 букв или цифр.'
  if (raw.includes('GUILD_DESCRIPTION_TOO_LONG')) return 'Описание не может быть длиннее 600 символов.'
  if (raw.includes('ALREADY_IN_GUILD')) return 'Персонаж уже состоит в гильдии.'
  if (raw.includes('GUILD_APPLICATION_ALREADY_PENDING')) return 'Заявка в эту гильдию уже отправлена.'
  if (raw.includes('GUILD_APPLICATION_TOO_LONG')) return 'Сообщение заявки не может быть длиннее 400 символов.'
  if (raw.includes('GUILD_FULL')) return 'В гильдии больше нет свободных мест.'
  if (raw.includes('FOUNDER_MUST_TRANSFER_OR_DISBAND')) return 'Основатель должен передать лидерство или распустить гильдию.'
  return userFacingError(raw)
}

export function GuildPanel({ characterId, onBack, embedded = false }: Props) {
  const [hub, setHub] = useState<GuildHub | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  const [name, setName] = useState('')
  const [tag, setTag] = useState('')
  const [description, setDescription] = useState('')
  const [applyGuildId, setApplyGuildId] = useState<string | null>(null)
  const [applicationMessage, setApplicationMessage] = useState('')

  const guild = hub?.guild ?? null
  const ownRole = guild?.role ?? null

  const pendingGuildIds = useMemo(
    () => new Set((hub?.own_applications ?? []).map((entry) => entry.guild_id)),
    [hub?.own_applications],
  )

  async function load(silent = false) {
    if (!silent) setLoading(true)
    const { data, error } = await supabase.rpc('get_guild_hub', {
      p_character_id: characterId,
    })

    if (error) {
      setMessage(guildError(error.message))
      if (!silent) setLoading(false)
      return
    }

    const next = data as GuildHub
    setHub(next)

    if (next.guild) {
      setName(next.guild.name)
      setTag(next.guild.tag)
      setDescription(next.guild.description)
    }

    if (!silent) setLoading(false)
  }

  useEffect(() => {
    void load()
  }, [characterId])

  async function createGuild() {
    setBusy(true)
    setMessage('')
    const { error } = await supabase.rpc('create_guild', {
      p_character_id: characterId,
      p_name: name,
      p_tag: tag,
      p_description: description,
    })
    if (error) {
      setMessage(guildError(error.message))
      setBusy(false)
      return
    }
    await load(true)
    setMessage('Гильдия создана.')
    setBusy(false)
  }

  async function apply(guildId: string) {
    setBusy(true)
    setMessage('')
    const { error } = await supabase.rpc('apply_to_guild', {
      p_character_id: characterId,
      p_guild_id: guildId,
      p_message: applicationMessage,
    })
    if (error) {
      setMessage(guildError(error.message))
      setBusy(false)
      return
    }
    setApplyGuildId(null)
    setApplicationMessage('')
    await load(true)
    setMessage('Заявка отправлена.')
    setBusy(false)
  }

  async function cancelApplication(applicationId: string) {
    setBusy(true)
    const { error } = await supabase.rpc('cancel_guild_application', {
      p_character_id: characterId,
      p_application_id: applicationId,
    })
    if (error) setMessage(guildError(error.message))
    else await load(true)
    setBusy(false)
  }

  async function resolveApplication(applicationId: string, accept: boolean) {
    setBusy(true)
    setMessage('')
    const { error } = await supabase.rpc('resolve_guild_application', {
      p_actor_character_id: characterId,
      p_application_id: applicationId,
      p_accept: accept,
    })
    if (error) setMessage(guildError(error.message))
    else {
      await load(true)
      setMessage(accept ? 'Заявка принята.' : 'Заявка отклонена.')
    }
    setBusy(false)
  }

  async function setRole(member: GuildMember, role: 'officer' | 'member') {
    setBusy(true)
    const { error } = await supabase.rpc('set_guild_member_role', {
      p_actor_character_id: characterId,
      p_target_character_id: member.character_id,
      p_role: role,
    })
    if (error) setMessage(guildError(error.message))
    else await load(true)
    setBusy(false)
  }

  async function removeMember(member: GuildMember) {
    if (!window.confirm(`Исключить «${member.name}» из гильдии?`)) return
    setBusy(true)
    const { error } = await supabase.rpc('remove_guild_member', {
      p_actor_character_id: characterId,
      p_target_character_id: member.character_id,
    })
    if (error) setMessage(guildError(error.message))
    else await load(true)
    setBusy(false)
  }

  async function transferFounder(member: GuildMember) {
    if (!window.confirm(`Передать руководство гильдией персонажу «${member.name}»? Ты станешь офицером.`)) return
    setBusy(true)
    const { error } = await supabase.rpc('transfer_guild_founder', {
      p_actor_character_id: characterId,
      p_target_character_id: member.character_id,
    })
    if (error) setMessage(guildError(error.message))
    else {
      await load(true)
      setMessage('Руководство передано.')
    }
    setBusy(false)
  }

  async function saveGuildProfile() {
    setBusy(true)
    setMessage('')
    const { error } = await supabase.rpc('update_guild_profile', {
      p_actor_character_id: characterId,
      p_name: name,
      p_tag: tag,
      p_description: description,
    })
    if (error) setMessage(guildError(error.message))
    else {
      await load(true)
      setMessage('Профиль гильдии обновлён.')
    }
    setBusy(false)
  }

  async function leaveGuild() {
    if (!window.confirm('Покинуть гильдию?')) return
    setBusy(true)
    const { error } = await supabase.rpc('leave_guild', {
      p_character_id: characterId,
    })
    if (error) setMessage(guildError(error.message))
    else {
      await load(true)
      setMessage('Ты покинул гильдию.')
    }
    setBusy(false)
  }

  async function disbandGuild() {
    if (!window.confirm('Распустить гильдию полностью? Это удалит состав и все текущие заявки.')) return
    setBusy(true)
    const { error } = await supabase.rpc('disband_guild', {
      p_actor_character_id: characterId,
    })
    if (error) setMessage(guildError(error.message))
    else {
      await load(true)
      setMessage('Гильдия распущена.')
    }
    setBusy(false)
  }

  if (loading && !hub) {
    return (
      <section className={embedded ? 'panel guild-loading-panel embedded' : 'panel guild-loading-panel'}>
        <span className="eyebrow">ГИЛЬДИИ</span>
        <h2>Загружаем гильдии…</h2>
      </section>
    )
  }

  return (
    <section className={'guild-section' + (embedded ? ' embedded' : '')}>
      {!embedded && (
        <article className="panel guild-header-panel">
          <div>
            <span className="eyebrow">ГИЛЬДИИ VEIRA</span>
            <h2>{guild ? `[${guild.tag}] ${guild.name}` : 'Фракции игроков'}</h2>
            <p className="muted">
              Гильдия объединяет персонажей в постоянную организацию. Один персонаж может состоять только в одной гильдии.
            </p>
          </div>
          {onBack && <button className="ghost-button" type="button" onClick={onBack}>Назад</button>}
        </article>
      )}

      {message && <p className="gm-notice" aria-live="polite">{message}</p>}

      {guild ? (
        <>
          <article className="panel guild-profile-card">
            <div className="guild-profile-heading">
              <div>
                <span className="eyebrow">[{guild.tag}] · {roleLabels[guild.role]}</span>
                <h3>{guild.name}</h3>
                <p>{guild.description || 'У гильдии пока нет описания.'}</p>
              </div>
              <span className="badge">{guild.member_count}/{guild.member_limit}</span>
            </div>

            {ownRole === 'founder' && (
              <div className="guild-edit-grid">
                <label>
                  <span>Название</span>
                  <input maxLength={40} value={name} onChange={(event) => setName(event.target.value)} />
                </label>
                <label>
                  <span>Тег</span>
                  <input maxLength={6} value={tag} onChange={(event) => setTag(event.target.value.toUpperCase())} />
                </label>
                <label className="guild-description-field">
                  <span>Описание</span>
                  <textarea maxLength={600} value={description} onChange={(event) => setDescription(event.target.value)} />
                </label>
                <button className="primary-button" type="button" disabled={busy} onClick={() => void saveGuildProfile()}>
                  Сохранить профиль
                </button>
              </div>
            )}
          </article>

          {(ownRole === 'founder' || ownRole === 'officer') && (
            <article className="panel">
              <div className="section-heading">
                <div>
                  <span className="eyebrow">ЗАЯВКИ</span>
                  <h3>Ждут решения</h3>
                </div>
                <span className="badge">{hub?.applications.length ?? 0}</span>
              </div>

              {(hub?.applications.length ?? 0) === 0 ? (
                <p className="muted">Новых заявок нет.</p>
              ) : (
                <div className="guild-application-list">
                  {hub?.applications.map((application) => (
                    <div className="guild-application-card" key={application.id}>
                      <div>
                        <strong>{application.name}</strong>
                        <span>{application.race} · ур. {application.level}</span>
                        {application.message && <p>{application.message}</p>}
                      </div>
                      <div>
                        <button className="primary-button" type="button" disabled={busy} onClick={() => void resolveApplication(application.id, true)}>Принять</button>
                        <button className="ghost-button" type="button" disabled={busy} onClick={() => void resolveApplication(application.id, false)}>Отклонить</button>
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </article>
          )}

          <article className="panel">
            <div className="section-heading">
              <div>
                <span className="eyebrow">СОСТАВ</span>
                <h3>Участники</h3>
              </div>
              <span className="badge">{hub?.members.length ?? 0}</span>
            </div>

            <div className="guild-member-list">
              {hub?.members.map((member) => {
                const isSelf = member.character_id === characterId
                const canManage = !isSelf && (
                  ownRole === 'founder'
                  || (ownRole === 'officer' && member.role === 'member')
                )

                return (
                  <div className="guild-member-card" key={member.character_id}>
                    <div>
                      <strong>{member.name}</strong>
                      <span>{member.race} · ур. {member.level} · {roleLabels[member.role]}</span>
                    </div>

                    {canManage && (
                      <div className="guild-member-actions">
                        {ownRole === 'founder' && member.role !== 'founder' && (
                          <>
                            <button
                              className="ghost-button"
                              type="button"
                              disabled={busy}
                              onClick={() => void setRole(member, member.role === 'officer' ? 'member' : 'officer')}
                            >
                              {member.role === 'officer' ? 'Сделать участником' : 'Сделать офицером'}
                            </button>
                            <button className="ghost-button" type="button" disabled={busy} onClick={() => void transferFounder(member)}>
                              Передать лидерство
                            </button>
                          </>
                        )}
                        <button className="ghost-button danger-button" type="button" disabled={busy} onClick={() => void removeMember(member)}>
                          Исключить
                        </button>
                      </div>
                    )}
                  </div>
                )
              })}
            </div>

            <div className="guild-exit-actions">
              {ownRole === 'founder' ? (
                <button className="ghost-button danger-button" type="button" disabled={busy} onClick={() => void disbandGuild()}>
                  Распустить гильдию
                </button>
              ) : (
                <button className="ghost-button danger-button" type="button" disabled={busy} onClick={() => void leaveGuild()}>
                  Покинуть гильдию
                </button>
              )}
            </div>
          </article>
        </>
      ) : (
        <>
          <article className="panel guild-create-card">
            <div className="section-heading">
              <div>
                <span className="eyebrow">СОЗДАТЬ</span>
                <h3>Новая гильдия</h3>
              </div>
            </div>

            <div className="guild-edit-grid">
              <label>
                <span>Название · 3–40 символов</span>
                <input maxLength={40} value={name} onChange={(event) => setName(event.target.value)} placeholder="Например, Серебряный Рассвет" />
              </label>
              <label>
                <span>Тег · 2–6 символов</span>
                <input maxLength={6} value={tag} onChange={(event) => setTag(event.target.value.toUpperCase())} placeholder="SR" />
              </label>
              <label className="guild-description-field">
                <span>Описание</span>
                <textarea maxLength={600} value={description} onChange={(event) => setDescription(event.target.value)} placeholder="Кто вы и чем занимаетесь?" />
              </label>
              <button className="primary-button" type="button" disabled={busy || name.trim().length < 3 || tag.trim().length < 2} onClick={() => void createGuild()}>
                Создать гильдию
              </button>
            </div>
          </article>

          {(hub?.own_applications.length ?? 0) > 0 && (
            <article className="panel">
              <div className="section-heading">
                <div>
                  <span className="eyebrow">МОИ ЗАЯВКИ</span>
                  <h3>Ожидают ответа</h3>
                </div>
              </div>
              <div className="guild-application-list">
                {hub?.own_applications.map((application) => (
                  <div className="guild-application-card" key={application.id}>
                    <div>
                      <strong>[{application.guild_tag}] {application.guild_name}</strong>
                      {application.message && <p>{application.message}</p>}
                    </div>
                    <button className="ghost-button" type="button" disabled={busy} onClick={() => void cancelApplication(application.id)}>
                      Отменить заявку
                    </button>
                  </div>
                ))}
              </div>
            </article>
          )}

          <article className="panel">
            <div className="section-heading">
              <div>
                <span className="eyebrow">КАТАЛОГ</span>
                <h3>Гильдии мира</h3>
              </div>
              <span className="badge">{hub?.directory.length ?? 0}</span>
            </div>

            {(hub?.directory.length ?? 0) === 0 ? (
              <p className="muted">Пока не создано ни одной гильдии.</p>
            ) : (
              <div className="guild-directory-grid">
                {hub?.directory.map((entry) => (
                  <div className="guild-directory-card" key={entry.id}>
                    <div>
                      <span className="eyebrow">[{entry.tag}]</span>
                      <strong>{entry.name}</strong>
                      <p>{entry.description || 'Без описания.'}</p>
                      <small>Основатель: {entry.founder_name} · {entry.member_count}/{entry.member_limit}</small>
                    </div>

                    {pendingGuildIds.has(entry.id) ? (
                      <span className="badge ready">заявка отправлена</span>
                    ) : applyGuildId === entry.id ? (
                      <div className="guild-apply-form">
                        <textarea
                          maxLength={400}
                          value={applicationMessage}
                          onChange={(event) => setApplicationMessage(event.target.value)}
                          placeholder="Сообщение гильдии · необязательно"
                        />
                        <div>
                          <button className="primary-button" type="button" disabled={busy} onClick={() => void apply(entry.id)}>Отправить</button>
                          <button className="ghost-button" type="button" disabled={busy} onClick={() => { setApplyGuildId(null); setApplicationMessage('') }}>Отмена</button>
                        </div>
                      </div>
                    ) : (
                      <button className="primary-button" type="button" disabled={busy} onClick={() => setApplyGuildId(entry.id)}>
                        Подать заявку
                      </button>
                    )}
                  </div>
                ))}
              </div>
            )}
          </article>
        </>
      )}
    </section>
  )
}
