-- Synced from live Supabase migration 20260927220714 (record_rare_exploration_discoveries)

CREATE OR REPLACE FUNCTION private.complete_expired_sector_expeditions(p_character_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  exp record;
  ev public.sector_event_definitions;
  sd public.sector_details;
  encounter public.exploration_event_templates;
  completed_count integer := 0;
  event_roll integer;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.characters c
    where c.id = p_character_id
      and (
        c.owner_user_id = auth.uid()
        or private.is_gm(auth.uid())
      )
  ) then
    raise exception 'CHARACTER_NOT_OWNED';
  end if;

  for exp in
    select e.*
    from public.sector_expeditions e
    where e.character_id = p_character_id
      and e.status = 'active'
      and e.ends_at <= now()
    order by e.started_at
    for update
  loop
    ev := null;
    sd := null;
    encounter := null;

    select *
      into sd
    from public.sector_details
    where sector_id = exp.sector_id;

    select *
      into ev
    from public.sector_event_definitions sed
    where sed.sector_id = exp.sector_id
      and sed.enabled = true
    limit 1;

    if ev.id is not null then
      update public.sector_expeditions
      set status = 'awaiting_event'
      where id = exp.id;

      insert into public.expedition_event_instances (
        expedition_id,
        event_definition_id,
        encounter_template_id,
        source_kind,
        character_id,
        sector_id,
        title,
        player_prompt,
        gm_notes
      )
      values (
        exp.id,
        ev.id,
        null,
        'sector',
        exp.character_id,
        exp.sector_id,
        coalesce(nullif(ev.title,''), 'Неожиданное событие'),
        ev.player_prompt,
        ev.gm_notes
      )
      on conflict (expedition_id) do nothing;

      continue;
    end if;

    select t.*
      into encounter
    from public.exploration_event_templates t
    where t.enabled = true
      and (t.terrain_type is null or t.terrain_type = coalesce(sd.terrain_type, 'unassigned'))
      and (t.content_type is null or t.content_type = coalesce(sd.content_type, 'unassigned'))
      and coalesce(sd.danger_level, 0) between t.min_danger and t.max_danger
    order by (-ln(greatest(random(), 0.000001)) / greatest(t.weight, 1))
    limit 1;

    if encounter.id is not null then
      event_roll := floor(random() * 100)::integer + 1;

      if event_roll <= encounter.chance_percent then
        if encounter.requires_gm then
          update public.sector_expeditions
          set status = 'awaiting_event'
          where id = exp.id;

          insert into public.expedition_event_instances (
            expedition_id,
            event_definition_id,
            encounter_template_id,
            source_kind,
            character_id,
            sector_id,
            title,
            player_prompt,
            gm_notes
          )
          values (
            exp.id,
            null,
            encounter.id,
            'random',
            exp.character_id,
            exp.sector_id,
            encounter.title,
            encounter.player_prompt,
            encounter.gm_notes
          )
          on conflict (expedition_id) do nothing;

          continue;
        else
          update public.sector_expeditions
          set status = 'completed',
              completed_at = now()
          where id = exp.id;

          insert into public.character_sector_discoveries (
            character_id,
            sector_id,
            source
          )
          values (
            exp.character_id,
            exp.sector_id,
            'exploration_event'
          )
          on conflict do nothing;

          insert into public.expedition_results (
            expedition_id,
            character_id,
            sector_id,
            source,
            result_type,
            title,
            summary,
            outcome,
            encounter_template_id
          )
          values (
            exp.id,
            exp.character_id,
            exp.sector_id,
            'random_event',
            coalesce(sd.content_type, 'unassigned'),
            encounter.title,
            coalesce(nullif(encounter.automatic_result,''), nullif(encounter.player_prompt,''), 'Во время экспедиции произошло событие.'),
            'discovered',
            encounter.id
          )
          on conflict (expedition_id) do nothing;

          perform private.record_discovery(
            exp.character_id,
            'world_event',
            encounter.id::text,
            encounter.title,
            coalesce(nullif(encounter.automatic_result,''), nullif(encounter.player_prompt,''), 'Во время экспедиции произошло событие.'),
            jsonb_build_object('sector_id',exp.sector_id,'terrain',sd.terrain_type)
          );

          completed_count := completed_count + 1;
          continue;
        end if;
      end if;
    end if;

    update public.sector_expeditions
    set status = 'completed',
        completed_at = now()
    where id = exp.id;

    insert into public.character_sector_discoveries (
      character_id,
      sector_id,
      source
    )
    values (
      exp.character_id,
      exp.sector_id,
      'exploration'
    )
    on conflict do nothing;

    perform private.default_expedition_result(
      exp.id,
      exp.character_id,
      exp.sector_id
    );

    completed_count := completed_count + 1;
  end loop;

  return completed_count;
end;
$function$;
