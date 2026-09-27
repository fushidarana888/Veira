-- Synced from live Supabase migration 20260927210103 (specialize_shop_inventories_and_move_special_gear_to_dungeons)

-- Give every currently universal shop item a single home shop.
update public.item_definitions
set shop_sector_id=70::smallint, updated_at=now()
where slug in ('healing_potion_great_beta') and shop_enabled=true;

update public.item_definitions
set shop_sector_id=86::smallint, updated_at=now()
where slug in ('greater_mana_potion_beta') and shop_enabled=true;

update public.item_definitions
set shop_sector_id=127::smallint, updated_at=now()
where slug in ('ashwood_spear','patched_hood','worn_boots','feather_charm','river_pebble_charm','fox_tooth','scout_hood','leather_gloves','trail_boots','iron_hatchet') and shop_enabled=true;

update public.item_definitions
set shop_sector_id=131::smallint, updated_at=now()
where slug in ('minor_healing_potion_beta','field_sword','stone_mace','padded_vest','work_gloves','wooden_buckler','bone_knot_charm','plain_copper_ring') and shop_enabled=true;

update public.item_definitions
set shop_sector_id=144::smallint, updated_at=now()
where slug in ('healing_potion_strong_beta') and shop_enabled=true;

update public.item_definitions
set shop_sector_id=153::smallint, updated_at=now()
where slug in ('training_rapier','travel_trousers','soldier_knot','reinforced_trousers','hide_jerkin','copper_buckler','quarry_hammer') and shop_enabled=true;

update public.item_definitions
set shop_sector_id=170::smallint, updated_at=now()
where slug in ('minor_mana_potion_beta','cast_scroll_weakening_spark','learn_scroll_weakening_spark','cast_scroll_sand_veil','learn_scroll_sand_veil','ember_bead','healing_potion_small_beta','mana_bead','ward_stone','chain_coif','iron_gauntlets_light') and shop_enabled=true;

update public.item_definitions
set shop_sector_id=176::smallint, updated_at=now()
where slug in ('healing_potion_large_beta') and shop_enabled=true;

update public.item_definitions
set shop_sector_id=228::smallint, updated_at=now()
where slug in ('chain_shirt','plated_leggings','soldier_boots','round_shield','dune_wraps','sandguard_leggings','scale_vest') and shop_enabled=true;

update public.item_definitions
set shop_sector_id=230::smallint, updated_at=now()
where slug in ('desert_veil','desert_boots','lightning_coil','sandglass_charm','tower_shield','healing_potion_standard_beta','mana_potion_beta') and shop_enabled=true;


-- Interesting build-defining gear should be found in dungeons instead of bought directly.
update public.item_definitions
set shop_enabled=false, shop_sector_id=null, updated_at=now()
where slug in (
  'breaker_token',
  'moon_chip',
  'guardian_seal',
  'scarlet_rapier',
  'scarlet_bowstring_bow'
);

-- The two new build talismans already have dungeon entries. Add missing special gear to dungeon/boss loot.
insert into public.loot_pool_entries(
  source_type,enemy_template_id,sector_id,terrain_type,min_danger,max_danger,
  item_definition_id,chance_percent,min_quantity,max_quantity,enabled
)
select 'boss',null,null,'desert',3,4,d.id,2.5,1,1,true
from public.item_definitions d
where d.slug='scarlet_rapier'
  and not exists (
    select 1 from public.loot_pool_entries l
    where l.item_definition_id=d.id and l.enabled=true
  );

insert into public.loot_pool_entries(
  source_type,enemy_template_id,sector_id,terrain_type,min_danger,max_danger,
  item_definition_id,chance_percent,min_quantity,max_quantity,enabled
)
select 'dungeon',null,null,'desert',4,4,d.id,4.5,1,1,true
from public.item_definitions d
where d.slug='guardian_seal'
  and not exists (
    select 1 from public.loot_pool_entries l
    where l.item_definition_id=d.id and l.enabled=true
  );

-- Safety net: no enabled shop item may remain universal.
update public.item_definitions
set shop_sector_id=case
  when shop_tier<=0 then 131
  when shop_tier=1 then 153
  when shop_tier=2 then 170
  when shop_tier=3 then 228
  when shop_tier=4 then 230
  when shop_tier=5 then 177
  when shop_tier=6 then 176
  when shop_tier=7 then 86
  when shop_tier=8 then 144
  when shop_tier=9 then 94
  else 70
end,
updated_at=now()
where shop_enabled=true and shop_sector_id is null;

