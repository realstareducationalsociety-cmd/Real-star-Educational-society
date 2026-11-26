-- Additive, transactional immediate educational class membership changes.
-- Does not modify monthly registrations, fees, payments, or receipts.
begin;

create or replace function public.change_student_class_membership(
  p_student uuid,
  p_prior_enrollment uuid,
  p_class uuid,
  p_effective_on date,
  p_operation text,
  p_reason text default null
) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_student public.students%rowtype;
  v_class public.class_rooms%rowtype;
  v_prior public.enrollments%rowtype;
  v_target_existing boolean := false;
  v_target_enrolled_on date;
  v_target_active boolean;
  v_today date := (now() at time zone 'Asia/Karachi')::date;
  v_enrollment uuid;
  v_has_active_financial_registration boolean;
begin
  if not public.staff_has_any(array['admin','registrar']) then
    raise exception 'Education access required' using errcode='42501';
  end if;
  if p_student is null or p_class is null or p_effective_on is null then
    raise exception 'Student, class, and effective date are required';
  end if;
  if p_effective_on <> v_today then
    raise exception 'Class membership changes must take effect today';
  end if;
  if p_operation not in ('move','add','correct') then
    raise exception 'Invalid class change operation';
  end if;
  if p_operation in ('move','correct') and p_prior_enrollment is null then
    raise exception 'Select the specific current class membership to change';
  end if;
  if p_operation='add' and p_prior_enrollment is not null then
    raise exception 'Adding a second class must not include a source membership';
  end if;
  if p_operation='correct' and length(trim(coalesce(p_reason,''))) < 4 then
    raise exception 'A correction reason of at least 4 characters is required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_student::text,0));
  select * into v_student from public.students where id=p_student and active for update;
  if not found then raise exception 'Active student not found'; end if;
  if p_operation in ('move','correct') then
    select exists(
      select 1 from public.monthly_memberships m
      join public.billing_periods bp on bp.id=m.period_id
      where m.enrollment_id=p_prior_enrollment and m.registration_active
        and bp.status='open'
    ) into v_has_active_financial_registration;
    if v_has_active_financial_registration then
      raise exception 'An active monthly financial registration exists; use the separate financial correction process';
    end if;
  end if;
  select * into v_class from public.class_rooms where id=p_class and active for update;
  if not found then raise exception 'Active class not found'; end if;
  if p_operation in ('move','correct') then
    select * into v_prior from public.enrollments
      where id=p_prior_enrollment and student_id=p_student and active and class_id<>p_class
      for update;
    if not found then
      raise exception 'The selected source class is not an active class for this student';
    end if;
  end if;
  if p_operation='add' and exists (select 1 from public.enrollments where student_id=p_student and class_id=p_class and active) then
    raise exception 'Student is already enrolled in this class';
  end if;
  if exists (select 1 from public.enrollments where student_id=p_student and class_id=p_class and active) then
    raise exception 'Student is already enrolled in the target class';
  end if;
  select id,enrolled_on,active into v_enrollment,v_target_enrolled_on,v_target_active
    from public.enrollments where student_id=p_student and class_id=p_class for update;
  v_target_existing := found;
  if v_enrollment is null then
    insert into public.enrollments(student_id,class_id,enrolled_on,active)
    values(p_student,p_class,p_effective_on,true) returning id into v_enrollment;
  else
    -- Preserve enrolled_on as the historical start date even when reactivating a link.
    update public.enrollments set active=true where id=v_enrollment;
  end if;
  if p_operation in ('move','correct') then
    update public.enrollments set active=false where id=v_prior.id;
  end if;
  insert into public.audit_logs(table_name,action,row_id,actor_id,old_data,new_data,reason,approved_by)
  values('enrollments',upper(p_operation)||'_CLASS',v_enrollment::text,auth.uid(),
    case when p_operation='add' then null else jsonb_build_object('enrollment_id',v_prior.id,'class_id',v_prior.class_id,'active',v_prior.active,'enrolled_on',v_prior.enrolled_on) end,
    jsonb_build_object('student_id',p_student,'source_enrollment_id',p_prior_enrollment,'enrollment_id',v_enrollment,'class_id',p_class,'class_title',v_class.title,'active',true,'effective_on',p_effective_on,'operation',p_operation,'prior_enrollment_id',case when p_operation='add' then null else v_prior.id end,'prior_class_id',case when p_operation='add' then null else v_prior.class_id end,'prior_enrolled_on',case when p_operation='add' then null else v_prior.enrolled_on end,'target_enrollment_existed',v_target_existing,'target_was_active',v_target_active,'target_previous_enrolled_on',v_target_enrolled_on,'target_enrolled_on',case when v_target_existing then v_target_enrolled_on else p_effective_on end),
    nullif(trim(p_reason),''),case when public.staff_has_any(array['admin']) then auth.uid() end);
  return jsonb_build_object('student_id',p_student,'prior_enrollment_id',p_prior_enrollment,'enrollment_id',v_enrollment,'class_id',p_class,'class_title',v_class.title,'effective_on',p_effective_on,'operation',p_operation);
end $$;

revoke all on function public.change_student_class_membership(uuid,uuid,uuid,date,text,text) from public,anon;
grant execute on function public.change_student_class_membership(uuid,uuid,uuid,date,text,text) to authenticated;
notify pgrst, 'reload schema';
commit;
