-- Keep educational registration state independent from tuition collection.
-- This migration changes only reporting functions/views; it does not rewrite rows.
begin;

create or replace function public.monthly_registration_summary(p_month date) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare result jsonb;
begin
  if not public.is_staff() then raise exception 'Staff access required'; end if;
  with registrations as (
    select m.*,e.student_id,e.class_id,c.active as class_active,t.active as teacher_active,
      case
        when f.amount_due <= 0 and f.discount > 0 then 'sponsored'
        when f.paid_total <= 0 then 'unpaid'
        when f.balance_due > 0 then 'partial'
        else 'paid'
      end as payment_status
    from public.monthly_memberships m
    join public.enrollments e on e.id=m.enrollment_id
    join public.class_rooms c on c.id=e.class_id
    join public.teachers t on t.id=m.teacher_id
    join public.billing_periods b on b.id=m.period_id
    join public.month_fee_overview f on f.id=m.id
    where b.year_month=p_month and m.registration_active
  )
  select jsonb_build_object(
    'registrations',count(*),'unique_students',count(distinct student_id),
    'active_classes',count(distinct class_id) filter(where class_active),
    'active_teachers',count(distinct teacher_id) filter(where teacher_active),
    'new_registrations',count(*) filter(where registration_type='new'),
    'returning_registrations',count(*) filter(where registration_type in ('returning','renewal')),
    'legacy_registrations',count(*) filter(where registration_type='legacy'),
    'unpaid_registrations',count(*) filter(where payment_status='unpaid'),
    'partial_registrations',count(*) filter(where payment_status='partial'),
    'paid_registrations',count(*) filter(where payment_status='paid'),
    'sponsored_registrations',count(*) filter(where payment_status='sponsored'),
    'by_class',coalesce((select jsonb_agg(g) from (
      select class_id,min(class_title_snapshot) class_name,count(*) registrations
      from registrations group by class_id
    ) g),'[]'::jsonb),
    'by_teacher',coalesce((select jsonb_agg(g) from (
      select r.teacher_id,t.full_name teacher_name,count(*) registrations
      from registrations r join public.teachers t on t.id=r.teacher_id
      group by r.teacher_id,t.full_name
    ) g),'[]'::jsonb)
  ) into result from registrations;
  return result;
end $$;

create or replace view public.month_tuition_summary with (security_invoker=true) as
select
  m.period_id,
  count(*) filter(where m.registration_active)::bigint as registrations,
  count(distinct e.student_id) filter(where m.registration_active)::bigint as unique_students,
  coalesce(sum(m.original_fee) filter(where m.registration_active), 0) as original_total,
  coalesce(sum(m.discount) filter(where m.registration_active), 0) as discounts_total,
  coalesce(sum(m.amount_due) filter(where m.registration_active), 0) as payable_total,
  -- Keep valid historical cash receipts visible even when their registration is inactive.
  -- Voided receipts remain in payment/audit history but are excluded from collected cash.
  coalesce(sum(coalesce(paid.paid_total,0)), 0) as received_total,
  coalesce(sum(m.amount_due-coalesce(paid.paid_total,0)) filter(where m.registration_active), 0) as outstanding_total,
  coalesce(sum(m.effective_teacher_entitlement) filter(where m.registration_active), 0) as teacher_total,
  coalesce(sum(m.effective_office_entitlement) filter(where m.registration_active), 0) as office_total,
  coalesce(sum(greatest(m.effective_teacher_entitlement-m.amount_due,0)) filter(where m.registration_active), 0) as institution_funded,
  count(*) filter(where m.registration_active
    and coalesce(paid.paid_total,0)<=0
    and not (m.sponsored_confirmed and m.amount_due=0 and m.discount=m.base_fee and m.base_fee>0))::bigint as pending_registrations
from public.monthly_memberships m
join public.enrollments e on e.id=m.enrollment_id
left join lateral (
  select sum(p.amount) as paid_total
  from public.payments p
  where p.monthly_membership_id=m.id and p.voided_at is null
) paid on true
group by m.period_id;

create or replace function public.monthly_registration_list(p_month date,p_student uuid default null) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not public.is_staff() then raise exception 'Staff access required'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',m.id,'registration_active',m.registration_active,'registered_on',m.registered_on,
      'registration_status',case when m.registration_active then 'registered' else 'cancelled' end,
      'payment_status',case when not m.registration_active then 'cancelled' else (
        select case
          when f.amount_due <= 0 and f.discount > 0 then 'sponsored'
          when f.paid_total <= 0 then 'unpaid'
          when f.balance_due > 0 then 'partial'
          else 'paid'
        end from public.month_fee_overview f where f.id=m.id
      ) end,
      -- Retain the legacy payment status key for callers that still use it.
      'confirmation_status',case when not m.registration_active then 'cancelled' else
        (select f.confirmation_status from public.month_fee_overview f where f.id=m.id) end,
      'registration_type',m.registration_type,'base_fee',m.base_fee,'original_fee',m.original_fee,
      'proration_rule',m.proration_rule,'discount',m.discount,
      'period',jsonb_build_object('year_month',b.year_month),
      'enrollment',jsonb_build_object('id',e.id,'student_id',e.student_id,'class_id',e.class_id,
        'student',jsonb_build_object('id',s.id,'student_code',s.student_code,
          'first_name',s.first_name,'last_name',s.last_name,'phone',s.phone),
        'class_item',jsonb_build_object('title',m.class_title_snapshot))
    ) order by m.registered_on desc,m.id)
    from public.monthly_memberships m
    join public.billing_periods b on b.id=m.period_id
    join public.enrollments e on e.id=m.enrollment_id
    join public.students s on s.id=e.student_id
    where (p_month is null or b.year_month=p_month) and (p_student is null or e.student_id=p_student)
  ),'[]'::jsonb);
end $$;

notify pgrst, 'reload schema';
commit;
