create index if not exists idx_dungeon_reward_cycles_sector
  on private.dungeon_reward_cycles(sector_id);

revoke all on function public.get_character_adventures_v3(uuid)
from public,anon,authenticated;
