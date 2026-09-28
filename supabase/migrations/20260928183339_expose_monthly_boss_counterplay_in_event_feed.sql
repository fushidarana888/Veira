-- Synced from live Supabase migration 20260928183339 (expose_monthly_boss_counterplay_in_event_feed)


drop function if exists public.get_event_bosses(uuid);

create function public.get_event_bosses(p_character_id uuid)
returns table(
  event_id uuid, slug text, boss_kind text, name text, description text,
  starts_at timestamptz, ends_at timestamptz, recommended_level integer,
  enemy_level integer, enemy_hp integer, enemy_attack integer, enemy_defense integer,
  enemy_damage_type text, enemy_resistances jsonb, special_name text, special_every_n integer,
  phase2_hp_percent integer, phase2_name text, mechanics jsonb,
  special_reward_name text, special_reward_description text,
  reward_material_name text, reward_material_quantity integer, featured_loot jsonb,
  first_reward_gold integer, first_reward_experience integer,
  repeat_reward_gold integer, repeat_reward_experience integer,
  victories integer, special_reward_claimed boolean,
  solo_run_id uuid, solo_run_status text, solo_encounter_id uuid, solo_encounter_status text,
  party_id uuid, party_member_count integer, is_party_leader boolean,
  party_run_id uuid, party_run_status text, party_encounter_id uuid, party_encounter_status text,
  character_busy boolean
)
language plpgsql
security definer
set search_path='pg_catalog','public','private'
as $$
declare caller uuid:=auth.uid();
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  return query
  with party_info as (
    select p.id,p.leader_character_id,count(pm2.character_id)::integer member_count
    from public.parties p
    join public.party_members pm on pm.party_id=p.id and pm.character_id=p_character_id
    join public.party_members pm2 on pm2.party_id=p.id
    where p.status='active'
    group by p.id,p.leader_character_id
    limit 1
  )
  select
    e.id,e.slug,e.boss_kind,e.name,e.description,e.starts_at,e.ends_at,e.recommended_level,
    e.solo_enemy_level,e.solo_hp,e.solo_attack,e.solo_defense,
    et.attack_damage_type,et.damage_resistances,et.special_name,e.special_every_n::integer,
    e.phase2_hp_percent::integer,et.phase2_name,e.mechanics,
    reward.name,reward.description,
    material.name,e.reward_material_quantity::integer,
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'slug',x->>'slug',
          'chance_percent',coalesce((x->>'chance_percent')::numeric,0),
          'craft_cost',coalesce((x->>'craft_cost')::integer,0),
          'name',i.name,
          'description',i.description,
          'rarity',i.rarity::text,
          'required_level',i.required_level,
          'unique_property_name',i.unique_property_name,
          'unique_property_description',i.unique_property_description
        )
        order by i.name
      )
      from jsonb_array_elements(coalesce(e.featured_loot,'[]'::jsonb)) x
      join public.item_definitions i on i.slug=x->>'slug'
    ),'[]'::jsonb),
    e.first_reward_gold,e.first_reward_experience,e.repeat_reward_gold,e.repeat_reward_experience,
    coalesce(comp.victories,0),coalesce(comp.special_reward_claimed,false),
    solo.id,solo.status,solo_ce.id,solo_ce.status,
    pi.id,coalesce(pi.member_count,0),coalesce(pi.leader_character_id=p_character_id,false),
    party_run.id,party_run.status,party_ce.id,party_ce.status,
    private.character_blocked_for_event_boss(p_character_id)
  from public.event_boss_events e
  join public.enemy_templates et on et.id=e.enemy_template_id
  left join public.item_definitions reward on reward.id=e.special_reward_item_id
  left join public.item_definitions material on material.id=e.reward_material_item_id
  left join public.event_boss_completions comp on comp.event_id=e.id and comp.character_id=p_character_id
  left join lateral(
    select dr.* from public.dungeon_runs dr
    where dr.character_id=p_character_id and dr.event_boss_id=e.id
    order by (dr.status='active') desc,dr.created_at desc limit 1
  ) solo on true
  left join lateral(
    select ce.* from public.combat_encounters ce
    where ce.dungeon_run_id=solo.id order by ce.created_at desc limit 1
  ) solo_ce on true
  left join party_info pi on true
  left join lateral(
    select pdr.* from public.party_dungeon_runs pdr
    join public.party_dungeon_run_members prm on prm.run_id=pdr.id
    where prm.character_id=p_character_id and pdr.event_boss_id=e.id
    order by (pdr.status='active') desc,pdr.created_at desc limit 1
  ) party_run on true
  left join lateral(
    select pce.* from public.party_combat_encounters pce
    where pce.run_id=party_run.id order by pce.created_at desc limit 1
  ) party_ce on true
  where e.enabled=true
    and e.boss_kind in ('weekly','monthly')
    and now()>=e.starts_at and now()<e.ends_at
  order by e.boss_kind,e.ends_at,e.name;
end;
$$;

revoke execute on function public.get_event_bosses(uuid) from anon,public;
grant execute on function public.get_event_bosses(uuid) to authenticated;

