-- ============================================================================
-- 005 Workforce, bookings and job delivery
-- ============================================================================

-- Company-approved outsourcing companies. Never public, never self-registered.
create table public.outsource_partners (
  id                uuid primary key default gen_random_uuid(),
  name              text not null,
  ssm_registration_no text not null unique,
  contact_name      text,
  contact_phone     text,
  approval_status   public.approval_status not null default 'pending',
  approved_by       uuid references public.profiles(id),
  approved_at       timestamptz,
  contract_expires_on date,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (approval_status <> 'approved' or (approved_by is not null and approved_at is not null))
);

create table public.workers (
  id              uuid primary key default gen_random_uuid(),
  profile_id      uuid not null unique references public.profiles(id) on delete restrict,
  worker_type     public.worker_type not null,
  partner_id      uuid references public.outsource_partners(id),
  employee_no     text unique,
  approval_status public.approval_status not null default 'pending',
  approved_by     uuid references public.profiles(id),
  approved_at     timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check ((worker_type = 'outsourced') = (partner_id is not null)),
  check (approval_status <> 'approved' or (approved_by is not null and approved_at is not null))
);

create table public.worker_categories (
  worker_id   uuid not null references public.workers(id) on delete cascade,
  category_id uuid not null references public.service_categories(id) on delete cascade,
  primary key (worker_id, category_id)
);

-- A booking is the commercial/scheduling commitment made to the customer.
-- Created only from an APPROVED quotation version.
create table public.bookings (
  id                   uuid primary key default gen_random_uuid(),
  booking_no           text not null unique,
  request_id           uuid not null,
  account_id           uuid not null,
  quotation_version_id uuid not null references public.quotation_versions(id),
  scheduled_start      timestamptz not null,
  scheduled_end        timestamptz not null,
  status               public.booking_status not null default 'confirmed',
  confirmed_by         uuid references public.profiles(id) on delete set null,
  confirmed_at         timestamptz not null default now(),
  cancelled_reason     text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (id, account_id),
  foreign key (request_id, account_id) references public.service_requests (id, account_id),
  check (scheduled_end > scheduled_start),
  check (status <> 'cancelled' or cancelled_reason is not null)
);
create unique index bookings_one_live_per_request on public.bookings (request_id) where status <> 'cancelled';
create unique index bookings_one_live_per_version on public.bookings (quotation_version_id) where status <> 'cancelled';

-- A job is the delivery record workers see. It deliberately carries NO prices
-- and a snapshot of the site details, so workers never need access to
-- customer accounts, properties, quotations or invoices.
create table public.jobs (
  id                 uuid primary key default gen_random_uuid(),
  job_no             text not null unique,
  booking_id         uuid not null unique,
  request_id         uuid not null,
  account_id         uuid not null,
  status             public.job_status not null default 'scheduled',
  supervisor_id      uuid not null references public.profiles(id),
  scope_of_work      text not null,
  site_address       text not null,
  site_contact_name  text,
  site_contact_phone text,
  site_access_notes  text,
  started_at         timestamptz,
  submitted_at       timestamptz,
  verified_at        timestamptz,
  cancelled_reason   text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (id, account_id),
  foreign key (booking_id, account_id) references public.bookings (id, account_id),
  foreign key (request_id, account_id) references public.service_requests (id, account_id),
  check (status <> 'cancelled' or cancelled_reason is not null)
);
create index jobs_supervisor_idx on public.jobs (supervisor_id, status);
create index jobs_account_idx    on public.jobs (account_id);

create table public.job_assignments (
  id            uuid primary key default gen_random_uuid(),
  job_id        uuid not null references public.jobs(id) on delete cascade,
  worker_id     uuid not null references public.workers(id),
  assignment_role public.assignment_role not null default 'crew',
  assigned_by   uuid not null references public.profiles(id),
  assigned_at   timestamptz not null default now(),
  released_at   timestamptz,
  release_reason text,
  check (released_at is null or release_reason is not null)
);
create unique index ja_one_active_per_worker on public.job_assignments (job_id, worker_id) where released_at is null;
create unique index ja_one_active_lead       on public.job_assignments (job_id) where assignment_role = 'lead' and released_at is null;
create index ja_worker_idx on public.job_assignments (worker_id) where released_at is null;

-- Append-only evidence trail ---------------------------------------------------
create table public.job_progress_updates (
  id           uuid primary key default gen_random_uuid(),
  job_id       uuid not null references public.jobs(id) on delete cascade,
  author_id    uuid not null references public.profiles(id),
  note         text not null check (length(btrim(note)) > 0),
  progress_pct smallint check (progress_pct between 0 and 100),
  created_at   timestamptz not null default now()
);
create index jpu_job_idx on public.job_progress_updates (job_id, created_at);

create table public.job_photos (
  id                 uuid primary key default gen_random_uuid(),
  job_id             uuid not null references public.jobs(id) on delete cascade,
  progress_update_id uuid references public.job_progress_updates(id),
  kind               public.photo_kind not null,
  storage_path       text not null unique,
  caption            text,
  taken_at           timestamptz not null default now(),
  uploaded_by        uuid not null references public.profiles(id),
  created_at         timestamptz not null default now(),
  check (storage_path like job_id::text || '/%')      -- storage layout: {job_id}/{file}
);
create index jp_job_idx on public.job_photos (job_id, kind);

create table public.job_verifications (
  id            uuid primary key default gen_random_uuid(),
  job_id        uuid not null references public.jobs(id) on delete cascade,
  supervisor_id uuid not null references public.profiles(id),
  result        public.verification_result not null,
  notes         text,
  verified_at   timestamptz not null default now(),
  check (result = 'passed' or length(btrim(coalesce(notes, ''))) > 0)
);
create index jv_job_idx on public.job_verifications (job_id, verified_at);
