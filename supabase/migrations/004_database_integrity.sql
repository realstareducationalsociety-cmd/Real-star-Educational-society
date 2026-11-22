-- Audit upgrade after 003. No historical rows are deleted or fabricated.
-- See DATABASE_AUDIT.md for preflight, review items, and deployment order.
begin;
revoke create on schema public from public,anon,authenticated;

alter table public.students add column registered_on date,
 add column notes text, add column updated_at timestamptz not null default now();
update public.students set registered_on=(created_at at time zone 'Asia/Karachi')::date;
alter table public.students alter column registered_on set default ((now() at time zone 'Asia/Karachi')::date);
alter table public.students alter column registered_on set not null;
alter table public.monthly_memberships
 add column registration_type text not null default 'legacy' check(registration_type in ('new','returning','renewal','legacy')),
 add column updated_at timestamptz not null default now(),
 add column calculation_mode text generated always as (case when manual_teacher_share is null then 'automatic' else 'manual' end) stored,
 add column effective_teacher_entitlement numeric(14,2) generated always as
   (coalesce(manual_teacher_share,round(base_fee*0.5-teacher_discount_share,2))) stored,
 add column effective_office_entitlement numeric(14,2) generated always as
   (coalesce(manual_office_share,base_fee-discount-round(base_fee*0.5-teacher_discount_share,2))) stored;
-- Keep legacy generated columns for compatibility; effective_* is authoritative, including half-cent rounding.
-- Retain cancelled rows and create a fresh ID for authorized re-registration.
do $$ begin
 if exists(select 1 from public.monthly_memberships where registration_active group by period_id,enrollment_id having count(*)>1)
 then raise exception 'Preflight: duplicate active memberships require review'; end if;
end $$;
alter table public.monthly_memberships drop constraint monthly_memberships_period_id_enrollment_id_key;
create unique index monthly_active_identity on public.monthly_memberships(period_id,enrollment_id) where registration_active;
alter table public.monthly_memberships add constraint effective_shares_balanced
 check(effective_teacher_entitlement>=0 and effective_office_entitlement>=0 and effective_teacher_entitlement+effective_office_entitlement=amount_due) not valid;

alter table public.billing_periods drop constraint billing_periods_status_check;
alter table public.billing_periods add constraint billing_periods_status_check check(status in ('open','under_review','closed','locked')),
 add column closed_at timestamptz, add column closed_by uuid references auth.users(id),
 add column reopened_at timestamptz, add column reopened_by uuid references auth.users(id), add column closure_notes text;
alter table public.expenses add column voided_at timestamptz, add column void_reason text;
alter table public.payments add column request_id uuid unique,
 add column receipt_number text generated always as ('TU-'||upper(replace(id::text,'-',''))) stored,
 add column payment_status text generated always as (case when voided_at is null then 'valid' else 'void' end) stored;
alter table public.teacher_settlements add column request_id uuid unique;
alter table public.material_payments add column method text not null default 'cash' check(method in ('cash','bank','other')),
 add column note text, add column receipt_number text generated always as ('MT-'||upper(replace(id::text,'-',''))) stored,
 add column payment_status text generated always as (case when voided_at is null then 'valid' else 'void' end) stored;
alter table public.book_owner_settlements add column request_id uuid unique,
 add column paid_by uuid references auth.users(id), add column created_at timestamptz not null default now(),
 add column voided_at timestamptz, add column void_reason text;
alter table public.book_sales add column owner_name_snapshot text;
update public.book_sales s set owner_name_snapshot=b.owner_name from public.books b where b.id=s.book_id;
alter table public.audit_logs add column reason text, add column approved_by uuid references auth.users(id);

create table public.registration_requests(
 id uuid primary key, actor_id uuid not null references auth.users(id), kind text not null,
 payload jsonb not null, result jsonb not null, created_at timestamptz not null default now()
);
create table public.membership_financial_adjustments(
 id uuid primary key default gen_random_uuid(), monthly_membership_id uuid not null references public.monthly_memberships(id),
 previous_teacher_entitlement numeric(14,2) not null, new_teacher_entitlement numeric(14,2) not null check(new_teacher_entitlement>=0),
 previous_office_entitlement numeric(14,2) not null, new_office_entitlement numeric(14,2) not null check(new_office_entitlement>=0),
 previous_discount numeric(14,2) not null, new_discount numeric(14,2) not null,
 previous_values jsonb not null, proposed_values jsonb not null,
 adjustment_reason text not null check(length(trim(adjustment_reason))>=4),
 adjustment_type text not null check(adjustment_type in ('automatic','manual')),
 requested_by uuid not null references auth.users(id), approved_by uuid references auth.users(id),
 approval_status text not null check(approval_status in ('pending','approved','rejected')),
 created_at timestamptz not null default now(), approved_at timestamptz,
 review_note text
);
create table public.migration_review_items(
 id bigint generated always as identity primary key, issue text not null, table_name text not null,
 row_id text, details jsonb not null, created_at timestamptz not null default now(),
 resolved_at timestamptz, resolved_by uuid references auth.users(id), resolution text
);
insert into public.migration_review_items(issue,table_name,row_id,details)
select 'Legacy negative or unbalanced shares','monthly_memberships',id::text,to_jsonb(m)
from public.monthly_memberships m where effective_office_entitlement<0 or effective_teacher_entitlement+effective_office_entitlement<>amount_due;
insert into public.migration_review_items(issue,table_name,row_id,details)
select 'Legacy registration classification/date requires review','monthly_memberships',m.id::text,
 jsonb_build_object('registered_on',m.registered_on,'billing_month',b.year_month,'registration_type',m.registration_type)
from public.monthly_memberships m join public.billing_periods b on b.id=m.period_id
where m.registration_type='legacy';
insert into public.migration_review_items(issue,table_name,row_id,details)
select 'Legacy sale missing student/class; receipts must be verified','book_sales',id::text,to_jsonb(s) from public.book_sales s where student_id is null or class_id is null
union all select 'Legacy sale missing student/class; receipts must be verified','chapter_sales',id::text,to_jsonb(s) from public.chapter_sales s where student_id is null or class_id is null;
insert into public.migration_review_items(issue,table_name,row_id,details)
select 'Partner configuration must be exactly three equal units','partners',null,jsonb_build_object('count',count(*),'units',jsonb_agg(ownership_units))
from public.partners having count(*)<>3 or bool_or(ownership_units<>1);

create or replace function public.audit_record() returns trigger language plpgsql security definer set search_path=public as $$
declare previous jsonb; current_value jsonb;
begin
 if tg_op<>'INSERT' then previous:=to_jsonb(old); end if;
 if tg_op<>'DELETE' then current_value:=to_jsonb(new); end if;
 insert into public.audit_logs(table_name,action,row_id,actor_id,old_data,new_data,reason,approved_by)
 values(tg_table_name,tg_op,coalesce(current_value->>'id',previous->>'id'),auth.uid(),previous,current_value,
 coalesce(nullif(current_setting('rsms.audit_reason',true),''),current_value->>'void_reason',current_value->>'adjustment_reason',current_value->>'closure_notes'),
 case when public.staff_has_any(array['admin']) then auth.uid() end);
 if tg_op='DELETE' then return old; end if; return new;
end $$;
create function public.touch_updated_at() returns trigger language plpgsql set search_path=public as $$
begin new.updated_at:=now(); return new; end $$;
create trigger touch_students before update on public.students for each row execute function public.touch_updated_at();
create trigger touch_membership before update on public.monthly_memberships for each row execute function public.touch_updated_at();
create trigger audit_students after insert or update on public.students for each row execute function public.audit_record();
create trigger audit_teachers after insert or update on public.teachers for each row execute function public.audit_record();
create trigger audit_classes after insert or update on public.class_rooms for each row execute function public.audit_record();
create trigger audit_periods after insert or update on public.billing_periods for each row execute function public.audit_record();
create trigger audit_adjustments after insert or update on public.membership_financial_adjustments for each row execute function public.audit_record();
create trigger audit_owner_settlements after insert or update on public.book_owner_settlements for each row execute function public.audit_record();
create trigger audit_partners after insert or update on public.partners for each row execute function public.audit_record();
create trigger audit_reviews after update on public.migration_review_items for each row execute function public.audit_record();

-- Lock all affected cash/billing months in calendar order. Missing periods are created explicitly.
create function public.lock_open_months(p_dates date[]) returns void language plpgsql security definer set search_path=public as $$
declare month date; state text;
begin
 for month in select distinct date_trunc('month',d)::date from unnest(p_dates) d where d is not null order by 1 loop
 perform pg_advisory_xact_lock(hashtextextended('rsms-month-'||month::text,0));
 insert into public.billing_periods(year_month) values(month) on conflict(year_month) do nothing;
 select status into state from public.billing_periods where year_month=month for update;
 if state<>'open' then raise exception 'Financial month % is not open',month; end if;
 end loop;
end $$;
revoke all on function public.lock_open_months(date[]) from public,anon,authenticated;
create function public.set_period_state(p_period uuid,p_state text,p_reason text) returns void language plpgsql security definer set search_path=public as $$
declare month date; row public.billing_periods%rowtype;
begin
 if not public.staff_has_any(array['admin']) then raise exception 'Administrator approval required'; end if;
 if p_state not in ('open','under_review','closed') or p_state is null or length(trim(coalesce(p_reason,'')))<4 then raise exception 'State and reason required'; end if;
 select year_month into month from public.billing_periods where id=p_period;
 if month is null then raise exception 'Period not found'; end if;
 perform pg_advisory_xact_lock(hashtextextended('rsms-month-'||month::text,0));
 select * into row from public.billing_periods where id=p_period for update;
 if p_state='closed' and exists(select 1 from public.membership_financial_adjustments a join public.monthly_memberships m on m.id=a.monthly_membership_id where m.period_id=p_period and a.approval_status='pending') then raise exception 'Review pending adjustments first'; end if;
 perform set_config('rsms.audit_reason',p_reason,true);
 update public.billing_periods set status=p_state,closure_notes=p_reason,
 closed_at=case when p_state='closed' then now() else closed_at end,closed_by=case when p_state='closed' then auth.uid() else closed_by end,
 reopened_at=case when p_state='open' and row.status<>'open' then now() else reopened_at end,
 reopened_by=case when p_state='open' and row.status<>'open' then auth.uid() else reopened_by end where id=p_period;
end $$;

-- The registrar sees registration metadata through RPC, not confidential financial columns/views.
drop policy monthly_read on public.monthly_memberships;
create policy monthly_read on public.monthly_memberships for select to authenticated using(public.staff_has_any(array['admin','accountant']));
revoke insert,update on public.monthly_memberships,public.billing_periods from authenticated;
revoke insert on public.payments,public.teacher_settlements,public.book_owner_settlements from authenticated;
alter table public.registration_requests enable row level security;
alter table public.membership_financial_adjustments enable row level security;
alter table public.migration_review_items enable row level security;
revoke all on public.registration_requests,public.membership_financial_adjustments,public.migration_review_items from anon,authenticated;
grant select on public.membership_financial_adjustments,public.migration_review_items to authenticated;
create policy adjustments_read on public.membership_financial_adjustments for select to authenticated using(public.staff_has_any(array['admin','accountant']));
create policy review_admin on public.migration_review_items for select to authenticated using(public.staff_has_any(array['admin']));

create index students_name_search on public.students(lower(first_name),lower(last_name));
create index students_phone_search on public.students(phone);
create index students_guardian_phone on public.students(guardian_phone);
create index memberships_active_period on public.monthly_memberships(period_id,teacher_id) where registration_active;
create index payments_cash_date on public.payments(paid_on) where voided_at is null;
create index settlements_cash_date on public.teacher_settlements(paid_on) where voided_at is null;
create index material_cash_date on public.material_payments(paid_on) where voided_at is null;
create index book_sales_student_class on public.book_sales(student_id,class_id,sold_on);
create index chapter_sales_student_class on public.chapter_sales(student_id,class_id,sold_on);
create index book_sales_status on public.book_sales(payment_status,sold_on);
create index chapter_sales_status on public.chapter_sales(payment_status,sold_on);
create index adjustments_membership on public.membership_financial_adjustments(monthly_membership_id,created_at);
create index expenses_date on public.expenses(spent_on);
create index chapters_class on public.chapters(class_id);
create index class_teacher on public.class_rooms(teacher_id);

-- Further RPC replacements and grants follow below within the same transaction.

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
    if old.registration_active and not new.registration_active and amount_received > 0 then
      raise exception 'ثبت‌نامی که پرداخت دارد قابل لغو نیست؛ ابتدا پرداخت را با دلیل اصلاح کنید';
    end if;
    if old.registration_active and not new.registration_active then
      if new.notes is not distinct from old.notes then raise exception 'دلیل لغو ثبت‌نام را ثبت کنید'; end if;
      if exists(select 1 from public.teacher_settlements ts
        where ts.period_id=new.period_id and ts.class_id=(
          select class_id from public.enrollments where id=new.enrollment_id
        ) and ts.teacher_id=new.teacher_id and ts.voided_at is null) then
        raise exception 'پس از تصفیه استاد، ثبت‌نام این صنف قابل لغو نیست';
      end if;
    end if;
    if old.base_fee <> new.base_fee or old.discount <> new.discount
       or old.teacher_discount_share <> new.teacher_discount_share
       or old.registration_active <> new.registration_active
       or old.manual_teacher_share is distinct from new.manual_teacher_share
       or old.manual_office_share is distinct from new.manual_office_share then
      select coalesce(sum(ts.amount),0) into paid_out from public.teacher_settlements ts
        join public.enrollments e on e.class_id=ts.class_id
        where e.id=new.enrollment_id and ts.period_id=new.period_id
          and ts.teacher_id=new.teacher_id and ts.voided_at is null;
      if paid_out > 0 then
        raise exception 'پس از تصفیه استاد، ابتدا اسناد مالی را بررسی کنید';
      end if;
    end if;
    if old.manual_teacher_share is distinct from new.manual_teacher_share
      or old.manual_office_share is distinct from new.manual_office_share
      or old.manual_adjustment_reason is distinct from new.manual_adjustment_reason then
      if not public.staff_has_any(array['admin']) then
        raise exception 'تنظیم دستی سهم‌ها تنها صلاحیت مدیر است';
      end if;
      if new.manual_teacher_share is null and new.manual_office_share is null then
        new.manual_adjustment_reason := null;
        new.manual_adjusted_by := null;
        new.manual_adjusted_at := null;
      else
        if new.manual_teacher_share is null or new.manual_office_share is null
          or new.manual_teacher_share < 0 or new.manual_office_share < 0
          or new.manual_teacher_share + new.manual_office_share <> new.base_fee-new.discount
          or length(trim(coalesce(new.manual_adjustment_reason,''))) < 4 then
          raise exception 'سهم استاد و اداره باید غیرمنفی، برابر فیس قابل پرداخت و همراه دلیل باشد';
        end if;
        new.manual_adjusted_by := auth.uid();
        new.manual_adjusted_at := now();
      end if;
    end if;
  end if;
  return new;
end $$;

create or replace function public.register_monthly_student(
  p_month date,
  p_student_id uuid,
  p_first_name text,
  p_last_name text,
  p_guardian_name text,
  p_phone text,
  p_guardian_phone text,
  p_address text,
  p_registration_date date,
  p_class_ids uuid[],
  p_discount numeric default 0
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  period uuid;
  student uuid := p_student_id;
  v_class_id uuid;
  class_row public.class_rooms%rowtype;
  enrollment uuid;
  membership public.monthly_memberships%rowtype;
  added integer := 0;
  class_count integer;
begin
 perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
  if not public.staff_has_any(array['admin','registrar']) then
    raise exception 'اجازه ثبت‌نام شاگرد ندارید';
  end if;
  if p_month is null or extract(day from p_month) <> 1 then
    raise exception 'ماه ثبت‌نام معتبر نیست';
  end if;
  if p_registration_date is null or p_registration_date < p_month
    or p_registration_date >= (p_month + interval '1 month')::date then
    raise exception 'تاریخ ثبت‌نام باید در ماه انتخاب‌شده باشد';
  end if;
  if p_class_ids is null or cardinality(p_class_ids)=0
    or cardinality(p_class_ids) <> (select count(distinct id) from unnest(p_class_ids) as u(id)) then
    raise exception 'حداقل یک صنف یکتا انتخاب کنید';
  end if;
  if coalesce(p_discount,0) < 0 or p_discount <> round(p_discount,2) then
    raise exception 'مبلغ تخفیف معتبر نیست';
  end if;
  p_discount := coalesce(p_discount,0);
  if student is null and length(trim(coalesce(p_first_name,'')))=0 then
    raise exception 'نام شاگرد ضروری است';
  end if;

  insert into public.billing_periods(year_month) values(p_month)
    on conflict(year_month) do nothing;
  select id into period from public.billing_periods
    where year_month=p_month and status='open' for update;
  if period is null then raise exception 'ماه انتخاب‌شده بسته است'; end if;

  if student is null then
    insert into public.students(first_name,last_name,guardian_name,phone,guardian_phone,address,registered_on)
      values(trim(p_first_name),coalesce(trim(p_last_name),''),nullif(trim(p_guardian_name),''),
        nullif(trim(p_phone),''),nullif(trim(p_guardian_phone),''),nullif(trim(p_address),''),p_registration_date)
      returning id into student;
  else
    update public.students set
      first_name=coalesce(nullif(trim(p_first_name),''),first_name),
      last_name=coalesce(trim(p_last_name),last_name),
      guardian_name=nullif(trim(p_guardian_name),''),
      phone=nullif(trim(p_phone),''), guardian_phone=nullif(trim(p_guardian_phone),''),
      address=nullif(trim(p_address),''), active=true
      where id=student;
    if not found then raise exception 'شاگرد پیدا نشد'; end if;
  end if;

  class_count := cardinality(p_class_ids);
  foreach v_class_id in array p_class_ids loop
    select * into class_row from public.class_rooms where id=v_class_id and active for update;
    if not found then raise exception 'یکی از صنف‌های انتخاب‌شده موجود یا فعال نیست'; end if;
    if p_discount > class_row.default_fee then
      raise exception 'تخفیف از فیس صنف % بیشتر است', class_row.title;
    end if;

    insert into public.enrollments(student_id,class_id,enrolled_on,active)
      values(student,v_class_id,p_registration_date,true)
      on conflict(student_id,class_id) do update set active=true
      returning id into enrollment;


    if exists(select 1 from public.monthly_memberships where period_id=period and enrollment_id=enrollment and registration_active)
    then raise exception 'Student already has an active registration for this class and month'; end if;
    insert into public.monthly_memberships(period_id,enrollment_id,teacher_id,class_title_snapshot,registered_on,base_fee,discount,registration_type)
    values(period,enrollment,class_row.teacher_id,class_row.title,p_registration_date,class_row.default_fee,p_discount,
      case when p_student_id is null then 'new' else 'returning' end);
    added := added + 1;
  end loop;

  return jsonb_build_object('student_id',student,'student_code',
    (select student_code from public.students where id=student),
    'membership_count',added,'selected_classes',class_count);
end $$;

create or replace function public.bulk_renew_monthly_students(
  p_month date,p_registration_date date,p_registrations jsonb
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare item jsonb; person public.students%rowtype; result jsonb; results jsonb:='[]'::jsonb;
begin
 perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
  if not public.staff_has_any(array['admin','registrar']) then
    raise exception 'اجازه ثبت‌نام شاگرد ندارید';
  end if;
  if p_registrations is null or jsonb_typeof(p_registrations)<>'array' or jsonb_array_length(p_registrations)=0 then
    raise exception 'حداقل یک ثبت‌نام برای تمدید انتخاب کنید';
  end if;
  if (select count(*) from jsonb_array_elements(p_registrations)) <>
     (select count(distinct value->>'student_id') from jsonb_array_elements(p_registrations)) then
    raise exception 'برای هر شاگرد فقط یک انتخاب تمدید بفرستید';
  end if;
  for item in select value from jsonb_array_elements(p_registrations) loop
    select * into person from public.students where id=(item->>'student_id')::uuid;
    if not found then raise exception 'یکی از شاگردان پیدا نشد'; end if;
    result := public.register_monthly_student(
      p_month,person.id,person.first_name,person.last_name,person.guardian_name,
      person.phone,person.guardian_phone,person.address,p_registration_date,
      array(select jsonb_array_elements_text(item->'class_ids')::uuid),
      coalesce((item->>'discount')::numeric,0)
    );

    update public.monthly_memberships m set registration_type='renewal'
    from public.enrollments e,public.billing_periods b
    where m.enrollment_id=e.id and m.period_id=b.id and b.year_month=p_month
      and e.student_id=person.id and e.class_id in (select jsonb_array_elements_text(item->'class_ids')::uuid)
      and m.registration_active;
    results := results || jsonb_build_array(result);
  end loop;
  return results;
end $$;

create or replace function public.adjust_monthly_fee(
  p_membership uuid,p_base_fee numeric,p_discount numeric,p_teacher_discount_share numeric,
  p_manual boolean,p_teacher_share numeric,p_office_share numeric,p_reason text,p_notes text
) returns void language plpgsql security definer set search_path=public as $$
declare
  row public.monthly_memberships%rowtype;
  month_status text;
  target_class_id uuid;
  due numeric(12,2);
begin
 perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
  if not public.staff_has_any(array['admin','accountant']) then raise exception 'اجازه مالی ندارید'; end if;
  if p_base_fee is null or p_discount is null or p_teacher_discount_share is null
    or p_base_fee<0 or p_discount<0 or p_teacher_discount_share<0
    or p_base_fee<>round(p_base_fee,2) or p_discount<>round(p_discount,2)
    or p_teacher_discount_share<>round(p_teacher_discount_share,2)
    or p_discount>p_base_fee or p_teacher_discount_share>p_discount
    or p_teacher_discount_share>p_base_fee*0.50 then
    raise exception 'مقادیر فیس، تخفیف و سهم تخفیف استاد معتبر نیست';
  end if;
  due := p_base_fee-p_discount;
  if p_manual then
    if not public.staff_has_any(array['admin']) then raise exception 'تنظیم دستی سهم‌ها تنها صلاحیت مدیر است'; end if;
    if p_teacher_share is null or p_office_share is null
      or p_teacher_share<0 or p_office_share<0
      or p_teacher_share<>round(p_teacher_share,2) or p_office_share<>round(p_office_share,2)
      or p_teacher_share+p_office_share<>due
      or length(trim(coalesce(p_reason,'')))<4 then
      raise exception 'سهم‌ها باید غیرمنفی، برابر فیس قابل پرداخت و همراه دلیل باشد';
    end if;
  end if;

  select m.* into row from public.monthly_memberships m
    where m.id=p_membership for update;
  if not found then raise exception 'حساب ماهانه پیدا نشد'; end if;
  select b.status,e.class_id into month_status,target_class_id
    from public.monthly_memberships m
    join public.billing_periods b on b.id=m.period_id
    join public.enrollments e on e.id=m.enrollment_id
    where m.id=p_membership;
  if month_status<>'open' then raise exception 'این ماه بسته شده است'; end if;
  if not row.registration_active then raise exception 'ثبت‌نام لغوشده قابل اصلاح نیست'; end if;
  if exists(select 1 from public.payments where monthly_membership_id=row.id and voided_at is null
      group by monthly_membership_id having sum(amount)>due) then
    raise exception 'فیس جدید از پرداخت‌های ثبت‌شده کمتر است';
  end if;
  if exists(select 1 from public.teacher_settlements ts where ts.period_id=row.period_id
      and ts.class_id=target_class_id and ts.teacher_id=row.teacher_id and ts.voided_at is null) then
    raise exception 'پس از تصفیه استاد، سهم قابل تغییر نیست؛ ابتدا اصلاح مالی مستند انجام دهید';
  end if;

  perform set_config('rsms.audit_reason',coalesce(nullif(trim(p_reason),''),'Automatic tuition adjustment'),true);
  update public.monthly_memberships set base_fee=p_base_fee,discount=p_discount,
    teacher_discount_share=p_teacher_discount_share,notes=nullif(trim(p_notes),''),
    manual_teacher_share=case when p_manual then p_teacher_share else null end,
    manual_office_share=case when p_manual then p_office_share else null end,
    manual_adjustment_reason=case when p_manual then trim(p_reason) else null end,
    manual_adjusted_by=case when p_manual then auth.uid() else null end,
    manual_adjusted_at=case when p_manual then now() else null end
    where id=row.id;
  insert into public.membership_financial_adjustments(monthly_membership_id,
    previous_teacher_entitlement,new_teacher_entitlement,previous_office_entitlement,new_office_entitlement,
    previous_discount,new_discount,previous_values,proposed_values,adjustment_reason,adjustment_type,
    requested_by,approved_by,approval_status,approved_at)
  select row.id,row.effective_teacher_entitlement,m.effective_teacher_entitlement,row.effective_office_entitlement,m.effective_office_entitlement,
    row.discount,m.discount,to_jsonb(row),to_jsonb(m),coalesce(nullif(trim(p_reason),''),'Automatic tuition adjustment'),
    case when p_manual then 'manual' else 'automatic' end,auth.uid(),auth.uid(),'approved',now()
  from public.monthly_memberships m where m.id=row.id;
end $$;

create function public.submit_monthly_registration(p_payload jsonb,p_request uuid) returns jsonb
language plpgsql security definer set search_path=public as $$
declare previous public.registration_requests%rowtype; result jsonb;
begin
 if not public.staff_has_any(array['admin','registrar']) then raise exception 'Registration access required'; end if;
 if p_request is null or p_payload is null then raise exception 'Request ID and payload required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
 select * into previous from public.registration_requests where id=p_request;
 if found then
  if previous.actor_id<>auth.uid() or previous.payload<>p_payload or previous.kind<>'single' then raise exception 'Request ID reused with different data'; end if;
  return previous.result;
 end if;
 result:=public.register_monthly_student((p_payload->>'p_month')::date,(p_payload->>'p_student_id')::uuid,
 p_payload->>'p_first_name',p_payload->>'p_last_name',p_payload->>'p_guardian_name',p_payload->>'p_phone',
 p_payload->>'p_guardian_phone',p_payload->>'p_address',(p_payload->>'p_registration_date')::date,
 array(select jsonb_array_elements_text(p_payload->'p_class_ids')::uuid),(p_payload->>'p_discount')::numeric);
 insert into public.registration_requests values(p_request,auth.uid(),'single',p_payload,result,now());
 return result;
end $$;

create function public.renew_monthly_students(p_month date,p_registration_date date,p_registrations jsonb,p_request uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare previous public.registration_requests%rowtype; payload jsonb; result jsonb;
begin
 if not public.staff_has_any(array['admin','registrar']) then raise exception 'Registration access required'; end if;
 if p_request is null then raise exception 'Request ID required'; end if;
 payload:=jsonb_build_object('month',p_month,'date',p_registration_date,'rows',p_registrations);
 perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
 select * into previous from public.registration_requests where id=p_request;
 if found then
  if previous.actor_id<>auth.uid() or previous.payload<>payload or previous.kind<>'bulk' then raise exception 'Request ID reused with different data'; end if;
  return previous.result;
 end if;
 result:=public.bulk_renew_monthly_students(p_month,p_registration_date,p_registrations);
 insert into public.registration_requests values(p_request,auth.uid(),'bulk',payload,result,now());
 return result;
end $$;

create function public.monthly_registration_list(p_month date,p_student uuid default null) returns jsonb
language plpgsql security definer set search_path=public as $$
begin
 if not public.is_staff() then raise exception 'Staff access required'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object(
 'id',m.id,'registration_active',m.registration_active,'registered_on',m.registered_on,'registration_type',m.registration_type,
 'base_fee',m.base_fee,'discount',m.discount,'period',jsonb_build_object('year_month',b.year_month),
 'enrollment',jsonb_build_object('id',e.id,'student_id',e.student_id,'class_id',e.class_id,
 'student',jsonb_build_object('id',s.id,'student_code',s.student_code,'first_name',s.first_name,'last_name',s.last_name,'phone',s.phone),
 'class_item',jsonb_build_object('title',m.class_title_snapshot))) order by m.registered_on desc,m.id)
 from public.monthly_memberships m join public.billing_periods b on b.id=m.period_id
 join public.enrollments e on e.id=m.enrollment_id join public.students s on s.id=e.student_id
 where (p_month is null or b.year_month=p_month) and (p_student is null or e.student_id=p_student)),'[]'::jsonb);
end $$;

create function public.monthly_registration_summary(p_month date) returns jsonb
language plpgsql security definer set search_path=public as $$
declare result jsonb;
begin
 if not public.is_staff() then raise exception 'Staff access required'; end if;
 with registrations as (
 select m.*,e.student_id,e.class_id,c.active as class_active,t.active as teacher_active
 from public.monthly_memberships m
 join public.enrollments e on e.id=m.enrollment_id
 join public.class_rooms c on c.id=e.class_id
 join public.teachers t on t.id=m.teacher_id
 join public.billing_periods b on b.id=m.period_id
 where b.year_month=p_month and m.registration_active
 )
 select jsonb_build_object('registrations',count(*),'unique_students',count(distinct student_id),
 'active_classes',count(distinct class_id) filter(where class_active),
 'active_teachers',count(distinct teacher_id) filter(where teacher_active),
 'new_registrations',count(*) filter(where registration_type='new'),
 'returning_registrations',count(*) filter(where registration_type in ('returning','renewal')),
 'legacy_registrations',count(*) filter(where registration_type='legacy'),
 'by_class',coalesce((select jsonb_agg(g) from (select class_id,min(class_title_snapshot) class_name,count(*) registrations from registrations group by class_id) g),'[]'::jsonb),
 'by_teacher',coalesce((select jsonb_agg(g) from (select r.teacher_id,t.full_name teacher_name,count(*) registrations from registrations r join public.teachers t on t.id=r.teacher_id group by r.teacher_id,t.full_name) g),'[]'::jsonb))
 into result from registrations;
 return result;
end $$;

create function public.request_membership_adjustment(p_membership uuid,p_teacher numeric,p_office numeric,p_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
declare row public.monthly_memberships%rowtype; result uuid;
begin
 if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
 select * into row from public.monthly_memberships where id=p_membership;
 if not found or not row.registration_active then raise exception 'Active membership not found'; end if;
 if p_teacher is null or p_office is null or p_teacher<0 or p_office<0 or p_teacher<>round(p_teacher,2)
 or p_office<>round(p_office,2) or p_teacher+p_office<>row.amount_due or length(trim(coalesce(p_reason,'')))<4
 then raise exception 'Balanced shares and reason required'; end if;
 perform public.lock_open_months(array[(select year_month from public.billing_periods where id=row.period_id)]);
 insert into public.membership_financial_adjustments(monthly_membership_id,
 previous_teacher_entitlement,new_teacher_entitlement,previous_office_entitlement,new_office_entitlement,
 previous_discount,new_discount,previous_values,proposed_values,adjustment_reason,adjustment_type,requested_by,approval_status)
 values(row.id,row.effective_teacher_entitlement,p_teacher,row.effective_office_entitlement,p_office,row.discount,row.discount,
 to_jsonb(row),jsonb_build_object('teacher',p_teacher,'office',p_office),p_reason,'manual',auth.uid(),'pending') returning id into result;
 return result;
end $$;

create function public.review_membership_adjustment(p_id uuid,p_approve boolean,p_note text) returns void
language plpgsql security definer set search_path=public as $$
declare request public.membership_financial_adjustments%rowtype; row public.monthly_memberships%rowtype;
begin
 perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
 if not public.staff_has_any(array['admin']) then raise exception 'Administrator approval required'; end if;
 if length(trim(coalesce(p_note,'')))<4 or p_approve is null then raise exception 'Review note required'; end if;
 select * into request from public.membership_financial_adjustments where id=p_id for update;
 if not found or request.approval_status<>'pending' then raise exception 'Pending adjustment not found'; end if;
 select * into row from public.monthly_memberships where id=request.monthly_membership_id for update;
 if p_approve then
  if row.base_fee<>(request.previous_values->>'base_fee')::numeric or row.discount<>request.previous_discount
  or row.effective_teacher_entitlement<>request.previous_teacher_entitlement
  or row.effective_office_entitlement<>request.previous_office_entitlement then raise exception 'Account changed since request; submit a new request'; end if;
  perform public.adjust_monthly_fee(row.id,row.base_fee,row.discount,row.teacher_discount_share,true,
    request.new_teacher_entitlement,request.new_office_entitlement,request.adjustment_reason,row.notes);
 end if;
 perform set_config('rsms.audit_reason',p_note,true);
 update public.membership_financial_adjustments set approval_status=case when p_approve then 'approved' else 'rejected' end,
 approved_by=auth.uid(),approved_at=now(),review_note=p_note where id=p_id;
end $$;

create or replace function public.guard_payment_insert() returns trigger
language plpgsql security definer set search_path=public as $$
declare row public.monthly_memberships%rowtype; received numeric; month date;
begin
 select b.year_month into month from public.monthly_memberships m join public.billing_periods b on b.id=m.period_id where m.id=new.monthly_membership_id;
 perform public.lock_open_months(array[month,new.paid_on]);
 select * into row from public.monthly_memberships where id=new.monthly_membership_id for update;
 if not found or not row.registration_active then raise exception 'Active membership required'; end if;
 select coalesce(sum(amount),0) into received from public.payments where monthly_membership_id=row.id and voided_at is null;
 if new.amount+received>row.amount_due or new.voided_at is not null then raise exception 'Invalid payment or overpayment'; end if;
 new.received_by:=auth.uid(); return new;
end $$;

create function public.record_tuition_payment(p_membership uuid,p_amount numeric,p_date date,p_method text,p_note text,p_request uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare row public.payments%rowtype;
begin
 perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
 if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
 if p_request is null or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) then raise exception 'Valid amount and request ID required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
 select * into row from public.payments where request_id=p_request;
 if found then
  if row.monthly_membership_id<>p_membership or row.amount<>p_amount or row.paid_on<>p_date or row.method<>p_method then raise exception 'Request ID reused with different data'; end if;
  return to_jsonb(row);
 end if;
 insert into public.payments(monthly_membership_id,amount,paid_on,method,reference_note,request_id)
 values(p_membership,p_amount,p_date,p_method,p_note,p_request) returning * into row;
 return to_jsonb(row);
end $$;

create or replace function public.guard_settlement_insert() returns trigger
language plpgsql security definer set search_path=public as $$
declare available numeric; already_paid numeric; month date;
begin
 select year_month into month from public.billing_periods where id=new.period_id;
 if month is null then raise exception 'Period not found'; end if;
 perform public.lock_open_months(array[month,new.paid_on]);
 select coalesce(sum(m.effective_teacher_entitlement),0) into available from public.monthly_memberships m
 join public.enrollments e on e.id=m.enrollment_id where m.period_id=new.period_id and e.class_id=new.class_id
 and m.teacher_id=new.teacher_id and m.registration_active;
 select coalesce(sum(amount),0) into already_paid from public.teacher_settlements
 where period_id=new.period_id and class_id=new.class_id and teacher_id=new.teacher_id and voided_at is null;
 if new.amount+already_paid>available or new.voided_at is not null then raise exception 'Settlement exceeds entitlement'; end if;
 new.paid_by:=auth.uid(); return new;
end $$;

create function public.record_teacher_settlement(p_period uuid,p_class uuid,p_teacher uuid,p_amount numeric,p_date date,p_note text,p_request uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare row public.teacher_settlements%rowtype; result uuid;
begin
 perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
 if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
 if p_request is null or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) then raise exception 'Valid amount and request ID required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
 select * into row from public.teacher_settlements where request_id=p_request;
 if found then
  if row.period_id<>p_period or row.class_id<>p_class or row.teacher_id<>p_teacher or row.amount<>p_amount or row.paid_on<>p_date then raise exception 'Request ID reused with different data'; end if;
  return row.id;
 end if;
 insert into public.teacher_settlements(period_id,class_id,teacher_id,amount,paid_on,note,request_id)
 values(p_period,p_class,p_teacher,p_amount,p_date,p_note,p_request) returning id into result;
 return result;
end $$;

create or replace function public.void_payment(p_id uuid,p_reason text) returns void
language plpgsql security definer set search_path=public as $$
declare row public.payments%rowtype; month date;
begin
 perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
 if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
 if length(trim(coalesce(p_reason,'')))<4 then raise exception 'Reason required'; end if;
 select * into row from public.payments where id=p_id;
 if not found or row.voided_at is not null then raise exception 'Valid receipt not found'; end if;
 select b.year_month into month from public.monthly_memberships m join public.billing_periods b on b.id=m.period_id where m.id=row.monthly_membership_id;
 perform public.lock_open_months(array[month,row.paid_on]);
 perform 1 from public.monthly_memberships where id=row.monthly_membership_id for update;
 perform set_config('rsms.audit_reason',p_reason,true);
 update public.payments set voided_at=now(),void_reason=p_reason where id=p_id and voided_at is null;
 if not found then raise exception 'Already voided'; end if;
end $$;

create or replace function public.void_teacher_settlement(p_id uuid,p_reason text) returns void
language plpgsql security definer set search_path=public as $$
declare row public.teacher_settlements%rowtype; month date;
begin
 perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
 if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
 if length(trim(coalesce(p_reason,'')))<4 then raise exception 'Reason required'; end if;
 select * into row from public.teacher_settlements where id=p_id;
 if not found or row.voided_at is not null then raise exception 'Valid settlement not found'; end if;
 select year_month into month from public.billing_periods where id=row.period_id;
 perform public.lock_open_months(array[month,row.paid_on]);
 perform set_config('rsms.audit_reason',p_reason,true);
 update public.teacher_settlements set voided_at=now(),void_reason=p_reason where id=p_id and voided_at is null;
 if not found then raise exception 'Already voided'; end if;
end $$;

create function public.guard_material_ledger() returns trigger language plpgsql security definer set search_path=public as $$
declare kind text; sale uuid; due numeric; received numeric; owner text; owner_received numeric; owner_paid numeric;
begin
 kind:=case when new.book_sale_id is not null then 'book' else 'chapter' end;
 sale:=coalesce(new.book_sale_id,new.chapter_sale_id);
 perform public.lock_open_months(array[new.paid_on]);
 if tg_op='UPDATE' then
  if new.amount<>old.amount or new.paid_on<>old.paid_on or new.book_sale_id is distinct from old.book_sale_id
  or new.chapter_sale_id is distinct from old.chapter_sale_id or old.voided_at is not null or new.voided_at is null
  or length(trim(coalesce(new.void_reason,'')))<4 then raise exception 'Receipts are immutable; use a documented void'; end if;
 else
  if new.voided_at is not null then raise exception 'New receipt cannot be voided'; end if;
 end if;
 if kind='book' then
  select owner_name_snapshot into owner from public.book_sales where id=sale;
  perform pg_advisory_xact_lock(hashtextextended('book-owner-'||owner,0));
  if tg_op='UPDATE' then
   select coalesce(sum(p.amount),0) into owner_received from public.material_payments p join public.book_sales s on s.id=p.book_sale_id where s.owner_name_snapshot=owner and p.voided_at is null;
   select coalesce(sum(amount),0) into owner_paid from public.book_owner_settlements where owner_name=owner and voided_at is null;
   if owner_received-new.amount<owner_paid then raise exception 'Reverse owner payout before voiding this receipt'; end if;
  end if;
 end if;
 execute format('select quantity*unit_price from public.%I where id=$1 for update',kind||'_sales') into due using sale;
 select coalesce(sum(amount),0) into received from public.material_payments where coalesce(book_sale_id,chapter_sale_id)=sale and voided_at is null;
 if tg_op='INSERT' and received+new.amount>due then raise exception 'Overpayment'; end if;
 if tg_op='INSERT' then new.received_by:=auth.uid(); end if;
 return new;
end $$;
create function public.sync_material_ledger() returns trigger language plpgsql security definer set search_path=public as $$
declare kind text; sale uuid; received numeric;
begin
 kind:=case when new.book_sale_id is not null then 'book' else 'chapter' end; sale:=coalesce(new.book_sale_id,new.chapter_sale_id);
 select coalesce(sum(amount),0) into received from public.material_payments where coalesce(book_sale_id,chapter_sale_id)=sale and voided_at is null;
 execute format('update public.%I set paid_total=$1 where id=$2',kind||'_sales') using received,sale;
 return new;
end $$;
create trigger guard_material_ledger before insert or update on public.material_payments for each row execute function public.guard_material_ledger();
create trigger sync_material_ledger after insert or update on public.material_payments for each row execute function public.sync_material_ledger();

create function public.guard_expense_date() returns trigger language plpgsql security definer set search_path=public as $$
begin perform public.lock_open_months(array[new.spent_on]); new.entered_by:=auth.uid(); return new; end $$;
create trigger guard_expense_date before insert on public.expenses for each row execute function public.guard_expense_date();
create function public.guard_chapter_cost_date() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if tg_op='INSERT' then
  if new.total_print_cost>0 then perform public.lock_open_months(array[new.printing_cost_on]); end if;
 elsif new.total_print_cost<>old.total_print_cost or new.printing_cost_on<>old.printing_cost_on then
  perform public.lock_open_months(array[old.printing_cost_on,new.printing_cost_on]);
 end if; return new;
end $$;
create trigger guard_chapter_cost_date before insert or update on public.chapters for each row execute function public.guard_chapter_cost_date();
create function public.snapshot_book_owner() returns trigger language plpgsql security definer set search_path=public as $$
begin select owner_name into new.owner_name_snapshot from public.books where id=new.book_id; return new; end $$;
create trigger snapshot_book_owner before insert on public.book_sales for each row execute function public.snapshot_book_owner();

create function public.independent_book_summary() returns jsonb language plpgsql security definer set search_path=public as $$
begin
 if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
 return jsonb_build_object(
 'total_sales',(select coalesce(sum(quantity*unit_price),0) from public.book_sales),
 'collected',(select coalesce(sum(amount),0) from public.material_payments where book_sale_id is not null and voided_at is null),
 'outstanding',(select coalesce(sum(quantity*unit_price-paid_total),0) from public.book_sales),
 'owners',coalesce((select jsonb_agg(o) from (
 select owner_name_snapshot owner_name,sum(paid_total) collected,
 coalesce((select sum(amount) from public.book_owner_settlements x where x.owner_name=s.owner_name_snapshot and x.voided_at is null),0) paid_to_owner,
 sum(paid_total)-coalesce((select sum(amount) from public.book_owner_settlements x where x.owner_name=s.owner_name_snapshot and x.voided_at is null),0) held_for_owner
 from public.book_sales s group by owner_name_snapshot) o),'[]'::jsonb));
end $$;

create function public.settle_book_owner(p_owner text,p_amount numeric,p_date date,p_note text,p_request uuid) returns uuid
language plpgsql security definer set search_path=public as $$
declare collected numeric; paid numeric; result uuid;
begin
 if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
 if p_request is null or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) then raise exception 'Valid amount and request ID required'; end if;
 perform public.lock_open_months(array[p_date]);
 perform pg_advisory_xact_lock(hashtextextended('book-owner-'||p_owner,0));
 select id into result from public.book_owner_settlements where request_id=p_request;
 if found then return result; end if;
 select coalesce(sum(p.amount),0) into collected from public.material_payments p join public.book_sales s on s.id=p.book_sale_id where s.owner_name_snapshot=p_owner and p.voided_at is null;
 select coalesce(sum(amount),0) into paid from public.book_owner_settlements where owner_name=p_owner and voided_at is null;
 if p_amount>collected-paid then raise exception 'Payout exceeds external-owner funds held'; end if;
 insert into public.book_owner_settlements(owner_name,amount,paid_on,note,request_id,paid_by)
 values(p_owner,p_amount,p_date,p_note,p_request,auth.uid()) returning id into result;
 return result;
end $$;

create function public.void_book_owner_settlement(p_id uuid,p_reason text) returns void
language plpgsql security definer set search_path=public as $$
declare row public.book_owner_settlements%rowtype;
begin
 if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
 if length(trim(coalesce(p_reason,'')))<4 then raise exception 'Reason required'; end if;
 select * into row from public.book_owner_settlements where id=p_id;
 if not found then raise exception 'Payout not found'; end if;
 perform public.lock_open_months(array[row.paid_on]);
 perform pg_advisory_xact_lock(hashtextextended('book-owner-'||row.owner_name,0));
 update public.book_owner_settlements set voided_at=now(),void_reason=p_reason where id=p_id and voided_at is null;
 if not found then raise exception 'Already voided'; end if;
end $$;

create or replace function public.pay_material(p_kind text,p_sale uuid,p_amount numeric,p_date date,p_request uuid,p_complete boolean default false)
returns void language plpgsql security definer set search_path=public as $$
declare sale record; value numeric;
begin
 if p_kind='chapter' then perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0)); end if;
 if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
 if p_kind not in ('book','chapter') or p_kind is null then raise exception 'Invalid material'; end if;
 execute format('select * from public.%I where id=$1 for update',p_kind||'_sales') into sale using p_sale;
 if sale.id is null then raise exception 'Sale not found'; end if;
 if exists(select 1 from public.material_payments where request_id=p_request) then return; end if;
 value:=case when p_complete then sale.quantity*sale.unit_price-sale.paid_total else p_amount end;
 if p_complete and value=0 then return; end if;
 if value is null or value<=0 or value<>round(value,2) or value+sale.paid_total>sale.quantity*sale.unit_price or p_date is null or p_request is null then raise exception 'Invalid payment or overpayment'; end if;
 insert into public.material_payments(book_sale_id,chapter_sale_id,amount,paid_on,request_id,received_by)
 values(case when p_kind='book' then p_sale end,case when p_kind='chapter' then p_sale end,value,p_date,p_request,auth.uid());
 -- Ledger trigger maintains the cached total.
end $$;

create or replace function public.void_material_payment(p_id uuid,p_reason text) returns void language plpgsql security definer set search_path=public as $$
declare receipt public.material_payments%rowtype; kind text; sale uuid;
begin
 if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
 if length(trim(coalesce(p_reason,'')))<4 then raise exception 'A correction reason is required'; end if;
 select * into receipt from public.material_payments where id=p_id;
 if not found then raise exception 'Payment not found'; end if;
 if receipt.chapter_sale_id is not null then perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0)); end if;
 kind:=case when receipt.book_sale_id is not null then 'book' else 'chapter' end;
 sale:=coalesce(receipt.book_sale_id,receipt.chapter_sale_id);
 execute format('select id from public.%I where id=$1 for update',kind||'_sales') using sale;
 select * into receipt from public.material_payments where id=p_id for update;
 if receipt.voided_at is not null then raise exception 'Already voided'; end if;
 update public.material_payments set voided_at=now(),void_reason=p_reason,voided_by=auth.uid() where id=p_id;
 -- Ledger trigger maintains the cached total.
end $$;

create or replace view public.month_fee_overview with (security_invoker=true) as
select m.id,m.period_id,m.enrollment_id,e.student_id,s.student_code,
  concat_ws(' ',s.first_name,s.last_name) as student_name,
  e.class_id,m.class_title_snapshot as class_name,m.teacher_id,t.full_name as teacher_name,
  m.base_fee,m.discount,m.teacher_discount_share,m.amount_due,
  m.effective_teacher_entitlement::numeric(12,2) as teacher_entitlement,
  m.effective_office_entitlement::numeric(12,2) as center_entitlement,
  m.notes,
  coalesce(paid.paid_total,0)::numeric(12,2) as paid_total,
  (m.amount_due-coalesce(paid.paid_total,0))::numeric(12,2) as balance_due,
  m.registration_active,m.registered_on,(m.manual_teacher_share is not null) as manually_adjusted,
  m.manual_adjustment_reason,m.manual_adjusted_by,m.manual_adjusted_at
from public.monthly_memberships m
join public.enrollments e on e.id=m.enrollment_id
join public.students s on s.id=e.student_id
join public.class_rooms c on c.id=e.class_id
join public.teachers t on t.id=m.teacher_id
left join lateral (
  select sum(amount) as paid_total from public.payments
  where monthly_membership_id=m.id and voided_at is null
) paid on true
where m.registration_active;

create or replace view public.teacher_class_month_totals with (security_invoker=true) as
select m.period_id,e.class_id,min(m.class_title_snapshot) as class_name,m.teacher_id,t.full_name as teacher_name,
  count(*)::integer as student_count,
  coalesce(sum(m.base_fee),0)::numeric(12,2) as base_total,
  coalesce(sum(m.discount),0)::numeric(12,2) as discounts_total,
  coalesce(sum((m.effective_teacher_entitlement+0)),0)::numeric(12,2) as teacher_entitlement,
  coalesce(sum((m.effective_office_entitlement+0)),0)::numeric(12,2) as center_entitlement,
  coalesce(sum(f.paid_total),0)::numeric(12,2) as received_total,
  coalesce((select sum(amount) from public.teacher_settlements ts
    where ts.period_id=m.period_id and ts.class_id=e.class_id
      and ts.teacher_id=m.teacher_id and ts.voided_at is null),0)::numeric(12,2) as settled_total
from public.monthly_memberships m
join public.enrollments e on e.id=m.enrollment_id
join public.class_rooms c on c.id=e.class_id
join public.teachers t on t.id=m.teacher_id
join public.month_fee_overview f on f.id=m.id
where m.registration_active
group by m.period_id,e.class_id,m.teacher_id,t.full_name;



create or replace function public.office_month_summary(p_month date) returns jsonb
language plpgsql security definer set search_path=public as $$
declare finish date:=(p_month+interval '1 month')::date; tuition numeric; chapters numeric;
  printing numeric; costs numeric; entitlement numeric; office_entitlement numeric; settled numeric; outstanding numeric;
begin
  if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
  select coalesce(sum(amount),0) into tuition from public.payments where voided_at is null and paid_on>=p_month and paid_on<finish;
  select coalesce(sum(amount),0) into chapters from public.material_payments where chapter_sale_id is not null and voided_at is null and paid_on>=p_month and paid_on<finish;
  select coalesce(sum(total_print_cost),0) into printing from public.chapters where printing_cost_on>=p_month and printing_cost_on<finish;
  select coalesce(sum(amount),0) into costs from public.expenses where voided_at is null and spent_on>=p_month and spent_on<finish;
  select coalesce(sum(m.effective_teacher_entitlement),0) into entitlement
    from public.monthly_memberships m join public.billing_periods b on b.id=m.period_id
    where b.year_month=p_month and m.registration_active;
  select coalesce(sum(m.effective_office_entitlement),0) into office_entitlement
    from public.monthly_memberships m join public.billing_periods b on b.id=m.period_id
    where b.year_month=p_month and m.registration_active;
  select coalesce(sum(amount),0) into settled from public.teacher_settlements where voided_at is null and paid_on>=p_month and paid_on<finish;
  select coalesce(sum(quantity*unit_price-paid_total),0) into outstanding from public.chapter_sales;
  return jsonb_build_object('tuition_collected',tuition,'chapter_collected',chapters,'chapter_outstanding',outstanding,
    'chapter_printing',printing,'chapter_net',chapters-printing,'gross_collected',tuition+chapters,
    'teacher_entitlement',entitlement,'office_entitlement',office_entitlement,
    'teacher_paid',settled,'expenses',costs,
    'net_after_entitlement',tuition+chapters-entitlement-printing-costs,
    'cash_after_payments',tuition+chapters-settled-printing-costs);
end $$;

alter table public.partners add column ownership_denominator integer generated always as (3) stored,
 add constraint partner_equal_unit check(ownership_units=1) not valid;
create table public.profit_distribution_batches(
 id uuid primary key default gen_random_uuid(), period_id uuid not null references public.billing_periods(id),
 amount numeric(14,2) not null check(amount>0), request_id uuid not null unique,
 approved_by uuid not null references auth.users(id), approved_at timestamptz not null default now(),
 reason text not null check(length(trim(reason))>=4), voided_at timestamptz, void_reason text
);
alter table public.partner_transactions add column batch_id uuid references public.profit_distribution_batches(id),
 add column request_id uuid unique, add column entered_by uuid references auth.users(id),
 add column voided_at timestamptz, add column void_reason text;
create unique index partner_distribution_once on public.partner_transactions(batch_id,partner_id) where batch_id is not null;
alter table public.profit_distribution_batches enable row level security;
revoke all on public.profit_distribution_batches from anon,authenticated;
grant select on public.profit_distribution_batches to authenticated;
create policy distribution_read on public.profit_distribution_batches for select to authenticated using(public.staff_has_any(array['admin','accountant']));
create trigger audit_distributions after insert or update on public.profit_distribution_batches for each row execute function public.audit_record();
revoke insert on public.partner_transactions from authenticated;
create function public.guard_partner_count() returns trigger language plpgsql security definer set search_path=public as $$
begin
 perform pg_advisory_xact_lock(hashtextextended('rsms-partners',0));
 if (select count(*) from public.partners)>=3 then raise exception 'Exactly three partners are permitted'; end if;
 return new;
end $$;
create trigger guard_partner_count before insert on public.partners for each row execute function public.guard_partner_count();

-- Conservative lifetime reserve: unpaid tuition is never distributable, book funds never enter it.
create function public.distributable_reserve() returns numeric language sql stable security definer set search_path=public as $$
 select
 (select coalesce(sum(amount),0) from public.payments where voided_at is null)
 +(select coalesce(sum(amount),0) from public.material_payments where chapter_sale_id is not null and voided_at is null)
 -(select coalesce(sum(effective_teacher_entitlement),0) from public.monthly_memberships where registration_active)
 -(select coalesce(sum(amount),0) from public.expenses where voided_at is null)
 -(select coalesce(sum(total_print_cost),0) from public.chapters)
 -(select coalesce(sum(amount),0) from public.partner_transactions where kind in ('withdrawal','profit_distribution') and voided_at is null)
$$;

create function public.partner_account_summary() returns jsonb language plpgsql security definer set search_path=public as $$
begin
 if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
 return jsonb_build_object('distributable_reserve',public.distributable_reserve(),
 'configuration_valid',(select count(*)=3 and bool_and(ownership_units=1) from public.partners),
 'partners',coalesce((select jsonb_agg(r) from (
 select p.id,p.full_name,p.ownership_units,p.ownership_denominator,
 coalesce(sum(t.amount) filter(where t.kind='capital' and t.voided_at is null),0) capital,
 coalesce(sum(t.amount) filter(where t.kind='withdrawal' and t.voided_at is null),0) withdrawals,
 coalesce(sum(t.amount) filter(where t.kind='profit_distribution' and t.voided_at is null),0) distributions
 from public.partners p left join public.partner_transactions t on t.partner_id=p.id group by p.id) r),'[]'::jsonb));
end $$;

create function public.record_partner_transaction(p_partner uuid,p_kind text,p_amount numeric,p_date date,p_note text,p_request uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare result uuid;
begin
 perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
 if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
 if p_kind not in ('capital','withdrawal') or p_kind is null or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_request is null then raise exception 'Invalid partner transaction'; end if;
 perform public.lock_open_months(array[p_date]);
 perform pg_advisory_xact_lock(hashtextextended('rsms-partners',0));
 select id into result from public.partner_transactions where request_id=p_request;
 if found then return result; end if;
 insert into public.partner_transactions(partner_id,kind,amount,transacted_on,description,request_id,entered_by)
 values(p_partner,p_kind,p_amount,p_date,p_note,p_request,auth.uid()) returning id into result;
 return result;
end $$;

create function public.distribute_partner_profit(p_period uuid,p_total numeric,p_reason text,p_request uuid) returns uuid
language plpgsql security definer set search_path=public as $$
declare period public.billing_periods%rowtype; result uuid; month_available numeric; snapshot jsonb; today date:=((now() at time zone 'Asia/Karachi')::date);
begin
 perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
 if not public.staff_has_any(array['admin']) then raise exception 'Administrator approval required'; end if;
 if p_request is null or p_total is null or p_total<=0 or p_total/3<>round(p_total/3,2) or length(trim(coalesce(p_reason,'')))<4 then raise exception 'Total must divide equally into three exact two-decimal shares; reason and request required'; end if;
 perform public.lock_open_months(array[today]);
 perform pg_advisory_xact_lock(hashtextextended('rsms-partners',0));
 select id into result from public.profit_distribution_batches where request_id=p_request;
 if found then return result; end if;
 select * into period from public.billing_periods where id=p_period for update;
 if not found or period.status not in ('closed','locked') then raise exception 'Approve and close the source period first'; end if;
 if (select count(*) from public.partners)<>3 or exists(select 1 from public.partners where ownership_units<>1) then raise exception 'Configure exactly three equal partners first'; end if;
 if exists(select 1 from public.monthly_memberships where registration_active and effective_office_entitlement<0) then raise exception 'Resolve legacy negative financial shares first'; end if;
 snapshot:=public.office_month_summary(period.year_month);
 select (snapshot->>'net_after_entitlement')::numeric-coalesce(sum(amount),0) into month_available
 from public.profit_distribution_batches where period_id=p_period and voided_at is null;
 if p_total>least(month_available,public.distributable_reserve()) then raise exception 'Insufficient approved distributable profit after obligations and expenses'; end if;
 insert into public.profit_distribution_batches(period_id,amount,request_id,approved_by,reason)
 values(p_period,p_total,p_request,auth.uid(),p_reason) returning id into result;
 insert into public.partner_transactions(partner_id,kind,amount,transacted_on,description,batch_id,entered_by)
 select id,'profit_distribution',p_total/3,today,p_reason,result,auth.uid() from public.partners;
 return result;
end $$;

create function public.void_partner_transaction(p_id uuid,p_reason text) returns void
language plpgsql security definer set search_path=public as $$
declare row public.partner_transactions%rowtype; source_month date;
begin
 perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
 if not public.staff_has_any(array['admin']) then raise exception 'Administrator approval required'; end if;
 if length(trim(coalesce(p_reason,'')))<4 then raise exception 'Reason required'; end if;
 select * into row from public.partner_transactions where id=p_id;
 if not found or row.voided_at is not null then raise exception 'Valid transaction not found'; end if;
 if row.batch_id is not null then
 select b.year_month into source_month from public.profit_distribution_batches d join public.billing_periods b on b.id=d.period_id where d.id=row.batch_id;
 end if;
 perform public.lock_open_months(array[row.transacted_on,source_month]);
 perform pg_advisory_xact_lock(hashtextextended('rsms-partners',0));
 perform set_config('rsms.audit_reason',p_reason,true);
 if row.batch_id is not null then
 update public.profit_distribution_batches set voided_at=now(),void_reason=p_reason where id=row.batch_id;
 update public.partner_transactions set voided_at=now(),void_reason=p_reason where batch_id=row.batch_id and voided_at is null;
 else update public.partner_transactions set voided_at=now(),void_reason=p_reason where id=p_id and voided_at is null;
 end if;
end $$;

create function public.resolve_migration_review(p_id bigint,p_resolution text) returns void
language plpgsql security definer set search_path=public as $$
begin
 if not public.staff_has_any(array['admin']) then raise exception 'Administrator approval required'; end if;
 if length(trim(coalesce(p_resolution,'')))<4 then raise exception 'Resolution note required'; end if;
 perform set_config('rsms.audit_reason',p_resolution,true);
 update public.migration_review_items set resolved_at=now(),resolved_by=auth.uid(),resolution=p_resolution where id=p_id and resolved_at is null;
 if not found then raise exception 'Unresolved review item not found'; end if;
end $$;


-- Serialize institutional mutations with profit approval; external book transactions remain separate.
create function public.serialize_office_ledger() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if tg_table_name='material_payments' then
  if new.chapter_sale_id is null then return new; end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
 return new;
end $$;
create trigger a_lock_office before insert or update on public.payments for each row execute function public.serialize_office_ledger();
create trigger a_lock_office before insert or update on public.teacher_settlements for each row execute function public.serialize_office_ledger();
create trigger a_lock_office before insert or update on public.monthly_memberships for each row execute function public.serialize_office_ledger();
create trigger a_lock_office before insert or update on public.material_payments for each row execute function public.serialize_office_ledger();
create trigger a_lock_office before insert on public.expenses for each row execute function public.serialize_office_ledger();
create trigger a_lock_office before insert or update on public.chapters for each row execute function public.serialize_office_ledger();

create function public.guard_finite_money() returns trigger language plpgsql set search_path=public as $$
declare field text; payload jsonb:=to_jsonb(new);
begin
 foreach field in array array['amount','base_fee','discount','teacher_discount_share','manual_teacher_share','manual_office_share','sale_price','default_sale_price','unit_price','unit_commission','commission_per_book','total_print_cost','default_fee'] loop
 if payload->>field in ('NaN','Infinity','-Infinity') then raise exception 'Money must be finite: %',field; end if;
 end loop;
 return new;
end $$;
do $$
declare name text;
begin
 foreach name in array array['monthly_memberships','payments','teacher_settlements','expenses','books','book_sales','chapters','chapter_sales','material_payments','book_owner_settlements','partner_transactions','class_rooms'] loop
 execute format('create trigger finite_money before insert or update on public.%I for each row execute function public.guard_finite_money()',name);
 end loop;
end $$;
insert into public.migration_review_items(issue,table_name,row_id,details)
select 'Cached payment total differs from ledger','book_sales',s.id::text,jsonb_build_object('cached',s.paid_total,'ledger',coalesce(p.paid,0))
from public.book_sales s left join lateral(select sum(amount) paid from public.material_payments where book_sale_id=s.id and voided_at is null) p on true where s.paid_total<>coalesce(p.paid,0)
union all
select 'Cached payment total differs from ledger','chapter_sales',s.id::text,jsonb_build_object('cached',s.paid_total,'ledger',coalesce(p.paid,0))
from public.chapter_sales s left join lateral(select sum(amount) paid from public.material_payments where chapter_sale_id=s.id and voided_at is null) p on true where s.paid_total<>coalesce(p.paid,0);

create or replace function public.cancel_monthly_registration(p_membership uuid,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare row public.monthly_memberships%rowtype;
begin
 perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
  if not public.staff_has_any(array['admin','registrar']) then
    raise exception 'اجازه لغو ثبت‌نام ندارید';
  end if;
  if length(trim(coalesce(p_reason,''))) < 4 then raise exception 'دلیل لغو را بنویسید'; end if;
  select * into row from public.monthly_memberships where id=p_membership for update;
  if not found or not row.registration_active then raise exception 'ثبت‌نام فعال پیدا نشد'; end if;
  update public.monthly_memberships set registration_active=false,
    notes=concat_ws(E'\n',notes,'لغو ثبت‌نام: '||trim(p_reason))
    where id=p_membership;
end $$;

create function public.void_expense(p_id uuid,p_reason text) returns void language plpgsql security definer set search_path=public as $$
declare row public.expenses%rowtype;
begin
 if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
 if length(trim(coalesce(p_reason,'')))<4 then raise exception 'Reason required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
 select * into row from public.expenses where id=p_id;
 if not found or row.voided_at is not null then raise exception 'Valid expense not found'; end if;
 perform public.lock_open_months(array[row.spent_on]);
 perform set_config('rsms.audit_reason',p_reason,true);
 update public.expenses set voided_at=now(),void_reason=p_reason where id=p_id and voided_at is null;
 if not found then raise exception 'Already voided'; end if;
end $$;

create view public.teacher_settlement_summary with(security_invoker=true) as
select t.*,teacher_entitlement-settled_total remaining_settlement,
case when teacher_entitlement=settled_total then 'settled' when settled_total>0 then 'partial' else 'unpaid' end settlement_status
from public.teacher_class_month_totals t;
create view public.month_tuition_summary with(security_invoker=true) as
select period_id,count(*) registrations,count(distinct student_id) unique_students,
sum(base_fee) original_total,sum(discount) discounts_total,sum(amount_due) payable_total,
sum(paid_total) received_total,sum(balance_due) outstanding_total,
sum(teacher_entitlement) teacher_total,sum(center_entitlement) office_total
from public.month_fee_overview group by period_id;
grant select on public.teacher_settlement_summary,public.month_tuition_summary to authenticated;

-- Expose only supported RPCs. Internal helpers and trigger functions cannot be called by API users.
do $$
declare f record; api text[]:=array[
 'is_staff','staff_has_any','void_expense','ensure_billing_month','submit_monthly_registration','renew_monthly_students',
 'cancel_monthly_registration','adjust_monthly_fee','request_membership_adjustment','review_membership_adjustment',
 'monthly_registration_list','monthly_registration_summary','record_tuition_payment','void_payment',
 'record_teacher_settlement','void_teacher_settlement','pay_material','sell_material','void_material_payment',
 'class_month_report','office_month_summary','independent_book_summary','settle_book_owner','void_book_owner_settlement',
 'set_period_state','partner_account_summary','record_partner_transaction','distribute_partner_profit','void_partner_transaction','resolve_migration_review'];
begin
 for f in select p.oid::regprocedure signature,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef loop
  execute format('alter function %s set search_path=public,pg_temp',f.signature);
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  if f.proname=any(api) then execute format('grant execute on function %s to authenticated',f.signature); end if;
 end loop;
end $$;
commit;
