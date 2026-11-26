-- 018_noorzia_november_registration_alignment.sql
-- Real Star Educational Society | November 2026 | Noorzia Ataei (RS-000056) class correction
--
-- PURPOSE
--   Correct Noorzia Atayee's November 2026 class from School Grade 2 to School Grade 3
--   after the original 800 PKR receipt was voided and the cash was refunded.
--
-- METHOD
--   Preserve the original educational enrollment, create/reactivate the Grade 3 link,
--   create a matching monthly membership with zero payment and 800 PKR outstanding.
--   Keep the original receipt voided and its refund represented only in the correction
--   audit; do not post another cash outflow because the refund already occurred.
--
-- SAFETY
--   * Does NOT disable freeze_enrollment_identity or guard_membership_change triggers
--   * Valid November payments after correction are zero PKR
--   * Does NOT affect other students
--   * Administrator-only; advisory-locked; transactional rollback on error
--
-- PREREQUISITES
--   Migrations 001..017 must already be applied.
begin;

create or replace function public.correct_november_student_class(
  p_student_code text,
  p_correct_class_id uuid,
  p_reason text,
  p_payment_request_id uuid,
  p_original_receipt_id uuid default null,
  p_manager_confirmed_refunded boolean default false,
  p_manager_approved_grade3_registration boolean default false
) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_student public.students%rowtype;
  v_period public.billing_periods%rowtype;
  v_old_membership public.monthly_memberships%rowtype;
  v_old_enrollment public.enrollments%rowtype;
  v_correction_payment public.payments%rowtype;
  v_prior_void_audit_id bigint;
  v_old_class public.class_rooms%rowtype;
  v_new_class public.class_rooms%rowtype;
  v_teacher public.teachers%rowtype;
  v_new_enrollment uuid;
  v_new_membership uuid;
  v_paid_total numeric(12,2);
  v_payment_ids uuid[];
  v_result jsonb;
begin
  if not public.staff_has_any(array['admin']) then
    raise exception 'Administrator approval required' using errcode='42501';
  end if;
  if length(trim(coalesce(p_student_code,''))) = 0 then
    raise exception 'Student code is required';
  end if;
  if p_correct_class_id is null then
    raise exception 'Correct class id is required';
  end if;
  if p_correct_class_id <> 'e2df6a0e-a6b2-4193-a585-ffed7a931ddc'::uuid then
    raise exception 'This correction must use the verified School Grade 3 class e2df6a0e-a6b2-4193-a585-ffed7a931ddc';
  end if;
  if length(trim(coalesce(p_reason,''))) < 4 then
    raise exception 'Correction reason of at least 4 characters is required';
  end if;
  if p_payment_request_id is null then
    raise exception 'Payment request id is required';
  end if;
  if p_original_receipt_id is null or p_manager_confirmed_refunded is distinct from true then
    raise exception 'Provide the original receipt ID and manager confirmation that the refund already occurred';
  end if;
  if p_manager_approved_grade3_registration is distinct from true then
    raise exception 'Manager approval is required to create the November Grade 3 financial registration';
  end if;
  if p_original_receipt_id <> '446d758c-3466-45bc-901a-063dfc05f752'::uuid then
    raise exception 'This verified correction must use the original receipt 446d758c-3466-45bc-901a-063dfc05f752';
  end if;

  select * into v_student from public.students
   where student_code = trim(p_student_code) limit 1;
  if not found then
    raise exception 'Student with code % not found', p_student_code;
  end if;
  if v_student.student_code <> 'RS-000056' then
    raise exception 'This approved correction is limited to student RS-000056';
  end if;

  select * into v_period from public.billing_periods
   where year_month = date '2026-11-01' for update;
  if not found then
    raise exception 'November 2026 billing period is missing';
  end if;
  if v_period.status <> 'open' then
    raise exception 'November 2026 billing period is not open';
  end if;

  perform public.lock_open_months(array[v_period.year_month]);
  perform pg_advisory_xact_lock(hashtextextended('rsms-nor-zia-class-correction',0));
  perform pg_advisory_xact_lock(hashtextextended(p_payment_request_id::text,0));

  select m.* into v_old_membership
  from public.monthly_memberships m
  join public.enrollments e on e.id = m.enrollment_id
  join public.class_rooms c on c.id=e.class_id
  where m.period_id = v_period.id
    and e.student_id = v_student.id
    and c.title = 'School Grade 2'
    and m.registration_active
  for update of m,e;
  if not found then
    raise exception 'No active November 2026 registration found for student %', v_student.student_code;
  end if;

  select * into v_old_enrollment from public.enrollments where id = v_old_membership.enrollment_id for update;
  select * into v_old_class from public.class_rooms where id = v_old_enrollment.class_id;
  if v_old_class.title <> 'School Grade 2' then
    raise exception 'Expected the incorrect November class to be School Grade 2';
  end if;

  select * into v_new_class from public.class_rooms
   where id = p_correct_class_id and active for update;
  if not found then
    raise exception 'Correct class does not exist or is inactive';
  end if;
  if v_new_class.title <> 'School Grade 3' then
    raise exception 'Expected the correct class to be School Grade 3';
  end if;

  select * into v_teacher from public.teachers where id = v_new_class.teacher_id;
  if v_teacher.full_name is distinct from 'Tahera Sakhizada' then
    raise exception 'Verified School Grade 3 class must be taught by Tahera Sakhizada';
  end if;

  if v_old_membership.teacher_id is distinct from v_new_class.teacher_id then
    raise exception 'Correct class teacher differs from registered class teacher';
  end if;
  if v_new_class.teacher_id is distinct from v_old_membership.teacher_id
     or v_old_membership.base_fee <> 1000 or v_old_membership.discount <> 200 then
    raise exception 'Student, teacher, fee, or discount does not match the approved correction';
  end if;

  if v_old_membership.proration_rule is distinct from 'manual_agreement' then
    raise exception 'Source financial agreement is not an approved manual agreement';
  end if;

  if exists (
    select 1 from public.teacher_settlements ts
    where ts.period_id=v_period.id and ts.class_id in (v_old_class.id,v_new_class.id)
      and ts.teacher_id=v_old_membership.teacher_id and ts.voided_at is null
  ) then
    raise exception 'Teacher settlement exists for the source or target class in November 2026';
  end if;

  if exists (
    select 1 from public.monthly_memberships m2
    join public.enrollments e2 on e2.id = m2.enrollment_id
    where m2.period_id = v_period.id
      and e2.student_id = v_student.id
      and e2.class_id = p_correct_class_id
  ) then
    raise exception 'A November membership already exists in the correct class';
  end if;

  select * into v_correction_payment from public.payments
   where id=p_original_receipt_id and monthly_membership_id=v_old_membership.id
   for update;
  if not found then
    raise exception 'Specified original receipt is not attached to the incorrect November registration';
  end if;
  if v_correction_payment.amount<>800 or v_correction_payment.paid_on<>date '2026-11-24'
     or v_correction_payment.method not in ('cash','bank','other') then
    raise exception 'Specified receipt does not match the verified 800 PKR payment';
  end if;
  if v_correction_payment.voided_at is null then
    raise exception 'The original receipt must remain voided after the confirmed refund';
  end if;
  if exists(select 1 from public.payments p
    where p.id<>v_correction_payment.id and p.monthly_membership_id=v_old_membership.id
      and p.amount=800 and p.voided_at is null) then
    raise exception 'Another valid 800 PKR receipt already exists for this registration';
  end if;
  if exists(select 1 from public.payments p join public.monthly_memberships m on m.id=p.monthly_membership_id
    join public.enrollments e on e.id=m.enrollment_id
    where e.student_id=v_student.id and m.period_id=v_period.id and p.id<>v_correction_payment.id
      and p.amount=800 and p.voided_at is null) then
    raise exception 'Another valid 800 PKR receipt exists for this student and month';
  end if;
  select a.id into v_prior_void_audit_id from public.audit_logs a
   where a.table_name='payments' and a.row_id=v_correction_payment.id::text and a.action='UPDATE'
     and a.old_data->>'voided_at' is null and a.new_data->>'voided_at' is not null
   order by a.created_at desc,a.id desc limit 1;
  if v_prior_void_audit_id is null then
    raise exception 'Receipt void history is missing; manual review is required';
  end if;

  select coalesce(sum(p.amount),0) into v_paid_total
  from public.payments p
  join public.monthly_memberships m on m.id=p.monthly_membership_id
  join public.billing_periods b on b.id=m.period_id
  join public.enrollments e on e.id=m.enrollment_id
  where e.student_id=v_student.id and b.id=v_period.id and p.voided_at is null;
  if v_paid_total<>0 then
    raise exception 'Valid November payments exist; this correction requires a zero valid-payment total';
  end if;
  v_paid_total:=0;
  v_payment_ids:=array[v_correction_payment.id];

  -- Preserve the existing educational enrollment row when the destination link already exists.
  -- This avoids violating unique(student_id,class_id) or creating duplicate class history rows.
  select id into v_new_enrollment from public.enrollments
   where student_id=v_student.id and class_id=p_correct_class_id for update;
  if not found then
  insert into public.enrollments(student_id, class_id, enrolled_on, active)
  values (v_student.id, p_correct_class_id, v_old_enrollment.enrolled_on, true)
  returning id into v_new_enrollment;
  else
    update public.enrollments set active=true where id=v_new_enrollment;
  end if;

  -- 3. Create new membership in correct class
  insert into public.monthly_memberships(
    period_id, enrollment_id, teacher_id, class_title_snapshot, registered_on,
    original_fee, base_fee, discount, teacher_discount_share, registration_active,
    manual_teacher_share, manual_office_share, manual_adjustment_reason, manual_adjusted_by, manual_adjusted_at,
    agreement_approved_by, agreement_approved_at, discount_reason, proration_rule,
    registration_type, notes, teacher_share_mode, teacher_share_reason, sponsored_confirmed,
    start_time_snapshot, end_time_snapshot
  ) values (
    v_period.id, v_new_enrollment, v_new_class.teacher_id, v_new_class.title, v_old_membership.registered_on,
    v_old_membership.original_fee, v_old_membership.base_fee, v_old_membership.discount,
    v_old_membership.teacher_discount_share, true,
    v_old_membership.manual_teacher_share, v_old_membership.manual_office_share, v_old_membership.manual_adjustment_reason,
    v_old_membership.manual_adjusted_by, v_old_membership.manual_adjusted_at,
    v_old_membership.agreement_approved_by, v_old_membership.agreement_approved_at,
    v_old_membership.discount_reason, 'manual_agreement',
    coalesce(v_old_membership.registration_type, 'returning'),
    'تصحیح صنف ثبت‌نام از ' || v_old_class.title || ' به ' || v_new_class.title || '.',
    coalesce(v_old_membership.teacher_share_mode,'standard'), v_old_membership.teacher_share_reason, v_old_membership.sponsored_confirmed,
    v_new_class.start_time, v_new_class.end_time
  ) returning id into v_new_membership;

  -- Keep the receipt attached to the historical Grade 2 membership and voided.
  -- The cash refund has already happened; no payment or expense row is added here.

  -- Deactivate old Grade 2 membership
  update public.monthly_memberships
    set registration_active = false,
        notes = concat_ws(E'\n', coalesce(v_old_membership.notes,''),
          'لغو ثبت‌نام در صنف ' || v_old_class.title || ' به دلیل ثبت‌نام اشتباه؛ منتقل به ' || v_new_class.title || '. ' || trim(p_reason))
  where id = v_old_membership.id;

  update public.enrollments set active=false where id=v_old_enrollment.id;

  -- 6. Audit trail
  insert into public.audit_logs(table_name, action, row_id, actor_id, old_data, new_data, reason, approved_by)
  values(
    'monthly_memberships', 'CORRECT_NOVEMBER_CLASS', v_old_membership.id::text, auth.uid(),
    jsonb_build_object(
      'membership_id', v_old_membership.id,
      'enrollment_id', v_old_enrollment.id,
      'class_id', v_old_enrollment.class_id,
      'class_title', v_old_class.title,
      'registration_active', true,
      'payment_ids', to_jsonb(v_payment_ids),
      'receipt_id',v_correction_payment.id,
      'receipt_amount',v_correction_payment.amount,
      'receipt_paid_on',v_correction_payment.paid_on,
      'receipt_method',v_correction_payment.method,
      'receipt_voided_at',v_correction_payment.voided_at,
      'receipt_void_reason',v_correction_payment.void_reason,
      'prior_void_audit_id',v_prior_void_audit_id,
      'valid_payment_total', v_paid_total
      ,'registered_on',v_old_membership.registered_on
      ,'registration_type',v_old_membership.registration_type
      ,'teacher_discount_share',v_old_membership.teacher_discount_share
      ,'manual_teacher_share',v_old_membership.manual_teacher_share
      ,'manual_office_share',v_old_membership.manual_office_share
    ),
    jsonb_build_object(
      'old_membership_id', v_old_membership.id,
      'new_membership_id', v_new_membership,
      'new_enrollment_id', v_new_enrollment,
      'old_class_id', v_old_enrollment.class_id,
      'old_class_title', v_old_class.title,
      'new_class_id', p_correct_class_id,
      'new_class_title', v_new_class.title,
      'source_registration_active', false,
      'target_registration_active', true,
      'voided_receipt_id_preserved',v_correction_payment.id,
      'receipt_remains_voided',true,
      'refund_confirmed_by',auth.uid(),
      'refund_confirmation_recorded_at',now(),
      'grade3_registration_approved_by',auth.uid(),
      'grade3_registration_approved_at',now(),
      'refund_amount',v_correction_payment.amount,
      'refund_date',null,
      'refund_cash_outflow_reposted',false,
      'prior_void_audit_id',v_prior_void_audit_id,
      'new_receipts_created', false,
      'new_expenses_created',false,
      'valid_payment_total', v_paid_total,
      'registered_on_preserved',v_old_membership.registered_on,
      'registration_type_preserved',v_old_membership.registration_type,
      'teacher_discount_share_preserved',v_old_membership.teacher_discount_share,
      'manual_teacher_share_preserved',v_old_membership.manual_teacher_share,
      'manual_office_share_preserved',v_old_membership.manual_office_share,
      'net_valid_revenue', v_paid_total,
      'outstanding_after_correction',v_old_membership.amount_due
    ),
    trim(p_reason),
    case when public.staff_has_any(array['admin']) then auth.uid() end
  );

  insert into public.migration_review_items(issue, table_name, row_id, details, resolved_at, resolved_by, resolution)
  values(
    'November class correction for RS-000056: ' || v_old_class.title || ' to ' || v_new_class.title,
    'monthly_memberships', v_old_membership.id::text,
    jsonb_build_object(
      'student_code', v_student.student_code,
      'old_class_id', v_old_enrollment.class_id,
      'old_class_title', v_old_class.title,
      'new_class_id', p_correct_class_id,
      'new_class_title', v_new_class.title,
      'target_registration_active',true,
      'grade3_registration_approved_by',auth.uid(),
      'teacher_id', v_new_class.teacher_id,
      'period', v_period.year_month,
      'payment_ids_preserved', to_jsonb(v_payment_ids),
      'valid_payment_total', v_paid_total,
      'registered_on_preserved',v_old_membership.registered_on,
      'registration_type_preserved',v_old_membership.registration_type,
      'teacher_discount_share_preserved',v_old_membership.teacher_discount_share,
      'manual_teacher_share_preserved',v_old_membership.manual_teacher_share,
      'manual_office_share_preserved',v_old_membership.manual_office_share,
      'fee', v_old_membership.base_fee,
      'discount', v_old_membership.discount,
      'paid', v_paid_total,
      'outstanding', greatest(0, v_old_membership.amount_due - v_paid_total)
    ),
    now(), auth.uid(),
    'Class corrected after confirmed refund. Original receipt remains voided; refund date was not provided and no additional cash outflow was posted.'
  );

  v_result := jsonb_build_object(
    'student_code', v_student.student_code,
    'student_name', v_student.first_name || ' ' || v_student.last_name,
    'month', v_period.year_month,
    'old_class_id', v_old_enrollment.class_id,
    'old_class_title', v_old_class.title,
    'new_class_id', p_correct_class_id,
    'new_class_title', v_new_class.title,
    'teacher_id', v_new_class.teacher_id,
    'teacher_name', v_teacher.full_name,
    'old_membership_id', v_old_membership.id,
    'new_membership_id', v_new_membership,
    'new_enrollment_id', v_new_enrollment,
    'original_payment_id', v_correction_payment.id,
    'payment_ids_preserved', to_jsonb(v_payment_ids),
    'old_payment_voided', true,
    'original_receipt_reinstated',false,
    'preserved_receipt_ids', to_jsonb(v_payment_ids),
    'new_payment_created', false,
    'receipt_amount_preserved', v_correction_payment.amount,
    'fee', v_old_membership.base_fee,
    'discount', v_old_membership.discount,
    'paid', v_paid_total,
    'outstanding', v_old_membership.amount_due,
    'registration_preserved', true,
    'new_cash_receipt_created', false,
    'duplicate_revenue_created', false,
    'net_valid_revenue', v_paid_total,
    'refund_confirmed',true,
    'refund_date',null,
    'cash_outflow_reposted',false,
    'teacher_settlement_created',false,
    'message', 'Class corrected from ' || v_old_class.title || ' to ' || v_new_class.title || '. Original receipt remains voided; the prior refund is documented without reposting cash outflow.'
  );
  return v_result;
end $$;

revoke all on function public.correct_november_student_class(text,uuid,text,uuid,uuid,boolean,boolean) from public,anon;
grant execute on function public.correct_november_student_class(text,uuid,text,uuid,uuid,boolean,boolean) to authenticated;

notify pgrst, 'reload schema';
commit;
