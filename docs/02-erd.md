# 2. Entity relationship diagram

```mermaid
erDiagram
  PROFILES ||--o{ CUSTOMER_MEMBERS : "is member"
  CUSTOMER_ACCOUNTS ||--o{ CUSTOMER_MEMBERS : has
  CUSTOMER_ACCOUNTS ||--o{ PROPERTIES : owns
  CUSTOMER_ACCOUNTS ||--o{ SERVICE_REQUESTS : raises
  PROPERTIES ||--o{ SERVICE_REQUESTS : "site of (same account)"
  SERVICE_CATEGORIES ||--o{ SERVICE_REQUESTS : classifies
  SERVICE_REQUESTS ||--o{ SERVICE_REQUEST_ATTACHMENTS : has
  SERVICE_REQUESTS ||--o{ SERVICE_REQUEST_EVENTS : timeline
  SERVICE_REQUESTS ||--|| QUOTATIONS : "quoted by"
  QUOTATIONS ||--|{ QUOTATION_VERSIONS : "v1..vn (frozen once sent)"
  QUOTATION_VERSIONS ||--|{ QUOTATION_ITEMS : lines
  QUOTATION_VERSIONS ||--o| BOOKINGS : "approved version books"
  SERVICE_REQUESTS ||--o{ BOOKINGS : "scheduled as"
  BOOKINGS ||--|| JOBS : "delivered as"
  PROFILES ||--o{ JOBS : "supervises"
  JOBS ||--o{ JOB_ASSIGNMENTS : staffed
  WORKERS ||--o{ JOB_ASSIGNMENTS : "assigned (approved only)"
  PROFILES ||--o| WORKERS : "is"
  OUTSOURCE_PARTNERS ||--o{ WORKERS : employs
  WORKERS ||--o{ WORKER_CATEGORIES : skilled
  SERVICE_CATEGORIES ||--o{ WORKER_CATEGORIES : ""
  JOBS ||--o{ JOB_PROGRESS_UPDATES : "append-only"
  JOBS ||--o{ JOB_PHOTOS : "append-only"
  JOBS ||--o{ JOB_VERIFICATIONS : "append-only"
  JOBS ||--o{ CHANGE_ORDER_REQUESTS : "worker flags"
  JOBS ||--o{ CHANGE_ORDERS : "extra work"
  CHANGE_ORDER_REQUESTS |o--o| CHANGE_ORDERS : "converted to"
  CHANGE_ORDERS ||--|{ CHANGE_ORDER_ITEMS : lines
  JOBS ||--o| INVOICES : "billed by (one live)"
  INVOICES ||--|{ INVOICE_ITEMS : "mirror approved lines"
  INVOICES ||--o{ PAYMENTS : "ledger"
  PROFILES ||--o{ AUDIT_LOGS : "actor"

  PROFILES { uuid id PK "= auth.users.id" app_role role "customer|worker|supervisor|admin" text full_name text email bool is_active }
  CUSTOMER_ACCOUNTS { uuid id PK account_type type text display_name text company_name }
  CUSTOMER_MEMBERS { uuid account_id PK uuid user_id PK member_role role }
  PROPERTIES { uuid id PK uuid account_id FK text postcode my_state state }
  SERVICE_REQUESTS { uuid id PK text request_no UK uuid account_id FK request_status status text title }
  QUOTATIONS { uuid id PK text quote_no UK uuid request_id UK }
  QUOTATION_VERSIONS { uuid id PK int version_no quote_status status date valid_until numeric total "trigger-computed" }
  QUOTATION_ITEMS { uuid id PK numeric quantity numeric unit_price numeric tax_rate numeric line_total "generated" }
  BOOKINGS { uuid id PK text booking_no UK uuid quotation_version_id FK timestamptz scheduled_start booking_status status }
  JOBS { uuid id PK text job_no UK uuid supervisor_id FK job_status status text scope_of_work "no prices" text site_address "snapshot" }
  WORKERS { uuid id PK worker_type type approval_status approval uuid partner_id FK }
  OUTSOURCE_PARTNERS { uuid id PK text ssm_registration_no UK approval_status approval date contract_expires_on }
  JOB_ASSIGNMENTS { uuid id PK uuid job_id FK uuid worker_id FK assignment_role role timestamptz released_at }
  JOB_PHOTOS { uuid id PK photo_kind kind text storage_path UK }
  CHANGE_ORDERS { uuid id PK text co_no UK co_status status numeric total }
  INVOICES { uuid id PK text invoice_no UK "assigned at issue" invoice_status status numeric total numeric amount_paid }
  PAYMENTS { uuid id PK numeric amount payment_method method timestamptz voided_at }
  AUDIT_LOGS { bigint id PK text table_name text entity_id jsonb old_data jsonb new_data }
  INTERNAL_NOTES { uuid id PK text entity_type uuid entity_id text body }
```

## Integrity features worth noting
- **Composite FKs** `(child_id, account_id) → parent(id, account_id)` on requests, quotations, bookings, jobs, change orders, invoices, payments, attachments: cross-account links are impossible.
- **Partial unique indexes** encode business rules: one draft / one live offer / one approved version per quotation; one live booking per request; one live invoice per job; one active lead per job; one active assignment per worker per job.
- **Generated columns** for line totals and line tax (no rounding drift between quotation → invoice).
- `doc_counters` (numbering) and `audit_logs` are not shown; neither is reachable by clients except admin read of audit.
