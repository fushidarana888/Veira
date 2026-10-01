create or replace function private.item_story_place_description(p_sector_id smallint)
returns text
language plpgsql
stable
set search_path to 'pg_catalog','public','private'
as $function$
declare
  direct_name text;
  terrain_name text;
  origin_col integer;
  origin_row integer;
  nearby_name text;
  nearby_genitive text;
begin
  select
    coalesce(nullif(btrim(sd.title),''),nullif(btrim(ms.location_name),'')),
    coalesce(nullif(btrim(sd.terrain_type),''),nullif(btrim(ms.terrain),'')),
    ms.grid_col,
    ms.grid_row
  into direct_name,terrain_name,origin_col,origin_row
  from public.map_sectors ms
  left join public.sector_details sd on sd.sector_id=ms.id
  where ms.id=p_sector_id;

  if direct_name is not null then
    return 'в месте, которое называют «'||direct_name||'»';
  end if;

  if origin_col is not null and origin_row is not null then
    select coalesce(nullif(btrim(sd.title),''),nullif(btrim(ms.location_name),''))
    into nearby_name
    from public.map_sectors ms
    left join public.sector_details sd on sd.sector_id=ms.id
    where sd.content_type='settlement'
      and coalesce(nullif(btrim(sd.title),''),nullif(btrim(ms.location_name),'')) is not null
      and abs(ms.grid_col-origin_col)+abs(ms.grid_row-origin_row)<=5
    order by
      case
        when coalesce(nullif(btrim(sd.terrain_type),''),nullif(btrim(ms.terrain),''))=terrain_name then 0
        else 1
      end,
      abs(ms.grid_col-origin_col)+abs(ms.grid_row-origin_row),
      ms.id
    limit 1;
  end if;

  if nearby_name is not null then
    nearby_genitive:=case nearby_name
      when 'Сахрет' then 'Сахрета'
      when 'Варден' then 'Вардена'
      when 'Кхарум' then 'Кхарума'
      when 'Лиавен' then 'Лиавена'
      when 'Искарн' then 'Искарна'
      when 'Морвейн' then 'Морвейна'
      else null
    end;

    if nearby_genitive is not null then
      return case terrain_name
        when 'desert' then 'среди песков '||nearby_genitive
        when 'forest' then 'в лесах близ '||nearby_genitive
        when 'plains' then 'на равнинах близ '||nearby_genitive
        when 'mountains' then 'в горах близ '||nearby_genitive
        when 'tundra' then 'в северных пустошах близ '||nearby_genitive
        when 'swamp' then 'среди болот близ '||nearby_genitive
        when 'coast' then 'на побережье близ '||nearby_genitive
        when 'riverlands' then 'в речных землях близ '||nearby_genitive
        when 'sea' then 'в водах близ '||nearby_genitive
        else 'в окрестностях '||nearby_genitive
      end;
    end if;

    return case terrain_name
      when 'desert' then 'среди пустынных песков в окрестностях «'||nearby_name||'»'
      when 'forest' then 'в лесах в окрестностях «'||nearby_name||'»'
      when 'plains' then 'на равнинах в окрестностях «'||nearby_name||'»'
      when 'mountains' then 'в горах в окрестностях «'||nearby_name||'»'
      when 'tundra' then 'в северных пустошах в окрестностях «'||nearby_name||'»'
      when 'swamp' then 'среди болот в окрестностях «'||nearby_name||'»'
      when 'coast' then 'на побережье в окрестностях «'||nearby_name||'»'
      when 'riverlands' then 'в речных землях в окрестностях «'||nearby_name||'»'
      when 'sea' then 'в водах неподалёку от «'||nearby_name||'»'
      else 'в окрестностях «'||nearby_name||'»'
    end;
  end if;

  return case terrain_name
    when 'desert' then 'среди безымянных пустынных песков'
    when 'forest' then 'в безымянной лесной глуши'
    when 'plains' then 'на безымянных равнинах'
    when 'mountains' then 'в безымянных горных землях'
    when 'tundra' then 'в безымянных северных пустошах'
    when 'swamp' then 'среди безымянных болот'
    when 'coast' then 'на безымянном побережье'
    when 'riverlands' then 'в безымянных речных землях'
    when 'sea' then 'в безымянных водах'
    else 'в безымянных землях Эйлара'
  end;
end;
$function$;

create or replace function private.item_drop_story(
  p_item_definition_id uuid,
  p_enemy_name text,
  p_sector_id smallint
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','private'
as $function$
declare
  item public.item_definitions;
  variant integer;
  place_description text;
  story_title text;
  story_text text;
begin
  select * into item
  from public.item_definitions
  where id=p_item_definition_id;

  if item.id is null
     or item.category not in ('weapon','armor','accessory')
     or item.rarity not in ('rare','epic','legendary','unique')
     or random()*100>=38
  then
    return '{}'::jsonb;
  end if;

  place_description:=private.item_story_place_description(p_sector_id);
  variant:=floor(random()*5)::integer;

  if variant=0 then
    story_title:='Клеймо исчезнувшей мастерской';
    story_text:='На вещи осталось почти стёртое клеймо мастерской, которой нет ни в одном современном списке ремесленников. След ведёт туда, где её нашли: '||place_description||'.';
  elsif variant=1 then
    story_title:='Выцветшая лента';
    story_text:='К креплению привязана старая лента с обрывком имени. Предмет найден после победы над «'||coalesce(p_enemy_name,'неизвестным противником')||'».';
  elsif variant=2 then
    story_title:='Чужая клятва';
    story_text:='На внутренней стороне выцарапано несколько слов о возвращении домой. Последняя строка так и не дописана.';
  elsif variant=3 then
    story_title:='След прежнего владельца';
    story_text:='Износ не похож на случайный: вещью пользовались долго и очень уверенно. Кто-то носил её задолго до того, как она оказалась '||place_description||'.';
  else
    story_title:='Непонятная метка';
    story_text:='Под грязью обнаружился маленький символ, не похожий ни на герб, ни на знак известной религии. Он едва заметно теплеет в руке.';
  end if;

  return jsonb_build_object(
    'story_title',story_title,
    'story_text',story_text,
    'story_origin_enemy',p_enemy_name,
    'story_origin_sector',p_sector_id
  );
end;
$function$;

update public.character_items ci
set metadata=jsonb_set(
  ci.metadata,
  '{story_text}',
  to_jsonb(
    case ci.metadata->>'story_title'
      when 'След прежнего владельца' then
        'Износ не похож на случайный: вещью пользовались долго и очень уверенно. Кто-то носил её задолго до того, как она оказалась '
        ||private.item_story_place_description((ci.metadata->>'story_origin_sector')::smallint)||'.'
      when 'Клеймо исчезнувшей мастерской' then
        'На вещи осталось почти стёртое клеймо мастерской, которой нет ни в одном современном списке ремесленников. След ведёт туда, где её нашли: '
        ||private.item_story_place_description((ci.metadata->>'story_origin_sector')::smallint)||'.'
      else ci.metadata->>'story_text'
    end
  ),
  true
)
where ci.metadata ? 'story_origin_sector'
  and coalesce(ci.metadata->>'story_text','') ~ 'сектор #[0-9]+'
  and ci.metadata->>'story_title' in ('След прежнего владельца','Клеймо исчезнувшей мастерской');
