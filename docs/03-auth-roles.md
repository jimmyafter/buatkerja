# 3. Authentication and role permissions

## Identity model
- **Supabase Auth** handles credentials, sessions, email confirmation, password reset and MFA.
- On sign-up a trigger creates `profiles(id = auth.users.id, role = 'customer')`. **Role is never read from client-supplied metadata**; only a **super admin** (or the service role) can change it, and a super admin cannot change their own role.
- `is_active = false` makes every helper return "no access" immediately, even with a still-valid JWT.
- Roles: `customer`, `worker` (employee or outsourced, via `workers.worker_type`), `supervisor`, `ops_admin`, `finance_admin`, `super_admin`. Policies use capability helpers: `is_super_admin()`, `is_ops()` (ops+super), `is_finance()` (finance+super), `is_back_office()` (all three).
- Supervisors are staff profiles named on a job (`jobs.supervisor_id`); they cannot be workers, which gives segregation of duties for verification.

## Onboarding flows
| Who | How |
|---|---|
| Customer | Public sign-up → confirm email → `create_customer_account()` (individual/business, becomes owner) → add property → request. |
| Business team member | Ops admin adds a membership (owner-invite UI in a later module). |
| Worker / supervisor / admin | **No public sign-up.** Super admin only, via the `invite-staff` Edge Function / admin server action (service role, never in the mobile bundle) invites the user by email, sets `profiles.role`, creates `workers` row (+ `outsource_partners` for outsourced). Worker must be set `approved` before they can be assigned or see any job. |
| Outsourced partner | Ops admin creates + approves partner (with contract expiry). Expiry/suspension automatically revokes the partner's workers' access and blocks new assignment. |

## Permission matrix (confirmed)
| Capability | Super | Ops | Finance | Supervisor |
|---|---|---|---|---|
| Users, roles, staff invites, audit log, settings | ✔ | – | – | – |
| Customers, properties, catalogue, checklist templates | ✔ | ✔ | read | – |
| Requests, inspections, quotations, change orders, offline-approval recording | ✔ | ✔ | read | inspections assigned to them |
| Bookings, workers, availability, partners, assignments (incl. override reason) | ✔ | ✔ | read | read own jobs |
| Job progress / evidence | ✔ | ✔ | read | own jobs |
| Verification and quality score | – | – | – | ✔ own jobs only |
| Invoices, payments, voids | ✔ | read | ✔ | – |
| Job costs (write / void) | ✔ | read | ✔ | – |
| Financial reports (receivables, margin, revenue) | ✔ | – | ✔ | – |
| Operational reports (funnel, turnaround, rework, utilisation) | ✔ | ✔ | ✔ | – |

Customer and worker access (unchanged): customers see only their account's records (never drafts, internal notes, checklists, materials, costs or inspection findings; before/after photos only after verification); workers see only jobs they are currently assigned to (price-free scope, site snapshot, checklist, materials, evidence) and never quotations, invoices, costs, feedback or other customers' data. Employees and outsourced workers use the same screens.

## Decisions received outside the portal
Ops admins can record a customer's approval/rejection of a quotation version or change order that arrived by WhatsApp, phone or signed copy (`record_quotation_response`, `record_change_order_response`). Safeguards: a note of at least 10 characters (who, channel, when) is mandatory; the row stores `response_channel = 'admin_recorded'` and the admin as `responded_by`; a customer-visible timeline note says it was recorded on their behalf; and the audit log captures the actor. The customer's own `respond_to_*` functions remain customer-only, so the two paths cannot be confused. Optional later: attach the WhatsApp screenshot to the `documents` bucket as evidence.

## Storage buckets (all private; access via short-lived signed URLs)
| Bucket | Path | Read | Write |
|---|---|---|---|
| `request-attachments` | `{account_id}/{request_id}/{file}` | account members, admin | account members while request is draft/info_requested; ops admin |
| `inspection-photos` | `{inspection_id}/{file}` | back office, the inspector | the inspector while the inspection is scheduled; no update/delete |
| `job-photos` | `{job_id}/{file}` | admin, assigned worker, job supervisor, owning customer for before/after of **verified** jobs | assigned worker while job in progress/rework. **No update/delete policy** (immutable) |
| `documents` | `{account_id}/{file}` | account members, back office | finance admin |
Limits: 10 MB, MIME allow-lists (JPEG/PNG/WebP/PDF).

## Session and hardening checklist
- Admin (Next.js): `@supabase/ssr` cookie sessions, middleware refresh, layouts call `getUser()`. Mobile: session in `expo-secure-store`.
- MFA (TOTP) required for super/ops/finance admins and supervisors; step-up before voiding invoices/payments (later).
- Rate-limit auth endpoints; generic error messages on login; password policy ≥ 10 chars + leaked-password check.
- Service-role key only in Edge Functions and Next.js server code (`server-only`) — never in the mobile app or `NEXT_PUBLIC_*`.
- Never trust the UI: every rule above is enforced in Postgres and covered by `supabase/tests/`.
