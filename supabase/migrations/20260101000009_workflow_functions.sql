-- ============================================================================
-- 009 Workflow functions (RPC). These are the ONLY way statuses move.
-- All are SECURITY DEFINER with an explicit actor/ownership check inside, so the
-- authorisation rule lives next to the state change, not in the web app.
--   customer : create_customer_account, submit_service_request, cancel_service_request,
--              respond_to_quotation, respond_to_change_order
--   admin    : review_service_request, create_quotation, create_quotation_revision,
--              send_quotation_version, withdraw_quotation_version, confirm_booking,
--              cancel_booking, create_change_order, send_change_order,
--              withdraw_change_order, create_invoice_draft, issue_invoice,
--              void_invoice, void_payment, record_quotation_response,
--              record_change_order_response (customer decision received offline)
--   worker   : start_job, submit_job_for_verification
--   supervisor: verify_job
--   system   : expire_stale_quotations (service_role / cron only)
-- ============================================================================

-- Small internal helper: add a timeline note to a request ----------------------
create function private.add_request_note(p_request uuid, p_note text, p_visible boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_note is not null and length(btrim(p_note)) > 0 then
    insert into public.service_request_events (request_id, event_type, note, visible_to_customer, actor_id)
    values (p_request, 'note', btrim(p_note), p_visible, (select auth.uid()));
  end if;
end $$;

-- ============================ CUSTOMER ======================================

create function public.create_customer_account(
  p_account_type public.account_type,
  p_display_name text,
  p_company_name text default null,
  p_ssm text default null,
  p_billing_email text default null,
  p_billing_address text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid()); v_id uuid;
begin
  perform private.require_role(array['customer']::public.app_role[]);
  if exists (select 1 from public.customer_members where user_id = v_uid) then
    raise exception 'you already belong to a customer account';
  end if;
  insert into public.customer_accounts
    (account_type, display_name, company_name, ssm_registration_no, billing_email, billing_address, created_by)
  values (p_account_type, p_display_name, p_company_name, p_ssm, p_billing_email, p_billing_address, v_uid)
  returning id into v_id;
  insert into public.customer_members (account_id, user_id, member_role) values (v_id, v_uid, 'owner');
  return v_id;
end $$;

create function public.submit_service_request(p_request_id uuid, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.service_requests;
begin
  perform private.require_role(array['customer','admin']::public.app_role[]);
  select * into r from public.service_requests where id = p_request_id for update;
  if not found or not (private.is_admin() or private.is_account_member(r.account_id)) then
    raise exception 'request not found' using errcode = 'P0002';
  end if;

  if r.status = 'draft' then
    if length(btrim(r.description)) < 10 then raise exception 'please describe the problem (at least 10 characters)'; end if;
    if not exists (select 1 from public.service_categories where id = r.category_id and is_active) then
      raise exception 'service category is not available';
    end if;
    if exists (select 1 from public.properties where id = r.property_id and archived_at is not null) then
      raise exception 'property is archived';
    end if;
    update public.service_requests
       set status = 'submitted', submitted_by = (select auth.uid()), submitted_at = now()
     where id = r.id;
  elsif r.status = 'info_requested' then
    if p_note is null or length(btrim(p_note)) = 0 then raise exception 'please provide the requested information'; end if;
    update public.service_requests set status = 'under_review' where id = r.id;
  else
    raise exception 'request cannot be submitted from status %', r.status;
  end if;
  perform private.add_request_note(r.id, p_note, true);
end $$;

create function public.cancel_service_request(p_request_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.service_requests;
begin
  perform private.require_role(array['customer','admin']::public.app_role[]);
  if p_reason is null or length(btrim(p_reason)) < 3 then raise exception 'a reason is required'; end if;
  select * into r from public.service_requests where id = p_request_id for update;
  if not found or not (private.is_admin() or private.is_account_member(r.account_id)) then
    raise exception 'request not found' using errcode = 'P0002';
  end if;
  if r.status not in ('draft','submitted','under_review','info_requested','quoted','approved') then
    raise exception 'request in status % cannot be cancelled here (cancel the booking first / contact us)', r.status;
  end if;
  update public.quotation_versions v set status = 'withdrawn'
   from public.quotations q
   where q.id = v.quotation_id and q.request_id = r.id and v.status = 'sent';
  update public.service_requests set status = 'cancelled', cancelled_reason = btrim(p_reason) where id = r.id;
end $$;

-- Shared by the customer's own response and by an admin recording a response
-- received outside the portal (WhatsApp, phone, signed copy). Channel is stored.
create function private.apply_quotation_response(p_version uuid, p_decision text, p_note text, p_channel text)
returns void language plpgsql security definer set search_path = '' as $$
declare v public.quotation_versions; q public.quotations;
begin
  if p_decision not in ('approve', 'reject') then raise exception 'decision must be approve or reject'; end if;
  select * into v from public.quotation_versions where id = p_version for update;
  if not found then raise exception 'quotation not found' using errcode = 'P0002'; end if;
  select * into q from public.quotations where id = v.quotation_id;
  if p_channel = 'portal' and not private.is_account_member(q.account_id) then
    raise exception 'quotation not found' using errcode = 'P0002';
  end if;
  if v.status <> 'sent' then raise exception 'this quotation version is no longer open for a response (%)', v.status; end if;
  if v.valid_until < private.today_my() then raise exception 'this quotation has expired; please request a new one'; end if;

  update public.quotation_versions
     set status = case p_decision when 'approve' then 'approved'::public.quote_status else 'rejected'::public.quote_status end,
         responded_at = now(), responded_by = (select auth.uid()),
         response_note = nullif(btrim(p_note), ''), response_channel = p_channel
   where id = v.id;
  perform private.set_request_status(q.request_id,
          case p_decision when 'approve' then 'approved'::public.request_status else 'under_review'::public.request_status end);
  if p_channel = 'admin_recorded' then
    perform private.add_request_note(q.request_id,
      'Quotation v' || v.version_no || ' ' || case p_decision when 'approve' then 'approval' else 'rejection' end
      || ' recorded by our team on your behalf: ' || btrim(p_note), true);
  end if;
end $$;

create function private.apply_change_order_response(p_co uuid, p_decision text, p_note text, p_channel text)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.change_orders; v_req uuid;
begin
  if p_decision not in ('approve', 'reject') then raise exception 'decision must be approve or reject'; end if;
  select * into c from public.change_orders where id = p_co for update;
  if not found or (p_channel = 'portal' and not private.is_account_member(c.account_id)) then
    raise exception 'change order not found' using errcode = 'P0002';
  end if;
  if c.status <> 'sent' then raise exception 'this change order is no longer open for a response (%)', c.status; end if;
  update public.change_orders
     set status = case p_decision when 'approve' then 'approved'::public.co_status else 'rejected'::public.co_status end,
         responded_at = now(), responded_by = (select auth.uid()),
         response_note = nullif(btrim(p_note), ''), response_channel = p_channel
   where id = c.id;
  if p_channel = 'admin_recorded' then
    select request_id into v_req from public.jobs where id = c.job_id;
    perform private.add_request_note(v_req,
      'Extra work ' || c.co_no || ' ' || case p_decision when 'approve' then 'approval' else 'rejection' end
      || ' recorded by our team on your behalf: ' || btrim(p_note), true);
  end if;
end $$;

create function public.respond_to_quotation(p_version_id uuid, p_decision text, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_role(array['customer']::public.app_role[]);
  perform private.apply_quotation_response(p_version_id, p_decision, p_note, 'portal');
end $$;

create function public.respond_to_change_order(p_co_id uuid, p_decision text, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_role(array['customer']::public.app_role[]);
  perform private.apply_change_order_response(p_co_id, p_decision, p_note, 'portal');
end $$;

-- Admin records a decision the customer gave outside the portal. The note is
-- mandatory (>= 10 chars: who, which channel, when) and is shown on the customer's
-- timeline, so the customer can see - and dispute - what was recorded.
create function public.record_quotation_response(p_version_id uuid, p_decision text, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_role(array['admin']::public.app_role[]);
  if p_note is null or length(btrim(p_note)) < 10 then
    raise exception 'describe how the customer responded (who, channel, when) - at least 10 characters';
  end if;
  perform private.apply_quotation_response(p_version_id, p_decision, p_note, 'admin_recorded');
end $$;

create function public.record_change_order_response(p_co_id uuid, p_decision text, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_role(array['admin']::public.app_role[]);
  if p_note is null or length(btrim(p_note)) < 10 then
    raise exception 'describe how the customer responded (who, channel, when) - at least 10 characters';
  end if;
  perform private.apply_change_order_response(p_co_id, p_decision, p_note, 'admin_recorded');
end $$;

-- ============================== ADMIN =======================================

create function public.review_service_request(p_request_id uuid, p_action text, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.service_requests;
begin
  perform private.require_role(array['admin']::public.app_role[]);
  select * into r from public.service_requests where id = p_request_id for update;
  if not found then raise exception 'request not found' using errcode = 'P0002'; end if;

  if p_action = 'start_review' then
    update public.service_requests set status = 'under_review' where id = r.id;
  elsif p_action = 'request_info' then
    if p_note is null or length(btrim(p_note)) = 0 then raise exception 'say what information is needed'; end if;
    update public.service_requests set status = 'info_requested' where id = r.id;
    perform private.add_request_note(r.id, p_note, true);
  elsif p_action = 'reject' then
    if p_note is null or length(btrim(p_note)) < 3 then raise exception 'a reason is required'; end if;
    update public.quotation_versions v set status = 'withdrawn'
     from public.quotations q where q.id = v.quotation_id and q.request_id = r.id and v.status = 'sent';
    update public.service_requests set status = 'rejected', rejected_reason = btrim(p_note) where id = r.id;
    perform private.add_request_note(r.id, p_note, true);
  else
    raise exception 'unknown action %', p_action;
  end if;
end $$;

create function public.create_quotation(p_request_id uuid, p_valid_until date default null, p_scope text default '')
returns uuid language plpgsql security definer set search_path = '' as $$
declare r public.service_requests; v_q uuid; v_ver uuid;
begin
  perform private.require_role(array['admin']::public.app_role[]);
  select * into r from public.service_requests where id = p_request_id for update;
  if not found then raise exception 'request not found' using errcode = 'P0002'; end if;
  insert into public.quotations (quote_no, request_id, account_id, created_by)
  values ('pending', r.id, r.account_id, (select auth.uid()))
  returning id into v_q;                       -- guard trigger assigns QT number & checks status
  insert into public.quotation_versions (quotation_id, valid_until, scope_summary, created_by)
  values (v_q, coalesce(p_valid_until, private.today_my() + 14), coalesce(p_scope, ''), (select auth.uid()))
  returning id into v_ver;
  return v_ver;
end $$;

create function public.create_quotation_revision(p_quotation_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare q public.quotations; prev public.quotation_versions; v_new uuid; v_status public.request_status;
begin
  perform private.require_role(array['admin']::public.app_role[]);
  select * into q from public.quotations where id = p_quotation_id for update;
  if not found then raise exception 'quotation not found' using errcode = 'P0002'; end if;
  select status into v_status from public.service_requests where id = q.request_id;
  if v_status not in ('under_review', 'quoted') then
    raise exception 'quotation can no longer be revised (request is %)', v_status;
  end if;
  select * into prev from public.quotation_versions where quotation_id = q.id order by version_no desc limit 1;
  if prev.status = 'draft' then raise exception 'a draft version already exists'; end if;
  insert into public.quotation_versions (quotation_id, valid_until, scope_summary, terms, created_by)
  values (q.id, private.today_my() + 14, prev.scope_summary, prev.terms, (select auth.uid()))
  returning id into v_new;
  insert into public.quotation_items (version_id, position, description, unit, quantity, unit_price, tax_rate)
  select v_new, position, description, unit, quantity, unit_price, tax_rate
    from public.quotation_items where version_id = prev.id;
  return v_new;
end $$;

create function public.send_quotation_version(p_version_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v public.quotation_versions; q public.quotations; v_status public.request_status;
begin
  perform private.require_role(array['admin']::public.app_role[]);
  select * into v from public.quotation_versions where id = p_version_id for update;
  if not found then raise exception 'version not found' using errcode = 'P0002'; end if;
  select * into q from public.quotations where id = v.quotation_id for update;
  if v.status <> 'draft' then raise exception 'only a draft can be sent'; end if;
  select status into v_status from public.service_requests where id = q.request_id for update;
  if v_status not in ('under_review', 'quoted') then
    raise exception 'request is % and cannot receive a quotation', v_status;
  end if;
  update public.quotation_versions set status = 'superseded'
   where quotation_id = q.id and status = 'sent';
  update public.quotation_versions
     set status = 'sent', sent_at = now(), sent_by = (select auth.uid())
   where id = v.id;
  perform private.set_request_status(q.request_id, 'quoted');
end $$;

create function public.withdraw_quotation_version(p_version_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare v public.quotation_versions; q public.quotations;
begin
  perform private.require_role(array['admin']::public.app_role[]);
  select * into v from public.quotation_versions where id = p_version_id for update;
  if not found or v.status <> 'sent' then raise exception 'only a sent version can be withdrawn'; end if;
  select * into q from public.quotations where id = v.quotation_id;
  update public.quotation_versions set status = 'withdrawn', response_note = p_reason where id = v.id;
  perform private.set_request_status(q.request_id, 'under_review');
end $$;

create function public.confirm_booking(
  p_request_id uuid, p_start timestamptz, p_end timestamptz,
  p_supervisor_id uuid, p_scope_of_work text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r public.service_requests; v public.quotation_versions; p public.properties;
  v_booking uuid; v_job uuid; v_scope text;
begin
  perform private.require_role(array['admin']::public.app_role[]);
  select * into r from public.service_requests where id = p_request_id for update;
  if not found then raise exception 'request not found' using errcode = 'P0002'; end if;
  if r.status <> 'approved' then raise exception 'the customer must approve a quotation first (request is %)', r.status; end if;
  if p_start <= now() then raise exception 'booking must start in the future'; end if;

  select v2.* into v from public.quotation_versions v2
    join public.quotations q on q.id = v2.quotation_id
   where q.request_id = r.id and v2.status = 'approved';
  if not found then raise exception 'no approved quotation version'; end if;

  select * into p from public.properties where id = r.property_id;
  -- Workers see scope WITHOUT prices
  v_scope := coalesce(nullif(btrim(p_scope_of_work), ''),
    (select string_agg(qi.description || ' (' || qi.quantity || ' ' || qi.unit || ')', E'\n' order by qi.position)
       from public.quotation_items qi where qi.version_id = v.id));

  insert into public.bookings (booking_no, request_id, account_id, quotation_version_id,
                               scheduled_start, scheduled_end, confirmed_by)
  values ('pending', r.id, r.account_id, v.id, p_start, p_end, (select auth.uid()))
  returning id into v_booking;

  insert into public.jobs (job_no, booking_id, request_id, account_id, supervisor_id, scope_of_work,
                           site_address, site_contact_name, site_contact_phone, site_access_notes)
  values ('pending', v_booking, r.id, r.account_id, p_supervisor_id, v_scope,
          concat_ws(', ', p.address_line1, p.address_line2, p.postcode || ' ' || p.city, initcap(replace(p.state::text, '_', ' '))),
          r.contact_name, r.contact_phone, p.access_notes)
  returning id into v_job;

  perform private.set_request_status(r.id, 'booked');
  return jsonb_build_object('booking_id', v_booking, 'job_id', v_job);
end $$;

create function public.cancel_booking(p_booking_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare b public.bookings; j public.jobs;
begin
  perform private.require_role(array['admin']::public.app_role[]);
  if p_reason is null or length(btrim(p_reason)) < 3 then raise exception 'a reason is required'; end if;
  select * into b from public.bookings where id = p_booking_id for update;
  if not found or b.status <> 'confirmed' then raise exception 'booking is not active'; end if;
  select * into j from public.jobs where booking_id = b.id for update;
  if j.status <> 'scheduled' then raise exception 'work has already started on this job (%)', j.status; end if;

  update public.job_assignments set released_at = now(), release_reason = 'booking cancelled'
   where job_id = j.id and released_at is null;
  update public.jobs set status = 'cancelled', cancelled_reason = btrim(p_reason) where id = j.id;
  update public.bookings set status = 'cancelled', cancelled_reason = btrim(p_reason) where id = b.id;
  perform private.set_request_status(b.request_id, 'approved');
end $$;

create function public.create_change_order(
  p_job_id uuid, p_title text, p_description text default '', p_source_request_id uuid default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare j public.jobs; v_id uuid;
begin
  perform private.require_role(array['admin']::public.app_role[]);
  select * into j from public.jobs where id = p_job_id;
  if not found then raise exception 'job not found' using errcode = 'P0002'; end if;
  insert into public.change_orders (co_no, job_id, account_id, source_request_id, title, description, created_by)
  values ('pending', j.id, j.account_id, p_source_request_id, p_title, coalesce(p_description, ''), (select auth.uid()))
  returning id into v_id;
  if p_source_request_id is not null then
    update public.change_order_requests set status = 'converted', change_order_id = v_id
     where id = p_source_request_id and job_id = j.id and status = 'open';
    if not found then raise exception 'flagged work item not found or already resolved'; end if;
  end if;
  return v_id;
end $$;

create function public.send_change_order(p_co_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_role(array['admin']::public.app_role[]);
  update public.change_orders set status = 'sent', sent_at = now() where id = p_co_id and status = 'draft';
  if not found then raise exception 'only a draft change order can be sent'; end if;
end $$;

create function public.withdraw_change_order(p_co_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_role(array['admin']::public.app_role[]);
  update public.change_orders set status = 'withdrawn', response_note = p_reason
   where id = p_co_id and status in ('draft', 'sent');
  if not found then raise exception 'change order cannot be withdrawn'; end if;
end $$;

create function public.create_invoice_draft(p_job_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare j public.jobs; v_ver uuid; v_inv uuid; v_pos int;
begin
  perform private.require_role(array['admin']::public.app_role[]);
  select * into j from public.jobs where id = p_job_id for update;
  if not found then raise exception 'job not found' using errcode = 'P0002'; end if;
  if j.status <> 'verified' then raise exception 'the job must be verified by the supervisor first'; end if;
  if exists (select 1 from public.change_orders where job_id = j.id and status = 'sent') then
    raise exception 'a change order is still waiting for the customer''s decision';
  end if;
  if exists (select 1 from public.change_order_requests where job_id = j.id and status = 'open') then
    raise exception 'flagged extra work has not been triaged (convert or dismiss it)';
  end if;
  select v.id into v_ver from public.quotation_versions v
    join public.bookings b on b.quotation_version_id = v.id where b.id = j.booking_id;

  insert into public.invoices (job_id, request_id, account_id, created_by)
  values (j.id, j.request_id, j.account_id, (select auth.uid())) returning id into v_inv;

  insert into public.invoice_items (invoice_id, position, description, unit, quantity, unit_price, tax_rate, source_type, source_id)
  select v_inv, qi.position, qi.description, qi.unit, qi.quantity, qi.unit_price, qi.tax_rate, 'quotation_item', qi.id
    from public.quotation_items qi where qi.version_id = v_ver;

  select coalesce(max(position), 0) into v_pos from public.invoice_items where invoice_id = v_inv;
  insert into public.invoice_items (invoice_id, position, description, unit, quantity, unit_price, tax_rate, source_type, source_id)
  select v_inv, v_pos + row_number() over (order by c.created_at, ci.position),
         ci.description, ci.unit, ci.quantity, ci.unit_price, ci.tax_rate, 'change_order_item', ci.id
    from public.change_order_items ci join public.change_orders c on c.id = ci.change_order_id
   where c.job_id = j.id and c.status = 'approved';
  return v_inv;
end $$;

create function public.issue_invoice(p_invoice_id uuid, p_due_date date default null)
returns text language plpgsql security definer set search_path = '' as $$
declare i public.invoices; v_no text; v_issue date := private.today_my();
begin
  perform private.require_role(array['admin']::public.app_role[]);
  select * into i from public.invoices where id = p_invoice_id for update;
  if not found or i.status <> 'draft' then raise exception 'only a draft invoice can be issued'; end if;
  if i.total <= 0 then raise exception 'invoice total must be greater than zero'; end if;
  v_no := private.next_ref('INV');
  update public.invoices
     set status = 'issued', invoice_no = v_no, issue_date = v_issue,
         due_date = coalesce(p_due_date, v_issue + 14), issued_by = (select auth.uid())
   where id = i.id;
  return v_no;
end $$;

create function public.void_invoice(p_invoice_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_role(array['admin']::public.app_role[]);
  if p_reason is null or length(btrim(p_reason)) < 3 then raise exception 'a reason is required'; end if;
  update public.invoices set status = 'void', void_reason = btrim(p_reason)
   where id = p_invoice_id and status = 'issued';
  if not found then raise exception 'only an issued invoice without payments can be voided'; end if;
end $$;

create function public.void_payment(p_payment_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_role(array['admin']::public.app_role[]);
  if p_reason is null or length(btrim(p_reason)) < 3 then raise exception 'a reason is required'; end if;
  update public.payments set voided_at = now(), voided_by = (select auth.uid()), void_reason = btrim(p_reason)
   where id = p_payment_id and voided_at is null;
  if not found then raise exception 'payment not found or already voided'; end if;
end $$;

-- ============================== WORKER ======================================

create function public.start_job(p_job_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare j public.jobs;
begin
  perform private.require_role(array['worker']::public.app_role[]);
  select * into j from public.jobs where id = p_job_id for update;
  if not found or not private.is_assigned_to_job(j.id) then raise exception 'job not found' using errcode = 'P0002'; end if;
  if j.status not in ('scheduled', 'rework_required') then raise exception 'job cannot be started from status %', j.status; end if;
  update public.jobs set status = 'in_progress', started_at = coalesce(started_at, now()) where id = j.id;
  if j.status = 'scheduled' then perform private.set_request_status(j.request_id, 'in_progress'); end if;
  insert into public.job_progress_updates (job_id, author_id, note, progress_pct)
  values (j.id, (select auth.uid()),
          case j.status when 'scheduled' then 'Work started' else 'Rework started' end, null);
end $$;

create function public.submit_job_for_verification(p_job_id uuid, p_summary text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare j public.jobs; v_last_fail timestamptz;
begin
  perform private.require_role(array['worker']::public.app_role[]);
  select * into j from public.jobs where id = p_job_id for update;
  if not found or not private.is_assigned_to_job(j.id) then raise exception 'job not found' using errcode = 'P0002'; end if;
  if j.status <> 'in_progress' then raise exception 'only a job in progress can be submitted (%)', j.status; end if;

  select max(verified_at) into v_last_fail from public.job_verifications where job_id = j.id and result = 'failed';
  if not exists (select 1 from public.job_photos where job_id = j.id and kind = 'before') then
    raise exception 'at least one BEFORE photo is required';
  end if;
  if not exists (select 1 from public.job_photos
                  where job_id = j.id and kind = 'after' and created_at > coalesce(v_last_fail, '-infinity')) then
    raise exception 'at least one AFTER photo is required (taken since the last rejection)';
  end if;

  insert into public.job_progress_updates (job_id, author_id, note, progress_pct)
  values (j.id, (select auth.uid()), coalesce(nullif(btrim(p_summary), ''), 'Submitted for verification'), 100);
  update public.jobs set status = 'pending_verification', submitted_at = now() where id = j.id;
end $$;

-- ============================ SUPERVISOR ====================================

create function public.verify_job(p_job_id uuid, p_result public.verification_result, p_notes text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare j public.jobs;
begin
  perform private.require_role(array['supervisor']::public.app_role[]);
  select * into j from public.jobs where id = p_job_id for update;
  if not found or not private.is_job_supervisor(j.id) then raise exception 'job not found' using errcode = 'P0002'; end if;
  if j.status <> 'pending_verification' then raise exception 'job is not awaiting verification (%)', j.status; end if;

  insert into public.job_verifications (job_id, supervisor_id, result, notes)
  values (j.id, (select auth.uid()), p_result, nullif(btrim(p_notes), ''));

  if p_result = 'passed' then
    update public.jobs set status = 'verified', verified_at = now() where id = j.id;
    update public.bookings set status = 'completed' where id = j.booking_id;
    perform private.set_request_status(j.request_id, 'completed');
  else
    update public.jobs set status = 'rework_required' where id = j.id;
  end if;
end $$;

-- =============================== SYSTEM =====================================

create function public.expire_stale_quotations() returns int
language plpgsql security definer set search_path = '' as $$
declare n int := 0; r record;
begin
  for r in
    select v.id, q.request_id from public.quotation_versions v
      join public.quotations q on q.id = v.quotation_id
     where v.status = 'sent' and v.valid_until < private.today_my()
  loop
    update public.quotation_versions set status = 'expired' where id = r.id;
    perform private.set_request_status(r.request_id, 'under_review');
    n := n + 1;
  end loop;
  return n;
end $$;
