-- ============================================================================
-- 006 Change orders (additional chargeable work), invoicing, payments
-- ============================================================================

-- Workers can only FLAG extra work (no prices). Admin converts it to a change order.
create table public.change_order_requests (
  id           uuid primary key default gen_random_uuid(),
  job_id       uuid not null references public.jobs(id) on delete cascade,
  raised_by    uuid not null references public.profiles(id),
  description  text not null check (length(btrim(description)) > 0),
  status       public.cor_status not null default 'open',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index cor_job_idx on public.change_order_requests (job_id);

create table public.change_orders (
  id            uuid primary key default gen_random_uuid(),
  co_no         text not null unique,
  job_id        uuid not null,
  account_id    uuid not null,
  source_request_id uuid references public.change_order_requests(id),
  title         text not null check (length(btrim(title)) > 0),
  description   text not null default '',
  status        public.co_status not null default 'draft',
  subtotal      numeric(12,2) not null default 0,
  tax_amount    numeric(12,2) not null default 0,
  total         numeric(12,2) not null default 0,
  created_by    uuid references public.profiles(id) on delete set null,
  sent_at       timestamptz,
  responded_at  timestamptz,
  responded_by  uuid references public.profiles(id) on delete set null,
  response_note text,
  response_channel text check (response_channel in ('portal','admin_recorded')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (id, account_id),
  foreign key (job_id, account_id) references public.jobs (id, account_id),
  check (total = subtotal + tax_amount),
  check (status in ('draft') or sent_at is not null),
  check (status not in ('approved','rejected') or (responded_at is not null and responded_by is not null and response_channel is not null)),
  check (response_channel is distinct from 'admin_recorded' or length(btrim(coalesce(response_note, ''))) >= 10)
);
create index co_job_idx on public.change_orders (job_id);

alter table public.change_order_requests
  add column change_order_id uuid references public.change_orders(id);

create table public.change_order_items (
  id              uuid primary key default gen_random_uuid(),
  change_order_id uuid not null references public.change_orders(id) on delete cascade,
  position        int  not null check (position > 0),
  description     text not null check (length(btrim(description)) > 0),
  unit            text not null default 'unit',
  quantity        numeric(10,2) not null check (quantity > 0),
  unit_price      numeric(12,2) not null,
  tax_rate        numeric(5,2)  not null default 0 check (tax_rate between 0 and 100),
  line_total      numeric(12,2) generated always as (round(quantity * unit_price, 2)) stored,
  tax_amount      numeric(12,2) generated always as (round(round(quantity * unit_price, 2) * tax_rate / 100, 2)) stored,
  unique (change_order_id, position)
);

-- Invoices --------------------------------------------------------------------
create table public.invoices (
  id            uuid primary key default gen_random_uuid(),
  invoice_no    text unique,                       -- assigned at issue time only
  job_id        uuid not null,
  request_id    uuid not null,
  account_id    uuid not null,
  status        public.invoice_status not null default 'draft',
  issue_date    date,
  due_date      date,
  subtotal      numeric(12,2) not null default 0,
  tax_amount    numeric(12,2) not null default 0,
  total         numeric(12,2) not null default 0,
  amount_paid   numeric(12,2) not null default 0, -- maintained by trigger from payments
  issued_by     uuid references public.profiles(id) on delete set null,
  void_reason   text,
  created_by    uuid references public.profiles(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (id, account_id),
  foreign key (job_id, account_id)     references public.jobs (id, account_id),
  foreign key (request_id, account_id) references public.service_requests (id, account_id),
  check (total = subtotal + tax_amount),
  check (amount_paid >= 0 and amount_paid <= total),
  check (status in ('draft','void') or (invoice_no is not null and issue_date is not null and due_date is not null)),
  check (status <> 'void' or void_reason is not null),
  check (due_date is null or issue_date is null or due_date >= issue_date)
);
create unique index invoices_one_live_per_job on public.invoices (job_id) where status <> 'void';

create table public.invoice_items (
  id          uuid primary key default gen_random_uuid(),
  invoice_id  uuid not null references public.invoices(id) on delete cascade,
  position    int  not null check (position > 0),
  description text not null check (length(btrim(description)) > 0),
  unit        text not null default 'unit',
  quantity    numeric(10,2) not null check (quantity > 0),
  unit_price  numeric(12,2) not null,
  tax_rate    numeric(5,2)  not null default 0 check (tax_rate between 0 and 100),
  line_total  numeric(12,2) generated always as (round(quantity * unit_price, 2)) stored,
  tax_amount  numeric(12,2) generated always as (round(round(quantity * unit_price, 2) * tax_rate / 100, 2)) stored,
  source_type public.invoice_item_source not null,
  source_id   uuid,
  unique (invoice_id, position),
  check ((source_type = 'adjustment') = (source_id is null))
);
-- an approved line can be billed at most once on one invoice
create unique index invoice_items_source_once on public.invoice_items (invoice_id, source_type, source_id)
  where source_id is not null;

-- Payments are append-only; mistakes are voided, never deleted.
create table public.payments (
  id           uuid primary key default gen_random_uuid(),
  invoice_id   uuid not null,
  account_id   uuid not null,
  amount       numeric(12,2) not null check (amount > 0),
  method       public.payment_method not null,
  reference    text,
  paid_at      timestamptz not null default now(),
  notes        text,
  recorded_by  uuid not null references public.profiles(id),
  created_at   timestamptz not null default now(),
  voided_at    timestamptz,
  voided_by    uuid references public.profiles(id),
  void_reason  text,
  foreign key (invoice_id, account_id) references public.invoices (id, account_id),
  check ((voided_at is null) = (voided_by is null)),
  check (voided_at is null or void_reason is not null)
);
create index payments_invoice_idx on public.payments (invoice_id);
