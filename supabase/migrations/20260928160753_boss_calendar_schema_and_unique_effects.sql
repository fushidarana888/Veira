-- Synced from live Supabase migration 20260928160753 (boss_calendar_schema_and_unique_effects)


alter table public.event_boss_events
  add column if not exists reward_material_item_id uuid references public.item_definitions(id) on delete set null,
  add column if not exists reward_material_quantity smallint not null default 0 check (reward_material_quantity>=0),
  add column if not exists featured_loot jsonb not null default '[]'::jsonb;

alter table public.world_rumors
  add column if not exists starts_at timestamptz,
  add column if not exists ends_at timestamptz,
  add column if not exists weight integer not null default 10 check (weight>=1),
  add column if not exists rumor_kind text not null default 'ambient',
  add column if not exists related_event_slug text;

alter table public.combat_encounters
  add column if not exists boss_item_state jsonb not null default '{}'::jsonb;

alter table public.party_combat_member_states
  add column if not exists boss_item_state jsonb not null default '{}'::jsonb;

alter table public.item_definitions
  drop constraint if exists item_definitions_unique_effect_type_check;

alter table public.item_definitions
  add constraint item_definitions_unique_effect_type_check check (
    unique_effect_type is null or unique_effect_type = any(array[
      'lifesteal','mana_on_hit','damage_vs_wounded','guard_boost','taunt',
      'overheal_barrier','dodge_counter','mana_charge_burst','debuff_bark',
      'bow_alternation','first_debuff_reflect','untouched_tempo',
      'critical_heal_cleanse','block_resonance','spell_role_alternation',
      'ally_damage_redirect','special_revenge_element','guard_store',
      'adaptive_resist','tri_element_constellation','one_shot_cap',
      'initiative_gap_bonus','grant_spell'
    ]::text[])
  );

