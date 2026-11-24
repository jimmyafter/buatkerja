-- ============================================================================
-- 007 Authorisation helpers (private schema, SECURITY DEFINER, not API-exposed)
-- They read profiles/members/assignments without recursing through RLS, and
-- every one of them returns "no access" for deactivated users.
-- ============================================================================

create function private.today_my() returns date
language sql stable as $$ select (now() at time zone 'Asia/Kuala_Lumpur')::date $$;

create function private.try_uuid(p text) returns uuid
language plpgsql immutable as $$
begin return p::uuid; exception when others then return null; end $$;

create function private.current_app_role() returns public.app_role
language sql stable security definer set search_path = '' as $$
  select p.role from public.profiles p where p.id = (select auth.uid()) and p.is_active
$$;

-- Capability helpers (super_admin implies every back-office capability)
create function private.is_super_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(private.current_app_role() = 'super_admin', false) $$;
create function private.is_ops() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(private.current_app_role() in ('ops_admin', 'super_admin'), false) $$;
create function private.is_finance() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(private.current_app_role() in ('finance_admin', 'super_admin'), false) $$;
create function private.is_back_office() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(private.current_app_role() in ('ops_admin', 'finance_admin', 'super_admin'), false) $$;

create function private.require_role(p_roles public.app_role[]) returns public.app_role
language plpgsql stable security definer set search_path = '' as $$
declare r public.app_role := private.current_app_role();
begin
  if r is null or not (r = any (p_roles)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return r;
end $$;

-- Customer side ------------------------------------------------------------
create function private.my_account_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select cm.account_id
  from public.customer_members cm
  join public.profiles p on p.id = cm.user_id
  where cm.user_id = (select auth.uid()) and p.is_active and p.role = 'customer'
$$;

create function private.is_account_member(p_account uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from private.my_account_ids() a where a = p_account)
$$;

create function private.is_account_owner(p_account uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.customer_members cm
    where cm.account_id = p_account and cm.user_id = (select auth.uid())
      and cm.member_role = 'owner' and private.is_account_member(p_account))
$$;

-- Worker / supervisor side ---------------------------------------------------
-- Approved + active worker whose partner (if outsourced) is approved and in contract.
create function private.my_worker_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select w.id
  from public.workers w
  join public.profiles p on p.id = w.profile_id
  left join public.outsource_partners op on op.id = w.partner_id
  where w.profile_id = (select auth.uid())
    and p.is_active and p.role = 'worker'
    and w.approval_status = 'approved'
    and (w.worker_type = 'employee'
         or (op.approval_status = 'approved'
             and (op.contract_expires_on is null or op.contract_expires_on >= private.today_my())))
$$;

create function private.is_assigned_to_job(p_job uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.job_assignments ja
    where ja.job_id = p_job and ja.released_at is null
      and ja.worker_id = private.my_worker_id())
$$;

create function private.is_job_supervisor(p_job uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.jobs j
    join public.profiles p on p.id = j.supervisor_id
    where j.id = p_job and j.supervisor_id = (select auth.uid())
      and p.is_active and p.role = 'supervisor')
$$;

create function private.supervisor_sees_worker(p_worker uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.job_assignments ja
    join public.jobs j on j.id = ja.job_id
    where ja.worker_id = p_worker and private.is_job_supervisor(j.id))
$$;

create function private.supervisor_sees_profile(p_profile uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.workers w
    where w.profile_id = p_profile and private.supervisor_sees_worker(w.id))
$$;

-- Customer visibility of documents: never drafts -----------------------------
create function private.customer_can_see_quotation(p_quotation uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.quotations q
    where q.id = p_quotation and q.account_id in (select private.my_account_ids())
      and exists (select 1 from public.quotation_versions v
                  where v.quotation_id = q.id and v.status <> 'draft'))
$$;

create function private.customer_can_see_version(p_version uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.quotation_versions v
    join public.quotations q on q.id = v.quotation_id
    where v.id = p_version and v.status <> 'draft'
      and q.account_id in (select private.my_account_ids()))
$$;

create function private.customer_can_see_change_order(p_co uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.change_orders c
    where c.id = p_co and c.status <> 'draft'
      and c.account_id in (select private.my_account_ids()))
$$;

create function private.customer_can_see_invoice(p_invoice uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.invoices i
    where i.id = p_invoice and i.status <> 'draft'
      and i.account_id in (select private.my_account_ids()))
$$;

-- Customers see before/after photos only once the supervisor has verified the job.
create function private.customer_can_see_job_photo(p_job uuid, p_kind public.photo_kind) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_kind in ('before', 'after') and exists (
    select 1 from public.jobs j
    where j.id = p_job and j.status = 'verified'
      and j.account_id in (select private.my_account_ids()))
$$;

create function private.customer_can_see_job_photo_path(p_path text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.job_photos jp
    where jp.storage_path = p_path and private.customer_can_see_job_photo(jp.job_id, jp.kind))
$$;

-- Request attachments may be added by the customer while the request is still editable.
create function private.can_attach_to_request(p_request uuid, p_account uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.service_requests r
    where r.id = p_request and r.account_id = p_account
      and r.status in ('draft', 'info_requested')
      and private.is_account_member(r.account_id))
$$;

create function private.job_open_for_evidence(p_job uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.jobs j
                 where j.id = p_job and j.status in ('in_progress', 'rework_required'))
$$;

-- Used by RPCs and triggers to move a request along its state machine.
create function private.set_request_status(p_id uuid, p_new public.request_status) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.service_requests set status = p_new where id = p_id and status <> p_new;
end $$;
