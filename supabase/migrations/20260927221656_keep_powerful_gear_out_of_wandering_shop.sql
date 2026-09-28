-- Synced from live Supabase migration 20260927221656 (keep_powerful_gear_out_of_wandering_shop)


delete from public.wandering_merchant_catalog c
using public.item_definitions i
where c.item_definition_id=i.id
  and i.slug in (
    'cursed_glass_ring',
    'blessed_wayfarer_charm',
    'cursed_bone_mask',
    'blessed_moonthread_cloak',
    'black_mirror_talisman',
    'oathbreaker_greaves'
  );

insert into public.wandering_merchant_catalog(
  item_definition_id,min_level,max_level,offer_price,weight,enabled
)
select i.id,x.min_level,99,x.price,1,true
from (values
  ('treasure_map_faded',1,95),
  ('treasure_map_royal',3,220),
  ('cast_scroll_mirror_barrier',2,140),
  ('cast_scroll_healing_spark',2,120),
  ('cast_scroll_combat_impulse',3,185),
  ('cast_scroll_moon_frost',4,225)
) x(slug,min_level,price)
join public.item_definitions i on i.slug=x.slug
on conflict(item_definition_id) do update
set min_level=excluded.min_level,
    max_level=excluded.max_level,
    offer_price=excluded.offer_price,
    weight=excluded.weight,
    enabled=true;

