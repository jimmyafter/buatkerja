# 1. System architecture

## Shape
Two clients, one Supabase project: a native **Expo / React Native** app (customers, employees, outsourced workers; role decides the interface) and a **Next.js** admin dashboard (super / operations / finance admin, supervisors).
No separate API server: the **database is the authority** (constraints, triggers, RLS, RPC functions); both clients are thin and typed.
*(Updated for the master spec: the earlier PWA plan and the `/portal`, `/work` web areas are dropped. See `00-spec-review-and-delta.md`.)*

```
 Browser / installed PWA
  Expo app (iOS/Android): customer · employee · outsourced worker      Next.js admin: super/ops/finance admin · supervisor
                         │  @supabase/ssr  (cookie session, user JWT)
                         ▼
   Supabase ── Auth (email+password / magic link, MFA for staff)
            ├─ PostgREST  (table reads/writes under RLS)  +  RPC (workflow functions, SECURITY DEFINER)
            ├─ Postgres   (enums, FKs, CHECKs, guard triggers, audit triggers, RLS)
            └─ Storage    (3 private buckets, path-based policies, signed URLs)
   Server-only: SUPABASE_SERVICE_ROLE_KEY — used ONLY to provision staff accounts and by cron (expire quotes)
```

## Defence in depth (who enforces what)
| Layer | Responsibility |
|---|---|
| Middleware + layouts | UX routing by role, session refresh. **Not** a security boundary. |
| RLS policies | Row visibility/ownership per role (customer = own account, worker = current assignment, supervisor = own jobs). |
| Guard triggers | Integrity no policy can express: state machines, frozen quotation versions, append-only evidence, invoice lines must mirror approved lines, no overpayment. |
| RPC functions | The only path that changes a `status`. Each re-checks the caller's role/ownership. A direct table `UPDATE status` from a client is rejected by trigger. |
| Audit triggers | Row-level INSERT/UPDATE/DELETE history with actor, role, changed columns. Append-only. |

## Key design decisions
1. **Company-operated, not a marketplace.** There is no table for contractor profiles, listings, bids or commissions. Workers exist only as company-approved records (`workers`, optional `outsource_partners`) and are created/approved by admins. Assignment is blocked by trigger unless the worker (and partner contract) is approved.
2. **Customer account ≠ user.** `customer_accounts` is the owning unit (individual or business); `customer_members` links 1..n logins. Property managers get several users and several properties under one account. Every child row carries `account_id` with **composite FKs** (`(request_id, account_id)`), so a record can never point at another account's data.
3. **Workers never see money or customer records.** `jobs` is a delivery record holding a *snapshot* of site address/contact and a price-free scope. Workers have no policy on quotations, invoices, properties or accounts.
4. **Quotation versioning.** `quotations` (1 per request) → `quotation_versions` (v1, v2…) → `quotation_items`. A version is editable only as `draft`; once `sent` its content and items are frozen by trigger and it can only end as approved/rejected/superseded/withdrawn/expired. Totals are computed by trigger, never trusted from the client. Customers cannot see drafts.
5. **Change orders for extra chargeable work.** Workers can only *flag* work (`change_order_requests`, no price). Admin prices it (`change_orders`), customer approves via RPC. Invoicing includes only approved change-order lines and is blocked while one is pending.
6. **Evidence.** `job_progress_updates`, `job_photos`, `job_verifications` are append-only (UPDATE/DELETE trigger-blocked); photo objects in Storage have no update/delete policy. Submitting for verification requires ≥1 *before* and ≥1 *after* photo (newer than the last rejection).
7. **Money.** `numeric(12,2)` MYR, per-line tax rate (SST-ready), line totals are generated columns. Invoice lines are copied from approved quote/CO lines and a trigger rejects any line that differs; extras are explicit `adjustment` lines. Payments are an append-only ledger; invoice `amount_paid`/status derive from it; mistakes are voided, never edited.
8. **Document numbers** (`SR-2026-00001`, `QT-`, `BK-`, `JB-`, `CO-`, `INV-`) come from a row-locked counter; invoice numbers are assigned only at issue, so drafts never burn numbers.
9. **Internal notes** live in `internal_notes` (admin-only) because RLS is row-level: a private column on a customer-readable row would leak.

## Workflow → state machines
```
service_request: draft → submitted → under_review ⇄ info_requested
                 → quoted → approved → booked → in_progress → completed → invoiced → closed
                 (cancelled / rejected from early states)
quotation_version: draft → sent → approved | rejected | superseded | withdrawn | expired
job:     scheduled → in_progress → pending_verification → verified
                                         └→ rework_required → in_progress
invoice: draft → issued → partially_paid ⇄ paid ;  issued → void (only with no payments)
change_order: draft → sent → approved | rejected | withdrawn
```
| Step (from brief) | Actor | Function / mechanism |
|---|---|---|
| Customer submits request | customer | insert draft → `submit_service_request` |
| Admin reviews | admin | `review_service_request(start_review / request_info / reject)` |
| Admin prepares quotation | admin | `create_quotation`, items, `create_quotation_revision`, `send_quotation_version` |
| Customer approves | customer (or admin recording an offline approval, flagged `admin_recorded`) | `respond_to_quotation` / `record_quotation_response` |
| Admin confirms booking | admin | `confirm_booking` (creates booking + job) |
| Admin assigns workforce | admin | insert `job_assignments` (trigger validates approval) |
| Worker updates progress | worker | `start_job`, insert progress/photos, `submit_job_for_verification` |
| Extra work | worker→admin→customer | flag → `create_change_order` → `send_change_order` → `respond_to_change_order` / `record_change_order_response` |
| Supervisor verifies | supervisor | `verify_job` (pass / fail → rework) |
| Admin issues invoice | admin | `create_invoice_draft` → `issue_invoice` |
| Payment recorded | admin | insert `payments` (trigger updates invoice + request) |

## Application layers (Next.js)
- `src/lib/supabase/{server,client,middleware}.ts` – `@supabase/ssr` clients. Server Components read with the user's JWT, so RLS always applies.
- `src/lib/db/*` – typed query/RPC wrappers; types from `supabase gen types typescript`.
- `src/lib/validation/*` – zod schemas shared by forms and Server Actions (UX validation; DB remains authoritative).
- Server Actions call RPCs and map Postgres errors (`42501`, `P0002`, `raise exception` text) to friendly messages.
- Service-role client exists in one file (`lib/supabase/admin.ts`, `server-only`), used by the staff-provisioning action and the quote-expiry cron.

## Mobile app (replaces the PWA plan)
Expo Router, session in `expo-secure-store`, deep links for email confirmation/reset. Worker flows have an offline queue (SQLite) for progress notes, checklist ticks and photos, with on-device compression and retry. Push via `expo-notifications`: the database writes `notifications` rows, and the `notify-push` Edge Function (service role) sends them. EAS Build produces the store binaries.

## Non-functional
- Security: email confirmation required, MFA (TOTP) mandatory for admin/supervisor, rate limiting on auth, strict CSP, signed URLs (short TTL) for files, MIME/size limits in buckets, service-role key server-only.
- Privacy (PDPA 2010): minimal customer data to workers (snapshot only), assignment-scoped access that ends when released; retention policy to be defined.
- Operations: migrations in `supabase/migrations`, DB tests in `supabase/tests` (rebuild + ~90 assertions), CI runs them on every PR.
- Performance: policies use `(select fn())` initPlan pattern; indexes on all FK/RLS columns.

## Build order (after your review)
1. Auth, profiles, role routing, customer onboarding (account + property)  ← first
2. Customer service request workflow (create draft, photos, submit, list, timeline, cancel)
3. Admin: request inbox + review → quotation builder/versions → customer approval UI
4. Booking, workforce (workers/partners), assignment
5. Worker mobile app (jobs, progress, photos offline queue, change-order flag) + supervisor verification
6. Change orders, invoicing, payments, receipts/PDFs
7. Audit viewer, reports, notifications, hardening
