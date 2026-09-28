-- Synced from live Supabase migration 20260928145118 (restrict_world_alive_rpc_to_authenticated)

revoke execute on function public.get_world_pulse(uuid) from anon, public;
revoke execute on function public.resolve_dungeon_event(uuid,text) from anon, public;
revoke execute on function public.activate_treasure_map(uuid,uuid) from anon, public;
revoke execute on function public.claim_treasure_hunt(uuid) from anon, public;
revoke execute on function public.buy_wandering_merchant_item(uuid,uuid) from anon, public;
revoke execute on function public.get_character_trophy_case(uuid) from anon, public;

grant execute on function public.get_world_pulse(uuid) to authenticated;
grant execute on function public.resolve_dungeon_event(uuid,text) to authenticated;
grant execute on function public.activate_treasure_map(uuid,uuid) to authenticated;
grant execute on function public.claim_treasure_hunt(uuid) to authenticated;
grant execute on function public.buy_wandering_merchant_item(uuid,uuid) to authenticated;
grant execute on function public.get_character_trophy_case(uuid) to authenticated;
