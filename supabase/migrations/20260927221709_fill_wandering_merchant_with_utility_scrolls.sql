-- Synced from live Supabase migration 20260927221709 (fill_wandering_merchant_with_utility_scrolls)


insert into public.wandering_merchant_catalog(
  item_definition_id,min_level,max_level,offer_price,weight,enabled
)
select i.id,x.min_level,99,x.price,1,true
from (values
  ('cast_scroll_weakening_spark',1,75),
  ('cast_scroll_sand_veil',1,72),
  ('cast_scroll_venom_spore',2,105)
) x(slug,min_level,price)
join public.item_definitions i on i.slug=x.slug
on conflict(item_definition_id) do update
set min_level=excluded.min_level,
    max_level=excluded.max_level,
    offer_price=excluded.offer_price,
    enabled=true;

