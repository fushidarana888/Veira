-- Synced from live Supabase migration 20260927220914 (character_trophy_case_rpc)


create or replace function public.get_character_trophy_case(
  p_character_id uuid
) returns table(
  slug text,
  name text,
  description text,
  quantity integer
)
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;

  if not private.is_gm(auth.uid())
     and not exists(
       select 1 from public.characters c
       where c.id=p_character_id and c.owner_user_id=auth.uid()
     )
  then raise exception 'CHARACTER_NOT_OWNED'; end if;

  return query
  select
    d.slug,
    d.name,
    d.description,
    sum(ci.quantity)::integer
  from public.character_items ci
  join public.item_definitions d on d.id=ci.item_definition_id
  where ci.character_id=p_character_id
    and ci.death_spirit_id is null
    and d.slug like 'trophy_%'
  group by d.slug,d.name,d.description
  order by d.name;
end;
$$;

