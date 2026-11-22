-- Separate verified student identity imports from monthly financial agreements.
-- Uses only the November source rows already staged by migrations 005/013.
begin;

-- Migration 013 used min(uuid) in its candidate builder. PostgreSQL has no
-- built-in min(uuid), so patch the already-deployed function body in place.
do $$
declare v_definition text;
begin
  if to_regprocedure('public.build_november_import_candidates(text)') is not null then
    select pg_get_functiondef('public.build_november_import_candidates(text)'::regprocedure)
      into v_definition;
    if position('min(s.id)' in v_definition)>0 then
      v_definition := replace(v_definition,'min(s.id)','(array_agg(s.id order by s.id))[1]');
      execute v_definition;
    end if;
  end if;
end $$;

alter table public.november_import_candidates
  add column if not exists identity_status text not null default 'pending'
    check (identity_status in ('pending','created','matched','ambiguous')),
  add column if not exists identity_student_id uuid references public.students(id),
  add column if not exists identity_scope text
    check (identity_scope in ('group','row')),
  add column if not exists identity_review_reason text;

alter table public.november_import_candidates
  add column if not exists approved_payment_verified boolean not null default false,
  add column if not exists payment_review_reason text;

create or replace function public.november_import_require_verified_payment()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if coalesce(new.approved_payment,0)>0 and not new.approved_payment_verified then
    raise exception 'A source receipt must be verified before a tuition payment can be approved or posted';
  end if;
  if coalesce(new.approved_payment,0)>0 and
     (new.approved_payment is distinct from new.source_payment or
      new.approved_payment_date is distinct from new.source_payment_date or
      new.source_payment_reference is null) then
    raise exception 'Posted payment amount and date must match its verified source receipt';
  end if;
  return new;
end $$;
drop trigger if exists november_payment_verification_guard on public.november_import_candidates;
create trigger november_payment_verification_guard
  before insert or update of approved_payment,approved_payment_verified,status
  on public.november_import_candidates
  for each row execute function public.november_import_require_verified_payment();

create index if not exists november_candidate_identity_status_idx
  on public.november_import_candidates(batch_id,identity_status,source_row);

create or replace function public.november_import_save_profile(
  p_candidate uuid,
  p_payload jsonb
) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  c public.november_import_candidates%rowtype;
  v_batch uuid;
  v_action text;
  v_scope text;
  v_student uuid;
  v_first text;
  v_last text;
  v_phone text;
  v_reason text;
  v_key text;
  v_mapped uuid;
  v_enrollment uuid;
  v_linked integer := 0;
  v_existing boolean := false;
begin
  if not public.staff_has_any(array['admin']) then
    raise exception 'Administrator approval required' using errcode='42501';
  end if;
  if p_candidate is null or p_payload is null or pg_column_size(p_payload)>8000 then
    raise exception 'Candidate and identity decision are required';
  end if;

  select * into c from public.november_import_candidates where id=p_candidate for update;
  if not found then raise exception 'November candidate not found'; end if;
  select id into v_batch from public.historical_import_batches
    where source_sha256='15e9b64e02048eba03e59636e2875c56701c0d1160748da7a85e26c8c1e7cc64'
      and id=c.batch_id;
  if v_batch is null then raise exception 'Candidate is not from the verified November staging batch'; end if;
  if c.status in ('posted','duplicate','rejected') then
    raise exception 'Candidate is already %; its identity cannot be changed',c.status;
  end if;

  v_action := p_payload->>'action';
  v_scope := p_payload->>'scope';
  v_first := nullif(trim(coalesce(p_payload->>'first_name',c.first_name)), '');
  v_last := trim(coalesce(p_payload->>'last_name',c.last_name,''));
  v_phone := nullif(trim(coalesce(p_payload->>'phone',c.phone,'')), '');
  v_reason := nullif(trim(coalesce(p_payload->>'reason','')), '');
  if coalesce(p_payload->>'identity_confirmed','false') <> 'true'
     or length(coalesce(v_reason,'')) < 4 then
    raise exception 'Confirm the identity and record a review reason of at least four characters';
  end if;
  if v_scope not in ('group','row') then raise exception 'Choose whether this decision covers the repeated-name group or this row'; end if;
  if v_scope='row' and coalesce(p_payload->>'distinct_person_confirmed','false') <> 'true' then
    raise exception 'A row-only profile requires confirmation that this is a different person';
  end if;

  if v_scope='group' then
    if c.identity_key is null then raise exception 'This row has no stable identity group; resolve it individually'; end if;
    v_key := c.identity_key;
  else
    v_key := case when c.identity_scope='row' then c.identity_key
      else coalesce(c.identity_key,c.source_key)||'|source:'||c.source_key end;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'november-profile:'||c.batch_id::text||':'||v_key,0));

  if v_action='match' then
    v_student := nullif(p_payload->>'student_id','')::uuid;
    if v_student is null or not exists(select 1 from public.students where id=v_student) then
      raise exception 'Select an existing student profile';
    end if;
  elsif v_action='create' then
    if v_first is null then raise exception 'Student first name is required'; end if;
    select student_id into v_mapped from public.november_import_students
      where batch_id=c.batch_id and identity_key=v_key;
    if v_mapped is not null then
      v_student := v_mapped;
      v_existing := true;
    end if;
    if v_student is null then
      perform set_config('rsms.audit_reason','November 2026 identity review: '||v_reason,true);
      insert into public.students(first_name,last_name,phone,registered_on,active,notes)
      values(v_first,v_last,v_phone,date '2026-11-01',true,
        'November 2026 source reference: '||c.source_key||' | '||v_reason)
      returning id into v_student;
    end if;
  else
    raise exception 'Choose create or match for the student profile';
  end if;

  if c.status='approved' and c.identity_student_id is not null
     and c.identity_student_id is distinct from v_student then
    raise exception 'This financial agreement is already approved for another student; return it to review before changing identity';
  end if;

  select student_id into v_mapped from public.november_import_students
    where batch_id=c.batch_id and identity_key=v_key;
  if v_mapped is not null and v_mapped<>v_student then
    raise exception 'This identity key already maps to another student; review the identity group before changing it';
  end if;

  insert into public.november_import_students(batch_id,identity_key,student_id,created_new,created_by)
  values(c.batch_id,v_key,v_student,(v_action='create' and not v_existing),auth.uid())
  on conflict(batch_id,identity_key) do update
    set student_id=excluded.student_id,created_by=excluded.created_by;

  if v_scope='group' then
    update public.november_import_candidates
      set identity_student_id=v_student,
          identity_status=case when v_action='create' then 'created' else 'matched' end,
          identity_scope='group',identity_review_reason=v_reason
      where batch_id=c.batch_id and identity_key=v_key
        and status in ('needs_review','approved');
    get diagnostics v_linked = row_count;
  else
    update public.november_import_candidates
      set identity_key=v_key,identity_student_id=v_student,
          identity_status=case when v_action='create' then 'created' else 'matched' end,
          identity_scope='row',identity_review_reason=v_reason
      where id=c.id;
    v_linked := 1;
  end if;

  -- Class participation is independent of billing. Link only the class explicitly
  -- selected and confirmed by the administrator; no membership or payment is created.
  v_enrollment := null;
  if coalesce(p_payload->>'class_confirmed','false')='true' then
    if nullif(p_payload->>'class_id','') is null then raise exception 'Select a class before confirming the enrollment'; end if;
    if c.status='approved' and c.approved_class_id is distinct from (p_payload->>'class_id')::uuid then
      raise exception 'This financial agreement is already approved for another class; return it to review before changing class';
    end if;
    if not exists(select 1 from public.class_rooms where id=(p_payload->>'class_id')::uuid) then
      raise exception 'Selected class does not exist';
    end if;
    insert into public.enrollments(student_id,class_id,enrolled_on,active)
      values(v_student,(p_payload->>'class_id')::uuid,date '2026-11-01',true)
      on conflict(student_id,class_id) do update set active=true
      returning id into v_enrollment;
    update public.november_import_candidates set enrollment_id=v_enrollment,
      approved_class_id=(p_payload->>'class_id')::uuid
      where id=c.id;
    insert into public.historical_import_destinations(
      source_row_id,destination_table,destination_id,mapping_status,created_by)
    values(c.source_row_id,'enrollments',v_enrollment,'created',auth.uid())
    on conflict(source_row_id,destination_table) do update set destination_id=excluded.destination_id;
  end if;

  insert into public.historical_import_destinations(
    source_row_id,destination_table,destination_id,mapping_status,created_by)
  values(c.source_row_id,'students',v_student,
    case when exists(select 1 from public.november_import_students m
      where m.batch_id=c.batch_id and m.identity_key=v_key and m.created_new)
      then 'created' else 'matched_existing' end,auth.uid())
  on conflict(source_row_id,destination_table) do update set destination_id=excluded.destination_id;

  insert into public.audit_logs(table_name,action,row_id,actor_id,new_data,reason,approved_by)
  values('november_import_candidates','IDENTITY_REVIEW',c.id::text,auth.uid(),
    jsonb_build_object('student_id',v_student,'action',v_action,'scope',v_scope,
      'source_key',c.source_key,'class_id',nullif(p_payload->>'class_id',''),
      'enrollment_id',v_enrollment,'linked_candidates',v_linked),
    v_reason,auth.uid());

  return jsonb_build_object('student_id',v_student,'action',v_action,'scope',v_scope,
    'linked_candidates',v_linked,'enrollment_id',v_enrollment,
    'profile_created',(v_action='create' and not v_existing));
end $$;

create or replace function public.november_import_profile_summary(p_sha256 text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_batch uuid;
begin
  if not public.staff_has_any(array['admin']) then
    raise exception 'Administrator approval required' using errcode='42501';
  end if;
  select id into v_batch from public.historical_import_batches where source_sha256=p_sha256;
  if v_batch is null then raise exception 'November staging batch not found'; end if;
  return jsonb_build_object(
    'source_registration_candidates',(select count(*) from public.november_import_candidates where batch_id=v_batch),
    'profiles_created',(select count(distinct identity_student_id) from public.november_import_candidates where batch_id=v_batch and identity_status='created'),
    'profiles_matched',(select count(distinct identity_student_id) from public.november_import_candidates where batch_id=v_batch and identity_status='matched'),
    'identities_pending',(select count(*) from public.november_import_candidates where batch_id=v_batch and identity_status='pending'),
    'november_enrollments',(select count(distinct c.enrollment_id) from public.november_import_candidates c where c.batch_id=v_batch and c.enrollment_id is not null),
    'monthly_memberships',(select count(*) from public.november_import_candidates where batch_id=v_batch and membership_id is not null),
    'verified_payments',(select count(*) from public.november_import_candidates where batch_id=v_batch and payment_id is not null),
    'financial_review',(select count(*) from public.november_import_candidates where batch_id=v_batch and identity_status in ('created','matched') and membership_id is null)
  );
end $$;

create or replace function public.november_import_verify_payment(
  p_candidate uuid,p_amount numeric,p_paid_on date,p_reason text
) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare c public.november_import_candidates%rowtype;
begin
  if not public.staff_has_any(array['admin']) then
    raise exception 'Administrator approval required' using errcode='42501';
  end if;
  if length(trim(coalesce(p_reason,'')))<4 then raise exception 'Payment verification reason required'; end if;
  select * into c from public.november_import_candidates where id=p_candidate for update;
  if not found then raise exception 'November candidate not found'; end if;
  if c.source_payment<=0 or c.source_payment_date is null or c.source_payment_reference is null then
    raise exception 'No unambiguous source receipt is available for this candidate';
  end if;
  if p_amount is distinct from c.source_payment or p_paid_on is distinct from c.source_payment_date
     or date_trunc('month',p_paid_on)::date<>date '2026-11-01' then
    raise exception 'Payment amount and date must match the source receipt and November 2026';
  end if;
  update public.november_import_candidates
    set approved_payment_verified=true,payment_review_reason=trim(p_reason)
    where id=p_candidate;
  insert into public.audit_logs(table_name,action,row_id,actor_id,new_data,reason,approved_by)
  values('november_import_candidates','VERIFY_PAYMENT',c.id::text,auth.uid(),
    jsonb_build_object('source_key',c.source_key,'amount',p_amount,'paid_on',p_paid_on,
      'reference',c.source_payment_reference),trim(p_reason),auth.uid());
end $$;

revoke all on function public.november_import_save_profile(uuid,jsonb),
  public.november_import_profile_summary(text),
  public.november_import_verify_payment(uuid,numeric,date,text) from public,anon,authenticated;
grant execute on function public.november_import_save_profile(uuid,jsonb),
  public.november_import_profile_summary(text),
  public.november_import_verify_payment(uuid,numeric,date,text) to authenticated;

-- The old bulk helper promoted source amounts into approved agreements. Keep
-- approval explicit for each reviewed record under the current finance policy.
revoke execute on function public.november_import_approve_ready(text) from public,anon,authenticated;

notify pgrst,'reload schema';
commit;
