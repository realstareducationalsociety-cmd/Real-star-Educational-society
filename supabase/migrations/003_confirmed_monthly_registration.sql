-- Apply after 001_initial.sql and 002_chapters_books_printing.sql.
-- Existing monthly records remain active; new months no longer assume renewals.
begin;

alter table public.monthly_memberships
  add column registration_active boolean not null default true,
  add column registered_on date,
  add column manual_teacher_share numeric(12,2),
  add column manual_office_share numeric(12,2),
  add column manual_adjustment_reason text,
  add column manual_adjusted_by uuid references auth.users(id),
  add column manual_adjusted_at timestamptz,
  add constraint monthly_membership_manual_shares_check check (
    (manual_teacher_share is null and manual_office_share is null
      and manual_adjustment_reason is null and manual_adjusted_by is null
      and manual_adjusted_at is null)
    or
    (manual_teacher_share is not null and manual_office_share is not null
      and manual_adjustment_reason is not null and length(trim(manual_adjustment_reason)) >= 4
      and manual_adjusted_by is not null and manual_adjusted_at is not null
      and manual_teacher_share >= 0 and manual_office_share >= 0
      and manual_teacher_share + manual_office_share = amount_due)
  ),
  add constraint monthly_membership_nonnegative_automatic_shares_check
    check (manual_teacher_share is not null or center_entitlement >= 0) not valid;
update public.monthly_memberships m set registered_on=e.enrolled_on
  from public.enrollments e where e.id=m.enrollment_id;
alter table public.monthly_memberships alter column registered_on set default ((now() at time zone 'Asia/Karachi')::date);
alter table public.monthly_memberships alter column registered_on set not null;

drop trigger if exists enrollment_month_sync on public.enrollments;

create or replace function public.ensure_billing_month(p_month date) returns integer
language plpgsql security definer set search_path=public as $$
declare existing_period public.billing_periods%rowtype;
begin
  if not public.staff_has_any(array['admin','accountant','registrar']) then
    raise exception 'اجازه ثبت‌نام ندارید';
  end if;
  if p_month is null or extract(day from p_month) <> 1 then
    raise exception 'تاریخ باید روز اول ماه باشد';
  end if;
  insert into public.billing_periods(year_month) values(p_month)
    on conflict(year_month) do nothing;
  select * into existing_period from public.billing_periods
    where year_month=p_month for update;
  if existing_period.status <> 'open' then raise exception 'این ماه بسته است'; end if;
  return 0;
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
       or old.registration_active <> new.registration_active then
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
    insert into public.students(first_name,last_name,guardian_name,phone,guardian_phone,address)
      values(trim(p_first_name),coalesce(trim(p_last_name),''),nullif(trim(p_guardian_name),''),
        nullif(trim(p_phone),''),nullif(trim(p_guardian_phone),''),nullif(trim(p_address),''))
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

    select * into membership from public.monthly_memberships
      where period_id=period and enrollment_id=enrollment for update;
    if found then
      if membership.registration_active then
        raise exception 'این شاگرد قبلاً در صنف % برای همین ماه ثبت شده است', class_row.title;
      end if;
      if exists(select 1 from public.payments where monthly_membership_id=membership.id and voided_at is null) then
        raise exception 'ثبت‌نام لغوشده‌ای که پرداخت دارد دوباره ثبت نمی‌شود';
      end if;
      if membership.manual_teacher_share is not null
        and not public.staff_has_any(array['admin']) then
        raise exception 'تمدید ثبت‌نامی که سهم دستی داشته تنها توسط مدیر انجام شود';
      end if;
      update public.monthly_memberships set registration_active=true,
        registered_on=p_registration_date,base_fee=class_row.default_fee,
        discount=p_discount,teacher_discount_share=0,
        manual_teacher_share=null,manual_office_share=null,manual_adjustment_reason=null,
        manual_adjusted_by=null,manual_adjusted_at=null
        where id=membership.id;
    else
      insert into public.monthly_memberships(
        period_id,enrollment_id,teacher_id,class_title_snapshot,registered_on,base_fee,discount
      ) values(period,enrollment,class_row.teacher_id,class_row.title,p_registration_date,class_row.default_fee,p_discount);
    end if;
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
    results := results || jsonb_build_array(result);
  end loop;
  return results;
end $$;

create or replace function public.cancel_monthly_registration(p_membership uuid,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare row public.monthly_memberships%rowtype;
begin
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

  update public.monthly_memberships set base_fee=p_base_fee,discount=p_discount,
    teacher_discount_share=p_teacher_discount_share,notes=nullif(trim(p_notes),''),
    manual_teacher_share=case when p_manual then p_teacher_share else null end,
    manual_office_share=case when p_manual then p_office_share else null end,
    manual_adjustment_reason=case when p_manual then trim(p_reason) else null end,
    manual_adjusted_by=case when p_manual then auth.uid() else null end,
    manual_adjusted_at=case when p_manual then now() else null end
    where id=row.id;
end $$;

create or replace view public.month_fee_overview with (security_invoker=true) as
select m.id,m.period_id,m.enrollment_id,e.student_id,s.student_code,
  concat_ws(' ',s.first_name,s.last_name) as student_name,
  e.class_id,m.class_title_snapshot as class_name,m.teacher_id,t.full_name as teacher_name,
  m.base_fee,m.discount,m.teacher_discount_share,m.amount_due,
  coalesce(m.manual_teacher_share,m.teacher_entitlement) as teacher_entitlement,
  coalesce(m.manual_office_share,m.center_entitlement) as center_entitlement,
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
select m.period_id,e.class_id,m.class_title_snapshot as class_name,m.teacher_id,t.full_name as teacher_name,
  count(*)::integer as student_count,
  coalesce(sum(m.base_fee),0)::numeric(12,2) as base_total,
  coalesce(sum(m.discount),0)::numeric(12,2) as discounts_total,
  coalesce(sum(coalesce(m.manual_teacher_share,m.teacher_entitlement)),0)::numeric(12,2) as teacher_entitlement,
  coalesce(sum(coalesce(m.manual_office_share,m.center_entitlement)),0)::numeric(12,2) as center_entitlement,
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
group by m.period_id,e.class_id,m.class_title_snapshot,m.teacher_id,t.full_name;

create or replace function public.guard_settlement_insert() returns trigger
language plpgsql security definer set search_path=public as $$
declare available numeric; already_paid numeric; month_status text;
begin
  select status into month_status from public.billing_periods where id=new.period_id for update;
  if month_status <> 'open' then raise exception 'ماه بسته شده است'; end if;
  select coalesce(sum(coalesce(m.manual_teacher_share,m.teacher_entitlement)),0) into available
    from public.monthly_memberships m
    join public.enrollments e on e.id=m.enrollment_id
    where m.period_id=new.period_id and e.class_id=new.class_id and m.teacher_id=new.teacher_id
      and m.registration_active;
  select coalesce(sum(amount),0) into already_paid
    from public.teacher_settlements
    where period_id=new.period_id and class_id=new.class_id and teacher_id=new.teacher_id and voided_at is null;
  if new.amount + already_paid > available then raise exception 'تصفیه بیشتر از سهم استاد است'; end if;
  new.paid_by=auth.uid();
  return new;
end $$;

create or replace function public.office_month_summary(p_month date) returns jsonb
language plpgsql security definer set search_path=public as $$
declare finish date:=(p_month+interval '1 month')::date; tuition numeric; chapters numeric;
  printing numeric; costs numeric; entitlement numeric; office_entitlement numeric; settled numeric; outstanding numeric;
begin
  if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
  select coalesce(sum(amount),0) into tuition from public.payments where voided_at is null and paid_on>=p_month and paid_on<finish;
  select coalesce(sum(amount),0) into chapters from public.material_payments where chapter_sale_id is not null and voided_at is null and paid_on>=p_month and paid_on<finish;
  select coalesce(sum(total_print_cost),0) into printing from public.chapters where printing_cost_on>=p_month and printing_cost_on<finish;
  select coalesce(sum(amount),0) into costs from public.expenses where spent_on>=p_month and spent_on<finish;
  select coalesce(sum(coalesce(m.manual_teacher_share,m.teacher_entitlement)),0) into entitlement
    from public.monthly_memberships m join public.billing_periods b on b.id=m.period_id
    where b.year_month=p_month and m.registration_active;
  select coalesce(sum(coalesce(m.manual_office_share,m.center_entitlement)),0) into office_entitlement
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

revoke all on function public.register_monthly_student(date,uuid,text,text,text,text,text,text,date,uuid[],numeric),
  public.bulk_renew_monthly_students(date,date,jsonb),
  public.cancel_monthly_registration(uuid,text),
  public.adjust_monthly_fee(uuid,numeric,numeric,numeric,boolean,numeric,numeric,text,text)
  from public,anon;
grant execute on function public.register_monthly_student(date,uuid,text,text,text,text,text,text,date,uuid[],numeric),
  public.bulk_renew_monthly_students(date,date,jsonb),
  public.cancel_monthly_registration(uuid,text),
  public.adjust_monthly_fee(uuid,numeric,numeric,numeric,boolean,numeric,numeric,text,text)
  to authenticated;

commit;
