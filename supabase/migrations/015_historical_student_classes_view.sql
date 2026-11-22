-- Read-only educational history for the Students page.
-- Historical rows remain monthly membership records; this view does not
-- create, update, or infer financial approvals or attendance.
begin;

create or replace view public.v_historical_student_classes
with (security_invoker = true)
as
select
  m.id,
  e.student_id,
  b.year_month,
  m.class_title_snapshot as class_name,
  t.full_name as teacher_name,
  m.start_time_snapshot as start_time,
  m.end_time_snapshot as end_time,
  coalesce(
    d.source_payload->>'Student Name',
    d.source_payload->>'Full Name',
    d.source_payload->>'Name',
    d.source_payload->>'Student'
  ) as source_student_name,
  case
    when coalesce(student_review.resolution->>'identity_confirmed', d.review_resolution->>'identity_confirmed') = 'true' then 'confirmed'
    else 'needs_review'
  end as identity_status
from public.monthly_memberships m
join public.billing_periods b on b.id = m.period_id
join public.enrollments e on e.id = m.enrollment_id
join public.teachers t on t.id = m.teacher_id
left join public.historical_import_destinations hd
  on hd.destination_table = 'monthly_memberships' and hd.destination_id = m.id
left join public.historical_import_source_rows d on d.id = hd.source_row_id
left join lateral (
  select s.review_resolution as resolution
  from public.historical_import_source_rows s
  join public.historical_import_destinations sd
    on sd.source_row_id = s.id and sd.destination_table = 'students'
  where d.id is not null
    and s.batch_id = d.batch_id
    and s.source_sheet = 'Students'
    and (
      sd.destination_id::text = d.review_resolution->>'student_id'
      or s.review_resolution->>'entity_key' = d.review_resolution->>'student_entity_key'
    )
  order by s.source_row
  limit 1
) student_review on true
where m.registration_type = 'legacy'
  and public.staff_has_any(array['admin']);

revoke all on public.v_historical_student_classes from public, anon;
grant select on public.v_historical_student_classes to authenticated;

commit;
