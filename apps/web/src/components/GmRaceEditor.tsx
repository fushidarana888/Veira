import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import type {
  DamageType,
  ElementalDamageType,
  RaceDefinition,
  RacePassiveType,
} from '../types'

const damageTypes: DamageType[] = [
  'slashing', 'piercing', 'blunt',
  'fire', 'water', 'earth', 'air', 'lightning', 'ice',
]

const elementalTypes: ElementalDamageType[] = [
  'fire', 'water', 'earth', 'air', 'lightning', 'ice',
]

const damageLabels: Record<DamageType, string> = {
  slashing: 'Режущий',
  piercing: 'Колющий',
  blunt: 'Дробящий',
  fire: 'Огонь',
  water: 'Вода',
  earth: 'Земля',
  air: 'Воздух',
  lightning: 'Молния',
  ice: 'Лёд',
}

const passiveOptions: Array<{ value: RacePassiveType; label: string }> = [
  { value: 'all_damage_bonus', label: 'Бонус ко всему прямому урону' },
  { value: 'physical_damage_bonus', label: 'Бонус к физическому урону' },
  { value: 'magic_damage_bonus', label: 'Бонус к магическому урону' },
  { value: 'lifesteal', label: 'Вампиризм' },
  { value: 'mana_on_hit', label: 'Мана при попадании' },
  { value: 'damage_vs_wounded', label: 'Урон по раненой цели' },
  { value: 'guard_boost', label: 'Усиленная защита' },
  { value: 'low_hp_damage_reduction', label: 'Снижение урона при низком ОЗ' },
  { value: 'boss_damage_bonus', label: 'Урон по хранителям' },
]

type RaceDraft = Omit<RaceDefinition, 'id' | 'stat_modifiers' | 'traits' | 'is_available'> & {
  id: string | null
}

function emptyRace(): RaceDraft {
  return {
    id: null,
    slug: '',
    name: '',
    category: 'Народы',
    description: '',
    sort_order: 1000,
    playable: true,
    innate_magic_damage_type: 'fire',
    access_mode: 'open',
    hp_bonus: 0,
    mana_bonus: 0,
    hp_regen_per_hour: 8,
    mana_regen_per_hour: 10,
    damage_resistances: {},
    passive_type: null,
    passive_value: 0,
    passive_name: '',
    passive_description: '',
  }
}

export function GmRaceEditor() {
  const [races, setRaces] = useState<RaceDefinition[]>([])
  const [draft, setDraft] = useState<RaceDraft>(emptyRace)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  async function loadData() {
    const { data, error } = await supabase.rpc('get_gm_race_definitions')

    if (error) {
      setMessage(error.message)
      return
    }

    setRaces((data as RaceDefinition[] | null) ?? [])
  }

  useEffect(() => {
    void loadData()
  }, [])

  const groupedRaces = useMemo(() => {
    const map = new Map<string, RaceDefinition[]>()
    for (const race of races) {
      const list = map.get(race.category) ?? []
      list.push(race)
      map.set(race.category, list)
    }
    return Array.from(map.entries())
  }, [races])

  function editRace(race: RaceDefinition) {
    setDraft({
      id: race.id,
      slug: race.slug,
      name: race.name,
      category: race.category,
      description: race.description,
      sort_order: race.sort_order,
      playable: race.playable,
      innate_magic_damage_type: race.innate_magic_damage_type,
      access_mode: 'open',
      hp_bonus: race.hp_bonus,
      mana_bonus: race.mana_bonus,
      hp_regen_per_hour: race.hp_regen_per_hour,
      mana_regen_per_hour: race.mana_regen_per_hour,
      damage_resistances: race.damage_resistances ?? {},
      passive_type: race.passive_type,
      passive_value: race.passive_value,
      passive_name: race.passive_name,
      passive_description: race.passive_description,
    })
    setMessage('')
  }

  function updateResistance(type: DamageType, raw: string) {
    const value = Math.max(-75, Math.min(75, Number(raw)))
    const next = { ...draft.damage_resistances }
    if (value === 0) delete next[type]
    else next[type] = value
    setDraft({ ...draft, damage_resistances: next })
  }

  async function saveRace() {
    setBusy(true)
    setMessage('')

    const { data, error } = await supabase.rpc('gm_save_race_definition', {
      p_id: draft.id,
      p_slug: draft.slug.trim(),
      p_name: draft.name.trim(),
      p_category: draft.category.trim(),
      p_description: draft.description,
      p_sort_order: draft.sort_order,
      p_playable: draft.playable,
      p_access_mode: 'open',
      p_innate_magic_damage_type: draft.innate_magic_damage_type,
      p_hp_bonus: draft.hp_bonus,
      p_mana_bonus: draft.mana_bonus,
      p_hp_regen_per_hour: draft.hp_regen_per_hour,
      p_mana_regen_per_hour: draft.mana_regen_per_hour,
      p_damage_resistances: draft.damage_resistances,
      p_passive_type: draft.passive_type,
      p_passive_value: draft.passive_value,
      p_passive_name: draft.passive_name,
      p_passive_description: draft.passive_description,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    await loadData()
    if (!draft.id && data) setDraft({ ...draft, id: String(data) })
    setMessage(draft.id ? 'Раса обновлена.' : 'Раса создана.')
    setBusy(false)
  }

  async function deleteRace() {
    if (!draft.id) return
    if (!window.confirm(`Удалить расу «${draft.name}»?`)) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('gm_delete_race_definition', {
      p_id: draft.id,
    })

    if (error) {
      setMessage(
        error.message.includes('RACE_IS_IN_USE')
          ? 'Эту расу нельзя удалить, пока её использует хотя бы один персонаж.'
          : error.message,
      )
      setBusy(false)
      return
    }

    setDraft(emptyRace())
    await loadData()
    setMessage('Раса удалена.')
    setBusy(false)
  }

  return (
    <section className="gm-race-editor">
      <article className="panel">
        <div className="section-heading">
          <div>
            <span className="eyebrow">РАСЫ ЭЙЛАРА</span>
            <h2>Редактор рас</h2>
            <p className="muted">
              Раса влияет на характеристики, HP, ману, восстановление, сопротивления, стихию и боевые особенности. Все игровые расы доступны всем игрокам.
            </p>
          </div>
          <span className="badge">{races.length}</span>
        </div>
        {message && <p className="gm-notice" aria-live="polite">{message}</p>}
      </article>

      <div className="gm-content-layout">
        <aside className="panel gm-content-list">
          <button className="primary-button" type="button" onClick={() => setDraft(emptyRace())}>
            + Новая раса
          </button>

          {groupedRaces.map(([category, list]) => (
            <div className="gm-content-list-group" key={category}>
              <strong>{category}</strong>
              {list.map((race) => (
                <button
                  type="button"
                  key={race.id}
                  className={draft.id === race.id ? 'active' : ''}
                  onClick={() => editRace(race)}
                >
                  <span>{race.name}</span>
                  <small>
                    {damageLabels[race.innate_magic_damage_type]}
                    {race.passive_name ? ' · ' + race.passive_name : ''}
                  </small>
                </button>
              ))}
            </div>
          ))}
        </aside>

        <article className="panel gm-content-form">
          <div className="section-heading">
            <div>
              <span className="eyebrow">РАСА</span>
              <h2>{draft.id ? draft.name || 'Редактирование' : 'Новая раса'}</h2>
            </div>
            <label className="gm-inline-check">
              <input
                type="checkbox"
                checked={draft.playable}
                onChange={(e) => setDraft({ ...draft, playable: e.target.checked })}
              />
              <span>Доступна в игре</span>
            </label>
          </div>

          <div className="gm-form-grid three">
            <label>
              <span>Название</span>
              <input value={draft.name} onChange={(e) => setDraft({ ...draft, name: e.target.value })} />
            </label>
            <label>
              <span>Slug</span>
              <input value={draft.slug} onChange={(e) => setDraft({ ...draft, slug: e.target.value })} />
            </label>
            <label>
              <span>Категория</span>
              <input value={draft.category} onChange={(e) => setDraft({ ...draft, category: e.target.value })} />
            </label>
          </div>

          <label>
            <span>Описание</span>
            <textarea rows={4} value={draft.description} onChange={(e) => setDraft({ ...draft, description: e.target.value })} />
          </label>

          <div className="gm-form-grid three">
            <label>
              <span>Врождённая стихия</span>
              <select
                value={draft.innate_magic_damage_type}
                onChange={(e) => setDraft({ ...draft, innate_magic_damage_type: e.target.value as ElementalDamageType })}
              >
                {elementalTypes.map((type) => <option key={type} value={type}>{damageLabels[type]}</option>)}
              </select>
            </label>
            <label>
              <span>Доступ при создании</span>
              <input value="Свободно для всех" disabled />
            </label>
            <label>
              <span>Порядок</span>
              <input
                type="number"
                value={draft.sort_order}
                onChange={(e) => setDraft({ ...draft, sort_order: Number(e.target.value) })}
              />
            </label>
          </div>

          <div className="gm-editor-box">
            <strong>Ресурсы и восстановление</strong>
            <div className="gm-form-grid four">
              <label>
                <span>Бонус ОЗ</span>
                <input type="number" min={-100} max={500} value={draft.hp_bonus} onChange={(e) => setDraft({ ...draft, hp_bonus: Number(e.target.value) })} />
              </label>
              <label>
                <span>Бонус ОМ</span>
                <input type="number" min={-100} max={500} value={draft.mana_bonus} onChange={(e) => setDraft({ ...draft, mana_bonus: Number(e.target.value) })} />
              </label>
              <label>
                <span>ОЗ в час</span>
                <input type="number" min={0} max={100} value={draft.hp_regen_per_hour} onChange={(e) => setDraft({ ...draft, hp_regen_per_hour: Number(e.target.value) })} />
              </label>
              <label>
                <span>ОМ в час</span>
                <input type="number" min={0} max={100} value={draft.mana_regen_per_hour} onChange={(e) => setDraft({ ...draft, mana_regen_per_hour: Number(e.target.value) })} />
              </label>
            </div>
          </div>

          <div className="gm-editor-box">
            <div>
              <strong>Сопротивления / уязвимости</strong>
              <small>От −75% до +75%</small>
            </div>
            <div className="gm-form-grid three">
              {damageTypes.map((type) => (
                <label key={type}>
                  <span>{damageLabels[type]}</span>
                  <input
                    type="number"
                    min={-75}
                    max={75}
                    value={draft.damage_resistances[type] ?? 0}
                    onChange={(e) => updateResistance(type, e.target.value)}
                  />
                </label>
              ))}
            </div>
          </div>

          <div className="gm-editor-box">
            <div>
              <strong>Расовая пассивка</strong>
              <small>Одна постоянная механика</small>
            </div>

            <div className="gm-form-grid two">
              <label>
                <span>Механика</span>
                <select
                  value={draft.passive_type ?? ''}
                  onChange={(e) => setDraft({
                    ...draft,
                    passive_type: e.target.value ? e.target.value as RacePassiveType : null,
                    passive_value: e.target.value ? draft.passive_value : 0,
                    passive_name: e.target.value ? draft.passive_name : '',
                    passive_description: e.target.value ? draft.passive_description : '',
                  })}
                >
                  <option value="">Нет</option>
                  {passiveOptions.map((option) => (
                    <option key={option.value} value={option.value}>{option.label}</option>
                  ))}
                </select>
              </label>

              <label>
                <span>Сила эффекта</span>
                <input
                  type="number"
                  min={0}
                  max={100}
                  disabled={!draft.passive_type}
                  value={draft.passive_value}
                  onChange={(e) => setDraft({ ...draft, passive_value: Math.max(0, Math.min(100, Number(e.target.value))) })}
                />
              </label>
            </div>

            <div className="gm-form-grid two">
              <label>
                <span>Название</span>
                <input
                  disabled={!draft.passive_type}
                  value={draft.passive_name}
                  onChange={(e) => setDraft({ ...draft, passive_name: e.target.value })}
                />
              </label>
              <label>
                <span>Описание игроку</span>
                <input
                  disabled={!draft.passive_type}
                  value={draft.passive_description}
                  onChange={(e) => setDraft({ ...draft, passive_description: e.target.value })}
                />
              </label>
            </div>
          </div>

          <div className="gm-form-actions">
            <button className="primary-button" type="button" disabled={busy} onClick={() => void saveRace()}>
              {busy ? 'Сохраняем…' : draft.id ? 'Сохранить расу' : 'Создать расу'}
            </button>
            {draft.id && (
              <button className="ghost-button danger-button" type="button" disabled={busy} onClick={() => void deleteRace()}>
                Удалить
              </button>
            )}
          </div>
        </article>
      </div>

    </section>
  )
}
