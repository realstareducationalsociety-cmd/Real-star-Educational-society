-- READ ONLY: investigate the reported November 2026 class registration mismatch for RS-000056 (Noorzia Ataei).
-- This script never writes data. Run as an authenticated administrator.
-- It extends supabase/november_noorzia_audit_readonly.sql with explicit mismatch detection.
begin transaction read only;

-- 1. Student identity
select
  s.id as student_id,
  s.student_code,
  s.first_name,
  s.last_name,
  s.phone,
  s.active as student_active,
  s.registered_on,
  s.notes
from public.students s
where s.student_code = 'RS-000056';

-- 2. All class enrolments for this student (educational links, any month)
select
  e.id as enrollment_id,
  e.student_id,
  e.class_id,
  c.title as class_title,
  t.full_name as class_teacher,
  c.start_time,
  c.end_time,
  c.active as class_active,
  e.active as enrollment_active,
  e.enrolled_on,
  e.created_at
from public.enrollments e
join public.class_rooms c on c.id = e.class_id
join public.teachers t on t.id = c.teacher_id
where e.student_id = (select id from public.students where student_code = 'RS-000056')
order by e.enrolled_on, e.id;

-- 3. November 2026 memberships with class snapshot vs live enrolment class (mismatch detection)
select
  m.id as monthly_membership_id,
  m.period_id,
  b.year_month,
  m.enrollment_id,
  e.class_id as enrolment_class_id,
  cr.title as enrolment_class_title,
  m.class_title_snapshot as registered_class_snapshot,
  m.teacher_id as membership_teacher_id,
  ct.full_name as membership_teacher_name,
  m.registration_active,
  m.registered_on,
  m.base_fee,
  m.discount,
  m.amount_due,
  m.registration_type,
  m.proration_rule,
  case
    when cr.id is null then 'ENROLMENT_CLASS_MISSING'
    when cr.title <> m.class_title_snapshot then 'CLASS_TITLE_MISMATCH'
    when ct.id <> m.teacher_id then 'TEACHER_MISMATCH'
    else 'ALIGNED'
  end as class_consistency,
  coalesce(sum(p.amount) filter(where p.voided_at is null), 0) as valid_payment_total,
  count(p.id) filter(where p.voided_at is null) as valid_receipt_count
from public.students s
join public.enrollments e on e.student_id = s.id
join public.class_rooms cr on cr.id = e.class_id
join public.monthly_memberships m on m.enrollment_id = e.id
join public.billing_periods b on b.id = m.period_id
join public.teachers ct on ct.id = m.teacher_id
left join public.payments p on p.monthly_membership_id = m.id
where s.student_code = 'RS-000056'
  and b.year_month = date '2026-11-01'
group by
  m.id, m.period_id, b.year_month, m.enrollment_id, e.class_id, cr.title,
  m.class_title_snapshot, m.teacher_id, ct.full_name,
  m.registration_active, m.registered_on, m.base_fee, m.discount, m.amount_due,
  m.registration_type, m.proration_rule
order by m.registered_on, m.id;

-- 4. Multiple active November memberships (must not happen; unique index monthly_active_identity)
select
  m.id, m.enrollment_id, e.student_id, s.student_code, b.year_month, m.registration_active, m.class_title_snapshot
from public.monthly_memberships m
join public.enrollments e on e.id = m.enrollment_id
join public.students s on s.id = e.student_id
join public.billing_periods b on b.id = m.period_id
where s.student_code = 'RS-000056'
  and b.year_month = date '2026-11-01'
  and m.registration_active
order by m.id;

-- 5. November billing period state
select year_month, status, closed_at, closed_by, closure_notes
from public.billing_periods
where year_month = date '2026-11-01';

-- 6. November import candidate provenance for this student
select
  c.id as candidate_id,
  c.source_key,
  c.source_row,
  c.source_sheet,
  c.source_month,
  c.status as review_status,
  c.identity_status,
  c.student_id as candidate_student_id,
  c.enrollment_id as candidate_enrollment_id,
  c.class_id as candidate_class_id,
  c.class_title as staged_class_name,
  c.teacher_name as staged_teacher_name,
  c.membership_id,
  c.approved_class_id,
  c.approved_tuition,
  c.approved_discount,
  c.approved_by,
  c.approved_at,
  c.posted_at,
  d.destination_table,
  d.destination_id,
  d.mapping_status
from public.november_import_candidates c
join public.historical_import_batches b on b.id = c.batch_id
left join public.historical_import_destinations d on d.source_row_id = c.source_row_id
where c.source_sheet = 'Registrations'
  and coalesce(c.student_id, c.identity_student_id, c.approved_student_id) in (
    select id from public.students where student_code = 'RS-000056'
  )
  and c.source_month in ('Nov', 'November', '2026-11', 'November 2026')
order by c.source_row, d.destination_table;

rollback;
