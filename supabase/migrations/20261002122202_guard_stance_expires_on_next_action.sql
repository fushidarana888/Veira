alter table public.pvp_duel_states
  add column if not exists guard_stance_active boolean not null default false,
  add column if not exists guard_spell_percent integer not null default 0;

alter table public.party_combat_member_states
  add column if not exists guard_stance_active boolean not null default false,
  add column if not exists guard_spell_percent smallint not null default 0;

comment on column public.pvp_duel_states.guard_stance_active is
  'True while ordinary guard stance is waiting for an incoming direct hit. Expires on the character next own action.';
comment on column public.pvp_duel_states.guard_spell_percent is
  'Persistent next-hit protection from a guard spell. Unlike ordinary stance, it survives the caster own later actions.';
comment on column public.party_combat_member_states.guard_stance_active is
  'True while ordinary guard stance is waiting for an incoming direct hit. Expires on the character next own action.';
comment on column public.party_combat_member_states.guard_spell_percent is
  'Persistent next-hit protection from a guard spell. Unlike ordinary stance, it survives the caster own later actions.';

create or replace function private.reset_pvp_guard_layers_on_consume()
returns trigger
language plpgsql
set search_path to 'pg_catalog','public','private'
as $$
begin
  if coalesce(old.guard_reduction_percent,0)>0
     and coalesce(new.guard_reduction_percent,0)=0 then
    new.guard_spell_percent:=0;
    new.guard_stance_active:=false;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_reset_pvp_guard_layers_on_consume on public.pvp_duel_states;
create trigger trg_reset_pvp_guard_layers_on_consume
before update of guard_reduction_percent on public.pvp_duel_states
for each row execute function private.reset_pvp_guard_layers_on_consume();

create or replace function private.sync_pvp_guard_lifecycle()
returns trigger
language plpgsql
set search_path to 'pg_catalog','public','private'
as $$
declare
  v_spell public.spell_definitions%rowtype;
  v_slug text;
  v_guard integer:=0;
  v_boost integer:=0;
begin
  if new.actor_character_id is null then
    return new;
  end if;

  if new.action_type='guard' then
    select coalesce(s.guard_boost_percent,0)
    into v_boost
    from private.get_character_combat_stats(new.actor_character_id) s;

    v_guard:=least(80,55+greatest(0,coalesce(v_boost,0)));

    update public.pvp_duel_states
    set guard_stance_active=true,
        guard_reduction_percent=greatest(coalesce(guard_spell_percent,0),v_guard),
        updated_at=now()
    where duel_id=new.duel_id
      and character_id=new.actor_character_id;

    new.message:=coalesce(new.message,'')
      ||' Стойка действует до первого прямого удара, но не дольше начала следующего собственного действия.';
    return new;
  end if;

  if new.action_type like 'spell_%' then
    v_slug:=substring(new.action_type from 7);

    select *
    into v_spell
    from public.spell_definitions
    where slug=v_slug
      and spell_kind='guard'
      and enabled=true
    limit 1;

    if v_spell.id is not null then
      if v_spell.slug='mirror_barrier' then
        v_guard:=0;
      else
        v_guard:=least(
          85,
          greatest(
            55,
            round(
              private.concentrated_spell_percent_value(
                new.actor_character_id,
                v_spell.id,
                v_spell.support_value
              )
              *(100+private.character_religion_modifier_number(
                new.actor_character_id,
                'shield_spell_bonus'
              ))
              /100.0
            )::integer
          )
        );
      end if;

      update public.pvp_duel_states
      set guard_stance_active=false,
          guard_spell_percent=v_guard,
          guard_reduction_percent=v_guard,
          updated_at=now()
      where duel_id=new.duel_id
        and character_id=new.actor_character_id;

      return new;
    end if;
  end if;

  update public.pvp_duel_states
  set guard_reduction_percent=guard_spell_percent,
      guard_stance_active=false,
      updated_at=now()
  where duel_id=new.duel_id
    and character_id=new.actor_character_id
    and guard_stance_active;

  return new;
end;
$$;

drop trigger if exists trg_sync_pvp_guard_lifecycle on public.pvp_duel_turns;
create trigger trg_sync_pvp_guard_lifecycle
before insert on public.pvp_duel_turns
for each row execute function private.sync_pvp_guard_lifecycle();

create or replace function private.reset_party_guard_layers_on_consume()
returns trigger
language plpgsql
set search_path to 'pg_catalog','public','private'
as $$
begin
  if coalesce(old.guard_percent,0)>0
     and coalesce(new.guard_percent,0)=0 then
    new.guard_spell_percent:=0;
    new.guard_stance_active:=false;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_reset_party_guard_layers_on_consume on public.party_combat_member_states;
create trigger trg_reset_party_guard_layers_on_consume
before update of guard_percent on public.party_combat_member_states
for each row execute function private.reset_party_guard_layers_on_consume();

create or replace function private.sync_party_guard_lifecycle()
returns trigger
language plpgsql
set search_path to 'pg_catalog','public','private'
as $$
declare
  v_spell public.spell_definitions%rowtype;
  v_slug text;
  v_guard integer:=0;
  v_boost integer:=0;
  v_target uuid;
begin
  if new.actor_type<>'player' or new.actor_character_id is null then
    return new;
  end if;

  if new.action_type='guard' then
    select coalesce(s.guard_boost_percent,0)
    into v_boost
    from private.get_character_combat_stats(new.actor_character_id) s;

    v_guard:=least(80,greatest(55,55+coalesce(v_boost,0)));

    update public.party_combat_member_states
    set guard_stance_active=true,
        guard_percent=greatest(coalesce(guard_spell_percent,0),v_guard),
        updated_at=now()
    where encounter_id=new.encounter_id
      and character_id=new.actor_character_id;

    new.message:=coalesce(new.message,'')
      ||' Стойка действует до первого прямого удара, но не дольше начала следующего собственного действия.';
    return new;
  end if;

  if new.action_type like 'spell_%' then
    v_slug:=substring(new.action_type from 7);

    select *
    into v_spell
    from public.spell_definitions
    where slug=v_slug
      and spell_kind='guard'
      and enabled=true
    limit 1;

    if v_spell.id is not null then
      update public.party_combat_member_states
      set guard_percent=guard_spell_percent,
          guard_stance_active=false,
          updated_at=now()
      where encounter_id=new.encounter_id
        and character_id=new.actor_character_id
        and guard_stance_active;

      v_target:=coalesce(new.target_character_id,new.actor_character_id);

      if v_spell.slug='mirror_barrier' then
        v_guard:=0;
      else
        v_guard:=least(
          85,
          greatest(
            55,
            round(
              private.concentrated_spell_percent_value(
                new.actor_character_id,
                v_spell.id,
                v_spell.support_value
              )
              *(100+private.character_religion_modifier_number(
                new.actor_character_id,
                'shield_spell_bonus'
              ))
              /100.0
            )::integer
          )
        );
      end if;

      update public.party_combat_member_states
      set guard_spell_percent=v_guard,
          guard_percent=case
            when guard_stance_active then greatest(guard_percent,v_guard)
            else v_guard
          end,
          updated_at=now()
      where encounter_id=new.encounter_id
        and character_id=v_target;

      return new;
    end if;
  end if;

  update public.party_combat_member_states
  set guard_percent=guard_spell_percent,
      guard_stance_active=false,
      updated_at=now()
  where encounter_id=new.encounter_id
    and character_id=new.actor_character_id
    and guard_stance_active;

  return new;
end;
$$;

drop trigger if exists trg_sync_party_guard_lifecycle on public.party_combat_turns;
create trigger trg_sync_party_guard_lifecycle
before insert on public.party_combat_turns
for each row execute function private.sync_party_guard_lifecycle();
