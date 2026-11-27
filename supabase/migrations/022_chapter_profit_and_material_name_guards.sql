-- Chapter cash belongs to common partner profit; books stay in a separate ledger.
-- Printing is not entered in the chapter form and is deducted only as an office expense.
begin;

-- Canonicalize common Arabic/Persian variants while retaining word boundaries.
create or replace function public.normalize_material_name(p_text text) returns text
language sql immutable parallel safe set search_path=public,pg_temp as $$
  select btrim(regexp_replace(translate(lower(normalize(coalesce(p_text,''), NFKC)),
    chr(1610)||chr(1609)||chr(1603)||chr(1571)||chr(1573)||chr(1570)||chr(1577)||chr(1572)||chr(1574)||chr(1649)||chr(1569),
    chr(1740)||chr(1740)||chr(1705)||chr(1575)||chr(1575)||chr(1575)||chr(1607)||chr(1608)||chr(1610)||chr(1575)||chr(1575)),
    '[[:space:]'||chr(8204)||chr(1600)||chr(1611)||'-'||chr(1619)||chr(1648)||chr(1620)||chr(1621)||']+', ' ', 'g'))
$$;
revoke all on function public.normalize_material_name(text) from public,anon,authenticated;
grant execute on function public.normalize_material_name(text) to authenticated;

create or replace function public.guard_unique_material_name() returns trigger
language plpgsql set search_path=public,pg_temp as $$
declare v_key text; v_duplicate boolean;
begin
  if nullif(trim(new.title),'') is null then raise exception 'Material name is required'; end if;
  if tg_table_name='books' then
    if nullif(trim(new.owner_name),'') is null then raise exception 'Book owner is required'; end if;
    if tg_op='UPDATE' and public.normalize_material_name(new.title)=public.normalize_material_name(old.title)
       and public.normalize_material_name(new.owner_name)=public.normalize_material_name(old.owner_name) then return new; end if;
    v_key := 'book|'||public.normalize_material_name(new.title)||'|'||public.normalize_material_name(new.owner_name);
    perform pg_advisory_xact_lock(hashtextextended(v_key,0));
    select exists(select 1 from public.books b where b.id is distinct from new.id
      and public.normalize_material_name(b.title)=public.normalize_material_name(new.title)
      and public.normalize_material_name(b.owner_name)=public.normalize_material_name(new.owner_name)) into v_duplicate;
  else
    if tg_op='UPDATE' and public.normalize_material_name(new.title)=public.normalize_material_name(old.title)
       and new.class_id is not distinct from old.class_id then return new; end if;
    v_key := 'chapter|'||coalesce(new.class_id::text,'')||'|'||public.normalize_material_name(new.title);
    perform pg_advisory_xact_lock(hashtextextended(v_key,0));
    select exists(select 1 from public.chapters c where c.id is distinct from new.id
      and c.class_id is not distinct from new.class_id
      and public.normalize_material_name(c.title)=public.normalize_material_name(new.title)) into v_duplicate;
  end if;
  if v_duplicate then raise exception 'A material with the same normalized name already exists'; end if;
  return new;
end $$;

drop trigger if exists guard_unique_material_name on public.books;
drop trigger if exists guard_unique_material_name on public.chapters;
create trigger guard_unique_material_name before insert or update of title,owner_name on public.books
  for each row execute function public.guard_unique_material_name();
create trigger guard_unique_material_name before insert or update of title,class_id on public.chapters
  for each row execute function public.guard_unique_material_name();

-- Keep legacy chapter costs readable, but freeze their values and reject new costs.
create or replace function public.guard_legacy_chapter_print_cost() returns trigger
language plpgsql set search_path=public,pg_temp as $$
begin
  if tg_op='INSERT' and coalesce(new.total_print_cost,0)<>0 then
    raise exception 'Record new printing costs in office expenses; chapter printing cost is legacy-only';
  elsif tg_op='UPDATE' and (new.total_print_cost is distinct from old.total_print_cost
      or (coalesce(old.total_print_cost,0)>0 and new.printing_cost_on is distinct from old.printing_cost_on)) then
    raise exception 'Historical chapter printing costs and dates are read-only; record new costs in office expenses';
  end if;
  return new;
end $$;
drop trigger if exists guard_legacy_chapter_print_cost on public.chapters;
create trigger guard_legacy_chapter_print_cost before insert or update of total_print_cost,printing_cost_on on public.chapters
  for each row execute function public.guard_legacy_chapter_print_cost();

-- Book-specific expenses stay outside the office expense and partner ledgers.
create table if not exists public.book_expenses (
  id uuid primary key default gen_random_uuid(),
  category text not null,
  description text not null,
  amount numeric(12,2) not null check(amount>0),
  spent_on date not null default ((now() at time zone 'Asia/Karachi')::date),
  request_id uuid not null unique,
  entered_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  voided_at timestamptz,
  void_reason text
);
alter table public.book_expenses enable row level security;
drop policy if exists book_expenses_finance_read on public.book_expenses;
create policy book_expenses_finance_read on public.book_expenses for select to authenticated
  using (public.staff_has_any(array['admin','accountant']));
revoke all on public.book_expenses from public,anon,authenticated;
grant select on public.book_expenses to authenticated;
drop trigger if exists audit_book_expenses on public.book_expenses;
create trigger audit_book_expenses after insert or update on public.book_expenses
  for each row execute function public.audit_record();

create or replace function public.record_book_expense(p_category text,p_description text,p_amount numeric,p_spent_on date,p_request uuid)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare result uuid; existing public.book_expenses%rowtype;
begin
  if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required' using errcode='42501'; end if;
  if nullif(trim(p_category),'') is null or nullif(trim(p_description),'') is null or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_spent_on is null or p_request is null then
    raise exception 'Valid category, description, amount, date and request ID are required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('book-expense-'||p_request::text,0));
  select * into existing from public.book_expenses where request_id=p_request;
  if found then
    if existing.category is distinct from trim(p_category)
       or existing.description is distinct from trim(p_description)
       or existing.amount is distinct from p_amount
       or existing.spent_on is distinct from p_spent_on then
      raise exception 'Request ID already used with different book expense details';
    end if;
    return existing.id;
  end if;
  perform public.lock_open_months(array[p_spent_on]);
  insert into public.book_expenses(category,description,amount,spent_on,request_id,entered_by)
  values(trim(p_category),trim(p_description),p_amount,p_spent_on,p_request,auth.uid()) returning id into result;
  return result;
end $$;

create or replace function public.void_book_expense(p_id uuid,p_reason text) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
declare expense_row public.book_expenses%rowtype;
begin
  if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required' using errcode='42501'; end if;
  if length(trim(coalesce(p_reason,'')))<4 then raise exception 'Reason required'; end if;
  select * into expense_row from public.book_expenses where id=p_id for update;
  if not found then raise exception 'Book expense not found'; end if;
  if expense_row.voided_at is not null then raise exception 'Book expense already voided'; end if;
  perform public.lock_open_months(array[expense_row.spent_on]);
  update public.book_expenses set voided_at=now(),void_reason=trim(p_reason) where id=p_id and voided_at is null;
end $$;
revoke all on function public.record_book_expense(text,text,numeric,date,uuid),public.void_book_expense(uuid,text) from public,anon,authenticated;
grant execute on function public.record_book_expense(text,text,numeric,date,uuid),public.void_book_expense(uuid,text) to authenticated;

create or replace function public.independent_book_summary() returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
  return jsonb_build_object(
    'total_sales',(select coalesce(sum(quantity*unit_price),0) from public.book_sales),
    'collected',(select coalesce(sum(amount),0) from public.material_payments where book_sale_id is not null and voided_at is null),
    'outstanding',(select coalesce(sum(quantity*unit_price-paid_total),0) from public.book_sales),
    'expenses',(select coalesce(sum(amount),0) from public.book_expenses where voided_at is null),
    'owners',coalesce((select jsonb_agg(o) from (
      select owner_name_snapshot owner_name,sum(paid_total) collected,
        coalesce((select sum(amount) from public.book_owner_settlements x where x.owner_name=s.owner_name_snapshot and x.voided_at is null),0) paid_to_owner,
        sum(paid_total)-coalesce((select sum(amount) from public.book_owner_settlements x where x.owner_name=s.owner_name_snapshot and x.voided_at is null),0) held_for_owner
      from public.book_sales s group by owner_name_snapshot) o),'[]'::jsonb));
end $$;

create or replace function public.office_month_summary(p_month date) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  finish date:=(p_month+interval '1 month')::date;
  tuition numeric; chapters numeric; legacy_printing numeric; costs numeric; entitlement numeric;
  office_entitlement numeric; settled numeric; outstanding numeric; institution_funded numeric;
begin
  if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
  select coalesce(sum(amount),0) into tuition from public.payments
    where voided_at is null and paid_on>=p_month and paid_on<finish;
  select coalesce(sum(amount),0) into chapters from public.material_payments
    where chapter_sale_id is not null and voided_at is null and paid_on>=p_month and paid_on<finish;
  select coalesce(sum(total_print_cost),0) into legacy_printing from public.chapters
    where printing_cost_on>=p_month and printing_cost_on<finish;
  select coalesce(sum(amount),0) into costs from public.expenses
    where voided_at is null and spent_on>=p_month and spent_on<finish;
  select coalesce(sum(m.effective_teacher_entitlement),0) into entitlement
    from public.monthly_memberships m join public.billing_periods b on b.id=m.period_id
    where b.year_month=p_month and m.registration_active;
  select coalesce(sum(m.effective_office_entitlement),0) into office_entitlement
    from public.monthly_memberships m join public.billing_periods b on b.id=m.period_id
    where b.year_month=p_month and m.registration_active;
  select coalesce(sum(amount),0) into settled from public.teacher_settlements
    where voided_at is null and paid_on>=p_month and paid_on<finish;
  select coalesce(sum(quantity*unit_price-paid_total),0) into outstanding from public.chapter_sales
    where sold_on>=p_month and sold_on<finish;
  select coalesce(sum(greatest(m.effective_teacher_entitlement-m.amount_due,0)),0) into institution_funded
    from public.monthly_memberships m join public.billing_periods b on b.id=m.period_id
    where b.year_month=p_month and m.registration_active;
  return jsonb_build_object(
    'tuition_collected',tuition,'chapter_collected',chapters,'chapter_outstanding',outstanding,
    -- Retained for old deployed dashboards; it is informational and is not subtracted below.
    'chapter_printing',legacy_printing,'chapter_net',chapters-legacy_printing,
    'gross_collected',tuition+chapters,
    'teacher_entitlement',entitlement,'office_entitlement',office_entitlement,'teacher_paid',settled,
    'expenses',costs,'institution_funded',institution_funded,
    'net_after_entitlement',tuition+chapters-entitlement-costs,
    'cash_after_payments',tuition+chapters-settled-costs
  );
end $$;
revoke all on function public.office_month_summary(date) from public,anon;
grant execute on function public.office_month_summary(date) to authenticated;

create or replace function public.distributable_reserve() returns numeric
language sql stable security definer set search_path=public,pg_temp as $$
  select
    (select coalesce(sum(amount),0) from public.payments where voided_at is null)
    +(select coalesce(sum(amount),0) from public.material_payments where chapter_sale_id is not null and voided_at is null)
    -(select coalesce(sum(effective_teacher_entitlement),0) from public.monthly_memberships where registration_active)
    -(select coalesce(sum(amount),0) from public.expenses where voided_at is null)
    -(select coalesce(sum(amount),0) from public.partner_transactions where kind in ('withdrawal','profit_distribution') and voided_at is null)
$$;
revoke all on function public.distributable_reserve() from public,anon,authenticated;

notify pgrst,'reload schema';
commit;
