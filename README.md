# buatkerja.my

Company-operated home-services platform (not a marketplace): a native Expo app for customers and workers, and a Next.js admin dashboard, on Supabase (Postgres, Auth, Storage, Edge Functions).

## Design package (review first)
0. [Spec review, decisions and phase plan](docs/00-spec-review-and-delta.md)
1. [Architecture](docs/01-architecture.md)
2. [ERD](docs/02-erd.md)
3. SQL migrations: [`supabase/migrations/`](supabase/migrations) (17 files, applied in order)
4. [Authentication & roles](docs/03-auth-roles.md)
5. [RLS policies](docs/04-rls-policies.md)
6. Navigation and phases: `docs/00-spec-review-and-delta.md` sections 5-7 (`05-routes-components.md` is superseded)

## Verify the database design
```bash
supabase/tests/run.sh   # rebuilds a scratch Postgres 16 DB from the migrations, runs both test suites
```
Expected last line: `ALL WORKFLOW + RLS TESTS PASSED`.
`tests/00_supabase_stub.sql` stands in for Supabase's `auth`/`storage` schemas and is never a migration.
