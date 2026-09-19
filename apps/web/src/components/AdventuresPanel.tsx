import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'
import type {
  AutobattleGuardMode,
  AutobattleResult,
  AutobattleSettings,
  AutobattleSpellRule,
  CharacterAdventureSite,
  CombatEncounter,
  CombatStyleProfile,
  CharacterSpell,
  CombatStatusEffect,
  CombatStatusEffectType,
  CombatTurn,
  DamageType,
  DungeonLootDrop,
} from '../types'

type Props = {
  characterId: string
  onProgressChanged?: () => Promise<unknown> | void
  onInventoryChanged?: () => Promise<unknown> | void
}

type CombatScroll = {
  id: string
  quantity: number
  item_definitions: {
    id: string
    name: string
    required_level: number
    category: 'consumable'
    effects: unknown[]
    scroll_mode: 'learn' | 'cast' | null
    scroll_spell_id: string | null
  } | {
    id: string
    name: string
    required_level: number
    category: 'consumable'
    effects: unknown[]
    scroll_mode: 'learn' | 'cast' | null
    scroll_spell_id: string | null
  }[] | null
}

function normalizeCombatScrollDefinition(value: CombatScroll['item_definitions']) {
  return Array.isArray(value) ? value[0] ?? null : value
}

function combatResourceAmounts(value: CombatScroll['item_definitions']) {
  const definition = normalizeCombatScrollDefinition(value)
  let heal = 0
  let mana = 0

  for (const effect of definition?.effects ?? []) {
    if (!effect || typeof effect !== 'object' || !('type' in effect) || !('amount' in effect)) continue
    const type = String((effect as { type?: unknown }).type ?? '')
    const amount = Math.max(0, Number((effect as { amount?: unknown }).amount) || 0)
    if (type === 'heal_hp') heal += amount
    if (type === 'restore_mana') mana += amount
  }

  return { heal, mana }
}

const statusEffectLabels: Record<CombatStatusEffectType, string> = {
  burn: 'Горение',
  bleed: 'Кровотечение',
  poison: 'Яд',
  chill: 'Охлаждение',
  stun: 'Оглушение',
  weaken: 'Ослабление',
  vulnerable: 'Уязвимость',
}

const damageTypeLabels: Record<DamageType, string> = {
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

function spellKindLabel(spell: CharacterSpell) {
  if (spell.spell_kind === 'heal') return 'Лечение'
  if (spell.spell_kind === 'guard') return 'Магический щит'
  if (spell.spell_kind === 'cleanse') return 'Очищение'
  if (spell.spell_kind === 'buff') return 'Усиление'
  return spell.damage_type ? damageTypeLabels[spell.damage_type] : 'Магия'
}

const enemySpecialLabels: Record<CombatEncounter['enemy_special_kind'], string> = {
  attack: 'Усиленная атака',
  heal: 'Самолечение',
  guard: 'Защитная стойка',
  enrage: 'Усиление атаки',
  cleanse: 'Снятие эффектов',
}

function enemySpecialValueText(encounter: CombatEncounter) {
  if (encounter.enemy_special_kind === 'attack') {
    return '×' + Number(encounter.enemy_special_damage_multiplier).toFixed(2)
  }
  if (encounter.enemy_special_kind === 'heal') return '+' + encounter.enemy_special_value + '% max HP'
  if (encounter.enemy_special_kind === 'guard') return '-' + encounter.enemy_special_value + '% следующего урона'
  if (encounter.enemy_special_kind === 'enrage') return '+' + encounter.enemy_special_value + '% атаки'
  return 'снимает негативные эффекты'
}

function combatStyleReady(profile: CombatStyleProfile | null | undefined) {
  return Boolean(
    profile
    && profile.sample_battles >= 3
    && profile.sample_actions >= 12
    && profile.confidence_percent >= 50,
  )
}

function combatStyleName(profile: CombatStyleProfile) {
  const spellShare = profile.magic_weight + profile.damage_spell_weight
  const defenseShare = profile.guard_weight + profile.shield_weight

  if (defenseShare >= 28) return 'Осторожный защитник'
  if (spellShare >= 55) return 'Боевой маг'
  if (profile.physical_weight >= 55) return 'Физический боец'
  if (profile.damage_spell_weight >= 35) return 'Заклинатель'
  return 'Смешанный стиль'
}

function combatStyleTraits(profile: CombatStyleProfile) {
  const traits: string[] = []

  if (profile.physical_weight >= 35) traits.push('любит физические атаки')
  if (profile.magic_weight + profile.damage_spell_weight >= 35) traits.push('часто использует магию')
  if (profile.guard_weight + profile.shield_weight >= 18) traits.push('часто защищается')
  if (profile.telegraph_guard_percent >= 60) traits.push('реагирует на подготовленные атаки')
  if (profile.heal_weight > 0 && profile.heal_hp_percent > 0) {
    traits.push(profile.heal_hp_percent >= 55 ? 'лечится рано' : profile.heal_hp_percent <= 30 ? 'лечится поздно' : 'лечится по ситуации')
  }
  if (profile.mana_reserve_percent >= 30) traits.push('бережёт ману')
  if (profile.buff_weight > 0) traits.push('поддерживает усиления')
  if (profile.cleanse_weight > 0) traits.push('снимает дебаффы')

  return traits.slice(0, 4)
}

export function AdventuresPanel({
  characterId,
  onProgressChanged,
  onInventoryChanged,
}: Props) {
  const [sites, setSites] = useState<CharacterAdventureSite[]>([])
  const [encounters, setEncounters] = useState<CombatEncounter[]>([])
  const [turns, setTurns] = useState<CombatTurn[]>([])
  const [statusEffects, setStatusEffects] = useState<CombatStatusEffect[]>([])
  const [spells, setSpells] = useState<CharacterSpell[]>([])
  const [combatScrolls, setCombatScrolls] = useState<CombatScroll[]>([])
  const [combatConsumables, setCombatConsumables] = useState<CombatScroll[]>([])
  const [lootDrops, setLootDrops] = useState<DungeonLootDrop[]>([])
  const [autobattleSettings, setAutobattleSettings] = useState<AutobattleSettings | null>(null)
  const [autobattleSpellRules, setAutobattleSpellRules] = useState<AutobattleSpellRule[]>([])
  const [combatStyleProfiles, setCombatStyleProfiles] = useState<CombatStyleProfile[]>([])
  const [autobattleEditorMode, setAutobattleEditorMode] = useState<'normal' | 'boss'>('normal')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  async function loadAdventures() {
    setLoading(true)

    const [siteResult, encounterResult, spellResult, scrollResult, autobattleResult, autobattleSpellResult, combatStyleResult] = await Promise.all([
      supabase.rpc('get_character_adventures', {
        p_character_id: characterId,
      }),
      supabase
        .from('combat_encounters')
        .select('id, dungeon_run_id, character_id, sector_id, status, round, room_index, is_boss, enemy_template_id, enemy_name, enemy_level, enemy_hp_current, enemy_hp_max, enemy_attack, enemy_defense, enemy_initiative, enemy_damage_type, enemy_resistances, enemy_on_hit_effect_type, enemy_on_hit_effect_chance, enemy_on_hit_effect_turns, enemy_on_hit_effect_potency, enemy_special_name, enemy_special_kind, enemy_special_value, enemy_special_damage_multiplier, enemy_special_every_n, enemy_special_damage_type, enemy_special_effect_type, enemy_special_effect_chance, enemy_special_effect_turns, enemy_special_effect_potency, enemy_special_telegraph_text, enemy_special_attack_text, enemy_special_charging, enemy_special_started_round, enemy_guard_percent, enemy_guard_hits, enemy_attack_bonus_percent, enemy_phase, enemy_phase2_hp_percent, enemy_phase2_name, enemy_phase2_attack_bonus_percent, enemy_phase2_defense_bonus_percent, enemy_phase2_special_every_n, player_physical_damage_type, player_magic_damage_type, player_hp_current, player_hp_max, player_mana_current, player_mana_max, player_counter_bonus_percent, player_counter_blocked_damage, player_spell_damage_bonus_percent, player_spell_damage_bonus_hits, created_at, ended_at')
        .eq('character_id', characterId)
        .order('created_at', { ascending: false })
        .limit(20),
      supabase.rpc('get_character_spells', {
        p_character_id: characterId,
      }),
      supabase
        .from('character_items')
        .select('id, quantity, item_definitions(id, name, required_level, category, effects, scroll_mode, scroll_spell_id)')
        .eq('character_id', characterId),
      supabase.rpc('get_character_autobattle_settings', {
        p_character_id: characterId,
      }),
      supabase.rpc('get_character_autobattle_spell_rules', {
        p_character_id: characterId,
      }),
      supabase.rpc('get_character_combat_style', {
        p_character_id: characterId,
      }),
    ])

    const error =
      siteResult.error ??
      encounterResult.error ??
      spellResult.error ??
      scrollResult.error ??
      autobattleResult.error ??
      autobattleSpellResult.error ??
      combatStyleResult.error

    if (error) {
      setMessage(error.message)
      setLoading(false)
      return
    }

    const nextSites = (siteResult.data as CharacterAdventureSite[] | null) ?? []
    const nextEncounters = (encounterResult.data as CombatEncounter[] | null) ?? []

    setSites(nextSites)
    setEncounters(nextEncounters)
    setSpells((spellResult.data as CharacterSpell[] | null) ?? [])
    const combatInventory = (scrollResult.data as CombatScroll[] | null) ?? []
    setCombatScrolls(
      combatInventory.filter((item) => {
        const definition = normalizeCombatScrollDefinition(item.item_definitions)
        return definition?.scroll_mode === 'cast' && Boolean(definition.scroll_spell_id)
      }),
    )
    setCombatConsumables(
      combatInventory.filter((item) => {
        const definition = normalizeCombatScrollDefinition(item.item_definitions)
        const resources = combatResourceAmounts(item.item_definitions)
        return definition?.scroll_mode == null && (resources.heal > 0 || resources.mana > 0)
      }),
    )
    setAutobattleSettings(
      (Array.isArray(autobattleResult.data)
        ? autobattleResult.data[0]
        : autobattleResult.data) as AutobattleSettings | null,
    )
    setAutobattleSpellRules(
      (autobattleSpellResult.data as AutobattleSpellRule[] | null) ?? [],
    )
    setCombatStyleProfiles(
      (combatStyleResult.data as CombatStyleProfile[] | null) ?? [],
    )

    const latestEncounter = nextEncounters[0] ?? null
    const activeRunId =
      nextSites.find((site) => site.content_type === 'dungeon' && site.run_status === 'active')?.active_run_id ??
      null
    const lootRunId = latestEncounter?.dungeon_run_id ?? activeRunId

    if (lootRunId) {
      const { data: lootData, error: lootError } = await supabase.rpc('get_dungeon_run_loot', {
        p_run_id: lootRunId,
      })

      if (lootError) {
        setMessage(lootError.message)
      } else {
        setLootDrops((lootData as DungeonLootDrop[] | null) ?? [])
      }
    } else {
      setLootDrops([])
    }

    if (latestEncounter) {
      const [turnResult, statusResult] = await Promise.all([
        supabase
          .from('combat_turns')
          .select('id, encounter_id, round, actor, action_type, damage, player_hp_after, enemy_hp_after, message, created_at')
          .eq('encounter_id', latestEncounter.id)
          .order('id', { ascending: false })
          .limit(18),
        supabase
          .from('combat_status_effects')
          .select('id, encounter_id, target, effect_type, potency, remaining_turns, source, created_at, updated_at')
          .eq('encounter_id', latestEncounter.id)
          .order('created_at', { ascending: true }),
      ])

      if (turnResult.error) {
        setMessage(turnResult.error.message)
      } else {
        setTurns((turnResult.data as CombatTurn[] | null) ?? [])
      }

      if (statusResult.error) {
        setMessage(statusResult.error.message)
      } else {
        setStatusEffects((statusResult.data as CombatStatusEffect[] | null) ?? [])
      }
    } else {
      setTurns([])
      setStatusEffects([])
    }

    setLoading(false)
  }

  useEffect(() => {
    void loadAdventures()
  }, [characterId])

  const activeDungeon = useMemo(
    () => sites.find((site) => site.content_type === 'dungeon' && site.run_status === 'active') ?? null,
    [sites],
  )

  const ruins = useMemo(
    () => sites.filter((site) => site.content_type === 'ruins'),
    [sites],
  )

  const dungeons = useMemo(
    () => sites.filter((site) => site.content_type === 'dungeon'),
    [sites],
  )

  const latestCombat = encounters[0] ?? null
  const activeCombat = latestCombat?.status === 'active' ? latestCombat : null
  const playerStatusEffects = statusEffects.filter((effect) => effect.target === 'player')
  const enemyStatusEffects = statusEffects.filter((effect) => effect.target === 'enemy')
  const latestCombatSite = latestCombat
    ? dungeons.find((site) => site.active_run_id === latestCombat.dungeon_run_id) ?? null
    : null

  async function startDungeon(site: CharacterAdventureSite) {
    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('start_dungeon_run', {
      p_character_id: characterId,
      p_sector_id: site.sector_id,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('PVP_DUEL_ACTIVE')) {
        setMessage('Сначала заверши активную дуэль.')
      } else if (raw.includes('DUNGEON_RUN_ALREADY_ACTIVE')) {
        setMessage('У персонажа уже есть активное прохождение подземелья.')
      } else if (raw.includes('DUNGEON_NOT_SCOUTED')) {
        setMessage('Сначала разведай вход через карту мира.')
      } else if (raw.includes('EXPEDITION_ALREADY_ACTIVE') || raw.includes('SITE_ACTION_ALREADY_ACTIVE')) {
        setMessage('Сначала заверши текущее исследование.')
      } else {
        setMessage(raw)
      }

      setBusy(false)
      return
    }

    await loadAdventures()
    setMessage('Прохождение начато.')
    setBusy(false)
  }

  async function startCombat(runId: string) {
    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('start_dungeon_combat', {
      p_run_id: runId,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('PVP_DUEL_ACTIVE')) {
        setMessage('Сначала заверши активную дуэль.')
      } else if (raw.includes('COMBAT_ALREADY_ACTIVE')) {
        setMessage('В этом подземелье уже идёт бой.')
      } else if (raw.includes('ROOM_COMBAT_ALREADY_EXISTS')) {
        setMessage('Этот зал уже был разыгран.')
      } else if (raw.includes('CHARACTER_HAS_NO_HP')) {
        setMessage('У персонажа нет здоровья для начала боя.')
      } else {
        setMessage(raw)
      }

      setBusy(false)
      return
    }

    await loadAdventures()
    setMessage('Следующий зал начат.')
    setBusy(false)
  }

  async function performCombatAction(action: 'physical' | 'magic' | 'guard') {
    if (!activeCombat) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('perform_combat_action', {
      p_encounter_id: activeCombat.id,
      p_action: action,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    await Promise.all([
      Promise.resolve(onProgressChanged?.()),
      Promise.resolve(onInventoryChanged?.()),
    ])
    await loadAdventures()
    setBusy(false)
  }

  async function castSpell(spell: CharacterSpell) {
    if (!activeCombat) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('cast_character_spell', {
      p_encounter_id: activeCombat.id,
      p_spell_id: spell.id,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('NOT_ENOUGH_MANA')) {
        setMessage('Недостаточно маны для этого заклинания.')
      } else if (raw.includes('SPELL_NOT_LEARNED')) {
        setMessage('Это заклинание не изучено персонажем.')
      } else if (raw.includes('ALREADY_FULL_HEALTH')) {
        setMessage('Здоровье уже полное.')
      } else {
        setMessage(raw)
      }
      setBusy(false)
      return
    }

    await Promise.all([
      Promise.resolve(onProgressChanged?.()),
      Promise.resolve(onInventoryChanged?.()),
    ])
    await loadAdventures()
    setBusy(false)
  }

  async function castScroll(scroll: CombatScroll) {
    if (!activeCombat) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('cast_spell_scroll', {
      p_encounter_id: activeCombat.id,
      p_character_item_id: scroll.id,
    })

    if (error) {
      const raw = error.message

      if (raw.includes('SCROLL_NOT_AVAILABLE')) {
        setMessage('Этот свиток уже был использован или его больше нет в инвентаре.')
      } else if (raw.includes('ITEM_IS_NOT_COMBAT_SCROLL')) {
        setMessage('Этот предмет нельзя применить как боевой свиток.')
      } else if (raw.includes('SPELL_NOT_AVAILABLE')) {
        setMessage('Заклинание этого свитка сейчас недоступно.')
      } else {
        setMessage(raw)
      }

      setBusy(false)
      return
    }

    await Promise.all([
      Promise.resolve(onProgressChanged?.()),
      Promise.resolve(onInventoryChanged?.()),
    ])
    await loadAdventures()
    setBusy(false)
  }

  async function useCombatConsumable(item: CombatScroll) {
    if (!activeCombat) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('use_combat_consumable', {
      p_encounter_id: activeCombat.id,
      p_character_item_id: item.id,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('ALREADY_FULL_RESOURCES')) {
        setMessage('HP и мана уже заполнены настолько, что этот предмет ничего не восстановит.')
      } else if (raw.includes('ITEM_IS_NOT_COMBAT_CONSUMABLE')) {
        setMessage('Этот расходник нельзя использовать в бою.')
      } else if (raw.includes('LEVEL_TOO_LOW')) {
        setMessage('Уровень персонажа слишком низкий для этого расходника.')
      } else {
        setMessage(raw)
      }
      setBusy(false)
      return
    }

    await Promise.all([
      Promise.resolve(onProgressChanged?.()),
      Promise.resolve(onInventoryChanged?.()),
    ])
    await loadAdventures()
    setBusy(false)
  }

  async function saveAutobattleSettings() {
    if (!autobattleSettings) return

    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('save_character_autobattle_settings', {
      p_character_id: characterId,
      p_strategy: autobattleSettings.strategy,
      p_stop_hp_percent: autobattleSettings.stop_hp_percent,
      p_mana_reserve_percent: autobattleSettings.mana_reserve_percent,
      p_use_learned_spells: autobattleSettings.use_learned_spells,
      p_include_boss: autobattleSettings.include_boss,
      p_normal_allow_physical: autobattleSettings.normal_allow_physical,
      p_normal_allow_magic: autobattleSettings.normal_allow_magic,
      p_normal_allow_spells: autobattleSettings.normal_allow_spells,
      p_normal_guard_mode: autobattleSettings.normal_guard_mode,
      p_normal_guard_hp_percent: autobattleSettings.normal_guard_hp_percent,
      p_normal_guard_every_n: autobattleSettings.normal_guard_every_n,
      p_boss_allow_physical: autobattleSettings.boss_allow_physical,
      p_boss_allow_magic: autobattleSettings.boss_allow_magic,
      p_boss_allow_spells: autobattleSettings.boss_allow_spells,
      p_boss_guard_mode: autobattleSettings.boss_guard_mode,
      p_boss_guard_hp_percent: autobattleSettings.boss_guard_hp_percent,
      p_boss_guard_every_n: autobattleSettings.boss_guard_every_n,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    const { data: supportData, error: supportError } = await supabase.rpc(
      'save_character_autobattle_support_settings',
      {
        p_character_id: characterId,
        p_normal_support_enabled: autobattleSettings.normal_support_enabled,
        p_normal_heal_hp_percent: autobattleSettings.normal_heal_hp_percent,
        p_normal_cleanse_min_debuffs: autobattleSettings.normal_cleanse_min_debuffs,
        p_normal_shield_special: autobattleSettings.normal_shield_special,
        p_normal_buff_enabled: autobattleSettings.normal_buff_enabled,
        p_boss_support_enabled: autobattleSettings.boss_support_enabled,
        p_boss_heal_hp_percent: autobattleSettings.boss_heal_hp_percent,
        p_boss_cleanse_min_debuffs: autobattleSettings.boss_cleanse_min_debuffs,
        p_boss_shield_special: autobattleSettings.boss_shield_special,
        p_boss_buff_enabled: autobattleSettings.boss_buff_enabled,
      },
    )

    if (supportError) {
      setMessage(supportError.message)
      setBusy(false)
      return
    }

    const spellRuleResults = await Promise.all(
      autobattleSpellRules.map((rule) => supabase.rpc('save_character_autobattle_spell_rule', {
        p_character_id: characterId,
        p_spell_id: rule.spell_id,
        p_normal_enabled: rule.normal_enabled,
        p_normal_priority: rule.normal_priority,
        p_boss_enabled: rule.boss_enabled,
        p_boss_priority: rule.boss_priority,
      })),
    )

    const spellRuleError = spellRuleResults.find((result) => result.error)?.error
    if (spellRuleError) {
      setMessage(spellRuleError.message)
      setBusy(false)
      return
    }

    const saved = (Array.isArray(supportData) ? supportData[0] : supportData) as AutobattleSettings | null
    if (saved) setAutobattleSettings(saved)
    setMessage('Тактика автобоя сохранена.')
    setBusy(false)
  }

  function applyAutobattlePreset(preset: 'physical' | 'mage' | 'tank' | 'balanced') {
    if (!autobattleSettings) return

    const boss = autobattleEditorMode === 'boss'
    const prefix = boss ? 'boss' : 'normal'

    const patch = preset === 'mage'
      ? {
          [prefix + '_allow_physical']: false,
          [prefix + '_allow_magic']: true,
          [prefix + '_allow_spells']: true,
          [prefix + '_guard_mode']: 'low_hp',
          [prefix + '_guard_hp_percent']: boss ? 35 : 25,
          [prefix + '_guard_every_n']: 0,
        }
      : preset === 'tank'
        ? {
            [prefix + '_allow_physical']: true,
            [prefix + '_allow_magic']: false,
            [prefix + '_allow_spells']: false,
            [prefix + '_guard_mode']: 'low_hp_or_interval',
            [prefix + '_guard_hp_percent']: boss ? 60 : 45,
            [prefix + '_guard_every_n']: 2,
          }
        : preset === 'physical'
          ? {
              [prefix + '_allow_physical']: true,
              [prefix + '_allow_magic']: false,
              [prefix + '_allow_spells']: false,
              [prefix + '_guard_mode']: 'low_hp',
              [prefix + '_guard_hp_percent']: boss ? 35 : 25,
              [prefix + '_guard_every_n']: 0,
            }
          : {
              [prefix + '_allow_physical']: true,
              [prefix + '_allow_magic']: true,
              [prefix + '_allow_spells']: true,
              [prefix + '_guard_mode']: 'low_hp',
              [prefix + '_guard_hp_percent']: boss ? 35 : 25,
              [prefix + '_guard_every_n']: 0,
            }

    setAutobattleSettings({
      ...autobattleSettings,
      ...patch,
    } as AutobattleSettings)
  }

  function updateAutobattleSpellRule(
    spellId: string,
    field: 'enabled' | 'priority',
    value: boolean | number,
  ) {
    const boss = autobattleEditorMode === 'boss'

    setAutobattleSpellRules((current) => current.map((rule) => {
      if (rule.spell_id !== spellId) return rule

      if (boss) {
        return field === 'enabled'
          ? { ...rule, boss_enabled: Boolean(value) }
          : { ...rule, boss_priority: Math.max(1, Math.min(999, Number(value))) }
      }

      return field === 'enabled'
        ? { ...rule, normal_enabled: Boolean(value) }
        : { ...rule, normal_priority: Math.max(1, Math.min(999, Number(value))) }
    }))
  }

  function updateAutobattleSupport(
    field: 'support_enabled' | 'heal_hp_percent' | 'cleanse_min_debuffs' | 'shield_special' | 'buff_enabled',
    value: boolean | number,
  ) {
    if (!autobattleSettings) return
    const prefix = autobattleEditorMode === 'boss' ? 'boss' : 'normal'
    const key = (prefix + '_' + field) as keyof AutobattleSettings

    setAutobattleSettings({
      ...autobattleSettings,
      [key]: value,
    } as AutobattleSettings)
  }

  function autobattleMessage(result: AutobattleResult, wholeDungeon: boolean) {
    if (result.status === 'completed') {
      return 'Автозачистка завершена: подземелье полностью пройдено.'
    }
    if (result.status === 'victory') {
      return wholeDungeon
        ? 'Автобой завершил доступные бои.'
        : 'Автобой выиграл текущий бой.'
    }
    if (result.status === 'defeat' || result.status === 'abandoned') {
      return 'Автобой закончился поражением. Персонаж отступил из подземелья.'
    }
    if (result.reason === 'low_hp' || result.reason === 'low_hp_between_rooms') {
      return 'Автобой остановился по порогу безопасности HP. Можно продолжить вручную или после лечения.'
    }
    if (result.reason === 'boss_wait') {
      return 'Автозачистка дошла до хранителя и остановилась: бой с боссом отключён в настройках.'
    }
    if (result.reason === 'action_limit' || result.reason === 'dungeon_action_limit') {
      return 'Автобой остановлен по защитному лимиту ходов. Управление возвращено игроку.'
    }
    return 'Автобой завершён.'
  }

  async function runCombatAutobattle() {
    if (!activeCombat) return

    setBusy(true)
    setMessage('Автобой просчитывает текущий бой…')

    const { data, error } = await supabase.rpc('run_combat_autobattle', {
      p_encounter_id: activeCombat.id,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    const result = data as AutobattleResult
    await Promise.all([
      Promise.resolve(onProgressChanged?.()),
      Promise.resolve(onInventoryChanged?.()),
    ])
    await loadAdventures()
    setMessage(autobattleMessage(result, false))
    setBusy(false)
  }

  async function runDungeonAutobattle(runId: string) {
    setBusy(true)
    setMessage('Автозачистка проходит подземелье…')

    const { data, error } = await supabase.rpc('run_dungeon_autobattle', {
      p_run_id: runId,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    const result = data as AutobattleResult
    await Promise.all([
      Promise.resolve(onProgressChanged?.()),
      Promise.resolve(onInventoryChanged?.()),
    ])
    await loadAdventures()
    setMessage(autobattleMessage(result, true))
    setBusy(false)
  }

  async function runCombatStyleAutobattle() {
    if (!activeCombat) return

    setBusy(true)
    setMessage('Veira повторяет твой изученный стиль боя…')

    const { data, error } = await supabase.rpc('run_combat_style_autobattle', {
      p_encounter_id: activeCombat.id,
    })

    if (error) {
      setMessage(
        error.message.includes('STYLE_PROFILE_NOT_READY')
          ? 'Стиль ещё изучен недостаточно. Заверши вручную хотя бы 3 боя и сделай в них не меньше 12 действий.'
          : error.message,
      )
      setBusy(false)
      return
    }

    const result = data as AutobattleResult
    await Promise.all([
      Promise.resolve(onProgressChanged?.()),
      Promise.resolve(onInventoryChanged?.()),
    ])
    await loadAdventures()
    setMessage(
      result.status === 'victory'
        ? 'Veira завершила бой в твоём стиле.'
        : autobattleMessage(result, false),
    )
    setBusy(false)
  }

  async function runDungeonStyleAutobattle(runId: string) {
    setBusy(true)
    setMessage('Veira проходит подземелье в твоём стиле…')

    const { data, error } = await supabase.rpc('run_dungeon_style_autobattle', {
      p_run_id: runId,
    })

    if (error) {
      setMessage(
        error.message.includes('STYLE_PROFILE_NOT_READY')
          ? 'Стиль ещё изучен недостаточно. Сначала заверши вручную хотя бы 3 обычных боя.'
          : error.message,
      )
      setBusy(false)
      return
    }

    const result = data as AutobattleResult
    await Promise.all([
      Promise.resolve(onProgressChanged?.()),
      Promise.resolve(onInventoryChanged?.()),
    ])
    await loadAdventures()
    setMessage(
      result.status === 'completed'
        ? 'Veira полностью зачистила подземелье, повторяя твой стиль.'
        : autobattleMessage(result, true),
    )
    setBusy(false)
  }

  async function leaveDungeon(runId: string) {
    setBusy(true)
    setMessage('')

    const { error } = await supabase.rpc('leave_dungeon_run', {
      p_run_id: runId,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    await loadAdventures()
    setMessage('Персонаж покинул подземелье. Его можно начать заново позже.')
    setBusy(false)
  }

  if (loading && sites.length === 0) {
    return (
      <section className="panel adventures-loading">
        <span className="eyebrow">ПРИКЛЮЧЕНИЯ</span>
        <h2>Проверяем найденные места…</h2>
      </section>
    )
  }

  const playerHpPercent = activeCombat
    ? Math.max(0, Math.min(100, Math.round((activeCombat.player_hp_current / activeCombat.player_hp_max) * 100)))
    : 0
  const enemyHpPercent = activeCombat
    ? Math.max(0, Math.min(100, Math.round((activeCombat.enemy_hp_current / activeCombat.enemy_hp_max) * 100)))
    : 0

  const playerManaPercent = activeCombat
    ? Math.max(0, Math.min(100, Math.round((activeCombat.player_mana_current / activeCombat.player_mana_max) * 100)))
    : 0

  const clearedRooms = activeDungeon?.run_rooms_cleared ?? 0
  const totalRooms = activeDungeon?.run_total_rooms ?? 0
  const nextRoom = Math.min(totalRooms, clearedRooms + 1)
  const dungeonProgress = totalRooms > 0
    ? Math.round((clearedRooms / totalRooms) * 100)
    : 0
  const nextRoomIsBoss = totalRooms > 0 && nextRoom === totalRooms

  const normalStyleProfile = combatStyleProfiles.find((profile) => profile.context === 'normal') ?? null
  const bossStyleProfile = combatStyleProfiles.find((profile) => profile.context === 'boss') ?? null
  const normalStyleReady = combatStyleReady(normalStyleProfile)
  const bossStyleReady = combatStyleReady(bossStyleProfile)
  const activeStyleProfile = activeCombat?.is_boss && bossStyleReady
    ? bossStyleProfile
    : normalStyleProfile
  const styleTraits = activeStyleProfile && combatStyleReady(activeStyleProfile)
    ? combatStyleTraits(activeStyleProfile)
    : []

  return (
    <section className="adventures-section">
      <article className="panel adventures-header">
        <div>
          <span className="eyebrow">ПРИКЛЮЧЕНИЯ</span>
          <h2>Руины и подземелья</h2>
          <p className="muted">
            Открытие сектора только обнаруживает место. Руины нужно исследовать отдельно, а вход в подземелье — сначала разведать.
          </p>
        </div>
        <div className="adventure-counters">
          <span><strong>{ruins.length}</strong><small>руин найдено</small></span>
          <span><strong>{dungeons.length}</strong><small>данжей найдено</small></span>
        </div>
      </article>

      {message && <p className="gm-notice" aria-live="polite">{message}</p>}

      {activeDungeon && activeDungeon.active_run_id && (
        <article className="panel active-dungeon-panel">
          <div className="section-heading">
            <div>
              <span className="eyebrow">АКТИВНОЕ ПРОХОЖДЕНИЕ</span>
              <h2>{activeDungeon.title}</h2>
            </div>
            <span className="badge">сектор #{activeDungeon.sector_id}</span>
          </div>

          <div className="dungeon-progress-block">
            <div className="dungeon-progress-head">
              <span>Пройдено залов</span>
              <strong>{clearedRooms} / {totalRooms}</strong>
            </div>
            <div className="dungeon-progress-meter">
              <span style={{ width: dungeonProgress + '%' }} />
            </div>
            <div className="dungeon-reward-preview">
              <span>За полную зачистку</span>
              <strong>
                {activeDungeon.run_reward_gold ?? 0} золота · {activeDungeon.run_reward_experience ?? 0} опыта
              </strong>
            </div>
          </div>

          {lootDrops.length > 0 && (
            <div className="dungeon-loot-block">
              <div className="combat-special-heading">
                <strong>Добыча этого прохождения</strong>
                <span>уже добавлена в инвентарь</span>
              </div>
              <div className="dungeon-loot-grid">
                {lootDrops.map((drop) => (
                  <div className={'dungeon-loot-item rarity-' + drop.rarity} key={drop.drop_id}>
                    <div>
                      <strong>{drop.item_name}</strong>
                      <span>
                        {drop.source_type === 'dungeon'
                          ? 'финальный тайник'
                          : drop.source_type === 'boss'
                            ? 'хранитель'
                            : 'враг'}
                      </span>
                    </div>
                    <b>×{drop.quantity}</b>
                  </div>
                ))}
              </div>
            </div>
          )}

          <div className="style-autobattle-panel">
            <div className="section-heading">
              <div>
                <span className="eyebrow">VEIRA ИЗУЧАЕТ ТВОЙ БОЙ</span>
                <h3>{normalStyleReady && normalStyleProfile
                  ? combatStyleName(normalStyleProfile)
                  : 'Стиль ещё формируется'}</h3>
                <p className="muted">
                  В обучение попадают только твои ручные действия. Обычный автобой и «Играть как я» сами себя не обучают.
                </p>
              </div>
              <span className="badge">
                {normalStyleProfile?.confidence_percent ?? 0}% уверенности
              </span>
            </div>

            {normalStyleReady && normalStyleProfile ? (
              <>
                <div className="style-profile-stats">
                  <span><strong>{normalStyleProfile.physical_weight}%</strong><small>физика</small></span>
                  <span><strong>{normalStyleProfile.magic_weight}%</strong><small>врожд. магия</small></span>
                  <span><strong>{normalStyleProfile.damage_spell_weight}%</strong><small>заклинания</small></span>
                  <span><strong>{normalStyleProfile.guard_weight + normalStyleProfile.shield_weight}%</strong><small>защита</small></span>
                </div>

                {styleTraits.length > 0 && (
                  <div className="style-traits">
                    {styleTraits.map((trait) => <span key={trait}>{trait}</span>)}
                  </div>
                )}

                <div className="style-learning-meta">
                  <span>Обычные бои: {normalStyleProfile.sample_battles}/10</span>
                  <span>Ручных решений: {normalStyleProfile.sample_actions}</span>
                  <span>
                    Боссы: {bossStyleReady && bossStyleProfile
                      ? bossStyleProfile.sample_battles + '/10 · свой профиль'
                      : 'пока используется обычный стиль'}
                  </span>
                </div>
              </>
            ) : (
              <div className="style-learning-progress">
                <strong>
                  {Math.min(3, normalStyleProfile?.sample_battles ?? 0)} / 3 ручных боя
                </strong>
                <span>
                  Решений: {normalStyleProfile?.sample_actions ?? 0} / 12. После этого откроется полностью автоматический режим.
                </span>
              </div>
            )}

            <button
              className="style-autobattle-button"
              type="button"
              disabled={busy || !normalStyleReady}
              onClick={() => activeCombat
                ? void runCombatStyleAutobattle()
                : void runDungeonStyleAutobattle(activeDungeon.active_run_id!)}
            >
              {busy ? 'Veira играет…' : normalStyleReady ? 'Играть как я' : 'Стиль ещё изучается'}
            </button>
          </div>

          {autobattleSettings && (
            <details className="autobattle-panel">
              <summary>
                <span>
                  <strong>Автобой · своя тактика</strong>
                  <small>Отдельные правила для обычных врагов и боссов</small>
                </span>
                <b>настроить</b>
              </summary>

              <div className="autobattle-mode-switch">
                <button
                  type="button"
                  className={autobattleEditorMode === 'normal' ? 'active' : ''}
                  onClick={() => setAutobattleEditorMode('normal')}
                >
                  Обычные бои
                </button>
                <button
                  type="button"
                  className={autobattleEditorMode === 'boss' ? 'active' : ''}
                  onClick={() => setAutobattleEditorMode('boss')}
                >
                  Боссы
                </button>
              </div>

              <div className="autobattle-presets">
                <span>Быстрый пресет</span>
                <div>
                  <button type="button" onClick={() => applyAutobattlePreset('physical')}>Физик</button>
                  <button type="button" onClick={() => applyAutobattlePreset('mage')}>Маг</button>
                  <button type="button" onClick={() => applyAutobattlePreset('tank')}>Танк</button>
                  <button type="button" onClick={() => applyAutobattlePreset('balanced')}>Универсал</button>
                </div>
              </div>

              <div className="autobattle-action-policy">
                <strong>Что персонажу вообще разрешено делать</strong>
                <div className="autobattle-checks">
                  <label>
                    <input
                      type="checkbox"
                      checked={autobattleEditorMode === 'boss'
                        ? autobattleSettings.boss_allow_physical
                        : autobattleSettings.normal_allow_physical}
                      onChange={(event) => setAutobattleSettings({
                        ...autobattleSettings,
                        [autobattleEditorMode === 'boss'
                          ? 'boss_allow_physical'
                          : 'normal_allow_physical']: event.target.checked,
                      })}
                    />
                    <span>Физические атаки</span>
                  </label>
                  <label>
                    <input
                      type="checkbox"
                      checked={autobattleEditorMode === 'boss'
                        ? autobattleSettings.boss_allow_magic
                        : autobattleSettings.normal_allow_magic}
                      onChange={(event) => setAutobattleSettings({
                        ...autobattleSettings,
                        [autobattleEditorMode === 'boss'
                          ? 'boss_allow_magic'
                          : 'normal_allow_magic']: event.target.checked,
                      })}
                    />
                    <span>Врождённая магия</span>
                  </label>
                  <label>
                    <input
                      type="checkbox"
                      checked={autobattleEditorMode === 'boss'
                        ? autobattleSettings.boss_allow_spells
                        : autobattleSettings.normal_allow_spells}
                      onChange={(event) => setAutobattleSettings({
                        ...autobattleSettings,
                        [autobattleEditorMode === 'boss'
                          ? 'boss_allow_spells'
                          : 'normal_allow_spells']: event.target.checked,
                      })}
                    />
                    <span>Изученные заклинания</span>
                  </label>
                </div>
              </div>

              <div className="autobattle-settings-grid">
                <label>
                  <span>Защита</span>
                  <select
                    value={autobattleEditorMode === 'boss'
                      ? autobattleSettings.boss_guard_mode
                      : autobattleSettings.normal_guard_mode}
                    onChange={(event) => setAutobattleSettings({
                      ...autobattleSettings,
                      [autobattleEditorMode === 'boss'
                        ? 'boss_guard_mode'
                        : 'normal_guard_mode']: event.target.value as AutobattleGuardMode,
                    })}
                  >
                    <option value="never">Не использовать</option>
                    <option value="low_hp">При низком HP</option>
                    <option value="interval">Каждые N ходов</option>
                    <option value="low_hp_or_interval">HP или каждые N ходов</option>
                  </select>
                </label>

                <label>
                  <span>Защита при HP ≤ %</span>
                  <input
                    type="number"
                    min={0}
                    max={100}
                    value={autobattleEditorMode === 'boss'
                      ? autobattleSettings.boss_guard_hp_percent
                      : autobattleSettings.normal_guard_hp_percent}
                    onChange={(event) => setAutobattleSettings({
                      ...autobattleSettings,
                      [autobattleEditorMode === 'boss'
                        ? 'boss_guard_hp_percent'
                        : 'normal_guard_hp_percent']: Math.max(0, Math.min(100, Number(event.target.value))),
                    })}
                  />
                </label>

                <label>
                  <span>Защита каждый N-й ход</span>
                  <input
                    type="number"
                    min={0}
                    max={20}
                    value={autobattleEditorMode === 'boss'
                      ? autobattleSettings.boss_guard_every_n
                      : autobattleSettings.normal_guard_every_n}
                    onChange={(event) => setAutobattleSettings({
                      ...autobattleSettings,
                      [autobattleEditorMode === 'boss'
                        ? 'boss_guard_every_n'
                        : 'normal_guard_every_n']: Math.max(0, Math.min(20, Number(event.target.value))),
                    })}
                  />
                </label>
              </div>

              <div className="autobattle-global-settings">
                <label>
                  <span>Полностью остановить автобой при HP ≤</span>
                  <strong>{autobattleSettings.stop_hp_percent}%</strong>
                  <input
                    type="range"
                    min={0}
                    max={80}
                    value={autobattleSettings.stop_hp_percent}
                    onChange={(event) => setAutobattleSettings({
                      ...autobattleSettings,
                      stop_hp_percent: Number(event.target.value),
                    })}
                  />
                </label>

                <label>
                  <span>Не тратить последние</span>
                  <strong>{autobattleSettings.mana_reserve_percent}% маны</strong>
                  <input
                    type="range"
                    min={0}
                    max={100}
                    value={autobattleSettings.mana_reserve_percent}
                    onChange={(event) => setAutobattleSettings({
                      ...autobattleSettings,
                      mana_reserve_percent: Number(event.target.value),
                    })}
                  />
                </label>
              </div>

              <div className="autobattle-spell-rules">
                <div className="combat-special-heading">
                  <strong>Умная поддержка</strong>
                  <span>реагирует на состояние боя автоматически</span>
                </div>

                <div className="autobattle-checks">
                  <label>
                    <input
                      type="checkbox"
                      checked={autobattleEditorMode === 'boss'
                        ? autobattleSettings.boss_support_enabled
                        : autobattleSettings.normal_support_enabled}
                      onChange={(event) => updateAutobattleSupport('support_enabled', event.target.checked)}
                    />
                    <span>Использовать лечебные и вспомогательные заклинания</span>
                  </label>

                  <label>
                    <input
                      type="checkbox"
                      checked={autobattleEditorMode === 'boss'
                        ? autobattleSettings.boss_shield_special
                        : autobattleSettings.normal_shield_special}
                      onChange={(event) => updateAutobattleSupport('shield_special', event.target.checked)}
                    />
                    <span>Магический щит перед подготовленной особой атакой</span>
                  </label>

                  <label>
                    <input
                      type="checkbox"
                      checked={autobattleEditorMode === 'boss'
                        ? autobattleSettings.boss_buff_enabled
                        : autobattleSettings.normal_buff_enabled}
                      onChange={(event) => updateAutobattleSupport('buff_enabled', event.target.checked)}
                    />
                    <span>Поддерживать усиление урона, пока враг не добит</span>
                  </label>
                </div>

                <div className="autobattle-global-settings">
                  <label>
                    <span>Лечиться при HP ≤</span>
                    <strong>
                      {autobattleEditorMode === 'boss'
                        ? autobattleSettings.boss_heal_hp_percent
                        : autobattleSettings.normal_heal_hp_percent}%
                    </strong>
                    <input
                      type="range"
                      min={0}
                      max={90}
                      value={autobattleEditorMode === 'boss'
                        ? autobattleSettings.boss_heal_hp_percent
                        : autobattleSettings.normal_heal_hp_percent}
                      onChange={(event) => updateAutobattleSupport('heal_hp_percent', Number(event.target.value))}
                    />
                  </label>

                  <label>
                    <span>Очищаться при дебаффах</span>
                    <strong>
                      {autobattleEditorMode === 'boss'
                        ? autobattleSettings.boss_cleanse_min_debuffs
                        : autobattleSettings.normal_cleanse_min_debuffs}+
                    </strong>
                    <input
                      type="range"
                      min={0}
                      max={6}
                      value={autobattleEditorMode === 'boss'
                        ? autobattleSettings.boss_cleanse_min_debuffs
                        : autobattleSettings.normal_cleanse_min_debuffs}
                      onChange={(event) => updateAutobattleSupport('cleanse_min_debuffs', Number(event.target.value))}
                    />
                  </label>
                </div>

                <p className="muted">
                  Поддержка уважает общий резерв маны. Приоритет: лечение → очищение → щит на подготовленную атаку → усиление. Значение 0 отключает соответствующий порог.
                </p>
              </div>

              {autobattleSpellRules.length > 0 && (
                <div className="autobattle-spell-rules">
                  <div className="combat-special-heading">
                    <strong>Приоритет заклинаний</strong>
                    <span>1 = использовать раньше</span>
                  </div>

                  {autobattleSpellRules.map((rule) => (
                    <div className="autobattle-spell-rule" key={rule.spell_id}>
                      <label>
                        <input
                          type="checkbox"
                          checked={autobattleEditorMode === 'boss'
                            ? rule.boss_enabled
                            : rule.normal_enabled}
                          onChange={(event) => updateAutobattleSpellRule(
                            rule.spell_id,
                            'enabled',
                            event.target.checked,
                          )}
                        />
                        <span>{rule.spell_name}</span>
                      </label>
                      <input
                        type="number"
                        min={1}
                        max={999}
                        value={autobattleEditorMode === 'boss'
                          ? rule.boss_priority
                          : rule.normal_priority}
                        onChange={(event) => updateAutobattleSpellRule(
                          rule.spell_id,
                          'priority',
                          Number(event.target.value),
                        )}
                      />
                    </div>
                  ))}
                </div>
              )}

              <div className="autobattle-checks final">
                <label>
                  <input
                    type="checkbox"
                    checked={autobattleSettings.include_boss}
                    onChange={(event) => setAutobattleSettings({
                      ...autobattleSettings,
                      include_boss: event.target.checked,
                    })}
                  />
                  <span>Автозачистке разрешено самой входить к боссу</span>
                </label>
              </div>

              <div className="autobattle-note">
                Автобой теперь умеет сам лечиться, очищать дебаффы, ставить изученный магический щит перед объявленной особой атакой и поддерживать бафф урона. Он соблюдает резерв маны и не расходует боевые свитки или зелья автоматически. Физическая контратака после блока всё ещё тратится первой, если поддержка в этот ход не нужна.
              </div>

              <button
                className="primary-button"
                type="button"
                disabled={busy}
                onClick={() => void saveAutobattleSettings()}
              >
                Сохранить тактику
              </button>
            </details>
          )}

          {!activeCombat ? (
            <>
              <div className="dungeon-run-stage">
                <span>Следующий этап</span>
                <strong>
                  {nextRoomIsBoss
                    ? `Финальный зал · хранитель`
                    : `Зал ${nextRoom} из ${totalRooms}`}
                </strong>
                <p className="muted">
                  Здоровье между залами не восстанавливается автоматически. Можно продолжить или выйти и начать прохождение заново позже.
                </p>
              </div>

              <div className="dungeon-entry-actions">
                <button
                  className="primary-button"
                  type="button"
                  disabled={busy}
                  onClick={() => void startCombat(activeDungeon.active_run_id!)}
                >
                  {nextRoomIsBoss ? 'Войти к хранителю' : `Войти в зал ${nextRoom}`}
                </button>

                <button
                  className="autobattle-button"
                  type="button"
                  disabled={busy}
                  onClick={() => void runDungeonAutobattle(activeDungeon.active_run_id!)}
                >
                  {busy ? 'Автобой…' : 'Автозачистка'}
                </button>

                <button
                  className="style-autobattle-button compact"
                  type="button"
                  disabled={busy || !normalStyleReady}
                  title={normalStyleReady ? 'Автоматически повторяет изученные привычки твоих ручных боёв.' : 'Сначала нужно минимум 3 завершённых ручных боя и 12 решений.'}
                  onClick={() => void runDungeonStyleAutobattle(activeDungeon.active_run_id!)}
                >
                  Играть как я
                </button>

                <button
                  className="ghost-button danger-button"
                  type="button"
                  disabled={busy}
                  onClick={() => void leaveDungeon(activeDungeon.active_run_id!)}
                >
                  Покинуть подземелье
                </button>
              </div>
            </>
          ) : (
            <div className="combat-shell">
              <div className="combat-heading">
                <div>
                  <span className="eyebrow">
                    {activeCombat.is_boss
                      ? `ХРАНИТЕЛЬ · РАУНД ${activeCombat.round + 1}`
                      : `ЗАЛ ${activeCombat.room_index} · РАУНД ${activeCombat.round + 1}`}
                  </span>
                  <h3>{activeCombat.enemy_name}</h3>
                  <span className="muted">
                    Уровень {activeCombat.enemy_level}
                    {activeCombat.is_boss ? ' · финальный противник' : ''}
                    {' · '}атака: {damageTypeLabels[activeCombat.enemy_damage_type]}
                  </span>
                </div>
                <span className="badge">
                  {activeCombat.room_index} / {totalRooms}
                </span>
              </div>

              <div className="combatants-grid">
                <div className="combatant-card">
                  <div className="combatant-head">
                    <span>Персонаж</span>
                    <strong>{activeCombat.player_hp_current} / {activeCombat.player_hp_max} HP</strong>
                  </div>
                  <div className="combat-hp-meter player"><span style={{ width: playerHpPercent + '%' }} /></div>
                  <div className="combatant-head mana">
                    <span>Мана</span>
                    <strong>{activeCombat.player_mana_current} / {activeCombat.player_mana_max}</strong>
                  </div>
                  <div className="combat-hp-meter mana"><span style={{ width: playerManaPercent + '%' }} /></div>
                  {activeCombat.player_counter_bonus_percent > 0 && (
                    <div className="combat-counter-ready">
                      <strong>Контратака +{activeCombat.player_counter_bonus_percent}%</strong>
                      <span>
                        Следующая физическая атака усилена
                        {activeCombat.player_counter_blocked_damage > 0
                          ? ` · заблокировано ${activeCombat.player_counter_blocked_damage} урона`
                          : ''}
                      </span>
                    </div>
                  )}
                  {activeCombat.player_spell_damage_bonus_percent > 0 && activeCombat.player_spell_damage_bonus_hits > 0 && (
                    <div className="combat-counter-ready">
                      <strong>Магическое усиление +{activeCombat.player_spell_damage_bonus_percent}%</strong>
                      <span>Осталось усиленных атак: {activeCombat.player_spell_damage_bonus_hits}</span>
                    </div>
                  )}
                  {playerStatusEffects.length > 0 && (
                    <div className="combat-status-list">
                      {playerStatusEffects.map((effect) => (
                        <span className={'combat-status-chip ' + effect.effect_type} key={effect.id}>
                          {statusEffectLabels[effect.effect_type]} · {effect.remaining_turns} х.
                          {effect.potency > 0 ? ' · ' + effect.potency : ''}
                        </span>
                      ))}
                    </div>
                  )}
                </div>

                <div className="combatant-card enemy">
                  <div className="combatant-head">
                    <span>{activeCombat.enemy_name}</span>
                    <strong>{activeCombat.enemy_hp_current} / {activeCombat.enemy_hp_max} HP</strong>
                  </div>
                  <div className="combat-hp-meter enemy"><span style={{ width: enemyHpPercent + '%' }} /></div>
                  <div className="combat-resistance-summary">
                    {Object.entries(activeCombat.enemy_resistances ?? {})
                      .filter((entry): entry is [DamageType, number] => typeof entry[1] === 'number' && entry[1] !== 0)
                      .map(([type, value]) => (
                        <span className={value >= 0 ? 'positive' : 'negative'} key={type}>
                          {damageTypeLabels[type]} {value >= 0 ? '+' : ''}{value}%
                        </span>
                      ))}
                  </div>

                  {enemyStatusEffects.length > 0 && (
                    <div className="combat-status-list">
                      {enemyStatusEffects.map((effect) => (
                        <span className={'combat-status-chip ' + effect.effect_type} key={effect.id}>
                          {statusEffectLabels[effect.effect_type]} · {effect.remaining_turns} х.
                          {effect.potency > 0 ? ' · ' + effect.potency : ''}
                        </span>
                      ))}
                    </div>
                  )}

                  {activeCombat.enemy_on_hit_effect_type && (
                    <div className="enemy-on-hit-effect">
                      При попадании: {statusEffectLabels[activeCombat.enemy_on_hit_effect_type]}
                      {' · '}{activeCombat.enemy_on_hit_effect_chance}%
                    </div>
                  )}

                  {activeCombat.enemy_special_every_n >= 2 && activeCombat.enemy_special_name && (
                    <div className={'enemy-special-summary ' + (activeCombat.enemy_special_charging ? 'charging' : '')}>
                      <strong>{activeCombat.enemy_special_name}</strong>
                      <span>
                        {enemySpecialLabels[activeCombat.enemy_special_kind]}
                        {' · '}подготовка видна за 1 ход
                        {' · '}{enemySpecialValueText(activeCombat)}
                      </span>
                    </div>
                  )}

                  {(activeCombat.enemy_guard_hits > 0 || activeCombat.enemy_attack_bonus_percent > 0 || activeCombat.enemy_phase > 1) && (
                    <div className="enemy-combat-state">
                      {activeCombat.enemy_phase > 1 && (
                        <span>Фаза {activeCombat.enemy_phase}{activeCombat.enemy_phase2_name ? ' · ' + activeCombat.enemy_phase2_name : ''}</span>
                      )}
                      {activeCombat.enemy_guard_hits > 0 && (
                        <span>Стойка · −{activeCombat.enemy_guard_percent}% следующего урона</span>
                      )}
                      {activeCombat.enemy_attack_bonus_percent > 0 && (
                        <span>Усиление · +{activeCombat.enemy_attack_bonus_percent}% атаки</span>
                      )}
                    </div>
                  )}
                </div>
              </div>

              {activeCombat.enemy_special_charging && (
                <div className="enemy-special-warning" role="status" aria-live="polite">
                  <span>ПОДГОТОВКА · {enemySpecialLabels[activeCombat.enemy_special_kind].toUpperCase()}</span>
                  <strong>{activeCombat.enemy_special_name || enemySpecialLabels[activeCombat.enemy_special_kind]}</strong>
                  <p>
                    Противник уже начал подготовку. На следующем его действии способность сработает, если её не сорвать оглушением.
                    {' '}{enemySpecialValueText(activeCombat)}.
                    {activeCombat.enemy_special_kind === 'attack' && activeCombat.enemy_special_damage_type
                      ? ' Тип урона: ' + damageTypeLabels[activeCombat.enemy_special_damage_type] + '.'
                      : ''}
                  </p>
                  <small>
                    {activeCombat.enemy_special_kind === 'attack'
                      ? 'Подготовка уже видна в истории боя: защита сейчас уменьшит удар.'
                      : 'Это не атака: обычная защита не отменит эффект. Можно атаковать, оглушить врага или принять решение по ситуации.'}
                  </small>
                </div>
              )}

              <div className="combat-actions">
                <button
                  className="autobattle-button"
                  type="button"
                  disabled={busy}
                  onClick={() => void runCombatAutobattle()}
                >
                  {busy ? 'Автобой…' : 'Автобой'}
                </button>

                <button
                  className="style-autobattle-button compact"
                  type="button"
                  disabled={busy || !normalStyleReady}
                  title={normalStyleReady ? 'Повторяет твой изученный стиль в этом бою.' : 'Стиль ещё изучается на ручных боях.'}
                  onClick={() => void runCombatStyleAutobattle()}
                >
                  Играть как я
                </button>

                <button
                  className="primary-button"
                  type="button"
                  disabled={busy}
                  onClick={() => void performCombatAction('physical')}
                >
                  Физическая · {damageTypeLabels[activeCombat.player_physical_damage_type]}
                </button>

                <button
                  className="primary-button"
                  type="button"
                  disabled={busy}
                  onClick={() => void performCombatAction('magic')}
                >
                  Магическая · {damageTypeLabels[activeCombat.player_magic_damage_type]}
                </button>
                <button
                  className="ghost-button"
                  type="button"
                  disabled={busy}
                  title="Снижает урон этого хода. Если удар реально заблокирован, следующая физическая атака получает +25–50% урона."
                  onClick={() => void performCombatAction('guard')}
                >
                  Защита
                </button>
                <button
                  className="ghost-button danger-button"
                  type="button"
                  disabled={busy}
                  onClick={() => void leaveDungeon(activeDungeon.active_run_id!)}
                >
                  Отступить
                </button>
              </div>

              <div className="combat-guard-help">
                <strong>Защита в соло:</strong> уменьшает входящий урон и, если враг действительно пробил по тебе,
                подготавливает <b>только физическую</b> контратаку. Магия и заклинания бонус не получают.
              </div>

              {message && (
                <p className="form-message combat-action-message" aria-live="polite">
                  {message}
                </p>
              )}

              {(spells.length > 0 || combatScrolls.length > 0 || combatConsumables.length > 0) && (
                <div className="combat-special-actions">
                  {spells.length > 0 && (
                    <div className="combat-spell-section">
                      <div className="combat-special-heading">
                        <strong>Изученные заклинания</strong>
                        <span>расходуют ману</span>
                      </div>
                      <div className="combat-spell-grid">
                        {spells.map((spell) => (
                            <button
                              className="spell-action-button"
                              type="button"
                              key={spell.id}
                              disabled={
                                busy
                                || activeCombat.player_mana_current < spell.mana_cost
                                || (spell.spell_kind === 'heal' && activeCombat.player_hp_current >= activeCombat.player_hp_max)
                              }
                              onClick={() => void castSpell(spell)}
                            >
                              <strong>{spell.name}</strong>
                              <span>
                                {spellKindLabel(spell)}
                                {' · '}{spell.mana_cost} маны
                                {spell.status_effect_type
                                  ? ' · ' + statusEffectLabels[spell.status_effect_type] + ' ' + spell.status_effect_chance + '%'
                                  : ''}
                              </span>
                            </button>
                          ))}
                      </div>
                    </div>
                  )}

                  {combatScrolls.length > 0 && (
                    <div className="combat-spell-section">
                      <div className="combat-special-heading">
                        <strong>Боевые свитки</strong>
                        <span>одноразовые · без маны</span>
                      </div>
                      <div className="combat-spell-grid">
                        {combatScrolls.map((scroll) => {
                          const definition = normalizeCombatScrollDefinition(scroll.item_definitions)
                          if (!definition) return null

                          return (
                            <button
                              className="spell-action-button scroll"
                              type="button"
                              key={scroll.id}
                              disabled={busy}
                              onClick={() => void castScroll(scroll)}
                            >
                              <strong>{definition.name}</strong>
                              <span>×{scroll.quantity} · одно применение</span>
                            </button>
                          )
                        })}
                      </div>
                    </div>
                  )}

                  {combatConsumables.length > 0 && (
                    <div className="combat-spell-section">
                      <div className="combat-special-heading">
                        <strong>Зелья и расходники</strong>
                        <span>использование занимает ход</span>
                      </div>
                      <div className="combat-spell-grid">
                        {combatConsumables.map((item) => {
                          const definition = normalizeCombatScrollDefinition(item.item_definitions)
                          if (!definition) return null
                          const resources = combatResourceAmounts(item.item_definitions)
                          const noUsefulHeal = resources.heal <= 0 || activeCombat.player_hp_current >= activeCombat.player_hp_max
                          const noUsefulMana = resources.mana <= 0 || activeCombat.player_mana_current >= activeCombat.player_mana_max
                          const disabled = busy || (noUsefulHeal && noUsefulMana)

                          return (
                            <button
                              className="spell-action-button consumable"
                              type="button"
                              key={item.id}
                              disabled={disabled}
                              onClick={() => void useCombatConsumable(item)}
                            >
                              <strong>{definition.name}</strong>
                              <span>
                                ×{item.quantity}
                                {resources.heal > 0 ? ' · +' + resources.heal + ' HP' : ''}
                                {resources.mana > 0 ? ' · +' + resources.mana + ' MP' : ''}
                              </span>
                            </button>
                          )
                        })}
                      </div>
                    </div>
                  )}
                </div>
              )}

              <div className="combat-log">
                {turns.map((turn) => (
                  <div className={'combat-log-row ' + turn.actor} key={turn.id}>
                    <span>{turn.actor === 'player' ? 'Ты' : turn.actor === 'enemy' ? 'Противник' : 'Система'}</span>
                    <p>{turn.message}</p>
                  </div>
                ))}
              </div>
            </div>
          )}
        </article>
      )}

      {!activeCombat && latestCombat && latestCombat.status !== 'active' && (
        <article className="panel combat-result-panel">
          <div>
            <span className="eyebrow">
              {latestCombat.status === 'victory'
                ? latestCombat.is_boss
                  ? 'ПОДЗЕМЕЛЬЕ ЗАЧИЩЕНО'
                  : `ЗАЛ ${latestCombat.room_index} ОЧИЩЕН`
                : latestCombat.status === 'defeat'
                  ? 'ПОРАЖЕНИЕ'
                  : 'БОЙ ПРЕКРАЩЁН'}
            </span>
            <h3>{latestCombat.enemy_name}</h3>
            <p className="muted">
              {latestCombat.status === 'victory'
                ? latestCombatSite?.run_status === 'completed'
                  ? `Полная зачистка завершена. Получено ${latestCombatSite.run_reward_gold ?? 0} золота и ${latestCombatSite.run_reward_experience ?? 0} опыта.`
                  : 'Противник повержен. Можно перейти к следующему залу.'
                : latestCombat.status === 'defeat'
                  ? 'Персонаж отступил из подземелья и остался с 1 HP.'
                  : 'Прохождение было прервано.'}
            </p>
          </div>
          <span className="badge">
            {latestCombat.status === 'victory'
              ? latestCombatSite?.run_status === 'completed'
                ? 'зачищено'
                : 'зал очищен'
              : latestCombat.status}
          </span>

          {lootDrops.length > 0 && (
            <div className="dungeon-loot-block result">
              <div className="combat-special-heading">
                <strong>Полученная добыча</strong>
                <span>{lootDrops.length} поз.</span>
              </div>
              <div className="dungeon-loot-grid">
                {lootDrops.map((drop) => (
                  <div className={'dungeon-loot-item rarity-' + drop.rarity} key={drop.drop_id}>
                    <div>
                      <strong>{drop.item_name}</strong>
                      <span>
                        {drop.source_type === 'dungeon'
                          ? 'финальный тайник'
                          : drop.source_type === 'boss'
                            ? 'хранитель'
                            : 'враг'}
                      </span>
                    </div>
                    <b>×{drop.quantity}</b>
                  </div>
                ))}
              </div>
            </div>
          )}
        </article>
      )}

      <div className="adventure-site-grid">
        <article className="panel">
          <div className="section-heading">
            <div>
              <span className="eyebrow">РУИНЫ</span>
              <h2>Найденные руины</h2>
            </div>
            <span className="badge">{ruins.length}</span>
          </div>

          <div className="adventure-site-list">
            {ruins.length === 0 && (
              <p className="muted">Руины пока не обнаружены.</p>
            )}

            {ruins.map((site) => (
              <div className="adventure-site-row" key={'ruins-' + site.sector_id}>
                <div>
                  <strong>{site.title}</strong>
                  <span>сектор #{site.sector_id}</span>
                </div>
                <span className={'badge ' + (site.site_status === 'explored' || site.site_status === 'cleared' ? 'ready' : '')}>
                  {site.site_status === 'cleared'
                    ? 'зачищено'
                    : site.site_status === 'explored'
                      ? 'исследовано'
                      : 'требует исследования'}
                </span>
              </div>
            ))}
          </div>
        </article>

        <article className="panel">
          <div className="section-heading">
            <div>
              <span className="eyebrow">ПОДЗЕМЕЛЬЯ</span>
              <h2>Найденные входы</h2>
            </div>
            <span className="badge">{dungeons.length}</span>
          </div>

          <div className="adventure-site-list">
            {dungeons.length === 0 && (
              <p className="muted">Подземелья пока не обнаружены.</p>
            )}

            {dungeons.map((site) => {
              const scouted = site.site_status === 'scouted' || site.site_status === 'cleared'
              const active = site.run_status === 'active'

              return (
                <div className="adventure-site-row dungeon-row" key={'dungeon-' + site.sector_id}>
                  <div>
                    <strong>{site.title}</strong>
                    <span>сектор #{site.sector_id}</span>
                  </div>

                  <div className="adventure-site-actions">
                    <span className={'badge ' + (scouted ? 'ready' : '')}>
                      {site.site_status === 'cleared'
                        ? 'зачищено'
                        : scouted
                          ? 'вход разведан'
                          : 'вход не разведан'}
                    </span>

                    {scouted && !active && !activeDungeon && (
                      <button
                        className="primary-button"
                        type="button"
                        disabled={busy}
                        onClick={() => void startDungeon(site)}
                      >
                        {site.site_status === 'cleared' ? 'Пройти снова' : 'Войти'}
                      </button>
                    )}

                    {active && (
                      <span className="badge">
                        {(site.run_rooms_cleared ?? 0)} / {(site.run_total_rooms ?? 0)}
                      </span>
                    )}
                  </div>
                </div>
              )
            })}
          </div>
        </article>
      </div>
    </section>
  )
}
