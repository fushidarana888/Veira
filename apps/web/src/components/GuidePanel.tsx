import { useEffect, useMemo, useState } from 'react'
import { supabase } from '../lib/supabase'

type GuideSection =
  | 'start'
  | 'races'
  | 'mechanics'
  | 'weapons'
  | 'armor'
  | 'accessories'
  | 'spells'
  | 'effects'
  | 'passives'
  | 'affixes'
  | 'blacksmith'
  | 'dungeons'

type GuideItem = {
  id: string
  slug: string
  name: string
  description: string
  category: 'weapon' | 'armor' | 'accessory'
  rarity: 'common' | 'uncommon' | 'rare' | 'epic' | 'legendary' | 'unique'
  equip_group: string | null
  stat_modifiers: Record<string, number>
  required_level: number
  shop_tier: number
  shop_price: number
  damage_type: string | null
  damage_resistances: Record<string, number>
  damage_bonuses: Record<string, number>
  weapon_base_damage: number
  weapon_scaling: 'strength' | 'agility' | 'hybrid' | null
  weapon_family: string | null
  bow_full_draw_armor_penetration_percent: number
  bloodshed_chance_percent: number
  echo_strike_chance_percent: number
  unique_property_name: string | null
  unique_property_description: string
  unique_effect_type: string | null
  unique_effect_value: number
}

type GuideMagicFamily = {
  slug: string
  name: string
  kind: 'element' | 'school' | 'function'
  description: string
  spell_count: number
}

type GuideRaceTrait = {
  name: string
  type: string
  value?: number
  description: string
  damage_type?: string
  threshold?: number
  families?: string[]
  effect_type?: string
}

type GuideRace = {
  id: string
  slug: string
  name: string
  category: string
  description: string
  stat_modifiers: Record<string, number>
  traits: GuideRaceTrait[]
  innate_magic_damage_type: string | null
  hp_bonus: number
  mana_bonus: number
  hp_regen_per_hour: number
  mana_regen_per_hour: number
  damage_resistances: Record<string, number>
  passive_type: string | null
  passive_value: number
  passive_name: string | null
  passive_description: string
}

type GuideSpell = {
  id: string
  slug: string
  name: string
  description: string
  spell_kind: string
  damage_type: string | null
  mana_cost: number
  required_level: number
  power_multiplier: number
  flat_power: number
  status_effect_type: string | null
  status_effect_chance: number
  status_effect_turns: number
  status_effect_potency: number
  support_effect_type: string | null
  support_value: number
  support_turns: number
  families: Array<Pick<GuideMagicFamily, 'slug' | 'name' | 'kind'>>
}

type GuideAffix = {
  id: string
  slug: string
  name: string
  description: string
  min_rarity_rank: number
  max_rarity_rank: number
  allowed_categories: string[]
  allowed_equip_groups: string[]
  stat_modifiers: Record<string, number>
  damage_resistances: Record<string, number>
  unique_effect_type: string | null
  unique_effect_value: number
}

type GuideMechanics = {
  enhancement_percent_per_level: number
  enhancement_max: number
  awakening_max: number
  critical_cap_percent: number
  physical_critical_multiplier: number
  magic_critical_multiplier: number
  loot_quality_luck_relative_percent_per_point: number
  affix_slots: Record<string, number>
}

type GuideCatalog = {
  items: GuideItem[]
  spells: GuideSpell[]
  magic_families: GuideMagicFamily[]
  races: GuideRace[]
  affixes: GuideAffix[]
  mechanics: GuideMechanics
}

type Props = {
  onBack: () => void
}

const sections: Array<{ id: GuideSection; label: string; description: string }> = [
  { id: 'start', label: 'Начало', description: 'Карта всего справочника' },
  { id: 'races', label: 'Расы', description: 'Все игровые расы и их особенности' },
  { id: 'mechanics', label: 'Основы', description: 'Характеристики, урон и крит' },
  { id: 'weapons', label: 'Оружие', description: 'Семейства и весь каталог' },
  { id: 'armor', label: 'Броня', description: 'Броня, защиты и свойства' },
  { id: 'accessories', label: 'Аксессуары', description: 'Талисманы и дополнительные эффекты' },
  { id: 'spells', label: 'Заклинания', description: 'Все доступные заклинания' },
  { id: 'effects', label: 'Баффы и дебаффы', description: 'Боевые статусы по раундам' },
  { id: 'passives', label: 'Пассивные эффекты', description: 'Эхо, Кровопролитие и другие пассивки' },
  { id: 'affixes', label: 'Аффиксы', description: 'Случайные свойства экипировки' },
  { id: 'blacksmith', label: 'Кузница', description: 'Заточка и пробуждение' },
  { id: 'dungeons', label: 'Подземелья', description: 'Награды, циклы и пати' },
]

const rarityLabels: Record<string, string> = {
  common: 'Обычный',
  uncommon: 'Необычный',
  rare: 'Редкий',
  epic: 'Эпический',
  legendary: 'Легендарный',
  unique: 'Уникальный',
}

const rarityByRank: Record<number, string> = {
  1: 'Обычный',
  2: 'Необычный',
  3: 'Редкий',
  4: 'Эпический',
  5: 'Легендарный / уникальный',
}

const damageLabels: Record<string, string> = {
  slashing: 'режущий',
  piercing: 'колющий',
  blunt: 'дробящий',
  fire: 'огонь',
  water: 'вода',
  earth: 'земля',
  air: 'воздух',
  lightning: 'молния',
  ice: 'лёд',
  arcane: 'арканный',
  star: 'звёздный',
  gravity: 'гравитационный',
  moon: 'лунный',
}

const statLabels: Record<string, string> = {
  strength: 'Сила',
  agility: 'Ловкость',
  intellect: 'Интеллект',
  vitality: 'Живучесть',
  luck: 'Удача',
  max_hp_percent: 'Макс. ОЗ',
  defense_percent: 'Защита',
}

const effectLabels: Record<string, string> = {
  lifesteal: 'Вампиризм',
  mana_on_hit: 'Мана за попадание',
  damage_vs_wounded: 'Урон по раненым',
  guard_boost: 'Усиление защиты',
  physical_damage_bonus: 'Физический урон',
  magic_damage_bonus: 'Магический урон',
  all_damage_bonus: 'Весь прямой урон',
  low_hp_damage_reduction: 'Снижение урона при низком ОЗ',
  boss_damage_bonus: 'Урон боссам',
}

const scalingLabels: Record<string, string> = {
  strength: 'Силовое · СИЛ ×3 + ЛОВ ×0,5',
  agility: 'Ловкостное · ЛОВ ×3 + СИЛ ×0,5',
  hybrid: 'Гибридное · СИЛ ×1,75 + ЛОВ ×1,75',
}

const familyLabels: Record<string, string> = {
  short_bow: 'Короткий лук',
  long_bow: 'Длинный лук',
  dagger: 'Кинжал',
  rapier: 'Рапира',
  sword: 'Меч',
  blade: 'Клинок',
  katana: 'Катана',
  spear: 'Копьё',
  axe: 'Топор',
  battleaxe: 'Секира',
  mace: 'Булава',
  hammer: 'Молот',
  club: 'Дубина',
  greatsword: 'Двуручный меч',
  staff: 'Боевой посох',
  wand: 'Магический жезл',
}

const familyMechanics: Array<{ family: string; title: string; text: string }> = [
  {
    family: 'short_bow',
    title: 'Короткий лук',
    text: 'Может быстро стрелять каждый ход или готовить полный натяг. Полный натяг занимает ход подготовки, а следующий выстрел получает усиленный урон и пробитие брони.',
  },
  {
    family: 'long_bow',
    title: 'Длинный лук',
    text: 'Стреляет через полный натяг: ход подготовки, затем усиленный выстрел. Вклад Силы у длинных луков заметнее, чем у коротких.',
  },
  {
    family: 'dagger',
    title: 'Кинжал',
    text: 'После расчёта защиты итог обычного физического удара умножается на ×0,80. Сильные кинжалы компенсируют это особыми механиками вроде Эха или Разрыва.',
  },
  {
    family: 'rapier',
    title: 'Рапира',
    text: 'Перед расчётом физического урона эффективная физическая защита цели уменьшается на 10%.',
  },
  {
    family: 'sword',
    title: 'Меч',
    text: 'У семейства нет отдельного общего скрытого эффекта: сила определяется базовым уроном, скейлингом и свойствами конкретного меча.',
  },
  {
    family: 'blade',
    title: 'Клинок',
    text: 'Получает дополнительный разброс физического урона +4.',
  },
  {
    family: 'katana',
    title: 'Катана',
    text: 'Последовательные физические атаки по одной цели дают +8% урона за стак, максимум +40%. Смена цели сбрасывает ритм.',
  },
  {
    family: 'spear',
    title: 'Копьё',
    text: 'При расчёте удара учитывает 120% физической защиты цели, зато сами копья балансируются более высокой базовой силой и особыми свойствами.',
  },
  {
    family: 'axe',
    title: 'Топор',
    text: 'Получает до +20% дополнительного физического урона в зависимости от максимального ОЗ цели: чем крупнее противник, тем сильнее бонус.',
  },
  {
    family: 'battleaxe',
    title: 'Секира',
    text: 'Использует ту же механику охоты на крупные цели, что и топор: до +20% дополнительного физического урона от максимального ОЗ врага.',
  },
  {
    family: 'mace',
    title: 'Булава',
    text: 'Физические удары могут оглушить: базово 8% в соло/дуэли и 5% в групповом бою.',
  },
  {
    family: 'hammer',
    title: 'Молот',
    text: 'Физические удары могут оглушить: базово 8% в соло/дуэли и 5% в групповом бою.',
  },
  {
    family: 'club',
    title: 'Дубина',
    text: 'Специализация на дробящем уроне: положительное сопротивление дробящему учитывается только наполовину, а уязвимость усиливается в ×1,5.',
  },
  {
    family: 'greatsword',
    title: 'Двуручный меч',
    text: 'Каждый некритический физический удар добавляет +5 п.п. к следующему шансу крита. Крит сбрасывает накопление; общий шанс крита ограничен 60%.',
  },
  {
    family: 'staff',
    title: 'Боевой посох',
    text: 'У семейства нет единой скрытой механики: характеристики боя задаются базой, скейлингом и свойствами конкретного посоха.',
  },
  {
    family: 'wand',
    title: 'Магический жезл',
    text: 'У семейства нет единой скрытой механики: основную роль играют параметры и магические свойства конкретного жезла.',
  },
]

const debuffs = [
  ['Горение', 'Периодический магический урон. Тик учитывает сопротивление огню и может критовать как магический урон.'],
  ['Кровотечение', 'Периодический физический урон. Тик учитывает соответствующую защиту от типа и может критовать как физический урон.'],
  ['Яд', 'Периодический магический урон. Срабатывает вместе с остальными DOT-эффектами в конце раунда.'],
  ['Охлаждение', 'Снижает наносимый целью урон на величину эффекта. Может суммироваться с Ослаблением, общий предел снижения — 60%.'],
  ['Ослабление', 'Снижает наносимый целью урон. Вместе с Охлаждением ограничено суммарными 60%.'],
  ['Уязвимость', 'Увеличивает входящий прямой урон цели на величину эффекта, максимум до системного лимита 75%.'],
  ['Оглушение', 'Цель пропускает действие. Булавы и молоты умеют накладывать короткое оглушение своими физическими ударами.'],
]

const buffs = [
  ['Защита', 'Уменьшает следующий полученный удар. В соло и дуэлях реально заблокированный урон может подготовить бонус следующей физической контратаки.'],
  ['Боевой фокус', 'Усиление прямого урона на ограниченное число следующих атак. Конкретная сила и длительность зависят от заклинания.'],
  ['Магический щит', 'Снижает следующий входящий удар. Эффективность может усиливаться аффиксом «Несокрушимый» и другими бонусами защиты.'],
  ['Провокация', 'В групповом бою повышает шанс, что враг выберет указанного союзника целью.'],
  ['Очищение', 'Снимает негативные боевые статусы с выбранной цели.'],
  ['Последняя жертва', 'Редкий эффект пати: пользователь становится Потерянным до конца похода, а живые союзники полностью лечатся и получают −30% входящего урона на 3 раунда.'],
]

function objectEntries(value: Record<string, number> | null | undefined) {
  return Object.entries(value ?? {}).filter(([, amount]) => Number(amount) !== 0)
}

function formatModifier(key: string, value: number) {
  const label = statLabels[key] ?? key
  const suffix = key.endsWith('_percent') ? '%' : ''
  return label + ' ' + (value >= 0 ? '+' : '') + value + suffix
}

function formatResistance(key: string, value: number) {
  return (damageLabels[key] ?? key) + ' ' + (value >= 0 ? '+' : '') + value + '%'
}

function awakeningText(item: GuideItem) {
  if (item.echo_strike_chance_percent > 0) return '+1 п.п. шанса Эха ударов за ступень'
  if (item.bloodshed_chance_percent > 0) return '+1 п.п. шанса Кровопролития за ступень'
  if (item.unique_effect_type === 'lifesteal') return '+1 п.п. вампиризма за ступень'
  if (item.unique_effect_type === 'damage_vs_wounded') return '+1 п.п. урона по раненым за ступень'
  if (item.unique_effect_type === 'mana_on_hit') return '+1 маны за попадание за ступень'
  if (item.unique_effect_type === 'guard_boost') return '+1 п.п. эффективности защиты за ступень'
  if (typeof item.stat_modifiers?.first_physical_strike_multiplier === 'number') {
    return '+0,02 к множителю бонусной части первого удара за ступень'
  }
  return '+1% физического урона оружием за ступень'
}

function matchesSearch(text: string, search: string) {
  return text.toLocaleLowerCase('ru-RU').includes(search.trim().toLocaleLowerCase('ru-RU'))
}

export function GuidePanel({ onBack }: Props) {
  const [section, setSection] = useState<GuideSection>('start')
  const [catalog, setCatalog] = useState<GuideCatalog | null>(null)
  const [loading, setLoading] = useState(true)
  const [message, setMessage] = useState('')
  const [search, setSearch] = useState('')

  async function loadGuide() {
    setLoading(true)
    setMessage('')

    const { data, error } = await supabase.rpc('get_game_guide_catalog')

    if (error) {
      setMessage(error.message)
      setLoading(false)
      return
    }

    setCatalog(data as GuideCatalog)
    setLoading(false)
  }

  useEffect(() => {
    void loadGuide()
  }, [])

  const filteredRaces = useMemo(() => {
    if (!catalog) return []
    if (!search.trim()) return catalog.races
    return catalog.races.filter((race) => matchesSearch([
      race.name,
      race.category,
      race.description,
      race.passive_name ?? '',
      race.passive_description,
      ...race.traits.map((trait) => [trait.name, trait.description].join(' ')),
    ].join(' '), search))
  }, [catalog, search])

  const filteredItems = useMemo(() => {
    if (!catalog) return []
    if (!search.trim()) return catalog.items
    return catalog.items.filter((item) => matchesSearch([
      item.name,
      item.description,
      familyLabels[item.weapon_family ?? ''] ?? '',
      rarityLabels[item.rarity] ?? item.rarity,
    ].join(' '), search))
  }, [catalog, search])

  const filteredSpells = useMemo(() => {
    if (!catalog) return []
    if (!search.trim()) return catalog.spells
    return catalog.spells.filter((spell) => matchesSearch([
      spell.name,
      spell.description,
      spell.spell_kind,
      spell.damage_type ?? '',
      spell.status_effect_type ?? '',
    ].join(' '), search))
  }, [catalog, search])

  const filteredAffixes = useMemo(() => {
    if (!catalog) return []
    if (!search.trim()) return catalog.affixes
    return catalog.affixes.filter((affix) => matchesSearch([
      affix.name,
      affix.description,
      affix.unique_effect_type ?? '',
      ...affix.allowed_categories,
    ].join(' '), search))
  }, [catalog, search])

  const raceCount = catalog?.races.length ?? 0
  const itemCount = catalog?.items.length ?? 0
  const spellCount = catalog?.spells.length ?? 0
  const affixCount = catalog?.affixes.length ?? 0

  return (
    <section className="guide-shell">
      <article className="panel guide-hero">
        <div>
          <button className="ghost-button guide-back-button" type="button" onClick={onBack}>
            ← Назад в «Ещё»
          </button>
          <span className="eyebrow">СПРАВОЧНИК VEIRA</span>
          <h1>Гид по механикам и контенту</h1>
          <p className="muted">
            Здесь собраны реальные правила боевой системы и актуальные каталоги из базы игры.
            Расы, оружие, броня, заклинания, магические семейства и аффиксы обновляются вместе с игровыми данными.
          </p>
        </div>

        <div className="guide-hero-stats">
          <span><b>{raceCount}</b><small>игровых рас</small></span>
          <span><b>{itemCount}</b><small>предметов экипировки</small></span>
          <span><b>{spellCount}</b><small>заклинаний</small></span>
          <span><b>{affixCount}</b><small>аффиксов</small></span>
        </div>
      </article>

      <div className="guide-layout">
        <aside className="panel guide-nav" aria-label="Разделы гида">
          {sections.map((entry) => (
            <button
              className={section === entry.id ? 'active' : ''}
              type="button"
              key={entry.id}
              onClick={() => {
                setSection(entry.id)
                setSearch('')
              }}
            >
              <strong>{entry.label}</strong>
              <span>{entry.description}</span>
            </button>
          ))}
        </aside>

        <div className="guide-content">
          {message && (
            <article className="panel">
              <p className="form-message" aria-live="polite">{message}</p>
              <button className="ghost-button" type="button" onClick={() => void loadGuide()}>
                Повторить загрузку
              </button>
            </article>
          )}

          {loading && (
            <article className="panel guide-loading">
              <span className="eyebrow">ЗАГРУЗКА</span>
              <h2>Собираем справочник…</h2>
              <p className="muted">Получаем актуальные предметы, заклинания и аффиксы из базы Veira.</p>
            </article>
          )}

          {!loading && catalog && section === 'start' && (
            <>
              <article className="panel guide-section-head">
                <span className="eyebrow">С ЧЕГО НАЧАТЬ</span>
                <h2>Всё важное в одном месте</h2>
                <p className="muted">
                  Гид не привязан к уровню персонажа. Можно сравнить все расы, заранее посмотреть будущие заклинания,
                  изучить семейства магии и оружия и понять, зачем нужны заточка, пробуждение и аффиксы.
                </p>
              </article>

              <div className="guide-topic-grid">
                {sections.filter((entry) => entry.id !== 'start').map((entry) => (
                  <button
                    className="guide-topic-card"
                    type="button"
                    key={entry.id}
                    onClick={() => setSection(entry.id)}
                  >
                    <span className="eyebrow">{entry.label}</span>
                    <strong>{entry.description}</strong>
                    <small>Открыть раздел →</small>
                  </button>
                ))}
              </div>

              <article className="panel guide-callout">
                <span className="eyebrow">БЫСТРЫЙ ОТВЕТ</span>
                <h3>Чем отличаются заточка и пробуждение?</h3>
                <p>
                  <b>Заточка</b> покупается за золото и увеличивает именно базовый урон оружия на
                  <b> +3% за каждый уровень</b>. <b>Пробуждение</b> требует уничтожить идентичную копию
                  оружия и усиливает его особую механику либо даёт +1% физического урона за ступень,
                  если отдельного эффекта для пробуждения нет.
                </p>
              </article>
            </>
          )}

          {!loading && catalog && section === 'races' && (
            <>
              <GuideHeading
                eyebrow="РАСЫ"
                title="Все игровые расы"
                text="Здесь показаны текущие расовые характеристики, сопротивления, регенерация, врождённая магия, пассивка и дополнительные черты прямо из базы."
              />

              <article className="panel guide-callout">
                <span className="eyebrow">КАК ЧИТАТЬ БОНУСЫ</span>
                <h3>Раса влияет на бой с первого уровня</h3>
                <p>
                  Расовые модификаторы добавляются поверх распределённых характеристик персонажа.
                  Бонусы ОЗ и маны меняют базовые запасы, регенерация работает каждый час, а отрицательное сопротивление означает уязвимость.
                </p>
              </article>

              <GuideSearch value={search} onChange={setSearch} placeholder="Найти расу, пассивку или категорию…" />

              {Array.from(new Set(filteredRaces.map((race) => race.category))).map((category) => (
                <article className="panel guide-subsection" key={category}>
                  <div className="section-heading">
                    <div>
                      <span className="eyebrow">КАТЕГОРИЯ</span>
                      <h3>{category}</h3>
                    </div>
                    <span className="badge">{filteredRaces.filter((race) => race.category === category).length}</span>
                  </div>
                  <div className="guide-catalog-grid">
                    {filteredRaces
                      .filter((race) => race.category === category)
                      .map((race) => <RaceCard race={race} key={race.id} />)}
                  </div>
                </article>
              ))}
            </>
          )}

          {!loading && catalog && section === 'mechanics' && (
            <>
              <GuideHeading
                eyebrow="ОСНОВЫ"
                title="Характеристики и формулы"
                text="Главные боевые значения рассчитываются из характеристик персонажа, уровня, оружия, расы, экипировки и аффиксов."
              />

              <div className="guide-rule-grid">
                <GuideRule title="Физическая мощь">
                  База оружия с заточкой + скейлинг оружия + уровень ×2.
                  Силовое: <b>СИЛ ×3 + ЛОВ ×0,5</b>; ловкостное: <b>ЛОВ ×3 + СИЛ ×0,5</b>;
                  гибридное: <b>СИЛ ×1,75 + ЛОВ ×1,75</b>.
                </GuideRule>
                <GuideRule title="Физическая защита">
                  <b>ЖИВ ×2 + ЛОВ ×0,5 + уровень</b>. После этого применяются процентные бонусы
                  экипировки, расы и эффектов.
                </GuideRule>
                <GuideRule title="Магическая защита">
                  <b>ЖИВ + ИНТ + уровень</b>. Используется против стихийного и магического входящего урона.
                </GuideRule>
                <GuideRule title="Критический шанс">
                  Базово <b>1% + УДА ×0,3%</b>, затем добавляются специальные бонусы.
                  Общий предел — <b>{catalog.mechanics.critical_cap_percent}%</b>.
                </GuideRule>
                <GuideRule title="Удача и качественный лут">
                  Каждая единица УДА даёт <b>+{catalog.mechanics.loot_quality_luck_relative_percent_per_point}% относительного шанса</b>
                  на выпадение экипировки Rare+ в подземельях. Это влияет на оружие, броню и аксессуары, но не на материалы и расходники.
                </GuideRule>
                <GuideRule title="Критический урон">
                  Физический крит: <b>×{catalog.mechanics.physical_critical_multiplier}</b>.
                  Магический крит: <b>×{catalog.mechanics.magic_critical_multiplier}</b>.
                  Процентный урон от максимального здоровья не критует.
                </GuideRule>
                <GuideRule title="Типы урона">
                  Физические: режущий, колющий, дробящий. Магические каналы: огонь, вода, земля, воздух,
                  молния, лёд, арканный, звёздный, гравитационный и лунный.
                  Сопротивление уменьшает урон, отрицательное сопротивление означает уязвимость.
                </GuideRule>
              </div>

              <article className="panel guide-callout">
                <span className="eyebrow">ВАЖНО</span>
                <h3>База оружия не заменяет характеристики</h3>
                <p>
                  Урон оружия строится из двух крупных частей: <b>базового урона самого предмета</b> и
                  вклада характеристик по его скейлингу. Поэтому сильная заточка и высокая Сила/Ловкость
                  усиливают друг друга, а не конкурируют.
                </p>
              </article>
            </>
          )}

          {!loading && catalog && section === 'weapons' && (
            <>
              <GuideHeading
                eyebrow="ОРУЖИЕ"
                title="Семейства и каталог"
                text="Сначала — общие механики семейств. Ниже находится полный актуальный список оружия из базы."
              />

              <div className="guide-rule-grid">
                {familyMechanics.map((entry) => (
                  <GuideRule title={entry.title} key={entry.family}>{entry.text}</GuideRule>
                ))}
              </div>

              <GuideSearch value={search} onChange={setSearch} placeholder="Найти оружие, семейство или редкость…" />

              <div className="guide-catalog-grid">
                {filteredItems.filter((item) => item.category === 'weapon').map((item) => (
                  <ItemCard item={item} key={item.id} />
                ))}
              </div>
            </>
          )}

          {!loading && catalog && section === 'armor' && (
            <>
              <GuideHeading
                eyebrow="БРОНЯ"
                title="Броня и сопротивления"
                text="Броня может давать характеристики, процентную защиту, сопротивления конкретным типам урона и уникальные свойства."
              />
              <GuideSearch value={search} onChange={setSearch} placeholder="Найти броню или свойство…" />
              <div className="guide-catalog-grid">
                {filteredItems.filter((item) => item.category === 'armor').map((item) => (
                  <ItemCard item={item} key={item.id} />
                ))}
              </div>
            </>
          )}

          {!loading && catalog && section === 'accessories' && (
            <>
              <GuideHeading
                eyebrow="АКСЕССУАРЫ"
                title="Дополнительные свойства"
                text="Аксессуары занимают два доступных слота и часто используются для сопротивлений, характеристик и редких боевых эффектов."
              />
              <GuideSearch value={search} onChange={setSearch} placeholder="Найти аксессуар…" />
              <div className="guide-catalog-grid">
                {filteredItems.filter((item) => item.category === 'accessory').map((item) => (
                  <ItemCard item={item} key={item.id} />
                ))}
              </div>
            </>
          )}

          {!loading && catalog && section === 'spells' && (
            <>
              <GuideHeading
                eyebrow="МАГИЯ"
                title="Заклинания и семейства"
                text="Каталог показывает текущие требования, стоимость маны, тип урона, семейства, статусы и поддержку прямо из базы."
              />

              <article className="panel guide-subsection">
                <div className="section-heading">
                  <div>
                    <span className="eyebrow">СЕМЕЙСТВА МАГИИ</span>
                    <h3>Стихии, школы и функции</h3>
                  </div>
                  <span className="badge">{catalog.magic_families.length}</span>
                </div>
                <p className="muted">
                  Семейство и тип урона — разные вещи. Одно заклинание может одновременно относиться к нескольким семействам:
                  например к магической школе и к функции вроде Защитной или Лечебной.
                </p>
                <div className="guide-effect-grid">
                  {catalog.magic_families.map((family) => (
                    <div className="guide-effect-card" key={family.slug}>
                      <strong>{family.name}</strong>
                      <p>{family.description}</p>
                      <div className="guide-chip-list">
                        <span>{family.kind === 'element' ? 'стихия' : family.kind === 'school' ? 'школа' : 'функция'}</span>
                        <span>{family.spell_count} закл.</span>
                      </div>
                    </div>
                  ))}
                </div>
              </article>

              <GuideSearch value={search} onChange={setSearch} placeholder="Найти заклинание, семейство, стихию или эффект…" />
              <div className="guide-catalog-grid">
                {filteredSpells.map((spell) => (
                  <SpellCard spell={spell} key={spell.id} />
                ))}
              </div>
            </>
          )}

          {!loading && catalog && section === 'effects' && (
            <>
              <GuideHeading
                eyebrow="ЭФФЕКТЫ"
                title="Баффы и дебаффы"
                text="Статусы действуют по раундам. Повторное наложение одного и того же статуса сохраняет более сильную мощность и более долгую длительность."
              />

              <article className="panel guide-subsection">
                <div className="section-heading">
                  <div>
                    <span className="eyebrow">ДЕБАФФЫ</span>
                    <h3>Негативные эффекты</h3>
                  </div>
                </div>
                <div className="guide-effect-grid">
                  {debuffs.map(([title, text]) => (
                    <div className="guide-effect-card debuff" key={title}>
                      <strong>{title}</strong>
                      <p>{text}</p>
                    </div>
                  ))}
                </div>
              </article>

              <article className="panel guide-subsection">
                <div className="section-heading">
                  <div>
                    <span className="eyebrow">БАФФЫ И ПОДДЕРЖКА</span>
                    <h3>Положительные эффекты</h3>
                  </div>
                </div>
                <div className="guide-effect-grid">
                  {buffs.map(([title, text]) => (
                    <div className="guide-effect-card buff" key={title}>
                      <strong>{title}</strong>
                      <p>{text}</p>
                    </div>
                  ))}
                </div>
              </article>

              <article className="panel guide-subsection">
                <span className="eyebrow">ЛУКИ</span>
                <h3>Дистанция</h3>
                <div className="guide-bloodshed-steps three">
                  <span><b>Ближняя</b><small>+10% урон · 3% уклонения</small></span>
                  <span><b>Средняя</b><small>9% уклонения</small></span>
                  <span><b>Дальняя</b><small>−10% урон · 15% уклонения</small></span>
                </div>
              </article>
            </>
          )}

          {!loading && catalog && section === 'passives' && (
            <>
              <GuideHeading
                eyebrow="ПАССИВНЫЕ ЭФФЕКТЫ"
                title="Особые эффекты оружия и экипировки"
                text="Пассивные эффекты работают автоматически, если выполнено их условие. Они не занимают отдельный ход и отличаются от временных баффов и дебаффов."
              />

              <div className="guide-effect-grid">
                <div className="guide-effect-card passive">
                  <strong>Эхо ударов</strong>
                  <p>
                    После физической атаки оружие бросает свой шанс на дополнительный удар по той же цели.
                    Если Эхо сработало, дополнительный удар снова может запустить Эхо и продолжить цепочку.
                    Эти попадания не тратят отдельный ход, могут критовать и активировать эффекты при попадании.
                  </p>
                </div>

                <div className="guide-effect-card passive">
                  <strong>Рваные раны / Разрыв</strong>
                  <p>
                    Пассивка «Кинжала Белого Клыка». Каждый успешный физический удар накладывает 1 Ранение.
                    После 3 Ранений следующий, 4-й удар вызывает Разрыв: базовый урон равен меньшему из
                    10% максимального ОЗ цели и лимита <b>80 + уровень × 10 + AGI × 4</b>.
                    Разрыв игнорирует физическую защиту и отдельно может критовать ×1.5 уже после расчёта лимита.
                  </p>
                </div>

                <div className="guide-effect-card passive">
                  <strong>Вампиризм</strong>
                  <p>
                    Восстанавливает владельцу часть нанесённого прямого урона как ОЗ.
                    Процент зависит от конкретного оружия, аффикса и других источников эффекта.
                  </p>
                </div>

                <div className="guide-effect-card passive">
                  <strong>Добивание</strong>
                  <p>
                    Увеличивает прямой урон по уже тяжело раненой цели. Например, «Пика Палача»
                    получает +25% прямого урона, когда у цели осталось 30% ОЗ или меньше.
                  </p>
                </div>

                <div className="guide-effect-card passive">
                  <strong>Первый удар</strong>
                  <p>
                    Особая пассивка некоторых катан. У «Катаны Первого Удара» первая физическая атака
                    в каждой битве усиливает базовую и бонусную части прямого урона отдельными множителями.
                    Не-физическое действие эффект не расходует.
                  </p>
                </div>

                <div className="guide-effect-card passive">
                  <strong>Мана за попадание</strong>
                  <p>
                    Восстанавливает фиксированное количество маны при успешном прямом попадании.
                    На многоударных физических атаках восстановление может учитываться за несколько попаданий.
                  </p>
                </div>

                <div className="guide-effect-card passive">
                  <strong>Усиление защиты</strong>
                  <p>
                    Повышает эффективность защитной стойки и защитных заклинаний. Значение складывается
                    с другими совместимыми источниками до системного лимита.
                  </p>
                </div>
              </div>

              <article className="panel guide-bloodshed">
                <span className="eyebrow">КРОВОПРОЛИТИЕ</span>
                <h3>Накопление урона между ударами</h3>
                <p>
                  Каждый успешный физический хит оружием с Кровопролитием отдельно бросает шанс добавить стак.
                  Поэтому многоударные атаки могут накопить сразу несколько стаков за одно действие.
                </p>
                <div className="guide-bloodshed-steps">
                  <span><b>1-й стак</b><small>5% от текущего ОЗ</small></span>
                  <span><b>2-й стак</b><small>4% от оставшегося ОЗ</small></span>
                  <span><b>3-й стак</b><small>3%</small></span>
                  <span><b>4-й стак</b><small>2%</small></span>
                  <span><b>5-й и дальше</b><small>1% за стак</small></span>
                </div>
                <p className="muted">
                  Накопленные стаки срабатывают последовательно в начале хода цели и после этого сбрасываются.
                  Каждый следующий процент считается уже от уменьшенного текущего здоровья.
                </p>
              </article>

              <article className="panel guide-callout">
                <span className="eyebrow">ПРОБУЖДЕНИЕ</span>
                <h3>Пассивка может становиться сильнее</h3>
                <p>
                  Если оружие построено вокруг особого пассивного эффекта, пробуждение обычно усиливает именно его.
                  Например, Кровопролитие и Эхо ударов получают <b>+1 п.п. шанса за каждую ступень пробуждения</b>.
                  Точный бонус всегда указан в карточке конкретного оружия.
                </p>
              </article>
            </>
          )}

          {!loading && catalog && section === 'affixes' && (
            <>
              <GuideHeading
                eyebrow="АФФИКСЫ"
                title="Случайные свойства экипировки"
                text="Аффиксы добавляются кузницей и могут давать характеристики, сопротивления или отдельные боевые эффекты."
              />

              <article className="panel guide-affix-slots">
                <span className="eyebrow">КОЛИЧЕСТВО СЛОТОВ</span>
                <div>
                  {Object.entries(catalog.mechanics.affix_slots).map(([rarity, count]) => (
                    <span className={'rarity-' + rarity} key={rarity}>
                      <b>{rarityLabels[rarity] ?? rarity}</b>
                      <small>{count} аффикс.</small>
                    </span>
                  ))}
                </div>
              </article>

              <GuideSearch value={search} onChange={setSearch} placeholder="Найти аффикс или эффект…" />

              <div className="guide-catalog-grid">
                {filteredAffixes.map((affix) => (
                  <AffixCard affix={affix} key={affix.id} />
                ))}
              </div>
            </>
          )}

          {!loading && catalog && section === 'blacksmith' && (
            <>
              <GuideHeading
                eyebrow="КУЗНИЦА"
                title="Заточка и пробуждение"
                text="Это две независимые системы усиления оружия. Они складываются и работают одновременно."
              />

              <div className="guide-forge-grid">
                <article className="panel guide-forge-card">
                  <span className="eyebrow">ЗАТОЧКА +0 → +{catalog.mechanics.enhancement_max}</span>
                  <h3>Усиливает базу оружия</h3>
                  <p>
                    Каждый уровень заточки добавляет <b>+{catalog.mechanics.enhancement_percent_per_level}%</b>
                    к базовому урону оружия. Например, +6 означает множитель базы <b>×1,18</b>,
                    а +20 — <b>×1,60</b>.
                  </p>
                  <p className="muted">
                    Заточка оплачивается золотом. Максимально доступный уровень зависит от уровня кузницы поселения.
                  </p>
                </article>

                <article className="panel guide-forge-card">
                  <span className="eyebrow">ПРОБУЖДЕНИЕ I → V</span>
                  <h3>Требует идентичную копию</h3>
                  <p>
                    Одна одинаковая ненадетая копия оружия уничтожается ради одной ступени пробуждения.
                    Максимум — <b>{catalog.mechanics.awakening_max} ступеней</b>.
                  </p>
                  <p className="muted">
                    Что именно усиливается, зависит от самого оружия. В карточках оружия в этом гиде
                    показан его конкретный бонус пробуждения.
                  </p>
                </article>
              </div>

            </>
          )}

          {!loading && catalog && section === 'dungeons' && (
            <>
              <GuideHeading
                eyebrow="ПОДЗЕМЕЛЬЯ"
                title="Повторные зачистки и цикл наград"
                text="Подземелье можно проходить сколько угодно, но награды ограничены личным 18-часовым циклом."
              />

              <article className="panel">
                <div className="dungeon-fatigue-scale guide-fatigue-scale">
                  <span><b>1-я</b><small>100% XP · 100% золота</small></span>
                  <span><b>2-я</b><small>90% XP · 95% золота</small></span>
                  <span><b>3-я</b><small>80% XP · 90% золота</small></span>
                  <span><b>4-я</b><small>65% XP · 80% золота</small></span>
                  <span><b>5-я</b><small>50% XP · 70% золота</small></span>
                  <span><b>6-я</b><small>35% XP · 60% золота</small></span>
                  <span><b>7-я</b><small>20% XP · 45% золота</small></span>
                  <span><b>8-я</b><small>10% XP · 35% золота</small></span>
                  <span><b>9+</b><small>0% XP · 25% золота</small></span>
                </div>
              </article>

              <div className="guide-rule-grid">
                <GuideRule title="25 наградных попыток">
                  С первого входа в конкретный данж запускается <b>18-часовой цикл</b>. Первые 25 попыток дают награды
                  по обычной шкале. С 26-й попытки и дальше вход остаётся полностью безлимитным, но награда равна
                  <b> 0 XP, 0 золота и 0 личного лута</b>.
                </GuideRule>
                <GuideRule title="Новый цикл через 18 часов">
                  Когда 18 часов с первого входа заканчиваются, следующий заход автоматически начинает новый цикл:
                  счётчик снова становится 1/25. Для каждого подземелья и каждого персонажа цикл считается отдельно.
                </GuideRule>
                <GuideRule title="Автобой">
                  Автобой использует тот же 18-часовой цикл и тот же лимит 25 наградных попыток, что ручное прохождение.
                  Он не создаёт отдельный источник опыта, золота или лута.
                </GuideRule>
                <GuideRule title="Слабые данжи">
                  Награда дополнительно масштабируется относительно уровня персонажа и сложности,
                  поэтому старые слабые данжи остаются запасным вариантом, а не лучшим способом прокачки.
                </GuideRule>
                <GuideRule title="Качество экипировки">
                  Удача немного повышает шанс получить оружие, броню или аксессуар Rare+.
                  Бонус относительный: каждая единица УДА добавляет <b>+{catalog.mechanics.loot_quality_luck_relative_percent_per_point}%</b>
                  к базовому шансу подходящей награды.
                </GuideRule>
              </div>
            </>
          )}
        </div>
      </div>
    </section>
  )
}

function GuideHeading({ eyebrow, title, text }: { eyebrow: string; title: string; text: string }) {
  return (
    <article className="panel guide-section-head">
      <span className="eyebrow">{eyebrow}</span>
      <h2>{title}</h2>
      <p className="muted">{text}</p>
    </article>
  )
}

function GuideRule({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <article className="guide-rule-card">
      <strong>{title}</strong>
      <p>{children}</p>
    </article>
  )
}

function GuideSearch({
  value,
  onChange,
  placeholder,
}: {
  value: string
  onChange: (value: string) => void
  placeholder: string
}) {
  return (
    <label className="panel guide-search">
      <span>Поиск по разделу</span>
      <input
        type="search"
        value={value}
        placeholder={placeholder}
        onChange={(event) => onChange(event.target.value)}
      />
    </label>
  )
}

function RaceCard({ race }: { race: GuideRace }) {
  const modifiers = objectEntries(race.stat_modifiers)
  const resistances = objectEntries(race.damage_resistances)

  return (
    <article className="guide-catalog-card race">
      <div className="guide-catalog-card-head">
        <div>
          <span className="eyebrow">{race.category}</span>
          <strong>{race.name}</strong>
        </div>
        {race.innate_magic_damage_type && (
          <span className="badge">{damageLabels[race.innate_magic_damage_type] ?? race.innate_magic_damage_type}</span>
        )}
      </div>

      <p>{race.description}</p>

      {modifiers.length > 0 && (
        <div className="guide-chip-list">
          {modifiers.map(([key, value]) => <span key={key}>{formatModifier(key, value)}</span>)}
        </div>
      )}

      <div className="guide-chip-list">
        {race.hp_bonus !== 0 && <span>ОЗ {race.hp_bonus > 0 ? '+' : ''}{race.hp_bonus}</span>}
        {race.mana_bonus !== 0 && <span>Мана {race.mana_bonus > 0 ? '+' : ''}{race.mana_bonus}</span>}
        <span>Реген ОЗ +{race.hp_regen_per_hour}/ч</span>
        <span>Реген маны +{race.mana_regen_per_hour}/ч</span>
        {race.innate_magic_damage_type && (
          <span>Врождённая магия: {damageLabels[race.innate_magic_damage_type] ?? race.innate_magic_damage_type}</span>
        )}
      </div>

      {resistances.length > 0 && (
        <div className="guide-chip-list resistance">
          {resistances.map(([key, value]) => <span key={key}>{formatResistance(key, value)}</span>)}
        </div>
      )}

      {race.passive_name && (
        <div className="guide-unique-block">
          <b>{race.passive_name}</b>
          <span>{race.passive_description}</span>
        </div>
      )}

      {race.traits.map((trait, index) => (
        <div className="guide-special-line" key={trait.name + index}>
          <b>{trait.name}</b>{trait.description ? ' · ' + trait.description : ''}
        </div>
      ))}
    </article>
  )
}

function ItemCard({ item }: { item: GuideItem }) {
  const modifiers = objectEntries(item.stat_modifiers)
  const resistances = objectEntries(item.damage_resistances)
  const bonuses = objectEntries(item.damage_bonuses)

  return (
    <article className={'guide-catalog-card rarity-' + item.rarity}>
      <div className="guide-catalog-card-head">
        <div>
          <span className="eyebrow">{rarityLabels[item.rarity] ?? item.rarity}</span>
          <strong>{item.name}</strong>
        </div>
        <span className="badge">ур. {item.required_level}</span>
      </div>

      {item.description && <p>{item.description}</p>}

      {item.category === 'weapon' && (
        <div className="guide-chip-list">
          <span>База {item.weapon_base_damage}</span>
          {item.damage_type && <span>{damageLabels[item.damage_type] ?? item.damage_type}</span>}
          {item.weapon_scaling && <span>{scalingLabels[item.weapon_scaling] ?? item.weapon_scaling}</span>}
          {item.weapon_family && <span>{familyLabels[item.weapon_family] ?? item.weapon_family}</span>}
        </div>
      )}

      {modifiers.length > 0 && (
        <div className="guide-chip-list">
          {modifiers.map(([key, value]) => <span key={key}>{formatModifier(key, value)}</span>)}
        </div>
      )}

      {resistances.length > 0 && (
        <div className="guide-chip-list resistance">
          {resistances.map(([key, value]) => <span key={key}>{formatResistance(key, value)}</span>)}
        </div>
      )}

      {bonuses.length > 0 && (
        <div className="guide-chip-list bonus">
          {bonuses.map(([key, value]) => (
            <span key={key}>{damageLabels[key] ?? key} урон +{value}%</span>
          ))}
        </div>
      )}

      {item.unique_property_name && (
        <div className="guide-unique-block">
          <b>{item.unique_property_name}</b>
          <span>{item.unique_property_description}</span>
        </div>
      )}

      {item.unique_effect_type && (
        <div className="guide-unique-block compact">
          <b>{effectLabels[item.unique_effect_type] ?? item.unique_effect_type}</b>
          <span>Значение: {item.unique_effect_value}{item.unique_effect_type === 'mana_on_hit' ? '' : '%'}</span>
        </div>
      )}

      {item.bloodshed_chance_percent > 0 && (
        <div className="guide-special-line">
          Кровопролитие · {item.bloodshed_chance_percent}% базовый шанс за физическое попадание
        </div>
      )}

      {item.echo_strike_chance_percent > 0 && (
        <div className="guide-special-line">
          Эхо ударов · {item.echo_strike_chance_percent}% базовый шанс
        </div>
      )}

      {item.category === 'weapon' && (
        <div className="guide-awakening-line">
          <span>Пробуждение</span>
          <b>{awakeningText(item)}</b>
        </div>
      )}
    </article>
  )
}

function SpellCard({ spell }: { spell: GuideSpell }) {
  const kindLabels: Record<string, string> = {
    damage: 'Урон',
    heal: 'Лечение',
    guard: 'Щит',
    cleanse: 'Очищение',
    buff: 'Бафф',
    taunt: 'Провокация',
    sacrifice: 'Жертва',
  }

  return (
    <article className="guide-catalog-card spell">
      <div className="guide-catalog-card-head">
        <div>
          <span className="eyebrow">{kindLabels[spell.spell_kind] ?? spell.spell_kind}</span>
          <strong>{spell.name}</strong>
        </div>
        <span className="badge">ур. {spell.required_level}</span>
      </div>

      <p>{spell.description}</p>

      <div className="guide-chip-list">
        <span>{spell.mana_cost} маны</span>
        {spell.damage_type && <span>{damageLabels[spell.damage_type] ?? spell.damage_type}</span>}
        {spell.families.map((family) => (
          <span key={family.slug}>{family.name}</span>
        ))}
        {spell.spell_kind === 'damage' && <span>множитель ×{Number(spell.power_multiplier).toFixed(2)}</span>}
        {spell.flat_power !== 0 && <span>плоская сила {spell.flat_power >= 0 ? '+' : ''}{spell.flat_power}</span>}
      </div>

      {spell.status_effect_type && (
        <div className="guide-special-line">
          {spell.status_effect_type} · {spell.status_effect_chance}% · {spell.status_effect_turns} ход.
          {spell.status_effect_potency > 0 ? ' · сила ' + spell.status_effect_potency : ''}
        </div>
      )}

      {spell.support_effect_type && (
        <div className="guide-special-line">
          Поддержка: {spell.support_effect_type} · значение {spell.support_value}
          {spell.support_turns > 0 ? ' · ' + spell.support_turns + ' ход.' : ''}
        </div>
      )}
    </article>
  )
}

function AffixCard({ affix }: { affix: GuideAffix }) {
  const modifiers = objectEntries(affix.stat_modifiers)
  const resistances = objectEntries(affix.damage_resistances)

  return (
    <article className="guide-catalog-card affix">
      <div className="guide-catalog-card-head">
        <div>
          <span className="eyebrow">АФФИКС</span>
          <strong>{affix.name}</strong>
        </div>
        <span className="badge">
          {rarityByRank[affix.min_rarity_rank] ?? affix.min_rarity_rank}+
        </span>
      </div>

      <p>{affix.description}</p>

      <div className="guide-chip-list">
        {affix.allowed_categories.map((category) => (
          <span key={category}>
            {category === 'weapon' ? 'оружие' : category === 'armor' ? 'броня' : 'аксессуар'}
          </span>
        ))}
      </div>

      {modifiers.length > 0 && (
        <div className="guide-chip-list">
          {modifiers.map(([key, value]) => <span key={key}>{formatModifier(key, value)}</span>)}
        </div>
      )}

      {resistances.length > 0 && (
        <div className="guide-chip-list resistance">
          {resistances.map(([key, value]) => <span key={key}>{formatResistance(key, value)}</span>)}
        </div>
      )}

      {affix.unique_effect_type && (
        <div className="guide-unique-block compact">
          <b>{effectLabels[affix.unique_effect_type] ?? affix.unique_effect_type}</b>
          <span>
            +{affix.unique_effect_value}{affix.unique_effect_type === 'mana_on_hit' ? '' : '%'}
          </span>
        </div>
      )}
    </article>
  )
}
