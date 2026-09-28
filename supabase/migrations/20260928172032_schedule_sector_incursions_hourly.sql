-- Synced from live Supabase migration 20260928172032 (schedule_sector_incursions_hourly)


create extension if not exists pg_cron with schema pg_catalog;

select cron.schedule(
  'veira-sector-incursions',
  '5 * * * *',
  $$select private.ensure_rotating_sector_incursions();$$
);

select private.ensure_rotating_sector_incursions();

