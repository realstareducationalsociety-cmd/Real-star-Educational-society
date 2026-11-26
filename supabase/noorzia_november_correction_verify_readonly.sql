-- READ ONLY verification for the Noorzia November 2026 class correction.
-- Run after applying the approved migrations and executing the correction RPC.
-- This script performs SELECT statements only.

-- 1. Show every November membership for the student, its class/teacher,
--    registration state, approved fees, and currently valid receipt totals.
select
  s.student_code,
  concat_ws(' ',s.first_name,s.last_name) as student_name,
  bp.year_month,
  c.title as class_name,
  t.full_name as teacher_name,
  m.id as membership_id,
  m.registration_active,
  m.base_fee,
  m.discount,
  m.amount_due,
  coalesce(sum(p.amount) filter(where p.voided_at is null),0)::numeric(12,2) as valid_paid,
  array_agg(p.id order by p.paid_on,p.id) filter(where p.voided_at is null) as valid_receipt_ids,
  array_agg(p.paid_on order by p.paid_on,p.id) filter(where p.voided_at is null) as valid_receipt_dates
from public.students s
join public.enrollments e on e.student_id=s.id
join public.class_rooms c on c.id=e.class_id
join public.teachers t on t.id=c.teacher_id
join public.monthly_memberships m on m.enrollment_id=e.id
join public.billing_periods bp on bp.id=m.period_id
left join public.payments p on p.monthly_membership_id=m.id
where s.student_code='RS-000056' and bp.year_month=date '2026-11-01'
group by s.student_code,s.first_name,s.last_name,bp.year_month,c.title,t.full_name,m.id,
  m.registration_active,m.base_fee,m.discount,m.amount_due
order by c.title,m.id;

-- 2. Show the correction audit event and its approval actor.
select id,created_at,actor_id,approved_by,reason,old_data,new_data
from public.audit_logs
join public.enrollments e on e.id::text=old_data->>'enrollment_id'
join public.students s on s.id=e.student_id
where table_name='monthly_memberships'
  and action='CORRECT_NOVEMBER_CLASS'
  and s.student_code='RS-000056'
order by created_at desc,id desc;

-- 3. Confirm that the original receipt rows remain valid and retain their IDs,
--    dates and amounts while their membership link now points to Grade 3.
select p.id,p.monthly_membership_id,p.amount,p.paid_on,p.method,p.reference_note,
       p.voided_at,p.void_reason,m.class_title_snapshot
from public.payments p
join public.monthly_memberships m on m.id=p.monthly_membership_id
join public.enrollments e on e.id=m.enrollment_id
join public.students s on s.id=e.student_id
join public.billing_periods bp on bp.id=m.period_id
where s.student_code='RS-000056' and bp.year_month=date '2026-11-01'
order by p.paid_on,p.id;
