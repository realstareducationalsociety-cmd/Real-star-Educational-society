-- READ ONLY: run as an authenticated administrator to investigate the reported
-- November class mismatch for RS-000056. This script never writes data.
begin transaction read only;

-- Current and historical class registrations, agreements, and real receipts.
select
  s.id as student_id,
  s.student_code,
  concat_ws(' ',s.first_name,s.last_name) as student_name,
  e.id as enrollment_id,
  e.active as class_membership_active,
  e.enrolled_on as class_membership_started,
  c.title as current_class_name,
  t.full_name as current_teacher,
  c.start_time,
  c.end_time,
  b.year_month,
  m.id as monthly_membership_id,
  m.class_title_snapshot as registered_class_snapshot,
  m.registration_active,
  m.registered_on,
  m.original_fee,
  m.base_fee as agreed_fee,
  m.discount,
  m.agreement_approved_by,
  m.agreement_approved_at,
  coalesce(sum(p.amount) filter(where p.voided_at is null),0) as valid_payment_total,
  count(p.id) filter(where p.voided_at is null) as valid_receipt_count,
  string_agg(distinct p.method, ', ' order by p.method) filter(where p.voided_at is null) as payment_methods,
  count(p.id) filter(where p.voided_at is not null) as voided_receipt_count
from public.students s
left join public.enrollments e on e.student_id=s.id
left join public.class_rooms c on c.id=e.class_id
left join public.teachers t on t.id=c.teacher_id
left join public.monthly_memberships m on m.enrollment_id=e.id
left join public.billing_periods b on b.id=m.period_id
left join public.payments p on p.monthly_membership_id=m.id
where s.student_code='RS-000056'
group by s.id,s.student_code,s.first_name,s.last_name,e.id,c.id,t.id,b.year_month,m.id
order by b.year_month nulls first,e.enrolled_on,e.id;

-- November source-row mappings/provenance for this existing student.
select
  b.source_filename as batch_source,
  c.id as candidate_id,
  c.source_key,
  c.source_sheet,
  c.source_row,
  c.status as review_status,
  c.identity_status,
  c.identity_student_id,
  c.student_id,
  c.enrollment_id,
  c.class_id,
  c.class_title as staged_class_name,
  c.teacher_name as staged_teacher_name,
  c.membership_id,
  c.approved_by,
  c.approved_at,
  d.destination_table,
  d.destination_id,
  d.mapping_status
from public.november_import_candidates c
join public.historical_import_batches b on b.id=c.batch_id
left join public.historical_import_destinations d on d.source_row_id=c.source_row_id
where c.source_sheet='Registrations'
  and coalesce(c.student_id,c.identity_student_id,c.approved_student_id) in (
    select id from public.students where student_code='RS-000056'
  )
  and c.source_month in ('Nov','November','2026-11','November 2026')
order by c.source_row,d.destination_table;

-- Period remains open; this is a status read only.
select year_month,status,closed_at,closed_by
from public.billing_periods
where year_month=date '2026-11-01';

rollback;
