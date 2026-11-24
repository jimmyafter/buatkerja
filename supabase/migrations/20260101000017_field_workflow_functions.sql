-- ============================================================================
-- 017 Workflow functions for inspections and travel/arrival
-- ============================================================================

create function public.schedule_inspection(p_request_id uuid, p_start timestamptz, p_end timestamptz, p_inspector uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare r public.service_requests; p public.properties; v_id uuid;
begin
  perform private.require_role(array['ops_admin','super_admin']::public.app_role[]);
  select * into r from public.service_requests where id = p_request_id for update;
  if not found then raise exception 'request not found' using errcode = 'P0002'; end if;
  if r.status not in ('submitted', 'under_review', 'info_requested') then
    raise exception 'an inspection can only be scheduled before quoting (request is %)', r.status;
  end if;
  if p_start <= now() then raise exception 'inspection must start in the future'; end if;
  select * into p from public.properties where id = r.property_id;
  insert into public.inspections (request_id, account_id, scheduled_start, scheduled_end, inspector_id,
                                  site_address, site_contact_name, site_contact_phone, site_access_notes, created_by)
  values (r.id, r.account_id, p_start, p_end, p_inspector,
          concat_ws(', ', p.address_line1, p.address_line2, p.postcode || ' ' || p.city, initcap(replace(p.state::text, '_', ' '))),
          r.contact_name, r.contact_phone, p.access_notes, (select auth.uid()))
  returning id into v_id;
  if r.status = 'submitted' then perform private.set_request_status(r.id, 'under_review'); end if;
  perform private.add_request_note(r.id, 'A free site inspection has been scheduled for '
          || to_char(p_start at time zone 'Asia/Kuala_Lumpur', 'DD Mon YYYY HH24:MI') || '.', true);
  perform private.notify_account(r.account_id, 'inspection_scheduled', 'Site inspection scheduled',
          to_char(p_start at time zone 'Asia/Kuala_Lumpur', 'DD Mon HH24:MI') || ' (free of charge)', 'service_request', r.id);
  return v_id;
end $$;

create function public.complete_inspection(p_inspection_id uuid, p_findings text)
returns void language plpgsql security definer set search_path = '' as $$
declare i public.inspections;
begin
  perform private.require_role(array['supervisor','ops_admin','super_admin']::public.app_role[]);
  select * into i from public.inspections where id = p_inspection_id for update;
  if not found or not (private.is_ops() or i.inspector_id = (select auth.uid())) then
    raise exception 'inspection not found' using errcode = 'P0002';
  end if;
  if i.status <> 'scheduled' then raise exception 'inspection is already %', i.status; end if;
  if p_findings is null or length(btrim(p_findings)) < 10 then raise exception 'please record the findings'; end if;
  update public.inspections set status = 'completed', findings = btrim(p_findings), completed_at = now() where id = i.id;
  perform private.add_request_note(i.request_id, 'Site inspection completed.', true);
end $$;

create function public.cancel_inspection(p_inspection_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare i public.inspections;
begin
  perform private.require_role(array['ops_admin','super_admin']::public.app_role[]);
  if p_reason is null or length(btrim(p_reason)) < 3 then raise exception 'a reason is required'; end if;
  select * into i from public.inspections where id = p_inspection_id for update;
  if not found or i.status <> 'scheduled' then raise exception 'inspection is not scheduled'; end if;
  update public.inspections set status = 'cancelled', cancelled_reason = btrim(p_reason) where id = i.id;
  perform private.add_request_note(i.request_id, 'The site inspection was cancelled; we will contact you to rearrange.', true);
end $$;

-- Travel / arrival. Location is read ONCE, at arrival, and only if the worker's device provides it.
create function public.set_job_travel_status(p_job_id uuid, p_status text,
    p_lat numeric default null, p_lng numeric default null, p_accuracy numeric default null)
returns void language plpgsql security definer set search_path = '' as $$
declare j public.jobs;
begin
  perform private.require_role(array['worker']::public.app_role[]);
  select * into j from public.jobs where id = p_job_id for update;
  if not found or not private.is_assigned_to_job(j.id) then raise exception 'job not found' using errcode = 'P0002'; end if;
  if p_status = 'en_route' then
    if j.status <> 'scheduled' then raise exception 'cannot set on-my-way from status %', j.status; end if;
    update public.jobs set status = 'en_route', travel_started_at = now() where id = j.id;
    perform private.notify_account(j.account_id, 'worker_en_route', 'Our technician is on the way',
            j.job_no || ' - please make sure someone can give access.', 'job', j.id);
  elsif p_status = 'arrived' then
    if j.status not in ('scheduled', 'en_route') then raise exception 'cannot mark arrival from status %', j.status; end if;
    update public.jobs set status = 'arrived', arrived_at = now(),
           arrival_lat = p_lat, arrival_lng = p_lng, arrival_accuracy_m = p_accuracy where id = j.id;
  else
    raise exception 'status must be en_route or arrived';
  end if;
end $$;

grant execute on function
  public.schedule_inspection(uuid, timestamptz, timestamptz, uuid),
  public.complete_inspection(uuid, text),
  public.cancel_inspection(uuid, text),
  public.set_job_travel_status(uuid, text, numeric, numeric, numeric)
to authenticated;
