-- ============================================================================
-- 016 Notifications: in-app inbox + push outbox
-- Rows are created by workflow functions (never by clients). The `notify-push`
-- Edge Function (service role, triggered by a database webhook on INSERT or on a
-- schedule) sends the Expo push and stamps push_sent_at.
-- ============================================================================

create table public.device_tokens (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  token        text not null unique,
  platform     text not null check (platform in ('ios', 'android')),
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index device_tokens_user_idx on public.device_tokens (user_id);

create table public.notifications (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  type         text not null,
  title        text not null,
  body         text not null,
  entity_type  text,
  entity_id    uuid,
  read_at      timestamptz,
  push_sent_at timestamptz,
  created_at   timestamptz not null default now()
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);
create index notifications_pending_push on public.notifications (created_at) where push_sent_at is null;

create function private.notify_user(p_user uuid, p_type text, p_title text, p_body text,
                                    p_entity_type text default null, p_entity_id uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.notifications (user_id, type, title, body, entity_type, entity_id)
  values (p_user, p_type, p_title, p_body, p_entity_type, p_entity_id);
end $$;

create function private.notify_account(p_account uuid, p_type text, p_title text, p_body text,
                                       p_entity_type text default null, p_entity_id uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.notifications (user_id, type, title, body, entity_type, entity_id)
  select cm.user_id, p_type, p_title, p_body, p_entity_type, p_entity_id
    from public.customer_members cm where cm.account_id = p_account;
end $$;

-- users may only mark their own notifications read
create function private.notifications_guard() returns trigger
language plpgsql as $$
begin
  if private.is_direct_client() and
     (new.user_id, new.type, new.title, new.body, new.entity_type, new.entity_id, new.push_sent_at, new.created_at)
     is distinct from
     (old.user_id, old.type, old.title, old.body, old.entity_type, old.entity_id, old.push_sent_at, old.created_at) then
    raise exception 'only read_at can be changed';
  end if;
  return new;
end $$;
create trigger notifications_guard before update on public.notifications
  for each row execute function private.notifications_guard();

-- Tell a worker when they are assigned
create function private.notify_on_assignment() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_job public.jobs; v_w public.workers; v_start timestamptz;
begin
  select * into v_job from public.jobs where id = new.job_id;
  select * into v_w from public.workers where id = new.worker_id;
  select scheduled_start into v_start from public.bookings where id = v_job.booking_id;
  perform private.notify_user(v_w.profile_id, 'job_assigned', 'New job assigned',
          v_job.job_no || ' on ' || to_char(v_start at time zone 'Asia/Kuala_Lumpur', 'DD Mon HH24:MI'),
          'job', v_job.id);
  return null;
end $$;
create trigger notify_on_assignment after insert on public.job_assignments
  for each row execute function private.notify_on_assignment();

alter table public.device_tokens  enable row level security;
alter table public.notifications  enable row level security;
grant select, insert, update, delete on public.device_tokens to authenticated;
grant select, update                 on public.notifications to authenticated;

create policy tokens_own on public.device_tokens for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy notifications_own_select on public.notifications for select to authenticated
  using (user_id = (select auth.uid()));
create policy notifications_own_update on public.notifications for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

grant execute on all functions in schema private to authenticated, service_role;
