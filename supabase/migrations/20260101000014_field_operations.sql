-- ============================================================================
-- 014 Field operations: availability, checklists, materials, inspections
-- ============================================================================

-- Worker availability ---------------------------------------------------------------
create type public.time_off_kind as enum ('leave', 'unavailable', 'training');

create table public.worker_time_off (
  id         uuid primary key default gen_random_uuid(),
  worker_id  uuid not null references public.workers(id) on delete cascade,
  kind       public.time_off_kind not null default 'leave',
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  reason     text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index worker_time_off_idx on public.worker_time_off (worker_id, starts_at);

-- Returns a human-readable conflict (or null) for a worker over a time window.
create function private.worker_conflicts(p_worker uuid, p_start timestamptz, p_end timestamptz, p_exclude_job uuid default null)
returns text language plpgsql stable security definer set search_path = '' as $$
declare v text;
begin
  select 'already on job ' || j.job_no into v
    from public.job_assignments ja
    join public.jobs j on j.id = ja.job_id
    join public.bookings b on b.id = j.booking_id
   where ja.worker_id = p_worker and ja.released_at is null
     and j.status in ('scheduled', 'en_route', 'arrived', 'in_progress', 'rework_required')
     and (p_exclude_job is null or j.id <> p_exclude_job)
     and tstzrange(b.scheduled_start, b.scheduled_end) && tstzrange(p_start, p_end)
   limit 1;
  if v is not null then return v; end if;
  select 'on ' || t.kind::text into v
    from public.worker_time_off t
   where t.worker_id = p_worker and tstzrange(t.starts_at, t.ends_at) && tstzrange(p_start, p_end)
   limit 1;
  return v;
end $$;

-- Who can take a job in this window? Used by the assignment dialog.
create function public.available_workers(p_start timestamptz, p_end timestamptz, p_category uuid default null)
returns table (worker_id uuid, full_name text, worker_type public.worker_type, partner_name text, conflict text)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_role(array['ops_admin','super_admin']::public.app_role[]);
  return query
  select w.id, p.full_name, w.worker_type, op.name, private.worker_conflicts(w.id, p_start, p_end)
    from public.workers w
    join public.profiles p on p.id = w.profile_id and p.is_active and p.role = 'worker'
    left join public.outsource_partners op on op.id = w.partner_id
   where w.approval_status = 'approved'
     and (w.worker_type = 'employee'
          or (op.approval_status = 'approved'
              and (op.contract_expires_on is null or op.contract_expires_on >= private.today_my())))
     and (p_category is null or exists (select 1 from public.worker_categories wc
                                        where wc.worker_id = w.id and wc.category_id = p_category))
   order by (private.worker_conflicts(w.id, p_start, p_end) is not null), p.full_name;
end $$;

-- Job checklists ----------------------------------------------------------------------
create table public.checklist_templates (
  id          uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.service_categories(id),
  name        text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create unique index checklist_one_active_per_category on public.checklist_templates (category_id) where is_active;

create table public.checklist_template_items (
  id          uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.checklist_templates(id) on delete cascade,
  position    int  not null check (position > 0),
  label       text not null check (length(btrim(label)) > 0),
  is_required boolean not null default true,
  unique (template_id, position)
);

-- Snapshot copied onto the job when the booking is confirmed (later template edits never alter old jobs)
create table public.job_checklist_items (
  id          uuid primary key default gen_random_uuid(),
  job_id      uuid not null references public.jobs(id) on delete cascade,
  position    int  not null check (position > 0),
  label       text not null,
  is_required boolean not null default true,
  is_done     boolean not null default false,
  done_by     uuid references public.profiles(id),
  done_at     timestamptz,
  note        text,
  unique (job_id, position)
);

create function private.job_checklist_guard() returns trigger
language plpgsql as $$
declare v_status public.job_status;
begin
  if tg_op = 'INSERT' then
    select status into v_status from public.jobs where id = new.job_id;
    if private.is_direct_client() then
      if v_status in ('verified', 'cancelled') then raise exception 'job is closed'; end if;
      new.is_done := false; new.done_by := null; new.done_at := null;
    end if;
    return new;
  end if;
  if private.is_direct_client() then
    if (new.job_id, new.position, new.label, new.is_required) is distinct from
       (old.job_id, old.position, old.label, old.is_required) then
      raise exception 'only the tick and note of a checklist item can change';
    end if;
    if not private.job_open_for_evidence(old.job_id) then
      raise exception 'the checklist can only be updated while work is in progress';
    end if;
    if new.is_done and not old.is_done then new.done_by := (select auth.uid()); new.done_at := now();
    elsif not new.is_done then new.done_by := null; new.done_at := null;
    else new.done_by := old.done_by; new.done_at := old.done_at; end if;
  end if;
  return new;
end $$;
create trigger job_checklist_guard before insert or update on public.job_checklist_items
  for each row execute function private.job_checklist_guard();

-- Materials used (quantities only; workers never see or enter costs) ----------------
create table public.job_materials (
  id          uuid primary key default gen_random_uuid(),
  job_id      uuid not null references public.jobs(id) on delete cascade,
  description text not null check (length(btrim(description)) > 0),
  quantity    numeric(10,2) not null check (quantity > 0),
  unit        text not null default 'pc',
  recorded_by uuid not null references public.profiles(id),
  created_at  timestamptz not null default now(),
  unique (id, job_id)
);
create index job_materials_job_idx on public.job_materials (job_id);

create function private.job_materials_guard() returns trigger
language plpgsql as $$
begin
  if not private.job_open_for_evidence(new.job_id) then
    raise exception 'materials can only be recorded while work is in progress';
  end if;
  if private.is_direct_client() then new.recorded_by := (select auth.uid()); end if;
  return new;
end $$;
create trigger job_materials_guard before insert on public.job_materials
  for each row execute function private.job_materials_guard();
create trigger job_materials_immutable before update or delete on public.job_materials
  for each row execute function private.forbid_mutation();

-- Inspections (free site visits before quoting) ---------------------------------------
create type public.inspection_status as enum ('scheduled', 'completed', 'cancelled');

create table public.inspections (
  id                 uuid primary key default gen_random_uuid(),
  inspection_no      text not null unique default 'pending',
  request_id         uuid not null,
  account_id         uuid not null,
  status             public.inspection_status not null default 'scheduled',
  scheduled_start    timestamptz not null,
  scheduled_end      timestamptz not null,
  inspector_id       uuid not null references public.profiles(id),
  site_address       text not null,
  site_contact_name  text,
  site_contact_phone text,
  site_access_notes  text,
  findings           text,
  completed_at       timestamptz,
  cancelled_reason   text,
  created_by         uuid references public.profiles(id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  foreign key (request_id, account_id) references public.service_requests (id, account_id),
  check (scheduled_end > scheduled_start),
  check (status <> 'completed' or (findings is not null and length(btrim(findings)) > 0 and completed_at is not null)),
  check (status <> 'cancelled' or cancelled_reason is not null)
);
create unique index inspections_one_open_per_request on public.inspections (request_id) where status = 'scheduled';
create index inspections_inspector_idx on public.inspections (inspector_id, status);

create table public.inspection_photos (
  id            uuid primary key default gen_random_uuid(),
  inspection_id uuid not null references public.inspections(id) on delete cascade,
  storage_path  text not null unique,
  caption       text,
  uploaded_by   uuid not null references public.profiles(id),
  created_at    timestamptz not null default now(),
  check (storage_path like inspection_id::text || '/%')
);

create function private.inspections_guard() returns trigger
language plpgsql as $$
declare v_ok boolean;
begin
  if tg_op = 'INSERT' then
    new.inspection_no := private.next_ref('IN');
    new.status := 'scheduled';
    select exists (select 1 from public.profiles p where p.id = new.inspector_id and p.is_active
                   and p.role in ('supervisor', 'ops_admin', 'super_admin')) into v_ok;
    if not v_ok then raise exception 'inspector must be an active supervisor or operations admin'; end if;
    return new;
  end if;
  if (new.request_id, new.account_id, new.inspection_no) is distinct from (old.request_id, old.account_id, old.inspection_no) then
    raise exception 'inspection links are immutable';
  end if;
  if new.status <> old.status then
    if private.is_direct_client() then
      raise exception 'inspection status can only be changed through the workflow functions' using errcode = '42501';
    end if;
    if old.status <> 'scheduled' then raise exception 'inspection is already %', old.status; end if;
  elsif old.status <> 'scheduled' and
        (new.findings, new.scheduled_start, new.scheduled_end, new.inspector_id) is distinct from
        (old.findings, old.scheduled_start, old.scheduled_end, old.inspector_id) then
    raise exception 'closed inspections are read-only';
  end if;
  if new.inspector_id <> old.inspector_id then
    select exists (select 1 from public.profiles p where p.id = new.inspector_id and p.is_active
                   and p.role in ('supervisor', 'ops_admin', 'super_admin')) into v_ok;
    if not v_ok then raise exception 'inspector must be an active supervisor or operations admin'; end if;
  end if;
  return new;
end $$;
create trigger inspections_guard before insert or update on public.inspections
  for each row execute function private.inspections_guard();
create trigger set_updated_at before update on public.inspections
  for each row execute function private.set_updated_at();

create function private.is_inspector(p_inspection uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.inspections i
                  join public.profiles p on p.id = i.inspector_id
                 where i.id = p_inspection and i.inspector_id = (select auth.uid()) and p.is_active)
$$;
create function private.inspection_open_for_photos(p_inspection uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.inspections i where i.id = p_inspection and i.status = 'scheduled')
$$;

create function private.inspection_photos_guard() returns trigger
language plpgsql as $$
begin
  if not private.inspection_open_for_photos(new.inspection_id) then
    raise exception 'photos can only be added to a scheduled inspection';
  end if;
  if private.is_direct_client() then new.uploaded_by := (select auth.uid()); end if;
  return new;
end $$;
create trigger inspection_photos_guard before insert on public.inspection_photos
  for each row execute function private.inspection_photos_guard();
create trigger inspection_photos_immutable before update or delete on public.inspection_photos
  for each row execute function private.forbid_mutation();

-- Audit new tables ----------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['worker_time_off','checklist_templates','checklist_template_items',
                           'job_checklist_items','job_materials','inspections','inspection_photos']
  loop
    execute format('create trigger audit_row after insert or update or delete on public.%I
                    for each row execute function private.audit_row()', t);
  end loop;
end $$;

-- RLS & grants ----------------------------------------------------------------------------
alter table public.worker_time_off           enable row level security;
alter table public.checklist_templates       enable row level security;
alter table public.checklist_template_items  enable row level security;
alter table public.job_checklist_items       enable row level security;
alter table public.job_materials             enable row level security;
alter table public.inspections               enable row level security;
alter table public.inspection_photos        enable row level security;

grant select, insert, update, delete on public.worker_time_off          to authenticated;
grant select, insert, update, delete on public.checklist_templates      to authenticated;
grant select, insert, update, delete on public.checklist_template_items to authenticated;
grant select, insert, update         on public.job_checklist_items      to authenticated;
grant select, insert                 on public.job_materials            to authenticated;
grant select, update                 on public.inspections              to authenticated;
grant select, insert                 on public.inspection_photos        to authenticated;

create policy time_off_select on public.worker_time_off for select to authenticated
  using ((select private.is_back_office()) or worker_id = (select private.my_worker_id()));
create policy time_off_ops_write on public.worker_time_off for all to authenticated
  using ((select private.is_ops())) with check ((select private.is_ops()));

create policy cl_templates_select on public.checklist_templates for select to authenticated
  using ((select private.is_back_office()));
create policy cl_templates_ops on public.checklist_templates for all to authenticated
  using ((select private.is_ops())) with check ((select private.is_ops()));
create policy cl_template_items_select on public.checklist_template_items for select to authenticated
  using ((select private.is_back_office()));
create policy cl_template_items_ops on public.checklist_template_items for all to authenticated
  using ((select private.is_ops())) with check ((select private.is_ops()));

create policy jci_select on public.job_checklist_items for select to authenticated
  using ((select private.is_back_office()) or (select private.is_assigned_to_job(job_id))
         or (select private.is_job_supervisor(job_id)));
create policy jci_ops_insert on public.job_checklist_items for insert to authenticated
  with check ((select private.is_ops()));
create policy jci_update on public.job_checklist_items for update to authenticated
  using ((select private.is_assigned_to_job(job_id)) or (select private.is_ops()))
  with check ((select private.is_assigned_to_job(job_id)) or (select private.is_ops()));

create policy materials_select on public.job_materials for select to authenticated
  using ((select private.is_back_office()) or (select private.is_assigned_to_job(job_id))
         or (select private.is_job_supervisor(job_id)));
create policy materials_insert on public.job_materials for insert to authenticated
  with check (recorded_by = (select auth.uid()) and (select private.is_assigned_to_job(job_id)));

-- Customers never read inspections (findings are internal); they get a timeline note instead.
create policy inspections_select on public.inspections for select to authenticated
  using ((select private.is_back_office()) or (select private.is_inspector(id)));
create policy inspections_ops_update on public.inspections for update to authenticated
  using ((select private.is_ops())) with check ((select private.is_ops()));
create policy inspection_photos_select on public.inspection_photos for select to authenticated
  using ((select private.is_back_office()) or (select private.is_inspector(inspection_id)));
create policy inspection_photos_insert on public.inspection_photos for insert to authenticated
  with check (uploaded_by = (select auth.uid()) and (select private.is_inspector(inspection_id)));

-- Storage: inspection photos ({inspection_id}/{file}); write-once ----------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('inspection-photos', 'inspection-photos', false, 10485760, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false;
create policy "ip read" on storage.objects for select to authenticated
  using (bucket_id = 'inspection-photos'
    and ((select private.is_back_office())
         or (select private.is_inspector(private.try_uuid((storage.foldername(name))[1])))));
create policy "ip upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'inspection-photos'
    and cardinality(storage.foldername(name)) = 1
    and (select private.is_inspector(private.try_uuid((storage.foldername(name))[1])))
    and (select private.inspection_open_for_photos(private.try_uuid((storage.foldername(name))[1]))));

grant execute on function public.available_workers(timestamptz, timestamptz, uuid) to authenticated;
grant execute on all functions in schema private to authenticated, service_role;
