import { userFacingError } from '../lib/userError'
import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { CharacterCraftingRecipe, CharacterProgress, ItemRarity } from '../types'

type Props = {
  characterId: string
  progress: CharacterProgress
  onProgressChanged?: () => Promise<unknown> | void
  onInventoryChanged?: () => Promise<unknown> | void
}

const rarityLabels: Record<ItemRarity, string> = {
  common: 'Обычный',
  uncommon: 'Необычный',
  rare: 'Редкий',
  epic: 'Эпический',
  legendary: 'Легендарный',
  unique: 'Уникальный',
}

export function CraftingPanel({
  characterId,
  progress,
  onProgressChanged,
  onInventoryChanged,
}: Props) {
  const [recipes, setRecipes] = useState<CharacterCraftingRecipe[]>([])
  const [busyRecipe, setBusyRecipe] = useState<string | null>(null)
  const [message, setMessage] = useState('')
  const [loading, setLoading] = useState(true)

  async function loadRecipes() {
    setLoading(true)

    const { data, error } = await supabase.rpc('get_character_crafting', {
      p_character_id: characterId,
    })

    if (error) {
      setMessage(userFacingError(error.message))
      setLoading(false)
      return
    }

    setRecipes((data as CharacterCraftingRecipe[] | null) ?? [])
    setLoading(false)
  }

  useEffect(() => {
    void loadRecipes()
  }, [characterId, progress.gold, progress.level])

  async function craft(recipe: CharacterCraftingRecipe) {
    setBusyRecipe(recipe.recipe_id)
    setMessage('')

    const { error } = await supabase.rpc('craft_recipe', {
      p_character_id: characterId,
      p_recipe_id: recipe.recipe_id,
      p_count: 1,
    })

    if (error) {
      const raw = error.message
      if (raw.includes('NOT_ENOUGH_INGREDIENTS')) {
        setMessage('Не хватает материалов.')
      } else if (raw.includes('NOT_ENOUGH_GOLD')) {
        setMessage('Не хватает золота.')
      } else if (raw.includes('LEVEL_TOO_LOW')) {
        setMessage(`Для этого рецепта нужен уровень ${recipe.required_level}.`)
      } else if (raw.includes('CHARACTER_BUSY')) {
        setMessage('Нельзя заниматься ремеслом во время другого активного действия.')
      } else {
        setMessage(userFacingError(raw))
      }
      setBusyRecipe(null)
      return
    }

    await Promise.all([
      Promise.resolve(onProgressChanged?.()),
      Promise.resolve(onInventoryChanged?.()),
    ])
    await loadRecipes()
    setMessage(`Создано: ${recipe.output_item_name} ×${recipe.output_quantity}.`)
    setBusyRecipe(null)
  }

  return (
    <section className="crafting-section">
      <article className="panel crafting-header">
        <div>
          <span className="eyebrow">РЕМЕСЛО</span>
          <h2>Крафт</h2>
          <p className="muted">
            Материалы из подземелий можно превращать в расходники и снаряжение. Экипировка, созданная по рецептам, может получать аффиксы в зависимости от своей редкости.
          </p>
        </div>

        <div className="crafting-wallet">
          <span>Золото</span>
          <strong>{progress.gold}</strong>
        </div>
      </article>

      {message && <p className="form-message" aria-live="polite">{message}</p>}

      {loading ? (
        <article className="panel"><p className="muted">Загружаем рецепты…</p></article>
      ) : recipes.length === 0 ? (
        <article className="panel"><p className="muted">Рецептов пока нет.</p></article>
      ) : (
        <div className="crafting-grid">
          {recipes.map((recipe) => (
            <article
              className={'panel crafting-card rarity-' + recipe.output_rarity}
              key={recipe.recipe_id}
            >
              <div className="crafting-card-head">
                <div>
                  <span className="eyebrow">УР. {recipe.required_level}</span>
                  <h3>{recipe.name}</h3>
                </div>
                <span className={'rarity-label rarity-text-' + recipe.output_rarity}>
                  {rarityLabels[recipe.output_rarity]}
                </span>
              </div>

              <p>{recipe.description}</p>

              <div className="crafting-output">
                <span>Результат</span>
                <strong>{recipe.output_item_name} ×{recipe.output_quantity}</strong>
              </div>

              <div className="crafting-ingredients">
                {recipe.ingredients.map((ingredient) => {
                  const enough = ingredient.owned_quantity >= ingredient.required_quantity

                  return (
                    <div className={enough ? 'ready' : 'missing'} key={ingredient.item_definition_id}>
                      <span>{ingredient.name}</span>
                      <strong>
                        {ingredient.owned_quantity} / {ingredient.required_quantity}
                      </strong>
                    </div>
                  )
                })}
              </div>

              {recipe.affix_bonus > 0 && (
                <div className="crafting-affix-note">
                  Мастерская обработка: +{recipe.affix_bonus} дополнительный аффикс
                </div>
              )}

              <div className="crafting-card-actions">
                <span className={recipe.can_afford_gold ? '' : 'missing-gold'}>
                  {recipe.gold_cost} золота
                </span>
                <button
                  className="primary-button"
                  type="button"
                  disabled={!recipe.can_craft || busyRecipe !== null}
                  onClick={() => void craft(recipe)}
                >
                  {busyRecipe === recipe.recipe_id ? 'Создаём…' : 'Создать'}
                </button>
              </div>
            </article>
          ))}
        </div>
      )}
    </section>
  )
}
