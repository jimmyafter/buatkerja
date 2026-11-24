-- ============================================================================
-- 008 Integrity triggers: state machines, immutability, derived totals.
-- Rule used throughout: a browser/API client (role `authenticated`) may edit
-- CONTENT, but may never change a `status` column directly. Status moves only
-- inside SECURITY DEFINER RPCs (migration 009), which run as the function owner.
-- ============================================================================

-- updated_at ------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'profiles','customer_accounts','properties','service_requests','quotation_versions',
    'outsource_partners','workers','bookings','jobs','change_order_requests',
    'change_orders','invoices']
  loop
    execute format('create trigger set_updated_at before update on public.%I
                    for each row execute function private.set_updated_at()', t);
  end loop;
end $$;

-- Auth -> profile ---------------------------------------------------------------
-- Every new auth user becomes a CUSTOMER. Role is never read from user metadata.
create function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data ->> 'full_name', ''));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();

create function private.sync_profile_email() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.profiles set email = new.email where id = new.id;
  return new;
end $$;
create trigger on_auth_user_email_changed after update of email on auth.users
  for each row when (old.email is distinct from new.email)
  execute function private.sync_profile_email();

create function private.profiles_guard() returns trigger
language plpgsql as $$
begin
  if private.is_direct_client() then
    if new.id <> old.id then raise exception 'profile id is immutable'; end if;
    if not private.is_admin() then
      if new.role <> old.role or new.is_active <> old.is_active or new.email <> old.email then
        raise exception 'only an administrator can change role, email or active state' using errcode = '42501';
      end if;
    elsif old.id = (select auth.uid()) and (new.role <> old.role or new.is_active <> old.is_active) then
      raise exception 'administrators cannot change their own role or active state' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
create trigger profiles_guard before update on public.profiles
  for each row execute function private.profiles_guard();

-- Service requests --------------------------------------------------------------
create function private.request_transition_ok(o public.request_status, n public.request_status)
returns boolean language sql immutable as $$
  select case o
    when 'draft'          then n in ('submitted', 'cancelled')
    when 'submitted'      then n in ('under_review', 'info_requested', 'rejected', 'cancelled')
    when 'under_review'   then n in ('info_requested', 'quoted', 'rejected', 'cancelled')
    when 'info_requested' then n in ('under_review', 'rejected', 'cancelled')
    when 'quoted'         then n in ('approved', 'under_review', 'rejected', 'cancelled')
    when 'approved'       then n in ('booked', 'under_review', 'cancelled')
    when 'booked'         then n in ('in_progress', 'approved')
    when 'in_progress'    then n in ('completed')
    when 'completed'      then n in ('invoiced')
    when 'invoiced'       then n in ('closed', 'completed')
    when 'closed'         then n in ('invoiced')
    else false end
$$;

create function private.service_requests_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.request_no := private.next_ref('SR');
    if private.is_direct_client() and new.status <> 'draft' then
      raise exception 'requests are created as drafts and submitted via submit_service_request()';
    end if;
    return new;
  end if;

  if new.account_id <> old.account_id or new.request_no <> old.request_no then
    raise exception 'account and request number are immutable';
  end if;
  if new.status <> old.status then
    if private.is_direct_client() then
      raise exception 'request status can only be changed through the workflow functions' using errcode = '42501';
    end if;
    if not private.request_transition_ok(old.status, new.status) then
      raise exception 'invalid request transition % -> %', old.status, new.status;
    end if;
    if old.status = 'draft' and new.status = 'submitted' then
      new.submitted_at := coalesce(new.submitted_at, now());
    end if;
  end if;
  return new;
end $$;
create trigger service_requests_guard before insert or update on public.service_requests
  for each row execute function private.service_requests_guard();

create function private.service_requests_log() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.service_request_events (request_id, event_type, from_status, to_status, actor_id)
  values (new.id, 'status_change', old.status, new.status, (select auth.uid()));
  return new;
end $$;
create trigger service_requests_log after update of status on public.service_requests
  for each row when (old.status is distinct from new.status)
  execute function private.service_requests_log();

create trigger events_no_update before update on public.service_request_events
  for each row execute function private.forbid_mutation();

-- Quotations & immutable versions -----------------------------------------------
create function private.recalc_quotation_version(p_version uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.quotation_versions v
  set subtotal = s.sub, tax_amount = s.tax, total = s.sub + s.tax
  from (select coalesce(sum(line_total), 0) sub, coalesce(sum(tax_amount), 0) tax
        from public.quotation_items where version_id = p_version) s
  where v.id = p_version;
end $$;

create function private.quotations_guard() returns trigger
language plpgsql as $$
declare v_status public.request_status;
begin
  if tg_op = 'INSERT' then
    select status into v_status from public.service_requests where id = new.request_id;
    if v_status not in ('under_review', 'quoted') then
      raise exception 'quotations can only be created while the request is under review';
    end if;
    new.quote_no := private.next_ref('QT');
  elsif new.request_id <> old.request_id or new.account_id <> old.account_id or new.quote_no <> old.quote_no then
    raise exception 'quotation links are immutable';
  end if;
  return new;
end $$;
create trigger quotations_guard before insert or update on public.quotations
  for each row execute function private.quotations_guard();

create function private.quotation_versions_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if old.status <> 'draft' then
      raise exception 'sent quotation versions are part of the history and cannot be deleted';
    end if;
    return old;
  end if;

  if tg_op = 'INSERT' then
    if new.status <> 'draft' then raise exception 'new quotation versions start as drafts'; end if;
    select coalesce(max(version_no), 0) + 1 into new.version_no
      from public.quotation_versions where quotation_id = new.quotation_id;
    new.subtotal := 0; new.tax_amount := 0; new.total := 0;
    return new;
  end if;

  -- UPDATE
  if private.is_direct_client() and new.status <> old.status then
    raise exception 'quotation status can only be changed through the workflow functions' using errcode = '42501';
  end if;

  if old.status = 'draft' then
    if new.status not in ('draft', 'sent') then raise exception 'draft can only move to sent'; end if;
    if private.is_direct_client() and (new.subtotal, new.tax_amount, new.total, new.version_no, new.quotation_id)
         is distinct from (old.subtotal, old.tax_amount, old.total, old.version_no, old.quotation_id) then
      raise exception 'totals are calculated from items';
    end if;
    if new.status = 'sent' then
      if not exists (select 1 from public.quotation_items where version_id = new.id) then
        raise exception 'cannot send a quotation without items';
      end if;
      if new.total <= 0 then raise exception 'quotation total must be greater than zero'; end if;
      if new.valid_until is null or new.valid_until < private.today_my() then
        raise exception 'quotation needs a valid_until date that is not in the past';
      end if;
    end if;
  else
    -- Frozen: content can never change once the customer has been able to see it.
    if (new.quotation_id, new.version_no, new.valid_until, new.scope_summary, new.terms,
        new.subtotal, new.tax_amount, new.total, new.created_by)
       is distinct from
       (old.quotation_id, old.version_no, old.valid_until, old.scope_summary, old.terms,
        old.subtotal, old.tax_amount, old.total, old.created_by) then
      raise exception 'quotation version % is frozen; create a new version instead', old.version_no;
    end if;
    if new.status <> old.status
       and not (old.status = 'sent' and new.status in ('approved','rejected','superseded','withdrawn','expired')) then
      raise exception 'invalid quotation transition % -> %', old.status, new.status;
    end if;
  end if;
  return new;
end $$;
create trigger quotation_versions_guard before insert or update or delete on public.quotation_versions
  for each row execute function private.quotation_versions_guard();

create function private.quotation_items_guard() returns trigger
language plpgsql as $$
declare v_status public.quote_status;
begin
  select status into v_status from public.quotation_versions
   where id = coalesce(new.version_id, old.version_id);
  -- (cascade delete of a draft version passes: the parent row is already gone)
  if v_status is not null and v_status <> 'draft' then
    raise exception 'items of a sent quotation version are frozen';
  end if;
  if tg_op = 'UPDATE' and new.version_id <> old.version_id then
    raise exception 'items cannot move between versions';
  end if;
  return coalesce(new, old);
end $$;
create trigger quotation_items_guard before insert or update or delete on public.quotation_items
  for each row execute function private.quotation_items_guard();

create function private.quotation_items_recalc() returns trigger
language plpgsql as $$
begin
  perform private.recalc_quotation_version(coalesce(new.version_id, old.version_id));
  return null;
end $$;
create trigger quotation_items_recalc after insert or update or delete on public.quotation_items
  for each row execute function private.quotation_items_recalc();

-- Workforce approval ------------------------------------------------------------------
create function private.approval_stamp() returns trigger
language plpgsql as $$
begin
  if new.approval_status = 'approved' and (tg_op = 'INSERT' or old.approval_status <> 'approved') then
    new.approved_by := coalesce((select auth.uid()), new.approved_by);
    new.approved_at := now();
  end if;
  return new;
end $$;
create trigger approval_stamp before insert or update on public.workers
  for each row execute function private.approval_stamp();
create trigger approval_stamp before insert or update on public.outsource_partners
  for each row execute function private.approval_stamp();

create function private.workers_guard() returns trigger
language plpgsql as $$
declare v_role public.app_role;
begin
  select role into v_role from public.profiles where id = new.profile_id;
  if v_role is distinct from 'worker' then
    raise exception 'a worker record requires a profile with role worker';
  end if;
  if tg_op = 'UPDATE' and (new.profile_id <> old.profile_id or new.worker_type <> old.worker_type) then
    raise exception 'worker identity and type are immutable';
  end if;
  return new;
end $$;
create trigger workers_guard before insert or update on public.workers
  for each row execute function private.workers_guard();

-- Bookings -------------------------------------------------------------------------------
create function private.bookings_guard() returns trigger
language plpgsql as $$
declare v_ok boolean;
begin
  if tg_op = 'INSERT' then
    select exists (
      select 1 from public.quotation_versions v
      join public.quotations q on q.id = v.quotation_id
      where v.id = new.quotation_version_id and v.status = 'approved'
        and q.request_id = new.request_id) into v_ok;
    if not v_ok then
      raise exception 'a booking requires the approved quotation version of the same request';
    end if;
    new.booking_no := private.next_ref('BK');
    return new;
  end if;

  if (new.request_id, new.account_id, new.quotation_version_id, new.booking_no)
     is distinct from (old.request_id, old.account_id, old.quotation_version_id, old.booking_no) then
    raise exception 'booking links are immutable';
  end if;
  if new.status <> old.status then
    if private.is_direct_client() then
      raise exception 'booking status can only be changed through the workflow functions' using errcode = '42501';
    end if;
    if not (old.status = 'confirmed' and new.status in ('completed', 'cancelled')) then
      raise exception 'invalid booking transition % -> %', old.status, new.status;
    end if;
  end if;
  if (new.scheduled_start, new.scheduled_end) is distinct from (old.scheduled_start, old.scheduled_end) then
    if old.status <> 'confirmed'
       or exists (select 1 from public.jobs j where j.booking_id = old.id and j.status <> 'scheduled') then
      raise exception 'a booking can only be rescheduled before work has started';
    end if;
  end if;
  return new;
end $$;
create trigger bookings_guard before insert or update on public.bookings
  for each row execute function private.bookings_guard();

-- Jobs ---------------------------------------------------------------------------------------
create function private.jobs_guard() returns trigger
language plpgsql as $$
declare v_sup_ok boolean;
begin
  if tg_op = 'INSERT' then
    new.job_no := private.next_ref('JB');
    new.status := 'scheduled';
  else
    if (new.booking_id, new.request_id, new.account_id, new.job_no)
       is distinct from (old.booking_id, old.request_id, old.account_id, old.job_no) then
      raise exception 'job links are immutable';
    end if;
    if new.status <> old.status then
      if private.is_direct_client() then
        raise exception 'job status can only be changed through the workflow functions' using errcode = '42501';
      end if;
      if not ((old.status, new.status) in (
           ('scheduled','in_progress'), ('scheduled','cancelled'),
           ('in_progress','pending_verification'),
           ('pending_verification','verified'), ('pending_verification','rework_required'),
           ('rework_required','in_progress'))) then
        raise exception 'invalid job transition % -> %', old.status, new.status;
      end if;
    end if;
    if old.status in ('verified', 'cancelled') and
       (new.supervisor_id, new.scope_of_work) is distinct from (old.supervisor_id, old.scope_of_work) then
      raise exception 'closed jobs are read-only';
    end if;
  end if;
  if tg_op = 'INSERT' or new.supervisor_id <> old.supervisor_id then
    select exists (select 1 from public.profiles p
                   where p.id = new.supervisor_id and p.role = 'supervisor' and p.is_active) into v_sup_ok;
    if not v_sup_ok then raise exception 'supervisor must be an active supervisor profile'; end if;
  end if;
  return new;
end $$;
create trigger jobs_guard before insert or update on public.jobs
  for each row execute function private.jobs_guard();

-- Assignments: only company-approved workers, never released rows rewritten ----------------------
create function private.job_assignments_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_job_status public.job_status;
  v_w public.workers;
  v_active boolean;
  v_partner public.outsource_partners;
begin
  if tg_op = 'DELETE' then raise exception 'assignment history cannot be deleted'; end if;

  if tg_op = 'INSERT' then
    select status into v_job_status from public.jobs where id = new.job_id;
    if v_job_status not in ('scheduled', 'in_progress', 'rework_required') then
      raise exception 'workers can only be assigned to open jobs (job is %)', v_job_status;
    end if;
    select * into v_w from public.workers where id = new.worker_id;
    select is_active and role = 'worker' into v_active from public.profiles where id = v_w.profile_id;
    if v_w.approval_status <> 'approved' or not coalesce(v_active, false) then
      raise exception 'worker is not an approved, active member of the workforce';
    end if;
    if v_w.worker_type = 'outsourced' then
      select * into v_partner from public.outsource_partners where id = v_w.partner_id;
      if v_partner.approval_status <> 'approved'
         or (v_partner.contract_expires_on is not null and v_partner.contract_expires_on < private.today_my()) then
        raise exception 'outsourcing partner is not currently approved';
      end if;
    end if;
    new.assigned_by := coalesce((select auth.uid()), new.assigned_by);
    new.assigned_at := now();
    new.released_at := null; new.release_reason := null;
    return new;
  end if;

  -- UPDATE: only releasing / changing role of an active assignment
  if old.released_at is not null then raise exception 'released assignments are immutable'; end if;
  if (new.job_id, new.worker_id, new.assigned_by, new.assigned_at)
     is distinct from (old.job_id, old.worker_id, old.assigned_by, old.assigned_at) then
    raise exception 'only role and release fields of an assignment can change';
  end if;
  if new.released_at is not null and new.released_at is distinct from old.released_at then
    new.released_at := now();
  end if;
  return new;
end $$;
create trigger job_assignments_guard before insert or update or delete on public.job_assignments
  for each row execute function private.job_assignments_guard();

-- Evidence trail: progress, photos, verifications are append-only ------------------------------------
create function private.job_progress_guard() returns trigger
language plpgsql as $$
declare v_status public.job_status;
begin
  select status into v_status from public.jobs where id = new.job_id;
  if v_status not in ('in_progress', 'rework_required', 'pending_verification') then
    raise exception 'progress can only be logged on an active job (job is %)', v_status;
  end if;
  if private.is_direct_client() then new.author_id := (select auth.uid()); end if;
  return new;
end $$;
create trigger job_progress_guard before insert on public.job_progress_updates
  for each row execute function private.job_progress_guard();
create trigger job_progress_immutable before update or delete on public.job_progress_updates
  for each row execute function private.forbid_mutation();

create function private.job_photos_guard() returns trigger
language plpgsql as $$
declare v_status public.job_status;
begin
  select status into v_status from public.jobs where id = new.job_id;
  if v_status not in ('in_progress', 'rework_required') then
    raise exception 'photos can only be added while the job is in progress (job is %)', v_status;
  end if;
  if new.progress_update_id is not null and not exists (
       select 1 from public.job_progress_updates u where u.id = new.progress_update_id and u.job_id = new.job_id) then
    raise exception 'progress update belongs to a different job';
  end if;
  if private.is_direct_client() then new.uploaded_by := (select auth.uid()); end if;
  return new;
end $$;
create trigger job_photos_guard before insert on public.job_photos
  for each row execute function private.job_photos_guard();
create trigger job_photos_immutable before update or delete on public.job_photos
  for each row execute function private.forbid_mutation();

create trigger job_verifications_immutable before update or delete on public.job_verifications
  for each row execute function private.forbid_mutation();

-- Change orders (additional chargeable work) --------------------------------------------------------
create function private.cor_guard() returns trigger
language plpgsql as $$
declare v_status public.job_status;
begin
  if tg_op = 'INSERT' then
    select status into v_status from public.jobs where id = new.job_id;
    if v_status not in ('in_progress', 'rework_required') then
      raise exception 'extra work can only be flagged on an active job';
    end if;
    new.status := 'open'; new.change_order_id := null;
    if private.is_direct_client() then new.raised_by := (select auth.uid()); end if;
    return new;
  end if;
  if (new.job_id, new.raised_by, new.description) is distinct from (old.job_id, old.raised_by, old.description) then
    raise exception 'flagged work is immutable once raised';
  end if;
  if new.status <> old.status then
    if old.status <> 'open' then raise exception 'request already resolved'; end if;
    if private.is_direct_client() and new.status <> 'dismissed' then
      raise exception 'use create_change_order() to convert a request' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
create trigger cor_guard before insert or update on public.change_order_requests
  for each row execute function private.cor_guard();

create function private.recalc_change_order(p_co uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.change_orders c
  set subtotal = s.sub, tax_amount = s.tax, total = s.sub + s.tax
  from (select coalesce(sum(line_total), 0) sub, coalesce(sum(tax_amount), 0) tax
        from public.change_order_items where change_order_id = p_co) s
  where c.id = p_co;
end $$;

create function private.change_orders_guard() returns trigger
language plpgsql as $$
declare v_status public.job_status;
begin
  if tg_op = 'INSERT' then
    select status into v_status from public.jobs where id = new.job_id;
    if v_status not in ('in_progress', 'rework_required', 'pending_verification') then
      raise exception 'change orders can only be raised on an active job (job is %)', v_status;
    end if;
    new.co_no := private.next_ref('CO');
    new.status := 'draft'; new.subtotal := 0; new.tax_amount := 0; new.total := 0;
    return new;
  end if;

  if private.is_direct_client() and new.status <> old.status then
    raise exception 'change order status can only be changed through the workflow functions' using errcode = '42501';
  end if;
  if old.status = 'draft' then
    if new.status not in ('draft', 'sent', 'withdrawn') then raise exception 'invalid change order transition'; end if;
    if private.is_direct_client() and (new.subtotal, new.tax_amount, new.total) is distinct from
       (old.subtotal, old.tax_amount, old.total) then
      raise exception 'totals are calculated from items';
    end if;
    if new.status = 'sent' then
      if not exists (select 1 from public.change_order_items where change_order_id = new.id) or new.total <= 0 then
        raise exception 'a change order needs priced items before it can be sent';
      end if;
    end if;
  else
    if (new.job_id, new.account_id, new.co_no, new.title, new.description, new.subtotal, new.tax_amount, new.total)
       is distinct from
       (old.job_id, old.account_id, old.co_no, old.title, old.description, old.subtotal, old.tax_amount, old.total) then
      raise exception 'a sent change order is frozen; withdraw it and raise a new one';
    end if;
    if new.status <> old.status and not (
         (old.status = 'sent' and new.status in ('approved', 'rejected', 'withdrawn'))) then
      raise exception 'invalid change order transition % -> %', old.status, new.status;
    end if;
  end if;
  return new;
end $$;
create trigger change_orders_guard before insert or update on public.change_orders
  for each row execute function private.change_orders_guard();

create function private.change_order_items_guard() returns trigger
language plpgsql as $$
declare v_status public.co_status;
begin
  select status into v_status from public.change_orders
   where id = coalesce(new.change_order_id, old.change_order_id);
  if v_status is not null and v_status <> 'draft' then
    raise exception 'items of a sent change order are frozen';
  end if;
  if tg_op = 'UPDATE' and new.change_order_id <> old.change_order_id then
    raise exception 'items cannot move between change orders';
  end if;
  return coalesce(new, old);
end $$;
create trigger change_order_items_guard before insert or update or delete on public.change_order_items
  for each row execute function private.change_order_items_guard();

create function private.change_order_items_recalc() returns trigger
language plpgsql as $$
begin
  perform private.recalc_change_order(coalesce(new.change_order_id, old.change_order_id));
  return null;
end $$;
create trigger change_order_items_recalc after insert or update or delete on public.change_order_items
  for each row execute function private.change_order_items_recalc();

-- Invoices ------------------------------------------------------------------------------------------
create function private.recalc_invoice(p_invoice uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.invoices i
  set subtotal = s.sub, tax_amount = s.tax, total = s.sub + s.tax
  from (select coalesce(sum(line_total), 0) sub, coalesce(sum(tax_amount), 0) tax
        from public.invoice_items where invoice_id = p_invoice) s
  where i.id = p_invoice;
end $$;

create function private.invoices_guard() returns trigger
language plpgsql as $$
declare v_job public.job_status;
begin
  if tg_op = 'DELETE' then
    if old.status <> 'draft' then raise exception 'issued invoices cannot be deleted; void them'; end if;
    return old;
  end if;

  if tg_op = 'INSERT' then
    select status into v_job from public.jobs where id = new.job_id;
    if v_job <> 'verified' then raise exception 'invoices can only be raised for supervisor-verified jobs'; end if;
    new.status := 'draft'; new.invoice_no := null; new.amount_paid := 0;
    new.subtotal := 0; new.tax_amount := 0; new.total := 0;
    return new;
  end if;

  if (new.job_id, new.request_id, new.account_id) is distinct from (old.job_id, old.request_id, old.account_id) then
    raise exception 'invoice links are immutable';
  end if;
  if old.invoice_no is not null and new.invoice_no is distinct from old.invoice_no then
    raise exception 'invoice number is immutable once issued';
  end if;
  if private.is_direct_client() and
     (new.status, new.invoice_no, new.subtotal, new.tax_amount, new.total, new.amount_paid,
      new.issue_date, new.issued_by, new.void_reason)
     is distinct from
     (old.status, old.invoice_no, old.subtotal, old.tax_amount, old.total, old.amount_paid,
      old.issue_date, old.issued_by, old.void_reason) then
    raise exception 'invoice figures and status are system-managed' using errcode = '42501';
  end if;
  if old.status <> 'draft' and (new.subtotal, new.tax_amount, new.total) is distinct from (old.subtotal, old.tax_amount, old.total) then
    raise exception 'an issued invoice is frozen';
  end if;
  if new.status <> old.status and not (
       (old.status = 'draft'          and new.status = 'issued') or
       (old.status = 'issued'         and new.status in ('partially_paid', 'paid', 'void')) or
       (old.status = 'partially_paid' and new.status in ('issued', 'paid')) or
       (old.status = 'paid'           and new.status in ('issued', 'partially_paid'))) then
    raise exception 'invalid invoice transition % -> %', old.status, new.status;
  end if;
  if new.status = 'void' and old.amount_paid > 0 then
    raise exception 'void the recorded payments before voiding the invoice';
  end if;
  return new;
end $$;
create trigger invoices_guard before insert or update or delete on public.invoices
  for each row execute function private.invoices_guard();

-- Invoice lines must mirror approved quotation / change-order lines exactly
-- (nothing billable can be invented or inflated); extras go through 'adjustment'.
create function private.invoice_items_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_inv public.invoices;
  v_ok boolean := false;
begin
  if tg_op = 'DELETE' then
    select * into v_inv from public.invoices where id = old.invoice_id;
    if found and v_inv.status <> 'draft' then raise exception 'issued invoice lines are frozen'; end if;
    return old;
  end if;
  select * into v_inv from public.invoices where id = new.invoice_id;
  if v_inv.status <> 'draft' then raise exception 'issued invoice lines are frozen'; end if;
  if tg_op = 'UPDATE' and new.invoice_id <> old.invoice_id then raise exception 'lines cannot move between invoices'; end if;

  if new.source_type = 'quotation_item' then
    select exists (
      select 1 from public.quotation_items qi
      join public.quotation_versions v on v.id = qi.version_id
      join public.quotations q on q.id = v.quotation_id
      where qi.id = new.source_id and v.status = 'approved' and q.request_id = v_inv.request_id
        and (qi.description, qi.unit, qi.quantity, qi.unit_price, qi.tax_rate)
          = (new.description, new.unit, new.quantity, new.unit_price, new.tax_rate)) into v_ok;
  elsif new.source_type = 'change_order_item' then
    select exists (
      select 1 from public.change_order_items ci
      join public.change_orders c on c.id = ci.change_order_id
      where ci.id = new.source_id and c.status = 'approved' and c.job_id = v_inv.job_id
        and (ci.description, ci.unit, ci.quantity, ci.unit_price, ci.tax_rate)
          = (new.description, new.unit, new.quantity, new.unit_price, new.tax_rate)) into v_ok;
  else
    v_ok := true;   -- adjustment (admin-only via RLS)
  end if;
  if not v_ok then
    raise exception 'invoice line does not match an approved quotation or change-order line';
  end if;
  return new;
end $$;
create trigger invoice_items_guard before insert or update or delete on public.invoice_items
  for each row execute function private.invoice_items_guard();

create function private.invoice_items_recalc() returns trigger
language plpgsql as $$
begin
  perform private.recalc_invoice(coalesce(new.invoice_id, old.invoice_id));
  return null;
end $$;
create trigger invoice_items_recalc after insert or update or delete on public.invoice_items
  for each row execute function private.invoice_items_recalc();

-- When an invoice moves, move the request ------------------------------------------------------------
create function private.invoice_status_propagate() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'issued' and old.status = 'draft' then
    perform private.set_request_status(new.request_id, 'invoiced');
  elsif new.status = 'paid' then
    perform private.set_request_status(new.request_id, 'closed');
  elsif old.status = 'paid' and new.status <> 'paid' then
    perform private.set_request_status(new.request_id, 'invoiced');
  elsif new.status = 'void' then
    perform private.set_request_status(new.request_id, 'completed');
  end if;
  return new;
end $$;
create trigger invoice_status_propagate after update of status on public.invoices
  for each row when (old.status is distinct from new.status)
  execute function private.invoice_status_propagate();

-- Payments: append-only ledger; invoice balance derived from it -----------------------------------------
create function private.payments_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_inv public.invoices;
begin
  if tg_op = 'DELETE' then raise exception 'payments cannot be deleted; void them'; end if;

  if tg_op = 'INSERT' then
    select * into v_inv from public.invoices where id = new.invoice_id for update;   -- serialise concurrent payments
    if v_inv.status not in ('issued', 'partially_paid') then
      raise exception 'payments can only be recorded against an open invoice (invoice is %)', v_inv.status;
    end if;
    if new.amount > v_inv.total - v_inv.amount_paid then
      raise exception 'payment of % exceeds the outstanding balance of %', new.amount, v_inv.total - v_inv.amount_paid;
    end if;
    if new.paid_at > now() + interval '1 day' then raise exception 'payment date is in the future'; end if;
    new.voided_at := null; new.voided_by := null; new.void_reason := null;
    if (select auth.uid()) is not null then new.recorded_by := (select auth.uid()); end if;
    return new;
  end if;

  -- UPDATE: the only permitted change is voiding, once
  if old.voided_at is not null then raise exception 'voided payments are immutable'; end if;
  if (new.invoice_id, new.account_id, new.amount, new.method, new.reference, new.paid_at, new.recorded_by)
     is distinct from (old.invoice_id, old.account_id, old.amount, old.method, old.reference, old.paid_at, old.recorded_by) then
    raise exception 'payments are immutable; void and re-record instead';
  end if;
  if new.voided_at is not null then new.voided_at := now(); end if;
  return new;
end $$;
create trigger payments_guard before insert or update or delete on public.payments
  for each row execute function private.payments_guard();

create function private.payments_apply() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_paid numeric(12,2);
  v_inv public.invoices;
begin
  select * into v_inv from public.invoices where id = new.invoice_id for update;
  select coalesce(sum(amount), 0) into v_paid
    from public.payments where invoice_id = new.invoice_id and voided_at is null;
  update public.invoices
  set amount_paid = v_paid,
      status = case when v_paid = 0 then 'issued'::public.invoice_status
                    when v_paid < v_inv.total then 'partially_paid'::public.invoice_status
                    else 'paid'::public.invoice_status end
  where id = new.invoice_id;
  return null;
end $$;
create trigger payments_apply after insert or update on public.payments
  for each row execute function private.payments_apply();

-- Document numbers are assigned by the guard triggers; defaults keep generated
-- TypeScript insert types from demanding them.
alter table public.service_requests alter column request_no set default 'pending';
alter table public.quotations       alter column quote_no   set default 'pending';
alter table public.bookings         alter column booking_no set default 'pending';
alter table public.jobs             alter column job_no     set default 'pending';
alter table public.change_orders    alter column co_no      set default 'pending';
