-- Synced from live Supabase migration 20260927210323 (trim_early_shop_gear_and_push_farming_to_dungeons)


create temp table moved_early_shop_gear on commit drop as
select
  d.id,
  d.slug,
  d.required_level,
  d.shop_sector_id,
  sd.terrain_type
from public.item_definitions d
join public.sector_details sd on sd.sector_id=d.shop_sector_id
where d.shop_enabled=true
  and d.category in ('weapon','armor','accessory')
  and d.required_level<=4
  and d.shop_sector_id in (127,131,153,170,228,230)
  and d.slug not in (
    -- Forest settlement: hunting / mobility identity
    'hunter_shortbow',
    'training_longbow',
    'scout_hood',
    'feather_charm',

    -- Varden: basic starter defence / sword identity
    'traveler_sword_beta',
    'wooden_buckler',
    'padded_vest',
    'plain_copper_ring',

    -- Plains settlement: militia / spear / duelist identity
    'hunting_spear_beta',
    'training_rapier',
    'travel_trousers',
    'soldier_knot',

    -- Liaven: early magic identity
    'apprentice_wand',
    'ember_wand',
    'ember_bead',
    'mana_bead',

    -- Desert outpost: practical armour
    'chain_shirt',
    'round_shield',
    'soldier_boots',

    -- Sahret: desert mobility / bow identity
    'sahret_short_bow',
    'desert_veil',
    'sandglass_charm',
    'desert_boots'
  );

update public.item_definitions d
set shop_enabled=false,
    shop_sector_id=null,
    updated_at=now()
from moved_early_shop_gear m
where d.id=m.id;

-- Anything removed from a shop but not already obtainable is now a dungeon reward.
insert into public.loot_pool_entries(
  source_type,
  enemy_template_id,
  sector_id,
  terrain_type,
  min_danger,
  max_danger,
  item_definition_id,
  chance_percent,
  min_quantity,
  max_quantity,
  enabled
)
select
  'dungeon',
  null,
  null,
  case
    when m.terrain_type in ('plains','forest','swamp','desert','mountains','tundra','coast','sea','riverlands')
      then m.terrain_type
    else null
  end,
  case
    when m.required_level<=1 then 0
    when m.required_level=2 then 1
    when m.required_level=3 then 2
    else 3
  end,
  case
    when m.required_level<=1 then 1
    when m.required_level=2 then 2
    when m.required_level=3 then 3
    else 4
  end,
  m.id,
  case
    when m.required_level<=1 then 6.0
    when m.required_level=2 then 5.5
    when m.required_level=3 then 5.0
    else 4.5
  end,
  1,
  1,
  true
from moved_early_shop_gear m
where not exists (
  select 1
  from public.loot_pool_entries l
  where l.item_definition_id=m.id
    and l.enabled=true
);

