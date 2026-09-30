import './newcomer.css'

type Props = {
  compact?: boolean
  daysRemaining?: number
  onOpenGuide?: () => void
}

const damageGroups = [
  ['Физический', 'режущий · колющий · дробящий'],
  ['Стихийный', 'огонь · вода · земля · воздух · молния · лёд'],
  ['Редкий', 'арканный · лунный · звёздный · гравитационный'],
]

const builds = [
  ['Силовой боец', 'СИЛ + ЖИВ', 'молоты, булавы, топоры, двуручники · сильный прямой урон и блок'],
  ['Ловкач', 'ЛОВ + немного СИЛ', 'луки, рапиры, кинжалы · инициатива, темп и быстрые физические атаки'],
  ['Маг', 'ИНТ + УДА/ЖИВ', 'заклинания, стихии и контроль · высокий урон за ману'],
  ['Гибрид', 'СИЛ + ЛОВ', 'копья и часть смешанного оружия · гибкость вместо одного максимального стата'],
  ['Саппорт', 'ИНТ + ЖИВ', 'лечение, щиты, баффы и дебаффы · особенно силён в группе'],
]

export function NewcomerHandbook({ compact = false, daysRemaining, onOpenGuide }: Props) {
  if (compact) {
    return (
      <section className="panel newcomer-handbook newcomer-handbook-compact">
        <div className="newcomer-heading">
          <div>
            <span className="eyebrow">ПОСОБИЕ НОВИЧКА</span>
            <h2>Что вообще делать в Veira</h2>
          </div>
          {typeof daysRemaining === 'number' && (
            <span className="badge">{Math.max(1, daysRemaining)} дн.</span>
          )}
        </div>

        <p className="muted">
          Исследуй Эйлар, собирай билд, проходи данжи, охоться на боссов и играй с другими персонажами.
          Здесь нет одного правильного класса: роль получается из характеристик, оружия, экипировки и заклинаний.
        </p>

        <div className="newcomer-quick-grid">
          <span><b>СИЛ</b> физический урон и блок</span>
          <span><b>ЛОВ</b> скорость, инициатива и ловкостное оружие</span>
          <span><b>ИНТ</b> магия и магическая броня</span>
          <span><b>ЖИВ</b> защита и выживаемость</span>
          <span><b>УДА</b> крит, разброс и качество находок</span>
          <span><b>Главное</b> не гонись только за одной цифрой урона</span>
        </div>

        {onOpenGuide && (
          <button className="ghost-button newcomer-guide-button" type="button" onClick={onOpenGuide}>
            Открыть полное пособие
          </button>
        )}
      </section>
    )
  }

  return (
    <div className="newcomer-handbook newcomer-handbook-full">
      <section className="panel newcomer-hero">
        <span className="eyebrow">ПЕРВЫЕ ШАГИ</span>
        <h2>Veira — это мир, а не список данжей</h2>
        <p>
          Ты создаёшь персонажа в Эйларе и постепенно открываешь карту, усиливаешь билд, находишь редкие вещи,
          участвуешь в событиях мира и объединяешься с другими игроками. Большая часть сильных механик раскрывается
          через сочетания: бафф союзника, уязвимость врага, правильный тип урона, роль в группе и момент для burst.
        </p>
      </section>

      <section className="newcomer-guide-grid">
        <article className="panel newcomer-guide-card">
          <span className="eyebrow">ХАРАКТЕРИСТИКИ</span>
          <h3>Что качать</h3>
          <div className="newcomer-stat-list">
            <p><b>Сила</b><span>главный стат силового оружия, немного ОЗ и эффективность блока.</span></p>
            <p><b>Ловкость</b><span>ловкостное оружие, инициатива, темп действий и часть физической защиты.</span></p>
            <p><b>Интеллект</b><span>магическая мощь и магическая броня.</span></p>
            <p><b>Живучесть</b><span>главный источник физической защиты и общей стойкости.</span></p>
            <p><b>Удача</b><span>криты, более удачный разброс урона и шанс качественных находок.</span></p>
          </div>
        </article>

        <article className="panel newcomer-guide-card">
          <span className="eyebrow">УРОН</span>
          <h3>Типы имеют значение</h3>
          <p className="muted">У врага могут быть сопротивления и уязвимости. Один и тот же билд не обязан одинаково хорошо бить всё.</p>
          <div className="newcomer-damage-list">
            {damageGroups.map(([title, values]) => (
              <p key={title}><b>{title}</b><span>{values}</span></p>
            ))}
          </div>
          <p className="newcomer-note">Физическая и магическая броня снижают входящий урон по кривой с убывающей отдачей.</p>
        </article>

        <article className="panel newcomer-guide-card newcomer-build-card">
          <span className="eyebrow">БИЛДЫ</span>
          <h3>Примеры направлений</h3>
          <div className="newcomer-build-list">
            {builds.map(([name, stats, text]) => (
              <div key={name}>
                <strong>{name}</strong>
                <small>{stats}</small>
                <span>{text}</span>
              </div>
            ))}
          </div>
        </article>

        <article className="panel newcomer-guide-card">
          <span className="eyebrow">ЧТО ДЕЛАТЬ СНАЧАЛА</span>
          <h3>Нормальный старт</h3>
          <ol className="newcomer-steps">
            <li>Пройди «Эхо дороги» — это короткий пролог без наказания за поражение.</li>
            <li>Посмотри оружие и реши, от какого стата будет твой основной урон.</li>
            <li>Исследуй соседние сектора и руины, но не жди только идеального лута.</li>
            <li>Пробуй данжи своей сложности и следи не только за уроном, но и за защитой.</li>
            <li>В группе думай действиями команды: слабый личный ход может создать сильное окно керри.</li>
          </ol>
        </article>

        <article className="panel newcomer-guide-card newcomer-wide-card">
          <span className="eyebrow">ВАЖНАЯ МЫСЛЬ</span>
          <h3>Считай не одну кнопку, а несколько ходов</h3>
          <p>
            Бафф +25% не обязательно выгоден, если ради него ты теряешь собственную сильную атаку.
            Но тот же бафф может быть отличным, если саппорт отдаёт слабый ход ради двух атак керри в окно сниженных резистов.
            В Veira хорошие сборки строятся вокруг таких связок, а не только вокруг максимальной цифры в описании предмета.
          </p>
        </article>
      </section>
    </div>
  )
}
