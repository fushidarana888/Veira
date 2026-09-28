-- Synced from live Supabase migration 20260927221842 (party_state_exposes_world_alive)

CREATE OR REPLACE FUNCTION public.get_party_dungeon_state(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid:=auth.uid();
  v_run_id uuid;
  v_encounter_id uuid;
  result jsonb;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id
      and c.owner_user_id=caller_id
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select pr.id into v_run_id
  from public.party_dungeon_runs pr
  join public.party_dungeon_run_members prm on prm.run_id=pr.id
  where prm.character_id=p_character_id
  order by (pr.status='active') desc,pr.created_at desc
  limit 1;

  if v_run_id is null then
    return jsonb_build_object(
      'run',null,
      'encounter',null,
      'members','[]'::jsonb,
      'statuses','[]'::jsonb,
      'turns','[]'::jsonb,
      'loot','[]'::jsonb,
      'sacrifice_scroll_count',coalesce((
        select sum(ci.quantity)::integer
        from public.character_items ci
        join public.item_definitions idf on idf.id=ci.item_definition_id
        where ci.character_id=p_character_id
          and idf.slug='combat_scroll_last_sacrifice'
      ),0)
    );
  end if;

  select ce.id into v_encounter_id
  from public.party_combat_encounters ce
  where ce.run_id=v_run_id
  order by (ce.status='active') desc,ce.room_index desc,ce.created_at desc
  limit 1;

  select jsonb_build_object(
    'sacrifice_scroll_count',coalesce((
      select sum(ci.quantity)::integer
      from public.character_items ci
      join public.item_definitions idf on idf.id=ci.item_definition_id
      where ci.character_id=p_character_id
        and idf.slug='combat_scroll_last_sacrifice'
    ),0),
    'run',(
      select jsonb_build_object(
        'id',pr.id,
        'party_id',pr.party_id,
        'leader_character_id',pr.leader_character_id,
        'sector_id',pr.sector_id,
        'title',coalesce((select ebe.name from public.event_boss_events ebe where ebe.id=pr.event_boss_id),coalesce(sd.title,'Подземелье')),
        'is_event_boss',pr.event_boss_id is not null,
        'event_boss_id',pr.event_boss_id,
        'danger_level',sd.danger_level,
        'modifier',case when pr.modifier_slug is null then null else (
          select jsonb_build_object(
            'slug',m.slug,
            'name',m.name,
            'description',m.description,
            'theme',m.theme,
            'enemy_hp_percent',m.enemy_hp_percent,
            'enemy_attack_percent',m.enemy_attack_percent,
            'enemy_defense_percent',m.enemy_defense_percent,
            'reward_gold_percent',m.reward_gold_percent,
            'reward_xp_percent',m.reward_xp_percent
          )
          from public.dungeon_modifier_definitions m
          where m.slug=pr.modifier_slug
        ) end,
        'status',pr.status,
        'current_stage',pr.current_stage,
        'rooms_cleared',pr.rooms_cleared,
        'total_rooms',pr.total_rooms,
        'reward_gold',pr.reward_gold,
        'reward_experience',pr.reward_experience,
        'member_count',pr.member_count,
        'escape_attempt_stage',pr.escape_attempt_stage,
        'started_at',pr.started_at,
        'sacrifice_scroll_used',pr.sacrifice_scroll_used
      )
      from public.party_dungeon_runs pr
      join public.sector_details sd on sd.sector_id=pr.sector_id
      where pr.id=v_run_id
    ),
    'encounter',case when v_encounter_id is null then null else (
      select jsonb_build_object(
        'id',ce.id,
        'room_index',ce.room_index,
        'is_boss',ce.is_boss,
        'is_rare_variant',exists(
          select 1 from public.enemy_templates et
          where et.id=ce.enemy_template_id and et.is_rare_variant
        ),
        'status',ce.status,
        'round',ce.round,
        'enemy_name',ce.enemy_name,
        'enemy_level',ce.enemy_level,
        'enemy_hp_current',ce.enemy_hp_current,
        'enemy_hp_max',ce.enemy_hp_max,
        'enemy_attack',ce.enemy_attack,
        'enemy_defense',ce.enemy_defense,
        'enemy_damage_type',ce.enemy_damage_type,
        'enemy_bloodshed_stacks',ce.enemy_bloodshed_stacks,
        'acted_character_ids',to_jsonb(ce.acted_character_ids),
        'next_actor_character_id',private.party_next_actor_id(ce.id),
        'created_at',ce.created_at,
        'ended_at',ce.ended_at
      )
      from public.party_combat_encounters ce
      where ce.id=v_encounter_id
    ) end,
    'members',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'character_id',c.id,
          'name',c.name,
          'display_name',pf.display_name,
          'race',c.race,
          'level',cp.level,
          'initiative',combat_stats.initiative,
          'hp_current',case when prm.lost then 0 when prm.dead and ms.character_id is null then 1 else coalesce(ms.hp_current,cp.hp_current) end,
          'hp_max',coalesce(ms.hp_max,cp.hp_max),
          'mana_current',coalesce(ms.mana_current,cp.mana_current),
          'mana_max',coalesce(ms.mana_max,cp.mana_max),
          'downed',case when prm.lost then true else coalesce(ms.downed,prm.dead) end,
          'dead',prm.dead,
          'lost',prm.lost,
          'lost_reason',prm.lost_reason,
          'incoming_damage_reduction_percent',coalesce(ms.incoming_damage_reduction_percent,0),
          'incoming_damage_reduction_rounds',coalesce(ms.incoming_damage_reduction_rounds,0),
          'guard_percent',coalesce(ms.guard_percent,0),
          'reflect_percent',coalesce(ms.reflect_percent,0),
          'damage_bonus_percent',coalesce(ms.damage_bonus_percent,0),
          'damage_bonus_hits',coalesce(ms.damage_bonus_hits,0),
          'taunt_chance',coalesce(ms.taunt_chance,0),
          'bow_distance',coalesce(ms.bow_distance,'medium'),
          'bow_draw_pending',coalesce(ms.bow_draw_pending,false),
          'acted',case
            when ce.id is null then false
            else c.id=any(ce.acted_character_ids)
          end,
          'is_leader',(c.id=pr.leader_character_id),
          'joined_order',prm.joined_order,
          'initiative_meter',coalesce(ms.initiative_meter,0),
          'reward_exhausted',coalesce(prm.reward_exhausted,false),
          'reward_attempt_number',prm.reward_attempt_number,
          'reward_cycle_ends_at',prm.reward_cycle_ends_at
        )
        order by combat_stats.initiative desc, prm.joined_order
      )
      from public.party_dungeon_run_members prm
      join public.party_dungeon_runs pr on pr.id=prm.run_id
      join public.characters c on c.id=prm.character_id
      join public.profiles pf on pf.user_id=c.owner_user_id
      join public.character_progress cp on cp.character_id=c.id
      cross join lateral private.get_character_combat_stats(c.id) combat_stats
      left join public.party_combat_encounters ce on ce.id=v_encounter_id
      left join public.party_combat_member_states ms
        on ms.encounter_id=ce.id
       and ms.character_id=c.id
      where prm.run_id=v_run_id
    ),'[]'::jsonb),
    'statuses',case when v_encounter_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',se.id,
        'target_type',se.target_type,
        'target_character_id',se.target_character_id,
        'effect_type',se.effect_type,
        'potency',se.potency,
        'remaining_turns',se.remaining_turns,
        'source',se.source
      ) order by se.id)
      from public.party_combat_status_effects se
      where se.encounter_id=v_encounter_id
    ),'[]'::jsonb) end,
    'turns',case when v_encounter_id is null then '[]'::jsonb else coalesce((
      select jsonb_agg(to_jsonb(x) order by x.id desc)
      from (
        select
          t.id,t.round,t.actor_type,t.actor_character_id,t.target_character_id,
          t.action_type,t.damage,t.message,t.created_at
        from public.party_combat_turns t
        where t.encounter_id=v_encounter_id
        order by t.id desc
        limit 30
      ) x
    ),'[]'::jsonb) end,
    'loot',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',pl.id,
          'source_type',pl.source_type,
          'item_definition_id',pl.item_definition_id,
          'item_name',idf.name,
          'rarity',idf.rarity::text,
          'quantity',pl.quantity,
          'created_at',pl.created_at
        )
        order by pl.created_at desc
      )
      from public.party_loot_drops pl
      join public.item_definitions idf on idf.id=pl.item_definition_id
      where pl.run_id=v_run_id
        and pl.character_id=p_character_id
    ),'[]'::jsonb)
  ) into result;

  return result;
end;
$function$;
