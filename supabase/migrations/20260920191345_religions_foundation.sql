create table public.religion_definitions (
  slug text primary key,
  name text not null unique,
  short_motto text not null default '',
  description text not null default '',
  praise_text text not null default '',
  taboo_text text not null default '',
  faith_daily_cap smallint not null default 25 check (faith_daily_cap between 1 and 100),
  level10_reward_item_id uuid,
  enabled boolean not null default true,
  sort_order smallint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.religion_level_perks (
  religion_slug text not null references public.religion_definitions(slug) on delete cascade,
  level smallint not null check (level between 1 and 10),
  title text not null,
  description text not null,
  modifiers jsonb not null default '{}'::jsonb,
  primary key(religion_slug,level)
);

create table public.character_religions (
  character_id uuid primary key references public.characters(id) on delete cascade,
  current_religion_slug text references public.religion_definitions(slug) on delete set null,
  joined_at timestamptz,
  changed_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.character_religion_progress (
  character_id uuid not null references public.characters(id) on delete cascade,
  religion_slug text not null references public.religion_definitions(slug) on delete cascade,
  faith_points integer not null default 0 check (faith_points >= 0),
  favor integer not null default 0 check (favor between -100 and 100),
  level10_reward_claimed boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(character_id,religion_slug)
);

create table public.religion_faith_events (
  id bigint generated always as identity primary key,
  character_id uuid not null references public.characters(id) on delete cascade,
  religion_slug text not null references public.religion_definitions(slug) on delete cascade,
  event_type text not null,
  source_key text not null,
  faith_delta integer not null default 0,
  favor_delta integer not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create unique index religion_faith_events_source_unique
  on public.religion_faith_events(character_id,event_type,source_key);
create index religion_faith_events_daily_idx
  on public.religion_faith_events(character_id,religion_slug,created_at desc);
create index religion_faith_events_religion_idx
  on public.religion_faith_events(religion_slug,created_at desc);

create table public.religion_oath_definitions (
  id uuid primary key default gen_random_uuid(),
  religion_slug text not null references public.religion_definitions(slug) on delete cascade,
  slug text not null,
  name text not null,
  description text not null,
  success_event_type text not null,
  success_metadata jsonb not null default '{}'::jsonb,
  target_count integer not null default 1 check (target_count between 1 and 1000),
  failure_event_type text,
  failure_metadata jsonb not null default '{}'::jsonb,
  faith_reward integer not null default 50 check (faith_reward between 0 and 1000),
  favor_reward integer not null default 5 check (favor_reward between 0 and 100),
  failure_faith_penalty integer not null default 40 check (failure_faith_penalty between 0 and 1000),
  failure_favor_penalty integer not null default 5 check (failure_favor_penalty between 0 and 100),
  enabled boolean not null default true,
  sort_order smallint not null default 0,
  unique(religion_slug,slug)
);

create table public.character_religion_oaths (
  id uuid primary key default gen_random_uuid(),
  character_id uuid not null references public.characters(id) on delete cascade,
  oath_definition_id uuid not null references public.religion_oath_definitions(id) on delete restrict,
  religion_slug text not null references public.religion_definitions(slug) on delete cascade,
  status text not null default 'active' check(status in ('active','completed','failed','abandoned')),
  progress_count integer not null default 0,
  accepted_at timestamptz not null default now(),
  completed_at timestamptz,
  failed_at timestamptz,
  created_at timestamptz not null default now()
);

create unique index character_religion_one_active_oath_idx
  on public.character_religion_oaths(character_id) where status='active';
create index character_religion_oaths_history_idx
  on public.character_religion_oaths(character_id,accepted_at desc);
create index character_religion_oaths_definition_idx
  on public.character_religion_oaths(oath_definition_id);

alter table public.item_definitions
  add column religion_origin_slug text references public.religion_definitions(slug) on delete set null;
create index item_definitions_religion_origin_idx
  on public.item_definitions(religion_origin_slug) where religion_origin_slug is not null;

alter table public.religion_definitions
  add constraint religion_definitions_level10_reward_item_fkey
  foreign key(level10_reward_item_id) references public.item_definitions(id) on delete set null;

alter table public.religion_definitions enable row level security;
alter table public.religion_level_perks enable row level security;
alter table public.character_religions enable row level security;
alter table public.character_religion_progress enable row level security;
alter table public.religion_faith_events enable row level security;
alter table public.religion_oath_definitions enable row level security;
alter table public.character_religion_oaths enable row level security;

revoke all on table public.religion_definitions from anon,authenticated;
revoke all on table public.religion_level_perks from anon,authenticated;
revoke all on table public.character_religions from anon,authenticated;
revoke all on table public.character_religion_progress from anon,authenticated;
revoke all on table public.religion_faith_events from anon,authenticated;
revoke all on table public.religion_oath_definitions from anon,authenticated;
revoke all on table public.character_religion_oaths from anon,authenticated;

insert into public.religion_definitions(
  slug,name,short_motto,description,praise_text,taboo_text,faith_daily_cap,sort_order
) values
('path_of_light','Путь Света','Долг сильнее страха.',
 'Вера защиты, долга, клятв и ответственности. Последователь Света ценится за тех, кого он сумел защитить.',
 'Защитные и поддерживающие заклинания, защитные действия, поручения защиты и исполненные клятвы.',
 'Нарушение клятвы, предательство принятого долга и сделки Бездны.',25,10),
('old_roots','Старые Корни','Ты часть мира, а не его хозяин.',
 'Древняя вера в жизнь, землю, духов мест и естественный порядок.',
 'Исследование дикой природы, экспедиции в wilderness, природные поручения и исполненные клятвы.',
 'Охота — тяжёлое табу. Само начало охоты считается нарушением; успешная охота усугубляет его.',25,20),
('star_covenant','Звёздный Завет','Неведение следует преодолеть.',
 'Мистическая традиция знания, магии, звёзд и поиска скрытого устройства мира.',
 'Изучение и применение магии, исследования, новые земли, магические и исследовательские поручения.',
 'Сознательное уничтожение знания и нарушение клятв Завета.',25,30),
('abyss','Бездна','Сила имеет цену.',
 'Запретная традиция воли, риска, сделок и добровольно принятой цены за силу.',
 'Опасные подземелья, боссы, боевые поручения, жертвы ценного имущества и исполненные сделки.',
 'Нарушить собственную сделку или отказаться платить уже принятую цену.',25,40);

insert into public.religion_level_perks(religion_slug,level,title,description,modifiers) values
('path_of_light',1,'Крепость духа','+1 к Живучести.','{"vitality":1}'),
('path_of_light',2,'Стойка хранителя','Блок и защитные стойки сильнее на 3 п.п.','{"guard_boost":3}'),
('path_of_light',3,'Ясность долга','+1 к Удаче.','{"luck":1}'),
('path_of_light',4,'Священная стойкость','+3% сопротивления режущему, колющему и дробящему урону.','{"resistances":{"slashing":3,"piercing":3,"blunt":3}}'),
('path_of_light',5,'Не отступать','При низком ОЗ входящий урон снижается ещё на 5%.','{"low_hp_damage_reduction":5}'),
('path_of_light',6,'Закалённая вера','Ещё +1 к Живучести.','{"vitality":1}'),
('path_of_light',7,'Истинный щит','Ещё +4 п.п. к эффективности блока.','{"guard_boost":4}'),
('path_of_light',8,'Стена Света','Ещё +3% ко всем трём физическим сопротивлениям.','{"resistances":{"slashing":3,"piercing":3,"blunt":3}}'),
('path_of_light',9,'Последний рубеж','Ещё +5% снижения урона при низком ОЗ.','{"low_hp_damage_reduction":5}'),
('path_of_light',10,'Первый Обет','+1 Живучесть, +1 Удача, +3 п.п. блока, +2% защиты при низком ОЗ и +2% физических сопротивлений. Выдаётся Эгида Первого Обета.','{"vitality":1,"luck":1,"guard_boost":3,"low_hp_damage_reduction":2,"resistances":{"slashing":2,"piercing":2,"blunt":2}}'),

('old_roots',1,'Сок земли','+1 к Живучести.','{"vitality":1}'),
('old_roots',2,'Память камня','+5% сопротивления земле.','{"resistances":{"earth":5}}'),
('old_roots',3,'Звериная поступь','+1 к Ловкости.','{"agility":1}'),
('old_roots',4,'Память воды','+5% сопротивления воде.','{"resistances":{"water":5}}'),
('old_roots',5,'Глубокие корни','Ещё +1 к Живучести.','{"vitality":1}'),
('old_roots',6,'Кора хранителя','+3% сопротивления режущему, колющему и дробящему урону.','{"resistances":{"slashing":3,"piercing":3,"blunt":3}}'),
('old_roots',7,'След без шума','Ещё +1 к Ловкости.','{"agility":1}'),
('old_roots',8,'Круг сезонов','+3% земли, +3% воды и +8% льда.','{"resistances":{"earth":3,"water":3,"ice":8}}'),
('old_roots',9,'Древняя кровь','Ещё +1 к Живучести.','{"vitality":1}'),
('old_roots',10,'Сердце чащи','+1 Живучесть, +1 Ловкость, +2% физических сопротивлений и +2% земли, воды и льда. Выдаётся Мантия Старых Корней.','{"vitality":1,"agility":1,"resistances":{"slashing":2,"piercing":2,"blunt":2,"earth":2,"water":2,"ice":2}}'),

('star_covenant',1,'Первая звезда','+1 к Интеллекту.','{"intellect":1}'),
('star_covenant',2,'Отголосок эфира','Успешный удар возвращает ещё 1 ману.','{"mana_on_hit":1}'),
('star_covenant',3,'Знак пути','+1 к Удаче.','{"luck":1}'),
('star_covenant',4,'Начертание силы','Магический урон +3%.','{"magic_damage_bonus":3}'),
('star_covenant',5,'Второй круг','Ещё +1 к Интеллекту.','{"intellect":1}'),
('star_covenant',6,'Эфирный поток','Ещё +1 мана за успешный удар.','{"mana_on_hit":1}'),
('star_covenant',7,'Чтение знаков','Ещё +1 к Удаче.','{"luck":1}'),
('star_covenant',8,'Созвездие силы','Ещё +4% магического урона.','{"magic_damage_bonus":4}'),
('star_covenant',9,'Глубокое созерцание','Ещё +1 к Интеллекту.','{"intellect":1}'),
('star_covenant',10,'За гранью неба','+1 Интеллект, +1 Удача, +2 маны за удар и +3% магического урона. Выдаётся Венец Звёздного Завета.','{"intellect":1,"luck":1,"mana_on_hit":2,"magic_damage_bonus":3}'),

('abyss',1,'Воля взять','+1 к Силе.','{"strength":1}'),
('abyss',2,'Первая цена','Вампиризм +2%.','{"lifesteal":2}'),
('abyss',3,'Запретное понимание','+1 к Интеллекту.','{"intellect":1}'),
('abyss',4,'Жажда силы','Весь прямой урон +3%.','{"all_damage_bonus":3}'),
('abyss',5,'Взгляд на чудовище','Урон боссам +5%.','{"boss_damage_bonus":5}'),
('abyss',6,'Закалённая воля','Ещё +1 Сила и +1 Интеллект.','{"strength":1,"intellect":1}'),
('abyss',7,'Кровавая плата','Ещё +2% вампиризма.','{"lifesteal":2}'),
('abyss',8,'Снять цепи','Ещё +4% всего прямого урона.','{"all_damage_bonus":4}'),
('abyss',9,'Не склоняться','Ещё +5% урона боссам.','{"boss_damage_bonus":5}'),
('abyss',10,'Сердце Бездны','+1 Сила, +1 Интеллект, +2% вампиризма, +3% всего урона и +5% урона боссам. Выдаётся Реликвия Сердца Бездны.','{"strength":1,"intellect":1,"lifesteal":2,"all_damage_bonus":3,"boss_damage_bonus":5}');

insert into public.item_definitions(
  slug,name,description,category,rarity,equip_group,stackable,max_stack,
  stat_modifiers,effects,base_value,required_level,shop_tier,shop_price,shop_enabled,
  damage_resistances,unique_property_name,unique_property_description,
  unique_effect_type,unique_effect_value,religion_origin_slug
) values
('aegis_first_oath','Эгида Первого Обета',
 'Щит, который получают лишь те, чья вера в Путь Света достигла предела.',
 'armor','unique','offhand',false,1,'{"vitality":5,"luck":2}','[]',0,10,0,0,false,
 '{"slashing":6,"piercing":6,"blunt":6}',
 'Нерушимый Обет','После ухода из Пути Света сила реликта уменьшается на 20%, но он остаётся рабочим.',
 'guard_boost',10,'path_of_light'),
('mantle_old_roots','Мантия Старых Корней',
 'Живая броня из переплетённых волокон и древней коры.',
 'armor','unique','chest',false,1,'{"vitality":6,"agility":3}','[]',0,10,0,0,false,
 '{"earth":10,"water":8,"ice":8}',
 'Живая кора','После отречения сила реликта уменьшается на 20%, но он не перестаёт работать.',
 null,0,'old_roots'),
('crown_star_covenant','Венец Звёздного Завета',
 'Тёмный венец с холодным звёздным блеском.',
 'armor','unique','head',false,1,'{"intellect":6,"luck":4}','[]',0,10,0,0,false,
 '{"lightning":6,"ice":6}',
 'Звёздный проводник','После ухода из Завета сила реликта уменьшается на 20%.',
 'mana_on_hit',5,'star_covenant'),
('relic_abyss_heart','Реликвия Сердца Бездны',
 'Тёмный амулет, будто отзывающийся на пульс владельца.',
 'accessory','unique','accessory',false,1,'{"strength":4,"intellect":4}','[]',0,10,0,0,false,
 '{}',
 'Цена силы','После разрыва с Бездной сила реликта уменьшается на 20%, но он не исчезает.',
 'lifesteal',6,'abyss');

update public.religion_definitions r
set level10_reward_item_id=i.id
from public.item_definitions i
where (r.slug='path_of_light' and i.slug='aegis_first_oath')
   or (r.slug='old_roots' and i.slug='mantle_old_roots')
   or (r.slug='star_covenant' and i.slug='crown_star_covenant')
   or (r.slug='abyss' and i.slug='relic_abyss_heart');

insert into public.religion_oath_definitions(
  religion_slug,slug,name,description,success_event_type,success_metadata,target_count,
  failure_event_type,failure_metadata,faith_reward,favor_reward,failure_faith_penalty,failure_favor_penalty,sort_order
) values
('path_of_light','service','Клятва Служения','Выполни 3 поручения поселений.','settlement_quest_completed','{}',3,null,'{}',70,5,45,6,10),
('path_of_light','shield','Клятва Щита','Совершить 10 защитных или поддерживающих действий в бою.','support_action','{}',10,null,'{}',65,5,45,6,20),
('path_of_light','fellowship','Клятва Верности','Заверши групповое подземелье вместе с группой.','party_dungeon_completed','{}',1,null,'{}',90,7,55,8,30),

('old_roots','no_hunt','Клятва Невредимой Жизни','Заверши 5 экспедиций в дикой природе, ни разу не начав охоту после принятия клятвы.','wilderness_expedition_completed','{}',5,'hunting_started','{}',90,7,70,12,10),
('old_roots','pathfinder','Клятва Странника','Открой 5 новых wilderness-секторов.','sector_discovered','{"content_type":"wilderness"}',5,null,'{}',75,5,50,7,20),
('old_roots','balance','Клятва Равновесия','Выполни 3 природных поручения поселений.','settlement_quest_completed','{"theme":"nature"}',3,null,'{}',80,6,50,7,30),

('star_covenant','archive','Клятва Архивариуса','Изучи новое заклинание.','spell_learned','{}',1,null,'{}',90,6,50,7,10),
('star_covenant','practice','Клятва Практики','Примени магию или изученные заклинания 20 раз в реальном бою.','spell_cast','{}',20,null,'{}',70,5,45,6,20),
('star_covenant','seeker','Клятва Искателя','Открой 5 новых секторов.','sector_discovered','{}',5,null,'{}',75,5,45,6,30),

('abyss','depths','Сделка Глубины','Полностью пройди 3 обычных подземелья.','dungeon_completed','{}',3,null,'{}',80,6,60,8,10),
('abyss','boss','Сделка Хищника','Одолей мирового event-босса.','event_boss_victory','{}',1,null,'{}',110,9,70,10,20),
('abyss','price','Сделка Цены','Пожертвуй Бездне предмет редкости Rare или выше.','item_sacrificed','{}',1,null,'{}',80,7,60,8,30);

create or replace function private.religion_level_threshold(p_level integer)
returns integer language sql immutable strict set search_path='' as $$
  select case p_level
    when 1 then 0 when 2 then 100 when 3 then 220 when 4 then 380 when 5 then 580
    when 6 then 820 when 7 then 1100 when 8 then 1420 when 9 then 1780 else 2200 end;
$$;

create or replace function private.religion_level(p_faith integer)
returns smallint language sql immutable strict set search_path='' as $$
  select (case
    when p_faith>=2200 then 10 when p_faith>=1780 then 9 when p_faith>=1420 then 8
    when p_faith>=1100 then 7 when p_faith>=820 then 6 when p_faith>=580 then 5
    when p_faith>=380 then 4 when p_faith>=220 then 3 when p_faith>=100 then 2 else 1 end)::smallint;
$$;

revoke all on function private.religion_level_threshold(integer) from public,anon,authenticated;
revoke all on function private.religion_level(integer) from public,anon,authenticated;

create or replace function private.character_religion_modifiers(p_character_id uuid)
returns jsonb language sql stable security definer
set search_path=pg_catalog,public,private as $$
with state as (
  select cr.current_religion_slug religion_slug,
         private.religion_level(coalesce(cp.faith_points,0)) religion_level
  from public.character_religions cr
  left join public.character_religion_progress cp
    on cp.character_id=cr.character_id and cp.religion_slug=cr.current_religion_slug
  where cr.character_id=p_character_id and cr.current_religion_slug is not null
), perks as (
  select p.modifiers
  from state s join public.religion_level_perks p
    on p.religion_slug=s.religion_slug and p.level<=s.religion_level
)
select jsonb_build_object(
  'strength',coalesce(sum(case when jsonb_typeof(modifiers->'strength')='number' then (modifiers->>'strength')::int else 0 end),0),
  'agility',coalesce(sum(case when jsonb_typeof(modifiers->'agility')='number' then (modifiers->>'agility')::int else 0 end),0),
  'intellect',coalesce(sum(case when jsonb_typeof(modifiers->'intellect')='number' then (modifiers->>'intellect')::int else 0 end),0),
  'vitality',coalesce(sum(case when jsonb_typeof(modifiers->'vitality')='number' then (modifiers->>'vitality')::int else 0 end),0),
  'luck',coalesce(sum(case when jsonb_typeof(modifiers->'luck')='number' then (modifiers->>'luck')::int else 0 end),0),
  'lifesteal',coalesce(sum(case when jsonb_typeof(modifiers->'lifesteal')='number' then (modifiers->>'lifesteal')::int else 0 end),0),
  'mana_on_hit',coalesce(sum(case when jsonb_typeof(modifiers->'mana_on_hit')='number' then (modifiers->>'mana_on_hit')::int else 0 end),0),
  'guard_boost',coalesce(sum(case when jsonb_typeof(modifiers->'guard_boost')='number' then (modifiers->>'guard_boost')::int else 0 end),0),
  'all_damage_bonus',coalesce(sum(case when jsonb_typeof(modifiers->'all_damage_bonus')='number' then (modifiers->>'all_damage_bonus')::int else 0 end),0),
  'physical_damage_bonus',coalesce(sum(case when jsonb_typeof(modifiers->'physical_damage_bonus')='number' then (modifiers->>'physical_damage_bonus')::int else 0 end),0),
  'magic_damage_bonus',coalesce(sum(case when jsonb_typeof(modifiers->'magic_damage_bonus')='number' then (modifiers->>'magic_damage_bonus')::int else 0 end),0),
  'low_hp_damage_reduction',coalesce(sum(case when jsonb_typeof(modifiers->'low_hp_damage_reduction')='number' then (modifiers->>'low_hp_damage_reduction')::int else 0 end),0),
  'boss_damage_bonus',coalesce(sum(case when jsonb_typeof(modifiers->'boss_damage_bonus')='number' then (modifiers->>'boss_damage_bonus')::int else 0 end),0),
  'resistances',jsonb_build_object(
    'slashing',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'slashing')='number' then (modifiers->'resistances'->>'slashing')::int else 0 end),0),
    'piercing',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'piercing')='number' then (modifiers->'resistances'->>'piercing')::int else 0 end),0),
    'blunt',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'blunt')='number' then (modifiers->'resistances'->>'blunt')::int else 0 end),0),
    'fire',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'fire')='number' then (modifiers->'resistances'->>'fire')::int else 0 end),0),
    'water',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'water')='number' then (modifiers->'resistances'->>'water')::int else 0 end),0),
    'earth',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'earth')='number' then (modifiers->'resistances'->>'earth')::int else 0 end),0),
    'air',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'air')='number' then (modifiers->'resistances'->>'air')::int else 0 end),0),
    'lightning',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'lightning')='number' then (modifiers->'resistances'->>'lightning')::int else 0 end),0),
    'ice',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'ice')='number' then (modifiers->'resistances'->>'ice')::int else 0 end),0)
  )
) from perks;
$$;

revoke all on function private.character_religion_modifiers(uuid) from public,anon,authenticated;

create or replace function private.refresh_religious_item_penalties(p_character_id uuid)
returns void language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare
  current_slug text;
  row_item record;
  stat_penalty jsonb;
  resistance_penalty jsonb;
  unique_penalty jsonb;
  weapon_penalty integer;
begin
  select current_religion_slug into current_slug
  from public.character_religions where character_id=p_character_id;

  for row_item in
    select ci.id,idf.stat_modifiers,idf.damage_resistances,idf.unique_effect_type,
           idf.unique_effect_value,idf.weapon_base_damage,idf.religion_origin_slug
    from public.character_items ci
    join public.item_definitions idf on idf.id=ci.item_definition_id
    where ci.character_id=p_character_id and idf.religion_origin_slug is not null
  loop
    if current_slug is not distinct from row_item.religion_origin_slug then
      update public.character_items
      set metadata=(coalesce(metadata,'{}'::jsonb)
        - 'religion_stat_modifiers' - 'religion_damage_resistances'
        - 'religion_unique_effects' - 'religion_weapon_base_damage_penalty'
        - 'religion_weakened')
        || jsonb_build_object('religion_weakened',false)
      where id=row_item.id;
    else
      select coalesce(jsonb_object_agg(key,
        to_jsonb(-ceil(abs((value::text)::numeric)*0.20)::integer
          * case when (value::text)::numeric>=0 then 1 else -1 end)),'{}'::jsonb)
      into stat_penalty
      from jsonb_each(coalesce(row_item.stat_modifiers,'{}'::jsonb))
      where jsonb_typeof(value)='number';

      select coalesce(jsonb_object_agg(key,
        to_jsonb(-ceil(abs((value::text)::numeric)*0.20)::integer
          * case when (value::text)::numeric>=0 then 1 else -1 end)),'{}'::jsonb)
      into resistance_penalty
      from jsonb_each(coalesce(row_item.damage_resistances,'{}'::jsonb))
      where jsonb_typeof(value)='number';

      unique_penalty:='{}'::jsonb;
      if row_item.unique_effect_type is not null and row_item.unique_effect_value<>0 then
        unique_penalty:=jsonb_build_object(
          row_item.unique_effect_type,
          -ceil(abs(row_item.unique_effect_value)*0.20)::integer
            * case when row_item.unique_effect_value>=0 then 1 else -1 end
        );
      end if;

      weapon_penalty:=case when row_item.weapon_base_damage>0
        then -ceil(row_item.weapon_base_damage*0.20)::integer else 0 end;

      update public.character_items
      set metadata=(coalesce(metadata,'{}'::jsonb)
        - 'religion_stat_modifiers' - 'religion_damage_resistances'
        - 'religion_unique_effects' - 'religion_weapon_base_damage_penalty'
        - 'religion_weakened')
        || jsonb_build_object(
          'religion_stat_modifiers',stat_penalty,
          'religion_damage_resistances',resistance_penalty,
          'religion_unique_effects',unique_penalty,
          'religion_weapon_base_damage_penalty',weapon_penalty,
          'religion_weakened',true
        )
      where id=row_item.id;
    end if;
  end loop;
end;
$$;

revoke all on function private.refresh_religious_item_penalties(uuid) from public,anon,authenticated;

create or replace function private.grant_religion_level10_reward(p_character_id uuid,p_religion_slug text)
returns text language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare prog public.character_religion_progress; reward public.item_definitions;
begin
  select * into prog
  from public.character_religion_progress
  where character_id=p_character_id and religion_slug=p_religion_slug
  for update;

  if prog.character_id is null or private.religion_level(prog.faith_points)<10
     or prog.level10_reward_claimed then return null; end if;

  select i.* into reward
  from public.religion_definitions r join public.item_definitions i on i.id=r.level10_reward_item_id
  where r.slug=p_religion_slug;
  if reward.id is null then return null; end if;

  insert into public.character_items(character_id,item_definition_id,quantity,metadata)
  values(p_character_id,reward.id,1,
    jsonb_build_object('religion_reward',true,'religion_origin_slug',p_religion_slug,'religion_weakened',false));

  update public.character_religion_progress
  set level10_reward_claimed=true,updated_at=now()
  where character_id=p_character_id and religion_slug=p_religion_slug;

  perform private.refresh_religious_item_penalties(p_character_id);
  return reward.name;
end;
$$;

revoke all on function private.grant_religion_level10_reward(uuid,text) from public,anon,authenticated;
