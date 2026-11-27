-- Read-only comparison aid. It does not move or change amounts.
-- Office expense candidates are selected by text matching; review descriptions manually
-- because historical office expenses were not explicitly linked to chapter IDs.
begin transaction read only;

with chapter_costs as (
  select date_trunc('month', printing_cost_on)::date as month,
         count(*) filter (where total_print_cost > 0) as chapter_rows,
         coalesce(sum(total_print_cost), 0) as historical_chapter_print_cost
  from public.chapters
  where total_print_cost > 0 and printing_cost_on is not null
  group by 1
), office_printing_candidates as (
  select date_trunc('month', spent_on)::date as month,
         count(*) as candidate_expense_rows,
         coalesce(sum(amount), 0) as candidate_office_printing_expenses,
         jsonb_agg(jsonb_build_object(
           'id', id, 'spent_on', spent_on, 'category', category,
           'description', description, 'amount', amount
         ) order by spent_on, id) as candidate_expense_details
  from public.expenses
  where voided_at is null
    and (coalesce(category, '') ilike '%print%'
      or coalesce(description, '') ilike '%print%'
      or coalesce(category, '') like '%چاپ%'
      or coalesce(description, '') like '%چاپ%')
  group by 1
), months as (
  select month from chapter_costs
  union
  select month from office_printing_candidates
)
select m.month,
       bp.status as billing_period_status,
       coalesce(c.chapter_rows, 0) as chapters_with_legacy_cost,
       coalesce(c.historical_chapter_print_cost, 0) as historical_chapter_print_cost,
       coalesce(e.candidate_expense_rows, 0) as candidate_office_expense_rows,
       coalesce(e.candidate_office_printing_expenses, 0) as candidate_office_printing_expenses,
       coalesce(c.historical_chapter_print_cost, 0)
         - coalesce(e.candidate_office_printing_expenses, 0) as amount_difference_for_review,
       coalesce(e.candidate_expense_details, '[]'::jsonb) as candidate_expense_details
from months m
left join chapter_costs c on c.month = m.month
left join office_printing_candidates e on e.month = m.month
left join public.billing_periods bp on bp.year_month = m.month
order by m.month;

rollback;
