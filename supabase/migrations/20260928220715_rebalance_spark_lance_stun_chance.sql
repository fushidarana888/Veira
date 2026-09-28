-- Synced from live Supabase migration 20260928220715 (rebalance_spark_lance_stun_chance)

update public.spell_definitions
set status_effect_chance=20,
    updated_at=now()
where slug='spark_lance';
