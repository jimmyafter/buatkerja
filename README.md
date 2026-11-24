# buatkerja.my

Company-operated home-services platform (not a marketplace): customer portal, admin/operations dashboard, workforce mobile app. Next.js + TypeScript + Tailwind + shadcn/ui on Supabase (Postgres, Auth, Storage).

## Design package (review first)
1. [Architecture](docs/01-architecture.md)
2. [ERD](docs/02-erd.md)
3. SQL migrations: [`supabase/migrations/`](supabase/migrations) (13 files, applied in order)
4. [Authentication & roles](docs/03-auth-roles.md)
5. [RLS policies](docs/04-rls-policies.md)
6. [Routes & components](docs/05-routes-components.md)

## Verify the database design
```bash
supabase/tests/run.sh   # rebuilds a scratch Postgres 16 DB from the migrations, runs the workflow + RLS tests
```
Expected last line: `ALL WORKFLOW + RLS TESTS PASSED`.
`tests/00_supabase_stub.sql` stands in for Supabase's `auth`/`storage` schemas and is never a migration.
