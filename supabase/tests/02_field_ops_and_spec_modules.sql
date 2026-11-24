-- Spec modules: availability + double-booking rule, checklist, travel/arrival, materials,
-- inspections, job costs, feedback, reports, notifications, settings, audit coverage.
-- Run after 01 (reuses its test.* helpers). Uses its own users.
do $$
declare
  cu uuid := 'c2000000-0000-0000-0000-0000000000c2'; cx uuid := 'c3000000-0000-0000-0000-0000000000c3';
  ops uuid := 'a2000000-0000-0000-0000-0000000000a2'; fin uuid := 'f2000000-0000-0000-0000-0000000000f2';
  sa uuid := '5b000000-0000-0000-0000-0000000000b5'; sup uuid := '52000000-0000-0000-0000-000000000052';
  u1 uuid := '12000000-0000-0000-0000-000000000012'; u2 uuid := '23000000-0000-0000-0000-000000000023';
  u3 uuid := '34000000-0000-0000-0000-000000000034';
  w1 uuid; w2 uuid; w3 uuid; partner uuid; acc uuid; prop uuid; cat uuid; req uuid; req2 uuid;
  ver uuid; bk jsonb; job uuid; bkid uuid; insp uuid; cost uuid; t uuid; s text; r jsonb; n bigint;
begin
  insert into auth.users (id,email) values (cu,'cu@y.my'),(cx,'cx@y.my'),(ops,'ops2@y.my'),(fin,'fin2@y.my'),(sa,'sa2@y.my'),
    (sup,'sup2@y.my'),(u1,'w1b@y.my'),(u2,'w2b@y.my'),(u3,'w3b@y.my');
  update profiles set role='ops_admin' where id=ops; update profiles set role='finance_admin' where id=fin;
  update profiles set role='super_admin' where id=sa; update profiles set role='supervisor' where id=sup;
  update profiles set role='worker' where id in (u1,u2,u3);
  insert into workers (profile_id, worker_type, approval_status, approved_by, approved_at) values (u1,'employee','approved',sa,now()) returning id into w1;
  insert into workers (profile_id, worker_type, approval_status, approved_by, approved_at) values (u2,'employee','approved',sa,now()) returning id into w2;
  insert into outsource_partners (name, ssm_registration_no, approval_status, approved_by, approved_at) values ('Hebat Sdn Bhd','202202000009','approved',sa,now()) returning id into partner;
  insert into workers (profile_id, worker_type, partner_id, approval_status, approved_by, approved_at) values (u3,'outsourced',partner,'approved',sa,now()) returning id into w3;
  select id into cat from service_categories where slug='electrical';
  insert into worker_categories values (w1, cat), (w3, cat);

  -- customer, request, quotation, approval
  perform test.as_user(cu); acc := public.create_customer_account('individual','Siti');
  perform test.as_user(cx); perform public.create_customer_account('individual','Other');
  perform test.as_user(cu);
  insert into properties (account_id,label,address_line1,city,state,postcode) values (acc,'Home','2 Jalan C','Shah Alam','selangor','40000') returning id into prop;
  insert into service_requests (account_id,property_id,category_id,title,description,contact_name,contact_phone)
    values (acc,prop,cat,'Fan not working','Ceiling fan stopped working in the living room','Siti','0198765432') returning id into req;
  perform public.submit_service_request(req);
  insert into service_requests (account_id,property_id,category_id,title,description)
    values (acc,prop,cat,'Socket sparks','Wall socket in bedroom sparks when used') returning id into req2;
  perform public.submit_service_request(req2);

  -- ---------- inspections (free) ----------
  perform test.as_user(ops);
  perform test.fails(format($q$select public.schedule_inspection(%L, now() + interval '1 day', now() + interval '1 day 1 hour', %L)$q$, req2, u1), 'worker as inspector');
  perform test.fails(format($q$select public.schedule_inspection(%L, now() - interval '1 day', now(), %L)$q$, req2, sup), 'inspection in the past');
  insp := public.schedule_inspection(req2, now() + interval '1 day', now() + interval '1 day 1 hour', sup);
  perform test.fails(format($q$select public.schedule_inspection(%L, now() + interval '2 day', now() + interval '2 day 1 hour', %L)$q$, req2, sup), 'two open inspections');
  perform test.as_user(cu);
  perform test.eq(test.count('select 1 from inspections'), 0::bigint, 'customer cannot read inspections (findings internal)');
  perform test.eq(test.count($q$select 1 from service_request_events where note like '%free site inspection%'$q$), 1::bigint, 'customer sees inspection on timeline');
  perform test.eq(test.count($q$select 1 from notifications where type='inspection_scheduled'$q$), 1::bigint, 'customer notified of inspection');
  perform test.as_user(u1); perform test.eq(test.count('select 1 from inspections'), 0::bigint, 'worker cannot read inspections');
  perform test.as_user(sup); perform test.eq(test.count('select 1 from inspections'), 1::bigint, 'inspector sees own inspection');
  insert into storage.objects (bucket_id, name) values ('inspection-photos', insp||'/wall.jpg');
  insert into inspection_photos (inspection_id, storage_path, uploaded_by) values (insp, insp||'/wall.jpg', sup);
  perform test.eq(test.affected(format($q$update inspections set status='completed' where id=%L$q$, insp)), 0::bigint, 'inspector cannot update inspection rows directly');
  perform test.fails(format($q$select public.complete_inspection(%L,'short')$q$, insp), 'findings too short');
  perform public.complete_inspection(insp, 'Burnt socket and damaged wiring, replace socket and 3m cable');
  perform test.fails(format($q$insert into inspection_photos (inspection_id, storage_path, uploaded_by) values (%L,%L,%L)$q$, insp, insp||'/late.jpg', sup), 'photo after completion');
  perform test.fails(format($q$select public.cancel_inspection(%L,'changed mind')$q$, insp), 'supervisor cancels (ops only)');

  -- ---------- quotation + booking ----------
  perform test.as_user(ops);
  perform public.review_service_request(req, 'start_review');
  ver := public.create_quotation(req, current_date + 7, 'Replace fan capacitor');
  insert into quotation_items (version_id, position, description, quantity, unit_price) values (ver,1,'Capacitor + labour',1,120);
  perform public.send_quotation_version(ver);
  perform test.as_user(cu); perform public.respond_to_quotation(ver,'approve');
  perform test.eq(test.count($q$select 1 from notifications where type='quotation_ready'$q$), 1::bigint, 'quote-ready notification');

  -- checklist template (ops) and availability
  perform test.as_user(ops);
  insert into checklist_templates (category_id, name) values (cat,'Electrical standard') returning id into t;
  insert into checklist_template_items (template_id, position, label, is_required) values (t,1,'Isolate power before work',true),(t,2,'Test after repair',true),(t,3,'Tidy site',false);
  perform test.fails(format($q$insert into checklist_templates (category_id, name) values (%L,'second active')$q$, cat), 'two active templates for a category');
  insert into worker_time_off (worker_id, kind, starts_at, ends_at, reason) values (w2,'leave', now() + interval '20 hours', now() + interval '3 days','Annual leave');
  perform test.as_user(cu); perform test.fails($q$select * from public.available_workers(now(), now() + interval '1 hour')$q$, 'customer lists workers');
  perform test.as_user(ops);
  bk := public.confirm_booking(req, now() + interval '1 day', now() + interval '1 day 3 hour', sup);
  job := (bk->>'job_id')::uuid; bkid := (bk->>'booking_id')::uuid;
  perform test.eq((select count(*) from job_checklist_items where job_id=job), 3::bigint, 'checklist copied onto job');
  perform test.eq((select conflict from public.available_workers(now() + interval '1 day', now() + interval '1 day 3 hour', cat) where worker_id=w2 limit 1), null::text, 'skill filter excludes unskilled worker w2');
  perform test.eq((select count(*) from public.available_workers(now() + interval '1 day', now() + interval '1 day 3 hour', null) where worker_id=w2 and conflict = 'on leave'), 1::bigint, 'leave shows as conflict');
  perform test.eq((select count(*) from public.available_workers(now() + interval '1 day', now() + interval '1 day 3 hour', cat) where worker_id=w1 and conflict is null), 1::bigint, 'free skilled worker listed');
  perform test.fails(format($q$insert into job_assignments (job_id,worker_id,assigned_by) values (%L,%L,%L)$q$, job, w2, ops), 'assign worker on leave without override');
  perform test.fails(format($q$insert into job_assignments (job_id,worker_id,assigned_by,override_reason) values (%L,%L,%L,'x')$q$, job, w2, ops), 'override reason too short');
  insert into job_assignments (job_id,worker_id,assigned_by,override_reason) values (job,w2,ops,'Leave cancelled, confirmed by phone');
  update job_assignments set released_at = now(), release_reason = 'worker unwell' where job_id=job and worker_id=w2;
  insert into job_assignments (job_id,worker_id,assignment_role,assigned_by) values (job,w1,'lead',ops);
  insert into job_assignments (job_id,worker_id,assigned_by) values (job,w3,ops);       -- approved outsourced worker, same screens
  perform test.as_user(u1); perform test.eq(test.count($q$select 1 from notifications where type='job_assigned'$q$), 1::bigint, 'worker notified of assignment');
  perform test.as_user(u3); perform test.eq(test.count('select 1 from jobs'), 1::bigint, 'outsourced worker sees assigned job');
  perform test.as_user(ops);
  insert into worker_time_off (worker_id, kind, starts_at, ends_at) values (w1,'training', now() + interval '5 days', now() + interval '6 days');
  perform test.fails(format($q$update bookings set scheduled_start = now() + interval '5 days 2 hours', scheduled_end = now() + interval '5 days 4 hours' where id=%L$q$, bkid), 'reschedule into assigned worker training');
  update bookings set scheduled_start = now() + interval '1 day 1 hour', scheduled_end = now() + interval '1 day 4 hour' where id = bkid;

  -- ---------- travel, checklist, materials ----------
  perform test.as_user(u2); perform test.fails(format($q$select public.set_job_travel_status(%L,'en_route')$q$, job), 'unassigned worker travels');
  perform test.as_user(u1);
  perform test.fails(format($q$select public.set_job_travel_status(%L,'teleported')$q$, job), 'bad travel status');
  perform public.set_job_travel_status(job, 'en_route');
  perform test.eq((select status::text from jobs where id=job), 'en_route', 'en route');
  perform test.as_user(cu); perform test.eq(test.count($q$select 1 from notifications where type='worker_en_route'$q$), 1::bigint, 'customer told technician is on the way');
  perform test.as_user(u1);
  perform public.set_job_travel_status(job, 'arrived', 3.139003, 101.686855, 12.5);
  perform test.eq((select arrival_lat::text from jobs where id=job), '3.139003', 'arrival location stored once');
  perform test.fails(format($q$update job_checklist_items set is_done=true where job_id=%L$q$, job), 'tick checklist before starting');
  perform public.start_job(job);
  perform test.eq((select status::text from service_requests where id=req) , null::text, 'worker cannot read request status');
  perform test.eq(test.affected(format($q$update job_checklist_items set is_done=true where job_id=%L and position=3$q$, job)), 1::bigint, 'tick optional item');
  perform test.fails(format($q$update job_checklist_items set label='renamed' where job_id=%L and position=1$q$, job), 'rename checklist item');
  insert into job_materials (job_id, description, quantity, unit, recorded_by) values (job,'Fan capacitor 2.5uF',1,'pc',u1);
  perform test.fails(format($q$update job_materials set quantity=9 where job_id=%L$q$, job), 'edit material record');
  insert into job_photos (job_id, kind, storage_path, uploaded_by) values (job,'before',job||'/b.jpg',u1),(job,'after',job||'/a.jpg',u1);
  perform test.fails(format($q$select public.submit_job_for_verification(%L)$q$, job), 'submit with required checklist undone');
  update job_checklist_items set is_done=true where job_id=job;
  perform public.submit_job_for_verification(job);
  perform test.eq(test.count('select 1 from job_cost_entries'), 0::bigint, 'worker sees no cost data');
  perform test.fails(format($q$insert into job_cost_entries (job_id,cost_type,description,amount,recorded_by) values (%L,'labour','x',10,%L)$q$, job, u1), 'worker records cost');
  perform test.as_user(cu);
  perform test.eq(test.count('select 1 from job_checklist_items'), 0::bigint, 'customer cannot read checklist');
  perform test.eq(test.count('select 1 from job_materials'), 0::bigint, 'customer cannot read materials');

  -- ---------- verification, feedback, costs, reports ----------
  perform test.as_user(sup);
  perform public.verify_job(job, 'passed', 'Neat work', 4::smallint);
  perform test.eq((select quality_score::text from job_verifications where job_id=job), '4', 'quality score stored');
  perform test.as_user(cu);
  perform test.eq(test.count($q$select 1 from notifications where type='job_completed'$q$), 1::bigint, 'completion notification');
  perform test.fails(format($q$select public.submit_job_feedback(%L, 6)$q$, job), 'rating out of range');
  perform public.submit_job_feedback(job, 5, 'Fast and tidy');
  perform test.fails(format($q$select public.submit_job_feedback(%L, 4)$q$, job), 'second feedback for the same job');
  perform test.as_user(cx); perform test.fails(format($q$select public.submit_job_feedback(%L, 1)$q$, job), 'other customer rates my job');
  perform test.as_user(u1); perform test.eq(test.count('select 1 from job_feedback'), 0::bigint, 'worker cannot read feedback');
  perform test.as_user(fin);
  insert into job_cost_entries (job_id,cost_type,description,amount,recorded_by) values (job,'labour','Technician 3h',90,fin) returning id into cost;
  insert into job_cost_entries (job_id,cost_type,description,amount,material_id,recorded_by)
    select job,'material','Fan capacitor',25,m.id,fin from job_materials m where m.job_id=job;
  perform test.fails(format($q$insert into job_cost_entries (job_id,cost_type,description,amount,material_id,recorded_by) values (%L,'material','x',5,%L,%L)$q$, job, gen_random_uuid(), fin), 'cost linked to a material of another job');
  perform test.fails(format($q$update job_cost_entries set amount=1 where id=%L$q$, cost), 'edit cost entry');
  perform test.as_user(ops);
  perform test.eq(test.count('select 1 from job_cost_entries'), 2::bigint, 'ops can read costs');
  perform test.fails(format($q$insert into job_cost_entries (job_id,cost_type,description,amount,recorded_by) values (%L,'other','x',5,%L)$q$, job, ops), 'ops writes costs');
  perform test.fails(format($q$select public.void_job_cost(%L,'wrong')$q$, cost), 'ops voids costs');
  perform test.fails($q$select * from public.report_job_margin(current_date - 1, current_date + 1)$q$, 'ops reads margin report');
  r := public.report_ops_summary(current_date - 1, current_date + 1);
  perform test.eq(r->>'avg_rating', '5.00', 'ops summary average rating');
  perform test.eq((r->>'jobs_verified')::int >= 1, true, 'ops summary counts verified jobs');
  perform test.as_user(fin);
  perform public.void_job_cost(cost, 'Entered twice');
  perform test.eq((select m.cost from public.report_job_margin(current_date - 1, current_date + 1) m where m.job_no = (select j.job_no from jobs j where j.id=job)), 25::numeric, 'margin report excludes voided cost');
  perform test.eq((select count(*) from public.report_receivables_ageing()) >= 0, true, 'ageing report runs for finance');
  perform test.as_user(cu); perform test.fails($q$select * from public.report_receivables_ageing()$q$, 'customer runs finance report');
  perform test.fails($q$select public.report_ops_summary(current_date, current_date)$q$, 'customer runs ops report');

  -- ---------- notifications, tokens, settings, audit ----------
  perform test.as_user(cu);
  perform test.eq(test.affected($q$update notifications set read_at = now()$q$) > 0, true, 'customer marks own notifications read');
  perform test.fails($q$update notifications set title = 'hacked'$q$, 'customer edits notification text');
  perform test.as_user(cx); perform test.eq(test.count('select 1 from notifications'), 0::bigint, 'other customer sees none of my notifications');
  perform test.fails(format($q$insert into notifications (user_id,type,title,body) values (%L,'x','x','x')$q$, cx), 'client creates notification');
  insert into device_tokens (user_id, token, platform) values (cx, 'ExponentPushToken[abc]', 'ios');
  perform test.fails(format($q$insert into device_tokens (user_id, token, platform) values (%L, 'ExponentPushToken[zzz]', 'ios')$q$, cu), 'register token for another user');
  execute 'set local role anon';
  perform test.eq(test.count($q$select 1 from app_settings where key like 'support.%'$q$), 4::bigint, 'anon reads public support settings');
  perform test.as_user(ops);
  perform test.eq(test.affected($q$update app_settings set value = to_jsonb('0312345678'::text) where key='support.phone'$q$), 0::bigint, 'ops cannot edit settings');
  perform test.as_user(sa);
  perform test.eq(test.affected($q$update app_settings set value = to_jsonb('0312345678'::text) where key='support.phone'$q$), 1::bigint, 'super admin edits settings');
  perform test.eq((select count(*) from audit_logs where table_name='quotation_items') > 0, true, 'quotation items audited');
  perform test.eq((select count(*) from audit_logs where table_name='job_checklist_items') > 0, true, 'checklist ticks audited');
  perform test.eq((select count(*) from audit_logs where table_name='job_cost_entries' and action='UPDATE') > 0, true, 'cost void audited');
  perform test.eq((select count(*) from audit_logs where table_name='app_settings') > 0, true, 'settings audited');
  perform test.as_user(sup);
  perform test.eq(test.count('select 1 from audit_logs'), 0::bigint, 'supervisor cannot read audit');
  perform test.fails($q$update profiles set role='super_admin' where id='52000000-0000-0000-0000-000000000052'$q$, 'supervisor self-promotion');
  perform test.as_user(sa);
  perform test.fails(format($q$update profiles set role='customer' where id=%L$q$, sa), 'super admin demotes self');
  perform test.as_system();
  raise notice 'ALL FIELD-OPS + SPEC MODULE TESTS PASSED';
end $$;
