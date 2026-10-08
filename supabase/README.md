# Supabase backend

Schema for running Project management Rev growth on Supabase. The design and the full field map are in `.10x/specs/2026-10-08-supabase-data-model-design.md`, and the decision is ADR-001.

## Files

- `migrations/20261008000000_init_schema.sql`: all tables, enums, triggers, RLS policies, the Storage bucket and the realtime publication
- `tests_rls_scenarios.sql`: access-control scenarios (Owner, Member, Guest, outsider) that the schema passed

## Apply it

1. Create a project at supabase.com. Note the **Project URL** and the **anon public key** (Project Settings → API).
2. Apply the migration in one of two ways:
   - **Dashboard:** open SQL Editor, paste `migrations/20261008000000_init_schema.sql`, and run it.
   - **CLI:** run `supabase link --project-ref <ref>` and then `supabase db push`.
3. Under Authentication → Providers, enable Email (and Google if wanted). Under Authentication → MFA, enable TOTP to back the 2FA settings screen.
4. Add the client keys to a local `.env` file (it is already gitignored):

```
VITE_SUPABASE_URL=https://<ref>.supabase.co
VITE_SUPABASE_ANON_KEY=<anon public key>
```

The app does not read these yet. Wiring the client is the next phase (ADR-001, Option A).
