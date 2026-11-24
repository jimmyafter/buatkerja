# 4. RLS policies

The policies are in `supabase/migrations/20260101000011_rls.sql` (tables) and `…012_storage.sql` (Storage). This page explains the pattern and the traps they avoid.

## Pattern
1. **Deny by default.** `revoke all` on every table from `anon`/`authenticated`, then grant only the verbs each table needs. RLS is enabled on every `public` table; `doc_counters` has no policy, so it is unreachable from clients.
2. **Helpers, not joins.** Policies call `private.*` SECURITY DEFINER functions (`is_super_admin`, `is_ops`, `is_finance`, `is_back_office`, `is_account_member`, `is_assigned_to_job`, `is_job_supervisor`, `customer_can_see_version`, …). They are not API-exposed, they avoid recursive RLS, and they return "no access" for deactivated users.
3. **initPlan caching.** Every helper call is wrapped as `(select private.fn())`, so Postgres evaluates it once per statement instead of once per row.
4. **Status never comes from table writes.** Policies allow content edits; guard triggers reject any client change to a `status` column; RPC functions (run as the function owner) perform transitions.
5. **No write policy = no write.** For example `job_photos` has insert only, `job_verifications` has select only, `payments` has insert only, and `storage.objects` for `job-photos` has no update/delete policy.

## Policy summary
Read 'admin' below as: **reads = any back-office role; content writes = ops admin (+super); invoices, invoice lines, payments, documents and job costs = finance admin (+super); profiles update, audit log and settings = super admin.** Migrations 014-016 add the same pattern for time off, checklists, materials, inspections, job costs, feedback, settings, notifications and device tokens (customers get no policy on inspections, checklists, materials or costs; notifications and tokens are own-rows only).

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| profiles | self, admin, supervisor of assigned worker | trigger only | self/admin (trigger blocks role/email/active unless admin) | – |
| customer_accounts | member, admin | admin (customers use RPC) | owner, admin | – |
| customer_members | member, admin | admin | admin | admin |
| properties | member, admin | member, admin | member, admin | admin |
| service_requests | member, admin | member with `status='draft'`, admin | admin; member only while `draft` | draft only |
| attachments | member, admin | uploader while draft/info_requested | – | while editable, admin |
| request events | admin; members see `visible_to_customer` | admin notes | – (trigger) | – |
| quotations / versions / items | admin; customer only non-draft | admin (RPC) | admin (drafts; frozen by trigger after send) | admin (drafts) |
| bookings | admin, member | RPC only | admin (reschedule) | – |
| jobs | admin, member, assigned worker, job supervisor | RPC only | admin | – |
| job_assignments | admin, own worker, job supervisor | admin | admin (release) | – |
| progress / photos | admin, assigned worker, job supervisor (+customer: before/after of verified jobs) | assigned worker (supervisor/admin for notes) | – (trigger) | – (trigger) |
| job_verifications | admin, job supervisor, assigned worker | RPC only | – | – |
| change_order_requests | admin, raiser, job supervisor | assigned worker | admin (dismiss) | – |
| change_orders / items | admin; customer only non-draft | admin | admin (drafts) | – |
| invoices | admin; customer only issued | RPC only | admin (due date only) | admin (drafts) |
| invoice_items | same as invoice | admin: **adjustment lines only** | adjustment only | adjustment only |
| payments | admin, customer of account | admin | RPC void only | – (trigger) |
| audit_logs | admin | triggers only | – (trigger) | – (trigger) |

## Traps handled deliberately
- **RLS is row-level, not column-level** → internal notes are a separate admin-only table; workers get a price-free `jobs` row with a site snapshot instead of access to `properties`/`quotations`.
- **Filtered UPDATE is silent** (0 rows, no error). Tests assert on affected rows where policy is the guard and on raised errors where a trigger is the guard.
- **Revocation is immediate**: releasing an assignment, suspending a worker/partner, partner contract expiry or `is_active=false` removes access on the next request.
- **Storage paths are untrusted**: `private.try_uuid()` prevents cast errors from a crafted folder name; upload paths must also match an existing, editable request / an assigned, active job.
- **Offline approvals are explicit, never silent**: `respond_to_quotation` is customer-only; an admin must use `record_quotation_response` with an evidence note, which flags `admin_recorded` and posts a customer-visible timeline entry.

## Verification
`supabase/tests/run.sh` rebuilds a scratch database from all migrations and runs two suites (about 185 assertions) as customers, ops/finance/super admins, a supervisor, employee and outsourced workers, plus `anon`: isolation between customers, worker scoping, draft invisibility, frozen versions, immutable evidence and audit, invoice-line tampering, overpayment, and bypass attempts (direct status update, self-promotion), plus double-booking and leave conflicts, checklist gating, inspections, costs, feedback, role-restricted reports, notifications and settings.
