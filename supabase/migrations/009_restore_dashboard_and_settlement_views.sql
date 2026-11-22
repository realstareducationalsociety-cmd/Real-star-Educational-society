begin;

do $$
begin
  if to_regclass('public.month_fee_overview') is null
    or to_regclass('public.teacher_class_month_totals') is null
    or to_regclass('public.historical_import_batches') is null
    or to_regclass('public.historical_import_source_rows') is null then
    raise exception 'Apply migrations 001 through 008 before migration 009';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='month_fee_overview' and column_name='original_fee'
  ) then
    raise exception 'Migration 008 is required before rebuilding dashboard views';
  end if;
end $$;

create or replace view public.month_tuition_summary
with (security_invoker=true) as
select period_id,
  count(*)::bigint as registrations,
  count(distinct student_id)::bigint as unique_students,
  coalesce(sum(original_fee),0) as original_total,
  coalesce(sum(discount),0) as discounts_total,
  coalesce(sum(amount_due),0) as payable_total,
  coalesce(sum(paid_total),0) as received_total,
  coalesce(sum(balance_due),0) as outstanding_total,
  coalesce(sum(teacher_entitlement),0) as teacher_total,
  coalesce(sum(center_entitlement),0) as office_total
from public.month_fee_overview
group by period_id;

create or replace view public.teacher_settlement_summary
with (security_invoker=true) as
select t.period_id,t.class_id,t.class_name,t.teacher_id,t.teacher_name,t.student_count,
  t.base_total,t.discounts_total,t.teacher_entitlement,t.center_entitlement,
  t.received_total,t.settled_total,
  (t.teacher_entitlement-t.settled_total) as remaining_settlement,
  case
    when t.teacher_entitlement=t.settled_total then 'settled'
    when t.settled_total>0 then 'partial'
    else 'unpaid'
  end as settlement_status
from public.teacher_class_month_totals t;

grant select on public.month_tuition_summary,public.teacher_settlement_summary to authenticated;

commit;
