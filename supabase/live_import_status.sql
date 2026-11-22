-- Run in the target Supabase SQL Editor to get exact counts before/after import.
-- Reads operational data only; the temporary result table is session-local.
create temporary table rsms_live_import_counts (
  item text primary key,
  row_count bigint,
  state text not null
);

do $$
declare
  table_name text;
  count_value bigint;
  table_names text[] := array[
    'students','teachers','class_rooms','enrollments','billing_periods',
    'monthly_memberships','payments','teacher_settlements','books','book_sales',
    'book_owner_settlements','chapters','chapter_sales','material_payments',
    'expenses','partners','partner_transactions','historical_import_batches',
    'historical_import_source_rows','historical_import_destinations',
    'historical_import_entities'
  ];
begin
  foreach table_name in array table_names loop
    if to_regclass(format('public.%I', table_name)) is null then
      insert into pg_temp.rsms_live_import_counts(item,row_count,state)
      values(table_name,null,'MISSING');
    else
      execute format('select count(*) from public.%I',table_name) into count_value;
      insert into pg_temp.rsms_live_import_counts(item,row_count,state)
      values(table_name,count_value,'PRESENT');
    end if;
  end loop;

  if to_regclass('public.monthly_memberships') is not null
    and to_regclass('public.billing_periods') is not null then
    insert into pg_temp.rsms_live_import_counts(item,row_count,state)
    select 'memberships:'||to_char(p.year_month,'YYYY-MM'),count(*),'PRESENT'
    from public.monthly_memberships m
    join public.billing_periods p on p.id=m.period_id
    group by p.year_month;
  end if;

  if to_regclass('public.payments') is not null then
    if exists(select 1 from information_schema.columns c
      where c.table_schema='public' and c.table_name='payments' and c.column_name='voided_at') then
      execute $q$
        insert into pg_temp.rsms_live_import_counts(item,row_count,state)
        select 'verified_tuition_payments',count(*) filter(where voided_at is null),'PRESENT'
        from public.payments
      $q$;
    else
      execute 'insert into pg_temp.rsms_live_import_counts(item,row_count,state) select ''verified_tuition_payments'',count(*),''PRESENT_NO_VOID_STATUS'' from public.payments';
    end if;
  end if;

  if to_regclass('public.expenses') is not null then
    if exists(select 1 from information_schema.columns c
      where c.table_schema='public' and c.table_name='expenses' and c.column_name='voided_at') then
      execute $q$
        insert into pg_temp.rsms_live_import_counts(item,row_count,state)
        select 'valid_expenses',count(*) filter(where voided_at is null),'PRESENT'
        from public.expenses
      $q$;
    else
      execute 'insert into pg_temp.rsms_live_import_counts(item,row_count,state) select ''valid_expenses'',count(*),''PRESENT_NO_VOID_STATUS'' from public.expenses';
    end if;
  end if;

  if to_regclass('public.historical_import_destinations') is not null then
    execute $q$
      insert into pg_temp.rsms_live_import_counts(item,row_count,state)
      select 'duplicate_records_excluded',count(*),'PRESENT'
      from public.historical_import_destinations
      where mapping_status='duplicate_excluded'
    $q$;
  end if;

  if to_regclass('public.historical_import_source_rows') is not null then
    execute $q$
      insert into pg_temp.rsms_live_import_counts(item,row_count,state)
      select 'import_rows:'||review_status,count(*),'PRESENT'
      from public.historical_import_source_rows
      group by review_status
    $q$;
    if exists(select 1 from information_schema.columns c
      where c.table_schema='public' and c.table_name='historical_import_source_rows'
        and c.column_name='posting_status') then
      execute $q$
        insert into pg_temp.rsms_live_import_counts(item,row_count,state)
        select 'import_posting:'||posting_status,count(*),'PRESENT'
        from public.historical_import_source_rows
        group by posting_status
      $q$;
    end if;
    if to_regclass('public.historical_import_destinations') is not null then
      execute $q$
        insert into pg_temp.rsms_live_import_counts(item,row_count,state)
        select 'financial_import_rows_pending_verification',count(*),'PRESENT'
        from public.historical_import_source_rows
        where source_sheet in ('Payments','Books','Chapters','Expenses','PartnerNotes')
          and posting_status='pending'
      $q$;
    end if;
  end if;
end $$;

select item,row_count,state
from pg_temp.rsms_live_import_counts
order by item;

drop table pg_temp.rsms_live_import_counts;
