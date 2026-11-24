-- ============================================================================
-- 004 Quotations with immutable version history
--   quotations          : one header per request
--   quotation_versions  : v1, v2, ... ; content frozen once sent
--   quotation_items     : priced lines per version (tax per line)
-- ============================================================================

create table public.quotations (
  id         uuid primary key default gen_random_uuid(),
  quote_no   text not null unique,
  request_id uuid not null unique,                -- one quotation per request; revisions = versions
  account_id uuid not null,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (request_id, account_id) references public.service_requests (id, account_id)
);

create table public.quotation_versions (
  id             uuid primary key default gen_random_uuid(),
  quotation_id   uuid not null references public.quotations(id) on delete cascade,
  version_no     int  not null check (version_no > 0),
  status         public.quote_status not null default 'draft',
  valid_until    date,
  scope_summary  text not null default '',
  terms          text not null default '',
  -- totals are maintained by trigger from the items; never trusted from clients
  subtotal       numeric(12,2) not null default 0,
  tax_amount     numeric(12,2) not null default 0,
  total          numeric(12,2) not null default 0,
  created_by     uuid references public.profiles(id) on delete set null,
  sent_at        timestamptz,
  sent_by        uuid references public.profiles(id) on delete set null,
  responded_at   timestamptz,
  responded_by   uuid references public.profiles(id) on delete set null,
  response_note  text,
  response_channel text check (response_channel in ('portal','admin_recorded')),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (quotation_id, version_no),
  check (total = subtotal + tax_amount),
  check (status = 'draft' or sent_at is not null),
  check (status not in ('approved','rejected') or (responded_at is not null and responded_by is not null and response_channel is not null)),
  -- a decision recorded by staff on the customer's behalf must say how it was received
  check (response_channel is distinct from 'admin_recorded' or length(btrim(coalesce(response_note, ''))) >= 10)
);
-- At most one working draft, one live offer, one accepted version per quotation.
create unique index qv_one_draft    on public.quotation_versions (quotation_id) where status = 'draft';
create unique index qv_one_sent     on public.quotation_versions (quotation_id) where status = 'sent';
create unique index qv_one_approved on public.quotation_versions (quotation_id) where status = 'approved';

create table public.quotation_items (
  id          uuid primary key default gen_random_uuid(),
  version_id  uuid not null references public.quotation_versions(id) on delete cascade,
  position    int  not null check (position > 0),
  description text not null check (length(btrim(description)) > 0),
  unit        text not null default 'unit',
  quantity    numeric(10,2) not null check (quantity > 0),
  unit_price  numeric(12,2) not null,             -- may be negative for discount lines
  tax_rate    numeric(5,2)  not null default 0 check (tax_rate between 0 and 100),
  line_total  numeric(12,2) generated always as (round(quantity * unit_price, 2)) stored,
  tax_amount  numeric(12,2) generated always as (round(round(quantity * unit_price, 2) * tax_rate / 100, 2)) stored,
  unique (version_id, position)
);
