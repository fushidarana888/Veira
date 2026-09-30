create or replace function private.concentrated_spell_direct_value(
  p_character_id uuid,
  p_spell_id uuid,
  p_base_value integer
)
returns integer
language sql
stable
set search_path to ''
as $function$
  select greatest(
    0,
    case
      when private.character_spell_concentration_active(p_character_id,p_spell_id)
        then round(
          greatest(0,coalesce(p_base_value,0))
          * case
              when exists(
                select 1
                from public.spell_definitions s
                where s.id=p_spell_id
                  and s.spell_kind='damage'
              )
              then 1.15
              else 1.30
            end
        )::integer
      else greatest(0,coalesce(p_base_value,0))
    end
  )
$function$;
