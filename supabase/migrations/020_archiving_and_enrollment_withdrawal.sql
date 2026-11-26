-- Reversible archives and guarded withdrawal of one educational class link.
-- Historical records remain in place. No production execution is included here.
begin;

create or replace function public.archive_student(p_student uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_student public.students%rowtype; v_open boolean; v_due numeric;
begin
  if not public.staff_has_any(array['admin']) then raise exception 'Administrator approval required' using errcode='42501'; end if;
  if length(trim(coalesce(p_reason,'')))<4 then raise exception 'Archive reason of at least 4 characters is required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
  perform pg_advisory_xact_lock(hashtextextended(p_student::text,0));
  select * into v_student from public.students where id=p_student for update;
  if not found then raise exception 'Student not found'; end if;
  if not v_student.active then raise exception 'Student is already archived'; end if;
  select exists(select 1 from public.monthly_memberships m join public.billing_periods b on b.id=m.period_id
    join public.enrollments e on e.id=m.enrollment_id where e.student_id=p_student and m.registration_active and b.status='open') into v_open;
  select coalesce(sum(f.balance_due),0) into v_due from public.month_fee_overview f where f.student_id=p_student;
  if v_open or v_due>0 then raise exception 'Student has an active financial registration or outstanding balance; review financial accounts before archiving'; end if;
  if exists(select 1 from public.enrollments where student_id=p_student and active) then
    raise exception 'Student has active class memberships; withdraw each membership before archiving';
  end if;
  if exists(select 1 from public.book_sale_overview where student_id=p_student and balance_due>0)
     or exists(select 1 from public.chapter_sale_overview where student_id=p_student and balance_due>0) then
    raise exception 'Student has an outstanding material balance';
  end if;
  update public.students set active=false where id=p_student;
  insert into public.audit_logs(table_name,action,row_id,actor_id,old_data,new_data,reason,approved_by)
  values('students','ARCHIVE',p_student::text,auth.uid(),to_jsonb(v_student),jsonb_build_object('id',p_student,'active',false),trim(p_reason),auth.uid());
  return jsonb_build_object('student_id',p_student,'active',false,'archived',true);
end $$;

create or replace function public.restore_student(p_student uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_student public.students%rowtype;
begin
  if not public.staff_has_any(array['admin']) then raise exception 'Administrator approval required' using errcode='42501'; end if;
  if length(trim(coalesce(p_reason,'')))<4 then raise exception 'Restore reason of at least 4 characters is required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
  perform pg_advisory_xact_lock(hashtextextended(p_student::text,0));
  select * into v_student from public.students where id=p_student for update;
  if not found then raise exception 'Student not found'; end if;
  if v_student.active then raise exception 'Student is already active'; end if;
  update public.students set active=true where id=p_student;
  insert into public.audit_logs(table_name,action,row_id,actor_id,old_data,new_data,reason,approved_by)
  values('students','RESTORE',p_student::text,auth.uid(),to_jsonb(v_student),jsonb_build_object('id',p_student,'active',true),trim(p_reason),auth.uid());
  return jsonb_build_object('student_id',p_student,'active',true,'restored',true);
end $$;

-- Deliberately disabled until a separate reviewed release authorizes deletion.
create or replace function public.purge_student_without_history(p_student uuid, p_manager_confirmed boolean)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
begin
  raise exception 'Permanent deletion is disabled; archive the profile instead' using errcode='42501';
end $$;

create or replace function public.archive_class(p_class uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_class public.class_rooms%rowtype; v_active bigint;
begin
  if not public.staff_has_any(array['admin']) then raise exception 'Administrator approval required' using errcode='42501'; end if;
  if length(trim(coalesce(p_reason,'')))<4 then raise exception 'Archive reason of at least 4 characters is required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
  select * into v_class from public.class_rooms where id=p_class for update;
  if not found then raise exception 'Class not found'; end if;
  select count(*) into v_active from public.enrollments where class_id=p_class and active;
  if v_active>0 then raise exception 'Class has % active student memberships; move or withdraw each student first',v_active; end if;
  if not v_class.active then raise exception 'Class is already archived'; end if;
  if exists(select 1 from public.monthly_memberships m join public.enrollments e on e.id=m.enrollment_id
    join public.billing_periods b on b.id=m.period_id where e.class_id=p_class and m.registration_active and b.status='open') then
    raise exception 'Class has active financial registrations; review them before archiving';
  end if;
  update public.class_rooms set active=false where id=p_class;
  insert into public.audit_logs(table_name,action,row_id,actor_id,old_data,new_data,reason,approved_by)
  values('class_rooms','ARCHIVE',p_class::text,auth.uid(),to_jsonb(v_class),jsonb_build_object('id',p_class,'active',false),trim(p_reason),auth.uid());
  return jsonb_build_object('class_id',p_class,'active',false,'archived',true,'active_memberships',v_active);
end $$;

create or replace function public.restore_class(p_class uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_class public.class_rooms%rowtype;
begin
  if not public.staff_has_any(array['admin']) then raise exception 'Administrator approval required' using errcode='42501'; end if;
  if length(trim(coalesce(p_reason,'')))<4 then raise exception 'Restore reason of at least 4 characters is required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
  select * into v_class from public.class_rooms where id=p_class for update;
  if not found then raise exception 'Class not found'; end if;
  if v_class.active then raise exception 'Class is already active'; end if;
  update public.class_rooms set active=true where id=p_class;
  insert into public.audit_logs(table_name,action,row_id,actor_id,old_data,new_data,reason,approved_by)
  values('class_rooms','RESTORE',p_class::text,auth.uid(),to_jsonb(v_class),jsonb_build_object('id',p_class,'active',true),trim(p_reason),auth.uid());
  return jsonb_build_object('class_id',p_class,'active',true,'restored',true);
end $$;

create or replace function public.withdraw_student_from_class(p_student uuid, p_enrollment uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_link public.enrollments%rowtype;
begin
  if not public.staff_has_any(array['admin','registrar']) then raise exception 'Education access required' using errcode='42501'; end if;
  if length(trim(coalesce(p_reason,'')))<4 then raise exception 'Withdrawal reason of at least 4 characters is required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
  perform pg_advisory_xact_lock(hashtextextended(p_student::text,0));
  select * into v_link from public.enrollments where id=p_enrollment and student_id=p_student and active for update;
  if not found then raise exception 'Selected active class membership not found for this student'; end if;
  if exists(select 1 from public.monthly_memberships m join public.billing_periods b on b.id=m.period_id
    where m.enrollment_id=p_enrollment and m.registration_active and b.status='open') then
    raise exception 'An active monthly financial registration exists; review or cancel it through the financial workflow before withdrawing the class membership';
  end if;
  update public.enrollments set active=false where id=p_enrollment;
  insert into public.audit_logs(table_name,action,row_id,actor_id,old_data,new_data,reason,approved_by)
  values('enrollments','WITHDRAW_FROM_CLASS',p_enrollment::text,auth.uid(),to_jsonb(v_link),jsonb_build_object('student_id',p_student,'enrollment_id',p_enrollment,'class_id',v_link.class_id,'active',false),trim(p_reason),case when public.staff_has_any(array['admin']) then auth.uid() end);
  return jsonb_build_object('student_id',p_student,'enrollment_id',p_enrollment,'class_id',v_link.class_id,'active',false);
end $$;

revoke all on function public.archive_student(uuid,text),public.restore_student(uuid,text),public.purge_student_without_history(uuid,boolean),public.archive_class(uuid,text),public.restore_class(uuid,text),public.withdraw_student_from_class(uuid,uuid,text) from public,anon;
grant execute on function public.archive_student(uuid,text),public.restore_student(uuid,text),public.purge_student_without_history(uuid,boolean),public.archive_class(uuid,text),public.restore_class(uuid,text),public.withdraw_student_from_class(uuid,uuid,text) to authenticated;
-- Invoker trigger: direct API updates cannot bypass the audited RPCs.
create or replace function public.guard_archive_status() returns trigger
language plpgsql set search_path=public,pg_temp as $$
begin
  if new.active is distinct from old.active and (
    current_user in ('authenticated','anon')
    or (auth.uid() is not null and (
      (tg_table_name='students' and not public.staff_has_any(array['admin']))
      or (tg_table_name='class_rooms' and not public.staff_has_any(array['admin']))
      or (tg_table_name='enrollments' and not public.staff_has_any(array['admin','registrar']))
    ))
  ) then
    raise exception 'Use the audited archive, restore or class membership workflow' using errcode='42501';
  end if;
  return new;
end $$;
do $$ begin
  if not exists(select 1 from pg_trigger where tgrelid='public.students'::regclass and tgname='guard_archive_status' and not tgisinternal) then
    execute 'create trigger guard_archive_status before update on public.students for each row execute function public.guard_archive_status()';
  end if;
  if not exists(select 1 from pg_trigger where tgrelid='public.class_rooms'::regclass and tgname='guard_archive_status' and not tgisinternal) then
    execute 'create trigger guard_archive_status before update on public.class_rooms for each row execute function public.guard_archive_status()';
  end if;
  if not exists(select 1 from pg_trigger where tgrelid='public.enrollments'::regclass and tgname='guard_archive_status' and not tgisinternal) then
    execute 'create trigger guard_archive_status before update on public.enrollments for each row execute function public.guard_archive_status()';
  end if;
end $$;
-- Parent locks serialize new/reactivated links with archive checks.
create or replace function public.guard_active_class_link() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.active then
    perform 1 from public.students where id=new.student_id and active for share;
    if not found then raise exception 'Active student not found'; end if;
    perform 1 from public.class_rooms where id=new.class_id and active for share;
    if not found then raise exception 'Active class not found'; end if;
  end if;
  return new;
end $$;
do $$ begin
  if not exists(select 1 from pg_trigger where tgrelid='public.enrollments'::regclass and tgname='guard_active_class_link' and not tgisinternal) then
    execute 'create trigger guard_active_class_link before insert or update on public.enrollments for each row execute function public.guard_active_class_link()';
  end if;
end $$;
revoke all on function public.guard_archive_status(),public.guard_active_class_link() from public,anon,authenticated;
revoke delete on public.students,public.class_rooms,public.enrollments from authenticated,anon;
notify pgrst,'reload schema';
commit;
