-- ============================================================================
-- 010 Audit log: append-only, written only by triggers, readable by admins.
-- UPDATE rows store only the changed columns (old/new) to stay compact.
-- ============================================================================

create table public.audit_logs (
  id          bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  actor_id    uuid,                         -- null => service role / system job
  actor_role  text,
  table_name  text not null,
  entity_id   text,
  action      text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  old_data    jsonb,
  new_data    jsonb
);
create index audit_logs_entity_idx on public.audit_logs (table_name, entity_id, occurred_at desc);
create index audit_logs_actor_idx  on public.audit_logs (actor_id, occurred_at desc);

create trigger audit_logs_immutable before update or delete on public.audit_logs
  for each row execute function private.forbid_mutation();
create trigger audit_logs_no_truncate before truncate on public.audit_logs
  for each statement execute function private.forbid_mutation();

create function private.audit_row() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end;
  v_row jsonb := coalesce(v_new, v_old);
  v_o jsonb; v_n jsonb;
begin
  if tg_op = 'UPDATE' then
    select coalesce(jsonb_object_agg(k, v_old -> k), '{}'), coalesce(jsonb_object_agg(k, v_new -> k), '{}')
      into v_o, v_n
      from jsonb_object_keys(v_new) k
     where k <> 'updated_at' and (v_old -> k) is distinct from (v_new -> k);
    if v_n = '{}'::jsonb then return null; end if;      -- nothing but updated_at changed
    v_old := v_o; v_new := v_n;
  end if;
  insert into public.audit_logs (actor_id, actor_role, table_name, entity_id, action, old_data, new_data)
  values ((select auth.uid()), private.current_app_role()::text, tg_table_name,
          coalesce(v_row ->> 'id', v_row ->> 'account_id' || ':' || coalesce(v_row ->> 'user_id', '')),
          tg_op, v_old, v_new);
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'profiles','customer_accounts','customer_members','properties','service_requests',
    'quotations','quotation_versions','quotation_items','bookings','jobs','job_assignments','job_verifications',
    'change_order_requests','change_orders','change_order_items','invoices','invoice_items','payments',
    'service_request_attachments',
    'outsource_partners','workers','internal_notes']
  loop
    execute format('create trigger audit_row after insert or update or delete on public.%I
                    for each row execute function private.audit_row()', t);
  end loop;
end $$;
