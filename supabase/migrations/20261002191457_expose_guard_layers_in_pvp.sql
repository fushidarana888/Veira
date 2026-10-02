CREATE OR REPLACE FUNCTION public.get_pvp_duel(p_duel_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller_id uuid := auth.uid();
  caller_character_id uuid;
  result jsonb;
begin
  if caller_id is null then raise exception 'AUTH_REQUIRED'; end if;

  select c.id into caller_character_id
  from public.pvp_duels d
  join public.characters c
    on c.id in (d.challenger_character_id,d.opponent_character_id)
   and c.owner_user_id=caller_id
  where d.id=p_duel_id
  limit 1;

  if caller_character_id is null then raise exception 'DUEL_NOT_FOUND'; end if;

  select jsonb_build_object(
    'duel', jsonb_build_object(
      'id',d.id,'status',d.status,
      'challenger_character_id',d.challenger_character_id,
      'opponent_character_id',d.opponent_character_id,
      'winner_character_id',d.winner_character_id,
      'current_turn_character_id',d.current_turn_character_id,
      'round',d.round,'finish_reason',d.finish_reason,
      'created_at',d.created_at,'started_at',d.started_at,
      'ended_at',d.ended_at,'turn_started_at',d.turn_started_at
    ),
    'participants', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'character_id',s.character_id,'side',s.side,
          'name',c.name,'race',c.race,'avatar_url',c.avatar_url,
          'display_name',p.display_name,
          'level',s.level,
          'hp_current',s.hp_current,'hp_max',s.hp_max,
          'mana_current',s.mana_current,'mana_max',s.mana_max,
          'physical_power',s.physical_power,'magic_power',s.magic_power,
          'defense',s.defense,
          'physical_defense',s.physical_defense,
          'magic_defense',s.magic_defense,
          'initiative',s.initiative,'initiative_meter',s.initiative_meter,
          'weapon_damage_type',s.weapon_damage_type,
          'magic_damage_type',s.magic_damage_type,
          'guard_reduction_percent',s.guard_reduction_percent,
          'guard_stance_active',s.guard_stance_active,
          'guard_spell_percent',s.guard_spell_percent,
          'reflect_percent',s.reflect_percent,
          'counter_bonus_percent',0,
          'counter_blocked_damage',s.counter_blocked_damage,
          'counter_bonus_damage',greatest(0,round(s.counter_blocked_damage*0.50)::integer),
          'spell_damage_bonus_percent',s.spell_damage_bonus_percent,
          'spell_damage_bonus_hits',s.spell_damage_bonus_hits,
          'bow_distance',s.bow_distance,
          'bow_draw_pending',s.bow_draw_pending,
          'bloodshed_stacks',s.bloodshed_stacks
        )
        order by case s.side when 'challenger' then 0 else 1 end
      )
      from public.pvp_duel_states s
      join public.characters c on c.id=s.character_id
      join public.profiles p on p.user_id=c.owner_user_id
      where s.duel_id=d.id
    ),'[]'::jsonb),
    'turns', coalesce((
      select jsonb_agg(to_jsonb(tq) order by tq.id)
      from (
        select t.id,t.round,t.actor_character_id,t.action_type,t.damage,t.healing,t.message,t.created_at,
               c.name as actor_name
        from public.pvp_duel_turns t
        left join public.characters c on c.id=t.actor_character_id
        where t.duel_id=d.id
        order by t.id desc
        limit 50
      ) tq
    ),'[]'::jsonb),
    'statuses', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',s.id,'target_character_id',s.target_character_id,
        'effect_type',s.effect_type,'potency',s.potency,
        'remaining_turns',s.remaining_turns,'source_character_id',s.source_character_id
      ) order by s.created_at)
      from public.pvp_duel_status_effects s
      where s.duel_id=d.id
    ),'[]'::jsonb)
  ) into result
  from public.pvp_duels d
  where d.id=p_duel_id;

  return result;
end;
$function$
;
