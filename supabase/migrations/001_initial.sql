-- Real Star Management System v0.1
-- Run once in a NEW Supabase project with SQL Editor (as postgres).
-- Currency: PKR. Teachers: 50% of BASE fee unless documented agreed reduction.
-- This migration creates tables; it DOES NOT import real students or create user accounts.

create extension if not exists pgcrypto;
create type public.staff_role as enum ('admin','accountant','registrar');

create table public.staff_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  role public.staff_role not null default 'registrar',
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.staff_profiles where id = (select auth.uid()) and is_active)
$$;
create or replace function public.staff_has_any(allowed text[])
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.staff_profiles
    where id = (select auth.uid()) and is_active and role::text = any(allowed))
$$;

create sequence public.student_number_seq start 1;
create table public.students (
  id uuid primary key default gen_random_uuid(),
  student_code text not null unique default ('RS-' || lpad(nextval('public.student_number_seq')::text, 6, '0')),
  first_name text not null check (length(trim(first_name)) > 0),
  last_name text not null default '',
  guardian_name text,
  phone text,
  guardian_phone text,
  address text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.teachers (
  id uuid primary key default gen_random_uuid(),
  full_name text not null check (length(trim(full_name)) > 0),
  phone text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.class_rooms (
  id uuid primary key default gen_random_uuid(),
  title text not null check(length(trim(title)) > 0),
  teacher_id uuid not null references public.teachers(id),
  default_fee numeric(12,2) not null default 0 check(default_fee >= 0),
  start_time time,
  end_time time,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.enrollments (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id),
  class_id uuid not null references public.class_rooms(id),
  enrolled_on date not null default ((now() at time zone 'Asia/Karachi')::date),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(student_id, class_id)
);

create table public.billing_periods (
  id uuid primary key default gen_random_uuid(),
  year_month date not null unique check(extract(day from year_month)=1),
  status text not null default 'open' check(status in ('open','locked')),
  created_at timestamptz not null default now()
);

create table public.monthly_memberships (
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null references public.billing_periods(id),
  enrollment_id uuid not null references public.enrollments(id),
  teacher_id uuid not null references public.teachers(id), -- frozen teacher for this month
  class_title_snapshot text not null, -- prevents later class renaming changing monthly history
  base_fee numeric(12,2) not null check(base_fee >= 0),
  discount numeric(12,2) not null default 0 check(discount >= 0),
  teacher_discount_share numeric(12,2) not null default 0 check(teacher_discount_share >= 0),
  notes text,
  amount_due numeric(12,2) generated always as (base_fee - discount) stored,
  teacher_entitlement numeric(12,2) generated always as (round(base_fee * 0.50 - teacher_discount_share,2)) stored,
  center_entitlement numeric(12,2) generated always as (round(base_fee * 0.50 - discount + teacher_discount_share,2)) stored,
  created_at timestamptz not null default now(),
  unique(period_id, enrollment_id),
  check(discount <= base_fee),
  check(teacher_discount_share <= discount),
  check(teacher_discount_share <= base_fee * 0.50)
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  monthly_membership_id uuid not null references public.monthly_memberships(id),
  amount numeric(12,2) not null check(amount > 0),
  paid_on date not null default ((now() at time zone 'Asia/Karachi')::date),
  method text not null default 'cash' check(method in ('cash','bank','other')),
  reference_note text,
  received_by uuid references auth.users(id),
  voided_at timestamptz,
  void_reason text,
  created_at timestamptz not null default now()
);

create table public.teacher_settlements (
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null references public.billing_periods(id),
  class_id uuid not null references public.class_rooms(id),
  teacher_id uuid not null references public.teachers(id),
  amount numeric(12,2) not null check(amount > 0),
  paid_on date not null default ((now() at time zone 'Asia/Karachi')::date),
  note text,
  paid_by uuid references auth.users(id),
  voided_at timestamptz,
  void_reason text,
  created_at timestamptz not null default now()
);

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  category text not null,
  description text not null,
  amount numeric(12,2) not null check(amount > 0),
  spent_on date not null default ((now() at time zone 'Asia/Karachi')::date),
  entered_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

-- Partners: three equally owned shares. A share does not imply profits are ready to distribute.
create table public.partners (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  ownership_units integer not null default 1 check(ownership_units > 0),
  created_at timestamptz not null default now()
);
create table public.partner_transactions (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.partners(id),
  kind text not null check(kind in ('capital','withdrawal','profit_distribution')),
  amount numeric(12,2) not null check(amount > 0),
  transacted_on date not null default ((now() at time zone 'Asia/Karachi')::date),
  description text,
  created_at timestamptz not null default now()
);

-- Consigned books: sale proceeds are liabilities to the outside owner except agreed commission.
create table public.books (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  owner_name text not null,
  opening_stock integer not null default 0 check(opening_stock >= 0),
  sale_price numeric(12,2) not null default 0 check(sale_price >= 0),
  commission_per_book numeric(12,2) not null default 0 check(commission_per_book >= 0),
  created_at timestamptz not null default now(),
  check(commission_per_book <= sale_price)
);
create table public.book_sales (
  id uuid primary key default gen_random_uuid(),
  book_id uuid not null references public.books(id),
  quantity integer not null check(quantity > 0),
  unit_price numeric(12,2) not null check(unit_price >= 0),
  unit_commission numeric(12,2) not null check(unit_commission >= 0),
  sold_on date not null default ((now() at time zone 'Asia/Karachi')::date),
  check(unit_commission <= unit_price)
);
create table public.book_owner_settlements (
  id uuid primary key default gen_random_uuid(),
  owner_name text not null,
  amount numeric(12,2) not null check(amount > 0),
  paid_on date not null default ((now() at time zone 'Asia/Karachi')::date),
  note text
);

-- Chapter printing and sales are separate from book-owner proceeds and tuition.
create table public.chapters (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  produced_quantity integer not null default 0 check(produced_quantity >= 0),
  total_print_cost numeric(12,2) not null default 0 check(total_print_cost >= 0),
  default_sale_price numeric(12,2) not null default 0 check(default_sale_price >= 0),
  created_at timestamptz not null default now()
);
create table public.chapter_sales (
  id uuid primary key default gen_random_uuid(),
  chapter_id uuid not null references public.chapters(id),
  quantity integer not null check(quantity > 0),
  unit_price numeric(12,2) not null check(unit_price >= 0),
  sold_on date not null default ((now() at time zone 'Asia/Karachi')::date)
);

create table public.audit_logs (
  id bigint generated always as identity primary key,
  table_name text not null,
  action text not null,
  row_id text,
  actor_id uuid,
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz not null default now()
);

create or replace function public.audit_record() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_id text;
begin
  if tg_op='INSERT' then v_id:=new.id::text;
  elsif tg_op='UPDATE' then v_id:=new.id::text;
  else v_id:=old.id::text; end if;
  insert into public.audit_logs(table_name,action,row_id,actor_id,old_data,new_data)
  values (tg_table_name,tg_op,v_id,auth.uid(),
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end);
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

create or replace function public.guard_membership_change() returns trigger
language plpgsql security definer set search_path=public as $$
declare month_status text; amount_received numeric; paid_out numeric;
begin
  select status into month_status from public.billing_periods
    where id=new.period_id for update;
  if month_status <> 'open' then raise exception 'این ماه بسته شده است'; end if;
  if tg_op='UPDATE' then
    if old.enrollment_id <> new.enrollment_id or old.period_id <> new.period_id
      or old.teacher_id <> new.teacher_id or old.class_title_snapshot <> new.class_title_snapshot then
      raise exception 'مشخصات ارتباط ماه را نمی‌توان تغییر داد';
    end if;
    select coalesce(sum(amount),0) into amount_received from public.payments
      where monthly_membership_id = new.id and voided_at is null;
    if amount_received > new.base_fee-new.discount then
      raise exception 'مبلغ جدید کمتر از پرداخت‌های ثبت‌شده است';
    end if;
    if old.base_fee <> new.base_fee or old.discount <> new.discount
       or old.teacher_discount_share <> new.teacher_discount_share then
      select coalesce(sum(ts.amount),0) into paid_out from public.teacher_settlements ts
        join public.enrollments e on e.class_id=ts.class_id
        where e.id=new.enrollment_id and ts.period_id=new.period_id
          and ts.teacher_id=new.teacher_id and ts.voided_at is null;
      if paid_out > 0 then
        raise exception 'پس از تصفیه استاد، ابتدا اسناد مالی را بررسی کنید';
      end if;
    end if;
  end if;
  return new;
end $$;
create trigger guard_membership before insert or update on public.monthly_memberships
for each row execute function public.guard_membership_change();

create or replace function public.guard_payment_insert() returns trigger
language plpgsql security definer set search_path=public as $$
declare due numeric; received numeric; month_status text;
begin
  select m.amount_due,p.status into due,month_status from public.monthly_memberships m
    join public.billing_periods p on p.id=m.period_id
    where m.id=new.monthly_membership_id for update of m;
  if due is null or month_status <> 'open' then raise exception 'حساب ماه موجود یا باز نیست'; end if;
  select coalesce(sum(amount),0) into received from public.payments
    where monthly_membership_id=new.monthly_membership_id and voided_at is null;
  if received+new.amount > due then raise exception 'مبلغ پرداخت از باقی‌داری بیشتر است'; end if;
  new.received_by=auth.uid();
  return new;
end $$;
create trigger guard_payment before insert on public.payments
for each row execute function public.guard_payment_insert();

create or replace function public.void_payment(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not public.staff_has_any(array['admin','accountant']) then raise exception 'اجازه ندارید'; end if;
  if length(trim(coalesce(p_reason,''))) < 4 then raise exception 'دلیل اصلاح را بنویسید'; end if;
  if exists (select 1 from public.payments x
      join public.monthly_memberships m on m.id=x.monthly_membership_id
      join public.billing_periods b on b.id=m.period_id
      where x.id=p_id and b.status='locked') then raise exception 'ماه بسته شده است'; end if;
  update public.payments set voided_at=now(),void_reason=p_reason
    where id=p_id and voided_at is null;
  if not found then raise exception 'پرداخت پیدا نشد یا قبلاً باطل شده است'; end if;
end $$;

create or replace function public.guard_settlement_insert() returns trigger
language plpgsql security definer set search_path=public as $$
declare available numeric; already_paid numeric; month_status text;
begin
  select status into month_status from public.billing_periods where id=new.period_id for update;
  if month_status <> 'open' then raise exception 'ماه بسته شده است'; end if;
  select coalesce(sum(m.teacher_entitlement),0) into available
    from public.monthly_memberships m
    join public.enrollments e on e.id=m.enrollment_id
    where m.period_id=new.period_id and e.class_id=new.class_id and m.teacher_id=new.teacher_id;
  select coalesce(sum(amount),0) into already_paid
    from public.teacher_settlements
    where period_id=new.period_id and class_id=new.class_id and teacher_id=new.teacher_id and voided_at is null;
  if new.amount + already_paid > available then raise exception 'تصفیه بیشتر از سهم استاد است'; end if;
  new.paid_by=auth.uid();
  return new;
end $$;
create trigger guard_settlement before insert on public.teacher_settlements
for each row execute function public.guard_settlement_insert();

create or replace function public.void_teacher_settlement(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not public.staff_has_any(array['admin','accountant']) then raise exception 'اجازه ندارید'; end if;
  if length(trim(coalesce(p_reason,''))) < 4 then raise exception 'دلیل اصلاح را بنویسید'; end if;
  if exists (select 1 from public.teacher_settlements x
      join public.billing_periods b on b.id=x.period_id
      where x.id=p_id and b.status='locked') then raise exception 'ماه بسته شده است'; end if;
  update public.teacher_settlements set voided_at=now(),void_reason=p_reason where id=p_id and voided_at is null;
  if not found then raise exception 'تصفیه پیدا نشد یا قبلاً باطل شده است'; end if;
end $$;

create or replace function public.ensure_billing_month(p_month date) returns integer
language plpgsql security definer set search_path=public as $$
declare period uuid; added integer;
begin
  if not public.staff_has_any(array['admin','accountant']) then raise exception 'اجازه مالی ندارید'; end if;
  if extract(day from p_month) <> 1 then raise exception 'تاریخ باید روز اول ماه باشد'; end if;
  insert into public.billing_periods(year_month) values(p_month)
    on conflict(year_month) do nothing;
  select id into period from public.billing_periods where year_month=p_month and status='open';
  if period is null then raise exception 'این ماه بسته است'; end if;
  insert into public.monthly_memberships(period_id,enrollment_id,teacher_id,class_title_snapshot,base_fee)
  select period,e.id,c.teacher_id,c.title,c.default_fee
  from public.enrollments e join public.class_rooms c on c.id=e.class_id
  join public.students s on s.id=e.student_id
  where e.active and c.active and s.active and e.enrolled_on <= (p_month + interval '1 month - 1 day')::date
  on conflict(period_id,enrollment_id) do nothing;
  get diagnostics added = row_count;
  return added;
end $$;

-- When a registrar registers a student into a class, add to OPEN current month automatically.
create or replace function public.current_month_enrollment() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.active then
    insert into public.monthly_memberships(period_id,enrollment_id,teacher_id,class_title_snapshot,base_fee)
    select p.id,new.id,c.teacher_id,c.title,c.default_fee
    from public.billing_periods p join public.class_rooms c on c.id=new.class_id
    where p.year_month = date_trunc('month', (now() at time zone 'Asia/Karachi'))::date and p.status='open'
      and c.active and new.enrolled_on <= (now() at time zone 'Asia/Karachi')::date
    on conflict(period_id,enrollment_id) do nothing;
  end if;
  return new;
end $$;
create trigger enrollment_month_sync after insert or update of active on public.enrollments
for each row execute function public.current_month_enrollment();

-- Reports. SECURITY INVOKER: underlying RLS still applies to these views.
create view public.month_fee_overview with (security_invoker=true) as
select m.id,m.period_id,m.enrollment_id,e.student_id,s.student_code,
  concat_ws(' ',s.first_name,s.last_name) as student_name,
  e.class_id,m.class_title_snapshot as class_name,m.teacher_id,t.full_name as teacher_name,
  m.base_fee,m.discount,m.teacher_discount_share,m.amount_due,
  m.teacher_entitlement,m.center_entitlement,m.notes,
  coalesce(paid.paid_total,0)::numeric(12,2) as paid_total,
  (m.amount_due-coalesce(paid.paid_total,0))::numeric(12,2) as balance_due
from public.monthly_memberships m
join public.enrollments e on e.id=m.enrollment_id
join public.students s on s.id=e.student_id
join public.class_rooms c on c.id=e.class_id
join public.teachers t on t.id=m.teacher_id
left join lateral (
  select sum(amount) as paid_total from public.payments
  where monthly_membership_id=m.id and voided_at is null
) paid on true;

create view public.teacher_class_month_totals with (security_invoker=true) as
select m.period_id,e.class_id,m.class_title_snapshot as class_name,m.teacher_id,t.full_name as teacher_name,
  count(*)::integer as student_count,
  coalesce(sum(m.base_fee),0)::numeric(12,2) as base_total,
  coalesce(sum(m.discount),0)::numeric(12,2) as discounts_total,
  coalesce(sum(m.teacher_entitlement),0)::numeric(12,2) as teacher_entitlement,
  coalesce(sum(m.center_entitlement),0)::numeric(12,2) as center_entitlement,
  coalesce(sum(f.paid_total),0)::numeric(12,2) as received_total,
  coalesce((select sum(amount) from public.teacher_settlements ts
    where ts.period_id=m.period_id and ts.class_id=e.class_id
      and ts.teacher_id=m.teacher_id and ts.voided_at is null),0)::numeric(12,2) as settled_total
from public.monthly_memberships m
join public.enrollments e on e.id=m.enrollment_id
join public.class_rooms c on c.id=e.class_id
join public.teachers t on t.id=m.teacher_id
join public.month_fee_overview f on f.id=m.id
group by m.period_id,e.class_id,m.class_title_snapshot,m.teacher_id,t.full_name;

-- Audit every financial change and important enrollment changes.
create trigger audit_monthly after insert or update on public.monthly_memberships
  for each row execute function public.audit_record();
create trigger audit_payments after insert or update on public.payments
  for each row execute function public.audit_record();
create trigger audit_teacher_settlements after insert or update on public.teacher_settlements
  for each row execute function public.audit_record();
create trigger audit_expenses after insert or update on public.expenses
  for each row execute function public.audit_record();
create trigger audit_enrollments after insert or update on public.enrollments
  for each row execute function public.audit_record();
create trigger audit_partner_transactions after insert or update on public.partner_transactions
  for each row execute function public.audit_record();
create trigger audit_book_sales after insert or update on public.book_sales
  for each row execute function public.audit_record();
create trigger audit_chapter_sales after insert or update on public.chapter_sales
  for each row execute function public.audit_record();

create index on public.enrollments(class_id,active);
create index on public.enrollments(student_id);
create index on public.monthly_memberships(period_id);
create index on public.monthly_memberships(teacher_id);
create index on public.payments(monthly_membership_id) where voided_at is null;
create index on public.teacher_settlements(period_id,class_id,teacher_id) where voided_at is null;

-- Access: all tables have RLS. No anonymous access or direct deletion.
alter table public.staff_profiles enable row level security;
alter table public.students enable row level security;
alter table public.teachers enable row level security;
alter table public.class_rooms enable row level security;
alter table public.enrollments enable row level security;
alter table public.billing_periods enable row level security;
alter table public.monthly_memberships enable row level security;
alter table public.payments enable row level security;
alter table public.teacher_settlements enable row level security;
alter table public.expenses enable row level security;
alter table public.partners enable row level security;
alter table public.partner_transactions enable row level security;
alter table public.books enable row level security;
alter table public.book_sales enable row level security;
alter table public.book_owner_settlements enable row level security;
alter table public.chapters enable row level security;
alter table public.chapter_sales enable row level security;
alter table public.audit_logs enable row level security;

create policy staff_self_read on public.staff_profiles for select to authenticated using(id=auth.uid() or public.staff_has_any(array['admin']));
create policy staff_admin_insert on public.staff_profiles for insert to authenticated with check(public.staff_has_any(array['admin']));
create policy staff_admin_update on public.staff_profiles for update to authenticated using(public.staff_has_any(array['admin'])) with check(public.staff_has_any(array['admin']));

create policy students_read on public.students for select to authenticated using(public.is_staff());
create policy students_write on public.students for insert to authenticated with check(public.staff_has_any(array['admin','registrar']));
create policy students_update on public.students for update to authenticated using(public.staff_has_any(array['admin','registrar'])) with check(public.staff_has_any(array['admin','registrar']));
create policy teachers_read on public.teachers for select to authenticated using(public.is_staff());
create policy teachers_write on public.teachers for insert to authenticated with check(public.staff_has_any(array['admin','registrar']));
create policy teachers_update on public.teachers for update to authenticated using(public.staff_has_any(array['admin','registrar'])) with check(public.staff_has_any(array['admin','registrar']));
create policy classes_read on public.class_rooms for select to authenticated using(public.is_staff());
create policy classes_write on public.class_rooms for insert to authenticated with check(public.staff_has_any(array['admin','registrar']));
create policy classes_update on public.class_rooms for update to authenticated using(public.staff_has_any(array['admin','registrar'])) with check(public.staff_has_any(array['admin','registrar']));
create policy enrollment_read on public.enrollments for select to authenticated using(public.is_staff());
create policy enrollment_write on public.enrollments for insert to authenticated with check(public.staff_has_any(array['admin','registrar']));
create policy enrollment_update on public.enrollments for update to authenticated using(public.staff_has_any(array['admin','registrar'])) with check(public.staff_has_any(array['admin','registrar']));

create policy periods_read on public.billing_periods for select to authenticated using(public.is_staff());
create policy periods_write on public.billing_periods for insert to authenticated with check(public.staff_has_any(array['admin','accountant']));
create policy periods_update on public.billing_periods for update to authenticated using(public.staff_has_any(array['admin'])) with check(public.staff_has_any(array['admin']));
create policy monthly_read on public.monthly_memberships for select to authenticated using(public.is_staff());
create policy monthly_write on public.monthly_memberships for insert to authenticated with check(public.staff_has_any(array['admin','accountant']));
create policy monthly_update on public.monthly_memberships for update to authenticated using(public.staff_has_any(array['admin','accountant'])) with check(public.staff_has_any(array['admin','accountant']));
create policy payments_read on public.payments for select to authenticated using(public.staff_has_any(array['admin','accountant']));
create policy payments_insert on public.payments for insert to authenticated with check(public.staff_has_any(array['admin','accountant']));
create policy settlement_read on public.teacher_settlements for select to authenticated using(public.staff_has_any(array['admin','accountant']));
create policy settlement_insert on public.teacher_settlements for insert to authenticated with check(public.staff_has_any(array['admin','accountant']));
create policy expenses_read on public.expenses for select to authenticated using(public.staff_has_any(array['admin','accountant']));
create policy expenses_write on public.expenses for insert to authenticated with check(public.staff_has_any(array['admin','accountant']));

create policy partners_read on public.partners for select to authenticated using(public.staff_has_any(array['admin','accountant']));
create policy partners_write on public.partners for insert to authenticated with check(public.staff_has_any(array['admin']));
create policy partners_update on public.partners for update to authenticated using(public.staff_has_any(array['admin'])) with check(public.staff_has_any(array['admin']));
create policy ptrx_read on public.partner_transactions for select to authenticated using(public.staff_has_any(array['admin','accountant']));
create policy ptrx_insert on public.partner_transactions for insert to authenticated with check(public.staff_has_any(array['admin','accountant']));

create policy books_read on public.books for select to authenticated using(public.staff_has_any(array['admin','accountant']));
create policy books_insert on public.books for insert to authenticated with check(public.staff_has_any(array['admin','accountant']));
create policy books_update on public.books for update to authenticated using(public.staff_has_any(array['admin','accountant'])) with check(public.staff_has_any(array['admin','accountant']));
create policy book_sales_read on public.book_sales for select to authenticated using(public.staff_has_any(array['admin','accountant']));
create policy book_sales_write on public.book_sales for insert to authenticated with check(public.staff_has_any(array['admin','accountant']));
create policy owner_settlements_read on public.book_owner_settlements for select to authenticated using(public.staff_has_any(array['admin','accountant']));
create policy owner_settlements_write on public.book_owner_settlements for insert to authenticated with check(public.staff_has_any(array['admin','accountant']));
create policy chapters_read on public.chapters for select to authenticated using(public.staff_has_any(array['admin','accountant']));
create policy chapters_write on public.chapters for insert to authenticated with check(public.staff_has_any(array['admin','accountant']));
create policy chapters_update on public.chapters for update to authenticated using(public.staff_has_any(array['admin','accountant'])) with check(public.staff_has_any(array['admin','accountant']));
create policy chapter_sales_read on public.chapter_sales for select to authenticated using(public.staff_has_any(array['admin','accountant']));
create policy chapter_sales_write on public.chapter_sales for insert to authenticated with check(public.staff_has_any(array['admin','accountant']));
create policy audit_admin_read on public.audit_logs for select to authenticated using(public.staff_has_any(array['admin']));

-- Supabase publishes public schema via PostgREST. Grant only required operations.
revoke all on all tables in schema public from anon;
revoke all on all tables in schema public from authenticated;
revoke all on all sequences in schema public from anon;
revoke all on all sequences in schema public from authenticated;
grant select,insert,update on public.staff_profiles,public.students,public.teachers,
  public.class_rooms,public.enrollments,public.billing_periods,public.monthly_memberships,
  public.partners,public.books,public.chapters to authenticated;
grant select,insert on public.payments,public.teacher_settlements,public.expenses,
  public.partner_transactions,public.book_sales,public.book_owner_settlements,
  public.chapter_sales to authenticated;
grant select on public.audit_logs,public.month_fee_overview,public.teacher_class_month_totals to authenticated;
grant usage,select on sequence public.student_number_seq to authenticated;
grant usage,select on sequence public.audit_logs_id_seq to authenticated;
grant execute on function public.is_staff(),public.staff_has_any(text[]),
  public.ensure_billing_month(date),public.void_payment(uuid,text),
  public.void_teacher_settlement(uuid,text) to authenticated;

-- SECURITY: do not grant direct UPDATE to payments or settlement tables;
-- only audited void functions can invalidate financial records.
