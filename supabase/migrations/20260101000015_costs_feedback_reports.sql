-- ============================================================================
-- 015 Job costs, quality score, customer feedback, settings, reports
-- ============================================================================

-- Quality check score recorded with the supervisor's verification
alter table public.job_verifications
  add column quality_score smallint check (quality_score between 1 and 5);

-- Job costs: append-only ledger (void, never edit) --------------------------------------
create type public.cost_type as enum ('labour', 'material', 'subcontract', 'other');

create table public.job_cost_entries (
  id          uuid primary key default gen_random_uuid(),
  job_id      uuid not null references public.jobs(id),
  cost_type   public.cost_type not null,
  description text not null check (length(btrim(description)) > 0),
  amount      numeric(12,2) not null check (amount > 0),
  partner_id  uuid references public.outsource_partners(id),
  material_id uuid,
  incurred_on date not null default private.today_my(),
  recorded_by uuid not null references public.profiles(id),
  created_at  timestamptz not null default now(),
  voided_at   timestamptz,
  voided_by   uuid references public.profiles(id),
  void_reason text,
  foreign key (material_id, job_id) references public.job_materials (id, job_id),
  check ((voided_at is null) = (voided_by is null)),
  check (voided_at is null or void_reason is not null)
);
create index job_cost_job_idx on public.job_cost_entries (job_id);

create function private.job_cost_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'cost entries cannot be deleted; void them'; end if;
  if tg_op = 'INSERT' then
    if (select status from public.jobs where id = new.job_id) = 'cancelled' then
      raise exception 'cannot record costs against a cancelled job';
    end if;
    new.voided_at := null; new.voided_by := null; new.void_reason := null;
    if (select auth.uid()) is not null then new.recorded_by := (select auth.uid()); end if;
    return new;
  end if;
  if old.voided_at is not null then raise exception 'voided cost entries are immutable'; end if;
  if (new.job_id, new.cost_type, new.description, new.amount, new.partner_id, new.material_id,
      new.incurred_on, new.recorded_by)
     is distinct from
     (old.job_id, old.cost_type, old.description, old.amount, old.partner_id, old.material_id,
      old.incurred_on, old.recorded_by) then
    raise exception 'cost entries are immutable; void and re-record instead';
  end if;
  if new.voided_at is not null then new.voided_at := now(); end if;
  return new;
end $$;
create trigger job_cost_guard before insert or update or delete on public.job_cost_entries
  for each row execute function private.job_cost_guard();

create function public.void_job_cost(p_entry uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_role(array['finance_admin','super_admin']::public.app_role[]);
  if p_reason is null or length(btrim(p_reason)) < 3 then raise exception 'a reason is required'; end if;
  update public.job_cost_entries set voided_at = now(), voided_by = (select auth.uid()), void_reason = btrim(p_reason)
   where id = p_entry and voided_at is null;
  if not found then raise exception 'cost entry not found or already voided'; end if;
end $$;

-- Customer feedback (one per verified job) ------------------------------------------------
create table public.job_feedback (
  id           uuid primary key default gen_random_uuid(),
  job_id       uuid not null unique,
  account_id   uuid not null,
  rating       smallint not null check (rating between 1 and 5),
  comment      text,
  submitted_by uuid not null references public.profiles(id),
  created_at   timestamptz not null default now(),
  foreign key (job_id, account_id) references public.jobs (id, account_id)
);
create trigger job_feedback_immutable before update or delete on public.job_feedback
  for each row execute function private.forbid_mutation();

create function public.submit_job_feedback(p_job_id uuid, p_rating int, p_comment text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare j public.jobs;
begin
  perform private.require_role(array['customer']::public.app_role[]);
  select * into j from public.jobs where id = p_job_id;
  if not found or not private.is_account_member(j.account_id) then raise exception 'job not found' using errcode = 'P0002'; end if;
  if j.status <> 'verified' then raise exception 'feedback can be given once the work is completed'; end if;
  insert into public.job_feedback (job_id, account_id, rating, comment, submitted_by)
  values (j.id, j.account_id, p_rating, nullif(btrim(p_comment), ''), (select auth.uid()));
exception when unique_violation then raise exception 'feedback has already been submitted for this job';
end $$;

-- Settings (support contact details etc.) --------------------------------------------------
create table public.app_settings (
  key        text primary key,
  value      jsonb not null,
  is_public  boolean not null default false,
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);
-- Placeholders only: a super admin must fill these in before launch (empty = not configured).
insert into public.app_settings (key, value, is_public) values
  ('support.phone',    to_jsonb(''::text), true),
  ('support.whatsapp', to_jsonb(''::text), true),
  ('support.email',    to_jsonb(''::text), true),
  ('support.hours',    to_jsonb(''::text), true);

-- Audit + RLS + grants -----------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['job_cost_entries','job_feedback','app_settings'] loop
    execute format('create trigger audit_row after insert or update or delete on public.%I
                    for each row execute function private.audit_row()', t);
  end loop;
end $$;
alter table public.job_cost_entries enable row level security;
alter table public.job_feedback     enable row level security;
alter table public.app_settings     enable row level security;
grant select, insert         on public.job_cost_entries to authenticated;
grant select                 on public.job_feedback     to authenticated;
grant select                 on public.app_settings     to anon, authenticated;
grant insert, update, delete on public.app_settings     to authenticated;

create policy costs_select on public.job_cost_entries for select to authenticated
  using ((select private.is_back_office()));
create policy costs_finance_insert on public.job_cost_entries for insert to authenticated
  with check ((select private.is_finance()) and recorded_by = (select auth.uid()));
create policy feedback_select on public.job_feedback for select to authenticated
  using ((select private.is_back_office()) or (select private.is_account_member(account_id)));
create policy settings_read on public.app_settings for select to anon, authenticated
  using (is_public or (select private.is_back_office()));
create policy settings_super_write on public.app_settings for all to authenticated
  using ((select private.is_super_admin())) with check ((select private.is_super_admin()));

-- Reports (role-checked functions; financial ones are finance/super only) -----------------------------
create function public.report_receivables_ageing()
returns table (invoice_id uuid, invoice_no text, account_name text, due_date date, outstanding numeric, days_overdue int, bucket text)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_role(array['finance_admin','super_admin']::public.app_role[]);
  return query
  select i.id, i.invoice_no, a.display_name, i.due_date, i.total - i.amount_paid,
         greatest(private.today_my() - i.due_date, 0),
         case when i.due_date >= private.today_my() then 'current'
              when private.today_my() - i.due_date <= 30 then '1-30'
              when private.today_my() - i.due_date <= 60 then '31-60' else '61+' end
    from public.invoices i join public.customer_accounts a on a.id = i.account_id
   where i.status in ('issued', 'partially_paid')
   order by i.due_date;
end $$;

create function public.report_job_margin(p_from date, p_to date)
returns table (job_no text, verified_on date, revenue numeric, cost numeric, margin numeric, margin_pct numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_role(array['finance_admin','super_admin']::public.app_role[]);
  return query
  select j.job_no, (j.verified_at at time zone 'Asia/Kuala_Lumpur')::date,
         coalesce(i.subtotal, 0), coalesce(c.cost, 0), coalesce(i.subtotal, 0) - coalesce(c.cost, 0),
         case when coalesce(i.subtotal, 0) > 0
              then round((coalesce(i.subtotal, 0) - coalesce(c.cost, 0)) / i.subtotal * 100, 1) end
    from public.jobs j
    left join public.invoices i on i.job_id = j.id and i.status not in ('draft', 'void')
    left join (select job_id, sum(amount) cost from public.job_cost_entries where voided_at is null group by job_id) c
           on c.job_id = j.id
   where j.status = 'verified'
     and (j.verified_at at time zone 'Asia/Kuala_Lumpur')::date between p_from and p_to
   order by j.verified_at;
end $$;

create function public.report_revenue_monthly(p_from date, p_to date)
returns table (month date, invoiced numeric, collected numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_role(array['finance_admin','super_admin']::public.app_role[]);
  return query
  with inv as (select date_trunc('month', issue_date)::date m, sum(total) amt from public.invoices
                where status not in ('draft', 'void') and issue_date between p_from and p_to group by 1),
       pay as (select date_trunc('month', paid_at at time zone 'Asia/Kuala_Lumpur')::date m, sum(amount) amt
                 from public.payments where voided_at is null
                  and (paid_at at time zone 'Asia/Kuala_Lumpur')::date between p_from and p_to group by 1)
  select coalesce(inv.m, pay.m), coalesce(inv.amt, 0), coalesce(pay.amt, 0)
    from inv full join pay on pay.m = inv.m order by 1;
end $$;

create function public.report_ops_summary(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r jsonb;
begin
  perform private.require_role(array['ops_admin','finance_admin','super_admin']::public.app_role[]);
  select jsonb_build_object(
    'requests_by_status', coalesce((select jsonb_object_agg(status, n) from (
        select status, count(*) n from public.service_requests
         where (created_at at time zone 'Asia/Kuala_Lumpur')::date between p_from and p_to group by status) s), '{}'),
    'jobs_verified', (select count(*) from public.jobs where status = 'verified'
         and (verified_at at time zone 'Asia/Kuala_Lumpur')::date between p_from and p_to),
    'avg_days_submit_to_verified', (select round(avg(extract(epoch from (j.verified_at - r.submitted_at)) / 86400)::numeric, 1)
         from public.jobs j join public.service_requests r on r.id = j.request_id
        where j.status = 'verified' and (j.verified_at at time zone 'Asia/Kuala_Lumpur')::date between p_from and p_to),
    'rework_rate_pct', (select case when count(*) = 0 then null else round(100.0 * count(*) filter (where failed) / count(*), 1) end
         from (select j.id, exists (select 1 from public.job_verifications v where v.job_id = j.id and v.result = 'failed') failed
                 from public.jobs j where j.status = 'verified'
                  and (j.verified_at at time zone 'Asia/Kuala_Lumpur')::date between p_from and p_to) x),
    'avg_rating', (select round(avg(rating)::numeric, 2) from public.job_feedback
         where (created_at at time zone 'Asia/Kuala_Lumpur')::date between p_from and p_to)
  ) into r;
  return r;
end $$;

create function public.report_worker_utilisation(p_from date, p_to date)
returns table (worker_id uuid, full_name text, worker_type public.worker_type, jobs bigint, booked_hours numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_role(array['ops_admin','finance_admin','super_admin']::public.app_role[]);
  return query
  select w.id, p.full_name, w.worker_type, count(distinct b.id),
         coalesce(round(sum(extract(epoch from (b.scheduled_end - b.scheduled_start)) / 3600)::numeric, 1), 0)
    from public.workers w
    join public.profiles p on p.id = w.profile_id
    left join public.job_assignments ja on ja.worker_id = w.id
    left join public.jobs j on j.id = ja.job_id and j.status <> 'cancelled'
    left join public.bookings b on b.id = j.booking_id
         and (b.scheduled_start at time zone 'Asia/Kuala_Lumpur')::date between p_from and p_to
   group by w.id, p.full_name, w.worker_type
   order by 5 desc;
end $$;

grant execute on function
  public.void_job_cost(uuid, text),
  public.submit_job_feedback(uuid, int, text),
  public.report_receivables_ageing(),
  public.report_job_margin(date, date),
  public.report_revenue_monthly(date, date),
  public.report_ops_summary(date, date),
  public.report_worker_utilisation(date, date)
to authenticated;

grant execute on all functions in schema private to authenticated, service_role;
