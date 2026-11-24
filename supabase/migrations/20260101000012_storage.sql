-- ============================================================================
-- 012 Storage: private buckets + path-based policies
--   request-attachments : {account_id}/{request_id}/{file}
--   job-photos          : {job_id}/{file}              (write-once evidence)
--   documents           : {account_id}/{file}          (invoice PDFs, receipts)
-- ============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('request-attachments', 'request-attachments', false, 10485760, array['image/jpeg','image/png','image/webp','application/pdf']),
  ('job-photos',          'job-photos',          false, 10485760, array['image/jpeg','image/png','image/webp']),
  ('documents',           'documents',           false, 10485760, array['application/pdf'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- request attachments
create policy "ra read" on storage.objects for select to authenticated
  using (bucket_id = 'request-attachments'
    and ((select private.is_back_office())
         or (select private.is_account_member(private.try_uuid((storage.foldername(name))[1])))));
create policy "ra upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'request-attachments'
    and cardinality(storage.foldername(name)) = 2
    and ((select private.is_ops())
         or (select private.can_attach_to_request(private.try_uuid((storage.foldername(name))[2]),
                                                  private.try_uuid((storage.foldername(name))[1])))));
create policy "ra delete" on storage.objects for delete to authenticated
  using (bucket_id = 'request-attachments'
    and ((select private.is_ops())
         or (select private.can_attach_to_request(private.try_uuid((storage.foldername(name))[2]),
                                                  private.try_uuid((storage.foldername(name))[1])))));

-- job photos: assigned workers write once; no update/delete policy => immutable
create policy "jp read" on storage.objects for select to authenticated
  using (bucket_id = 'job-photos'
    and ((select private.is_back_office())
         or (select private.is_assigned_to_job(private.try_uuid((storage.foldername(name))[1])))
         or (select private.is_job_supervisor(private.try_uuid((storage.foldername(name))[1])))
         or (select private.customer_can_see_job_photo_path(name))));
create policy "jp upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'job-photos'
    and cardinality(storage.foldername(name)) = 1
    and (select private.is_assigned_to_job(private.try_uuid((storage.foldername(name))[1])))
    and (select private.job_open_for_evidence(private.try_uuid((storage.foldername(name))[1]))));

-- documents: admin writes, owning customer reads
create policy "doc read" on storage.objects for select to authenticated
  using (bucket_id = 'documents'
    and ((select private.is_back_office())
         or (select private.is_account_member(private.try_uuid((storage.foldername(name))[1])))));
create policy "doc admin write" on storage.objects for all to authenticated
  using (bucket_id = 'documents' and (select private.is_finance()))
  with check (bucket_id = 'documents' and (select private.is_finance()));
