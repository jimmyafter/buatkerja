-- ============================================================================
-- 011 Row Level Security + privileges
-- Principles
--   * deny by default: RLS on every table, explicit grants only where needed
--   * customers: only rows of accounts they belong to, never drafts of staff documents
--   * workers : only jobs they are CURRENTLY assigned to; no prices, no customer records
--   * supervisors: only jobs where they are the named supervisor
--   * back office: ops admin (operations), finance admin (billing, costs), super admin (all + users/audit);
--     still bound by integrity triggers
--   * status changes never come from table writes (guard triggers + RPCs)
-- ============================================================================

-- Privileges --------------------------------------------------------------------
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

grant select, update                         on public.profiles                    to authenticated;
grant select, insert, update                 on public.customer_accounts           to authenticated;
grant select, insert, update, delete         on public.customer_members            to authenticated;
grant select, insert, update, delete         on public.properties                  to authenticated;
grant select, insert                         on public.internal_notes              to authenticated;
grant select                                 on public.service_categories          to anon, authenticated;
grant insert, update, delete                 on public.service_categories          to authenticated;
grant select, insert, update, delete         on public.service_requests            to authenticated;
grant select, insert, delete                 on public.service_request_attachments to authenticated;
grant select, insert                         on public.service_request_events      to authenticated;
grant select, insert                         on public.quotations                  to authenticated;
grant select, update, delete                 on public.quotation_versions          to authenticated;
grant select, insert, update, delete         on public.quotation_items             to authenticated;
grant select, insert, update                 on public.outsource_partners          to authenticated;
grant select, insert, update                 on public.workers                     to authenticated;
grant select, insert, delete                 on public.worker_categories           to authenticated;
grant select, update                         on public.bookings                    to authenticated;
grant select, update                         on public.jobs                        to authenticated;
grant select, insert, update                 on public.job_assignments             to authenticated;
grant select, insert                         on public.job_progress_updates        to authenticated;
grant select, insert                         on public.job_photos                  to authenticated;
grant select                                 on public.job_verifications           to authenticated;
grant select, insert, update                 on public.change_order_requests       to authenticated;
grant select, insert, update                 on public.change_orders               to authenticated;
grant select, insert, update, delete         on public.change_order_items          to authenticated;
grant select, update, delete                 on public.invoices                    to authenticated;
grant select, insert, update, delete         on public.invoice_items               to authenticated;
grant select, insert                         on public.payments                    to authenticated;
grant select                                 on public.audit_logs                  to authenticated;
-- doc_counters: no client access at all

-- RPCs callable by signed-in users (each checks the caller's role internally)
grant execute on function
  public.create_customer_account(public.account_type, text, text, text, text, text),
  public.submit_service_request(uuid, text),
  public.cancel_service_request(uuid, text),
  public.respond_to_quotation(uuid, text, text),
  public.respond_to_change_order(uuid, text, text),
  public.record_quotation_response(uuid, text, text),
  public.record_change_order_response(uuid, text, text),
  public.review_service_request(uuid, text, text),
  public.create_quotation(uuid, date, text),
  public.create_quotation_revision(uuid),
  public.send_quotation_version(uuid),
  public.withdraw_quotation_version(uuid, text),
  public.confirm_booking(uuid, timestamptz, timestamptz, uuid, text),
  public.cancel_booking(uuid, text),
  public.create_change_order(uuid, text, text, uuid),
  public.send_change_order(uuid),
  public.withdraw_change_order(uuid, text),
  public.create_invoice_draft(uuid),
  public.issue_invoice(uuid, date),
  public.void_invoice(uuid, text),
  public.void_payment(uuid, text),
  public.start_job(uuid),
  public.submit_job_for_verification(uuid, text),
  public.verify_job(uuid, public.verification_result, text, smallint)
to authenticated;
grant execute on function public.expire_stale_quotations() to service_role;

-- Helpers used inside policies/triggers execute as the caller
grant execute on all functions in schema private to authenticated, service_role;

-- Enable RLS everywhere ------------------------------------------------------------
do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t.tablename);
  end loop;
end $$;
-- doc_counters has RLS on and no policy => unreachable for clients.

-- profiles --------------------------------------------------------------------------
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select private.is_back_office())
         or (select private.supervisor_sees_profile(id)));
create policy profiles_update on public.profiles for update to authenticated
  using (id = (select auth.uid()) or (select private.is_super_admin()))
  with check (id = (select auth.uid()) or (select private.is_super_admin()));

-- customers, members, properties ------------------------------------------------------
create policy accounts_select on public.customer_accounts for select to authenticated
  using ((select private.is_account_member(id)) or (select private.is_back_office()));
create policy accounts_insert on public.customer_accounts for insert to authenticated
  with check ((select private.is_ops()));
create policy accounts_update on public.customer_accounts for update to authenticated
  using ((select private.is_account_owner(id)) or (select private.is_ops()))
  with check ((select private.is_account_owner(id)) or (select private.is_ops()));

create policy members_select on public.customer_members for select to authenticated
  using ((select private.is_account_member(account_id)) or (select private.is_back_office()));
create policy members_admin_write on public.customer_members for all to authenticated
  using ((select private.is_ops())) with check ((select private.is_ops()));

create policy properties_select on public.properties for select to authenticated
  using ((select private.is_account_member(account_id)) or (select private.is_back_office()));
create policy properties_insert on public.properties for insert to authenticated
  with check ((select private.is_account_member(account_id)) or (select private.is_ops()));
create policy properties_update on public.properties for update to authenticated
  using ((select private.is_account_member(account_id)) or (select private.is_ops()))
  with check ((select private.is_account_member(account_id)) or (select private.is_ops()));
create policy properties_delete on public.properties for delete to authenticated
  using ((select private.is_ops()));

create policy notes_admin on public.internal_notes for select to authenticated
  using ((select private.is_back_office()));
create policy notes_admin_insert on public.internal_notes for insert to authenticated
  with check ((select private.is_back_office()) and author_id = (select auth.uid()));

-- catalogue ---------------------------------------------------------------------------
create policy categories_read on public.service_categories for select to anon, authenticated
  using (is_active or (select private.is_back_office()));
create policy categories_admin on public.service_categories for all to authenticated
  using ((select private.is_ops())) with check ((select private.is_ops()));

-- service requests ----------------------------------------------------------------------
create policy requests_select on public.service_requests for select to authenticated
  using ((select private.is_account_member(account_id)) or (select private.is_back_office()));
create policy requests_insert on public.service_requests for insert to authenticated
  with check (status = 'draft' and ((select private.is_account_member(account_id)) or (select private.is_ops())));
create policy requests_update on public.service_requests for update to authenticated
  using ((select private.is_ops()) or ((select private.is_account_member(account_id)) and status = 'draft'))
  with check ((select private.is_ops()) or ((select private.is_account_member(account_id)) and status = 'draft'));
create policy requests_delete on public.service_requests for delete to authenticated
  using (status = 'draft' and ((select private.is_account_member(account_id)) or (select private.is_ops())));

create policy attachments_select on public.service_request_attachments for select to authenticated
  using ((select private.is_account_member(account_id)) or (select private.is_back_office()));
create policy attachments_insert on public.service_request_attachments for insert to authenticated
  with check (uploaded_by = (select auth.uid())
              and ((select private.can_attach_to_request(request_id, account_id)) or (select private.is_ops())));
create policy attachments_delete on public.service_request_attachments for delete to authenticated
  using ((select private.can_attach_to_request(request_id, account_id)) or (select private.is_ops()));

create policy events_select on public.service_request_events for select to authenticated
  using ((select private.is_back_office())
         or (visible_to_customer and exists (select 1 from public.service_requests r where r.id = request_id)));
create policy events_admin_insert on public.service_request_events for insert to authenticated
  with check ((select private.is_ops()) and event_type = 'note' and actor_id = (select auth.uid()));

-- quotations (customers never see drafts) -------------------------------------------------
create policy quotations_select on public.quotations for select to authenticated
  using ((select private.is_back_office()) or (select private.customer_can_see_quotation(id)));
create policy quotations_insert on public.quotations for insert to authenticated
  with check ((select private.is_ops()));
create policy versions_select on public.quotation_versions for select to authenticated
  using ((select private.is_back_office()) or (select private.customer_can_see_version(id)));
create policy versions_admin_update on public.quotation_versions for update to authenticated
  using ((select private.is_ops())) with check ((select private.is_ops()));
create policy versions_admin_delete on public.quotation_versions for delete to authenticated
  using ((select private.is_ops()));
create policy qitems_select on public.quotation_items for select to authenticated
  using ((select private.is_back_office()) or (select private.customer_can_see_version(version_id)));
create policy qitems_admin_write on public.quotation_items for all to authenticated
  using ((select private.is_ops())) with check ((select private.is_ops()));

-- workforce -----------------------------------------------------------------------------------
create policy partners_admin on public.outsource_partners for all to authenticated
  using ((select private.is_ops())) with check ((select private.is_ops()));
create policy workers_select on public.workers for select to authenticated
  using (profile_id = (select auth.uid()) or (select private.is_back_office())
         or (select private.supervisor_sees_worker(id)));
create policy workers_admin_write on public.workers for insert to authenticated
  with check ((select private.is_ops()));
create policy workers_admin_update on public.workers for update to authenticated
  using ((select private.is_ops())) with check ((select private.is_ops()));
create policy wcat_select on public.worker_categories for select to authenticated
  using ((select private.is_back_office()) or worker_id = (select private.my_worker_id()));
create policy wcat_admin_write on public.worker_categories for all to authenticated
  using ((select private.is_ops())) with check ((select private.is_ops()));

-- bookings & jobs --------------------------------------------------------------------------------
create policy bookings_select on public.bookings for select to authenticated
  using ((select private.is_back_office()) or (select private.is_account_member(account_id)));
create policy bookings_admin_update on public.bookings for update to authenticated
  using ((select private.is_ops())) with check ((select private.is_ops()));

create policy jobs_select on public.jobs for select to authenticated
  using ((select private.is_back_office()) or (select private.is_account_member(account_id))
         or (select private.is_assigned_to_job(id)) or (select private.is_job_supervisor(id)));
create policy jobs_admin_update on public.jobs for update to authenticated
  using ((select private.is_ops())) with check ((select private.is_ops()));

create policy assignments_select on public.job_assignments for select to authenticated
  using ((select private.is_back_office()) or worker_id = (select private.my_worker_id())
         or (select private.is_job_supervisor(job_id)));
create policy assignments_admin_insert on public.job_assignments for insert to authenticated
  with check ((select private.is_ops()));
create policy assignments_admin_update on public.job_assignments for update to authenticated
  using ((select private.is_ops())) with check ((select private.is_ops()));

-- delivery evidence -----------------------------------------------------------------------------------
create policy progress_select on public.job_progress_updates for select to authenticated
  using ((select private.is_back_office()) or (select private.is_assigned_to_job(job_id))
         or (select private.is_job_supervisor(job_id)));
create policy progress_insert on public.job_progress_updates for insert to authenticated
  with check (author_id = (select auth.uid())
              and ((select private.is_assigned_to_job(job_id)) or (select private.is_job_supervisor(job_id))
                   or (select private.is_ops())));

create policy photos_select on public.job_photos for select to authenticated
  using ((select private.is_back_office()) or (select private.is_assigned_to_job(job_id))
         or (select private.is_job_supervisor(job_id))
         or (select private.customer_can_see_job_photo(job_id, kind)));
create policy photos_insert on public.job_photos for insert to authenticated
  with check (uploaded_by = (select auth.uid()) and (select private.is_assigned_to_job(job_id)));

create policy verifications_select on public.job_verifications for select to authenticated
  using ((select private.is_back_office()) or (select private.is_job_supervisor(job_id))
         or (select private.is_assigned_to_job(job_id)));

-- change orders -------------------------------------------------------------------------------------------
create policy cor_select on public.change_order_requests for select to authenticated
  using ((select private.is_back_office()) or raised_by = (select auth.uid())
         or (select private.is_job_supervisor(job_id)));
create policy cor_insert on public.change_order_requests for insert to authenticated
  with check (raised_by = (select auth.uid()) and (select private.is_assigned_to_job(job_id)));
create policy cor_admin_update on public.change_order_requests for update to authenticated
  using ((select private.is_ops())) with check ((select private.is_ops()));

create policy co_select on public.change_orders for select to authenticated
  using ((select private.is_back_office()) or (select private.customer_can_see_change_order(id)));
create policy co_admin_insert on public.change_orders for insert to authenticated
  with check ((select private.is_ops()));
create policy co_admin_update on public.change_orders for update to authenticated
  using ((select private.is_ops())) with check ((select private.is_ops()));
create policy coitems_select on public.change_order_items for select to authenticated
  using ((select private.is_back_office()) or (select private.customer_can_see_change_order(change_order_id)));
create policy coitems_admin_write on public.change_order_items for all to authenticated
  using ((select private.is_ops())) with check ((select private.is_ops()));

-- billing ------------------------------------------------------------------------------------------------------
create policy invoices_select on public.invoices for select to authenticated
  using ((select private.is_back_office()) or (select private.customer_can_see_invoice(id)));
create policy invoices_admin_update on public.invoices for update to authenticated
  using ((select private.is_finance())) with check ((select private.is_finance()));
create policy invoices_admin_delete on public.invoices for delete to authenticated
  using ((select private.is_finance()));
create policy invitems_select on public.invoice_items for select to authenticated
  using ((select private.is_back_office()) or (select private.customer_can_see_invoice(invoice_id)));
-- admins may only hand-edit ADJUSTMENT lines; source-linked lines come from approved documents
create policy invitems_admin_write on public.invoice_items for all to authenticated
  using ((select private.is_finance()) and source_type = 'adjustment')
  with check ((select private.is_finance()) and source_type = 'adjustment');

create policy payments_select on public.payments for select to authenticated
  using ((select private.is_back_office()) or (select private.customer_can_see_invoice(invoice_id)));
create policy payments_admin_insert on public.payments for insert to authenticated
  with check ((select private.is_finance()) and recorded_by = (select auth.uid()));

-- audit -----------------------------------------------------------------------------------------------------------
create policy audit_admin_select on public.audit_logs for select to authenticated
  using ((select private.is_super_admin()));
