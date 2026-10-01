
-- Enemy descriptions are flavor text only. Combat rules stay in mechanics/stats,
-- not in descriptions or counterplay copy.

update public.enemy_templates
set description=case slug
  when 'ash_forgemaster_weekly' then
    'Древний кузнечный исполин, в чьём раскалённом корпусе всё ещё гудит забытый горн.'
  when 'auto_incursion_beasts' then
    'Стая зверей, сорвавшаяся с привычных троп и заполнившая окрестности тяжёлым рыком.'
  when 'auto_incursion_marauders' then
    'Вооружённая банда, превратившая чужую землю в временную стоянку и укреплённый лагерь.'
  when 'auto_incursion_spirits' then
    'Скопление беспокойных духов, чьи голоса не умолкают даже в безветренную ночь.'
  when 'auto_incursion_aberrations' then
    'Искажённые существа неясного происхождения, оставляющие после себя след чуждой магии.'
  when 'calendar_weekly_2026_09_28_ash_matron' then
    'Пепельная Матрона несёт в груди тлеющий очаг, а за её шагами остаётся запах горячего железа и золы.'
  when 'calendar_weekly_2026_10_05_blind_duelist' then
    'Слепой воин в старом плаще, который слушает пространство вокруг себя так, будто видит каждый шорох.'
  when 'calendar_weekly_2026_10_12_storm_shepherd' then
    'Странник с обугленным посохом, вокруг которого даже в ясную погоду собираются низкие грозовые тучи.'
  when 'calendar_weekly_2026_10_19_root_devourer' then
    'Древняя болотная тварь, опутанная корнями, мхом и остатками растений, поглощённых вместе с землёй.'
  when 'calendar_weekly_2026_10_26_crystal_stag' then
    'Олень с прозрачными рогами, в которых преломляется свет, будто внутри них застыл целый зимний рассвет.'
  when 'calendar_weekly_2026_11_02_faceless_monk' then
    'Безликая фигура в монашеских одеждах, чья тихая молитва звучит сразу с нескольких сторон.'
  when 'calendar_weekly_2026_11_09_clockmaker' then
    'Высокий мастер в маске из латуни, окружённый шестернями и часами, идущими в разном ритме.'
  when 'calendar_weekly_2026_11_16_drowned_queen' then
    'Королева в потемневшей короне и мокрых одеждах, за которой по камню тянется холодная морская вода.'
  when 'calendar_weekly_2026_11_23_black_bell_prince' then
    'Князь в тяжёлых доспехах, украшенных чёрными колоколами, чей звон слышен задолго до его появления.'
  when 'calendar_weekly_2026_11_30_white_witch' then
    'Белая Ведьма идёт сквозь северный снег без следов, а её голос тонет в ветре прежде, чем достигает слуха.'
  when 'calendar_weekly_2026_12_07_empty_throne_guardian' then
    'Безмолвный страж древнего трона, переживший исчезновение хозяина и всё ещё несущий свою службу.'
  when 'calendar_weekly_2026_12_14_name_hunter' then
    'Охотник в тёмной маске, собирающий чужие имена так же бережно, как другие собирают трофеи.'
  when 'calendar_world_2026_10_22_salt_leviathan' then
    'Древний морской исполин поднялся из северных вод, покрытый солью, раковинами и следами вековых штормов.'
  when 'calendar_world_2026_11_19_aster' then
    'Небесный Червь Астэр проходит над Эйларом, оставляя в облаках длинные светящиеся разломы.'
  when 'calendar_world_2026_12_17_gravity_dragon' then
    'Дракон парит внутри искривлённого пространства, где камни падают вверх, а воздух дрожит без ветра.'
  when 'monthly_zero_hour_colossus' then
    'Каменный исполин с неподвижным циферблатом в груди. Рядом с ним время будто запинается на каждом ударе маятника.'
  when 'monthly_extinguished_seraph' then
    'Серафим с обугленными крыльями несёт над собой тёмное солнце, от которого не исходит ни света, ни тепла.'
  when 'monthly_underking' then
    'Древний король сидит под толщей гор, окружённый камнем, руинами и молчанием давно исчезнувшего двора.'
  when 'white_wolf_world_enemy' then
    'Огромный белый волк, покрытый старыми шрамами. Его следы слишком велики для обычного зверя.'
  when 'weak_scavenger' then
    'Бледный подземный падальщик, привыкший рыться в остатках добычи более крупных хищников.'
  else description
end
where slug in (
  'ash_forgemaster_weekly',
  'auto_incursion_beasts','auto_incursion_marauders','auto_incursion_spirits','auto_incursion_aberrations',
  'calendar_weekly_2026_09_28_ash_matron',
  'calendar_weekly_2026_10_05_blind_duelist',
  'calendar_weekly_2026_10_12_storm_shepherd',
  'calendar_weekly_2026_10_19_root_devourer',
  'calendar_weekly_2026_10_26_crystal_stag',
  'calendar_weekly_2026_11_02_faceless_monk',
  'calendar_weekly_2026_11_09_clockmaker',
  'calendar_weekly_2026_11_16_drowned_queen',
  'calendar_weekly_2026_11_23_black_bell_prince',
  'calendar_weekly_2026_11_30_white_witch',
  'calendar_weekly_2026_12_07_empty_throne_guardian',
  'calendar_weekly_2026_12_14_name_hunter',
  'calendar_world_2026_10_22_salt_leviathan',
  'calendar_world_2026_11_19_aster',
  'calendar_world_2026_12_17_gravity_dragon',
  'monthly_zero_hour_colossus','monthly_extinguished_seraph','monthly_underking',
  'white_wolf_world_enemy','weak_scavenger'
);

update public.event_boss_events
set description=case
  when slug='weekly_2026_09_20_ash_forgemaster' then
    'Пепельный Кузнец вышел из заброшенной кузницы, неся на себе жар давно погасших печей.'
  when slug='world_2026_09_20_white_wolf' then
    'В лесах появился огромный Белый волк, чьи следы теряются там, где начинается самый старый чащобный мрак.'
  when boss_kind='sector_incursion' and name='Озверевшая стая' then
    'Озверевшая стая заняла окрестности, разогнав обычную дичь и заполнив лес тревожным воем.'
  when boss_kind='sector_incursion' and name='Банда захватчиков' then
    'Банда захватчиков укрепилась в секторе, развесив над стоянкой чужие знамёна и трофеи.'
  when boss_kind='sector_incursion' and name='Беспокойные духи' then
    'Беспокойные духи наполнили сектор холодным светом и голосами, которым не отвечает никто живой.'
  when boss_kind='sector_incursion' and name='Искажённые твари' then
    'Искажённые твари заполнили сектор, оставляя на земле следы чуждой и нестабильной магии.'
  when slug='weekly_2026_09_28_ash_matron' then
    'Пепельная Матрона несёт в груди тлеющий очаг, а за её шагами остаётся запах горячего железа и золы.'
  when slug='monthly_2026_10_zero_hour_colossus' then
    'Каменный исполин с неподвижным циферблатом в груди. Рядом с ним время будто запинается на каждом ударе маятника.'
  when slug='weekly_2026_10_05_blind_duelist' then
    'Слепой воин в старом плаще, который слушает пространство вокруг себя так, будто видит каждый шорох.'
  when slug='weekly_2026_10_12_storm_shepherd' then
    'Странник с обугленным посохом, вокруг которого даже в ясную погоду собираются низкие грозовые тучи.'
  when slug='weekly_2026_10_19_root_devourer' then
    'Древняя болотная тварь, опутанная корнями, мхом и остатками растений, поглощённых вместе с землёй.'
  when slug='world_2026_10_22_salt_leviathan' then
    'Древний морской исполин поднялся из северных вод, покрытый солью, раковинами и следами вековых штормов.'
  when slug='weekly_2026_10_26_crystal_stag' then
    'Олень с прозрачными рогами, в которых преломляется свет, будто внутри них застыл целый зимний рассвет.'
  when slug='monthly_2026_11_extinguished_seraph' then
    'Серафим с обугленными крыльями несёт над собой тёмное солнце, от которого не исходит ни света, ни тепла.'
  when slug='weekly_2026_11_02_faceless_monk' then
    'Безликая фигура в монашеских одеждах, чья тихая молитва звучит сразу с нескольких сторон.'
  when slug='weekly_2026_11_09_clockmaker' then
    'Высокий мастер в маске из латуни, окружённый шестернями и часами, идущими в разном ритме.'
  when slug='weekly_2026_11_16_drowned_queen' then
    'Королева в потемневшей короне и мокрых одеждах, за которой по камню тянется холодная морская вода.'
  when slug='world_2026_11_19_aster' then
    'Небесный Червь Астэр проходит над Эйларом, оставляя в облаках длинные светящиеся разломы.'
  when slug='weekly_2026_11_23_black_bell_prince' then
    'Князь в тяжёлых доспехах, украшенных чёрными колоколами, чей звон слышен задолго до его появления.'
  when slug='weekly_2026_11_30_white_witch' then
    'Белая Ведьма идёт сквозь северный снег без следов, а её голос тонет в ветре прежде, чем достигает слуха.'
  when slug='monthly_2026_12_underking' then
    'Древний король сидит под толщей гор, окружённый камнем, руинами и молчанием давно исчезнувшего двора.'
  when slug='weekly_2026_12_07_empty_throne_guardian' then
    'Безмолвный страж древнего трона, переживший исчезновение хозяина и всё ещё несущий свою службу.'
  when slug='weekly_2026_12_14_name_hunter' then
    'Охотник в тёмной маске, собирающий чужие имена так же бережно, как другие собирают трофеи.'
  when slug='world_2026_12_17_gravity_dragon' then
    'Дракон парит внутри искривлённого пространства, где камни падают вверх, а воздух дрожит без ветра.'
  else description
end;

update public.event_boss_events
set mechanics=coalesce(mechanics,'{}'::jsonb)-'counterplay'
where coalesce(mechanics,'{}'::jsonb) ? 'counterplay';

create or replace function private.ensure_rotating_sector_incursions()
returns void
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $$
declare
 slot_start timestamptz; slot_end timestamptz; slot_key text; i integer;
 chosen_sector smallint; danger integer; profile integer; template_slug text;
 event_name text; event_desc text; v_slug text;
begin
 slot_start:=to_timestamp(floor(extract(epoch from now())/172800)*172800);
 slot_end:=slot_start+interval '48 hours';
 slot_key:=to_char(slot_start at time zone 'UTC','YYYYMMDDHH24');

 for i in 1..2 loop
  v_slug:='auto_incursion_'||slot_key||'_'||i;
  if exists(select 1 from public.event_boss_events where slug=v_slug) then continue; end if;

  select sd.sector_id,greatest(1,least(10,coalesce(sd.danger_level,1)))
  into chosen_sector,danger
  from public.sector_details sd
  where sd.content_type='wilderness' and sd.terrain_type<>'sea'
    and not exists(
      select 1 from public.event_boss_events old
      where old.boss_kind='sector_incursion' and old.sector_id=sd.sector_id
        and old.starts_at>=slot_start-interval '6 days'
    )
    and not exists(
      select 1 from public.event_boss_events same_slot
      where same_slot.boss_kind='sector_incursion' and same_slot.starts_at=slot_start
        and same_slot.sector_id=sd.sector_id
    )
  order by md5(slot_key||':'||i||':'||sd.sector_id::text)
  limit 1;

  if chosen_sector is null then continue; end if;

  profile:=1+(abs(hashtext(slot_key||':'||i||':'||chosen_sector::text))%4);
  template_slug:=case profile
    when 1 then 'auto_incursion_beasts'
    when 2 then 'auto_incursion_marauders'
    when 3 then 'auto_incursion_spirits'
    else 'auto_incursion_aberrations'
  end;
  event_name:=case profile
    when 1 then 'Озверевшая стая'
    when 2 then 'Банда захватчиков'
    when 3 then 'Беспокойные духи'
    else 'Искажённые твари'
  end;
  event_desc:=case profile
    when 1 then 'Озверевшая стая заняла окрестности, разогнав обычную дичь и заполнив лес тревожным воем.'
    when 2 then 'Банда захватчиков укрепилась в секторе, развесив над стоянкой чужие знамёна и трофеи.'
    when 3 then 'Беспокойные духи наполнили сектор холодным светом и голосами, которым не отвечает никто живой.'
    else 'Искажённые твари заполнили сектор, оставляя на земле следы чуждой и нестабильной магии.'
  end;

  insert into public.event_boss_events(
    slug,boss_kind,name,description,enabled,starts_at,ends_at,enemy_template_id,
    recommended_level,solo_enemy_level,solo_hp,solo_attack,solo_defense,solo_initiative,
    party_hp_per_extra,party_attack_per_extra,party_defense_per_extra,special_reward_item_id,
    first_reward_gold,first_reward_experience,repeat_reward_gold,repeat_reward_experience,
    special_every_n,special_damage_multiplier,phase2_hp_percent,phase2_attack_bonus_percent,
    sector_id,solo_only,max_victories_per_character,mechanics,global_clear_target
  )
  select v_slug,'sector_incursion',event_name,event_desc,true,slot_start,slot_end,et.id,
    greatest(1,danger*2),greatest(2,danger*2+1),150+danger*70,18+danger*7,7+danger*4,10+danger*2,
    0.65,0.08,0.05,null,50,100,50,100,3,1.55,35,20,chosen_sector,false,1,
    jsonb_build_object('auto_rotation',true,'slot',slot_key,'profile',profile),3
  from public.enemy_templates et where et.slug=template_slug;
 end loop;
end;
$$;

revoke all on function private.ensure_rotating_sector_incursions() from public,anon,authenticated;

