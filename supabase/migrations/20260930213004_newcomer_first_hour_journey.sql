
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

create table if not exists public.character_newcomer_journeys(
  character_id uuid primary key references public.characters(id) on delete cascade,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  dismissed_at timestamptz,
  stage smallint not null default 0 check(stage between 0 and 3),
  approach text,
  preparation text,
  trial_hp integer not null default 0,
  trial_hp_max integer not null default 0,
  boss_hp integer not null default 0,
  boss_hp_max integer not null default 0,
  guard_active boolean not null default false,
  clue_power integer not null default 0,
  round integer not null default 0,
  battle_log jsonb not null default '[]'::jsonb,
  reward_claimed boolean not null default false,
  updated_at timestamptz not null default now()
);

alter table public.character_newcomer_journeys enable row level security;
revoke all on public.character_newcomer_journeys from public,anon,authenticated;

CREATE OR REPLACE FUNCTION private.newcomer_journey_state(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  j public.character_newcomer_journeys;
  account_created timestamptz;
  reward_name text;
begin
  select u.created_at
  into account_created
  from public.characters c
  join auth.users u on u.id=c.owner_user_id
  where c.id=p_character_id;

  if account_created is null then
    raise exception 'CHARACTER_NOT_FOUND';
  end if;

  select * into j
  from public.character_newcomer_journeys
  where character_id=p_character_id;

  select name into reward_name
  from public.item_definitions
  where slug='first_road_token';

  if j.character_id is null then
    return jsonb_build_object(
      'available',false,
      'account_created_at',account_created,
      'handbook_visible_until',account_created+interval '3 days',
      'reward_name',coalesce(reward_name,'Знак первой дороги')
    );
  end if;

  return to_jsonb(j)||jsonb_build_object(
    'available',true,
    'account_created_at',account_created,
    'handbook_visible_until',account_created+interval '3 days',
    'reward_name',coalesce(reward_name,'Знак первой дороги')
  );
end;
$function$


CREATE OR REPLACE FUNCTION public.choose_newcomer_journey(p_character_id uuid, p_choice text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
  j public.character_newcomer_journeys;
  stats record;
  next_hp integer;
  next_boss_hp integer;
  next_boss_max integer;
  next_clue integer:=0;
  next_log jsonb:='[]'::jsonb;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters
    where id=p_character_id and owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select * into j
  from public.character_newcomer_journeys
  where character_id=p_character_id
  for update;

  if j.character_id is null then raise exception 'NEWCOMER_JOURNEY_NOT_AVAILABLE'; end if;
  if j.completed_at is not null then return private.newcomer_journey_state(p_character_id); end if;

  if j.stage=0 then
    if p_choice not in ('tracks','witness','cargo') then raise exception 'INVALID_NEWCOMER_CHOICE'; end if;

    update public.character_newcomer_journeys
    set approach=p_choice,
        stage=1,
        updated_at=now()
    where character_id=p_character_id;

  elsif j.stage=1 then
    if p_choice not in ('ambush','ward','listen') then raise exception 'INVALID_NEWCOMER_CHOICE'; end if;

    select * into stats from private.get_character_combat_stats(p_character_id);

    next_boss_max:=greatest(115,95+coalesce(stats.level,1)*18);
    next_boss_hp:=next_boss_max;
    next_hp:=greatest(105,90+coalesce(stats.level,1)*8+coalesce(stats.vitality,3)*3);

    if p_choice='ambush' then
      next_boss_hp:=greatest(1,round(next_boss_max*0.84)::integer);
      next_log:=jsonb_build_array('Ты начинаешь бой первым: Отзвук уже ранен.');
    elsif p_choice='ward' then
      next_hp:=next_hp+30;
      next_log:=jsonb_build_array('Ты укрепляешь защиту перед столкновением.');
    else
      next_clue:=1;
      next_log:=jsonb_build_array('Ты запоминаешь ритм чужого голоса и находишь слабое место.');
    end if;

    if j.approach='witness' then next_clue:=greatest(next_clue,1); end if;
    if j.approach='cargo' then next_hp:=next_hp+10; end if;

    update public.character_newcomer_journeys
    set preparation=p_choice,
        stage=2,
        trial_hp=next_hp,
        trial_hp_max=next_hp,
        boss_hp=next_boss_hp,
        boss_hp_max=next_boss_max,
        clue_power=next_clue,
        guard_active=false,
        round=1,
        battle_log=next_log,
        updated_at=now()
    where character_id=p_character_id;

  else
    raise exception 'NEWCOMER_CHOICE_NOT_EXPECTED';
  end if;

  return private.newcomer_journey_state(p_character_id);
end;
$function$


CREATE OR REPLACE FUNCTION public.dismiss_newcomer_journey(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters
    where id=p_character_id and owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  update public.character_newcomer_journeys
  set dismissed_at=now(),updated_at=now()
  where character_id=p_character_id and completed_at is not null;

  return private.newcomer_journey_state(p_character_id);
end;
$function$


CREATE OR REPLACE FUNCTION public.get_newcomer_journey(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
  account_created timestamptz;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  select u.created_at
  into account_created
  from public.characters c
  join auth.users u on u.id=c.owner_user_id
  where c.id=p_character_id and c.owner_user_id=caller;

  if account_created is null then raise exception 'CHARACTER_NOT_OWNED'; end if;

  if not exists(
    select 1 from public.character_newcomer_journeys
    where character_id=p_character_id
  ) and account_created>=now()-interval '3 days' then
    insert into public.character_newcomer_journeys(character_id)
    values(p_character_id)
    on conflict(character_id) do nothing;
  end if;

  return private.newcomer_journey_state(p_character_id);
end;
$function$


CREATE OR REPLACE FUNCTION public.perform_newcomer_journey_action(p_character_id uuid, p_action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
  j public.character_newcomer_journeys;
  stats record;
  reward_def public.item_definitions;
  player_base integer:=0;
  player_damage integer:=0;
  enemy_base integer:=0;
  enemy_damage integer:=0;
  defense_value integer:=0;
  incoming_reduction integer:=0;
  new_boss_hp integer;
  new_player_hp integer;
  log_line text;
  next_log jsonb;
  chronicle_text text;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters
    where id=p_character_id and owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select * into j
  from public.character_newcomer_journeys
  where character_id=p_character_id
  for update;

  if j.character_id is null or j.stage<>2 or j.completed_at is not null then
    raise exception 'NEWCOMER_FIGHT_NOT_ACTIVE';
  end if;

  if p_action not in ('strike','guard','insight') then
    raise exception 'INVALID_NEWCOMER_ACTION';
  end if;
  if p_action='insight' and j.clue_power<=0 then
    raise exception 'NEWCOMER_INSIGHT_SPENT';
  end if;

  select * into stats from private.get_character_combat_stats(p_character_id);

  player_base:=greatest(
    16,
    round(greatest(
      coalesce(stats.physical_power,20)::numeric,
      coalesce(stats.magic_power,20)::numeric*1.05
    )*0.58)::integer
  );

  if j.approach='tracks' then
    player_base:=round(player_base*1.08)::integer;
  end if;

  if p_action='strike' then
    player_damage:=greatest(10,player_base+floor(random()*7)::integer-3);
    incoming_reduction:=0;
    log_line:='Ты бьёшь в открывшийся силуэт и наносишь '||player_damage||' урона.';
  elsif p_action='guard' then
    player_damage:=0;
    incoming_reduction:=60;
    log_line:='Ты не гонишься за уроном и встречаешь ответ подготовленным.';
  else
    player_damage:=greatest(
      14,
      round(player_base*1.05)::integer+round(j.boss_hp_max*0.08)::integer
    );
    incoming_reduction:=35;
    log_line:='Ты используешь найденную закономерность: '||player_damage||' урона и безопасное окно.';
  end if;

  new_boss_hp:=greatest(0,j.boss_hp-player_damage);
  new_player_hp:=j.trial_hp;
  next_log:=coalesce(j.battle_log,'[]'::jsonb)||jsonb_build_array(log_line);

  if new_boss_hp>0 then
    defense_value:=greatest(0,coalesce(stats.defense,0)::integer);
    enemy_base:=greatest(
      12,
      private.damage_after_armor(24+coalesce(stats.level,1)*5,defense_value)
    );
    enemy_damage:=greatest(
      1,
      round(enemy_base*(100-incoming_reduction)/100.0)::integer
    );
    new_player_hp:=greatest(0,new_player_hp-enemy_damage);
    next_log:=next_log||jsonb_build_array('Отзвук отвечает: -'||enemy_damage||' ОЗ испытания.');
  end if;

  if new_boss_hp<=0 then
    select * into reward_def from public.item_definitions where slug='first_road_token';

    if reward_def.id is not null and not exists(
      select 1 from public.character_items
      where character_id=p_character_id and item_definition_id=reward_def.id
    ) then
      perform private.grant_character_item(
        p_character_id,reward_def.id,1,
        jsonb_build_object('source','newcomer_journey','story','echo_of_the_road')
      );
    end if;

    if not j.reward_claimed then
      update public.character_progress
      set gold=gold+120,updated_at=now()
      where character_id=p_character_id;
    end if;

    chronicle_text:=
      case j.approach
        when 'tracks' then 'Пошёл по следам пропавшего каравана и не дал лесу сбить себя с пути. '
        when 'witness' then 'Выслушал единственного свидетеля и заметил закономерность в чужом голосе. '
        else 'Осмотрел оставленный груз и нашёл то, что караванщики не успели понять. '
      end
      ||case j.preparation
        when 'ambush' then 'Подготовил засаду и первым ранил существо. '
        when 'ward' then 'Выбрал осторожность и пережил столкновение за счёт подготовки. '
        else 'Запомнил ритм эха и обратил слабость существа против него. '
      end
      ||'Победил Отзвук дороги и вернулся в Варден со Знаком первой дороги.';

    perform private.record_discovery(
      p_character_id,
      'chronicle',
      'first_road',
      'Эхо дороги',
      chronicle_text,
      jsonb_build_object(
        'approach',j.approach,
        'preparation',j.preparation,
        'reward','first_road_token'
      )
    );

    update public.character_newcomer_journeys
    set stage=3,
        boss_hp=0,
        trial_hp=new_player_hp,
        completed_at=now(),
        reward_claimed=true,
        clue_power=case when p_action='insight' then 0 else clue_power end,
        battle_log=next_log||jsonb_build_array('Отзвук рассыпается. Первое приключение завершено.'),
        updated_at=now()
    where character_id=p_character_id;

    return private.newcomer_journey_state(p_character_id);
  end if;

  if new_player_hp<=0 then
    update public.character_newcomer_journeys
    set trial_hp=trial_hp_max,
        boss_hp=boss_hp_max,
        round=1,
        guard_active=false,
        clue_power=case when preparation='listen' or approach='witness' then 1 else 0 end,
        battle_log=jsonb_build_array('Отзвук отбрасывает тебя к дороге. Потерь нет: можно попробовать другую тактику.'),
        updated_at=now()
    where character_id=p_character_id;

    return private.newcomer_journey_state(p_character_id);
  end if;

  update public.character_newcomer_journeys
  set trial_hp=new_player_hp,
      boss_hp=new_boss_hp,
      round=round+1,
      guard_active=false,
      clue_power=case when p_action='insight' then 0 else clue_power end,
      battle_log=next_log,
      updated_at=now()
  where character_id=p_character_id;

  return private.newcomer_journey_state(p_character_id);
end;
$function$


revoke all on function public.get_newcomer_journey(uuid) from public,anon;
revoke all on function public.choose_newcomer_journey(uuid,text) from public,anon;
revoke all on function public.perform_newcomer_journey_action(uuid,text) from public,anon;
revoke all on function public.dismiss_newcomer_journey(uuid) from public,anon;

grant execute on function public.get_newcomer_journey(uuid) to authenticated;
grant execute on function public.choose_newcomer_journey(uuid,text) to authenticated;
grant execute on function public.perform_newcomer_journey_action(uuid,text) to authenticated;
grant execute on function public.dismiss_newcomer_journey(uuid) to authenticated;
