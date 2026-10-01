
create index if not exists camp_actions_target_sector_idx on public.camp_actions(target_sector_id);
create index if not exists camp_scout_reports_owner_idx on public.camp_scout_reports(camp_owner_character_id);
create index if not exists camp_scout_reports_sector_idx on public.camp_scout_reports(sector_id);
create index if not exists camp_storage_bound_character_idx on public.camp_storage_items(bound_to_character_id);
create index if not exists camp_storage_item_definition_idx on public.camp_storage_items(item_definition_id);
create index if not exists camp_trade_accepted_by_idx on public.camp_trade_offers(accepted_by_character_id);
create index if not exists camp_trade_offered_definition_idx on public.camp_trade_offers(offered_item_definition_id);
create index if not exists camp_trade_requested_definition_idx on public.camp_trade_offers(requested_item_definition_id);
create index if not exists camp_trade_sector_idx on public.camp_trade_offers(sector_id);
create index if not exists camp_preparations_owner_idx on public.character_camp_preparations(camp_owner_character_id);
create index if not exists character_items_bound_to_character_idx on public.character_items(bound_to_character_id);

drop function if exists private.hunter_camp_after_hunting_attempt();
drop function if exists private.active_camp_specialization(uuid);

