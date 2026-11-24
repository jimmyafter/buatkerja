# 3. Authentication and role permissions

## Identity model
- **Supabase Auth** handles credentials, sessions, email confirmation, password reset and MFA.
- On sign-up a trigger creates `profiles(id = auth.users.id, role = 'customer')`. **Role is never read from client-supplied metadata**; it can only be changed by an admin (or the service role), and admins cannot change their own role (lock-out/escalation guard).
- `is_active = false` (deactivation) makes every helper return "no access" immediately — RLS denies even with a still-valid JWT.
- Roles: `customer`, `worker`, `supervisor`, `admin`. A supervisor is a staff profile named on a job (`jobs.supervisor_id`); supervisors cannot also be workers (different profile role), which gives segregation of duties for verification.

## Onboarding flows
| Who | How |
|---|---|
| Customer | Public sign-up → confirm email → `create_customer_account()` (individual/business, becomes owner) → add property → request. |
| Business team member | Admin adds a membership (owner-invite UI in a later module). |
| Worker / supervisor / admin | **No public sign-up.** Admin server action (service role, `server-only`) invites the user by email, sets `profiles.role`, creates `workers` row (+ `outsource_partners` for outsourced). Worker must be set `approved` before they can be assigned or see any job. |
| Outsourced partner | Admin creates + approves partner (with contract expiry). Expiry/suspension automatically revokes the partner's workers' access and blocks new assignment. |

## Permission matrix (R read, C create, U update, – none; "RPC" = only via workflow function)
| Resource | Customer | Worker | Supervisor | Admin |
|---|---|---|---|---|
| Own profile | R/U (no role/email/active) | same | same | R/U all |
| Customer account / members | R own; U billing (owner) | – | – | R/C/U |
| Properties | R/C/U own account | – | – | R/C/U/D |
| Service request | R own; C draft; U draft; RPC submit/cancel | – | – | R/C/U content; RPC review |
| Request attachments | R/C own while editable | – | – | R/C |
| Request timeline | R customer-visible | – | – | R/C notes |
| Internal notes | – | – | – | R/C |
| Quotation / versions / items | R **non-draft** own; RPC approve/reject (own decision) | – | – | R/C/U drafts; RPC send/withdraw/revise |
| Booking | R own | – | – | R; U reschedule; RPC confirm/cancel |
| Job | R own | R **currently assigned** | R **own supervised** | R/U |
| Job assignments | – | R own | R own jobs | R/C/U (approved workers only) |
| Progress updates | – | R/C on assigned active jobs | R/C own jobs | R/C |
| Job photos | R before/after **after verification** | R/C assigned (write-once) | R | R |
| Verifications | – | R (to see rework notes) | R; RPC verify | R |
| Extra-work flags | – | R own, C on assigned | R own jobs | R/U dismiss; RPC convert |
| Change orders / items | R **non-draft** own; RPC approve/reject (own decision) | – | – | R/C/U drafts; RPC send/withdraw |
| Invoices / lines | R **issued** own | – | – | R; RPC draft/issue/void; adjustment lines |
| Payments | R own | – | – | R/C (append-only); RPC void |
| Audit log | – | – | – | R (append-only for everyone) |
| Partners / workers / categories | R active categories (also anon) | R own worker row | R workers on own jobs | R/C/U |

## Decisions received outside the portal
Admins can record a customer's approval/rejection of a quotation version or change order that arrived by WhatsApp, phone or signed copy (`record_quotation_response`, `record_change_order_response`). Safeguards: a note of at least 10 characters (who, channel, when) is mandatory; the row stores `response_channel = 'admin_recorded'` and the admin as `responded_by`; a customer-visible timeline note says it was recorded on their behalf; and the audit log captures the actor. The customer's own `respond_to_*` functions remain customer-only, so the two paths cannot be confused. Optional later: attach the WhatsApp screenshot to the `documents` bucket as evidence.

## Storage buckets (all private; access via short-lived signed URLs)
| Bucket | Path | Read | Write |
|---|---|---|---|
| `request-attachments` | `{account_id}/{request_id}/{file}` | account members, admin | account members while request is draft/info_requested; admin |
| `job-photos` | `{job_id}/{file}` | admin, assigned worker, job supervisor, owning customer for before/after of **verified** jobs | assigned worker while job in progress/rework. **No update/delete policy** (immutable) |
| `documents` | `{account_id}/{file}` | account members, admin | admin |
Limits: 10 MB, MIME allow-lists (JPEG/PNG/WebP/PDF).

## Session and hardening checklist
- `@supabase/ssr` cookie sessions; middleware refreshes tokens; layouts call `getUser()` (not `getSession()`) server-side.
- MFA (TOTP) required for `admin` and `supervisor`; step-up before voiding invoices/payments (later).
- Rate-limit auth endpoints; generic error messages on login; password policy ≥ 10 chars + leaked-password check.
- Service-role key only in `lib/supabase/admin.ts` (`import 'server-only'`) — never in client bundles or `NEXT_PUBLIC_*`.
- Never trust the UI: every rule above is enforced in Postgres and covered by `supabase/tests/01_workflow_and_rls.sql`.
