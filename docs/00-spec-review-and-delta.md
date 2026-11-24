# Master specification review: what is kept, what changes, what is missing

Reviewed: *buatkerja.my — Master Software Development Specification* (supersedes the earlier "responsive PWA" brief).
Status of the repo at review time: design package + 13 Supabase migrations + DB test suite (all passing). No app code yet.

## 1. Summary
- The **backend design holds up**: the workflow, RLS model, quotation versioning, evidence trail, billing integrity and audit log already match section 7 of the spec. Roughly 80% of the migrations are reusable as-is.
- **Three structural changes**: (1) customer and worker UIs become a **native Expo app**, not PWA routes; Next.js becomes **admin-only**. (2) The single `admin` role splits into **super / operations / finance admin**, with supervisors working on the web. (3) Eight modules in the spec have **no database support yet** (below).
- **One gap in my earlier work**: financial *line items* (`quotation_items`, `change_order_items`, `invoice_items`) are not audit-logged. Spec rule "all financial changes must be auditable" requires it. Quick fix, listed in 3.

## 2. Requirement-by-requirement status (spec section 7)
| Rule | Status | Where / note |
|---|---|---|
| No marketplace functionality | Met | No listing/bid/commission tables exist |
| Outsourced workers approved by company | Met | `workers`/`outsource_partners` approval + assignment trigger; partner expiry revokes access |
| Only administrators assign workers | Met, needs role update | assignment insert policy = admin → becomes operations admin + super admin |
| Customers only access own data | Met | account-scoped RLS, composite FKs, tested |
| Workers only access assigned jobs | Met | assignment-scoped, ends on release/suspension |
| Quotation version history | Met | frozen versions, trigger-computed totals |
| Customer approves chargeable extra work | Met | change orders + offline-recorded approvals (flagged `admin_recorded`) |
| Workers cannot change quotation prices | Met | workers have no policy on quotations/items; extra work flagged without price |
| Every important status change logged | Mostly | row-level audit on core tables; new tables need the same (3) |
| Job completion requires evidence | Met | before + after photos required, append-only; to add: mandatory checklist items |
| All financial changes auditable | **Gap** | line items not audited; job costs (new) must be |
| Business customers, multiple properties | Met | accounts → members + properties |

## 3. Gaps: new schema needed (proposed migrations 014+)
| Spec module | Proposal | Notes |
|---|---|---|
| **Inspections** | `inspections` (request, site snapshot, inspector, scheduled_at, status, findings) + photos in `request-attachments`/new `inspection-photos` bucket | Request stays `under_review`; admin schedules, supervisor/ops completes; quotation can cite the inspection |
| **Job checklist** | `checklist_templates` + `checklist_template_items` per service category; `job_checklist_items` copied onto the job in `confirm_booking`; worker ticks | `submit_job_for_verification` requires all *required* items done; ticks audited |
| **Travel and arrival status** | add job statuses `en_route`, `arrived` (+ `travel_started_at`, `arrived_at`, optional arrival lat/lng) | Location captured **only at the arrival event**, not continuous tracking (PDPA minimisation); customer notified "on the way" |
| **Materials used** | `job_materials` (description, qty, unit; **no cost**, worker-writable, append-only) | Workers never see cost data |
| **Job cost tracking** | `job_cost_entries` (type labour/material/subcontract/other, amount, source, void-not-edit like payments), finance/ops only | Outsourced partner charges recorded here; feeds margin report |
| **Worker availability** | `worker_time_off` + availability rules; `available_workers(start,end,category)` for the assignment dialog; assignment trigger blocks overlapping bookings unless an override reason is given | Business rule to confirm (6) |
| **Quality checks** | Keep `job_verifications` (supervisor pass/fail) and add optional `quality_score` + checklist review; admin QA view | No separate workflow unless you want post-completion sampling |
| **Feedback** | `job_feedback` (rating 1–5, comment), one per verified job, customer inserts via RPC, back-office reads | Hidden from workers |
| **Reports** | security-invoker SQL views/RPCs: revenue, receivables ageing, job margin, turnaround, worker utilisation, request funnel | Financial reports finance/super only |
| **Notifications** | `device_tokens`, `notifications` (in-app inbox), outbox processed by an **Edge Function** (Expo push) | Events: quote ready, booking confirmed, on the way, extra-work approval needed, invoice issued, job assigned |
| **Service history** | view over closed jobs per property/account | No new table |
| **Support** | start with profile + contact (WhatsApp/phone/email) config; tickets only if you want them | Flagged as a decision |
| Audit coverage | add `audit_row` triggers to `quotation_items`, `change_order_items`, `invoice_items`, `service_request_attachments`, and every new table | Closes the financial-audit gap |

## 4. Roles (spec section 2B)
Spec roles: **super admin, operations admin, finance admin, supervisor** (web); **customer, employee, outsourced worker** (mobile).
- `app_role` becomes `customer | worker | supervisor | super_admin | ops_admin | finance_admin`. Employee vs outsourced stays on `workers.worker_type` (one login role, two interface variants).
- Replace `private.is_admin()` with capability helpers so policies stay readable:
  `is_super_admin()`, `is_ops()` (super+ops), `is_finance()` (super+finance), `is_back_office()` (any of the three).
- Proposed mapping (please confirm):

| Capability | Super | Ops | Finance | Supervisor |
|---|---|---|---|---|
| Users, roles, permissions, staff invites, audit log | ✔ | – | – | – |
| Customers, properties, catalogue | ✔ | ✔ | read | – |
| Requests, inspections, quotations, change orders | ✔ | ✔ | read | – |
| Bookings, workers, availability, partners, assignments | ✔ | ✔ | read | read own jobs |
| Job progress / evidence | ✔ | ✔ | read | own jobs |
| Verification / quality checks | – | – | – | ✔ (own jobs) |
| Invoices, payments, voids | ✔ | read | ✔ | – |
| Job costs, margin & financial reports | ✔ | read costs | ✔ | – |
| Operational reports | ✔ | ✔ | ✔ | own |
- Existing RPCs that say `require_role(['admin'])` change to the right capability (e.g. invoices → finance, confirm_booking → ops).
- Segregation of duties kept: only the named supervisor verifies; nobody can approve a quotation except the customer, or ops recording an offline approval with evidence.
- Postgres cannot drop enum values, and nothing is deployed yet, so I propose **amending the original migrations in place** (clean history for first deploy) instead of stacking "fix" migrations. Git history keeps the earlier version.

## 5. Architecture changes
```
 apps/mobile  (Expo, Expo Router, TS)  ── customers + employees + outsourced workers (role-based UI)
 apps/admin   (Next.js, Tailwind, shadcn) ── super / ops / finance admin + supervisor
 packages/db-types   generated Supabase types       packages/validation  zod schemas (shared)
 packages/tokens     brand tokens: teal #0E6F66, cream #F1EBE1, charcoal/white  (Tailwind + RN theme)
 supabase/           migrations, tests, Edge Functions
```
- **Backend unchanged in kind**: Postgres is the authority (RLS, triggers, RPCs). Both clients use `supabase-js` with the user's JWT.
- **Edge Functions** (service-role, server-side only): `send-notifications` (outbox → Expo push), `expire-quotations` (scheduled), `invite-staff` (create auth user + role; called from admin Next.js server action), later PDF generation. The service-role key lives only there and in Next.js server code, never in the mobile bundle or `NEXT_PUBLIC_*`.
- **Mobile specifics**: session in `expo-secure-store`; email-confirm/reset via deep links; photos via `expo-camera`/`image-picker` → compress → upload to Storage with the user session; **offline queue** (SQLite) for progress, checklist ticks and photos with retry; `expo-notifications`; EAS Build for Android/iOS; one binary, role decides the interface after login. Staff accounts are provisioned only by super admin, so the stores' "login required" review needs a demo customer account.
- The earlier PWA plan (`/portal`, `/work` Next.js routes, service worker) is **dropped**; `docs/05-routes-components.md` is superseded by section 6 below.

## 6. Navigation
### Mobile (Expo Router)
```
app/
  (auth)/        welcome  login  register  verify-email  forgot-password
  (customer)/    tabs: Home · Requests · Properties · Invoices · Account
    Home            service catalogue, "needs your action" cards (approve quote / extra work), active job
    Requests        list → new (service → property → details → photos → review) → [id] tracking timeline
                    → quotation/[versionId] (versions, approve / decline) → job/[id] (progress, verified photos)
                    → change-order/[id] → feedback/[jobId]
    Properties      list, add/edit, service history per property
    Invoices        list → [id] (status, payments)
    Account         profile, business team, support, notifications, sign out
  (worker)/      tabs: Today · Schedule · Notifications · Profile
    Today           assigned jobs
    job/[id]        details + customer/site info → checklist → On my way → Arrived → Start → progress notes
                    → materials used → camera (before/progress/after/issue) → additional-work request → submit
    Schedule        calendar of assignments + time off
    Profile         worker + (outsourced: partner company) details
```
### Admin web (Next.js), items shown by role
`Dashboard` · `Requests` (inbox, inspections) · `Quotations` (builder, versions) · `Bookings` (calendar) · `Jobs` (progress, additional-work approvals, quality checks) · `Workforce` (workers, availability, partners) · `Customers` (accounts, properties) · `Finance` (invoices, payments, job costs, reports) · `Catalogue` · `Administration` (users & roles, audit log).
Supervisor view: **My jobs** (verification queue, evidence review, quality notes) only.

## 7. Implementation phases and dependencies
| Phase | Deliverable | Depends on |
|---|---|---|
| 0 | Confirm decisions (section 8); amend migrations for roles + new tables + audit coverage; extend DB tests | – |
| 1 | Monorepo scaffold (pnpm + Turborepo), shared packages, tokens, CI: typecheck, lint, DB tests, unit tests | 0 |
| 2 | Auth + onboarding: mobile register/login/deep links/customer onboarding; admin login with MFA + role guard | 1 |
| 3 | Customer service request (mobile) + admin request inbox and review | 2 |
| 4 | Quotation builder + versions (admin) and review/approve (mobile) | 3 |
| 5 | Bookings, workforce, availability, assignment, inspections (admin) | 4 |
| 6 | Worker app: jobs, checklist, travel/arrival, progress, camera + offline queue, materials, extra-work request | 5 |
| 7 | Supervisor verification + quality checks (web); change orders end to end | 6 |
| 8 | Invoices, payments, job costs, reports (finance) | 7 |
| 9 | Notifications (Edge Function + push), feedback, service history, support, hardening, EAS store builds | 8 |
Per-feature gate (spec section 9): explain changes → implement → typecheck → lint → tests → verify permissions → report files and open issues.

## 8. Decisions (confirmed 24 Nov 2026)
1. **Role mapping** in section 4: correct anything that is wrong (e.g. should ops admins see invoice amounts?).
2. **Outsourced vs employee interface**: same job screens, or should outsourced workers see less (no schedule of other jobs, no company notices)? Proposed default: identical job flow, partner name on profile, no employee-only items.
3. **Amend migrations in place** (recommended, nothing deployed) vs append.
4. **Overlapping bookings**: block double-booking a worker unless an override reason is given (proposed), or only warn?
5. **Support**: contact details only for v1 (proposed), or in-app tickets?
6. **Inspections**: free, or can they be charged? (affects whether they need a quotation/invoice line)

**Confirmed:** (1) role mapping as in section 4, ops admins can read invoice amounts; (2) outsourced workers get the same job screens as employees; (3) migrations amended in place; (4) double-booking is blocked unless an admin records an override reason; (5) support is contact details only for v1; (6) inspections are free.

## 9. Phase 0 status: done
- Roles: `super_admin | ops_admin | finance_admin | supervisor | worker | customer`; capability helpers `is_super_admin / is_ops / is_finance / is_back_office`; every policy, RPC and storage policy re-mapped.
- New migrations: `014` field operations (availability + conflict rule, checklists, materials, inspections), `015` costs / quality score / feedback / settings / reports, `016` notifications, `017` inspection + travel functions.
- Amended: job statuses `en_route`, `arrived`; assignment override; booking reschedule conflict check; checklist copy on booking; required-checklist gate before submission; verification quality score; audit now also covers quotation, change-order and invoice lines, attachments and every new table.
- Tests: `supabase/tests/01` (workflow + RLS) and `02` (spec modules) both pass via `supabase/tests/run.sh`.
- Open items for later phases: Edge Functions (`notify-push`, `expire-quotations`, `invite-staff`) are specified but not written; support phone/WhatsApp/email/hours in `app_settings` are empty placeholders that a super admin must fill in before launch.
