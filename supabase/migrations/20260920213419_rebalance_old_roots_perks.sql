update public.religion_level_perks
set title=v.title, description=v.description, modifiers=v.modifiers::jsonb
from (values
  (1,'Сок земли','+2 к Живучести.','{"vitality":2}'),
  (2,'Память камня','+5% сопротивления земле.','{"resistances":{"earth":5}}'),
  (3,'Звериная поступь','+2 к Ловкости.','{"agility":2}'),
  (4,'Тропа корней','Скорость исследования +10 п.п.','{"exploration_speed_percent":10}'),
  (5,'Каменная память','Ещё +5% сопротивления земле.','{"resistances":{"earth":5}}'),
  (6,'Кора хранителя','+3% сопротивления режущему, колющему и дробящему урону.','{"resistances":{"slashing":3,"piercing":3,"blunt":3}}'),
  (7,'Торговля с землёй','Скидка 5% во всех магазинах.','{"shop_discount_percent":5}'),
  (8,'Глубокие корни','Ещё +2 к Живучести.','{"vitality":2}'),
  (9,'Зов чащи','Скорость исследования +15 п.п.','{"exploration_speed_percent":15}')
) as v(level,title,description,modifiers)
where religion_level_perks.religion_slug='old_roots'
  and religion_level_perks.level=v.level;

CREATE OR REPLACE FUNCTION private.character_religion_modifiers(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
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
  'evasion_chance',coalesce(sum(case when jsonb_typeof(modifiers->'evasion_chance')='number' then (modifiers->>'evasion_chance')::int else 0 end),0),
  'healing_spell_bonus',coalesce(sum(case when jsonb_typeof(modifiers->'healing_spell_bonus')='number' then (modifiers->>'healing_spell_bonus')::int else 0 end),0),
  'shield_spell_bonus',coalesce(sum(case when jsonb_typeof(modifiers->'shield_spell_bonus')='number' then (modifiers->>'shield_spell_bonus')::int else 0 end),0),
  'low_hp_50_damage_reduction',coalesce(sum(case when jsonb_typeof(modifiers->'low_hp_50_damage_reduction')='number' then (modifiers->>'low_hp_50_damage_reduction')::int else 0 end),0),
  'exploration_speed_percent',coalesce(sum(case when jsonb_typeof(modifiers->'exploration_speed_percent')='number' then (modifiers->>'exploration_speed_percent')::int else 0 end),0),
  'shop_discount_percent',coalesce(sum(case when jsonb_typeof(modifiers->'shop_discount_percent')='number' then (modifiers->>'shop_discount_percent')::int else 0 end),0),
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
    'ice',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'ice')='number' then (modifiers->'resistances'->>'ice')::int else 0 end),0),
    'arcane',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'arcane')='number' then (modifiers->'resistances'->>'arcane')::int else 0 end),0),
    'star',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'star')='number' then (modifiers->'resistances'->>'star')::int else 0 end),0),
    'gravity',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'gravity')='number' then (modifiers->'resistances'->>'gravity')::int else 0 end),0),
    'moon',coalesce(sum(case when jsonb_typeof(modifiers->'resistances'->'moon')='number' then (modifiers->'resistances'->>'moon')::int else 0 end),0)
  )
) from perks;
$function$;

CREATE OR REPLACE FUNCTION public.get_settlement_shop(p_character_id uuid, p_sector_id smallint)
 RETURNS TABLE(settlement_name text, settlement_level smallint, item_id uuid, slug text, item_name text, description text, category text, rarity text, equip_group text, stat_modifiers jsonb, damage_type text, damage_resistances jsonb, scroll_mode text, scroll_spell_id uuid, scroll_spell_name text, heal_amount integer, price bigint, required_level integer, shop_tier smallint, can_afford boolean, level_unlocked boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid := auth.uid();
  current_level integer;
  current_gold bigint;
  settlement public.sector_details;
  rep_points integer := 0;
  rep_level smallint := 1;
  discount smallint := 0;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  if not exists(
    select 1 from public.character_sector_discoveries d
    where d.character_id=p_character_id and d.sector_id=p_sector_id
  ) then raise exception 'SETTLEMENT_NOT_DISCOVERED'; end if;

  select * into settlement
  from public.sector_details
  where sector_id=p_sector_id;

  if settlement.sector_id is null or settlement.content_type<>'settlement' then
    raise exception 'SECTOR_IS_NOT_SETTLEMENT';
  end if;

  perform private.apply_passive_hp_regen(p_character_id);
  perform private.apply_passive_mana_regen(p_character_id);

  select cp.level,cp.gold into current_level,current_gold
  from public.character_progress cp
  where cp.character_id=p_character_id;

  select coalesce(r.reputation_points,0)
  into rep_points
  from public.character_settlement_reputations r
  where r.character_id=p_character_id and r.sector_id=p_sector_id;

  rep_points := coalesce(rep_points,0);
  rep_level := private.settlement_reputation_level(rep_points);

  select p.shop_discount_percent into discount
  from private.settlement_reputation_perks(rep_level) p;

  discount:=least(
    80,
    coalesce(discount,0)
      +greatest(0,private.character_religion_modifier_number(p_character_id,'shop_discount_percent'))
  );

  return query
  select
    coalesce(settlement.title,'Поселение'),
    settlement.settlement_level,
    d.id,d.slug,d.name,d.description,d.category::text,d.rarity::text,d.equip_group::text,
    d.stat_modifiers,d.damage_type,d.damage_resistances,
    d.scroll_mode,d.scroll_spell_id,s.name,
    coalesce((
      select (e->>'amount')::integer
      from jsonb_array_elements(d.effects) e
      where e->>'type'='heal_hp'
      limit 1
    ),0),
    greatest(1,floor(d.shop_price*(100-coalesce(discount,0))/100.0)::bigint),
    d.required_level,d.shop_tier,
    current_gold>=greatest(1,floor(d.shop_price*(100-coalesce(discount,0))/100.0)::bigint),
    current_level>=d.required_level
  from public.item_definitions d
  left join public.spell_definitions s on s.id=d.scroll_spell_id
  where d.shop_enabled=true
    and d.shop_tier<=settlement.settlement_level
    and (d.shop_sector_id is null or d.shop_sector_id=p_sector_id)
  order by
    case d.category::text
      when 'consumable' then 0
      when 'weapon' then 1
      when 'armor' then 2
      when 'accessory' then 3
      else 4
    end,
    d.shop_tier,d.shop_price,d.name;
end;
$function$;

CREATE OR REPLACE FUNCTION public.buy_settlement_shop_item(p_character_id uuid, p_sector_id smallint, p_item_definition_id uuid, p_quantity integer DEFAULT 1)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid := auth.uid();
  cp public.character_progress;
  settlement public.sector_details;
  item public.item_definitions;
  total_price bigint;
  rep_points integer := 0;
  rep_level smallint := 1;
  discount smallint := 0;
  unit_price bigint := 0;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_quantity<1 or p_quantity>99 then raise exception 'INVALID_QUANTITY'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  if exists(
    select 1 from public.dungeon_runs r
    where r.character_id=p_character_id and r.status='active'
  ) or exists(
    select 1 from public.sector_expeditions e
    where e.character_id=p_character_id and e.status in ('active','awaiting_event')
  ) or exists(
    select 1 from public.sector_site_actions a
    where a.character_id=p_character_id and a.status='active'
  ) then raise exception 'CHARACTER_BUSY'; end if;

  if not exists(
    select 1 from public.character_sector_discoveries d
    where d.character_id=p_character_id and d.sector_id=p_sector_id
  ) then raise exception 'SETTLEMENT_NOT_DISCOVERED'; end if;

  select * into settlement
  from public.sector_details
  where sector_id=p_sector_id;

  if settlement.sector_id is null or settlement.content_type<>'settlement' then
    raise exception 'SECTOR_IS_NOT_SETTLEMENT';
  end if;

  select * into item
  from public.item_definitions d
  where d.id=p_item_definition_id and d.shop_enabled=true;

  if item.id is null then raise exception 'ITEM_NOT_FOR_SALE'; end if;
  if item.shop_sector_id is not null and item.shop_sector_id<>p_sector_id then
    raise exception 'ITEM_NOT_SOLD_HERE';
  end if;
  if item.shop_tier>settlement.settlement_level then raise exception 'ITEM_NOT_SOLD_HERE'; end if;
  if not item.stackable and p_quantity<>1 then raise exception 'NONSTACKABLE_QUANTITY_MUST_BE_ONE'; end if;

  select * into cp
  from public.character_progress
  where character_id=p_character_id
  for update;

  if cp.level<item.required_level then raise exception 'LEVEL_TOO_LOW'; end if;

  select coalesce(r.reputation_points,0)
  into rep_points
  from public.character_settlement_reputations r
  where r.character_id=p_character_id and r.sector_id=p_sector_id;

  rep_points := coalesce(rep_points,0);
  rep_level := private.settlement_reputation_level(rep_points);

  select p.shop_discount_percent into discount
  from private.settlement_reputation_perks(rep_level) p;

  discount:=least(
    80,
    coalesce(discount,0)
      +greatest(0,private.character_religion_modifier_number(p_character_id,'shop_discount_percent'))
  );

  unit_price := greatest(1,floor(item.shop_price*(100-coalesce(discount,0))/100.0)::bigint);
  total_price := unit_price*p_quantity;

  if cp.gold<total_price then raise exception 'NOT_ENOUGH_GOLD'; end if;

  update public.character_progress
  set gold=gold-total_price,
      updated_at=now()
  where character_id=p_character_id;

  if item.stackable then
    update public.character_items
    set quantity=quantity+p_quantity
    where id=(
      select ci.id
      from public.character_items ci
      where ci.character_id=p_character_id
        and ci.item_definition_id=item.id
        and ci.custom_name is null
      order by ci.acquired_at
      limit 1
    );

    if not found then
      insert into public.character_items(character_id,item_definition_id,quantity)
      values(p_character_id,item.id,p_quantity);
    end if;
  else
    insert into public.character_items(character_id,item_definition_id,quantity)
    values(p_character_id,item.id,1);
  end if;
end;
$function$;
