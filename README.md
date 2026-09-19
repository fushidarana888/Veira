# Veira

Veira Game / Game RP is a browser-first RPG project designed from the start for a future Android/iOS client.

## Architecture

- `apps/web` — React + Vite web client
- `packages/game-core` — shared deterministic game logic and types
- Supabase — auth, database, RLS, server-side state

The web client is only one frontend. Authoritative game mutations must stay on the backend so a future mobile app can use the same game state safely.

## Current foundation

- email/password registration and login
- automatic profile creation
- separate `player` and `gm` account types
- first-character creation for player accounts
- server-created character progress
- player dashboard with level, EXP, HP, stats and gold
- GM dashboard shell
- RLS enabled on all public game tables
- GM audit log table

## Local setup

Create `apps/web/.env.local`:

```env
VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

Then run:

```bash
npm install
npm run dev
```

## GM accounts

All new signups default to `player`. A GM account must be promoted by an administrator in the database. Players cannot promote themselves through the client.

## Next modules

Character editing and avatars, inventory/equipment, personal world map and expeditions, combat engine, parties/dungeons, guilds, raid bosses and the full GM live-control panel.
