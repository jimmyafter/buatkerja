-- ============================================================================
-- 001 Foundations: private schema, enums, document numbering, shared triggers
-- ============================================================================

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Enumerations (statuses are enums so invalid states are unrepresentable)
-- ---------------------------------------------------------------------------
create type public.app_role            as enum ('customer', 'worker', 'supervisor', 'admin');
create type public.account_type        as enum ('individual', 'business');
create type public.member_role         as enum ('owner', 'member');
create type public.property_type       as enum ('landed_house', 'condominium', 'commercial', 'industrial', 'other');
create type public.my_state            as enum (
  'johor','kedah','kelantan','melaka','negeri_sembilan','pahang','perak','perlis',
  'pulau_pinang','sabah','sarawak','selangor','terengganu',
  'kuala_lumpur','labuan','putrajaya');
create type public.urgency             as enum ('normal', 'urgent');

create type public.request_status      as enum (
  'draft','submitted','under_review','info_requested','quoted','approved',
  'booked','in_progress','completed','invoiced','closed','cancelled','rejected');
create type public.quote_status        as enum (
  'draft','sent','approved','rejected','superseded','withdrawn','expired');
create type public.booking_status      as enum ('confirmed', 'completed', 'cancelled');
create type public.job_status          as enum (
  'scheduled','in_progress','pending_verification','rework_required','verified','cancelled');

create type public.worker_type         as enum ('employee', 'outsourced');
create type public.approval_status     as enum ('pending', 'approved', 'suspended', 'rejected');
create type public.assignment_role     as enum ('lead', 'crew');
create type public.photo_kind          as enum ('before', 'progress', 'after', 'issue');
create type public.verification_result as enum ('passed', 'failed');

create type public.co_status           as enum ('draft', 'sent', 'approved', 'rejected', 'withdrawn');
create type public.cor_status          as enum ('open', 'converted', 'dismissed');

create type public.invoice_status      as enum ('draft', 'issued', 'partially_paid', 'paid', 'void');
create type public.invoice_item_source as enum ('quotation_item', 'change_order_item', 'adjustment');
create type public.payment_method      as enum ('bank_transfer', 'duitnow_qr', 'fpx', 'card', 'cash', 'cheque');

-- ---------------------------------------------------------------------------
-- Human-readable document numbers (SR-2026-00001, QT-..., JB-..., INV-...)
-- Row-locked counter per (prefix, year) => no duplicates under concurrency.
-- ---------------------------------------------------------------------------
create table public.doc_counters (
  prefix     text not null,
  year       int  not null,
  last_value int  not null default 0,
  primary key (prefix, year)
);

create function private.next_ref(p_prefix text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_year int := extract(year from (now() at time zone 'Asia/Kuala_Lumpur'))::int;
  v_next int;
begin
  insert into public.doc_counters as c (prefix, year, last_value)
  values (p_prefix, v_year, 1)
  on conflict (prefix, year) do update set last_value = c.last_value + 1
  returning last_value into v_next;
  return p_prefix || '-' || v_year || '-' || lpad(v_next::text, 5, '0');
end;
$$;

create function private.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- True only for statements issued directly by a browser/API client
-- (PostgREST runs as `authenticated`/`anon`). Inside SECURITY DEFINER RPCs the
-- current_user is the function owner, so this is false there. Guard triggers
-- use it to make "status changes only via RPC" a database-level rule.
create function private.is_direct_client()
returns boolean
language sql
stable
as $$ select current_user in ('authenticated', 'anon') $$;

create function private.forbid_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception '% on % is not allowed: table is append-only', tg_op, tg_table_name
    using errcode = 'restrict_violation';
end;
$$;
