-- ============================================================================
-- 002 Identity: profiles, customer accounts, members, properties
-- ============================================================================

-- One row per auth user. Role lives HERE (never in user-editable metadata).
create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  role       public.app_role not null default 'customer',
  full_name  text not null default '',
  email      text not null,
  phone      text check (phone is null or phone ~ '^\+?[0-9 -]{8,16}$'),
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index profiles_email_key on public.profiles (lower(email));
create index profiles_role_idx on public.profiles (role) where is_active;

-- A customer account is the billing/ownership unit: a homeowner (individual)
-- or a business / property manager with several user logins.
create table public.customer_accounts (
  id                  uuid primary key default gen_random_uuid(),
  account_type        public.account_type not null,
  display_name        text not null check (length(btrim(display_name)) > 0),
  company_name        text,
  ssm_registration_no text,
  billing_address     text,
  billing_email       text,
  created_by          uuid references public.profiles(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint business_needs_company check (account_type = 'individual' or company_name is not null)
);

create table public.customer_members (
  account_id  uuid not null references public.customer_accounts(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  member_role public.member_role not null default 'member',
  created_at  timestamptz not null default now(),
  primary key (account_id, user_id)
);
create index customer_members_user_idx on public.customer_members (user_id);

create table public.properties (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid not null references public.customer_accounts(id) on delete cascade,
  label         text not null check (length(btrim(label)) > 0),
  property_type public.property_type not null default 'landed_house',
  address_line1 text not null,
  address_line2 text,
  city          text not null,
  state         public.my_state not null,
  postcode      text not null check (postcode ~ '^[0-9]{5}$'),
  access_notes  text,
  archived_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (id, account_id)            -- target for composite FKs (account consistency)
);
create index properties_account_idx on public.properties (account_id) where archived_at is null;

-- Staff-only free text. Kept out of customer-visible tables on purpose, because
-- RLS is row-level: a private column on a customer-readable row would leak.
create table public.internal_notes (
  id          uuid primary key default gen_random_uuid(),
  entity_type text not null check (entity_type in
                ('service_request','quotation','booking','job','invoice','customer_account','worker')),
  entity_id   uuid not null,
  body        text not null check (length(btrim(body)) > 0),
  author_id   uuid not null references public.profiles(id),
  created_at  timestamptz not null default now()
);
create index internal_notes_entity_idx on public.internal_notes (entity_type, entity_id);
