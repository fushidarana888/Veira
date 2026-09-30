-- Pin search_path for immutable Arena AI helpers.
-- These helpers are private, but fixing the path removes mutable-search-path
-- warnings and keeps all SECURITY DEFINER/SQL helpers explicit.

alter function private.arena_effect_severity(jsonb)
  set search_path = pg_catalog, public, private;
alter function private.arena_effect_reduction(jsonb)
  set search_path = pg_catalog, public, private;
alter function private.arena_effect_vulnerable(jsonb)
  set search_path = pg_catalog, public, private;
alter function private.arena_has_effect(jsonb,text)
  set search_path = pg_catalog, public, private;
alter function private.arena_apply_effect(jsonb,text,integer,integer)
  set search_path = pg_catalog, public, private;
alter function private.arena_decay_effects(jsonb)
  set search_path = pg_catalog, public, private;
