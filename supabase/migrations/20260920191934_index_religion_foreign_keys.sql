create index if not exists character_religion_oaths_religion_idx
  on public.character_religion_oaths(religion_slug);
create index if not exists character_religion_progress_religion_idx
  on public.character_religion_progress(religion_slug);
create index if not exists character_religions_current_religion_idx
  on public.character_religions(current_religion_slug)
  where current_religion_slug is not null;
create index if not exists religion_definitions_reward_item_idx
  on public.religion_definitions(level10_reward_item_id)
  where level10_reward_item_id is not null;
