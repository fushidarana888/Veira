import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import { GmItemsAndSpells } from './GmItemsAndSpells'
import { GmRaceEditor } from './GmRaceEditor'
import { GmWorldEditor } from './GmWorldEditor'
import type { Character, CharacterProgress, ItemDefinition, Profile } from '../types'

type Props = {
  profile: Profile
  onSignOut: () => Promise<void> | void
}

type GmTab = 'players' | 'world' | 'races' | 'content' | 'audit'

type AuditEntry = {
  id: number
  actor_user_id: string
  action: string
  target_type: string | null
  target_id: string | null
  details: Record<string, unknown>
  created_at: string
}

function normalizeProgress(value: Character['character_progress']): CharacterProgress | null {
  if (Array.isArray(value)) return value[0] ?? null
  return value
}

export function GmHome({ profile, onSignOut }: Props) {
  const [tab, setTab] = useState<GmTab>('players')
  const [characters, setCharacters] = useState<Character[]>([])
  const [profiles, setProfiles] = useState<Profile[]>([])
  const [definitions, setDefinitions] = useState<ItemDefinition[]>([])
  const [audit, setAudit] = useState<AuditEntry[]>([])
  const [selectedId, setSelectedId] = useState<string>('')
  const [selectedItemId, setSelectedItemId] = useState<string>('')
  const [quantity, setQuantity] = useState(1)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState('')
  const [mapFile, setMapFile] = useState<File | null>(null)
  const [mapUploading, setMapUploading] = useState(false)
  const [mapPreviewVersion, setMapPreviewVersion] = useState(() => Date.now())

  async function loadData() {
    setLoading(true)

    const [charactersResult, profilesResult, definitionsResult, auditResult] = await Promise.all([
      supabase
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
        .order('created_at', { ascending: true }),
      supabase
        .from('profiles')
        .select('user_id, display_name, avatar_url, account_type')
        .order('created_at', { ascending: true }),
      supabase
        .from('item_definitions')
        .select('id, slug, name, description, category, rarity, equip_group, stackable, max_stack, icon_url, stat_modifiers, effects, base_value, required_level, shop_tier, shop_price, shop_enabled, damage_type, damage_resistances, scroll_spell_id, scroll_mode, unique_property_name, unique_property_description, unique_effect_type, unique_effect_value')
        .order('name', { ascending: true }),
      supabase
        .from('gm_audit_log')
        .select('id, actor_user_id, action, target_type, target_id, details, created_at')
        .order('created_at', { ascending: false })
        .limit(100),
    ])

    const error =
      charactersResult.error ??
      profilesResult.error ??
      definitionsResult.error ??
      auditResult.error

    if (error) {
      setNotice(error.message)
      setLoading(false)
      return
    }

    const nextCharacters = (charactersResult.data as Character[] | null) ?? []
    setCharacters(nextCharacters)
    setProfiles((profilesResult.data as Profile[] | null) ?? [])
    setDefinitions((definitionsResult.data as ItemDefinition[] | null) ?? [])
    setAudit((auditResult.data as AuditEntry[] | null) ?? [])

    if (!nextCharacters.some((character) => character.id === selectedId)) {
      setSelectedId(nextCharacters[0]?.id ?? '')
    }

    if (!selectedItemId && definitionsResult.data?.[0]) {
      setSelectedItemId(definitionsResult.data[0].id)
    }

    setLoading(false)
  }

  useEffect(() => {
    void loadData()
  }, [])

  const profileById = useMemo(
    () => new Map(profiles.map((entry) => [entry.user_id, entry])),
    [profiles],
  )

  const selectedCharacter = characters.find((entry) => entry.id === selectedId) ?? null
  const selectedProgress = selectedCharacter
    ? normalizeProgress(selectedCharacter.character_progress)
    : null

  async function mutateProgress(patch: Partial<CharacterProgress>, successMessage: string) {
    if (!selectedCharacter) return

    setBusy(true)
    setNotice('')

    const { error } = await supabase
      .from('character_progress')
      .update(patch)
      .eq('character_id', selectedCharacter.id)

    if (error) {
      setNotice(error.message)
      setBusy(false)
      return
    }

    setNotice(successMessage)
    await loadData()
    setBusy(false)
  }

  async function giveItem() {
    if (!selectedCharacter || !selectedItemId) return

    const definition = definitions.find((entry) => entry.id === selectedItemId)
    if (!definition) return

    const safeQuantity = Math.max(1, Math.min(Math.floor(quantity || 1), definition.stackable ? definition.max_stack : 20))
    const rows = definition.stackable
      ? [{
          character_id: selectedCharacter.id,
          item_definition_id: definition.id,
          quantity: safeQuantity,
        }]
      : Array.from({ length: safeQuantity }, () => ({
          character_id: selectedCharacter.id,
          item_definition_id: definition.id,
          quantity: 1,
        }))

    setBusy(true)
    setNotice('')

    const { error } = await supabase.from('character_items').insert(rows)

    if (error) {
      setNotice(error.message)
      setBusy(false)
      return
    }

    setNotice(`Выдано: ${definition.name} ×${safeQuantity}`)
    await loadData()
    setBusy(false)
  }

  async function uploadWorldMap() {
    if (!mapFile) {
      setNotice('Выбери PNG-карту перед загрузкой.')
      return
    }

    if (mapFile.type !== 'image/png') {
      setNotice('Для основной карты сейчас принимается PNG без дополнительного сжатия.')
      return
    }

    if (mapFile.size > 10 * 1024 * 1024) {
      setNotice('Файл карты больше 10 МБ.')
      return
    }

    setMapUploading(true)
    setNotice('')

    const { error } = await supabase.storage
      .from('veira-assets')
      .upload('eilar-map-original.png', mapFile, {
        upsert: true,
        contentType: 'image/png',
        cacheControl: '0',
      })

    if (error) {
      setNotice(error.message)
      setMapUploading(false)
      return
    }

    setMapPreviewVersion(Date.now())
    setNotice('Карта загружена без уменьшения разрешения и повторного сжатия.')
    setMapUploading(false)
  }

  async function resetCharacterToCreation() {
    if (!selectedCharacter) return

    const owner = profileById.get(selectedCharacter.owner_user_id)
    const confirmed = window.confirm(
      `Вернуть аккаунт @${owner?.display_name ?? 'unknown'} к созданию персонажа?\n\n` +
      `Персонаж «${selectedCharacter.name}», его прогресс, экипировка и инвентарь будут удалены. ` +
      'Сам аккаунт останется, и при следующем входе игрок снова увидит форму имени, расы и биографии.',
    )

    if (!confirmed) return

    setBusy(true)
    setNotice('')

    const { error } = await supabase.rpc('gm_reset_character_to_creation', {
      p_character_id: selectedCharacter.id,
    })

    if (error) {
      setNotice(error.message)
      setBusy(false)
      return
    }

    setSelectedId('')
    setNotice(
      `Аккаунт @${owner?.display_name ?? 'unknown'} возвращён к созданию персонажа. ` +
      'Игроку достаточно обновить страницу или войти заново.',
    )
    await loadData()
    setBusy(false)
  }

  return (
    <main className="shell gm-shell">
      <header className="topbar">
        <div>
          <span className="eyebrow">VEIRA GAME MASTER</span>
          <h1>Панель мира</h1>
          <p className="muted">{profile.display_name}</p>
        </div>
        <div className="top-actions">
          <span className="badge gm-badge">GM</span>
          <button className="ghost-button" type="button" onClick={() => void loadData()}>
            Обновить
          </button>
          <button className="ghost-button" type="button" onClick={() => void onSignOut()}>
            Выйти
          </button>
        </div>
      </header>

      <div className="subnav gm-subnav">
        <button className={tab === 'players' ? 'active' : ''} type="button" onClick={() => setTab('players')}>
          Игроки
        </button>
        <button className={tab === 'world' ? 'active' : ''} type="button" onClick={() => setTab('world')}>
          Карта мира
        </button>
        <button className={tab === 'races' ? 'active' : ''} type="button" onClick={() => setTab('races')}>
          Расы
        </button>
        <button className={tab === 'content' ? 'active' : ''} type="button" onClick={() => setTab('content')}>
          Предметы и магия
        </button>
        <button className={tab === 'audit' ? 'active' : ''} type="button" onClick={() => setTab('audit')}>
          Журнал GM
        </button>
      </div>

      {notice && <p className="gm-notice" aria-live="polite">{notice}</p>}

      {loading ? (
        <section className="panel"><p className="muted">Загружаем данные мира…</p></section>
      ) : tab === 'players' ? (
        <div className="gm-console">
          <aside className="panel gm-player-list">
            <span className="eyebrow">ПЕРСОНАЖИ</span>
            <h2>{characters.length} в мире</h2>

            <div className="gm-player-buttons">
              {characters.length === 0 && <p className="muted">Игровых персонажей пока нет.</p>}
              {characters.map((character) => {
                const owner = profileById.get(character.owner_user_id)
                const progress = normalizeProgress(character.character_progress)

                return (
                  <button
                    key={character.id}
                    type="button"
                    className={selectedId === character.id ? 'active' : ''}
                    onClick={() => setSelectedId(character.id)}
                  >
                    <strong>{character.name}</strong>
                    <span>{character.race} · LVL {progress?.level ?? '?'}</span>
                    <small>@{owner?.display_name ?? 'unknown'}</small>
                  </button>
                )
              })}
            </div>
          </aside>

          <section className="gm-detail">
            {!selectedCharacter || !selectedProgress ? (
              <article className="panel">
                <p className="muted">Выбери персонажа слева.</p>
              </article>
            ) : (
              <>
                <article className="panel gm-character-card">
                  <div>
                    <span className="eyebrow">ВЫБРАННЫЙ ПЕРСОНАЖ</span>
                    <h2>{selectedCharacter.name}</h2>
                    <p className="muted">
                      {selectedCharacter.race} · @{profileById.get(selectedCharacter.owner_user_id)?.display_name ?? 'unknown'}
                    </p>
                  </div>

                  <div className="gm-stat-strip">
                    <span><small>LVL</small><strong>{selectedProgress.level}</strong></span>
                    <span><small>EXP</small><strong>{selectedProgress.experience}</strong></span>
                    <span><small>HP</small><strong>{selectedProgress.hp_current}/{selectedProgress.hp_max}</strong></span>
                    <span><small>MP</small><strong>{selectedProgress.mana_current}/{selectedProgress.mana_max}</strong></span>
                    <span><small>Золото</small><strong>{selectedProgress.gold}</strong></span>
                  </div>
                </article>

                <article className="panel">
                  <span className="eyebrow">БЫСТРЫЕ ДЕЙСТВИЯ</span>
                  <h2>Тестовый контроль</h2>

                  <div className="gm-action-grid">
                    <button
                      className="primary-button"
                      type="button"
                      disabled={busy}
                      onClick={() => void mutateProgress(
                        { experience: selectedProgress.experience + 100 },
                        'Добавлено 100 EXP.',
                      )}
                    >
                      +100 EXP
                    </button>
                    <button
                      className="primary-button"
                      type="button"
                      disabled={busy}
                      onClick={() => void mutateProgress(
                        { gold: selectedProgress.gold + 100 },
                        'Добавлено 100 золота.',
                      )}
                    >
                      +100 золота
                    </button>
                    <button
                      className="ghost-button"
                      type="button"
                      disabled={busy}
                      onClick={() => void mutateProgress(
                        { hp_current: selectedProgress.hp_max },
                        'Здоровье восстановлено.',
                      )}
                    >
                      Вылечить
                    </button>
                    <button
                      className="ghost-button"
                      type="button"
                      disabled={busy}
                      onClick={() => void mutateProgress(
                        { mana_current: selectedProgress.mana_max },
                        'Мана восстановлена.',
                      )}
                    >
                      Восстановить ману
                    </button>
                    <button
                      className="ghost-button"
                      type="button"
                      disabled={busy}
                      onClick={() => void mutateProgress(
                        { hp_current: Math.max(0, selectedProgress.hp_current - 25) },
                        'Нанесено 25 тестового урона.',
                      )}
                    >
                      -25 HP
                    </button>
                  </div>
                </article>

                <article className="panel">
                  <span className="eyebrow">ЛУТ</span>
                  <h2>Выдать предмет</h2>

                  <div className="gm-loot-row">
                    <select value={selectedItemId} onChange={(event) => setSelectedItemId(event.target.value)}>
                      {definitions.map((definition) => (
                        <option key={definition.id} value={definition.id}>
                          {definition.name} · {definition.rarity}
                        </option>
                      ))}
                    </select>
                    <input
                      type="number"
                      min={1}
                      max={20}
                      value={quantity}
                      onChange={(event) => setQuantity(Number(event.target.value))}
                      aria-label="Количество"
                    />
                    <button className="primary-button" type="button" disabled={busy} onClick={() => void giveItem()}>
                      Выдать
                    </button>
                  </div>
                </article>

                <article className="panel danger-panel">
                  <span className="eyebrow">ТЕСТИРОВАНИЕ</span>
                  <h2>Вернуть к созданию персонажа</h2>
                  <p className="muted">
                    Удаляет текущего персонажа вместе с прогрессом, инвентарём и экипировкой, но сохраняет сам аккаунт.
                    После обновления страницы игрок снова попадёт на выбор имени, расы и биографии.
                  </p>
                  <button
                    className="ghost-button danger-button"
                    type="button"
                    disabled={busy}
                    onClick={() => void resetCharacterToCreation()}
                  >
                    Сбросить до создания
                  </button>
                </article>
              </>
            )}
          </section>
        </div>
      ) : tab === 'world' ? (
        <div className="gm-world-tab">
          <section className="panel gm-map-upload-panel">
            <div className="section-heading">
              <div>
                <span className="eyebrow">ПОДЛОЖКА ЭЙЛАРА</span>
                <h2>Оригинальная карта мира</h2>
              </div>
              <span className="badge">PNG · до 10 МБ</span>
            </div>

            <p className="muted gm-map-upload-copy">
              Этот файл используется как визуальная подложка. Сектора, содержимое и события хранятся отдельно в базе.
            </p>

            <div className="gm-map-upload-controls">
              <label className="gm-map-file-picker">
                <span>{mapFile ? mapFile.name : 'Выбрать PNG-карту'}</span>
                <input
                  type="file"
                  accept="image/png"
                  onChange={(event) => setMapFile(event.target.files?.[0] ?? null)}
                />
              </label>

              <button
                className="primary-button"
                type="button"
                disabled={!mapFile || mapUploading}
                onClick={() => void uploadWorldMap()}
              >
                {mapUploading ? 'Загружаем…' : 'Опубликовать карту'}
              </button>
            </div>

            <div className="gm-map-preview compact">
              <img
                src={supabase.storage
                  .from('veira-assets')
                  .getPublicUrl('eilar-map-original.png').data.publicUrl + '?v=' + mapPreviewVersion}
                alt="Текущая карта Эйлара"
              />
            </div>
          </section>

          <GmWorldEditor characters={characters} profiles={profiles} />
        </div>
      ) : tab === 'races' ? (
        <GmRaceEditor />
      ) : tab === 'content' ? (
        <GmItemsAndSpells />
      ) : (
        <section className="panel">
          <div className="section-heading">
            <div>
              <span className="eyebrow">AUDIT LOG</span>
              <h2>Последние действия GM</h2>
            </div>
            <span className="badge">{audit.length}</span>
          </div>

          <div className="audit-list">
            {audit.length === 0 && <p className="muted">Журнал пока пуст.</p>}
            {audit.map((entry) => (
              <article key={entry.id} className="audit-row">
                <div>
                  <strong>{entry.action}</strong>
                  <span>{entry.target_type ?? 'system'} · {entry.target_id ?? '—'}</span>
                </div>
                <time>{new Date(entry.created_at).toLocaleString('ru-RU')}</time>
              </article>
            ))}
          </div>
        </section>
      )}
    </main>
  )
}
