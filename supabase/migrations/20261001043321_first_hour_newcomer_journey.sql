insert into public.item_definitions(
  slug,name,description,category,rarity,stackable,max_stack,base_value,shop_enabled,required_level
)
values(
  'first_road_token',
  'Знак первой дороги',
  'Небольшой знак с насечкой Варденской дороги. Память о первой собственной истории в Эйларе.',
  'quest','unique',false,1,0,false,1
)
on conflict(slug) do update
set name=excluded.name,
    description=excluded.description,
    rarity=excluded.rarity,
    updated_at=now();

create table if not exists public.character_first_journeys(
  character_id uuid primary key references public.characters(id) on delete cascade,
  stage smallint not null default 0 check(stage between 0 and 3),
  first_choice text,
  second_choice text,
  final_choice text,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.character_first_journeys enable row level security;
revoke all on public.character_first_journeys from public,anon,authenticated;

create or replace function public.get_first_journey(p_character_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $function$
declare
  caller uuid:=auth.uid();
  j public.character_first_journeys;
  result_text text;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id
      and (c.owner_user_id=caller or private.is_gm(caller))
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  insert into public.character_first_journeys(character_id)
  values(p_character_id)
  on conflict(character_id) do nothing;

  select * into j
  from public.character_first_journeys
  where character_id=p_character_id;

  result_text:=case j.stage
    when 0 then 'На дороге к Вардену пропал небольшой караван. Единственный вернувшийся путник говорит, что ночью из леса ему отвечал его собственный голос.'
    when 1 then case j.first_choice
      when 'tracks' then 'Следы ведут не от дороги, а вокруг неё, будто кто-то долго наблюдал за караваном и только потом вышел к людям.'
      when 'survivor' then 'Выживший вспоминает деталь: голос повторял не последние слова, а фразы, сказанные несколько часов назад.'
      else 'В брошенном грузе ты находишь ткань с тонким серым налётом. Такой же след уходит в сторону лесной низины.'
    end
    when 2 then 'Источник голосов найден. Между деревьями двигается Существо Чужого Голоса — оно приманивало людей знакомыми фразами и собирало их вещи у старого каменного круга.'
    else 'Первая глава завершена. В хронике персонажа появилась запись «Эхо дороги».'
  end;

  return jsonb_build_object(
    'stage',j.stage,
    'first_choice',j.first_choice,
    'second_choice',j.second_choice,
    'final_choice',j.final_choice,
    'completed_at',j.completed_at,
    'title',case when j.stage<3 then 'Эхо дороги' else 'Первая глава завершена' end,
    'text',result_text,
    'choices',case j.stage
      when 0 then jsonb_build_array(
        jsonb_build_object('id','tracks','title','Идти по следам','description','Сразу искать маршрут пропавших.'),
        jsonb_build_object('id','survivor','title','Расспросить выжившего','description','Сначала понять, что именно произошло ночью.'),
        jsonb_build_object('id','cargo','title','Осмотреть груз','description','Искать то, что враг мог оставить на вещах.')
      )
      when 1 then jsonb_build_array(
        jsonb_build_object('id','voice','title','Ответить голосу','description','Выманить источник звука на себя.'),
        jsonb_build_object('id','trap','title','Подготовить ловушку','description','Использовать местность и заставить врага раскрыться.'),
        jsonb_build_object('id','silence','title','Идти молча','description','Не давать существу новых слов и следить за движением леса.')
      )
      when 2 then jsonb_build_array(
        jsonb_build_object('id','pressure','title','Давить без паузы','description','Не дать существу снова скрыться между голосами.'),
        jsonb_build_object('id','guard','title','Переждать выпад','description','Спровоцировать атаку и ответить после неё.'),
        jsonb_build_object('id','pattern','title','Разрушить его ритм','description','Использовать найденные подсказки и ударить в момент подмены голоса.')
      )
      else '[]'::jsonb
    end,
    'reward',jsonb_build_object(
      'gold',60,
      'experience',80,
      'item_name','Знак первой дороги'
    )
  );
end;
$function$;

create or replace function public.advance_first_journey(
  p_character_id uuid,
  p_choice text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $function$
declare
  caller uuid:=auth.uid();
  j public.character_first_journeys;
  reward_item public.item_definitions;
  first_text text;
  second_text text;
  final_text text;
  chronicle_text text;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  insert into public.character_first_journeys(character_id)
  values(p_character_id)
  on conflict(character_id) do nothing;

  select * into j
  from public.character_first_journeys
  where character_id=p_character_id
  for update;

  if j.stage=0 then
    if p_choice not in ('tracks','survivor','cargo') then raise exception 'INVALID_STORY_CHOICE'; end if;
    update public.character_first_journeys
    set stage=1,first_choice=p_choice,updated_at=now()
    where character_id=p_character_id;

  elsif j.stage=1 then
    if p_choice not in ('voice','trap','silence') then raise exception 'INVALID_STORY_CHOICE'; end if;
    update public.character_first_journeys
    set stage=2,second_choice=p_choice,updated_at=now()
    where character_id=p_character_id;

  elsif j.stage=2 then
    if p_choice not in ('pressure','guard','pattern') then raise exception 'INVALID_STORY_CHOICE'; end if;

    update public.character_first_journeys
    set stage=3,final_choice=p_choice,completed_at=now(),updated_at=now()
    where character_id=p_character_id;

    select * into reward_item
    from public.item_definitions
    where slug='first_road_token';

    if reward_item.id is not null
       and not exists(
         select 1 from public.character_items ci
         where ci.character_id=p_character_id
           and ci.item_definition_id=reward_item.id
           and ci.death_spirit_id is null
       )
    then
      perform private.grant_character_item(
        p_character_id,reward_item.id,1,
        jsonb_build_object('source','first_journey','story','echo_road')
      );
    end if;

    update public.character_progress
    set gold=gold+60,
        experience=experience+80,
        updated_at=now()
    where character_id=p_character_id;

    first_text:=case j.first_choice
      when 'tracks' then 'пошёл по следам пропавшего каравана'
      when 'survivor' then 'сначала выслушал единственного выжившего'
      else 'начал с осмотра брошенного груза'
    end;
    second_text:=case j.second_choice
      when 'voice' then 'выманил источник голосов ответом'
      when 'trap' then 'подготовил ловушку в лесной низине'
      else 'прошёл к каменному кругу, не дав существу новых слов'
    end;
    final_text:=case p_choice
      when 'pressure' then 'не дал Существу Чужого Голоса снова скрыться и задавил его непрерывной атакой'
      when 'guard' then 'пережил его выпад и закончил бой ответным ударом'
      else 'распознал ритм подмены голоса и ударил в момент, когда существо раскрылось'
    end;

    chronicle_text:='Первое приключение: Эхо дороги. Персонаж '||first_text||', '||second_text||' и '||final_text||'.';

    perform private.record_discovery(
      p_character_id,
      'chronicle',
      'first_journey_echo_road',
      'Первая глава: Эхо дороги',
      chronicle_text,
      jsonb_build_object(
        'first_choice',j.first_choice,
        'second_choice',j.second_choice,
        'final_choice',p_choice,
        'reward_item','first_road_token'
      )
    );
  else
    raise exception 'FIRST_JOURNEY_ALREADY_COMPLETED';
  end if;

  return public.get_first_journey(p_character_id);
end;
$function$;

create or replace function public.get_newcomer_world_activity(p_character_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $function$
declare
  caller uuid:=auth.uid();
  feed jsonb;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id
      and (c.owner_user_id=caller or private.is_gm(caller))
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'kind',x.kind,
    'title',x.title,
    'text',x.body,
    'occurred_at',x.occurred_at
  ) order by x.occurred_at desc),'[]'::jsonb)
  into feed
  from (
    select *
    from (
      select
        'boss'::text kind,
        c.name||' победил босса' title,
        e.name||' · '||
          case e.boss_kind
            when 'weekly' then 'недельная угроза'
            when 'monthly' then 'месячная угроза'
            when 'world_enemy' then 'мировой босс'
            when 'raid' then 'рейдовый босс'
            else 'событие мира'
          end body,
        ec.last_victory_at occurred_at
      from public.event_boss_completions ec
      join public.characters c on c.id=ec.character_id
      join public.event_boss_events e on e.id=ec.event_id
      where ec.last_victory_at>=now()-interval '14 days'

      union all

      select
        'chronicle',
        c.name||' начал свою хронику',
        d.title,
        d.last_seen_at
      from public.character_discoveries d
      join public.characters c on c.id=d.character_id
      where d.category='chronicle'
        and d.last_seen_at>=now()-interval '14 days'

      union all

      select
        'discovery',
        c.name||' сделал редкое открытие',
        d.title,
        d.last_seen_at
      from public.character_discoveries d
      join public.characters c on c.id=d.character_id
      where d.category in ('ancient_restoration','rare_boss','treasure')
        and d.last_seen_at>=now()-interval '14 days'
    ) q
    order by occurred_at desc
    limit 6
  ) x;

  return feed;
end;
$function$;

revoke all on function public.get_first_journey(uuid) from public,anon;
revoke all on function public.advance_first_journey(uuid,text) from public,anon;
revoke all on function public.get_newcomer_world_activity(uuid) from public,anon;
grant execute on function public.get_first_journey(uuid) to authenticated;
grant execute on function public.advance_first_journey(uuid,text) to authenticated;
grant execute on function public.get_newcomer_world_activity(uuid) to authenticated;
