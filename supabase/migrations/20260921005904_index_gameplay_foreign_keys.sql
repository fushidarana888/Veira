
create index if not exists death_spirits_defeated_by_character_id_idx
  on private.death_spirits(defeated_by_character_id);
create index if not exists death_spirits_source_sector_id_idx
  on private.death_spirits(source_sector_id);
create index if not exists hunting_attempts_combat_encounter_id_idx
  on private.hunting_attempts(combat_encounter_id);
create index if not exists hunting_attempts_dungeon_run_id_idx
  on private.hunting_attempts(dungeon_run_id);
create index if not exists hunting_attempts_enemy_template_id_idx
  on private.hunting_attempts(enemy_template_id);
create index if not exists hunting_attempts_item_definition_id_idx
  on private.hunting_attempts(item_definition_id);
create index if not exists hunting_attempts_sector_id_idx
  on private.hunting_attempts(sector_id);
create index if not exists hunting_loot_pool_item_definition_id_idx
  on private.hunting_loot_pool(item_definition_id);
create index if not exists character_autobattle_spell_rules_spell_id_idx
  on public.character_autobattle_spell_rules(spell_id);
create index if not exists character_combat_style_profiles_damage_spell_idx
  on public.character_combat_style_profiles(preferred_damage_spell_id);
create index if not exists character_combat_style_profiles_heal_spell_idx
  on public.character_combat_style_profiles(preferred_heal_spell_id);
create index if not exists character_spells_spell_id_idx
  on public.character_spells(spell_id);
create index if not exists combat_decision_events_spell_id_idx
  on public.combat_decision_events(spell_id);
create index if not exists combat_encounters_enemy_template_id_idx
  on public.combat_encounters(enemy_template_id);
create index if not exists combat_encounters_sector_id_idx
  on public.combat_encounters(sector_id);
create index if not exists combat_status_effects_source_character_id_idx
  on public.combat_status_effects(source_character_id);
create index if not exists crafting_recipe_ingredients_item_definition_id_idx
  on public.crafting_recipe_ingredients(item_definition_id);
create index if not exists dungeon_runs_event_boss_id_idx
  on public.dungeon_runs(event_boss_id);
create index if not exists dungeon_runs_sector_id_idx
  on public.dungeon_runs(sector_id);
create index if not exists event_boss_events_enemy_template_id_idx
  on public.event_boss_events(enemy_template_id);
create index if not exists event_boss_events_sector_id_idx
  on public.event_boss_events(sector_id);
create index if not exists event_boss_events_special_reward_item_id_idx
  on public.event_boss_events(special_reward_item_id);
create index if not exists expedition_event_instances_encounter_template_id_idx
  on public.expedition_event_instances(encounter_template_id);
create index if not exists expedition_results_encounter_template_id_idx
  on public.expedition_results(encounter_template_id);
create index if not exists guild_applications_resolved_by_character_id_idx
  on public.guild_applications(resolved_by_character_id);
create index if not exists guilds_founder_character_id_idx
  on public.guilds(founder_character_id);
create index if not exists item_definitions_scroll_spell_id_idx
  on public.item_definitions(scroll_spell_id);
create index if not exists loot_drops_character_id_idx
  on public.loot_drops(character_id);
create index if not exists loot_drops_item_definition_id_idx
  on public.loot_drops(item_definition_id);
create index if not exists loot_pool_entries_enemy_template_id_idx
  on public.loot_pool_entries(enemy_template_id);
create index if not exists loot_pool_entries_item_definition_id_idx
  on public.loot_pool_entries(item_definition_id);
create index if not exists loot_pool_entries_sector_id_idx
  on public.loot_pool_entries(sector_id);
create index if not exists party_dungeon_runs_event_boss_id_idx
  on public.party_dungeon_runs(event_boss_id);
create index if not exists race_access_grants_granted_by_idx
  on public.race_access_grants(granted_by);
create index if not exists race_access_grants_race_id_idx
  on public.race_access_grants(race_id);
create index if not exists sector_site_actions_sector_id_idx
  on public.sector_site_actions(sector_id);
