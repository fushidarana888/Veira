-- Synced from live Supabase migration 20260928144801 (polish_world_alive_security_and_indexes)


revoke all on function public.get_world_pulse(uuid) from public;
grant execute on function public.get_world_pulse(uuid) to authenticated;

revoke all on function public.resolve_dungeon_event(uuid,text) from public;
grant execute on function public.resolve_dungeon_event(uuid,text) to authenticated;

revoke all on function public.activate_treasure_map(uuid,uuid) from public;
grant execute on function public.activate_treasure_map(uuid,uuid) to authenticated;

revoke all on function public.claim_treasure_hunt(uuid) from public;
grant execute on function public.claim_treasure_hunt(uuid) to authenticated;

revoke all on function public.buy_wandering_merchant_item(uuid,uuid) from public;
grant execute on function public.buy_wandering_merchant_item(uuid,uuid) to authenticated;

revoke all on function public.get_character_trophy_case(uuid) from public;
grant execute on function public.get_character_trophy_case(uuid) to authenticated;

create index if not exists character_treasure_hunts_character_idx
  on public.character_treasure_hunts(character_id);

create index if not exists character_treasure_hunts_target_sector_idx
  on public.character_treasure_hunts(target_sector_id);

create index if not exists dungeon_run_events_character_idx
  on public.dungeon_run_events(character_id);

create index if not exists dungeon_run_events_event_slug_idx
  on public.dungeon_run_events(event_slug);

create index if not exists wandering_merchant_purchases_item_definition_idx
  on public.wandering_merchant_purchases(item_definition_id);

