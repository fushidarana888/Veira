-- Synced from live Supabase migration 20260928161850 (faceless_mask_reflects_first_debuff)


create or replace function private.apply_combat_status_effect(
  p_encounter_id uuid,
  p_target text,
  p_effect_type text,
  p_potency integer,
  p_turns integer,
  p_source text
) returns void
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  v_source_character_id uuid;
  v_target_character_id uuid;
  v_state jsonb:='{}'::jsonb;
  v_reflect_percent integer:=60;
begin
  if p_target not in ('player','enemy') then raise exception 'INVALID_STATUS_TARGET'; end if;
  if p_effect_type not in ('burn','bleed','poison','chill','stun','weaken','vulnerable') then raise exception 'INVALID_STATUS_EFFECT'; end if;
  if p_turns < 1 then return; end if;

  if p_target='enemy' then
    select ce.character_id into v_source_character_id
    from public.combat_encounters ce where ce.id=p_encounter_id;
  else
    select ce.character_id,coalesce(ce.boss_item_state,'{}'::jsonb)
    into v_target_character_id,v_state
    from public.combat_encounters ce where ce.id=p_encounter_id
    for update;

    if v_target_character_id is not null
       and private.race_status_immune(v_target_character_id,p_effect_type)
    then return; end if;

    if v_target_character_id is not null
       and private.character_has_equipped_effect(v_target_character_id,'first_debuff_reflect')
       and coalesce((v_state->>'faceless_mask_used')::boolean,false)=false
    then
      v_reflect_percent:=greatest(1,least(100,
        private.character_equipped_effect_number(v_target_character_id,'first_debuff_reflect','reflected_potency_percent',60)::integer
      ));

      update public.combat_encounters
      set boss_item_state=jsonb_set(coalesce(boss_item_state,'{}'::jsonb),'{faceless_mask_used}','true'::jsonb,true)
      where id=p_encounter_id;

      perform private.apply_combat_status_effect(
        p_encounter_id,'enemy',p_effect_type,
        greatest(0,round(p_potency*v_reflect_percent/100.0)::integer),
        p_turns,'Безликая Маска'
      );
      return;
    end if;

    v_source_character_id:=null;
  end if;

  insert into public.combat_status_effects(
    encounter_id,target,effect_type,potency,remaining_turns,source,source_character_id,updated_at
  )
  values(
    p_encounter_id,p_target,p_effect_type,greatest(0,p_potency),
    least(10,greatest(1,p_turns)),coalesce(p_source,''),v_source_character_id,now()
  )
  on conflict(encounter_id,target,effect_type) do update
  set potency=greatest(public.combat_status_effects.potency,excluded.potency),
      remaining_turns=greatest(public.combat_status_effects.remaining_turns,excluded.remaining_turns),
      source=excluded.source,source_character_id=excluded.source_character_id,updated_at=now();
end;
$$;

create or replace function private.apply_party_combat_status_effect(
  p_encounter_id uuid,
  p_target_type text,
  p_target_character_id uuid,
  p_effect_type text,
  p_potency integer,
  p_turns integer,
  p_source_character_id uuid,
  p_source text
) returns void
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare
  v_state jsonb:='{}'::jsonb;
  v_reflect_percent integer:=60;
begin
  if p_target_type not in ('enemy','member') then raise exception 'INVALID_PARTY_STATUS_TARGET'; end if;
  if p_effect_type not in ('burn','bleed','poison','stun','chill','weaken','vulnerable') then raise exception 'INVALID_PARTY_STATUS_EFFECT'; end if;
  if p_turns<=0 then return; end if;

  if p_target_type='enemy' then
    insert into public.party_combat_status_effects(
      encounter_id,target_type,target_character_id,effect_type,potency,remaining_turns,source_character_id,source
    )
    values(
      p_encounter_id,'enemy',null,p_effect_type,greatest(0,p_potency),
      least(20,p_turns)::smallint,p_source_character_id,coalesce(p_source,'')
    )
    on conflict(encounter_id,effect_type) where target_type='enemy'
    do update
    set potency=greatest(public.party_combat_status_effects.potency,excluded.potency),
        remaining_turns=greatest(public.party_combat_status_effects.remaining_turns,excluded.remaining_turns),
        source_character_id=excluded.source_character_id,source=excluded.source,updated_at=now();
  else
    if p_target_character_id is null then raise exception 'PARTY_STATUS_MEMBER_REQUIRED'; end if;
    if private.race_status_immune(p_target_character_id,p_effect_type) then return; end if;

    select coalesce(ms.boss_item_state,'{}'::jsonb)
    into v_state
    from public.party_combat_member_states ms
    where ms.encounter_id=p_encounter_id and ms.character_id=p_target_character_id
    for update;

    if private.character_has_equipped_effect(p_target_character_id,'first_debuff_reflect')
       and coalesce((v_state->>'faceless_mask_used')::boolean,false)=false
    then
      v_reflect_percent:=greatest(1,least(100,
        private.character_equipped_effect_number(p_target_character_id,'first_debuff_reflect','reflected_potency_percent',60)::integer
      ));

      update public.party_combat_member_states
      set boss_item_state=jsonb_set(coalesce(boss_item_state,'{}'::jsonb),'{faceless_mask_used}','true'::jsonb,true),
          updated_at=now()
      where encounter_id=p_encounter_id and character_id=p_target_character_id;

      perform private.apply_party_combat_status_effect(
        p_encounter_id,'enemy',null,p_effect_type,
        greatest(0,round(p_potency*v_reflect_percent/100.0)::integer),
        p_turns,p_target_character_id,'Безликая Маска'
      );
      return;
    end if;

    insert into public.party_combat_status_effects(
      encounter_id,target_type,target_character_id,effect_type,potency,remaining_turns,source_character_id,source
    )
    values(
      p_encounter_id,'member',p_target_character_id,p_effect_type,greatest(0,p_potency),
      least(20,p_turns)::smallint,p_source_character_id,coalesce(p_source,'')
    )
    on conflict(encounter_id,target_character_id,effect_type) where target_type='member'
    do update
    set potency=greatest(public.party_combat_status_effects.potency,excluded.potency),
        remaining_turns=greatest(public.party_combat_status_effects.remaining_turns,excluded.remaining_turns),
        source_character_id=excluded.source_character_id,source=excluded.source,updated_at=now();
  end if;
end;
$$;

