create or replace function private.religion_on_settlement_quest_completed()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare q public.settlement_quest_definitions;
begin
  if new.status='completed' and old.status is distinct from 'completed' then
    select * into q from public.settlement_quest_definitions where id=new.quest_definition_id;
    if q.id is not null then
      perform private.record_religion_event(
        new.character_id,'settlement_quest_completed','settlement_quest:'||new.id::text,
        jsonb_build_object('theme',q.theme,'sector_id',q.sector_id,'quest_id',q.id)
      );
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists religion_settlement_quest_completed on public.character_settlement_quests;
create trigger religion_settlement_quest_completed
after update of status on public.character_settlement_quests
for each row execute function private.religion_on_settlement_quest_completed();

create or replace function private.religion_on_sector_discovered()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare content text;
begin
  select content_type into content from public.sector_details where sector_id=new.sector_id;
  perform private.record_religion_event(
    new.character_id,'sector_discovered','sector_discovery:'||new.sector_id::text,
    jsonb_build_object('sector_id',new.sector_id,'content_type',coalesce(content,'unassigned'))
  );
  return new;
end;
$$;

drop trigger if exists religion_sector_discovered on public.character_sector_discoveries;
create trigger religion_sector_discovered
after insert on public.character_sector_discoveries
for each row execute function private.religion_on_sector_discovered();

create or replace function private.religion_on_expedition_completed()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare content text;
begin
  if new.status='completed' and old.status is distinct from 'completed' then
    select content_type into content from public.sector_details where sector_id=new.sector_id;
    if content='wilderness' then
      perform private.record_religion_event(
        new.character_id,'wilderness_expedition_completed','expedition:'||new.id::text,
        jsonb_build_object('sector_id',new.sector_id,'content_type','wilderness')
      );
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists religion_expedition_completed on public.sector_expeditions;
create trigger religion_expedition_completed
after update of status on public.sector_expeditions
for each row execute function private.religion_on_expedition_completed();

create or replace function private.religion_on_spell_learned()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare s public.spell_definitions;
begin
  select * into s from public.spell_definitions where id=new.spell_id;
  perform private.record_religion_event(
    new.character_id,'spell_learned','spell_learned:'||new.spell_id::text,
    jsonb_build_object('spell_id',new.spell_id,'spell_kind',coalesce(s.spell_kind,''),'spell_name',coalesce(s.name,''))
  );
  return new;
end;
$$;

drop trigger if exists religion_spell_learned on public.character_spells;
create trigger religion_spell_learned
after insert on public.character_spells
for each row execute function private.religion_on_spell_learned();

create or replace function private.religion_record_combat_turn(
  p_character_id uuid,p_action_type text,p_source_key text
)
returns void language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare
  spell_slug text;
  spell_kind text;
begin
  if p_character_id is null then return; end if;

  if p_action_type='guard' then
    perform private.record_religion_event(
      p_character_id,'guard_action',p_source_key||':guard','{}'::jsonb
    );
  end if;

  if p_action_type='magic' then
    perform private.record_religion_event(
      p_character_id,'spell_cast',p_source_key||':magic',
      jsonb_build_object('spell_kind','innate_magic')
    );
  elsif p_action_type like 'spell_%' then
    spell_slug:=substring(p_action_type from 7);
    select s.spell_kind into spell_kind
    from public.spell_definitions s where s.slug=spell_slug;

    perform private.record_religion_event(
      p_character_id,'spell_cast',p_source_key||':spell',
      jsonb_build_object('spell_slug',spell_slug,'spell_kind',coalesce(spell_kind,''))
    );

    if spell_kind in ('heal','guard','cleanse','buff','taunt') then
      perform private.record_religion_event(
        p_character_id,'support_action',p_source_key||':support',
        jsonb_build_object('spell_slug',spell_slug,'spell_kind',spell_kind)
      );
    end if;
  end if;
end;
$$;

revoke all on function private.religion_record_combat_turn(uuid,text,text) from public,anon,authenticated;

create or replace function private.religion_on_solo_turn()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare cid uuid;
begin
  if new.actor='player' then
    select character_id into cid from public.combat_encounters where id=new.encounter_id;
    perform private.religion_record_combat_turn(cid,new.action_type,'solo_turn:'||new.id::text);
  end if;
  return new;
end;
$$;

drop trigger if exists religion_solo_turn on public.combat_turns;
create trigger religion_solo_turn
after insert on public.combat_turns
for each row execute function private.religion_on_solo_turn();

create or replace function private.religion_on_party_turn()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,private as $$
begin
  if new.actor_type='player' and new.actor_character_id is not null then
    perform private.religion_record_combat_turn(
      new.actor_character_id,new.action_type,'party_turn:'||new.id::text
    );
  end if;
  return new;
end;
$$;

drop trigger if exists religion_party_turn on public.party_combat_turns;
create trigger religion_party_turn
after insert on public.party_combat_turns
for each row execute function private.religion_on_party_turn();

create or replace function private.religion_on_pvp_turn()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,private as $$
begin
  if new.actor_character_id is not null then
    perform private.religion_record_combat_turn(
      new.actor_character_id,new.action_type,'pvp_turn:'||new.id::text
    );
  end if;
  return new;
end;
$$;

drop trigger if exists religion_pvp_turn on public.pvp_duel_turns;
create trigger religion_pvp_turn
after insert on public.pvp_duel_turns
for each row execute function private.religion_on_pvp_turn();

create or replace function private.religion_on_dungeon_completed()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,private as $$
begin
  if new.status='completed' and old.status is distinct from 'completed' then
    if new.hunting_attempt_id is not null then
      perform private.record_religion_event(
        new.character_id,'hunting_kill','hunting_kill:'||new.hunting_attempt_id::text,
        jsonb_build_object('sector_id',new.sector_id)
      );
    elsif new.event_boss_id is null then
      perform private.record_religion_event(
        new.character_id,'dungeon_completed','dungeon:'||new.id::text,
        jsonb_build_object('sector_id',new.sector_id,'rooms',new.total_rooms)
      );
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists religion_dungeon_completed on public.dungeon_runs;
create trigger religion_dungeon_completed
after update of status on public.dungeon_runs
for each row execute function private.religion_on_dungeon_completed();

create or replace function private.religion_on_party_dungeon_completed()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare member_row record;
begin
  if new.status='completed' and old.status is distinct from 'completed' then
    for member_row in
      select character_id from public.party_dungeon_run_members
      where run_id=new.id and not lost
    loop
      perform private.record_religion_event(
        member_row.character_id,'party_dungeon_completed',
        'party_dungeon:'||new.id::text||':'||member_row.character_id::text,
        jsonb_build_object('sector_id',new.sector_id,'member_count',new.member_count)
      );
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists religion_party_dungeon_completed on public.party_dungeon_runs;
create trigger religion_party_dungeon_completed
after update of status on public.party_dungeon_runs
for each row execute function private.religion_on_party_dungeon_completed();

create or replace function private.religion_on_event_boss_completion()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare start_v integer:=0; i integer;
begin
  if tg_op='UPDATE' then start_v:=coalesce(old.victories,0); end if;
  if new.victories>start_v then
    for i in start_v+1..new.victories loop
      perform private.record_religion_event(
        new.character_id,'event_boss_victory',
        'event_boss:'||new.event_id::text||':victory:'||i::text,
        jsonb_build_object('event_id',new.event_id,'victory_number',i)
      );
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists religion_event_boss_completion on public.event_boss_completions;
create trigger religion_event_boss_completion
after insert or update of victories on public.event_boss_completions
for each row execute function private.religion_on_event_boss_completion();

create or replace function private.religion_on_hunting_started()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,private as $$
begin
  perform private.record_religion_event(
    new.character_id,'hunting_started','hunting_started:'||new.id::text,
    jsonb_build_object('sector_id',new.sector_id,'region_key',new.region_key)
  );
  return new;
end;
$$;

drop trigger if exists religion_hunting_started on private.hunting_attempts;
create trigger religion_hunting_started
after insert on private.hunting_attempts
for each row execute function private.religion_on_hunting_started();
