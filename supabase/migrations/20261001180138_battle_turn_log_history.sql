CREATE OR REPLACE FUNCTION public.get_battle_turn_log(p_character_id uuid, p_kind text, p_battle_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  caller uuid:=auth.uid();
  result jsonb:='[]'::jsonb;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then
    raise exception 'CHARACTER_NOT_OWNED';
  end if;

  if p_kind='solo' then
    if not exists(
      select 1 from public.dungeon_runs dr
      where dr.id=p_battle_id and dr.character_id=p_character_id
    ) then raise exception 'BATTLE_NOT_FOUND'; end if;

    select coalesce(jsonb_agg(jsonb_build_object(
      'id','solo:'||t.id::text,
      'room',ce.room_index,
      'round',t.round,
      'actor_name',case
        when t.actor='player' then ch.name
        when t.actor='enemy' then ce.enemy_name
        when t.action_type='status_tick' then 'Эффект противника'
        when t.action_type='bloodshed_tick' then 'Эффект персонажа'
        else 'Система'
      end,
      'target_name',case
        when t.actor='player' and t.damage>0 then ce.enemy_name
        when t.actor='enemy' and t.damage>0 then ch.name
        when t.action_type='status_tick' and t.damage>0 then ch.name
        when t.action_type='bloodshed_tick' and t.damage>0 then ce.enemy_name
        else null
      end,
      'action_type',t.action_type,
      'action_name',coalesce(
        substring(t.message from '«([^»]+)»'),
        case
          when t.action_type='physical' then 'Физическая атака'
          when t.action_type='magic' then 'Врождённая магия'
          when t.action_type='guard' then 'Защита'
          when t.action_type='bow_fast' then 'Быстрый выстрел'
          when t.action_type='bow_draw' then 'Натяжение тетивы'
          when t.action_type='bow_full_release' then 'Полный выстрел'
          when t.action_type='status_tick' then 'Периодический эффект'
          when t.action_type='bloodshed_tick' then 'Кровопролитие'
          else replace(t.action_type,'_',' ')
        end
      ),
      'damage',greatest(0,coalesce(t.damage,0)),
      'healing',0,
      'message',t.message,
      'created_at',t.created_at
    ) order by ce.room_index,t.id),'[]'::jsonb)
    into result
    from public.combat_turns t
    join public.combat_encounters ce on ce.id=t.encounter_id
    join public.characters ch on ch.id=ce.character_id
    where ce.dungeon_run_id=p_battle_id
      and (
        t.actor in('player','enemy')
        or t.damage>0
      );

  elsif p_kind='party' then
    if not exists(
      select 1 from public.party_dungeon_run_members prm
      where prm.run_id=p_battle_id and prm.character_id=p_character_id
    ) then raise exception 'BATTLE_NOT_FOUND'; end if;

    select coalesce(jsonb_agg(jsonb_build_object(
      'id','party:'||t.id::text,
      'room',ce.room_index,
      'round',t.round,
      'actor_name',case
        when t.actor_type='player' then actor_ch.name
        when t.actor_type='enemy' then ce.enemy_name
        when t.action_type='status_tick' then 'Эффект'
        when t.action_type='bloodshed_tick' then 'Эффект группы'
        else 'Система'
      end,
      'target_name',case
        when target_ch.id is not null then target_ch.name
        when t.actor_type='player' and t.damage>0 then ce.enemy_name
        when t.action_type='bloodshed_tick' and t.damage>0 then ce.enemy_name
        else null
      end,
      'action_type',t.action_type,
      'action_name',coalesce(
        substring(t.message from '«([^»]+)»'),
        case
          when t.action_type='physical' then 'Физическая атака'
          when t.action_type='magic' then 'Врождённая магия'
          when t.action_type='guard' then 'Защита'
          when t.action_type='bow_fast' then 'Быстрый выстрел'
          when t.action_type='bow_draw' then 'Натяжение тетивы'
          when t.action_type='bow_full_release' then 'Полный выстрел'
          when t.action_type='status_tick' then 'Периодический эффект'
          when t.action_type='bloodshed_tick' then 'Кровопролитие'
          else replace(t.action_type,'_',' ')
        end
      ),
      'damage',greatest(0,coalesce(t.damage,0)),
      'healing',0,
      'message',t.message,
      'created_at',t.created_at
    ) order by ce.room_index,t.id),'[]'::jsonb)
    into result
    from public.party_combat_turns t
    join public.party_combat_encounters ce on ce.id=t.encounter_id
    left join public.characters actor_ch on actor_ch.id=t.actor_character_id
    left join public.characters target_ch on target_ch.id=t.target_character_id
    where ce.run_id=p_battle_id
      and (
        t.actor_type in('player','enemy')
        or t.damage>0
      );

  elsif p_kind='pvp' then
    if not exists(
      select 1 from public.pvp_duels pd
      where pd.id=p_battle_id
        and p_character_id in(pd.challenger_character_id,pd.opponent_character_id)
    ) then raise exception 'BATTLE_NOT_FOUND'; end if;

    select coalesce(jsonb_agg(jsonb_build_object(
      'id','pvp:'||t.id::text,
      'room',null,
      'round',t.round,
      'actor_name',coalesce(actor_ch.name,'Система'),
      'target_name',case
        when t.actor_character_id is null then null
        when t.healing>0 and t.damage=0 then actor_ch.name
        when t.damage>0 then target_ch.name
        else null
      end,
      'action_type',t.action_type,
      'action_name',coalesce(
        substring(t.message from '«([^»]+)»'),
        case
          when t.action_type='physical' then 'Физическая атака'
          when t.action_type='magic' then 'Врождённая магия'
          when t.action_type='guard' then 'Защита'
          when t.action_type='bow_fast' then 'Быстрый выстрел'
          when t.action_type='bow_draw' then 'Натяжение тетивы'
          when t.action_type='bow_full_release' then 'Полный выстрел'
          when t.action_type='status_tick' then 'Периодический эффект'
          else replace(t.action_type,'_',' ')
        end
      ),
      'damage',greatest(0,coalesce(t.damage,0)),
      'healing',greatest(0,coalesce(t.healing,0)),
      'message',t.message,
      'created_at',t.created_at
    ) order by t.id),'[]'::jsonb)
    into result
    from public.pvp_duel_turns t
    join public.pvp_duels pd on pd.id=t.duel_id
    left join public.characters actor_ch on actor_ch.id=t.actor_character_id
    left join public.characters target_ch on target_ch.id=case
      when t.actor_character_id=pd.challenger_character_id then pd.opponent_character_id
      when t.actor_character_id=pd.opponent_character_id then pd.challenger_character_id
      else null
    end
    where t.duel_id=p_battle_id
      and (
        t.actor_character_id is not null
        or t.damage>0
        or t.healing>0
      );

  else
    raise exception 'INVALID_BATTLE_KIND';
  end if;

  return result;
end;
$function$
;

revoke all on function public.get_battle_turn_log(uuid,text,uuid) from public,anon;
grant execute on function public.get_battle_turn_log(uuid,text,uuid) to authenticated,service_role;

