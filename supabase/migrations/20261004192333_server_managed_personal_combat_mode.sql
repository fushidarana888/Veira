create table if not exists private.client_runtime_sessions (
  character_id uuid not null references public.characters(id) on delete cascade,
  scope text not null check (scope in ('duel','party')),
  scope_id uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_action_at timestamptz,
  last_error text,
  last_error_at timestamptz,
  error_count smallint not null default 0,
  primary key(character_id,scope,scope_id)
);

alter table private.client_runtime_sessions enable row level security;

create index if not exists client_runtime_sessions_scope_idx
  on private.client_runtime_sessions(scope,scope_id);

CREATE OR REPLACE FUNCTION public.get_client_runtime_state(p_character_id uuid, p_scope text, p_scope_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
  available_value boolean:=false;
  enabled_value boolean:=false;
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  select exists(
    select 1
    from private.client_runtime_flags f
    where f.character_id=p_character_id
      and f.flag_key='turn_mode_v1'
      and f.enabled
  ) into available_value;

  if not available_value then
    return jsonb_build_object(
      'available',false,
      'enabled',false,
      'server_managed',false
    );
  end if;

  if p_scope not in ('duel','party') then
    return jsonb_build_object(
      'available',true,
      'enabled',false,
      'server_managed',true
    );
  end if;

  select exists(
    select 1 from private.client_runtime_sessions s
    where s.character_id=p_character_id
      and s.scope=p_scope
      and s.scope_id=p_scope_id
  ) into enabled_value;

  return jsonb_build_object(
    'available',true,
    'enabled',enabled_value,
    'server_managed',true
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_client_runtime_state(p_character_id uuid, p_scope text, p_scope_id uuid, p_enabled boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  caller uuid:=auth.uid();
begin
  if caller is null then raise exception 'AUTH_REQUIRED'; end if;

  if not exists(
    select 1 from public.characters c
    where c.id=p_character_id and c.owner_user_id=caller
  ) then raise exception 'CHARACTER_NOT_OWNED'; end if;

  if not exists(
    select 1
    from private.client_runtime_flags f
    where f.character_id=p_character_id
      and f.flag_key='turn_mode_v1'
      and f.enabled
  ) then
    return jsonb_build_object(
      'available',false,
      'enabled',false,
      'server_managed',false
    );
  end if;

  if p_scope not in ('duel','party') then
    raise exception 'INVALID_RUNTIME_SCOPE';
  end if;

  if p_scope='duel' then
    if not exists(
      select 1
      from public.pvp_duels d
      where d.id=p_scope_id
        and d.status='active'
        and p_character_id in (d.challenger_character_id,d.opponent_character_id)
    ) then raise exception 'RUNTIME_SCOPE_NOT_ACTIVE'; end if;
  else
    if not exists(
      select 1
      from public.party_dungeon_runs r
      join public.party_dungeon_run_members m on m.run_id=r.id
      where r.id=p_scope_id
        and r.status='active'
        and m.character_id=p_character_id
    ) then raise exception 'RUNTIME_SCOPE_NOT_ACTIVE'; end if;
  end if;

  if p_enabled then
    delete from private.client_runtime_sessions
    where character_id=p_character_id
      and scope=p_scope
      and scope_id<>p_scope_id;

    insert into private.client_runtime_sessions(
      character_id,scope,scope_id,updated_at,error_count,last_error,last_error_at
    )
    values(
      p_character_id,p_scope,p_scope_id,now(),0,null,null
    )
    on conflict(character_id,scope,scope_id) do update
    set updated_at=now(),
        error_count=0,
        last_error=null,
        last_error_at=null;
  else
    delete from private.client_runtime_sessions
    where character_id=p_character_id
      and scope=p_scope
      and scope_id=p_scope_id;
  end if;

  return jsonb_build_object(
    'available',true,
    'enabled',p_enabled,
    'server_managed',true
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.process_client_runtime_sessions()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  rec record;
  owner_id uuid;
  encounter_id uuid;
  processed integer:=0;
  acted integer:=0;
  failures integer:=0;
  err text;
begin
  if not pg_try_advisory_xact_lock(hashtextextended('veira_client_runtime_worker',0)) then
    return jsonb_build_object('locked',true,'processed',0,'acted',0,'failures',0);
  end if;

  delete from private.client_runtime_sessions s
  where not exists(
    select 1 from private.client_runtime_flags f
    where f.character_id=s.character_id
      and f.flag_key='turn_mode_v1'
      and f.enabled
  );

  for rec in
    select s.character_id,s.scope,s.scope_id,s.error_count,c.owner_user_id
    from private.client_runtime_sessions s
    join public.characters c on c.id=s.character_id
    order by s.created_at
  loop
    processed:=processed+1;
    owner_id:=rec.owner_user_id;

    begin
      perform set_config('request.jwt.claim.sub',owner_id::text,true);

      if rec.scope='duel' then
        if not exists(
          select 1 from public.pvp_duels d
          where d.id=rec.scope_id
            and d.status='active'
            and rec.character_id in (d.challenger_character_id,d.opponent_character_id)
        ) then
          delete from private.client_runtime_sessions
          where character_id=rec.character_id
            and scope=rec.scope
            and scope_id=rec.scope_id;
          continue;
        end if;

        if exists(
          select 1 from public.pvp_duels d
          where d.id=rec.scope_id
            and d.current_turn_character_id=rec.character_id
        ) then
          perform public.sync_client_duel_turn(rec.character_id,rec.scope_id);
          update private.client_runtime_sessions
          set last_action_at=now(),
              updated_at=now(),
              error_count=0,
              last_error=null,
              last_error_at=null
          where character_id=rec.character_id
            and scope=rec.scope
            and scope_id=rec.scope_id;
          acted:=acted+1;
        end if;

      elsif rec.scope='party' then
        if not exists(
          select 1
          from public.party_dungeon_runs r
          join public.party_dungeon_run_members m on m.run_id=r.id
          where r.id=rec.scope_id
            and r.status='active'
            and m.character_id=rec.character_id
        ) then
          delete from private.client_runtime_sessions
          where character_id=rec.character_id
            and scope=rec.scope
            and scope_id=rec.scope_id;
          continue;
        end if;

        select ce.id
        into encounter_id
        from public.party_combat_encounters ce
        where ce.run_id=rec.scope_id
          and ce.status='active'
        order by ce.created_at desc
        limit 1;

        if encounter_id is not null
           and private.party_next_actor_id(encounter_id)=rec.character_id
        then
          perform public.sync_client_party_turn(rec.character_id,encounter_id);
          update private.client_runtime_sessions
          set last_action_at=now(),
              updated_at=now(),
              error_count=0,
              last_error=null,
              last_error_at=null
          where character_id=rec.character_id
            and scope=rec.scope
            and scope_id=rec.scope_id;
          acted:=acted+1;
        end if;
      end if;

    exception when others then
      err:=sqlerrm;

      if err like '%NOT_YOUR_TURN%'
         or err like '%PARTY_NOT_YOUR_TURN%'
         or err like '%DUEL_NOT_ACTIVE%'
         or err like '%PARTY_COMBAT_NOT_ACTIVE%'
      then
        null;
      else
        failures:=failures+1;
        update private.client_runtime_sessions
        set error_count=least(32767,error_count+1),
            last_error=left(err,500),
            last_error_at=now(),
            updated_at=now()
        where character_id=rec.character_id
          and scope=rec.scope
          and scope_id=rec.scope_id;

        if rec.error_count+1>=5 then
          delete from private.client_runtime_sessions
          where character_id=rec.character_id
            and scope=rec.scope
            and scope_id=rec.scope_id;
        end if;
      end if;
    end;
  end loop;

  return jsonb_build_object(
    'locked',false,
    'processed',processed,
    'acted',acted,
    'failures',failures
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION private.resolve_client_duel_turn(p_character_id uuid, p_duel_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  cid uuid:=p_character_id;
  d public.pvp_duels%rowtype;
  a public.pvp_duel_states%rowtype;
  t public.pvp_duel_states%rowtype;
  hp_percent integer:=100;
  reserve integer:=0;
  physical_score integer:=0;
  magic_score integer:=0;
  target_physical integer:=0;
  target_magic integer:=0;
  target_threat integer:=0;
  resistance integer:=0;
  heal_spell record;
  guard_spell record;
  vuln_spell record;
  damage_spell record;
  damage_spell_score integer:=0;
  free_score integer:=0;
  mana_cost integer:=0;
  settings public.character_autobattle_settings;
  self_reduction integer:=0;
  target_vulnerable integer:=0;
  self_severity integer:=0;
  cleanse_spell record;
begin
  select * into d from public.pvp_duels where id=p_duel_id;
  if d.id is null or d.status<>'active' then raise exception 'DUEL_NOT_ACTIVE'; end if;
  if d.current_turn_character_id<>cid then raise exception 'NOT_YOUR_TURN'; end if;

  select * into a from public.pvp_duel_states where duel_id=p_duel_id and character_id=cid;
  select * into t from public.pvp_duel_states
  where duel_id=p_duel_id and character_id<>cid
  limit 1;

  if a.character_id is null or t.character_id is null then raise exception 'DUEL_NOT_FOUND'; end if;

  settings:=private.ensure_character_autobattle_settings(cid);
  hp_percent:=floor(a.hp_current*100.0/greatest(1,a.hp_max))::integer;
  reserve:=floor(a.mana_max*greatest(0,coalesce(settings.mana_reserve_percent,20))/100.0)::integer;

  if a.bow_draw_pending then
    return jsonb_build_object('action','physical','label','Выпустить подготовленный выстрел');
  end if;

  physical_score:=greatest(
    1,
    private.damage_after_armor(a.physical_power,greatest(0,t.physical_defense))
  );
  resistance:=private.damage_resistance_percent(t.damage_resistances,a.weapon_damage_type);
  physical_score:=greatest(1,round(
    physical_score
    *(100+a.all_damage_bonus_percent+a.physical_damage_bonus_percent
      +private.character_damage_bonus(cid,a.weapon_damage_type))/100.0
    *(100-resistance)/100.0
  )::integer);
  if t.hp_current*100<=greatest(1,t.hp_max)*30 then
    physical_score:=greatest(1,round(
      physical_score*(100+a.damage_vs_wounded_percent)/100.0
      *(100-t.low_hp_damage_reduction_percent)/100.0
    )::integer);
  end if;
  physical_score:=greatest(1,round(
    physical_score*private.character_expected_critical_multiplier(cid,'physical')
  )::integer);

  magic_score:=greatest(
    1,
    private.damage_after_armor(a.magic_power,greatest(0,t.magic_defense))
  );
  resistance:=private.damage_resistance_percent(t.damage_resistances,a.magic_damage_type);
  magic_score:=greatest(1,round(
    magic_score
    *(100+a.all_damage_bonus_percent+a.magic_damage_bonus_percent
      +private.character_damage_bonus(cid,a.magic_damage_type))/100.0
    *(100-resistance)/100.0
  )::integer);
  magic_score:=greatest(1,round(
    magic_score*private.character_expected_critical_multiplier(cid,'magic')
  )::integer);

  target_physical:=greatest(
    1,
    private.damage_after_armor(t.physical_power,greatest(0,a.physical_defense))
  );
  resistance:=private.damage_resistance_percent(a.damage_resistances,t.weapon_damage_type);
  target_physical:=greatest(1,round(
    target_physical
    *(100+t.all_damage_bonus_percent+t.physical_damage_bonus_percent)/100.0
    *(100-resistance)/100.0
  )::integer);

  target_magic:=greatest(
    1,
    private.damage_after_armor(t.magic_power,greatest(0,a.magic_defense))
  );
  resistance:=private.damage_resistance_percent(a.damage_resistances,t.magic_damage_type);
  target_magic:=greatest(1,round(
    target_magic
    *(100+t.all_damage_bonus_percent+t.magic_damage_bonus_percent)/100.0
    *(100-resistance)/100.0
  )::integer);
  target_threat:=greatest(target_physical,target_magic);

  select least(60,coalesce(sum(potency),0))::integer
  into self_reduction
  from public.pvp_duel_status_effects
  where duel_id=p_duel_id
    and target_character_id=cid
    and remaining_turns>0
    and effect_type in ('chill','weaken');

  if self_reduction>0 then
    physical_score:=greatest(1,round(physical_score*(100-self_reduction)/100.0)::integer);
    magic_score:=greatest(1,round(magic_score*(100-self_reduction)/100.0)::integer);
  end if;

  select least(75,coalesce(sum(potency),0))::integer
  into target_vulnerable
  from public.pvp_duel_status_effects
  where duel_id=p_duel_id
    and target_character_id=t.character_id
    and remaining_turns>0
    and effect_type='vulnerable';

  if target_vulnerable>0 then
    physical_score:=greatest(1,round(physical_score*(100+target_vulnerable)/100.0)::integer);
    magic_score:=greatest(1,round(magic_score*(100+target_vulnerable)/100.0)::integer);
  end if;

  free_score:=greatest(physical_score,magic_score);

  -- Never spend a defensive turn when a free action is already a credible finish.
  if t.hp_current<=physical_score and physical_score>=magic_score then
    return jsonb_build_object('action','physical','label','Физическая атака','reason','lethal_free_hit');
  elsif t.hp_current<=magic_score then
    return jsonb_build_object('action','magic','label','Врождённая магия','reason','lethal_free_hit');
  end if;

  -- In a near-kill window, mana is worth less than tempo.
  if t.hp_current<=ceil(free_score*1.50)::integer then
    reserve:=0;
  end if;

  -- An already prepared counter should be cashed out immediately.
  if coalesce(a.counter_blocked_damage,0)>0 then
    return jsonb_build_object(
      'action','physical','label','Контратака',
      'reason','prepared_counter'
    );
  end if;

  -- Do not feed a valuable physical hit into a stance or a strong stored shield.
  -- Innate magic is free, so it is the preferred shield-breaker for a physical build.
  if (
       coalesce(t.guard_stance_active,false)
       or coalesce(t.guard_spell_percent,0)>=50
     )
     and physical_score>=ceil(magic_score*1.35)::integer
  then
    return jsonb_build_object(
      'action','magic','label','Врождённая магия','reason','break_protection_cheaply'
    );
  end if;

  select coalesce(sum(case effect_type
    when 'stun' then 5
    when 'vulnerable' then 4
    when 'weaken' then 3
    when 'chill' then 3
    when 'poison' then 2
    when 'burn' then 2
    when 'bleed' then 2
    else 1 end),0)::integer
  into self_severity
  from public.pvp_duel_status_effects
  where duel_id=p_duel_id
    and target_character_id=cid
    and remaining_turns>0;

  if self_severity>=5
     and t.hp_current>free_score
     and a.initiative_meter<80
  then
    select sd.*,
           private.character_effective_spell_mana_cost(cid,sd.id) as effective_cost
    into cleanse_spell
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=cid
      and sd.enabled
      and sd.spell_kind='cleanse'
      and private.character_effective_spell_mana_cost(cid,sd.id)<=a.mana_current
    order by private.character_effective_spell_mana_cost(cid,sd.id)
    limit 1;

    if cleanse_spell.id is not null
       and a.mana_current-cleanse_spell.effective_cost>=reserve
    then
      return jsonb_build_object(
        'action','spell','spell_id',cleanse_spell.id,
        'label',cleanse_spell.name,'reason','dangerous_debuffs'
      );
    end if;
  end if;

  -- Heal according to actual incoming threat, not a fixed HP threshold.
  if hp_percent<=greatest(
       38,
       least(62,ceil(target_threat*100.0/greatest(1,a.hp_max))::integer+12)
     )
     and t.hp_current>free_score
     and (a.initiative_meter<80 or target_threat>=a.hp_current)
  then
    select sd.*,
           private.character_effective_spell_mana_cost(cid,sd.id) as effective_cost
    into heal_spell
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=cid
      and sd.enabled
      and sd.spell_kind='heal'
      and private.character_effective_spell_mana_cost(cid,sd.id)<=a.mana_current
    order by private.autobattle_heal_score(
      cid,sd.id,a.magic_power,greatest(0,a.hp_max-a.hp_current),hp_percent
    ) desc
    limit 1;

    if heal_spell.id is not null
       and (
         a.mana_current-heal_spell.effective_cost>=reserve
         or target_threat>=a.hp_current
       )
    then
      return jsonb_build_object(
        'action','spell','spell_id',heal_spell.id,
        'label',heal_spell.name,'reason','low_hp'
      );
    end if;
  end if;

  -- Magical shield if a bad exchange is coming. It may survive our later turn,
  -- unlike ordinary stance.
  if coalesce(a.guard_spell_percent,0)<=0
     and coalesce(a.reflect_percent,0)<=0
     and t.hp_current>free_score
     and (
       target_threat>=ceil(a.hp_current*0.38)::integer
       or hp_percent<=55
     )
     and (a.initiative_meter<80 or target_threat>=a.hp_current)
  then
    select sd.*,
           private.character_effective_spell_mana_cost(cid,sd.id) as effective_cost
    into guard_spell
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=cid
      and sd.enabled
      and sd.spell_kind='guard'
      and private.character_effective_spell_mana_cost(cid,sd.id)<=a.mana_current
    order by
      case when sd.slug='mirror_barrier' and target_threat>=ceil(a.hp_current*0.45)::integer then 0 else 1 end,
      private.concentrated_spell_percent_value(cid,sd.id,sd.support_value) desc,
      private.character_effective_spell_mana_cost(cid,sd.id)
    limit 1;

    if guard_spell.id is not null
       and a.mana_current-guard_spell.effective_cost>=reserve
    then
      return jsonb_build_object(
        'action','spell','spell_id',guard_spell.id,
        'label',guard_spell.name,'reason','dangerous_exchange'
      );
    end if;
  end if;

  -- Ordinary guard is a last-resort tempo action.
  if hp_percent<=34
     and not coalesce(a.guard_stance_active,false)
     and t.hp_current>free_score
     and (a.initiative_meter<80 or target_threat>=a.hp_current)
  then
    return jsonb_build_object('action','guard','label','Защитная стойка','reason','critical_hp');
  end if;

  -- Consider equipped damage spells, but require them to beat the free attack
  -- by a useful margin. This prevents Rune of Exposure from being spammed.
  select q.*
  into damage_spell
  from (
    select
      sd.id,sd.name,
      private.character_effective_spell_mana_cost(cid,sd.id) as effective_cost,
      greatest(1,round(
        greatest(
          1,
          private.damage_after_armor(
            round(a.magic_power*sd.power_multiplier)::integer+sd.flat_power,
            greatest(0,t.magic_defense)*0.85
          )
        )
        *(100+a.all_damage_bonus_percent+a.magic_damage_bonus_percent
          +private.character_damage_bonus(cid,sd.damage_type)
          +private.character_spell_family_damage_bonus_percent(cid,sd.id))/100.0
        *(100-private.damage_resistance_percent(t.damage_resistances,sd.damage_type))/100.0
        *private.character_expected_critical_multiplier(cid,'magic')
      )::integer)
      +case
        when sd.status_effect_type='stun'
          then round(target_threat*sd.status_effect_chance/100.0)::integer
        when sd.status_effect_type='vulnerable' and target_vulnerable<=0
          then round(
            free_score
            *sd.status_effect_potency/100.0
            *greatest(1,least(2,sd.status_effect_turns))
            *sd.status_effect_chance/100.0
          )::integer
        when sd.status_effect_type in ('weaken','chill')
          then round(
            target_threat
            *sd.status_effect_potency/100.0
            *greatest(1,least(2,sd.status_effect_turns))
            *sd.status_effect_chance/100.0
          )::integer
        else 0
      end as score
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=cid
      and sd.enabled
      and sd.spell_kind='damage'
      and private.character_effective_spell_mana_cost(cid,sd.id)<=a.mana_current
  ) q
  where a.mana_current-q.effective_cost>=reserve
  order by q.score desc,q.effective_cost
  limit 1;

  if damage_spell.id is not null
     and damage_spell.score>=ceil(free_score*1.18)::integer
  then
    return jsonb_build_object(
      'action','spell','spell_id',damage_spell.id,
      'label',damage_spell.name,'reason','best_damage_line'
    );
  end if;

  if physical_score>=magic_score then
    if private.character_weapon_family(cid)='long_bow'
       and not a.bow_draw_pending
       and hp_percent>40
       and target_threat<a.hp_current
    then
      return jsonb_build_object('action','bow_draw','label','Полный натяг','reason','long_bow');
    end if;
    return jsonb_build_object('action','physical','label','Физическая атака','reason','best_free_hit');
  end if;

  return jsonb_build_object('action','magic','label','Врождённая магия','reason','best_free_hit');
end;
$function$
;

CREATE OR REPLACE FUNCTION private.resolve_client_party_turn(p_character_id uuid, p_encounter_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  cid uuid:=p_character_id;
  ce public.party_combat_encounters%rowtype;
  ms public.party_combat_member_states%rowtype;
  st record;
  settings public.character_autobattle_settings;
  hp_percent integer:=100;
  reserve integer:=0;
  allow_physical boolean:=true;
  allow_magic boolean:=false;
  allow_spells boolean:=false;
  support_enabled boolean:=false;
  heal_threshold integer:=0;
  cleanse_min integer:=0;
  shield_special boolean:=false;
  buff_enabled boolean:=false;
  guard_mode text:='never';
  guard_hp integer:=0;
  guard_every integer:=0;
  guard_due boolean:=false;
  severity integer:=0;
  physical_score integer:=-1;
  magic_score integer:=-1;
  free_score integer:=1;
  resistance integer:=0;
  heal_spell record;
  cleanse_spell record;
  guard_spell record;
  buff_spell record;
  damage_spell record;
  family text;
  support_target_id uuid;
  support_target_hp_current integer:=0;
  support_target_hp_max integer:=1;
  support_target_hp_percent integer:=100;
  support_target_downed boolean:=false;
  support_target_guard integer:=0;
  support_target_reflect integer:=0;
  cleanse_target_id uuid;
  cleanse_target_severity integer:=0;
begin
  select * into ce from public.party_combat_encounters where id=p_encounter_id;
  if ce.id is null or ce.status<>'active' then raise exception 'PARTY_COMBAT_NOT_ACTIVE'; end if;
  if private.party_next_actor_id(p_encounter_id)<>cid then raise exception 'PARTY_NOT_YOUR_TURN'; end if;

  select * into ms
  from public.party_combat_member_states
  where encounter_id=p_encounter_id and character_id=cid;

  if ms.character_id is null or ms.downed then raise exception 'PARTY_MEMBER_DOWNED'; end if;

  if exists(
    select 1
    from public.party_combat_status_effects
    where encounter_id=p_encounter_id
      and target_type='member'
      and target_character_id=cid
      and effect_type='stun'
      and remaining_turns>0
  ) then
    return jsonb_build_object('action','skip','label','Пропуск хода · оглушение');
  end if;

  if ms.bow_draw_pending then
    return jsonb_build_object('action','physical','label','Выпустить подготовленный выстрел');
  end if;

  select * into st from private.get_character_combat_stats(cid);
  settings:=private.ensure_character_autobattle_settings(cid);
  family:=private.character_weapon_family(cid);

  hp_percent:=floor(ms.hp_current*100.0/greatest(1,ms.hp_max))::integer;
  reserve:=floor(ms.mana_max*greatest(0,coalesce(settings.mana_reserve_percent,20))/100.0)::integer;

  if ce.is_boss then
    allow_physical:=settings.boss_allow_physical;
    allow_magic:=settings.boss_allow_magic;
    allow_spells:=settings.boss_allow_spells and settings.use_learned_spells;
    support_enabled:=settings.boss_support_enabled;
    heal_threshold:=settings.boss_heal_hp_percent;
    cleanse_min:=settings.boss_cleanse_min_debuffs;
    shield_special:=settings.boss_shield_special;
    buff_enabled:=settings.boss_buff_enabled;
    guard_mode:=settings.boss_guard_mode;
    guard_hp:=settings.boss_guard_hp_percent;
    guard_every:=settings.boss_guard_every_n;
  else
    allow_physical:=settings.normal_allow_physical;
    allow_magic:=settings.normal_allow_magic;
    allow_spells:=settings.normal_allow_spells and settings.use_learned_spells;
    support_enabled:=settings.normal_support_enabled;
    heal_threshold:=settings.normal_heal_hp_percent;
    cleanse_min:=settings.normal_cleanse_min_debuffs;
    shield_special:=settings.normal_shield_special;
    buff_enabled:=settings.normal_buff_enabled;
    guard_mode:=settings.normal_guard_mode;
    guard_hp:=settings.normal_guard_hp_percent;
    guard_every:=settings.normal_guard_every_n;
  end if;

  -- Personal server mode evaluates every equipped combat option itself.
  -- The normal autobattle profile still supplies thresholds and mana reserve,
  -- but it does not forbid an otherwise clearly superior move.
  allow_physical:=true;
  allow_magic:=true;
  allow_spells:=settings.use_learned_spells;
  support_enabled:=true;
  shield_special:=true;
  buff_enabled:=true;

  physical_score:=greatest(1,private.damage_after_armor(st.physical_power,ce.enemy_defense));
  resistance:=private.damage_resistance_percent(ce.enemy_resistances,st.weapon_damage_type);
  physical_score:=greatest(1,round(
    physical_score
    *(100+st.all_damage_bonus_percent+st.physical_damage_bonus_percent
      +private.character_damage_bonus(cid,st.weapon_damage_type))/100.0
    *(100-resistance)/100.0
    *private.character_expected_critical_multiplier(cid,'physical')
  )::integer);

  magic_score:=greatest(1,private.damage_after_armor(st.magic_power,ce.enemy_defense*0.85));
  resistance:=private.damage_resistance_percent(ce.enemy_resistances,st.magic_damage_type);
  magic_score:=greatest(1,round(
    magic_score
    *(100+st.all_damage_bonus_percent+st.magic_damage_bonus_percent
      +private.character_damage_bonus(cid,st.magic_damage_type))/100.0
    *(100-resistance)/100.0
    *private.character_expected_critical_multiplier(cid,'magic')
  )::integer);

  free_score:=greatest(physical_score,magic_score,1);

  if ce.enemy_hp_current<=physical_score and physical_score>=magic_score then
    return jsonb_build_object('action','physical','label','Физическая атака','reason','lethal_free_hit');
  elsif ce.enemy_hp_current<=magic_score then
    return jsonb_build_object('action','magic','label','Врождённая магия','reason','lethal_free_hit');
  end if;

  if ce.enemy_hp_current<=ceil(free_score*1.5)::integer then
    reserve:=0;
  end if;

  select
    m.character_id,
    m.hp_current,
    m.hp_max,
    floor(m.hp_current*100.0/greatest(1,m.hp_max))::integer,
    m.downed,
    m.guard_percent,
    m.reflect_percent
  into
    support_target_id,
    support_target_hp_current,
    support_target_hp_max,
    support_target_hp_percent,
    support_target_downed,
    support_target_guard,
    support_target_reflect
  from public.party_combat_member_states m
  join public.party_dungeon_run_members rm
    on rm.run_id=ce.run_id and rm.character_id=m.character_id
  where m.encounter_id=p_encounter_id
    and not rm.lost
  order by
    m.downed desc,
    (m.hp_current::numeric/greatest(1,m.hp_max)) asc,
    m.taunt_chance desc,
    m.character_id
  limit 1;

  if support_target_id is null then
    support_target_id:=cid;
    support_target_hp_current:=ms.hp_current;
    support_target_hp_max:=ms.hp_max;
    support_target_hp_percent:=hp_percent;
    support_target_downed:=ms.downed;
    support_target_guard:=ms.guard_percent;
    support_target_reflect:=ms.reflect_percent;
  end if;

  select q.character_id,q.severity
  into cleanse_target_id,cleanse_target_severity
  from (
    select
      m.character_id,
      coalesce(sum(case e.effect_type
        when 'stun' then 5
        when 'vulnerable' then 4
        when 'weaken' then 3
        when 'chill' then 3
        when 'poison' then 2
        when 'burn' then 2
        when 'bleed' then 2
        else 1 end),0)::integer as severity
    from public.party_combat_member_states m
    join public.party_dungeon_run_members rm
      on rm.run_id=ce.run_id and rm.character_id=m.character_id
    left join public.party_combat_status_effects e
      on e.encounter_id=m.encounter_id
     and e.target_type='member'
     and e.target_character_id=m.character_id
     and e.remaining_turns>0
    where m.encounter_id=p_encounter_id
      and not rm.lost
      and not m.downed
    group by m.character_id
  ) q
  order by q.severity desc,q.character_id
  limit 1;

  select coalesce(sum(case effect_type
    when 'stun' then 4
    when 'vulnerable' then 3
    when 'weaken' then 2
    when 'chill' then 2
    else 1 end),0)::integer
  into severity
  from public.party_combat_status_effects
  where encounter_id=p_encounter_id
    and target_type='member'
    and target_character_id=cid
    and remaining_turns>0;

  guard_due:=coalesce((ce.enemy_ai_state->>'danger_pending')::boolean,false);
  if not guard_due then
    guard_due:=case guard_mode
      when 'low_hp' then hp_percent<=guard_hp
      when 'interval' then guard_every>0 and ce.round>0 and mod(ce.round,guard_every)=0
      when 'low_hp_or_interval' then hp_percent<=guard_hp
        or (guard_every>0 and ce.round>0 and mod(ce.round,guard_every)=0)
      else false
    end;
  end if;

  if allow_spells
     and support_enabled
     and cleanse_min>0
     and cleanse_target_id is not null
     and cleanse_target_severity>=cleanse_min
     and ce.enemy_hp_current>free_score
  then
    select sd.*,private.character_effective_spell_mana_cost(cid,sd.id) effective_cost
    into cleanse_spell
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=cid
      and sd.enabled and sd.spell_kind='cleanse'
      and private.character_effective_spell_mana_cost(cid,sd.id)<=ms.mana_current
      and ms.mana_current-private.character_effective_spell_mana_cost(cid,sd.id)>=reserve
    order by private.character_effective_spell_mana_cost(cid,sd.id)
    limit 1;
    if cleanse_spell.id is not null then
      return jsonb_build_object(
        'action','spell','spell_id',cleanse_spell.id,'target_id',cleanse_target_id,
        'label',cleanse_spell.name,'reason','cleanse_ally'
      );
    end if;
  end if;

  if allow_spells and support_enabled and (
       support_target_downed
       or support_target_hp_percent<=28
       or (
         not guard_due
         and (
           (
             heal_threshold>0
             and support_target_hp_percent<=heal_threshold
           )
           or support_target_hp_current<=ceil(ce.enemy_attack*0.90)::integer
         )
       )
     )
     and ce.enemy_hp_current>free_score
  then
    select sd.*,private.character_effective_spell_mana_cost(cid,sd.id) effective_cost
    into heal_spell
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=cid
      and sd.enabled and sd.spell_kind='heal'
      and private.character_effective_spell_mana_cost(cid,sd.id)<=ms.mana_current
      and ms.mana_current-private.character_effective_spell_mana_cost(cid,sd.id)>=reserve
    order by private.autobattle_heal_score(
      cid,sd.id,st.magic_power,
      greatest(0,support_target_hp_max-support_target_hp_current),
      support_target_hp_percent
    ) desc
    limit 1;
    if heal_spell.id is not null
       and (
         ms.mana_current-heal_spell.effective_cost>=reserve
         or support_target_downed
         or support_target_hp_current<=ce.enemy_attack
       )
    then
      return jsonb_build_object(
        'action','spell','spell_id',heal_spell.id,'target_id',support_target_id,
        'label',heal_spell.name,
        'reason',case when support_target_downed then 'revive_ally' else 'protect_weakest_ally' end
      );
    end if;
  end if;

  guard_due:=coalesce((ce.enemy_ai_state->>'danger_pending')::boolean,false);
  if not guard_due then
    guard_due:=case guard_mode
      when 'low_hp' then hp_percent<=guard_hp
      when 'interval' then guard_every>0 and ce.round>0 and mod(ce.round,guard_every)=0
      when 'low_hp_or_interval' then hp_percent<=guard_hp
        or (guard_every>0 and ce.round>0 and mod(ce.round,guard_every)=0)
      else false
    end;
  end if;

  if allow_spells
     and support_enabled
     and shield_special
     and not support_target_downed
     and ce.enemy_hp_current>free_score
     and (
       guard_due
       or support_target_hp_percent<=48
       or support_target_hp_current<=ceil(ce.enemy_attack*1.20)::integer
     )
     and coalesce(support_target_guard,0)<=0
     and coalesce(support_target_reflect,0)<=0
  then
    select sd.*,private.character_effective_spell_mana_cost(cid,sd.id) effective_cost
    into guard_spell
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=cid
      and sd.enabled and sd.spell_kind='guard'
      and (sd.slug<>'mirror_barrier' or support_target_id=cid)
      and private.character_effective_spell_mana_cost(cid,sd.id)<=ms.mana_current
      and ms.mana_current-private.character_effective_spell_mana_cost(cid,sd.id)>=reserve
    order by
      case when sd.slug='mirror_barrier' then 0 else 1 end,
      private.concentrated_spell_percent_value(cid,sd.id,sd.support_value) desc,
      private.character_effective_spell_mana_cost(cid,sd.id)
    limit 1;
    if guard_spell.id is not null then
      return jsonb_build_object(
        'action','spell','spell_id',guard_spell.id,'target_id',support_target_id,
        'label',guard_spell.name,'reason','shield_endangered_ally'
      );
    end if;
  end if;

  if guard_due
     and coalesce(ms.guard_percent,0)<=0
     and coalesce(ms.reflect_percent,0)<=0
  then
    return jsonb_build_object('action','guard','label','Защитная стойка','reason','configured_guard');
  end if;

  if allow_spells and support_enabled and buff_enabled
     and coalesce(ms.damage_bonus_hits,0)<=0
  then
    select sd.*,private.character_effective_spell_mana_cost(cid,sd.id) effective_cost
    into buff_spell
    from public.character_combat_spells ccs
    join public.spell_definitions sd on sd.id=ccs.spell_id
    where ccs.character_id=cid
      and sd.enabled and sd.spell_kind='buff'
      and private.character_effective_spell_mana_cost(cid,sd.id)<=ms.mana_current
      and ms.mana_current-private.character_effective_spell_mana_cost(cid,sd.id)>=reserve
    order by
      private.concentrated_spell_percent_value(cid,sd.id,sd.support_value)
        *greatest(1,sd.support_turns) desc,
      private.character_effective_spell_mana_cost(cid,sd.id)
    limit 1;
    if buff_spell.id is not null and ce.enemy_hp_current*100>greatest(1,ce.enemy_hp_max)*40 then
      return jsonb_build_object(
        'action','spell','spell_id',buff_spell.id,'target_id',cid,
        'label',buff_spell.name,'reason','buff_opening'
      );
    end if;
  end if;

  if allow_physical then
    physical_score:=greatest(1,private.damage_after_armor(st.physical_power,ce.enemy_defense));
    resistance:=private.damage_resistance_percent(ce.enemy_resistances,st.weapon_damage_type);
    physical_score:=greatest(1,round(
      physical_score
      *(100+st.all_damage_bonus_percent+st.physical_damage_bonus_percent
        +private.character_damage_bonus(cid,st.weapon_damage_type))/100.0
      *(100-resistance)/100.0
      *private.character_expected_critical_multiplier(cid,'physical')
    )::integer);
  end if;

  if allow_magic then
    magic_score:=greatest(1,private.damage_after_armor(st.magic_power,ce.enemy_defense*0.85));
    resistance:=private.damage_resistance_percent(ce.enemy_resistances,st.magic_damage_type);
    magic_score:=greatest(1,round(
      magic_score
      *(100+st.all_damage_bonus_percent+st.magic_damage_bonus_percent
        +private.character_damage_bonus(cid,st.magic_damage_type))/100.0
      *(100-resistance)/100.0
      *private.character_expected_critical_multiplier(cid,'magic')
    )::integer);
  end if;

  free_score:=greatest(physical_score,magic_score,1);

  if allow_spells then
    select q.* into damage_spell
    from (
      select
        sd.id,sd.name,
        private.character_effective_spell_mana_cost(cid,sd.id) effective_cost,
        greatest(1,round(
          greatest(1,private.damage_after_armor(
            round(st.magic_power*sd.power_multiplier)::integer+sd.flat_power,
            ce.enemy_defense*0.85
          ))
          *(100+st.all_damage_bonus_percent+st.magic_damage_bonus_percent
            +private.character_damage_bonus(cid,sd.damage_type)
            +private.character_spell_family_damage_bonus_percent(cid,sd.id))/100.0
          *(100-private.damage_resistance_percent(ce.enemy_resistances,sd.damage_type))/100.0
          *private.character_expected_critical_multiplier(cid,'magic')
        )::integer)
        +case
          when sd.status_effect_type='stun'
            then round(ce.enemy_attack*sd.status_effect_chance/100.0)::integer
          when sd.status_effect_type='vulnerable'
            then round(
              free_score
              *sd.status_effect_potency/100.0
              *greatest(1,least(2,sd.status_effect_turns))
              *sd.status_effect_chance/100.0
            )::integer
          when sd.status_effect_type in ('weaken','chill')
            then round(
              ce.enemy_attack
              *sd.status_effect_potency/100.0
              *greatest(1,least(2,sd.status_effect_turns))
              *sd.status_effect_chance/100.0
            )::integer
          else 0
        end as score,
        coalesce(
          case when ce.is_boss then rule.boss_priority else rule.normal_priority end,
          100
        ) priority
      from public.character_combat_spells ccs
      join public.spell_definitions sd on sd.id=ccs.spell_id
      left join public.character_autobattle_spell_rules rule
        on rule.character_id=cid and rule.spell_id=sd.id
      where ccs.character_id=cid
        and sd.enabled and sd.spell_kind='damage'
        and private.character_effective_spell_mana_cost(cid,sd.id)<=ms.mana_current
        and ms.mana_current-private.character_effective_spell_mana_cost(cid,sd.id)>=reserve
        and (
          rule.character_id is null
          or case when ce.is_boss then rule.boss_enabled else rule.normal_enabled end
        )
    ) q
    order by round(q.score*greatest(0.8,least(1.2,1.10-(q.priority-1)*0.002))) desc,
             q.effective_cost
    limit 1;
  end if;

  if damage_spell.id is not null
     and damage_spell.score>=ceil(free_score*1.10)::integer
  then
    return jsonb_build_object(
      'action','spell','spell_id',damage_spell.id,'target_id',null,
      'label',damage_spell.name,'reason','best_damage_line'
    );
  end if;

  if physical_score>=magic_score and physical_score>0 then
    if family='long_bow' and hp_percent>40 then
      return jsonb_build_object('action','bow_draw','label','Полный натяг','reason','long_bow');
    end if;
    return jsonb_build_object('action','physical','label','Физическая атака','reason','best_free_hit');
  elsif magic_score>0 then
    return jsonb_build_object('action','magic','label','Врождённая магия','reason','best_free_hit');
  end if;

  return jsonb_build_object('action','physical','label','Физическая атака','reason','fallback');
end;
$function$
;

revoke all on function public.get_client_runtime_state(uuid,text,uuid) from public,anon;
grant execute on function public.get_client_runtime_state(uuid,text,uuid) to authenticated;

revoke all on function public.set_client_runtime_state(uuid,text,uuid,boolean) from public,anon;
grant execute on function public.set_client_runtime_state(uuid,text,uuid,boolean) to authenticated;

revoke all on function public.sync_client_duel_turn(uuid,uuid) from public,anon,authenticated;
revoke all on function public.sync_client_party_turn(uuid,uuid) from public,anon,authenticated;
revoke all on function private.process_client_runtime_sessions() from public,anon,authenticated;

do $$
declare
  jid bigint;
begin
  select jobid into jid
  from cron.job
  where jobname='veira-client-runtime-worker'
  limit 1;

  if jid is not null then
    perform cron.unschedule(jid);
  end if;

  perform cron.schedule(
    'veira-client-runtime-worker',
    '1 second',
    'select private.process_client_runtime_sessions();'
  );
end $$;
