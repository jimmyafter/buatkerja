-- End-to-end workflow + access-control test. Run after all migrations (plain Postgres + stub).
-- Every "fails" line is a negative test: the action MUST be rejected.
create schema if not exists test;
grant usage on schema test to anon, authenticated;

create or replace function test.as_user(u uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', u::text, true); execute 'set local role authenticated'; end $$;
create or replace function test.as_system() returns void language plpgsql as $$
begin execute 'reset role'; perform set_config('request.jwt.claim.sub', '', true); end $$;
create or replace function test.fails(p_sql text, p_label text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then return; end;
  raise exception 'SHOULD HAVE FAILED: %', p_label;
end $$;
create or replace function test.count(p_sql text) returns bigint language plpgsql as $$
declare n bigint; begin execute 'select count(*) from (' || p_sql || ') s' into n; return n; end $$;
create or replace function test.affected(p_sql text) returns bigint language plpgsql as $$
declare n bigint; begin execute p_sql; get diagnostics n = row_count; return n; end $$;
create or replace function test.eq(a anyelement, b anyelement, p_label text) returns void language plpgsql as $$
begin if a is distinct from b then raise exception 'ASSERT % : got %, expected %', p_label, a, b; end if; end $$;

do $$
declare
  cA uuid := 'a0000000-0000-0000-0000-00000000000a'; cB uuid := 'b0000000-0000-0000-0000-00000000000b';
  adm uuid := 'ad000000-0000-0000-0000-0000000000ad'; fin uuid := 'f1000000-0000-0000-0000-0000000000f1'; sa uuid := '5a000000-0000-0000-0000-0000000000a5'; sup uuid := '50000000-0000-0000-0000-000000000005';
  u1 uuid := '11000000-0000-0000-0000-000000000001'; u2 uuid := '22000000-0000-0000-0000-000000000002';
  u3 uuid := '33000000-0000-0000-0000-000000000003';
  w1 uuid; w2 uuid; w3 uuid; partner uuid;
  accA uuid; accB uuid; propA uuid; propB uuid; cat uuid; req uuid;
  ver1 uuid; ver2 uuid; qid uuid; bk jsonb; job uuid; co uuid; cor uuid; inv uuid; pay uuid;
  s text; n bigint;
begin
  -- ---------- seed users (profiles auto-created as customers) ----------
  insert into auth.users (id, email) values
    (cA,'a@x.my'),(cB,'b@x.my'),(adm,'ops@x.my'),(fin,'fin@x.my'),(sa,'super@x.my'),(sup,'sup@x.my'),(u1,'w1@x.my'),(u2,'w2@x.my'),(u3,'w3@x.my');
  perform test.eq((select role::text from profiles where id = cA), 'customer', 'new users default to customer');
  update profiles set role='ops_admin' where id = adm;
  update profiles set role='finance_admin' where id = fin;
  update profiles set role='super_admin' where id = sa;
  update profiles set role='supervisor' where id = sup;
  update profiles set role='worker' where id in (u1,u2,u3);
  insert into workers (profile_id, worker_type, approval_status, approved_by, approved_at) values (u1,'employee','approved',adm,now()) returning id into w1;
  insert into workers (profile_id, worker_type, approval_status, approved_by, approved_at) values (u2,'employee','approved',adm,now()) returning id into w2;
  insert into outsource_partners (name, ssm_registration_no) values ('Maju Sdn Bhd','202001000001') returning id into partner;
  insert into workers (profile_id, worker_type, partner_id, approval_status, approved_by, approved_at) values (u3,'outsourced',partner,'approved',adm,now()) returning id into w3;
  select id into cat from service_categories where slug='plumbing';

  -- ---------- customers onboard ----------
  perform test.as_user(cA); accA := public.create_customer_account('individual','Ali');
  perform test.fails($q$select public.create_customer_account('individual','Ali 2')$q$, 'second account for same user');
  perform test.as_user(cB); accB := public.create_customer_account('business','Budi Properties','Budi Properties Sdn Bhd','202101000002');
  insert into properties (account_id,label,address_line1,city,state,postcode) values (accB,'Office','5 Jalan B','KL','kuala_lumpur','50000') returning id into propB;
  perform test.as_user(cA);
  insert into properties (account_id,label,address_line1,city,state,postcode) values (accA,'Home','1 Jalan A','Petaling Jaya','selangor','47500') returning id into propA;
  perform test.fails(format($q$insert into properties (account_id,label,address_line1,city,state,postcode) values (%L,'x','y','z','johor','80000')$q$, accB), 'property in another account');

  -- ---------- request creation guards ----------
  perform test.fails(format($q$insert into service_requests (account_id,property_id,category_id,title) values (%L,%L,%L,'Leak')$q$, accB, propB, cat), 'request in other account');
  perform test.fails(format($q$insert into service_requests (account_id,property_id,category_id,title) values (%L,%L,%L,'Leak')$q$, accA, propB, cat), 'request with foreign property (composite FK)');
  perform test.fails(format($q$insert into service_requests (account_id,property_id,category_id,title,status,submitted_at) values (%L,%L,%L,'Leak','submitted',now())$q$, accA, propA, cat), 'client creates non-draft');
  insert into service_requests (account_id,property_id,category_id,title,description,contact_name,contact_phone,submitted_by)
    values (accA, propA, cat, 'Kitchen sink leaking', 'Water leaks under the kitchen sink every morning', 'Ali', '0123456789', cA) returning id into req;
  perform test.eq((select request_no like 'SR-____-_____' from service_requests where id=req), true, 'request number assigned');
  perform test.fails(format($q$update service_requests set status='submitted' where id=%L$q$, req), 'client sets status directly');
  -- attachments (storage + table)
  insert into storage.objects (bucket_id, name) values ('request-attachments', accA||'/'||req||'/leak.jpg');
  perform test.fails(format($q$insert into storage.objects (bucket_id,name) values ('request-attachments', %L)$q$, accB||'/'||req||'/x.jpg'), 'upload into another account folder');
  perform test.as_user(cB);
  perform test.eq(test.count('select 1 from storage.objects'), 0::bigint, 'other customer cannot see attachment objects');
  perform test.fails(format($q$select public.submit_service_request(%L)$q$, req), 'other customer submits my request');
  perform test.eq(test.count('select 1 from service_requests'), 0::bigint, 'other customer sees no requests');
  perform test.as_user(cA);
  perform public.submit_service_request(req);
  perform test.eq((select status::text from service_requests where id=req), 'submitted', 'submitted');
  perform test.eq(test.affected(format($q$update service_requests set title='Changed' where id=%L$q$, req)), 0::bigint, 'submitted request no longer editable by customer');
  perform test.eq(test.count('select 1 from storage.objects'), 1::bigint, 'owner sees own attachment');
  perform test.fails($q$update profiles set role='admin' where id='a0000000-0000-0000-0000-00000000000a'$q$, 'self-promotion to admin');

  -- ---------- workers/supervisors cannot see customer data ----------
  perform test.as_user(u1);
  perform test.eq(test.count('select 1 from service_requests'), 0::bigint, 'worker sees no requests');
  perform test.eq(test.count('select 1 from customer_accounts'), 0::bigint, 'worker sees no accounts');

  -- ---------- admin: review & quote ----------
  perform test.as_user(adm);
  perform public.review_service_request(req, 'start_review');
  ver1 := public.create_quotation(req, current_date + 7, 'Replace trap and supply lines');
  select quotation_id into qid from quotation_versions where id = ver1;
  insert into quotation_items (version_id, position, description, unit, quantity, unit_price, tax_rate) values
    (ver1,1,'Replace sink trap','pc',2,150,8),(ver1,2,'Labour','job',1,200,8),(ver1,3,'Goodwill discount','lot',1,-40,8);
  select total::text into s from quotation_versions where id = ver1;
  perform test.eq(s, '496.80', 'quotation total computed from items');
  perform test.as_user(cA);
  perform test.eq(test.count('select 1 from quotation_versions'), 0::bigint, 'customer cannot see draft quotation');
  perform test.eq(test.count('select 1 from quotation_items'), 0::bigint, 'customer cannot see draft items');
  perform test.as_user(adm);
  perform test.fails(format($q$update quotation_versions set total=1 where id=%L$q$, ver1), 'client-written totals');
  perform public.send_quotation_version(ver1);
  perform test.fails(format($q$update quotation_versions set scope_summary='cheaper' where id=%L$q$, ver1), 'edit sent version');
  perform test.fails(format($q$insert into quotation_items (version_id,position,description,quantity,unit_price) values (%L,9,'sneaky',1,1)$q$, ver1), 'add item to sent version');
  perform test.fails(format($q$delete from quotation_versions where id=%L$q$, ver1), 'delete sent version');
  perform test.fails(format($q$update service_requests set status='approved' where id=%L$q$, req), 'admin bypasses customer approval');
  -- revision keeps history
  ver2 := public.create_quotation_revision(qid);
  update quotation_items set unit_price = 140 where version_id = ver2 and position = 1;   -- 2*140=280
  perform public.send_quotation_version(ver2);
  perform test.eq((select status::text from quotation_versions where id=ver1), 'superseded', 'v1 superseded');
  perform test.eq((select count(*) from quotation_versions where quotation_id=qid), 2::bigint, 'history preserved');
  perform test.as_user(cB);
  perform test.fails(format($q$select public.respond_to_quotation(%L,'approve')$q$, ver2), 'other customer approves');
  perform test.as_user(adm);
  perform test.fails(format($q$select public.respond_to_quotation(%L,'approve')$q$, ver2), 'admin uses the customer-only approval function');
  perform test.fails(format($q$select public.record_quotation_response(%L,'approve','ok')$q$, ver2), 'admin-recorded approval without evidence note');
  perform test.as_user(cA);
  perform test.fails(format($q$select public.record_quotation_response(%L,'approve','Customer said yes on WhatsApp')$q$, ver2), 'customer uses admin-record function');
  perform test.as_user(adm);
  perform test.as_user(cA);
  perform test.fails(format($q$select public.respond_to_quotation(%L,'approve')$q$, ver1), 'approve superseded version');
  perform test.eq(test.count('select 1 from quotation_versions'), 2::bigint, 'customer sees sent+superseded versions');
  perform public.respond_to_quotation(ver2, 'approve', 'OK go ahead');
  perform test.eq((select status::text from service_requests where id=req), 'approved', 'request approved');

  -- ---------- booking & assignment ----------
  perform test.as_user(adm);
  perform test.fails(format($q$select public.confirm_booking(%L, now() - interval '1 day', now(), %L)$q$, req, sup), 'booking in the past');
  perform test.fails(format($q$select public.confirm_booking(%L, now() + interval '1 day', now() + interval '2 day', %L)$q$, req, u1), 'non-supervisor as supervisor');
  bk := public.confirm_booking(req, now() + interval '1 day', now() + interval '1 day 4 hour', sup);
  job := (bk ->> 'job_id')::uuid;
  perform test.eq((select status::text from service_requests where id=req), 'booked', 'request booked');
  perform test.fails(format($q$insert into job_assignments (job_id,worker_id,assigned_by) values (%L,%L,%L)$q$, job, w3, adm), 'outsourced worker with unapproved partner');
  update outsource_partners set approval_status='approved' where id=partner;
  update outsource_partners set approval_status='suspended' where id=partner;
  perform test.fails(format($q$insert into job_assignments (job_id,worker_id,assigned_by) values (%L,%L,%L)$q$, job, w3, adm), 'outsourced worker with suspended partner');
  update workers set approval_status='pending' where id=w2;
  perform test.fails(format($q$insert into job_assignments (job_id,worker_id,assigned_by) values (%L,%L,%L)$q$, job, w2, adm), 'unapproved worker');
  update workers set approval_status='approved' where id=w2;
  insert into job_assignments (job_id, worker_id, assignment_role, assigned_by) values (job, w1, 'lead', adm);
  perform test.fails(format($q$insert into job_assignments (job_id,worker_id,assignment_role,assigned_by) values (%L,%L,'lead',%L)$q$, job, w2, adm), 'two leads');

  -- visibility by role
  perform test.as_user(u1); perform test.eq(test.count('select 1 from jobs'), 1::bigint, 'assigned worker sees job');
  perform test.eq(test.count('select 1 from quotation_versions'), 0::bigint, 'worker sees no quotation prices');
  perform test.eq(test.count('select 1 from properties'), 0::bigint, 'worker sees no properties');
  perform test.eq(test.count('select 1 from invoices'), 0::bigint, 'worker sees no invoices');
  perform test.as_user(u2); perform test.eq(test.count('select 1 from jobs'), 0::bigint, 'unassigned worker sees no job');
  perform test.fails(format($q$select public.start_job(%L)$q$, job), 'unassigned worker starts job');
  perform test.as_user(sup); perform test.eq(test.count('select 1 from jobs'), 1::bigint, 'supervisor sees own job');
  perform test.eq(test.count('select 1 from service_requests'), 0::bigint, 'supervisor sees no requests');
  perform test.as_user(cA); perform test.eq(test.count('select 1 from jobs'), 1::bigint, 'customer sees own job');
  perform test.eq(test.count('select 1 from job_assignments'), 0::bigint, 'customer sees no assignments');
  perform test.as_user(cB); perform test.eq(test.count('select 1 from jobs'), 0::bigint, 'other customer sees no job');

  -- ---------- delivery & evidence ----------
  perform test.as_user(u1);
  perform test.fails(format($q$insert into job_progress_updates (job_id,author_id,note) values (%L,%L,'too early')$q$, job, u1), 'progress before start');
  perform public.start_job(job);
  insert into job_progress_updates (job_id, author_id, note, progress_pct) values (job, u1, 'Old trap removed', 40);
  insert into storage.objects (bucket_id, name) values ('job-photos', job||'/before1.jpg');
  perform test.fails(format($q$insert into storage.objects (bucket_id,name) values ('job-photos', %L)$q$, gen_random_uuid()||'/x.jpg'), 'photo into foreign job folder');
  insert into job_photos (job_id, kind, storage_path, uploaded_by) values (job,'before',job||'/before1.jpg',u1);
  perform test.fails(format($q$select public.submit_job_for_verification(%L)$q$, job), 'submit without after photo');
  insert into job_photos (job_id, kind, storage_path, uploaded_by) values (job,'after',job||'/after1.jpg',u1);
  insert into job_photos (job_id, kind, storage_path, uploaded_by) values (job,'progress',job||'/mid.jpg',u1);
  perform test.fails(format($q$update job_photos set caption='edited' where job_id=%L$q$, job), 'edit evidence photo');
  perform test.fails(format($q$delete from job_photos where job_id=%L$q$, job), 'delete evidence photo');
  perform test.fails(format($q$update job_progress_updates set note='rewritten' where job_id=%L$q$, job), 'rewrite progress');
  insert into change_order_requests (job_id, raised_by, description) values (job, u1, 'Corroded valve needs replacing') returning id into cor;
  perform test.eq(test.affected(format($q$update jobs set status='verified' where id=%L$q$, job)), 0::bigint, 'worker cannot update jobs (RLS filters row)');
  perform public.submit_job_for_verification(job, 'All done');
  perform test.eq((select status::text from jobs where id=job), 'pending_verification', 'pending verification');
  perform test.fails(format($q$insert into job_photos (job_id,kind,storage_path,uploaded_by) values (%L,'after',%L,%L)$q$, job, job||'/late.jpg', u1), 'photo after submission');

  -- ---------- additional chargeable work ----------
  perform test.as_user(adm);
  co := public.create_change_order(job, 'Replace corroded valve', 'Found during works', cor);
  insert into change_order_items (change_order_id, position, description, quantity, unit_price, tax_rate) values (co,1,'Brass valve',1,100,8);
  perform test.as_user(cA); perform test.eq(test.count('select 1 from change_orders'), 0::bigint, 'draft CO hidden from customer');
  perform test.as_user(adm); perform public.send_change_order(co);
  perform test.fails(format($q$update change_order_items set unit_price=1 where change_order_id=%L$q$, co), 'edit sent CO items');

  -- ---------- verification (segregation: only the named supervisor) ----------
  perform test.as_user(u1); perform test.fails(format($q$select public.verify_job(%L,'passed')$q$, job), 'worker verifies');
  perform test.as_user(adm); perform test.fails(format($q$select public.verify_job(%L,'passed')$q$, job), 'admin verifies');
  perform test.as_user(sup);
  perform test.fails(format($q$select public.verify_job(%L,'failed')$q$, job), 'fail without notes');
  perform public.verify_job(job, 'passed', 'Looks good');
  perform test.as_system();
  perform test.eq((select status::text from service_requests where id=(select request_id from jobs where id=job)), 'completed', 'request completed');
  perform test.as_user(cA);
  perform test.eq(test.count('select 1 from job_photos'), 2::bigint, 'customer sees before/after only after verification');
  perform test.eq(test.count('select 1 from job_progress_updates'), 0::bigint, 'customer never sees internal progress notes');

  -- ---------- invoicing ----------
  perform test.as_user(adm);
  perform test.fails(format($q$select public.create_invoice_draft(%L)$q$, job), 'ops admin cannot raise invoices');
  perform test.as_user(fin);
  perform test.fails(format($q$select public.create_invoice_draft(%L)$q$, job), 'invoice while CO awaits customer');
  perform test.as_user(adm);
  perform test.fails(format($q$select public.record_change_order_response(%L,'approve','short')$q$, co), 'offline CO approval without evidence');
  perform public.record_change_order_response(co, 'approve', 'Mr Ali approved by WhatsApp 24 Nov 15:10');
  perform test.eq((select response_channel from change_orders where id=co), 'admin_recorded', 'channel flagged admin_recorded');
  perform test.eq((select responded_by from change_orders where id=co), adm, 'ops admin recorded as responder');
  perform test.as_user(cA);
  perform test.eq(test.count($q$select 1 from service_request_events where note like '%recorded by our team on your behalf%'$q$), 1::bigint, 'customer sees the recorded-on-behalf note');
  perform test.eq((select response_channel from quotation_versions where id=ver2), 'portal', 'customer approval channel is portal');
  perform test.as_user(fin);
  perform test.as_user(fin);
  perform test.as_user(fin);
  inv := public.create_invoice_draft(job);
  select total::text into s from invoices where id = inv;
  perform test.eq(s, '583.20', 'invoice = approved v2 (475.20) + approved CO (108.00)');
  perform test.eq((select count(*) from invoice_items where invoice_id=inv), 4::bigint, 'invoice lines copied from approved sources');
  perform test.eq(test.affected(format($q$update invoice_items set quantity = 99 where invoice_id=%L and position=1$q$, inv)), 0::bigint, 'admin cannot edit source-linked invoice line (RLS)');
  perform test.fails(format($q$insert into invoice_items (invoice_id,position,description,quantity,unit_price,source_type,source_id) values (%L,9,'Made up',1,500,'quotation_item',(select id from quotation_items where version_id=%L limit 1))$q$, inv, ver2), 'invoice line not matching approved line');
  perform test.fails(format($q$insert into invoice_items (invoice_id,position,description,quantity,unit_price,source_type,source_id) select %L,9,description,quantity,unit_price,'quotation_item',id from quotation_items where version_id=%L limit 1$q$, inv, ver1), 'line from superseded (unapproved) version');
  perform test.as_user(cA); perform test.eq(test.count('select 1 from invoices'), 0::bigint, 'draft invoice hidden from customer');
  perform test.as_user(fin);
  perform test.fails(format($q$update invoices set status='paid' where id=%L$q$, inv), 'admin marks invoice paid directly');
  perform test.fails(format($q$insert into payments (invoice_id,account_id,amount,method,recorded_by) values (%L,%L,10,'cash',%L)$q$, inv, accA, fin), 'payment on draft invoice');
  perform public.issue_invoice(inv);
  perform test.eq((select status::text from service_requests where id=req), 'invoiced', 'request invoiced');
  perform test.fails(format($q$insert into invoice_items (invoice_id,position,description,quantity,unit_price,source_type) values (%L,20,'late',1,1,'adjustment')$q$, inv), 'edit issued invoice');
  perform test.as_user(cA); perform test.eq(test.count('select 1 from invoices'), 1::bigint, 'customer sees issued invoice');
  perform test.as_user(cB); perform test.eq(test.count('select 1 from invoices'), 0::bigint, 'other customer sees no invoice');
  perform test.as_user(fin);
  insert into payments (invoice_id, account_id, amount, method, reference, recorded_by) values (inv, accA, 300, 'bank_transfer', 'TRX1', fin) returning id into pay;
  perform test.eq((select status::text from invoices where id=inv), 'partially_paid', 'partial payment');
  perform test.fails(format($q$insert into payments (invoice_id,account_id,amount,method,recorded_by) values (%L,%L,300,'cash',%L)$q$, inv, accA, fin), 'overpayment');
  perform test.fails(format($q$update payments set amount=1 where id=%L$q$, pay), 'edit payment');
  perform test.fails(format($q$delete from payments where id=%L$q$, pay), 'delete payment');
  insert into payments (invoice_id, account_id, amount, method, recorded_by) values (inv, accA, 283.20, 'duitnow_qr', fin);
  perform test.eq((select status::text from invoices where id=inv), 'paid', 'fully paid');
  perform test.eq((select status::text from service_requests where id=req), 'closed', 'request closed');
  perform public.void_payment(pay, 'Bounced');
  perform test.eq((select status::text from invoices where id=inv), 'partially_paid', 'void payment reopens balance');
  perform test.eq((select status::text from service_requests where id=req), 'invoiced', 'request reopened to invoiced');

  -- ---------- audit ----------
  perform test.as_user(adm); perform test.eq(test.count('select 1 from audit_logs'), 0::bigint, 'ops admin cannot read audit');
  perform test.as_user(fin); perform test.fails(format($q$select public.create_quotation(%L)$q$, req), 'finance cannot create quotations');
  perform test.as_user(sa);
  perform test.eq(test.count('select 1 from audit_logs'), test.count('select 1 from audit_logs'), 'admin reads audit');
  perform test.eq((test.count('select 1 from audit_logs where table_name=''payments'''))>=3, true, 'payments audited');
  perform test.eq((test.count('select 1 from audit_logs where table_name=''quotation_versions'''))>=4, true, 'quotation versions audited');
  perform test.as_user(cA); perform test.eq(test.count('select 1 from audit_logs'), 0::bigint, 'customer cannot read audit');
  perform test.as_user(sa); perform test.fails('delete from audit_logs', 'delete audit');
  perform test.fails('update audit_logs set action=''INSERT''', 'edit audit');
  perform test.as_system();
  perform test.fails('delete from audit_logs', 'superuser delete audit (trigger)');
  perform test.eq((select count(*) from audit_logs where actor_id = adm and table_name='service_requests') > 0, true, 'actor recorded');

  -- ---------- customer anon access ----------
  execute 'set local role anon';
  perform test.eq(test.count('select 1 from service_categories'), 8::bigint, 'anon can list services');
  perform test.fails('select 1 from service_requests', 'anon reads requests');
  perform test.as_system();
  raise notice 'ALL WORKFLOW + RLS TESTS PASSED';
end $$;
