-- Synced from live Supabase migration 20260927205234 (make_level_one_spell_scrolls_widely_available)


update public.item_definitions
set shop_sector_id=null, updated_at=now()
where slug in (
  'cast_scroll_weakening_spark',
  'learn_scroll_weakening_spark',
  'cast_scroll_sand_veil',
  'learn_scroll_sand_veil'
);

