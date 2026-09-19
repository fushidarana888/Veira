import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type {
  DamageType,
  EquipmentAffix,
  GmCraftingRecipe,
  ItemCategory,
  ItemDefinition,
  ItemEquipGroup,
} from '../types'

const rarityRankLabels: Record<number, string> = {
  1: 'Обычный',
  2: 'Необычный',
  3: 'Редкий',
  4: 'Эпический',
  5: 'Легендарный',
  6: 'Уникальный',
}

const statKeys = ['strength', 'agility', 'intellect', 'vitality', 'luck'] as const
const statLabels: Record<(typeof statKeys)[number], string> = {
  strength: 'Сила',
  agility: 'Ловкость',
  intellect: 'Интеллект',
  vitality: 'Живучесть',
  luck: 'Удача',
}

const damageTypes: DamageType[] = [
  'slashing', 'piercing', 'blunt',
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

type RecipeDraft = {
  id: string | null
  slug: string
  name: string
  description: string
  enabled: boolean
  required_level: number
  gold_cost: number
  output_item_definition_id: string
  output_quantity: number
  affix_bonus: number
  sort_order: number
  ingredients: Array<{ item_definition_id: string; quantity: number }>
}

type AffixDraft = {
  id: string | null
  slug: string
  name: string
  description: string
  enabled: boolean
  min_rarity_rank: number
  max_rarity_rank: number
  weight: number
  allowed_categories: Array<'weapon' | 'armor' | 'accessory'>
  allowed_equip_groups: ItemEquipGroup[]
  stat_modifiers: Record<string, number>
  damage_resistances: Partial<Record<DamageType, number>>
}

function emptyRecipe(): RecipeDraft {
  return {
    id: null,
    slug: '',
    name: '',
    description: '',
    enabled: true,
    required_level: 1,
    gold_cost: 0,
    output_item_definition_id: '',
    output_quantity: 1,
    affix_bonus: 0,
    sort_order: 100,
    ingredients: [],
  }
}

function emptyAffix(): AffixDraft {
  return {
    id: null,
    slug: '',
    name: '',
    description: '',
    enabled: true,
    min_rarity_rank: 2,
    max_rarity_rank: 5,
    weight: 100,
    allowed_categories: ['weapon', 'armor', 'accessory'],
    allowed_equip_groups: [],
    stat_modifiers: {},
    damage_resistances: {},
  }
}

export function GmCraftingEditor() {
  const [section, setSection] = useState<'recipes' | 'affixes'>('recipes')
  const [recipes, setRecipes] = useState<GmCraftingRecipe[]>([])
  const [affixes, setAffixes] = useState<EquipmentAffix[]>([])
  const [items, setItems] = useState<ItemDefinition[]>([])
  const [recipe, setRecipe] = useState<RecipeDraft>(emptyRecipe)
  const [affix, setAffix] = useState<AffixDraft>(emptyAffix)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')

  async function loadData() {
    const [recipeResult, affixResult, itemResult] = await Promise.all([
      supabase.rpc('get_gm_crafting_recipes'),
      supabase.rpc('get_gm_equipment_affixes'),
      supabase.rpc('get_gm_item_definitions'),
    ])

    const error = recipeResult.error ?? affixResult.error ?? itemResult.error
    if (error) {
      setMessage(error.message)
      return
    }

    setRecipes((recipeResult.data as GmCraftingRecipe[] | null) ?? [])
    setAffixes((affixResult.data as EquipmentAffix[] | null) ?? [])
    setItems((itemResult.data as ItemDefinition[] | null) ?? [])
  }

  useEffect(() => {
    void loadData()
  }, [])

  function editRecipe(value: GmCraftingRecipe) {
    setRecipe({
      id: value.id,
      slug: value.slug,
      name: value.name,
      description: value.description,
      enabled: value.enabled,
      required_level: value.required_level,
      gold_cost: value.gold_cost,
      output_item_definition_id: value.output_item_definition_id,
      output_quantity: value.output_quantity,
      affix_bonus: value.affix_bonus,
      sort_order: value.sort_order,
      ingredients: value.ingredients.map((entry) => ({
        item_definition_id: entry.item_definition_id,
        quantity: entry.quantity,
      })),
    })
    setMessage('')
  }

  function editAffix(value: EquipmentAffix) {
    setAffix({
      id: value.id,
      slug: value.slug,
      name: value.name,
      description: value.description,
      enabled: value.enabled,
      min_rarity_rank: value.min_rarity_rank,
      max_rarity_rank: value.max_rarity_rank,
      weight: value.weight,
      allowed_categories: value.allowed_categories,
      allowed_equip_groups: value.allowed_equip_groups,
      stat_modifiers: value.stat_modifiers ?? {},
      damage_resistances: value.damage_resistances ?? {},
    })
    setMessage('')
  }

  async function saveRecipe() {
    if (!recipe.output_item_definition_id) {
      setMessage('Выбери результат рецепта.')
      return
    }

    setBusy(true)
    setMessage('')

    const { data, error } = await supabase.rpc('gm_save_crafting_recipe', {
      p_id: recipe.id,
      p_slug: recipe.slug.trim(),
      p_name: recipe.name.trim(),
      p_description: recipe.description,
      p_enabled: recipe.enabled,
      p_required_level: recipe.required_level,
      p_gold_cost: recipe.gold_cost,
      p_output_item_definition_id: recipe.output_item_definition_id,
      p_output_quantity: recipe.output_quantity,
      p_affix_bonus: recipe.affix_bonus,
      p_sort_order: recipe.sort_order,
      p_ingredients: recipe.ingredients,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    await loadData()
    if (!recipe.id && data) setRecipe({ ...recipe, id: String(data) })
    setMessage(recipe.id ? 'Рецепт обновлён.' : 'Рецепт создан.')
    setBusy(false)
  }

  async function deleteRecipe() {
    if (!recipe.id) return
    if (!window.confirm(`Удалить рецепт «${recipe.name}»?`)) return

    setBusy(true)
    const { error } = await supabase.rpc('gm_delete_crafting_recipe', { p_id: recipe.id })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    setRecipe(emptyRecipe())
    await loadData()
    setMessage('Рецепт удалён.')
    setBusy(false)
  }

  async function saveAffix() {
    setBusy(true)
    setMessage('')

    const { data, error } = await supabase.rpc('gm_save_equipment_affix', {
      p_id: affix.id,
      p_slug: affix.slug.trim(),
      p_name: affix.name.trim(),
      p_description: affix.description,
      p_enabled: affix.enabled,
      p_min_rarity_rank: affix.min_rarity_rank,
      p_max_rarity_rank: affix.max_rarity_rank,
      p_weight: affix.weight,
      p_allowed_categories: affix.allowed_categories,
      p_allowed_equip_groups: affix.allowed_equip_groups,
      p_stat_modifiers: affix.stat_modifiers,
      p_damage_resistances: affix.damage_resistances,
    })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    await loadData()
    if (!affix.id && data) setAffix({ ...affix, id: String(data) })
    setMessage(affix.id ? 'Аффикс обновлён.' : 'Аффикс создан.')
    setBusy(false)
  }

  async function deleteAffix() {
    if (!affix.id) return
    if (!window.confirm(`Удалить аффикс «${affix.name}»?`)) return

    setBusy(true)
    const { error } = await supabase.rpc('gm_delete_equipment_affix', { p_id: affix.id })

    if (error) {
      setMessage(error.message)
      setBusy(false)
      return
    }

    setAffix(emptyAffix())
    await loadData()
    setMessage('Аффикс удалён.')
    setBusy(false)
  }

  function setRecipeIngredient(index: number, patch: Partial<RecipeDraft['ingredients'][number]>) {
    const next = recipe.ingredients.map((entry, i) => i === index ? { ...entry, ...patch } : entry)
    setRecipe({ ...recipe, ingredients: next })
  }

  function setAffixStat(key: string, value: number) {
    const next = { ...affix.stat_modifiers }
    if (value === 0) delete next[key]
    else next[key] = value
    setAffix({ ...affix, stat_modifiers: next })
  }

  function setAffixResistance(type: DamageType, value: number) {
    const next = { ...affix.damage_resistances }
    if (value === 0) delete next[type]
    else next[type] = value
    setAffix({ ...affix, damage_resistances: next })
  }

  function toggleCategory(category: 'weapon' | 'armor' | 'accessory') {
    setAffix({
      ...affix,
      allowed_categories: affix.allowed_categories.includes(category)
        ? affix.allowed_categories.filter((value) => value !== category)
        : [...affix.allowed_categories, category],
    })
  }

  return (
    <section className="gm-crafting-editor">
      <article className="panel">
        <div className="section-heading">
          <div>
            <span className="eyebrow">РЕМЕСЛО</span>
            <h2>Рецепты и аффиксы</h2>
          </div>
          <div className="gm-editor-switch">
            <button type="button" className={section === 'recipes' ? 'active' : ''} onClick={() => setSection('recipes')}>
              Рецепты · {recipes.length}
            </button>
            <button type="button" className={section === 'affixes' ? 'active' : ''} onClick={() => setSection('affixes')}>
              Аффиксы · {affixes.length}
            </button>
          </div>
        </div>
        {message && <p className="gm-notice" aria-live="polite">{message}</p>}
      </article>

      {section === 'recipes' ? (
        <div className="gm-content-layout">
          <aside className="panel gm-content-list">
            <button className="primary-button" type="button" onClick={() => setRecipe(emptyRecipe())}>
              + Новый рецепт
            </button>
            {recipes.map((value) => (
              <button type="button" key={value.id} className={recipe.id === value.id ? 'active' : ''} onClick={() => editRecipe(value)}>
                <span>{value.name}</span>
                <small>{value.output_item_name} · ур. {value.required_level}</small>
              </button>
            ))}
          </aside>

          <article className="panel gm-content-form">
            <div className="section-heading">
              <div>
                <span className="eyebrow">РЕЦЕПТ</span>
                <h2>{recipe.id ? recipe.name || 'Редактирование' : 'Новый рецепт'}</h2>
              </div>
              <label className="gm-inline-check">
                <input type="checkbox" checked={recipe.enabled} onChange={(e) => setRecipe({ ...recipe, enabled: e.target.checked })} />
                <span>Включён</span>
              </label>
            </div>

            <div className="gm-form-grid two">
              <label><span>Название</span><input value={recipe.name} onChange={(e) => setRecipe({ ...recipe, name: e.target.value })} /></label>
              <label><span>Slug</span><input value={recipe.slug} onChange={(e) => setRecipe({ ...recipe, slug: e.target.value })} /></label>
            </div>
            <label><span>Описание</span><textarea rows={3} value={recipe.description} onChange={(e) => setRecipe({ ...recipe, description: e.target.value })} /></label>

            <div className="gm-form-grid four">
              <label><span>Уровень</span><input type="number" min={1} value={recipe.required_level} onChange={(e) => setRecipe({ ...recipe, required_level: Math.max(1, Number(e.target.value)) })} /></label>
              <label><span>Золото</span><input type="number" min={0} value={recipe.gold_cost} onChange={(e) => setRecipe({ ...recipe, gold_cost: Math.max(0, Number(e.target.value)) })} /></label>
              <label><span>Количество</span><input type="number" min={1} max={999} value={recipe.output_quantity} onChange={(e) => setRecipe({ ...recipe, output_quantity: Math.max(1, Number(e.target.value)) })} /></label>
              <label><span>Бонус аффиксов</span><input type="number" min={0} max={3} value={recipe.affix_bonus} onChange={(e) => setRecipe({ ...recipe, affix_bonus: Math.max(0, Math.min(3, Number(e.target.value))) })} /></label>
            </div>

            <label>
              <span>Результат</span>
              <select value={recipe.output_item_definition_id} onChange={(e) => setRecipe({ ...recipe, output_item_definition_id: e.target.value })}>
                <option value="">Выбрать предмет</option>
                {items.map((item) => <option key={item.id} value={item.id}>{item.name} · {item.rarity}</option>)}
              </select>
            </label>

            <div className="gm-editor-box">
              <div>
                <strong>Ингредиенты</strong>
                <button className="ghost-button" type="button" onClick={() => setRecipe({ ...recipe, ingredients: [...recipe.ingredients, { item_definition_id: '', quantity: 1 }] })}>
                  + Ингредиент
                </button>
              </div>

              <div className="recipe-ingredient-editor">
                {recipe.ingredients.map((entry, index) => (
                  <div className="recipe-ingredient-row" key={index}>
                    <select value={entry.item_definition_id} onChange={(e) => setRecipeIngredient(index, { item_definition_id: e.target.value })}>
                      <option value="">Выбрать</option>
                      {items.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}
                    </select>
                    <input type="number" min={1} max={999} value={entry.quantity} onChange={(e) => setRecipeIngredient(index, { quantity: Math.max(1, Number(e.target.value)) })} />
                    <button className="ghost-button danger-button" type="button" onClick={() => setRecipe({ ...recipe, ingredients: recipe.ingredients.filter((_, i) => i !== index) })}>
                      ×
                    </button>
                  </div>
                ))}
              </div>
            </div>

            <div className="gm-form-actions">
              <button className="primary-button" type="button" disabled={busy} onClick={() => void saveRecipe()}>
                {busy ? 'Сохраняем…' : recipe.id ? 'Сохранить рецепт' : 'Создать рецепт'}
              </button>
              {recipe.id && <button className="ghost-button danger-button" type="button" disabled={busy} onClick={() => void deleteRecipe()}>Удалить</button>}
            </div>
          </article>
        </div>
      ) : (
        <div className="gm-content-layout">
          <aside className="panel gm-content-list">
            <button className="primary-button" type="button" onClick={() => setAffix(emptyAffix())}>
              + Новый аффикс
            </button>
            {affixes.map((value) => (
              <button type="button" key={value.id} className={affix.id === value.id ? 'active' : ''} onClick={() => editAffix(value)}>
                <span>{value.name}</span>
                <small>{rarityRankLabels[value.min_rarity_rank]}–{rarityRankLabels[value.max_rarity_rank]} · вес {value.weight}</small>
              </button>
            ))}
          </aside>

          <article className="panel gm-content-form">
            <div className="section-heading">
              <div>
                <span className="eyebrow">АФФИКС</span>
                <h2>{affix.id ? affix.name || 'Редактирование' : 'Новый аффикс'}</h2>
              </div>
              <label className="gm-inline-check">
                <input type="checkbox" checked={affix.enabled} onChange={(e) => setAffix({ ...affix, enabled: e.target.checked })} />
                <span>Включён</span>
              </label>
            </div>

            <div className="gm-form-grid two">
              <label><span>Название</span><input value={affix.name} onChange={(e) => setAffix({ ...affix, name: e.target.value })} /></label>
              <label><span>Slug</span><input value={affix.slug} onChange={(e) => setAffix({ ...affix, slug: e.target.value })} /></label>
            </div>
            <label><span>Описание</span><textarea rows={3} value={affix.description} onChange={(e) => setAffix({ ...affix, description: e.target.value })} /></label>

            <div className="gm-form-grid three">
              <label>
                <span>Мин. редкость</span>
                <select value={affix.min_rarity_rank} onChange={(e) => setAffix({ ...affix, min_rarity_rank: Number(e.target.value) })}>
                  {[1,2,3,4,5,6].map((rank) => <option key={rank} value={rank}>{rarityRankLabels[rank]}</option>)}
                </select>
              </label>
              <label>
                <span>Макс. редкость</span>
                <select value={affix.max_rarity_rank} onChange={(e) => setAffix({ ...affix, max_rarity_rank: Number(e.target.value) })}>
                  {[1,2,3,4,5,6].map((rank) => <option key={rank} value={rank}>{rarityRankLabels[rank]}</option>)}
                </select>
              </label>
              <label><span>Вес выпадения</span><input type="number" min={1} value={affix.weight} onChange={(e) => setAffix({ ...affix, weight: Math.max(1, Number(e.target.value)) })} /></label>
            </div>

            <div className="gm-check-strip">
              {(['weapon','armor','accessory'] as const).map((category) => (
                <label key={category}>
                  <input type="checkbox" checked={affix.allowed_categories.includes(category)} onChange={() => toggleCategory(category)} />
                  <span>{category === 'weapon' ? 'Оружие' : category === 'armor' ? 'Броня' : 'Аксессуары'}</span>
                </label>
              ))}
            </div>

            <div className="gm-editor-box">
              <strong>Характеристики</strong>
              <div className="gm-form-grid five">
                {statKeys.map((key) => (
                  <label key={key}>
                    <span>{statLabels[key]}</span>
                    <input type="number" min={-99} max={99} value={affix.stat_modifiers[key] ?? 0} onChange={(e) => setAffixStat(key, Number(e.target.value))} />
                  </label>
                ))}
              </div>
            </div>

            <div className="gm-editor-box">
              <strong>Сопротивления</strong>
              <div className="gm-form-grid three">
                {damageTypes.map((type) => (
                  <label key={type}>
                    <span>{damageLabels[type]}</span>
                    <input type="number" min={-75} max={75} value={affix.damage_resistances[type] ?? 0} onChange={(e) => setAffixResistance(type, Number(e.target.value))} />
                  </label>
                ))}
              </div>
            </div>

            <div className="gm-form-actions">
              <button className="primary-button" type="button" disabled={busy} onClick={() => void saveAffix()}>
                {busy ? 'Сохраняем…' : affix.id ? 'Сохранить аффикс' : 'Создать аффикс'}
              </button>
              {affix.id && <button className="ghost-button danger-button" type="button" disabled={busy} onClick={() => void deleteAffix()}>Удалить</button>}
            </div>
          </article>
        </div>
      )}
    </section>
  )
}
