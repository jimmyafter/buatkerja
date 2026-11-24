-- ============================================================================
-- 003 Service requests
-- ============================================================================

create table public.service_categories (
  id         uuid primary key default gen_random_uuid(),
  slug       text not null unique check (slug ~ '^[a-z0-9-]+$'),
  name       text not null,
  sort_order int  not null default 0,
  is_active  boolean not null default true
);

create table public.service_requests (
  id              uuid primary key default gen_random_uuid(),
  request_no      text not null unique,
  account_id      uuid not null references public.customer_accounts(id),
  property_id     uuid not null,
  category_id     uuid not null references public.service_categories(id),
  title           text not null check (length(btrim(title)) between 3 and 120),
  description     text not null default '',
  urgency         public.urgency not null default 'normal',
  preferred_from  date,
  preferred_to    date,
  contact_name    text,
  contact_phone   text check (contact_phone is null or contact_phone ~ '^\+?[0-9 -]{8,16}$'),
  status          public.request_status not null default 'draft',
  submitted_by    uuid references public.profiles(id) on delete set null,
  submitted_at    timestamptz,
  cancelled_reason text,
  rejected_reason  text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (id, account_id),
  -- the property MUST belong to the same account as the request
  foreign key (property_id, account_id) references public.properties (id, account_id),
  check (preferred_to is null or preferred_from is null or preferred_to >= preferred_from),
  check (status = 'draft' or submitted_at is not null),
  check (status <> 'cancelled' or cancelled_reason is not null),
  check (status <> 'rejected'  or rejected_reason  is not null)
);
create index service_requests_account_idx on public.service_requests (account_id, created_at desc);
create index service_requests_status_idx  on public.service_requests (status, created_at);

create table public.service_request_attachments (
  id           uuid primary key default gen_random_uuid(),
  request_id   uuid not null,
  account_id   uuid not null,
  storage_path text not null unique,
  file_name    text not null,
  mime_type    text not null check (mime_type in ('image/jpeg','image/png','image/webp','application/pdf')),
  size_bytes   int  not null check (size_bytes > 0 and size_bytes <= 10485760),
  uploaded_by  uuid not null references public.profiles(id),
  created_at   timestamptz not null default now(),
  foreign key (request_id, account_id) references public.service_requests (id, account_id) on delete cascade,
  -- storage layout: {account_id}/{request_id}/{file}
  check (storage_path like account_id::text || '/' || request_id::text || '/%')
);
create index sra_request_idx on public.service_request_attachments (request_id);

-- Timeline. Rows are written by triggers/RPCs; customers see visible rows only.
create table public.service_request_events (
  id                  bigint generated always as identity primary key,
  request_id          uuid not null references public.service_requests(id) on delete cascade,
  event_type          text not null check (event_type in ('status_change','note')),
  from_status         public.request_status,
  to_status           public.request_status,
  note                text,
  visible_to_customer boolean not null default true,
  actor_id            uuid references public.profiles(id) on delete set null,
  created_at          timestamptz not null default now()
);
create index sre_request_idx on public.service_request_events (request_id, created_at);
