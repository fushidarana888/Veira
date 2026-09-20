import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { CombatStatusEffectType, DamageType, EnemyAbility, EnemyTemplate, SectorTerrain } from '../types'

const damageTypes: DamageType[] = [
  'slashing',
  'piercing',
  'blunt',
  'fire',
  'water',
  'earth',
  'air',
  'lightning',
  'ice',
]

const statusEffectOptions: Array<{ value: CombatStatusEffectType; label: string }> = [
  { value: 'burn', label: 'Горение' },
  { value: 'bleed', label: 'Кровотечение' },
  { value: 'poison', label: 'Яд' },
  { value: 'chill', label: 'Охлаждение' },
  { value: 'stun', label: 'Оглушение' },
  { value: 'weaken', label: 'Ослабление' },
  { value: 'vulnerable', label: 'Уязвимость' },
]

const damageLabels: Record<DamageType, string> = {
  slashing: 'Режущий',
  piercing: 'Колющий',
  blunt: 'Дробящий',
  fire: 'Огненный',
  water: 'Водный',
  earth: 'Земляной',
  air: 'Воздушный',
  lightning: 'Электрический',
  ice: 'Ледяной',
}

const terrains: Array<{ value: SectorTerrain; label: string }> = [
  { value: 'plains', label: 'Равнины' },
  { value: 'forest', label: 'Лес' },
  { value: 'swamp', label: 'Болото' },
  { value: 'desert', label: 'Пустыня' },
  { value: 'mountains', label: 'Горы' },
  { value: 'tundra', label: 'Тундра' },
  { value: 'coast', label: 'Побережье' },
  { value: 'sea', label: 'Море' },
  { value: 'riverlands', label: 'Речные земли' },
]

type Draft = {
  id: string | null
  slug: string
  name: string
  description: string
  enabled: boolean
  terrain_type: SectorTerrain | null
  min_danger: number
  max_danger: number
  is_boss: boolean
  weight: number
  attack_damage_type: DamageType
  damage_resistances: Partial<Record<DamageType, number>>
  hp_multiplier: number
  attack_multiplier: number
  defense_multiplier: number
  initiative_multiplier: number
  on_hit_effect_type: CombatStatusEffectType | null
  on_hit_effect_chance: number
  on_hit_effect_turns: number
  on_hit_effect_potency: number
  special_name: string
  special_kind: 'attack' | 'heal' | 'guard' | 'enrage' | 'cleanse'
  special_value: number
  special_damage_multiplier: number
  special_every_n: number
  special_damage_type: DamageType | null
  special_effect_type: CombatStatusEffectType | null
  special_effect_chance: number
  special_effect_turns: number
  special_effect_potency: number
  special_telegraph_text: string
  special_attack_text: string
  phase2_hp_percent: number
  phase2_name: string
  phase2_attack_bonus_percent: number
  phase2_defense_bonus_percent: number
  phase2_special_every_n: number
  abilities: EnemyAbility[]
}

function emptyDraft(): Draft {
  return {
    id: null,
    slug: '',
    name: '',
    description: '',
    enabled: true,
    terrain_type: null,
    min_danger: 0,
    max_danger: 10,
    is_boss: false,
    weight: 1,
    attack_damage_type: 'slashing',
    damage_resistances: {},
    hp_multiplier: 1,
    attack_multiplier: 1,
    defense_multiplier: 1,
    initiative_multiplier: 1,
    on_hit_effect_type: null,
    on_hit_effect_chance: 0,
    on_hit_effect_turns: 0,
    on_hit_effect_potency: 0,
    special_name: '',
    special_kind: 'attack',
    special_value: 0,
    special_damage_multiplier: 0,
    special_every_n: 0,
    special_damage_type: null,
    special_effect_type: null,
    special_effect_chance: 0,
    special_effect_turns: 0,
    special_effect_potency: 0,
    special_telegraph_text: '',
    special_attack_text: '',
    phase2_hp_percent: 0,
    phase2_name: '',
    phase2_attack_bonus_percent: 0,
    phase2_defense_bonus_percent: 0,
    phase2_special_every_n: 0,
    abilities: [],
  }
}

function createAbilityDraft(index: number): EnemyAbility {
  return {
    id: `ability_${Date.now()}_${index}`,
    enabled: true,
    name: 'Новая способность',
    kind: 'attack',
    priority: 50,
    cooldown: 2,
    max_uses: 0,
    phase: 0,
    min_enemy_hp_percent: 0,
    max_enemy_hp_percent: 100,
    min_player_hp_percent: 0,
    max_player_hp_percent: 100,
    min_debuffs: 0,
    value: 0,
    damage_multiplier: 1.5,
    damage_type: null,
    effect_type: null,
    effect_chance: 0,
    effect_turns: 0,
    effect_potency: 0,
    telegraph_text: '',
    attack_text: '',
  }
}

export function GmEnemyTemplates() {
  const [templates, setTemplates] = useState<EnemyTemplate[]>([])
  const [draft, setDraft] = useState<Draft>(emptyDraft)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  async function loadTemplates() {
    const { data, error } = await supabase.rpc('get_gm_enemy_templates')

    if (error) {
      setMessage(error.message)
      return
    }

    setTemplates((data as EnemyTemplate[] | null) ?? [])
  }

  useEffect(() => {
    void loadTemplates()
  }, [])

  function edit(template: EnemyTemplate) {
    setDraft({
      id: template.id,
      slug: template.slug,
      name: template.name,
      description: template.description,
      enabled: template.enabled,
      terrain_type: template.terrain_type,
      min_danger: template.min_danger,
      max_danger: template.max_danger,
      is_boss: template.is_boss,
      weight: template.weight,
      attack_damage_type: template.attack_damage_type,
      damage_resistances: template.damage_resistances ?? {},
      hp_multiplier: Number(template.hp_multiplier),
      attack_multiplier: Number(template.attack_multiplier),
      defense_multiplier: Number(template.defense_multiplier),
      initiative_multiplier: Number(template.initiative_multiplier),
      on_hit_effect_type: template.on_hit_effect_type,
      on_hit_effect_chance: template.on_hit_effect_chance,
      on_hit_effect_turns: template.on_hit_effect_turns,
      on_hit_effect_potency: template.on_hit_effect_potency,
      special_name: template.special_name ?? '',
      special_kind: template.special_kind ?? 'attack',
      special_value: template.special_value ?? 0,
      special_damage_multiplier: Number(template.special_damage_multiplier ?? 0),
      special_every_n: template.special_every_n ?? 0,
      special_damage_type: template.special_damage_type ?? null,
      special_effect_type: template.special_effect_type ?? null,
      special_effect_chance: template.special_effect_chance ?? 0,
      special_effect_turns: template.special_effect_turns ?? 0,
      special_effect_potency: template.special_effect_potency ?? 0,
      special_telegraph_text: template.special_telegraph_text ?? '',
      special_attack_text: template.special_attack_text ?? '',
      phase2_hp_percent: template.phase2_hp_percent ?? 0,
      phase2_name: template.phase2_name ?? '',
      phase2_attack_bonus_percent: template.phase2_attack_bonus_percent ?? 0,
      phase2_defense_bonus_percent: template.phase2_defense_bonus_percent ?? 0,
      phase2_special_every_n: template.phase2_special_every_n ?? 0,
      abilities: Array.isArray(template.abilities) ? template.abilities : [],
    })
    setMessage('')
  }

  async function save() {
    if (!draft.slug.trim() || !draft.name.trim()) {
      setMessage('Нужно задать slug и название врага.')
      return
    }

    setBusy(true)
    setMessage('')

    const { data, error } = await supabase.rpc('gm_save_enemy_template', {
      p_id: draft.id,
      p_slug: draft.slug.trim(),
      p_name: draft.name.trim(),
      p_description: draft.description,
      p_enabled: draft.enabled,
      p_terrain_type: draft.terrain_type,
      p_min_danger: draft.min_danger,
      p_max_danger: draft.max_danger,
      p_is_boss: draft.is_boss,
      p_weight: draft.weight,
      p_attack_damage_type: draft.attack_damage_type,
      p_damage_resistances: draft.damage_resistances,
      p_hp_multiplier: draft.hp_multiplier,
      p_attack_multiplier: draft.attack_multiplier,
      p_defense_multiplier: draft.defense_multiplier,
      p_initiative_multiplier: draft.initiative_multiplier,
      p_on_hit_effect_type: draft.on_hit_effect_type,
      p_on_hit_effect_chance: draft.on_hit_effect_chance,
      p_on_hit_effect_turns: draft.on_hit_effect_turns,
      p_on_hit_effect_potency: draft.on_hit_effect_potency,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    const savedId = data ? String(data) : draft.id

    if (!savedId) {
      setMessage('Шаблон сохранён, но не удалось получить его ID для настройки особой атаки.')
      setBusy(false)
      return
    }

    const { error: specialError } = await supabase.rpc('gm_set_enemy_special', {
      p_enemy_id: savedId,
      p_special_name: draft.special_name.trim(),
      p_kind: draft.special_kind,
      p_value: draft.special_value,
      p_damage_multiplier: draft.special_damage_multiplier,
      p_every_n: draft.special_every_n,
      p_damage_type: draft.special_damage_type,
      p_effect_type: draft.special_effect_type,
      p_effect_chance: draft.special_effect_chance,
      p_effect_turns: draft.special_effect_turns,
      p_effect_potency: draft.special_effect_potency,
      p_telegraph_text: draft.special_telegraph_text,
      p_attack_text: draft.special_attack_text,
    })

    if (specialError) {
      setMessage(specialError.message)
      setBusy(false)
      return
    }

    const { error: phaseError } = await supabase.rpc('gm_set_enemy_phase2', {
      p_enemy_id: savedId,
      p_hp_percent: draft.phase2_hp_percent,
      p_name: draft.phase2_name,
      p_attack_bonus_percent: draft.phase2_attack_bonus_percent,
      p_defense_bonus_percent: draft.phase2_defense_bonus_percent,
      p_special_every_n: draft.phase2_special_every_n,
    })

    if (phaseError) {
      setMessage(phaseError.message)
      setBusy(false)
      return
    }

    const { error: abilitiesError } = await supabase.rpc('gm_set_enemy_abilities', {
      p_enemy_id: savedId,
      p_abilities: draft.abilities,
    })

    if (abilitiesError) {
      setMessage(abilitiesError.message)
      setBusy(false)
      return
    }

    await loadTemplates()
    if (!draft.id) setDraft({ ...draft, id: savedId })
    setMessage(draft.id ? 'Шаблон врага обновлён.' : 'Шаблон врага создан.')
    setBusy(false)
  }

  async function remove() {
    if (!draft.id) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('gm_delete_enemy_template', {
      p_id: draft.id,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    setDraft(emptyDraft())
    await loadTemplates()
    setMessage('Шаблон врага удалён.')
    setBusy(false)
  }

  function addAbility() {
    if (draft.abilities.length >= 12) {
      setMessage('У одного врага может быть максимум 12 способностей.')
      return
    }
    setDraft({ ...draft, abilities: [...draft.abilities, createAbilityDraft(draft.abilities.length)] })
  }

  function updateAbility(index: number, patch: Partial<EnemyAbility>) {
    const abilities = draft.abilities.map((ability, abilityIndex) =>
      abilityIndex === index ? { ...ability, ...patch } : ability,
    )
    setDraft({ ...draft, abilities })
  }

  function removeAbility(index: number) {
    setDraft({ ...draft, abilities: draft.abilities.filter((_, abilityIndex) => abilityIndex !== index) })
  }

  function setResistance(type: DamageType, raw: string) {
    const value = Math.max(-75, Math.min(75, Number(raw) || 0))
    const next = { ...draft.damage_resistances }

    if (value === 0) {
      delete next[type]
    } else {
      next[type] = value
    }

    setDraft({ ...draft, damage_resistances: next })
  }

  return (
    <article className="panel gm-enemy-templates">
      <div className="section-heading">
        <div>
          <span className="eyebrow">ШАБЛОНЫ ВРАГОВ</span>
          <h2>Типы урона и сопротивления</h2>
          <p className="muted">
            Один и тот же шаблон всегда имеет один тип атаки и одинаковый набор сопротивлений/уязвимостей.
          </p>
        </div>
        <span className="badge">{templates.length}</span>
      </div>

      {message && <p className="gm-notice" aria-live="polite">{message}</p>}

      <div className="gm-enemy-layout">
        <div className="gm-enemy-list">
          <button className="ghost-button" type="button" onClick={() => setDraft(emptyDraft())}>
            + Новый шаблон
          </button>

          {templates.map((template) => (
            <button
              type="button"
              key={template.id}
              className={[
                'gm-enemy-card',
                draft.id === template.id ? 'active' : '',
                !template.enabled ? 'disabled' : '',
              ].filter(Boolean).join(' ')}
              onClick={() => edit(template)}
            >
              <div>
                <strong>{template.name}</strong>
                <span>{template.is_boss ? 'Босс' : 'Обычный'}</span>
              </div>
              <small>
                {damageLabels[template.attack_damage_type]} · {template.min_danger}–{template.max_danger}/10
              </small>
            </button>
          ))}
        </div>

        <div className="gm-enemy-editor">
          <div className="gm-sector-form-grid">
            <label>
              <span>Название</span>
              <input
                value={draft.name}
                onChange={(event) => setDraft({ ...draft, name: event.target.value })}
                placeholder="Каменный страж"
              />
            </label>
            <label>
              <span>Slug</span>
              <input
                value={draft.slug}
                onChange={(event) => setDraft({ ...draft, slug: event.target.value })}
                placeholder="stone_sentry"
              />
            </label>
          </div>

          <label>
            <span>Описание</span>
            <textarea
              rows={3}
              value={draft.description}
              onChange={(event) => setDraft({ ...draft, description: event.target.value })}
            />
          </label>

          <div className="gm-sector-form-grid">
            <label>
              <span>Местность</span>
              <select
                value={draft.terrain_type ?? ''}
                onChange={(event) => setDraft({
                  ...draft,
                  terrain_type: event.target.value
                    ? event.target.value as SectorTerrain
                    : null,
                })}
              >
                <option value="">Любая</option>
                {terrains.map((terrain) => (
                  <option key={terrain.value} value={terrain.value}>{terrain.label}</option>
                ))}
              </select>
            </label>

            <label>
              <span>Тип атаки</span>
              <select
                value={draft.attack_damage_type}
                onChange={(event) => setDraft({
                  ...draft,
                  attack_damage_type: event.target.value as DamageType,
                })}
              >
                {damageTypes.map((type) => (
                  <option key={type} value={type}>{damageLabels[type]}</option>
                ))}
              </select>
            </label>
          </div>

          <div className="gm-enemy-number-grid">
            <label>
              <span>Сложность от</span>
              <input
                type="number"
                min={0}
                max={10}
                value={draft.min_danger}
                onChange={(event) => setDraft({
                  ...draft,
                  min_danger: Math.max(0, Math.min(10, Number(event.target.value))),
                })}
              />
            </label>
            <label>
              <span>до</span>
              <input
                type="number"
                min={0}
                max={10}
                value={draft.max_danger}
                onChange={(event) => setDraft({
                  ...draft,
                  max_danger: Math.max(0, Math.min(10, Number(event.target.value))),
                })}
              />
            </label>
            <label>
              <span>Вес спавна</span>
              <input
                type="number"
                min={1}
                max={1000}
                value={draft.weight}
                onChange={(event) => setDraft({
                  ...draft,
                  weight: Math.max(1, Math.min(1000, Number(event.target.value))),
                })}
              />
            </label>
          </div>

          <div className="gm-enemy-toggle-row">
            <label className="gm-check-row">
              <input
                type="checkbox"
                checked={draft.enabled}
                onChange={(event) => setDraft({ ...draft, enabled: event.target.checked })}
              />
              <span>Включён</span>
            </label>
            <label className="gm-check-row">
              <input
                type="checkbox"
                checked={draft.is_boss}
                onChange={(event) => setDraft({ ...draft, is_boss: event.target.checked })}
              />
              <span>Шаблон босса</span>
            </label>
          </div>

          <div className="gm-enemy-multipliers">
            <label>
              <span>ОЗ ×</span>
              <input type="number" min={0.25} max={5} step={0.05} value={draft.hp_multiplier}
                onChange={(event) => setDraft({ ...draft, hp_multiplier: Number(event.target.value) })} />
            </label>
            <label>
              <span>Атака ×</span>
              <input type="number" min={0.25} max={5} step={0.05} value={draft.attack_multiplier}
                onChange={(event) => setDraft({ ...draft, attack_multiplier: Number(event.target.value) })} />
            </label>
            <label>
              <span>Защита ×</span>
              <input type="number" min={0.25} max={5} step={0.05} value={draft.defense_multiplier}
                onChange={(event) => setDraft({ ...draft, defense_multiplier: Number(event.target.value) })} />
            </label>
            <label>
              <span>Инициатива ×</span>
              <input type="number" min={0.25} max={5} step={0.05} value={draft.initiative_multiplier}
                onChange={(event) => setDraft({ ...draft, initiative_multiplier: Number(event.target.value) })} />
            </label>
          </div>

          <div className="gm-enemy-resistances">
            <div>
              <strong>Эффект при попадании</strong>
              <span>Необязательный статус, который враг может наложить своей обычной атакой.</span>
            </div>

            <div className="gm-enemy-resistance-grid">
              <label>
                <span>Эффект</span>
                <select
                  value={draft.on_hit_effect_type ?? ''}
                  onChange={(event) => setDraft({
                    ...draft,
                    on_hit_effect_type: event.target.value
                      ? event.target.value as CombatStatusEffectType
                      : null,
                    on_hit_effect_chance: event.target.value
                      ? Math.max(1, draft.on_hit_effect_chance || 25)
                      : 0,
                    on_hit_effect_turns: event.target.value
                      ? Math.max(1, draft.on_hit_effect_turns || 1)
                      : 0,
                    on_hit_effect_potency: event.target.value
                      ? draft.on_hit_effect_potency
                      : 0,
                  })}
                >
                  <option value="">Нет</option>
                  {statusEffectOptions.map((effect) => (
                    <option key={effect.value} value={effect.value}>{effect.label}</option>
                  ))}
                </select>
              </label>

              <label>
                <span>Шанс %</span>
                <input
                  type="number"
                  min={0}
                  max={100}
                  disabled={!draft.on_hit_effect_type}
                  value={draft.on_hit_effect_chance}
                  onChange={(event) => setDraft({
                    ...draft,
                    on_hit_effect_chance: Math.max(0, Math.min(100, Number(event.target.value))),
                  })}
                />
              </label>

              <label>
                <span>Ходов</span>
                <input
                  type="number"
                  min={0}
                  max={10}
                  disabled={!draft.on_hit_effect_type}
                  value={draft.on_hit_effect_turns}
                  onChange={(event) => setDraft({
                    ...draft,
                    on_hit_effect_turns: Math.max(0, Math.min(10, Number(event.target.value))),
                  })}
                />
              </label>

              <label>
                <span>Сила</span>
                <input
                  type="number"
                  min={0}
                  max={1000}
                  disabled={!draft.on_hit_effect_type}
                  value={draft.on_hit_effect_potency}
                  onChange={(event) => setDraft({
                    ...draft,
                    on_hit_effect_potency: Math.max(0, Number(event.target.value)),
                  })}
                />
              </label>
            </div>
          </div>

          <div className="gm-enemy-resistances enemy-ability-editor">
            <div className="section-heading">
              <div>
                <strong>Умный набор способностей</strong>
                <span>
                  Враг сам выбирает действие по приоритету и ситуации. Cooldown — сколько полных ходов
                  должно пройти до повторного выбора; лимит 0 означает без ограничений.
                </span>
              </div>
              <button className="ghost-button" type="button" onClick={addAbility}>
                + Способность
              </button>
            </div>

            {draft.abilities.length === 0 ? (
              <p className="muted">Нет умных способностей — враг использует только обычную атаку и старую механику ниже.</p>
            ) : draft.abilities.map((ability, index) => (
              <div className="gm-enemy-resistances" key={ability.id}>
                <div className="gm-enemy-toggle-row">
                  <label className="gm-check-row">
                    <input
                      type="checkbox"
                      checked={ability.enabled}
                      onChange={(event) => updateAbility(index, { enabled: event.target.checked })}
                    />
                    <span>Включена</span>
                  </label>
                  <button className="ghost-button" type="button" onClick={() => removeAbility(index)}>
                    Удалить
                  </button>
                </div>

                <div className="gm-sector-form-grid">
                  <label>
                    <span>Название</span>
                    <input
                      value={ability.name}
                      onChange={(event) => updateAbility(index, { name: event.target.value })}
                    />
                  </label>
                  <label>
                    <span>Тип</span>
                    <select
                      value={ability.kind}
                      onChange={(event) => {
                        const kind = event.target.value as EnemyAbility['kind']
                        updateAbility(index, {
                          kind,
                          value: kind === 'heal' ? Math.max(10, ability.value || 10)
                            : kind === 'guard' ? Math.max(30, ability.value || 30)
                            : kind === 'enrage' ? Math.max(15, ability.value || 15)
                            : 0,
                          damage_multiplier: kind === 'attack' ? Math.max(1, ability.damage_multiplier || 1.5) : 0,
                          damage_type: kind === 'attack' ? ability.damage_type : null,
                          effect_type: kind === 'attack' ? ability.effect_type : null,
                        })
                      }}
                    >
                      <option value="attack">Усиленная атака</option>
                      <option value="heal">Самолечение</option>
                      <option value="guard">Защитная стойка</option>
                      <option value="enrage">Усиление атаки</option>
                      <option value="cleanse">Очищение</option>
                    </select>
                  </label>
                </div>

                <div className="gm-enemy-number-grid">
                  <label>
                    <span>Приоритет</span>
                    <input type="number" min={0} max={100} value={ability.priority}
                      onChange={(event) => updateAbility(index, {
                        priority: Math.max(0, Math.min(100, Number(event.target.value))),
                      })} />
                  </label>
                  <label>
                    <span>Cooldown</span>
                    <input type="number" min={0} max={20} value={ability.cooldown}
                      onChange={(event) => updateAbility(index, {
                        cooldown: Math.max(0, Math.min(20, Number(event.target.value))),
                      })} />
                  </label>
                  <label>
                    <span>Лимит использований</span>
                    <input type="number" min={0} max={20} value={ability.max_uses}
                      onChange={(event) => updateAbility(index, {
                        max_uses: Math.max(0, Math.min(20, Number(event.target.value))),
                      })} />
                  </label>
                  <label>
                    <span>Фаза</span>
                    <select
                      value={ability.phase}
                      onChange={(event) => updateAbility(index, {
                        phase: Number(event.target.value) as 0 | 1 | 2,
                      })}
                    >
                      <option value={0}>Любая</option>
                      <option value={1}>Только 1</option>
                      <option value={2}>Только 2</option>
                    </select>
                  </label>
                </div>

                <div className="gm-enemy-number-grid">
                  <label>
                    <span>ОЗ врага от %</span>
                    <input type="number" min={0} max={100} value={ability.min_enemy_hp_percent}
                      onChange={(event) => updateAbility(index, {
                        min_enemy_hp_percent: Math.max(0, Math.min(100, Number(event.target.value))),
                      })} />
                  </label>
                  <label>
                    <span>ОЗ врага до %</span>
                    <input type="number" min={0} max={100} value={ability.max_enemy_hp_percent}
                      onChange={(event) => updateAbility(index, {
                        max_enemy_hp_percent: Math.max(0, Math.min(100, Number(event.target.value))),
                      })} />
                  </label>
                  <label>
                    <span>ОЗ игрока от %</span>
                    <input type="number" min={0} max={100} value={ability.min_player_hp_percent}
                      onChange={(event) => updateAbility(index, {
                        min_player_hp_percent: Math.max(0, Math.min(100, Number(event.target.value))),
                      })} />
                  </label>
                  <label>
                    <span>ОЗ игрока до %</span>
                    <input type="number" min={0} max={100} value={ability.max_player_hp_percent}
                      onChange={(event) => updateAbility(index, {
                        max_player_hp_percent: Math.max(0, Math.min(100, Number(event.target.value))),
                      })} />
                  </label>
                  <label>
                    <span>Мин. дебаффов на враге</span>
                    <input type="number" min={0} max={20} value={ability.min_debuffs}
                      onChange={(event) => updateAbility(index, {
                        min_debuffs: Math.max(0, Math.min(20, Number(event.target.value))),
                      })} />
                  </label>
                </div>

                <div className="gm-enemy-resistance-grid">
                  {ability.kind === 'attack' ? (
                    <>
                      <label>
                        <span>Урон ×</span>
                        <input type="number" min={0.1} max={5} step={0.05} value={ability.damage_multiplier}
                          onChange={(event) => updateAbility(index, {
                            damage_multiplier: Math.max(0.1, Math.min(5, Number(event.target.value))),
                          })} />
                      </label>
                      <label>
                        <span>Тип урона</span>
                        <select
                          value={ability.damage_type ?? ''}
                          onChange={(event) => updateAbility(index, {
                            damage_type: event.target.value ? event.target.value as DamageType : null,
                          })}
                        >
                          <option value="">Как обычная атака</option>
                          {damageTypes.map((type) => (
                            <option key={type} value={type}>{damageLabels[type]}</option>
                          ))}
                        </select>
                      </label>
                    </>
                  ) : ability.kind !== 'cleanse' ? (
                    <label>
                      <span>
                        {ability.kind === 'heal' ? 'Лечение · % макс. ОЗ'
                          : ability.kind === 'guard' ? 'Снижение урона %'
                            : 'Бонус атаки %'}
                      </span>
                      <input type="number" min={1} max={100} value={ability.value}
                        onChange={(event) => updateAbility(index, {
                          value: Math.max(1, Math.min(100, Number(event.target.value))),
                        })} />
                    </label>
                  ) : null}

                  {ability.kind === 'attack' && (
                    <label>
                      <span>Эффект</span>
                      <select
                        value={ability.effect_type ?? ''}
                        onChange={(event) => updateAbility(index, {
                          effect_type: event.target.value ? event.target.value as CombatStatusEffectType : null,
                          effect_chance: event.target.value ? Math.max(1, ability.effect_chance || 50) : 0,
                          effect_turns: event.target.value ? Math.max(1, ability.effect_turns || 1) : 0,
                          effect_potency: event.target.value ? ability.effect_potency : 0,
                        })}
                      >
                        <option value="">Нет</option>
                        {statusEffectOptions.map((effect) => (
                          <option key={effect.value} value={effect.value}>{effect.label}</option>
                        ))}
                      </select>
                    </label>
                  )}
                </div>

                {ability.kind === 'attack' && ability.effect_type && (
                  <div className="gm-enemy-number-grid">
                    <label>
                      <span>Шанс эффекта %</span>
                      <input type="number" min={0} max={100} value={ability.effect_chance}
                        onChange={(event) => updateAbility(index, {
                          effect_chance: Math.max(0, Math.min(100, Number(event.target.value))),
                        })} />
                    </label>
                    <label>
                      <span>Ходов эффекта</span>
                      <input type="number" min={0} max={10} value={ability.effect_turns}
                        onChange={(event) => updateAbility(index, {
                          effect_turns: Math.max(0, Math.min(10, Number(event.target.value))),
                        })} />
                    </label>
                    <label>
                      <span>Сила эффекта</span>
                      <input type="number" min={0} max={1000} value={ability.effect_potency}
                        onChange={(event) => updateAbility(index, {
                          effect_potency: Math.max(0, Number(event.target.value)),
                        })} />
                    </label>
                  </div>
                )}

                <div className="gm-sector-form-grid">
                  <label>
                    <span>Текст подготовки</span>
                    <textarea rows={2} value={ability.telegraph_text}
                      onChange={(event) => updateAbility(index, { telegraph_text: event.target.value })} />
                  </label>
                  <label>
                    <span>Текст срабатывания</span>
                    <textarea rows={2} value={ability.attack_text}
                      onChange={(event) => updateAbility(index, { attack_text: event.target.value })} />
                  </label>
                </div>
              </div>
            ))}
          </div>

          <div className="gm-enemy-resistances enemy-special-editor">
            <div>
              <strong>Особая способность с подготовкой</strong>
              <span>
                Враг сначала тратит ход на явную подготовку. На следующем своём действии способность срабатывает,
                если её не сорвать оглушением. Автобой не знает её заранее.
              </span>
            </div>

            <div className="gm-enemy-resistance-grid">
              <label>
                <span>Тип способности</span>
                <select
                  disabled={draft.special_every_n === 0}
                  value={draft.special_kind}
                  onChange={(event) => {
                    const kind = event.target.value as Draft['special_kind']
                    setDraft({
                      ...draft,
                      special_kind: kind,
                      special_value: kind === 'heal' ? Math.max(10, draft.special_value || 10)
                        : kind === 'guard' ? Math.max(30, draft.special_value || 30)
                        : kind === 'enrage' ? Math.max(15, draft.special_value || 15)
                        : 0,
                      special_damage_multiplier: kind === 'attack'
                        ? Math.max(1, draft.special_damage_multiplier || 1.75)
                        : 0,
                      special_damage_type: kind === 'attack' ? draft.special_damage_type : null,
                      special_effect_type: kind === 'attack' ? draft.special_effect_type : null,
                      special_effect_chance: kind === 'attack' ? draft.special_effect_chance : 0,
                      special_effect_turns: kind === 'attack' ? draft.special_effect_turns : 0,
                      special_effect_potency: kind === 'attack' ? draft.special_effect_potency : 0,
                    })
                  }}
                >
                  <option value="attack">Усиленная атака</option>
                  <option value="heal">Самолечение</option>
                  <option value="guard">Защитная стойка</option>
                  <option value="enrage">Усиление атаки</option>
                  <option value="cleanse">Снятие эффектов</option>
                </select>
              </label>

              <label>
                <span>Название</span>
                <input
                  value={draft.special_name}
                  disabled={draft.special_every_n === 0}
                  onChange={(event) => setDraft({ ...draft, special_name: event.target.value })}
                  placeholder="Сокрушающий удар"
                />
              </label>

              <label>
                <span>Каждые N ходов</span>
                <input
                  type="number"
                  min={0}
                  max={20}
                  value={draft.special_every_n}
                  onChange={(event) => {
                    const value = Math.max(0, Math.min(20, Number(event.target.value)))
                    const interval = value === 1 ? 2 : value
                    setDraft({
                      ...draft,
                      special_every_n: interval,
                      special_damage_multiplier: interval > 0 && draft.special_kind === 'attack'
                        ? Math.max(1, draft.special_damage_multiplier || 1.75)
                        : interval > 0 ? 0 : 0,
                    })
                  }}
                />
              </label>

              {draft.special_kind === 'attack' ? (
                <label>
                  <span>Урон ×</span>
                  <input
                    type="number"
                    min={0}
                    max={5}
                    step={0.05}
                    disabled={draft.special_every_n === 0}
                    value={draft.special_damage_multiplier}
                    onChange={(event) => setDraft({
                      ...draft,
                      special_damage_multiplier: Math.max(0, Math.min(5, Number(event.target.value))),
                    })}
                  />
                </label>
              ) : draft.special_kind !== 'cleanse' ? (
                <label>
                  <span>
                    {draft.special_kind === 'heal'
                      ? 'Лечение · % макс. ОЗ'
                      : draft.special_kind === 'guard'
                        ? 'Снижение следующего урона %'
                        : 'Бонус атаки %'}
                  </span>
                  <input
                    type="number"
                    min={1}
                    max={100}
                    disabled={draft.special_every_n === 0}
                    value={draft.special_value}
                    onChange={(event) => setDraft({
                      ...draft,
                      special_value: Math.max(1, Math.min(100, Number(event.target.value))),
                    })}
                  />
                </label>
              ) : (
                <div />
              )}
            </div>

            {draft.special_kind === 'attack' && (
              <div className="gm-enemy-resistance-grid">
                <label>
                  <span>Тип урона</span>
                  <select
                    disabled={draft.special_every_n === 0}
                    value={draft.special_damage_type ?? ''}
                    onChange={(event) => setDraft({
                      ...draft,
                      special_damage_type: event.target.value ? event.target.value as DamageType : null,
                    })}
                  >
                    <option value="">Как обычная атака</option>
                    {damageTypes.map((type) => (
                      <option key={type} value={type}>{damageLabels[type]}</option>
                    ))}
                  </select>
                </label>

                <label>
                  <span>Эффект</span>
                  <select
                    disabled={draft.special_every_n === 0}
                    value={draft.special_effect_type ?? ''}
                    onChange={(event) => setDraft({
                      ...draft,
                      special_effect_type: event.target.value
                        ? event.target.value as CombatStatusEffectType
                        : null,
                      special_effect_chance: event.target.value
                        ? Math.max(1, draft.special_effect_chance || 50)
                        : 0,
                      special_effect_turns: event.target.value
                        ? Math.max(1, draft.special_effect_turns || 1)
                        : 0,
                      special_effect_potency: event.target.value ? draft.special_effect_potency : 0,
                    })}
                  >
                    <option value="">Нет</option>
                    {statusEffectOptions.map((effect) => (
                      <option key={effect.value} value={effect.value}>{effect.label}</option>
                    ))}
                  </select>
                </label>

                <label>
                  <span>Шанс %</span>
                  <input
                    type="number"
                    min={0}
                    max={100}
                    disabled={draft.special_every_n === 0 || !draft.special_effect_type}
                    value={draft.special_effect_chance}
                    onChange={(event) => setDraft({
                      ...draft,
                      special_effect_chance: Math.max(0, Math.min(100, Number(event.target.value))),
                    })}
                  />
                </label>

                <label>
                  <span>Ходов / сила</span>
                  <div className="gm-inline-fields">
                    <input
                      type="number"
                      min={0}
                      max={10}
                      disabled={draft.special_every_n === 0 || !draft.special_effect_type}
                      value={draft.special_effect_turns}
                      onChange={(event) => setDraft({
                        ...draft,
                        special_effect_turns: Math.max(0, Math.min(10, Number(event.target.value))),
                      })}
                    />
                    <input
                      type="number"
                      min={0}
                      max={1000}
                      disabled={draft.special_every_n === 0 || !draft.special_effect_type}
                      value={draft.special_effect_potency}
                      onChange={(event) => setDraft({
                        ...draft,
                        special_effect_potency: Math.max(0, Number(event.target.value)),
                      })}
                    />
                  </div>
                </label>
              </div>
            )}

            <div className="gm-sector-form-grid">
              <label>
                <span>Текст подготовки</span>
                <textarea
                  rows={2}
                  disabled={draft.special_every_n === 0}
                  value={draft.special_telegraph_text}
                  onChange={(event) => setDraft({ ...draft, special_telegraph_text: event.target.value })}
                />
              </label>
              <label>
                <span>Текст срабатывания</span>
                <textarea
                  rows={2}
                  disabled={draft.special_every_n === 0}
                  value={draft.special_attack_text}
                  onChange={(event) => setDraft({ ...draft, special_attack_text: event.target.value })}
                />
              </label>
            </div>
          </div>

          <div className="gm-enemy-resistances enemy-phase-editor">
            <div>
              <strong>Вторая фаза</strong>
              <span>
                Срабатывает один раз при указанном проценте HP. Можно усилить атаку/защиту и ускорить особую способность.
              </span>
            </div>

            <div className="gm-enemy-resistance-grid">
              <label>
                <span>Порог ОЗ %</span>
                <input
                  type="number"
                  min={0}
                  max={90}
                  value={draft.phase2_hp_percent}
                  onChange={(event) => setDraft({
                    ...draft,
                    phase2_hp_percent: Math.max(0, Math.min(90, Number(event.target.value))),
                  })}
                />
              </label>

              <label>
                <span>Название фазы</span>
                <input
                  disabled={draft.phase2_hp_percent === 0}
                  value={draft.phase2_name}
                  onChange={(event) => setDraft({ ...draft, phase2_name: event.target.value })}
                  placeholder="Последняя стойка"
                />
              </label>

              <label>
                <span>Атака +%</span>
                <input
                  type="number"
                  min={0}
                  max={100}
                  disabled={draft.phase2_hp_percent === 0}
                  value={draft.phase2_attack_bonus_percent}
                  onChange={(event) => setDraft({
                    ...draft,
                    phase2_attack_bonus_percent: Math.max(0, Math.min(100, Number(event.target.value))),
                  })}
                />
              </label>

              <label>
                <span>Защита +%</span>
                <input
                  type="number"
                  min={0}
                  max={100}
                  disabled={draft.phase2_hp_percent === 0}
                  value={draft.phase2_defense_bonus_percent}
                  onChange={(event) => setDraft({
                    ...draft,
                    phase2_defense_bonus_percent: Math.max(0, Math.min(100, Number(event.target.value))),
                  })}
                />
              </label>

              <label>
                <span>Особая каждые N</span>
                <input
                  type="number"
                  min={0}
                  max={20}
                  disabled={draft.phase2_hp_percent === 0}
                  value={draft.phase2_special_every_n}
                  onChange={(event) => {
                    const value = Math.max(0, Math.min(20, Number(event.target.value)))
                    setDraft({ ...draft, phase2_special_every_n: value === 1 ? 2 : value })
                  }}
                />
              </label>
            </div>
          </div>

          <div className="gm-enemy-resistances">
            <div>
              <strong>Сопротивления / уязвимости</strong>
              <span>+% уменьшает урон, −% увеличивает. Диапазон −75…+75.</span>
            </div>
            <div className="gm-enemy-resistance-grid">
              {damageTypes.map((type) => (
                <label key={type}>
                  <span>{damageLabels[type]}</span>
                  <input
                    type="number"
                    min={-75}
                    max={75}
                    value={draft.damage_resistances[type] ?? 0}
                    onChange={(event) => setResistance(type, event.target.value)}
                  />
                </label>
              ))}
            </div>
          </div>

          <div className="gm-event-template-actions">
            <button className="primary-button" type="button" disabled={busy} onClick={() => void save()}>
              {busy ? 'Сохраняем…' : draft.id ? 'Сохранить шаблон' : 'Создать шаблон'}
            </button>
            {draft.id && (
              <button className="ghost-button danger" type="button" disabled={busy} onClick={() => void remove()}>
                Удалить
              </button>
            )}
          </div>
        </div>
      </div>
    </article>
  )
}
