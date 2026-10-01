CREATE OR REPLACE FUNCTION private.bind_character_item_on_equip()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
begin update public.character_items ci set bound_to_character_id=new.character_id from public.item_definitions d where ci.id=new.character_item_id and d.id=ci.item_definition_id and d.trade_policy='bind_on_equip' and ci.bound_to_character_id is null; return new; end $function$
;

CREATE OR REPLACE FUNCTION private.camp_access_allowed(p_actor uuid, p_owner uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
 select exists(select 1 from public.character_camps c where c.character_id=p_owner and c.expires_at>now() and (p_actor=p_owner or c.access_mode='open' or (c.access_mode='party' and private.characters_share_active_party(p_actor,p_owner)))) $function$
;

CREATE OR REPLACE FUNCTION private.camp_has_module(p_owner uuid, p_module text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
 select exists(select 1 from public.character_camps c join public.camp_modules m on m.camp_owner_character_id=c.character_id where c.character_id=p_owner and c.expires_at>now() and m.module_type=p_module) $function$
;

CREATE OR REPLACE FUNCTION private.camp_item_trade_allowed(p_character_item_id uuid, p_character_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  select exists(
    select 1
    from public.character_items ci
    join public.item_definitions d on d.id=ci.item_definition_id
    where ci.id=p_character_item_id
      and ci.character_id=p_character_id
      and ci.death_spirit_id is null
      and coalesce((ci.metadata->>'inventory_locked')::boolean,false)=false
      and not exists(select 1 from public.character_equipment ce where ce.character_item_id=ci.id)
      and d.trade_policy<>'bound'
      and (d.trade_policy<>'bind_on_equip' or ci.bound_to_character_id is null)
  );
$function$
;

CREATE OR REPLACE FUNCTION private.camp_module_slots(p_level integer)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$ select case when p_level<=1 then 1 when p_level=2 then 2 else 4 end $function$
;

CREATE OR REPLACE FUNCTION private.camp_preparation_bonus(p_character_id uuid, p_kind text)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
 select case when exists(select 1 from public.character_camp_preparations p where p.character_id=p_character_id and p.preparation_type=p_kind and p.expires_at>now()) then 6 else 0 end $function$
;

CREATE OR REPLACE FUNCTION private.camp_storage_capacity(p_level integer)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$ select case when p_level<=1 then 6 when p_level=2 then 12 else 20 end $function$
;

CREATE OR REPLACE FUNCTION private.character_blocked_for_event_boss(p_character_id uuid)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
 select private.character_busy_for_duel(p_character_id,null)
   or private.character_blocked_for_party_dungeon(p_character_id);
$function$
;

CREATE OR REPLACE FUNCTION private.character_blocked_for_party_dungeon(p_character_id uuid)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
 select
   exists(select 1 from public.sector_expeditions where character_id=p_character_id and status in ('active','awaiting_event'))
   or exists(select 1 from public.sector_site_actions where character_id=p_character_id and status='active')
   or exists(select 1 from public.dungeon_runs where character_id=p_character_id and status='active')
   or private.character_in_active_party_dungeon(p_character_id)
   or exists(select 1 from public.pvp_duel_locks where character_id=p_character_id)
   or exists(select 1 from public.combat_encounters where character_id=p_character_id and status='active')
   or private.character_has_active_hunt(p_character_id)
   or private.character_has_active_camp_action(p_character_id);
$function$
;

CREATE OR REPLACE FUNCTION private.character_defense_percent(p_character_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
 select greatest(-75,least(100,coalesce((select sum(case when jsonb_typeof(idf.stat_modifiers->'defense_percent')='number' then (idf.stat_modifiers->>'defense_percent')::numeric::integer else 0 end) from public.character_equipment ce join public.character_items ci on ci.id=ce.character_item_id join public.item_definitions idf on idf.id=ci.item_definition_id where ce.character_id=p_character_id),0)::integer+private.camp_preparation_bonus(p_character_id,'fortify'))) $function$
;

CREATE OR REPLACE FUNCTION private.character_exploration_speed_percent(p_character_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
 select greatest(-75,least(300,private.character_religion_modifier_number(p_character_id,'exploration_speed_percent')+private.character_equipment_exploration_speed_percent(p_character_id)+private.character_cartography_speed_percent(p_character_id))) $function$
;

CREATE OR REPLACE FUNCTION private.character_has_active_camp_action(p_character_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
 select exists(select 1 from public.camp_actions a where a.actor_character_id=p_character_id and a.status='active') $function$
;

CREATE OR REPLACE FUNCTION private.character_has_active_hunt(p_character_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
 select exists(select 1 from private.hunting_attempts h where h.character_id=p_character_id and h.status='active') $function$
;

CREATE OR REPLACE FUNCTION private.characters_share_active_party(p_a uuid, p_b uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
 select exists(select 1 from public.parties p join public.party_members a on a.party_id=p.id and a.character_id=p_a join public.party_members b on b.party_id=p.id and b.character_id=p_b where p.status='active') $function$
;

CREATE OR REPLACE FUNCTION private.cleanup_expired_camp_trade_offers()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare o public.camp_trade_offers; begin
 for o in select * from public.camp_trade_offers where status='open' and expires_at<=now() for update loop
  perform private.restore_camp_item_snapshot(o.offered_by_character_id,o.offered_item_definition_id,o.offered_quantity,o.offered_durability_current,o.offered_durability_max,o.offered_custom_name,o.offered_metadata,o.offered_enhancement_level,o.offered_awakening_level,o.offered_lineage_id,null);
  update public.camp_trade_offers set status='expired' where id=o.id;
 end loop;
end $function$
;

CREATE OR REPLACE FUNCTION private.cleanup_expired_camps()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare x record; begin
 for x in select character_id from public.character_camps where expires_at<=now() for update loop
  perform private.return_camp_assets(x.character_id);
  delete from public.character_camps where character_id=x.character_id;
 end loop;
end $function$
;

CREATE OR REPLACE FUNCTION private.consume_item_slug(p_character_id uuid, p_slug text, p_quantity integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare did uuid; begin
 if p_quantity<=0 then return; end if;
 select id into did from public.item_definitions where slug=p_slug;
 if did is null then raise exception 'ITEM_DEFINITION_NOT_FOUND:%',p_slug; end if;
 perform private.consume_character_item_definition(p_character_id,did,p_quantity);
end $function$
;

CREATE OR REPLACE FUNCTION private.current_wandering_merchant_offers(p_character_id uuid)
 RETURNS TABLE(item_definition_id uuid, offer_price integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
 select c.item_definition_id,c.offer_price from public.wandering_merchant_catalog c join public.character_progress cp on cp.character_id=p_character_id where c.enabled and cp.level between c.min_level and c.max_level order by (-ln(((((pg_catalog.hashtextextended(current_date::text||':'||p_character_id::text||':'||c.item_definition_id::text,0)&2147483647)::numeric+1)/2147483649.0)))/greatest(c.weight,1)),c.item_definition_id limit 4 $function$
;

CREATE OR REPLACE FUNCTION private.get_character_combat_stats(p_character_id uuid)
 RETURNS TABLE(level integer, hp_current integer, hp_max integer, mana_current integer, mana_max integer, strength integer, agility integer, intellect integer, vitality integer, luck integer, physical_power integer, magic_power integer, defense integer, initiative integer, weapon_damage_type text, magic_damage_type text, damage_resistances jsonb, lifesteal_percent integer, mana_on_hit integer, damage_vs_wounded_percent integer, guard_boost_percent integer, all_damage_bonus_percent integer, physical_damage_bonus_percent integer, magic_damage_bonus_percent integer, low_hp_damage_reduction_percent integer, boss_damage_bonus_percent integer)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
  with equipped as (
    select ce.slot,idf.*,ci.metadata,ci.enhancement_level,ci.awakening_level
    from public.character_equipment ce
    join public.character_items ci on ci.id=ce.character_item_id
    join public.item_definitions idf on idf.id=ci.item_definition_id
    where ce.character_id=p_character_id
  ),
  mods as (
    select
      coalesce(sum(
        case when jsonb_typeof(stat_modifiers->'strength')='number'
          then (stat_modifiers->>'strength')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'affix_stat_modifiers'->'strength')='number'
          then (metadata->'affix_stat_modifiers'->>'strength')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'religion_stat_modifiers'->'strength')='number'
          then (metadata->'religion_stat_modifiers'->>'strength')::numeric::integer else 0 end
      ),0)::integer strength_mod,
      coalesce(sum(
        case when jsonb_typeof(stat_modifiers->'agility')='number'
          then (stat_modifiers->>'agility')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'affix_stat_modifiers'->'agility')='number'
          then (metadata->'affix_stat_modifiers'->>'agility')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'religion_stat_modifiers'->'agility')='number'
          then (metadata->'religion_stat_modifiers'->>'agility')::numeric::integer else 0 end
      ),0)::integer agility_mod,
      coalesce(sum(
        case when jsonb_typeof(stat_modifiers->'intellect')='number'
          then (stat_modifiers->>'intellect')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'affix_stat_modifiers'->'intellect')='number'
          then (metadata->'affix_stat_modifiers'->>'intellect')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'religion_stat_modifiers'->'intellect')='number'
          then (metadata->'religion_stat_modifiers'->>'intellect')::numeric::integer else 0 end
      ),0)::integer intellect_mod,
      coalesce(sum(
        case when jsonb_typeof(stat_modifiers->'vitality')='number'
          then (stat_modifiers->>'vitality')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'affix_stat_modifiers'->'vitality')='number'
          then (metadata->'affix_stat_modifiers'->>'vitality')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'religion_stat_modifiers'->'vitality')='number'
          then (metadata->'religion_stat_modifiers'->>'vitality')::numeric::integer else 0 end
      ),0)::integer vitality_mod,
      coalesce(sum(
        case when jsonb_typeof(stat_modifiers->'luck')='number'
          then (stat_modifiers->>'luck')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'affix_stat_modifiers'->'luck')='number'
          then (metadata->'affix_stat_modifiers'->>'luck')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'religion_stat_modifiers'->'luck')='number'
          then (metadata->'religion_stat_modifiers'->>'luck')::numeric::integer else 0 end
      ),0)::integer luck_mod,
      coalesce(
        max(damage_type) filter(
          where slot='weapon' and damage_type in ('slashing','piercing','blunt')
        ),
        'blunt'
      )::text weapon_type,
      coalesce(max(weapon_base_damage + case when jsonb_typeof(metadata->'religion_weapon_base_damage_penalty')='number' then (metadata->>'religion_weapon_base_damage_penalty')::numeric::integer else 0 end) filter(where slot='weapon'),0)::integer weapon_base_damage,
      coalesce(max(weapon_scaling) filter(where slot='weapon'),'strength')::text weapon_scaling,
      coalesce(max(enhancement_level) filter(where slot='weapon'),0)::integer weapon_enhancement_level,
      jsonb_build_object(
        'slashing',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'slashing')='number'
            then (damage_resistances->>'slashing')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'slashing')='number'
            then (metadata->'affix_damage_resistances'->>'slashing')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'slashing')='number'
            then (metadata->'religion_damage_resistances'->>'slashing')::numeric::integer else 0 end
        ),0)::integer)),
        'piercing',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'piercing')='number'
            then (damage_resistances->>'piercing')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'piercing')='number'
            then (metadata->'affix_damage_resistances'->>'piercing')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'piercing')='number'
            then (metadata->'religion_damage_resistances'->>'piercing')::numeric::integer else 0 end
        ),0)::integer)),
        'blunt',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'blunt')='number'
            then (damage_resistances->>'blunt')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'blunt')='number'
            then (metadata->'affix_damage_resistances'->>'blunt')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'blunt')='number'
            then (metadata->'religion_damage_resistances'->>'blunt')::numeric::integer else 0 end
        ),0)::integer)),
        'fire',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'fire')='number'
            then (damage_resistances->>'fire')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'fire')='number'
            then (metadata->'affix_damage_resistances'->>'fire')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'fire')='number'
            then (metadata->'religion_damage_resistances'->>'fire')::numeric::integer else 0 end
        ),0)::integer)),
        'water',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'water')='number'
            then (damage_resistances->>'water')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'water')='number'
            then (metadata->'affix_damage_resistances'->>'water')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'water')='number'
            then (metadata->'religion_damage_resistances'->>'water')::numeric::integer else 0 end
        ),0)::integer)),
        'earth',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'earth')='number'
            then (damage_resistances->>'earth')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'earth')='number'
            then (metadata->'affix_damage_resistances'->>'earth')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'earth')='number'
            then (metadata->'religion_damage_resistances'->>'earth')::numeric::integer else 0 end
        ),0)::integer)),
        'air',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'air')='number'
            then (damage_resistances->>'air')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'air')='number'
            then (metadata->'affix_damage_resistances'->>'air')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'air')='number'
            then (metadata->'religion_damage_resistances'->>'air')::numeric::integer else 0 end
        ),0)::integer)),
        'lightning',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'lightning')='number'
            then (damage_resistances->>'lightning')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'lightning')='number'
            then (metadata->'affix_damage_resistances'->>'lightning')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'lightning')='number'
            then (metadata->'religion_damage_resistances'->>'lightning')::numeric::integer else 0 end
        ),0)::integer)),
        'ice',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'ice')='number'
            then (damage_resistances->>'ice')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'ice')='number'
            then (metadata->'affix_damage_resistances'->>'ice')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'ice')='number'
            then (metadata->'religion_damage_resistances'->>'ice')::numeric::integer else 0 end
        ),0)::integer)),
        'arcane',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'arcane')='number'
            then (damage_resistances->>'arcane')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'arcane')='number'
            then (metadata->'affix_damage_resistances'->>'arcane')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'arcane')='number'
            then (metadata->'religion_damage_resistances'->>'arcane')::numeric::integer else 0 end
        ),0)::integer)),
        'star',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'star')='number'
            then (damage_resistances->>'star')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'star')='number'
            then (metadata->'affix_damage_resistances'->>'star')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'star')='number'
            then (metadata->'religion_damage_resistances'->>'star')::numeric::integer else 0 end
        ),0)::integer)),
        'gravity',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'gravity')='number'
            then (damage_resistances->>'gravity')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'gravity')='number'
            then (metadata->'affix_damage_resistances'->>'gravity')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'gravity')='number'
            then (metadata->'religion_damage_resistances'->>'gravity')::numeric::integer else 0 end
        ),0)::integer)),
        'moon',greatest(-75,least(75,coalesce(sum(
          case when jsonb_typeof(damage_resistances->'moon')='number'
            then (damage_resistances->>'moon')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'affix_damage_resistances'->'moon')='number'
            then (metadata->'affix_damage_resistances'->>'moon')::numeric::integer else 0 end
          + case when jsonb_typeof(metadata->'religion_damage_resistances'->'moon')='number'
            then (metadata->'religion_damage_resistances'->>'moon')::numeric::integer else 0 end
        ),0)::integer))
      ) resistances,
      least(50,coalesce(sum(
        case when unique_effect_type='lifesteal' then unique_effect_value + case when slot='weapon' then awakening_level else 0 end else 0 end
        + case when jsonb_typeof(metadata->'affix_unique_effects'->'lifesteal')='number'
          then (metadata->'affix_unique_effects'->>'lifesteal')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'religion_unique_effects'->'lifesteal')='number'
          then (metadata->'religion_unique_effects'->>'lifesteal')::numeric::integer else 0 end
      ),0))::integer item_lifesteal,
      least(30,coalesce(sum(
        case when unique_effect_type='mana_on_hit' then unique_effect_value + case when slot='weapon' then awakening_level else 0 end else 0 end
        + case when jsonb_typeof(metadata->'affix_unique_effects'->'mana_on_hit')='number'
          then (metadata->'affix_unique_effects'->>'mana_on_hit')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'religion_unique_effects'->'mana_on_hit')='number'
          then (metadata->'religion_unique_effects'->>'mana_on_hit')::numeric::integer else 0 end
      ),0))::integer item_mana_hit,
      least(75,coalesce(sum(
        case when unique_effect_type='damage_vs_wounded' then unique_effect_value + case when slot='weapon' then awakening_level else 0 end else 0 end
        + case when jsonb_typeof(metadata->'affix_unique_effects'->'damage_vs_wounded')='number'
          then (metadata->'affix_unique_effects'->>'damage_vs_wounded')::numeric::integer else 0 end
      ),0))::integer item_wounded_bonus,
      least(25,coalesce(sum(
        case when unique_effect_type='guard_boost' then unique_effect_value + case when slot='weapon' then awakening_level else 0 end else 0 end
        + case when jsonb_typeof(metadata->'affix_unique_effects'->'guard_boost')='number'
          then (metadata->'affix_unique_effects'->>'guard_boost')::numeric::integer else 0 end
        + case when jsonb_typeof(metadata->'religion_unique_effects'->'guard_boost')='number'
          then (metadata->'religion_unique_effects'->>'guard_boost')::numeric::integer else 0 end
      ),0))::integer item_guard_bonus,
      least(50,coalesce(sum(
        case when jsonb_typeof(metadata->'affix_unique_effects'->'all_damage_bonus')='number'
          then (metadata->'affix_unique_effects'->>'all_damage_bonus')::numeric::integer else 0 end
      ),0))::integer item_all_damage_bonus,
      least(75,coalesce(sum(
        case when jsonb_typeof(metadata->'affix_unique_effects'->'physical_damage_bonus')='number'
          then (metadata->'affix_unique_effects'->>'physical_damage_bonus')::numeric::integer else 0 end
        + case when slot='weapon'
            and coalesce(unique_effect_type,'')=''
            and coalesce(echo_strike_chance_percent,0)=0
            and coalesce(bloodshed_chance_percent,0)=0
            and jsonb_typeof(stat_modifiers->'first_physical_strike_multiplier') is distinct from 'number'
          then awakening_level else 0 end
      ),0))::integer item_physical_damage_bonus,
      least(75,coalesce(sum(
        case when jsonb_typeof(metadata->'affix_unique_effects'->'magic_damage_bonus')='number'
          then (metadata->'affix_unique_effects'->>'magic_damage_bonus')::numeric::integer else 0 end
      ),0))::integer item_magic_damage_bonus,
      least(50,coalesce(sum(
        case when jsonb_typeof(metadata->'affix_unique_effects'->'low_hp_damage_reduction')='number'
          then (metadata->'affix_unique_effects'->>'low_hp_damage_reduction')::numeric::integer else 0 end
      ),0))::integer item_low_hp_reduction,
      least(75,coalesce(sum(
        case when jsonb_typeof(metadata->'affix_unique_effects'->'boss_damage_bonus')='number'
          then (metadata->'affix_unique_effects'->>'boss_damage_bonus')::numeric::integer else 0 end
      ),0))::integer item_boss_damage_bonus
    from equipped
  ),
  religion as (
    select private.character_religion_modifiers(p_character_id) mods
  ),
  base as (
    select
      cp.level,cp.hp_current,cp.hp_max,cp.mana_current,cp.mana_max,
      cp.strength+m.strength_mod+case when jsonb_typeof(rd.stat_modifiers->'strength')='number' then (rd.stat_modifiers->>'strength')::numeric::integer else 0 end+coalesce((rm.mods->>'strength')::integer,0) strength,
      cp.agility+m.agility_mod+case when jsonb_typeof(rd.stat_modifiers->'agility')='number' then (rd.stat_modifiers->>'agility')::numeric::integer else 0 end+coalesce((rm.mods->>'agility')::integer,0) agility,
      cp.intellect+m.intellect_mod+case when jsonb_typeof(rd.stat_modifiers->'intellect')='number' then (rd.stat_modifiers->>'intellect')::numeric::integer else 0 end+coalesce((rm.mods->>'intellect')::integer,0) intellect,
      cp.vitality+m.vitality_mod+case when jsonb_typeof(rd.stat_modifiers->'vitality')='number' then (rd.stat_modifiers->>'vitality')::numeric::integer else 0 end+coalesce((rm.mods->>'vitality')::integer,0) vitality,
      cp.luck+m.luck_mod+case when jsonb_typeof(rd.stat_modifiers->'luck')='number' then (rd.stat_modifiers->>'luck')::numeric::integer else 0 end+coalesce((rm.mods->>'luck')::integer,0) luck,
      m.weapon_type,
      m.weapon_base_damage,
      m.weapon_scaling,
      m.weapon_enhancement_level,
      coalesce(rd.innate_magic_damage_type,'fire')::text magic_type,
      private.merge_numeric_json(
        private.merge_numeric_json(
          m.resistances,
          coalesce(rd.damage_resistances,'{}'::jsonb),
          -75,75
        ),
        coalesce(rm.mods->'resistances','{}'::jsonb),
        -75,75
      ) resistances,
      least(50,m.item_lifesteal + case when rd.passive_type='lifesteal' then rd.passive_value else 0 end + coalesce((rm.mods->>'lifesteal')::integer,0)) lifesteal,
      least(30,m.item_mana_hit + case when rd.passive_type='mana_on_hit' then rd.passive_value else 0 end + coalesce((rm.mods->>'mana_on_hit')::integer,0) + private.character_equipment_set_static_bonus(p_character_id,'mana_on_hit')) mana_hit,
      least(75,m.item_wounded_bonus + case when rd.passive_type='damage_vs_wounded' then rd.passive_value else 0 end) wounded_bonus,
      least(25,m.item_guard_bonus + case when rd.passive_type='guard_boost' then rd.passive_value else 0 end + coalesce((rm.mods->>'guard_boost')::integer,0) + private.character_equipment_set_static_bonus(p_character_id,'guard_boost')) guard_bonus,
      least(50,m.item_all_damage_bonus + case when rd.passive_type='all_damage_bonus' then rd.passive_value else 0 end + coalesce((rm.mods->>'all_damage_bonus')::integer,0) + private.race_low_hp_trait_bonus(p_character_id,'low_hp_all_damage_bonus',cp.hp_current,cp.hp_max) + private.character_equipment_set_low_hp_damage_bonus(p_character_id,cp.hp_current,cp.hp_max)) all_damage_bonus,
      least(75,m.item_physical_damage_bonus + case when rd.passive_type='physical_damage_bonus' then rd.passive_value else 0 end + coalesce((rm.mods->>'physical_damage_bonus')::integer,0) + private.race_weapon_family_damage_bonus(p_character_id) + private.race_low_hp_trait_bonus(p_character_id,'low_hp_physical_damage_bonus',cp.hp_current,cp.hp_max) + private.character_equipment_set_static_bonus(p_character_id,'physical_damage_bonus') + private.camp_preparation_bonus(p_character_id,'physical')) physical_damage_bonus,
      least(75,m.item_magic_damage_bonus + case when rd.passive_type='magic_damage_bonus' then rd.passive_value else 0 end + coalesce((rm.mods->>'magic_damage_bonus')::integer,0) + private.character_equipment_set_static_bonus(p_character_id,'magic_damage_bonus') + private.camp_preparation_bonus(p_character_id,'magic')) magic_damage_bonus,
      least(50,m.item_low_hp_reduction + case when rd.passive_type='low_hp_damage_reduction' then rd.passive_value else 0 end + coalesce((rm.mods->>'low_hp_damage_reduction')::integer,0)) low_hp_reduction,
      least(75,m.item_boss_damage_bonus + case when rd.passive_type='boss_damage_bonus' then rd.passive_value else 0 end + coalesce((rm.mods->>'boss_damage_bonus')::integer,0)) boss_damage_bonus
    from public.character_progress cp
    join public.characters c on c.id=cp.character_id
    left join public.race_definitions rd on rd.id=c.race_id
    cross join mods m
    cross join religion rm
    where cp.character_id=p_character_id
  )
  select
    b.level,least(greatest(1,round(b.hp_max*(100+private.character_max_hp_percent(p_character_id))/100.0)::integer),greatest(1,round(b.hp_current*(100+private.character_max_hp_percent(p_character_id))/100.0)::integer)),greatest(1,round(b.hp_max*(100+private.character_max_hp_percent(p_character_id))/100.0)::integer),b.mana_current,b.mana_max,
    b.strength,b.agility,b.intellect,b.vitality,b.luck,
    private.physical_power_from_enhanced_weapon(
      b.strength,b.agility,b.level,b.weapon_base_damage,b.weapon_scaling,b.weapon_enhancement_level
    ),
    (b.intellect*3+b.luck+b.level*2)::integer,
    greatest(0,round(private.character_physical_defense(
      b.level,b.vitality,b.agility
    )*(100+private.character_defense_percent(p_character_id)+private.race_trait_number(p_character_id,'physical_defense_percent'))/100.0)::integer),
    (b.agility*2+b.luck+private.race_trait_number(p_character_id,'initiative_flat'))::integer,
    b.weapon_type,b.magic_type,b.resistances,
    b.lifesteal,b.mana_hit,b.wounded_bonus,b.guard_bonus,
    b.all_damage_bonus,b.physical_damage_bonus,b.magic_damage_bonus,
    b.low_hp_reduction,b.boss_damage_bonus
  from base b;
$function$
;

CREATE OR REPLACE FUNCTION private.restore_camp_item_snapshot(p_character_id uuid, p_item_definition_id uuid, p_quantity integer, p_durability_current integer, p_durability_max integer, p_custom_name text, p_metadata jsonb, p_enhancement_level smallint, p_awakening_level smallint, p_lineage_id uuid, p_bound_to_character_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare rid uuid; begin
 insert into public.character_items(character_id,item_definition_id,quantity,durability_current,durability_max,custom_name,metadata,enhancement_level,awakening_level,lineage_id,bound_to_character_id)
 values(p_character_id,p_item_definition_id,p_quantity,p_durability_current,p_durability_max,p_custom_name,coalesce(p_metadata,'{}'::jsonb),p_enhancement_level,p_awakening_level,coalesce(p_lineage_id,gen_random_uuid()),p_bound_to_character_id)
 returning id into rid;
 return rid;
end $function$
;

CREATE OR REPLACE FUNCTION private.return_camp_assets(p_owner uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare s public.camp_storage_items; o public.camp_trade_offers;
begin
 for s in select * from public.camp_storage_items where camp_owner_character_id=p_owner order by stored_at loop
  perform private.restore_camp_item_snapshot(p_owner,s.item_definition_id,s.quantity,s.durability_current,s.durability_max,s.custom_name,s.metadata,s.enhancement_level,s.awakening_level,s.lineage_id,s.bound_to_character_id);
 end loop;
 delete from public.camp_storage_items where camp_owner_character_id=p_owner;
 for o in select * from public.camp_trade_offers where camp_owner_character_id=p_owner and status='open' order by created_at loop
  perform private.restore_camp_item_snapshot(o.offered_by_character_id,o.offered_item_definition_id,o.offered_quantity,o.offered_durability_current,o.offered_durability_max,o.offered_custom_name,o.offered_metadata,o.offered_enhancement_level,o.offered_awakening_level,o.offered_lineage_id,null);
 end loop;
 delete from public.camp_trade_offers where camp_owner_character_id=p_owner and status='open';
 delete from public.character_camp_preparations where camp_owner_character_id=p_owner;
end $function$
;

CREATE OR REPLACE FUNCTION private.start_sector_exploration(p_character_id uuid, p_sector_id smallint)
 RETURNS sector_expeditions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid := auth.uid();
  target public.map_sectors;
  expedition public.sector_expeditions;
  duration_seconds integer;
begin
  if private.character_has_active_hunt(p_character_id) then raise exception 'HUNT_ALREADY_ACTIVE'; end if;
  if private.character_has_active_camp_action(p_character_id) then raise exception 'CAMP_ACTION_ALREADY_ACTIVE'; end if;
  if caller_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.characters c
    where c.id = p_character_id
      and c.owner_user_id = caller_id
  ) then
    raise exception 'CHARACTER_NOT_OWNED';
  end if;

  perform private.complete_expired_sector_expeditions(p_character_id);
  perform private.complete_expired_site_actions(p_character_id);

  select *
    into target
  from public.map_sectors s
  where s.id = p_sector_id;

  if target.id is null then
    raise exception 'SECTOR_NOT_FOUND';
  end if;

  if exists (
    select 1
    from public.character_sector_discoveries d
    where d.character_id = p_character_id
      and d.sector_id = p_sector_id
  ) then
    raise exception 'SECTOR_ALREADY_DISCOVERED';
  end if;

  if exists (
    select 1
    from public.sector_expeditions e
    where e.character_id = p_character_id
      and e.status in ('active','awaiting_event')
  ) then
    raise exception 'EXPEDITION_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.sector_site_actions a
    where a.character_id = p_character_id
      and a.status = 'active'
  ) then
    raise exception 'SITE_ACTION_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.dungeon_runs r
    where r.character_id = p_character_id
      and r.status = 'active'
  ) then
    raise exception 'DUNGEON_RUN_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.combat_encounters ce
    where ce.character_id = p_character_id
      and ce.status = 'active'
  ) then
    raise exception 'COMBAT_ALREADY_ACTIVE';
  end if;

  if not exists (
    select 1
    from public.character_sector_discoveries d
    join public.map_sectors known on known.id = d.sector_id
    where d.character_id = p_character_id
      and abs(known.grid_col - target.grid_col) <= 1
      and abs(known.grid_row - target.grid_row) <= 1
      and not (
        known.grid_col = target.grid_col
        and known.grid_row = target.grid_row
      )
  ) then
    raise exception 'SECTOR_NOT_ADJACENT_TO_DISCOVERED';
  end if;

  duration_seconds:=private.character_exploration_duration_seconds(p_character_id,14400);

  insert into public.sector_expeditions (
    character_id,
    sector_id,
    ends_at
  )
  values (
    p_character_id,
    p_sector_id,
    now() + make_interval(secs=>duration_seconds)
  )
  returning * into expedition;

  return expedition;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.accept_camp_trade_offer(p_character_id uuid, p_offer_id uuid, p_requested_character_item_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); o public.camp_trade_offers; payment public.character_items;
  payment_lineage uuid; offered_new_id uuid; payment_new_id uuid;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;
  perform private.cleanup_expired_camps();
  perform private.cleanup_expired_camp_trade_offers();

  select * into o from public.camp_trade_offers where id=p_offer_id for update;
  if o.id is null then raise exception 'TRADE_OFFER_NOT_FOUND'; end if;
  if o.status<>'open' or o.expires_at<=now() then raise exception 'TRADE_OFFER_NOT_OPEN'; end if;
  if o.offered_by_character_id=p_character_id then raise exception 'CANNOT_ACCEPT_OWN_OFFER'; end if;
  if not private.camp_access_allowed(p_character_id,o.camp_owner_character_id) then raise exception 'CAMP_ACCESS_DENIED'; end if;
  if not private.camp_has_module(o.camp_owner_character_id,'trading_post') then raise exception 'TRADING_POST_REQUIRED'; end if;

  select * into payment from public.character_items
  where id=p_requested_character_item_id and character_id=p_character_id for update;
  if payment.id is null
     or payment.item_definition_id<>o.requested_item_definition_id
     or payment.quantity<o.requested_quantity
  then raise exception 'REQUESTED_ITEM_NOT_AVAILABLE'; end if;
  if not private.camp_item_trade_allowed(payment.id,p_character_id) then raise exception 'REQUESTED_ITEM_NOT_TRADEABLE'; end if;

  payment_lineage:=case when payment.quantity=o.requested_quantity then payment.lineage_id else gen_random_uuid() end;
  payment_new_id:=private.restore_camp_item_snapshot(
    o.offered_by_character_id,payment.item_definition_id,o.requested_quantity,
    payment.durability_current,payment.durability_max,payment.custom_name,payment.metadata,
    payment.enhancement_level,payment.awakening_level,payment_lineage,null
  );

  if payment.quantity=o.requested_quantity then delete from public.character_items where id=payment.id;
  else update public.character_items set quantity=quantity-o.requested_quantity where id=payment.id;
  end if;

  offered_new_id:=private.restore_camp_item_snapshot(
    p_character_id,o.offered_item_definition_id,o.offered_quantity,o.offered_durability_current,
    o.offered_durability_max,o.offered_custom_name,o.offered_metadata,o.offered_enhancement_level,
    o.offered_awakening_level,o.offered_lineage_id,null
  );

  update public.camp_trade_offers
  set status='accepted',accepted_by_character_id=p_character_id,accepted_at=now()
  where id=o.id;

  return jsonb_build_object(
    'offer_id',o.id,'received_character_item_id',offered_new_id,
    'seller_received_character_item_id',payment_new_id
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.build_camp_module(p_character_id uuid, p_module_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); c public.character_camps; module_count integer;
begin
 if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
 if p_module_type not in ('scout_post','hunting_table','training_yard','trading_post','field_kitchen') then raise exception 'INVALID_CAMP_MODULE'; end if;
 if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id) then raise exception 'CHARACTER_NOT_OWNED'; end if;
 perform private.cleanup_expired_camps();
 select * into c from public.character_camps where character_id=p_character_id and expires_at>now() for update;
 if c.character_id is null then raise exception 'CAMP_NOT_FOUND'; end if;
 if exists(select 1 from public.camp_modules where camp_owner_character_id=p_character_id and module_type=p_module_type) then raise exception 'CAMP_MODULE_ALREADY_BUILT'; end if;
 select count(*)::integer into module_count from public.camp_modules where camp_owner_character_id=p_character_id;
 if module_count>=private.camp_module_slots(c.camp_level) then raise exception 'CAMP_MODULE_SLOTS_FULL'; end if;
 case p_module_type
  when 'scout_post' then perform private.consume_item_slug(p_character_id,'field_timber',4); perform private.consume_item_slug(p_character_id,'field_fiber',2);
  when 'hunting_table' then perform private.consume_item_slug(p_character_id,'field_timber',3); perform private.consume_item_slug(p_character_id,'field_fiber',2);
  when 'training_yard' then perform private.consume_item_slug(p_character_id,'field_timber',5); perform private.consume_item_slug(p_character_id,'smithing_scrap_beta',2);
  when 'trading_post' then perform private.consume_item_slug(p_character_id,'field_timber',4); perform private.consume_item_slug(p_character_id,'field_fiber',3);
  when 'field_kitchen' then perform private.consume_item_slug(p_character_id,'field_timber',3); perform private.consume_item_slug(p_character_id,'field_fiber',3);
 end case;
 insert into public.camp_modules(camp_owner_character_id,module_type) values(p_character_id,p_module_type);
 return jsonb_build_object('module_type',p_module_type);
end $function$
;

CREATE OR REPLACE FUNCTION public.cancel_camp_trade_offer(p_character_id uuid, p_offer_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); o public.camp_trade_offers;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;
  select * into o from public.camp_trade_offers
  where id=p_offer_id and offered_by_character_id=p_character_id for update;
  if o.id is null then raise exception 'TRADE_OFFER_NOT_FOUND'; end if;
  if o.status<>'open' then raise exception 'TRADE_OFFER_NOT_OPEN'; end if;

  perform private.restore_camp_item_snapshot(
    p_character_id,o.offered_item_definition_id,o.offered_quantity,o.offered_durability_current,
    o.offered_durability_max,o.offered_custom_name,o.offered_metadata,o.offered_enhancement_level,
    o.offered_awakening_level,o.offered_lineage_id,null
  );
  update public.camp_trade_offers set status='cancelled' where id=o.id;
  return true;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.cook_at_camp(p_character_id uuid, p_camp_owner_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); meat_id uuid; herb_id uuid; begin
 if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
 if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id) then raise exception 'CHARACTER_NOT_OWNED'; end if;
 perform private.cleanup_expired_camps();
 if not private.camp_access_allowed(p_character_id,p_camp_owner_character_id) then raise exception 'CAMP_ACCESS_DENIED'; end if;
 if not private.camp_has_module(p_camp_owner_character_id,'field_kitchen') then raise exception 'FIELD_KITCHEN_REQUIRED'; end if;
 select hp.item_definition_id into meat_id from private.hunting_loot_pool hp where hp.resource_type='meat' and private.available_character_item_quantity(p_character_id,hp.item_definition_id)>0 order by hp.item_definition_id limit 1;
 select hp.item_definition_id into herb_id from private.hunting_loot_pool hp where hp.resource_type='herbs' and private.available_character_item_quantity(p_character_id,hp.item_definition_id)>0 order by hp.item_definition_id limit 1;
 if meat_id is null then raise exception 'CAMP_COOKING_NEEDS_MEAT'; end if;
 if herb_id is null then raise exception 'CAMP_COOKING_NEEDS_HERBS'; end if;
 perform private.consume_character_item_definition(p_character_id,meat_id,1);
 perform private.consume_character_item_definition(p_character_id,herb_id,1);
 perform private.grant_item_slug(p_character_id,'camp_stew',1);
 return jsonb_build_object('item_name','Полевое рагу','quantity',1);
end $function$
;

CREATE OR REPLACE FUNCTION public.create_camp_trade_offer(p_character_id uuid, p_camp_owner_character_id uuid, p_character_item_id uuid, p_offered_quantity integer, p_requested_item_definition_id uuid, p_requested_quantity integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); c public.character_camps; ci public.character_items; req public.item_definitions;
  offer_id uuid; offer_exp timestamptz; snapshot_lineage uuid;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;
  perform private.cleanup_expired_camps();
  perform private.cleanup_expired_camp_trade_offers();
  if not private.camp_access_allowed(p_character_id,p_camp_owner_character_id) then raise exception 'CAMP_ACCESS_DENIED'; end if;
  if not private.camp_has_module(p_camp_owner_character_id,'trading_post') then raise exception 'TRADING_POST_REQUIRED'; end if;

  select * into c from public.character_camps where character_id=p_camp_owner_character_id and expires_at>now();
  select * into ci from public.character_items where id=p_character_item_id and character_id=p_character_id for update;
  if ci.id is null or p_offered_quantity<1 or p_offered_quantity>ci.quantity then raise exception 'ITEM_NOT_AVAILABLE'; end if;
  if not private.camp_item_trade_allowed(ci.id,p_character_id) then raise exception 'ITEM_NOT_TRADEABLE'; end if;

  select * into req from public.item_definitions where id=p_requested_item_definition_id;
  if req.id is null or req.trade_policy='bound' then raise exception 'REQUESTED_ITEM_NOT_TRADEABLE'; end if;
  if p_requested_quantity<1 then raise exception 'INVALID_TRADE_QUANTITY'; end if;
  if not req.stackable and p_requested_quantity<>1 then raise exception 'NONSTACKABLE_TRADE_QUANTITY'; end if;

  snapshot_lineage:=case when p_offered_quantity=ci.quantity then ci.lineage_id else gen_random_uuid() end;
  offer_exp:=least(c.expires_at,now()+interval '24 hours');

  insert into public.camp_trade_offers(
    camp_owner_character_id,offered_by_character_id,sector_id,
    offered_item_definition_id,offered_quantity,offered_durability_current,offered_durability_max,
    offered_custom_name,offered_metadata,offered_enhancement_level,offered_awakening_level,offered_lineage_id,
    requested_item_definition_id,requested_quantity,expires_at
  ) values(
    p_camp_owner_character_id,p_character_id,c.sector_id,
    ci.item_definition_id,p_offered_quantity,ci.durability_current,ci.durability_max,
    ci.custom_name,ci.metadata,ci.enhancement_level,ci.awakening_level,snapshot_lineage,
    p_requested_item_definition_id,p_requested_quantity,offer_exp
  ) returning id into offer_id;

  if p_offered_quantity=ci.quantity then delete from public.character_items where id=ci.id;
  else update public.character_items set quantity=quantity-p_offered_quantity where id=ci.id;
  end if;

  return jsonb_build_object('offer_id',offer_id,'expires_at',offer_exp);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.deposit_camp_storage(p_character_id uuid, p_character_item_id uuid, p_quantity integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); c public.character_camps; ci public.character_items;
  used integer; capacity integer; snapshot_lineage uuid; sid uuid;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;
  perform private.cleanup_expired_camps();
  select * into c from public.character_camps where character_id=p_character_id and expires_at>now() for update;
  if c.character_id is null then raise exception 'CAMP_NOT_FOUND'; end if;
  select count(*)::integer into used from public.camp_storage_items where camp_owner_character_id=p_character_id;
  capacity:=private.camp_storage_capacity(c.camp_level);
  if used>=capacity then raise exception 'CAMP_STORAGE_FULL'; end if;

  select * into ci from public.character_items where id=p_character_item_id and character_id=p_character_id for update;
  if ci.id is null or p_quantity<1 or p_quantity>ci.quantity then raise exception 'ITEM_NOT_AVAILABLE'; end if;
  if ci.death_spirit_id is not null or exists(select 1 from public.character_equipment ce where ce.character_item_id=ci.id)
    then raise exception 'ITEM_NOT_STORABLE'; end if;

  snapshot_lineage:=case when p_quantity=ci.quantity then ci.lineage_id else gen_random_uuid() end;
  insert into public.camp_storage_items(
    camp_owner_character_id,item_definition_id,quantity,durability_current,durability_max,custom_name,
    metadata,enhancement_level,awakening_level,lineage_id,bound_to_character_id
  ) values(
    p_character_id,ci.item_definition_id,p_quantity,ci.durability_current,ci.durability_max,ci.custom_name,
    ci.metadata,ci.enhancement_level,ci.awakening_level,snapshot_lineage,ci.bound_to_character_id
  ) returning id into sid;

  if p_quantity=ci.quantity then delete from public.character_items where id=ci.id;
  else update public.character_items set quantity=quantity-p_quantity where id=ci.id;
  end if;

  return jsonb_build_object('storage_item_id',sid,'used_slots',used+1,'capacity',capacity);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.finish_camp_action(p_character_id uuid, p_action_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); a public.camp_actions; sd public.sector_details; result_data jsonb;
begin
 if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
 if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id) then raise exception 'CHARACTER_NOT_OWNED'; end if;
 select * into a from public.camp_actions where id=p_action_id and actor_character_id=p_character_id for update;
 if a.id is null then raise exception 'CAMP_ACTION_NOT_FOUND'; end if;
 if a.status<>'active' then raise exception 'CAMP_ACTION_NOT_ACTIVE'; end if;
 if a.ends_at>now() then raise exception 'CAMP_ACTION_NOT_READY'; end if;
 if a.action_type='rest' then
  update public.character_progress set hp_current=hp_max,mana_current=mana_max,hp_regen_anchor_at=now(),mana_regen_anchor_at=now(),updated_at=now() where character_id=p_character_id;
  result_data:=jsonb_build_object('title','Отдых завершён','text','ОЗ и мана полностью восстановлены.');
 else
  select * into sd from public.sector_details where sector_id=a.target_sector_id;
  insert into public.camp_scout_reports(character_id,camp_owner_character_id,sector_id,terrain_type,content_hint,danger_level)
  values(p_character_id,a.camp_owner_character_id,a.target_sector_id,coalesce(sd.terrain_type,'unknown'),
    case coalesce(sd.content_type,'unassigned') when 'settlement' then 'видны признаки поселения' when 'ruins' then 'замечены древние руины' when 'dungeon' then 'обнаружены следы подземного входа' when 'resource' then 'есть признаки ресурсной точки' when 'npc' then 'замечена стоянка или одиночная фигура' when 'landmark' then 'виден необычный ориентир' when 'event' then 'местность выглядит необычно' else 'ничего заметного издалека' end,
    coalesce(sd.danger_level,0));
  result_data:=jsonb_build_object('title','Разведка завершена','text','Разведчики вернулись с предварительным отчётом.','sector_id',a.target_sector_id,'terrain_type',sd.terrain_type,'danger_level',coalesce(sd.danger_level,0));
 end if;
 update public.camp_actions set status='completed',result=result_data,completed_at=now() where id=a.id;
 return result_data;
end $function$
;

CREATE OR REPLACE FUNCTION public.finish_hunt_v2(p_character_id uuid, p_attempt_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid(); h private.hunting_attempts; sd public.sector_details;
  stats record; template public.enemy_templates; loot_row record;
  run_id uuid; encounter_id uuid; item_name text; quantity integer:=0; tracking_experience integer:=0;
  effective_danger integer; enemy_hp integer; enemy_attack integer; enemy_defense integer; enemy_initiative integer; enemy_level integer;
  monster_roll numeric; resource_roll numeric; hunting_table_bonus integer:=0; camp_owner uuid;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters c where c.id=p_character_id and c.owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select * into h from private.hunting_attempts
  where id=p_attempt_id and character_id=p_character_id
  for update;
  if h.id is null then raise exception 'HUNT_NOT_FOUND'; end if;
  if h.status<>'active' then
    return jsonb_build_object(
      'result',h.result_kind,'attempt_id',h.id,'pressure',h.pressure_level,'monster_chance',h.monster_chance,
      'item_name',(select name from public.item_definitions where id=h.item_definition_id),'quantity',h.quantity,
      'run_id',h.dungeon_run_id,'encounter_id',h.combat_encounter_id
    );
  end if;
  if h.finishes_at is null or h.finishes_at>now() then raise exception 'HUNT_NOT_READY'; end if;

  select * into sd from public.sector_details where sector_id=h.sector_id;
  monster_roll:=random();
  resource_roll:=random();

  if h.pressure_level>=6 or monster_roll<h.monster_chance/100.0 then
    perform private.apply_passive_hp_regen(p_character_id);
    perform private.apply_passive_mana_regen(p_character_id);
    select * into stats from private.get_character_combat_stats(p_character_id);
    if stats.level is null then raise exception 'CHARACTER_PROGRESS_NOT_FOUND'; end if;
    if stats.hp_current<=0 then raise exception 'CHARACTER_HAS_NO_HP'; end if;

    select t.* into template
    from public.enemy_templates t
    where t.enabled=true and t.is_boss=true and t.terrain_type=sd.terrain_type
      and t.slug<>'white_wolf_world_enemy'
    order by (-ln(greatest(random(),0.000001))/greatest(t.weight,1))
    limit 1;
    if template.id is null then raise exception 'NO_STRONG_HUNT_MONSTER_FOR_REGION'; end if;

    effective_danger:=greatest(3,least(10,coalesce(sd.danger_level,0)+2));
    enemy_level:=greatest(stats.level+1,effective_danger*2+1);
    enemy_hp:=50+effective_danger*25+12;
    enemy_attack:=10+effective_danger*4+2;
    enemy_defense:=6+effective_danger*3+2;
    enemy_initiative:=6+effective_danger*2+1;
    if effective_danger=10 then
      enemy_hp:=enemy_hp+150; enemy_attack:=enemy_attack+15; enemy_defense:=enemy_defense+12; enemy_initiative:=enemy_initiative+8;
    end if;
    enemy_hp:=ceil(enemy_hp*1.40*template.hp_multiplier)::integer;
    enemy_attack:=ceil(enemy_attack*1.20*template.attack_multiplier)::integer;
    enemy_defense:=ceil(enemy_defense*1.15*template.defense_multiplier)::integer;
    enemy_initiative:=greatest(0,round((enemy_initiative+3)*template.initiative_multiplier)::integer);

    insert into public.dungeon_runs(
      character_id,sector_id,status,current_stage,rooms_cleared,total_rooms,reward_gold,reward_experience,hunting_attempt_id
    ) values(p_character_id,h.sector_id,'active','hunting_combat',0,1,0,0,h.id)
    returning id into run_id;

    insert into public.combat_encounters(
      dungeon_run_id,character_id,sector_id,status,round,room_index,is_boss,
      enemy_template_id,enemy_name,enemy_level,enemy_hp_current,enemy_hp_max,
      enemy_attack,enemy_defense,enemy_initiative,enemy_damage_type,enemy_resistances,
      enemy_on_hit_effect_type,enemy_on_hit_effect_chance,enemy_on_hit_effect_turns,enemy_on_hit_effect_potency,
      enemy_special_name,enemy_special_damage_multiplier,enemy_special_every_n,enemy_special_damage_type,
      enemy_special_effect_type,enemy_special_effect_chance,enemy_special_effect_turns,enemy_special_effect_potency,
      enemy_special_telegraph_text,enemy_special_attack_text,enemy_special_kind,enemy_special_value,
      enemy_phase2_hp_percent,enemy_phase2_name,enemy_phase2_attack_bonus_percent,enemy_phase2_defense_bonus_percent,
      enemy_phase2_special_every_n,enemy_abilities,enemy_ai_state,
      player_physical_damage_type,player_magic_damage_type,player_hp_current,player_hp_max,player_mana_current,player_mana_max
    ) values(
      run_id,p_character_id,h.sector_id,'active',0,1,true,
      template.id,template.name,enemy_level,enemy_hp,enemy_hp,
      enemy_attack,enemy_defense,enemy_initiative,template.attack_damage_type,template.damage_resistances,
      template.on_hit_effect_type,template.on_hit_effect_chance,template.on_hit_effect_turns,template.on_hit_effect_potency,
      template.special_name,template.special_damage_multiplier,template.special_every_n,template.special_damage_type,
      template.special_effect_type,template.special_effect_chance,template.special_effect_turns,template.special_effect_potency,
      template.special_telegraph_text,template.special_attack_text,template.special_kind,template.special_value,
      template.phase2_hp_percent,template.phase2_name,template.phase2_attack_bonus_percent,template.phase2_defense_bonus_percent,
      template.phase2_special_every_n,template.abilities,'{}'::jsonb,
      stats.weapon_damage_type,stats.magic_damage_type,stats.hp_current,stats.hp_max,stats.mana_current,stats.mana_max
    ) returning id into encounter_id;

    update private.hunting_attempts
    set result_kind='monster',status='combat',enemy_template_id=template.id,
        dungeon_run_id=run_id,combat_encounter_id=encounter_id,resolved_at=now()
    where id=h.id;

    update public.character_progress
    set hp_regen_anchor_at=now(),mana_regen_anchor_at=now(),updated_at=now()
    where character_id=p_character_id;

    insert into public.combat_turns(
      encounter_id,round,actor,action_type,damage,player_hp_after,enemy_hp_after,message
    ) values(
      encounter_id,0,'system','hunting_monster_start',0,stats.hp_current,enemy_hp,
      'Следы привели к сильному противнику: '||template.name||'. Давление региона: '||h.pressure_level||'/6.'
    );

    return jsonb_build_object(
      'result','monster','attempt_id',h.id,'pressure',h.pressure_level,'monster_chance',h.monster_chance,
      'region_key',h.region_key,'enemy_name',template.name,'run_id',run_id,'encounter_id',encounter_id
    );
  end if;

  if resource_roll<0.70 then
    select hp.*,d.name item_name into loot_row
    from private.hunting_loot_pool hp
    join public.item_definitions d on d.id=hp.item_definition_id
    where hp.terrain_type=sd.terrain_type
    order by (
      -ln(greatest(random(),0.000001))
      /greatest(
        hp.weight*case when h.focus_type<>'general' and hp.resource_type=h.focus_type then 4 else 1 end,
        1
      )
    )
    limit 1;

    if loot_row.item_definition_id is null then raise exception 'HUNT_LOOT_POOL_EMPTY'; end if;
    quantity:=loot_row.min_quantity+floor(random()*(loot_row.max_quantity-loot_row.min_quantity+1))::integer;

    select c.character_id into camp_owner
    from public.character_camps c
    join public.camp_modules m on m.camp_owner_character_id=c.character_id and m.module_type='hunting_table'
    where c.sector_id=h.sector_id and c.expires_at>now()
      and private.camp_access_allowed(p_character_id,c.character_id)
    order by (c.character_id=p_character_id) desc,c.placed_at
    limit 1;
    hunting_table_bonus:=case when camp_owner is not null then 1 else 0 end;
    quantity:=quantity+hunting_table_bonus;

    perform private.grant_character_item(
      p_character_id,loot_row.item_definition_id,quantity,
      jsonb_build_object('source','hunting','sector_id',h.sector_id,'region',h.region_key,'pressure',h.pressure_level,'focus',h.focus_type)
    );

    update private.hunting_attempts
    set result_kind='resource',status='resolved',item_definition_id=loot_row.item_definition_id,
        quantity=quantity,resolved_at=now()
    where id=h.id;

    return jsonb_build_object(
      'result','resource','attempt_id',h.id,'pressure',h.pressure_level,'monster_chance',h.monster_chance,
      'region_key',h.region_key,'item_name',loot_row.item_name,'quantity',quantity,
      'resource_type',loot_row.resource_type,'hunting_table_bonus',hunting_table_bonus
    );
  end if;

  tracking_experience:=3+greatest(0,least(10,coalesce(sd.danger_level,0)))+h.pressure_level;
  update public.character_progress set experience=experience+tracking_experience,updated_at=now()
  where character_id=p_character_id;
  update private.hunting_attempts set result_kind='tracks',status='resolved',resolved_at=now() where id=h.id;

  return jsonb_build_object(
    'result','tracks','attempt_id',h.id,'pressure',h.pressure_level,'monster_chance',h.monster_chance,
    'region_key',h.region_key,'experience',tracking_experience
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_camp_state(p_character_id uuid, p_camp_owner_character_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); owner_id uuid; c public.character_camps; camp_json jsonb:='null'::jsonb;
  modules_json jsonb:='[]'::jsonb; action_json jsonb:='null'::jsonb; prep_json jsonb:='null'::jsonb;
  reports_json jsonb:='[]'::jsonb; targets_json jsonb:='[]'::jsonb; storage_json jsonb:='[]'::jsonb;
  offers_json jsonb:='[]'::jsonb; resource_json jsonb:='{}'::jsonb; event_json jsonb:='null'::jsonb;
  event_roll integer; event_claimed boolean;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;
  perform private.cleanup_expired_camps();
  perform private.cleanup_expired_camp_trade_offers();

  owner_id:=coalesce(p_camp_owner_character_id,p_character_id);
  select * into c from public.character_camps where character_id=owner_id and expires_at>now();
  if c.character_id is not null and not private.camp_access_allowed(p_character_id,owner_id)
    then raise exception 'CAMP_ACCESS_DENIED'; end if;

  if c.character_id is not null then
    camp_json:=jsonb_build_object(
      'owner_character_id',c.character_id,
      'owner_name',(select ch.name from public.characters ch where ch.id=c.character_id),
      'sector_id',c.sector_id,'camp_level',c.camp_level,'access_mode',c.access_mode,
      'camp_name',c.camp_name,'placed_at',c.placed_at,'expires_at',c.expires_at,
      'module_slots',private.camp_module_slots(c.camp_level),
      'storage_capacity',private.camp_storage_capacity(c.camp_level),
      'is_owner',c.character_id=p_character_id
    );

    select coalesce(jsonb_agg(jsonb_build_object('module_type',m.module_type,'built_at',m.built_at) order by m.built_at),'[]'::jsonb)
      into modules_json from public.camp_modules m where m.camp_owner_character_id=owner_id;

    if private.camp_has_module(owner_id,'scout_post') then
      select coalesce(jsonb_agg(jsonb_build_object('sector_id',s.id,'grid_col',s.grid_col,'grid_row',s.grid_row) order by s.id),'[]'::jsonb)
      into targets_json
      from public.map_sectors s
      join public.map_sectors origin on origin.id=c.sector_id
      where abs(origin.grid_col-s.grid_col)<=1 and abs(origin.grid_row-s.grid_row)<=1
        and not(origin.grid_col=s.grid_col and origin.grid_row=s.grid_row)
        and not exists(select 1 from public.character_sector_discoveries d where d.character_id=p_character_id and d.sector_id=s.id);
    end if;

    if c.character_id=p_character_id then
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',s.id,'item_definition_id',s.item_definition_id,'item_name',d.name,'rarity',d.rarity::text,
        'quantity',s.quantity,'custom_name',s.custom_name,'enhancement_level',s.enhancement_level,
        'awakening_level',s.awakening_level
      ) order by s.stored_at),'[]'::jsonb)
      into storage_json
      from public.camp_storage_items s join public.item_definitions d on d.id=s.item_definition_id
      where s.camp_owner_character_id=owner_id;
    end if;

    if private.camp_has_module(owner_id,'trading_post') then
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',o.id,'offered_by_character_id',o.offered_by_character_id,
        'offered_by_name',seller.name,'offered_item_definition_id',o.offered_item_definition_id,
        'offered_item_name',od.name,'offered_quantity',o.offered_quantity,
        'offered_rarity',od.rarity::text,'offered_custom_name',o.offered_custom_name,
        'requested_item_definition_id',o.requested_item_definition_id,'requested_item_name',rd.name,
        'requested_quantity',o.requested_quantity,'expires_at',o.expires_at,
        'is_mine',o.offered_by_character_id=p_character_id
      ) order by o.created_at desc),'[]'::jsonb)
      into offers_json
      from public.camp_trade_offers o
      join public.item_definitions od on od.id=o.offered_item_definition_id
      join public.item_definitions rd on rd.id=o.requested_item_definition_id
      join public.characters seller on seller.id=o.offered_by_character_id
      where o.camp_owner_character_id=owner_id and o.status='open' and o.expires_at>now();
    end if;

    event_roll:=abs(hashtext(current_date::text||':'||p_character_id::text||':'||owner_id::text))%4;
    event_claimed:=exists(select 1 from public.camp_event_claims where character_id=p_character_id and event_date=current_date);
    event_json:=jsonb_build_object(
      'kind',case event_roll when 0 then 'traveler' when 1 then 'lost_pack' when 2 then 'fallen_branch' else 'quiet' end,
      'title',case event_roll when 0 then 'Путник у костра' when 1 then 'Потерянный свёрток' when 2 then 'После ночного ветра' else 'Тихая ночь' end,
      'claimed',event_claimed
    );
  end if;

  select jsonb_build_object(
    'field_timber',coalesce(sum(ci.quantity) filter(where d.slug='field_timber'),0),
    'field_fiber',coalesce(sum(ci.quantity) filter(where d.slug='field_fiber'),0),
    'smithing_scrap',coalesce(sum(ci.quantity) filter(where d.slug='smithing_scrap_beta'),0)
  ) into resource_json
  from public.character_items ci join public.item_definitions d on d.id=ci.item_definition_id
  where ci.character_id=p_character_id and ci.death_spirit_id is null;

  select jsonb_build_object('id',a.id,'action_type',a.action_type,'target_sector_id',a.target_sector_id,'started_at',a.started_at,'ends_at',a.ends_at)
  into action_json
  from public.camp_actions a where a.actor_character_id=p_character_id and a.status='active'
  order by a.started_at desc limit 1;

  select jsonb_build_object('preparation_type',p.preparation_type,'expires_at',p.expires_at,'bonus_percent',6)
  into prep_json
  from public.character_camp_preparations p where p.character_id=p_character_id and p.expires_at>now();

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'sector_id',r.sector_id,'terrain_type',r.terrain_type,'content_hint',r.content_hint,
    'danger_level',r.danger_level,'created_at',r.created_at,'expires_at',r.expires_at
  ) order by r.created_at desc),'[]'::jsonb)
  into reports_json
  from public.camp_scout_reports r where r.character_id=p_character_id and r.expires_at>now();

  return jsonb_build_object(
    'camp',camp_json,'modules',modules_json,'active_action',action_json,'preparation',prep_json,
    'scout_reports',reports_json,'scout_targets',targets_json,'storage',storage_json,
    'trade_offers',offers_json,'resources',resource_json,'daily_event',event_json
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_character_activity_journal_v2(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
 caller_id uuid:=auth.uid(); base jsonb; entries_data jsonb:='[]'::jsonb; camp_data jsonb:='null'::jsonb;
 blocker_data jsonb:='null'::jsonb; h private.hunting_attempts; a public.camp_actions; c public.character_camps;
begin
 if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
 if not exists(select 1 from public.characters ch where ch.id=p_character_id and (ch.owner_user_id=caller_id or private.is_gm(caller_id)))
   then raise exception 'CHARACTER_NOT_OWNED'; end if;

 perform private.cleanup_expired_camps();
 perform private.cleanup_expired_camp_trade_offers();
 base:=public.get_character_activity_journal(p_character_id);

 select coalesce(jsonb_agg(e),'[]'::jsonb) into entries_data
 from jsonb_array_elements(coalesce(base->'entries','[]'::jsonb)) e
 where e->>'kind'<>'camp';

 select * into h from private.hunting_attempts
 where character_id=p_character_id and status='active'
 order by created_at desc limit 1;

 select * into a from public.camp_actions
 where actor_character_id=p_character_id and status='active'
 order by started_at desc limit 1;

 if h.id is not null then
   blocker_data:=jsonb_build_object(
     'kind','hunting','title','Идёт охота',
     'detail','Выслеживание занимает 10 минут. После возвращения забери результат.',
     'sector_id',h.sector_id,'ends_at',h.finishes_at
   );
   entries_data:=entries_data||jsonb_build_array(jsonb_build_object(
     'id',h.id::text,'kind','hunting','title','Охота',
     'objective','Выслеживание в секторе #'||h.sector_id::text,
     'reward_hint','Ресурсы региона, следы или встреча с сильным противником',
     'sector_id',h.sector_id,'ends_at',h.finishes_at,'progress_current',0,'progress_target',1,
     'status','active','action_hint',case when h.finishes_at<=now() then 'Охота завершена — забери результат на карте.' else 'Дождись возвращения с охоты.' end
   ));
 elsif a.id is not null then
   blocker_data:=jsonb_build_object(
     'kind','camp_action','title',case a.action_type when 'rest' then 'Отдых в лагере' else 'Лагерная разведка' end,
     'detail',case a.action_type when 'rest' then 'Персонаж отдыхает у костра.' else 'Разведчики осматривают соседний сектор.' end,
     'sector_id',(select sector_id from public.character_camps where character_id=a.camp_owner_character_id),
     'ends_at',a.ends_at
   );
   entries_data:=entries_data||jsonb_build_array(jsonb_build_object(
     'id',a.id::text,'kind','camp_action',
     'title',case a.action_type when 'rest' then 'Отдых в лагере' else 'Разведка из лагеря' end,
     'objective',case a.action_type when 'rest' then 'Восстановить ОЗ и ману' else 'Получить предварительный отчёт о секторе #'||a.target_sector_id::text end,
     'reward_hint',case a.action_type when 'rest' then 'Полное восстановление ресурсов' else 'Тип местности, опасность и признаки интересных мест' end,
     'sector_id',(select sector_id from public.character_camps where character_id=a.camp_owner_character_id),
     'ends_at',a.ends_at,'progress_current',0,'progress_target',1,'status','active',
     'action_hint',case when a.ends_at<=now() then 'Действие завершено — забери результат в лагере.' else 'Дождись окончания.' end
   ));
 else
   blocker_data:=coalesce(base->'blocker','null'::jsonb);
 end if;

 select * into c from public.character_camps where character_id=p_character_id and expires_at>now();
 if c.character_id is not null then
   camp_data:=jsonb_build_object(
     'sector_id',c.sector_id,'camp_level',c.camp_level,'access_mode',c.access_mode,
     'placed_at',c.placed_at,'expires_at',c.expires_at,
     'module_slots',private.camp_module_slots(c.camp_level),
     'module_count',(select count(*) from public.camp_modules m where m.camp_owner_character_id=c.character_id),
     'storage_capacity',private.camp_storage_capacity(c.camp_level),
     'storage_used',(select count(*) from public.camp_storage_items s where s.camp_owner_character_id=c.character_id)
   );
   entries_data:=entries_data||jsonb_build_array(jsonb_build_object(
     'id',c.character_id::text,'kind','camp','title','Полевой лагерь · уровень '||c.camp_level::text,
     'objective','Сектор #'||c.sector_id::text||' · построек '
       ||(select count(*)::text from public.camp_modules m where m.camp_owner_character_id=c.character_id)
       ||'/'||private.camp_module_slots(c.camp_level)::text,
     'reward_hint','Отдых, постройки, склад, подготовка, разведка и локальный обмен',
     'sector_id',c.sector_id,'ends_at',c.expires_at,'progress_current',
       (select count(*)::integer from public.camp_modules m where m.camp_owner_character_id=c.character_id),
     'progress_target',private.camp_module_slots(c.camp_level),'status','active',
     'action_hint','Развивай лагерь ресурсами, строй модули или используй его как полевую базу.'
   ));
 end if;

 return jsonb_set(jsonb_set(jsonb_set(base,'{entries}',entries_data,true),'{blocker}',blocker_data,true),'{camp}',camp_data,true);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_character_hunting_state_v2(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller uuid:=auth.uid(); st private.hunting_states; active_json jsonb:='null'::jsonb; last_json jsonb:='null'::jsonb;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters c where c.id=p_character_id and c.owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select * into st from private.hunting_states where character_id=p_character_id;

  select jsonb_build_object(
    'attempt_id',h.id,'sector_id',h.sector_id,'region_key',h.region_key,'pressure',h.pressure_level,
    'monster_chance',h.monster_chance,'focus',h.focus_type,'started_at',h.created_at,'finishes_at',h.finishes_at,
    'ready',h.finishes_at<=now()
  ) into active_json
  from private.hunting_attempts h
  where h.character_id=p_character_id and h.status='active'
  order by h.created_at desc limit 1;

  select jsonb_build_object(
    'attempt_id',h.id,'sector_id',h.sector_id,'result',h.result_kind,'resolved_at',h.resolved_at,
    'item_name',d.name,'quantity',h.quantity,
    'enemy_name',et.name
  ) into last_json
  from private.hunting_attempts h
  left join public.item_definitions d on d.id=h.item_definition_id
  left join public.enemy_templates et on et.id=h.enemy_template_id
  where h.character_id=p_character_id and h.status<>'active'
  order by coalesce(h.resolved_at,h.created_at) desc limit 1;

  return jsonb_build_object(
    'region_key',case when st.character_id is not null and st.locked_until>now() then st.region_key else null end,
    'pressure',case when st.character_id is not null and st.locked_until>now() then st.pressure else 0 end,
    'locked_until',case when st.character_id is not null and st.locked_until>now() then st.locked_until else null end,
    'active',st.character_id is not null and st.locked_until>now(),
    'next_pressure',case when st.character_id is not null and st.locked_until>now() then least(6,st.pressure+1) else 1 end,
    'next_monster_chance',private.hunting_monster_chance(case when st.character_id is not null and st.locked_until>now() then least(6,st.pressure+1) else 1 end),
    'resource_chance',70,
    'duration_seconds',600,
    'active_hunt',active_json,
    'last_result',last_json
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_character_world_markers_v2(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); base jsonb; result_data jsonb:='[]'::jsonb;
begin
 if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
 if not exists(select 1 from public.characters ch where ch.id=p_character_id and (ch.owner_user_id=caller_id or private.is_gm(caller_id)))
   then raise exception 'CHARACTER_NOT_OWNED'; end if;
 perform private.cleanup_expired_camps();

 base:=public.get_character_world_markers(p_character_id);
 select coalesce(jsonb_agg(e),'[]'::jsonb) into result_data
 from jsonb_array_elements(coalesce(base,'[]'::jsonb)) e
 where e->>'kind'<>'camp';

 result_data:=result_data||coalesce((
   select jsonb_agg(jsonb_build_object(
     'id',c.character_id::text,'kind','camp','sector_id',c.sector_id,
     'title',case when c.character_id=p_character_id then 'Твой лагерь' else 'Лагерь · '||ch.name end,
     'detail','Уровень '||c.camp_level::text||' · построек '
       ||(select count(*)::text from public.camp_modules m where m.camp_owner_character_id=c.character_id)
       ||'/'||private.camp_module_slots(c.camp_level)::text,
     'ends_at',c.expires_at,'camp_owner_character_id',c.character_id,
     'is_own',c.character_id=p_character_id,'access_mode',c.access_mode,'camp_level',c.camp_level
   ) order by (c.character_id=p_character_id) desc,c.placed_at)
   from public.character_camps c
   join public.characters ch on ch.id=c.character_id
   where c.expires_at>now()
     and private.camp_access_allowed(p_character_id,c.character_id)
     and (c.character_id=p_character_id or exists(
       select 1 from public.character_sector_discoveries d
       where d.character_id=p_character_id and d.sector_id=c.sector_id
     ))
 ),'[]'::jsonb);

 return result_data;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.place_character_camp(p_character_id uuid, p_sector_id smallint, p_specialization text DEFAULT 'base'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); sd public.sector_details; exp timestamptz;
begin
 if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
 if not exists(select 1 from public.characters c where c.id=p_character_id and c.owner_user_id=caller_id) then raise exception 'CHARACTER_NOT_OWNED'; end if;
 perform private.cleanup_expired_camps();
 if exists(select 1 from public.character_camps where character_id=p_character_id) then raise exception 'CAMP_ALREADY_ACTIVE'; end if;
 if not exists(select 1 from public.character_sector_discoveries d where d.character_id=p_character_id and d.sector_id=p_sector_id) then raise exception 'CAMP_SECTOR_NOT_DISCOVERED'; end if;
 select * into sd from public.sector_details where sector_id=p_sector_id;
 if sd.sector_id is null or sd.content_type<>'wilderness' or sd.terrain_type='sea' then raise exception 'CAMP_REQUIRES_WILDERNESS'; end if;
 if private.character_blocked_for_party_dungeon(p_character_id) or private.character_has_active_hunt(p_character_id) or private.character_has_active_camp_action(p_character_id) then raise exception 'CHARACTER_BUSY'; end if;
 exp:=now()+interval '5 days';
 insert into public.character_camps(character_id,sector_id,specialization,camp_level,access_mode,camp_name,placed_at,expires_at,updated_at)
 values(p_character_id,p_sector_id,'base',1,'private','Полевой лагерь',now(),exp,now());
 return jsonb_build_object('character_id',p_character_id,'sector_id',p_sector_id,'camp_level',1,'access_mode','private','price',0,'expires_at',exp);
end $function$
;

CREATE OR REPLACE FUNCTION public.prepare_at_camp(p_character_id uuid, p_camp_owner_character_id uuid, p_preparation_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); exp timestamptz; begin
 if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
 if p_preparation_type not in ('physical','magic','fortify') then raise exception 'INVALID_PREPARATION'; end if;
 if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id) then raise exception 'CHARACTER_NOT_OWNED'; end if;
 perform private.cleanup_expired_camps();
 if not private.camp_access_allowed(p_character_id,p_camp_owner_character_id) then raise exception 'CAMP_ACCESS_DENIED'; end if;
 if not private.camp_has_module(p_camp_owner_character_id,'training_yard') then raise exception 'TRAINING_YARD_REQUIRED'; end if;
 if private.character_blocked_for_party_dungeon(p_character_id) or private.character_has_active_hunt(p_character_id) then raise exception 'CHARACTER_BUSY'; end if;
 exp:=now()+interval '45 minutes';
 insert into public.character_camp_preparations(character_id,camp_owner_character_id,preparation_type,prepared_at,expires_at)
 values(p_character_id,p_camp_owner_character_id,p_preparation_type,now(),exp)
 on conflict(character_id) do update set camp_owner_character_id=excluded.camp_owner_character_id,preparation_type=excluded.preparation_type,prepared_at=now(),expires_at=excluded.expires_at;
 return jsonb_build_object('preparation_type',p_preparation_type,'bonus_percent',6,'expires_at',exp);
end $function$
;

CREATE OR REPLACE FUNCTION public.refuel_character_camp(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); c public.character_camps; new_exp timestamptz;
begin
 if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
 if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id) then raise exception 'CHARACTER_NOT_OWNED'; end if;
 perform private.cleanup_expired_camps();
 select * into c from public.character_camps where character_id=p_character_id and expires_at>now() for update;
 if c.character_id is null then raise exception 'CAMP_NOT_FOUND'; end if;
 perform private.consume_item_slug(p_character_id,'field_timber',2); perform private.consume_item_slug(p_character_id,'field_fiber',1);
 new_exp:=least(c.expires_at+interval '48 hours',now()+interval '7 days');
 if new_exp<=c.expires_at then raise exception 'CAMP_DURATION_CAP'; end if;
 update public.character_camps set expires_at=new_exp,updated_at=now() where character_id=p_character_id;
 return jsonb_build_object('expires_at',new_exp);
end $function$
;

CREATE OR REPLACE FUNCTION public.remove_camp_module(p_character_id uuid, p_module_type text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); begin
 if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
 if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id) then raise exception 'CHARACTER_NOT_OWNED'; end if;
 delete from public.camp_modules where camp_owner_character_id=p_character_id and module_type=p_module_type;
 if not found then return false; end if;
 case p_module_type
  when 'scout_post' then perform private.grant_item_slug(p_character_id,'field_timber',2); perform private.grant_item_slug(p_character_id,'field_fiber',1);
  when 'hunting_table' then perform private.grant_item_slug(p_character_id,'field_timber',1); perform private.grant_item_slug(p_character_id,'field_fiber',1);
  when 'training_yard' then perform private.grant_item_slug(p_character_id,'field_timber',2); perform private.grant_item_slug(p_character_id,'smithing_scrap_beta',1);
  when 'trading_post' then perform private.grant_item_slug(p_character_id,'field_timber',2); perform private.grant_item_slug(p_character_id,'field_fiber',1);
  when 'field_kitchen' then perform private.grant_item_slug(p_character_id,'field_timber',1); perform private.grant_item_slug(p_character_id,'field_fiber',1);
  else null;
 end case;
 return true;
end $function$
;

CREATE OR REPLACE FUNCTION public.remove_character_camp(p_character_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); c public.character_camps; begin
 if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
 if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id) then raise exception 'CHARACTER_NOT_OWNED'; end if;
 select * into c from public.character_camps where character_id=p_character_id for update;
 if c.character_id is null then return false; end if;
 perform private.return_camp_assets(p_character_id);
 perform private.grant_item_slug(p_character_id,'field_timber',case c.camp_level when 3 then 8 when 2 then 3 else 0 end);
 perform private.grant_item_slug(p_character_id,'field_fiber',case c.camp_level when 3 then 5 when 2 then 2 else 0 end);
 if c.camp_level=3 then perform private.grant_item_slug(p_character_id,'smithing_scrap_beta',1); end if;
 delete from public.character_camps where character_id=p_character_id;
 return true;
end $function$
;

CREATE OR REPLACE FUNCTION public.resolve_camp_daily_event(p_character_id uuid, p_camp_owner_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); roll integer; kind text; title text; body text;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;
  perform private.cleanup_expired_camps();
  if not private.camp_access_allowed(p_character_id,p_camp_owner_character_id) then raise exception 'CAMP_ACCESS_DENIED'; end if;
  if exists(select 1 from public.camp_event_claims where character_id=p_character_id and event_date=current_date)
    then raise exception 'CAMP_EVENT_ALREADY_RESOLVED'; end if;

  roll:=abs(hashtext(current_date::text||':'||p_character_id::text||':'||p_camp_owner_character_id::text))%4;
  if roll=0 then
    kind:='traveler'; title:='Путник у костра'; body:='Незнакомец ненадолго разделил огонь и оставил пару полезных наблюдений.';
    update public.character_progress set experience=experience+8,updated_at=now() where character_id=p_character_id;
  elsif roll=1 then
    kind:='lost_pack'; title:='Потерянный свёрток'; body:='У края стоянки нашёлся забытый свёрток с пригодными для ремонта материалами.';
    perform private.grant_item_slug(p_character_id,'field_fiber',1);
  elsif roll=2 then
    kind:='fallen_branch'; title:='После ночного ветра'; body:='Ветер свалил рядом сухое дерево. Часть древесины удалось пустить на лагерные нужды.';
    perform private.grant_item_slug(p_character_id,'field_timber',1);
  else
    kind:='quiet'; title:='Тихая ночь'; body:='Ночь прошла спокойно. Редкая роскошь для полевой стоянки.';
    update public.character_progress set hp_current=least(hp_max,hp_current+20),updated_at=now() where character_id=p_character_id;
  end if;

  insert into public.camp_event_claims(character_id,event_date,event_kind) values(p_character_id,current_date,kind);
  return jsonb_build_object('kind',kind,'title',title,'text',body);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_camp_access(p_character_id uuid, p_access_mode text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); begin
 if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
 if p_access_mode not in ('private','party','open') then raise exception 'INVALID_CAMP_ACCESS'; end if;
 if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id) then raise exception 'CHARACTER_NOT_OWNED'; end if;
 perform private.cleanup_expired_camps();
 update public.character_camps set access_mode=p_access_mode,updated_at=now() where character_id=p_character_id and expires_at>now();
 if not found then raise exception 'CAMP_NOT_FOUND'; end if;
 return jsonb_build_object('access_mode',p_access_mode);
end $function$
;

CREATE OR REPLACE FUNCTION public.start_camp_action(p_character_id uuid, p_camp_owner_character_id uuid, p_action_type text, p_target_sector_id smallint DEFAULT NULL::smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); c public.character_camps; target public.map_sectors; ends_value timestamptz;
begin
 if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
 if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id) then raise exception 'CHARACTER_NOT_OWNED'; end if;
 if p_action_type not in ('rest','scout') then raise exception 'INVALID_CAMP_ACTION'; end if;
 perform private.cleanup_expired_camps();
 if not private.camp_access_allowed(p_character_id,p_camp_owner_character_id) then raise exception 'CAMP_ACCESS_DENIED'; end if;
 select * into c from public.character_camps where character_id=p_camp_owner_character_id and expires_at>now();
 if c.character_id is null then raise exception 'CAMP_NOT_FOUND'; end if;
 if private.character_blocked_for_party_dungeon(p_character_id) or private.character_has_active_hunt(p_character_id) or private.character_has_active_camp_action(p_character_id) then raise exception 'CHARACTER_BUSY'; end if;
 if p_action_type='scout' then
  if not private.camp_has_module(p_camp_owner_character_id,'scout_post') then raise exception 'SCOUT_POST_REQUIRED'; end if;
  if p_target_sector_id is null then raise exception 'SCOUT_TARGET_REQUIRED'; end if;
  select * into target from public.map_sectors where id=p_target_sector_id;
  if target.id is null then raise exception 'SECTOR_NOT_FOUND'; end if;
  if exists(select 1 from public.character_sector_discoveries d where d.character_id=p_character_id and d.sector_id=p_target_sector_id) then raise exception 'SCOUT_TARGET_ALREADY_DISCOVERED'; end if;
  if not exists(select 1 from public.map_sectors origin where origin.id=c.sector_id and abs(origin.grid_col-target.grid_col)<=1 and abs(origin.grid_row-target.grid_row)<=1 and not(origin.grid_col=target.grid_col and origin.grid_row=target.grid_row)) then raise exception 'SCOUT_TARGET_NOT_ADJACENT'; end if;
  ends_value:=now()+interval '20 minutes';
 else ends_value:=now()+interval '30 minutes'; end if;
 insert into public.camp_actions(actor_character_id,camp_owner_character_id,action_type,target_sector_id,ends_at) values(p_character_id,p_camp_owner_character_id,p_action_type,p_target_sector_id,ends_value);
 return jsonb_build_object('action_type',p_action_type,'ends_at',ends_value,'target_sector_id',p_target_sector_id);
end $function$
;

CREATE OR REPLACE FUNCTION public.start_dungeon_run(p_character_id uuid, p_sector_id smallint)
 RETURNS dungeon_runs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid := auth.uid();
  created_run public.dungeon_runs;
  sector_info public.sector_details;
  danger integer;
  room_count integer;
  reward_gold_value integer;
  reward_exp_value integer;
  character_level integer:=1;
  reward_exhausted_value boolean:=false;
  reward_attempt_number_value integer:=1;
  reward_cycle_ends_at_value timestamptz;
  modifier_slug_value text;
begin
  if private.character_has_active_hunt(p_character_id) then raise exception 'HUNT_ALREADY_ACTIVE'; end if;
  if private.character_has_active_camp_action(p_character_id) then raise exception 'CAMP_ACTION_ALREADY_ACTIVE'; end if;
  if caller_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.characters c
    where c.id = p_character_id
      and c.owner_user_id = caller_id
  ) then
    raise exception 'CHARACTER_NOT_OWNED';
  end if;

  perform private.complete_expired_sector_expeditions(p_character_id);
  perform private.complete_expired_site_actions(p_character_id);

  select details.*
    into sector_info
  from public.character_sector_discoveries d
  join public.sector_details details on details.sector_id = d.sector_id
  where d.character_id = p_character_id
    and d.sector_id = p_sector_id
    and details.content_type = 'dungeon';

  if sector_info.sector_id is null then
    raise exception 'DUNGEON_NOT_DISCOVERED';
  end if;

  if not exists (
    select 1
    from public.character_sector_site_progress p
    where p.character_id = p_character_id
      and p.sector_id = p_sector_id
      and p.site_type = 'dungeon'
      and p.status in ('scouted','cleared')
  ) then
    raise exception 'DUNGEON_NOT_SCOUTED';
  end if;

  if exists (
    select 1
    from public.sector_expeditions e
    where e.character_id = p_character_id
      and e.status in ('active','awaiting_event')
  ) then
    raise exception 'EXPEDITION_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.sector_site_actions a
    where a.character_id = p_character_id
      and a.status = 'active'
  ) then
    raise exception 'SITE_ACTION_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.dungeon_runs r
    where r.character_id = p_character_id
      and r.status = 'active'
  ) then
    raise exception 'DUNGEON_RUN_ALREADY_ACTIVE';
  end if;

  select a.attempt_number,a.reward_exhausted,a.cycle_ends_at
  into reward_attempt_number_value,reward_exhausted_value,reward_cycle_ends_at_value
  from private.consume_dungeon_reward_attempt(p_character_id,p_sector_id) a;

  danger := greatest(0, least(10, coalesce(sector_info.danger_level, 0)));
  modifier_slug_value:=private.pick_dungeon_modifier(danger);

  select coalesce(cp.level,1) into character_level
  from public.character_progress cp
  where cp.character_id=p_character_id;

  room_count := case
    when danger = 0 then 1
    when danger <= 2 then 2
    when danger <= 4 then 3
    when danger <= 6 then 4
    when danger <= 8 then 5
    else 6
  end;

  reward_gold_value:=private.scaled_dungeon_gold(
    danger,character_level,private.dungeon_base_gold(danger)
  );

  if danger = 0 then
    reward_exp_value := private.dungeon_zero_experience(character_level);
  else
    reward_exp_value := 50 + danger * 45 + room_count * 18;
    reward_exp_value:=private.scaled_dungeon_xp(danger,character_level,reward_exp_value);
  end if;

  reward_gold_value:=greatest(
    1,
    round(reward_gold_value
      *private.dungeon_repeat_gold_multiplier_percent(p_character_id,p_sector_id)
      /100.0
    )::integer
  );
  reward_exp_value:=greatest(
    0,
    round(reward_exp_value
      *private.dungeon_repeat_xp_multiplier_percent(p_character_id,p_sector_id)
      /100.0
    )::integer
  );

  if not reward_exhausted_value and modifier_slug_value is not null then
    reward_gold_value:=greatest(1,round(reward_gold_value*(100+private.dungeon_modifier_value(modifier_slug_value,'reward_gold_percent'))/100.0)::integer);
    reward_exp_value:=greatest(0,round(reward_exp_value*(100+private.dungeon_modifier_value(modifier_slug_value,'reward_xp_percent'))/100.0)::integer);
  end if;

  if reward_exhausted_value then
    reward_gold_value:=0;
    reward_exp_value:=0;
  end if;

  insert into public.dungeon_runs (
    character_id,
    sector_id,
    status,
    current_stage,
    rooms_cleared,
    total_rooms,
    reward_gold,
    reward_experience,
    reward_exhausted,
    reward_attempt_number,
    reward_cycle_ends_at,
    modifier_slug
  )
  values (
    p_character_id,
    p_sector_id,
    'active',
    'entrance',
    0,
    room_count,
    reward_gold_value,
    reward_exp_value,
    reward_exhausted_value,
    reward_attempt_number_value,
    reward_cycle_ends_at_value,
    modifier_slug_value
  )
  returning * into created_run;

  return created_run;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.start_hunt(p_character_id uuid, p_sector_id smallint)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
 select public.start_hunt_v2(p_character_id,p_sector_id,'general');
$function$
;

CREATE OR REPLACE FUNCTION public.start_hunt_v2(p_character_id uuid, p_sector_id smallint, p_focus text DEFAULT 'general'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid(); sd public.sector_details; st private.hunting_states;
  attempt_id uuid; next_pressure integer; monster_chance integer; finish_time timestamptz;
  camp_owner uuid;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters c where c.id=p_character_id and c.owner_user_id=caller)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;
  if p_focus not in ('general','meat','hide','herbs','supplies') then raise exception 'INVALID_HUNT_FOCUS'; end if;

  perform private.cleanup_expired_camps();
  if private.character_blocked_for_party_dungeon(p_character_id)
     or private.character_has_active_hunt(p_character_id)
     or private.character_has_active_camp_action(p_character_id)
  then raise exception 'CHARACTER_BUSY'; end if;

  if not exists(select 1 from public.character_sector_discoveries d where d.character_id=p_character_id and d.sector_id=p_sector_id)
    then raise exception 'HUNT_SECTOR_NOT_DISCOVERED'; end if;
  select * into sd from public.sector_details where sector_id=p_sector_id;
  if sd.sector_id is null or sd.content_type<>'wilderness' then raise exception 'HUNT_REQUIRES_WILDERNESS'; end if;
  if sd.terrain_type='sea' then raise exception 'HUNT_NOT_AVAILABLE_AT_SEA'; end if;
  if exists(
    select 1 from public.event_boss_events e
    where e.enabled=true and e.boss_kind='sector_incursion' and e.sector_id=p_sector_id
      and now()>=e.starts_at and now()<e.ends_at
  ) then raise exception 'SECTOR_CAPTURED'; end if;

  if p_focus<>'general' then
    select c.character_id into camp_owner
    from public.character_camps c
    join public.camp_modules m on m.camp_owner_character_id=c.character_id and m.module_type='hunting_table'
    where c.sector_id=p_sector_id and c.expires_at>now()
      and private.camp_access_allowed(p_character_id,c.character_id)
    order by (c.character_id=p_character_id) desc,c.placed_at
    limit 1;
    if camp_owner is null then raise exception 'HUNTING_TABLE_REQUIRED'; end if;
  end if;

  select * into st from private.hunting_states where character_id=p_character_id for update;
  if st.character_id is null or st.locked_until<=now() then
    next_pressure:=1;
    insert into private.hunting_states(character_id,region_key,pressure,locked_until,last_hunt_at,updated_at)
    values(p_character_id,sd.terrain_type,1,now()+interval '12 hours',now(),now())
    on conflict(character_id) do update set region_key=excluded.region_key,pressure=1,locked_until=excluded.locked_until,last_hunt_at=now(),updated_at=now();
  else
    if st.region_key<>sd.terrain_type then raise exception 'HUNT_REGION_LOCKED:%:%',st.region_key,st.locked_until; end if;
    next_pressure:=least(6,st.pressure+1);
    update private.hunting_states
    set pressure=next_pressure,locked_until=now()+interval '12 hours',last_hunt_at=now(),updated_at=now()
    where character_id=p_character_id;
  end if;

  monster_chance:=private.hunting_monster_chance(next_pressure);
  finish_time:=now()+interval '10 minutes';

  insert into private.hunting_attempts(
    character_id,sector_id,region_key,pressure_level,monster_chance,result_kind,status,
    focus_type,finishes_at
  ) values(
    p_character_id,p_sector_id,sd.terrain_type,next_pressure,monster_chance,'pending','active',
    p_focus,finish_time
  ) returning id into attempt_id;

  return jsonb_build_object(
    'result','pending','attempt_id',attempt_id,'sector_id',p_sector_id,'region_key',sd.terrain_type,
    'pressure',next_pressure,'monster_chance',monster_chance,'focus',p_focus,
    'started_at',now(),'finishes_at',finish_time,'duration_seconds',600
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.start_sector_site_action(p_character_id uuid, p_sector_id smallint, p_action_type text)
 RETURNS sector_site_actions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid := auth.uid();
  sd public.sector_details;
  created_action public.sector_site_actions;
  base_duration_seconds integer;
  effective_duration_seconds integer;
begin
  if private.character_has_active_hunt(p_character_id) then raise exception 'HUNT_ALREADY_ACTIVE'; end if;
  if private.character_has_active_camp_action(p_character_id) then raise exception 'CAMP_ACTION_ALREADY_ACTIVE'; end if;
  if caller_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.characters c
    where c.id = p_character_id
      and c.owner_user_id = caller_id
  ) then
    raise exception 'CHARACTER_NOT_OWNED';
  end if;

  perform private.complete_expired_sector_expeditions(p_character_id);
  perform private.complete_expired_site_actions(p_character_id);

  if not exists (
    select 1
    from public.character_sector_discoveries d
    where d.character_id = p_character_id
      and d.sector_id = p_sector_id
  ) then
    raise exception 'SECTOR_NOT_DISCOVERED';
  end if;

  select *
    into sd
  from public.sector_details
  where sector_id = p_sector_id;

  if sd.sector_id is null then
    raise exception 'SECTOR_DETAILS_NOT_FOUND';
  end if;

  if p_action_type = 'explore_ruins' then
    if sd.content_type <> 'ruins' then
      raise exception 'SECTOR_IS_NOT_RUINS';
    end if;
    base_duration_seconds := 7200;

    if exists (
      select 1
      from public.character_sector_site_progress p
      where p.character_id = p_character_id
        and p.sector_id = p_sector_id
        and p.status in ('explored','cleared')
    ) then
      raise exception 'RUINS_ALREADY_EXPLORED';
    end if;
  elsif p_action_type = 'scout_dungeon' then
    if sd.content_type <> 'dungeon' then
      raise exception 'SECTOR_IS_NOT_DUNGEON';
    end if;
    base_duration_seconds := 3600;

    if exists (
      select 1
      from public.character_sector_site_progress p
      where p.character_id = p_character_id
        and p.sector_id = p_sector_id
        and p.status in ('scouted','cleared')
    ) then
      raise exception 'DUNGEON_ALREADY_SCOUTED';
    end if;
  else
    raise exception 'INVALID_SITE_ACTION';
  end if;

  if exists (
    select 1
    from public.sector_expeditions e
    where e.character_id = p_character_id
      and e.status in ('active','awaiting_event')
  ) then
    raise exception 'EXPEDITION_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.sector_site_actions a
    where a.character_id = p_character_id
      and a.status = 'active'
  ) then
    raise exception 'SITE_ACTION_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.dungeon_runs r
    where r.character_id = p_character_id
      and r.status = 'active'
  ) then
    raise exception 'DUNGEON_RUN_ALREADY_ACTIVE';
  end if;

  if exists (
    select 1
    from public.combat_encounters ce
    where ce.character_id = p_character_id
      and ce.status = 'active'
  ) then
    raise exception 'COMBAT_ALREADY_ACTIVE';
  end if;

  effective_duration_seconds:=private.character_exploration_duration_seconds(
    p_character_id,
    base_duration_seconds
  );

  insert into public.sector_site_actions (
    character_id,
    sector_id,
    action_type,
    ends_at
  )
  values (
    p_character_id,
    p_sector_id,
    p_action_type,
    now() + make_interval(secs=>effective_duration_seconds)
  )
  returning * into created_action;

  return created_action;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.start_treasure_hunt_expedition(p_hunt_id uuid)
 RETURNS sector_expeditions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid:=auth.uid();
  owner_character_id uuid;
  hunt public.character_treasure_hunts;
  expedition public.sector_expeditions;
  duration_seconds integer;
  base_seconds integer;
begin
  if private.character_has_active_hunt(p_character_id) then raise exception 'HUNT_ALREADY_ACTIVE'; end if;
  if private.character_has_active_camp_action(p_character_id) then raise exception 'CAMP_ACTION_ALREADY_ACTIVE'; end if;
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;

  select h.character_id
  into owner_character_id
  from public.character_treasure_hunts h
  join public.characters c on c.id=h.character_id
  where h.id=p_hunt_id and c.owner_user_id=caller_id;

  if owner_character_id is null then
    raise exception 'TREASURE_HUNT_NOT_FOUND';
  end if;

  perform private.complete_expired_sector_expeditions(owner_character_id);
  perform private.complete_expired_site_actions(owner_character_id);

  select h.*
  into hunt
  from public.character_treasure_hunts h
  where h.id=p_hunt_id
  for update;

  if hunt.id is null then raise exception 'TREASURE_HUNT_NOT_FOUND'; end if;
  if hunt.status<>'active' then raise exception 'TREASURE_HUNT_NOT_ACTIVE'; end if;

  select e.* into expedition
  from public.sector_expeditions e
  where e.treasure_hunt_id=hunt.id
    and e.treasure_stage=hunt.stage
    and e.status='active'
  order by e.started_at desc
  limit 1;

  if expedition.id is not null then return expedition; end if;

  if exists(
    select 1
    from public.sector_expeditions e
    where e.treasure_hunt_id=hunt.id
      and coalesce(e.treasure_stage,1)=hunt.stage
      and e.status='completed'
  ) then raise exception 'TREASURE_HUNT_ALREADY_VISITED'; end if;

  if exists(
    select 1 from public.sector_expeditions e
    where e.character_id=hunt.character_id
      and e.status in ('active','awaiting_event')
  ) then raise exception 'EXPEDITION_ALREADY_ACTIVE'; end if;

  if exists(
    select 1 from public.sector_site_actions a
    where a.character_id=hunt.character_id and a.status='active'
  ) then raise exception 'SITE_ACTION_ALREADY_ACTIVE'; end if;

  if exists(
    select 1 from public.dungeon_runs r
    where r.character_id=hunt.character_id and r.status='active'
  ) then raise exception 'DUNGEON_RUN_ALREADY_ACTIVE'; end if;

  if exists(
    select 1 from public.combat_encounters ce
    where ce.character_id=hunt.character_id and ce.status='active'
  ) then raise exception 'COMBAT_ALREADY_ACTIVE'; end if;

  if exists(
    select 1
    from public.party_dungeon_runs pr
    join public.party_dungeon_run_members prm on prm.run_id=pr.id
    where prm.character_id=hunt.character_id and pr.status='active'
  ) then raise exception 'PARTY_DUNGEON_ACTIVE'; end if;

  if not exists(
    select 1 from public.character_sector_discoveries d
    where d.character_id=hunt.character_id
      and d.sector_id=hunt.target_sector_id
  ) then raise exception 'TREASURE_TARGET_NOT_DISCOVERED'; end if;

  base_seconds:=case hunt.hunt_kind
    when 'lost_trail' then 9000
    when 'guarded_vault' then 10800
    when 'cursed_route' then 9000
    else 14400
  end;

  duration_seconds:=private.character_exploration_duration_seconds(
    hunt.character_id,base_seconds
  );

  insert into public.sector_expeditions(
    character_id,sector_id,ends_at,treasure_hunt_id,treasure_stage
  )
  values(
    hunt.character_id,hunt.target_sector_id,
    now()+make_interval(secs=>duration_seconds),
    hunt.id,hunt.stage
  )
  returning * into expedition;

  return expedition;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.upgrade_character_camp(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); c public.character_camps; next_level integer;
begin
 if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
 if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id) then raise exception 'CHARACTER_NOT_OWNED'; end if;
 perform private.cleanup_expired_camps();
 select * into c from public.character_camps where character_id=p_character_id and expires_at>now() for update;
 if c.character_id is null then raise exception 'CAMP_NOT_FOUND'; end if;
 if c.camp_level>=3 then raise exception 'CAMP_MAX_LEVEL'; end if;
 next_level:=c.camp_level+1;
 if next_level=2 then
  perform private.consume_item_slug(p_character_id,'field_timber',6); perform private.consume_item_slug(p_character_id,'field_fiber',4);
 else
  perform private.consume_item_slug(p_character_id,'field_timber',10); perform private.consume_item_slug(p_character_id,'field_fiber',6); perform private.consume_item_slug(p_character_id,'smithing_scrap_beta',2);
 end if;
 update public.character_camps set camp_level=next_level,updated_at=now() where character_id=p_character_id;
 return jsonb_build_object('camp_level',next_level,'module_slots',private.camp_module_slots(next_level),'storage_capacity',private.camp_storage_capacity(next_level));
end $function$
;

CREATE OR REPLACE FUNCTION public.withdraw_camp_storage(p_character_id uuid, p_storage_item_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare caller_id uuid:=auth.uid(); s public.camp_storage_items; rid uuid;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(select 1 from public.characters where id=p_character_id and owner_user_id=caller_id)
    then raise exception 'CHARACTER_NOT_OWNED'; end if;
  select * into s from public.camp_storage_items
  where id=p_storage_item_id and camp_owner_character_id=p_character_id for update;
  if s.id is null then raise exception 'CAMP_STORAGE_ITEM_NOT_FOUND'; end if;

  rid:=private.restore_camp_item_snapshot(
    p_character_id,s.item_definition_id,s.quantity,s.durability_current,s.durability_max,s.custom_name,
    s.metadata,s.enhancement_level,s.awakening_level,s.lineage_id,s.bound_to_character_id
  );
  delete from public.camp_storage_items where id=s.id;
  return jsonb_build_object('character_item_id',rid,'quantity',s.quantity);
end;
$function$
;


drop trigger if exists bind_character_item_on_equip on public.character_equipment;
create trigger bind_character_item_on_equip
after insert or update of character_item_id on public.character_equipment
for each row execute function private.bind_character_item_on_equip();

update public.character_items ci
set bound_to_character_id=ce.character_id
from public.character_equipment ce,public.item_definitions d
where ce.character_item_id=ci.id and d.id=ci.item_definition_id
  and d.trade_policy='bind_on_equip' and ci.bound_to_character_id is null;

do $$
declare r record;
begin
  for r in
    select p.oid,p.oid::regprocedure as signature
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in (
      'place_character_camp','set_camp_access','upgrade_character_camp','refuel_character_camp',
      'build_camp_module','remove_camp_module','remove_character_camp','start_camp_action','finish_camp_action',
      'prepare_at_camp','cook_at_camp','deposit_camp_storage','withdraw_camp_storage',
      'create_camp_trade_offer','cancel_camp_trade_offer','accept_camp_trade_offer','resolve_camp_daily_event',
      'get_camp_state','start_hunt_v2','finish_hunt_v2','get_character_hunting_state_v2',
      'get_character_activity_journal_v2','get_character_world_markers_v2','start_hunt'
    )
  loop
    execute 'revoke all on function '||r.signature||' from public,anon';
    execute 'grant execute on function '||r.signature||' to authenticated,service_role';
  end loop;

  for r in
    select p.oid,p.oid::regprocedure as signature
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='private' and p.proname in (
      'camp_module_slots','camp_storage_capacity','characters_share_active_party','camp_access_allowed',
      'camp_has_module','character_has_active_hunt','character_has_active_camp_action','camp_preparation_bonus',
      'bind_character_item_on_equip','consume_item_slug','restore_camp_item_snapshot','return_camp_assets',
      'cleanup_expired_camps','cleanup_expired_camp_trade_offers','camp_item_trade_allowed'
    )
  loop
    execute 'revoke all on function '||r.signature||' from public,anon,authenticated';
  end loop;
end;
$$;

