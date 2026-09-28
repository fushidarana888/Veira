-- Synced from live Supabase migration 20260927221254 (rare_item_instance_stories_helper)


create or replace function private.item_drop_story(
  p_item_definition_id uuid,
  p_enemy_name text,
  p_sector_id smallint
) returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  item public.item_definitions;
  roll numeric;
  variant integer;
  sector_name text;
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

  select coalesce(sd.title,'сектор #'||p_sector_id::text)
  into sector_name
  from public.sector_details sd
  where sd.sector_id=p_sector_id;

  sector_name:=coalesce(sector_name,'сектор #'||p_sector_id::text);
  variant:=floor(random()*5)::integer;

  if variant=0 then
    story_title:='Клеймо исчезнувшей мастерской';
    story_text:='На вещи осталось почти стёртое клеймо мастерской, которой нет ни в одном современном списке ремесленников. Находка связана с местом «'||sector_name||'».';
  elsif variant=1 then
    story_title:='Выцветшая лента';
    story_text:='К креплению привязана старая лента с обрывком имени. Предмет найден после победы над «'||coalesce(p_enemy_name,'неизвестным противником')||'».';
  elsif variant=2 then
    story_title:='Чужая клятва';
    story_text:='На внутренней стороне выцарапано несколько слов о возвращении домой. Последняя строка так и не дописана.';
  elsif variant=3 then
    story_title:='След прежнего владельца';
    story_text:='Износ не похож на случайный: вещью пользовались долго и очень уверенно. Кто-то носил её задолго до того, как она оказалась в '||sector_name||'.';
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
$$;

revoke all on function private.item_drop_story(uuid,text,smallint) from public;

