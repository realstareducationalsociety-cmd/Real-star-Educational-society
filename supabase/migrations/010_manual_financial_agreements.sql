-- Migration 010: Manual Financial Agreements and Institution-Controlled Entitlements
-- Real Star Educational Society (Attock, Pakistan)
-- Core Financial Policy:
-- 1. Standard teacher entitlement is 50% of administrator-approved base tuition before discounts.
-- 2. Ordinary student discounts reduce the institution's share, not the teacher's standard entitlement.
-- 3. The administrator retains full authority over base tuition and student discounts.
-- 4. The administrator may override the default entitlement (higher or lower) with mandatory reason.
-- 5. Fully discounted students still generate approved teacher entitlement (institution-funded).
begin;

-- Add manual agreement columns to monthly_memberships
alter table public.monthly_memberships
  add column if not exists discount_reason text,
  add column if not exists agreement_approved_by uuid references auth.users(id),
  add column if not exists agreement_approved_at timestamptz;

-- Update constraints to support institution-funded teacher obligations (office share may be negative when institution funds teacher entitlement)
alter table public.monthly_memberships drop constraint if exists effective_shares_balanced;
alter table public.monthly_memberships add constraint effective_shares_balanced
  check(effective_teacher_entitlement >= 0 and effective_teacher_entitlement + effective_office_entitlement = amount_due) not valid;

alter table public.monthly_memberships drop constraint if exists monthly_membership_nonnegative_automatic_shares_check;

alter table public.monthly_memberships drop constraint if exists monthly_membership_manual_shares_check;
alter table public.monthly_memberships add constraint monthly_membership_manual_shares_check check (
  (manual_teacher_share is null and manual_office_share is null and manual_adjustment_reason is null and manual_adjusted_by is null and manual_adjusted_at is null)
  or (manual_teacher_share is not null and manual_office_share is not null and manual_teacher_share >= 0
  and manual_teacher_share + manual_office_share = amount_due and length(trim(manual_adjustment_reason)) >= 4
  and manual_adjusted_by is not null and manual_adjusted_at is not null)
);

alter table public.monthly_memberships drop constraint if exists monthly_memberships_proration_rule_check;
alter table public.monthly_memberships add constraint monthly_memberships_proration_rule_check
  check(proration_rule in ('full_month', 'half_after_20th', 'manual_agreement'));

alter table public.membership_financial_adjustments drop constraint if exists membership_financial_adjustments_new_office_entitlement_check;

-- Guard for membership updates: preserves receipts, prevents unauthorized edits, and guards against modifying settled classes
create or replace function public.guard_membership_change() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  month_status text;
  amount_received numeric;
  paid_out numeric;
begin
  select status into month_status from public.billing_periods
    where id = new.period_id for update;
  if month_status <> 'open' then raise exception 'این ماه بسته شده است'; end if;

  if tg_op = 'UPDATE' then
    if old.enrollment_id <> new.enrollment_id or old.period_id <> new.period_id
      or old.teacher_id <> new.teacher_id or old.class_title_snapshot <> new.class_title_snapshot then
      raise exception 'مشخصات ارتباط ماه را نمی‌توان تغییر داد';
    end if;

    select coalesce(sum(amount),0) into amount_received from public.payments
      where monthly_membership_id = new.id and voided_at is null;
    if amount_received > new.base_fee - new.discount then
      raise exception 'مبلغ جدید کمتر از پرداخت‌های ثبت‌شده است';
    end if;

    if old.registration_active and not new.registration_active and amount_received > 0 then
      raise exception 'ثبت‌نامی که پرداخت دارد قابل لغو نیست؛ ابتدا پرداخت را با دلیل اصلاح کنید';
    end if;

    if old.registration_active and not new.registration_active then
      if new.notes is not distinct from old.notes then
        raise exception 'دلیل لغو ثبت‌نام را ثبت کنید';
      end if;
      if exists(select 1 from public.teacher_settlements ts
        where ts.period_id = new.period_id and ts.class_id = (
          select class_id from public.enrollments where id = new.enrollment_id
        ) and ts.teacher_id = new.teacher_id and ts.voided_at is null) then
        raise exception 'پس از تصفیه استاد، ثبت‌نام این صنف قابل لغو نیست';
      end if;
    end if;

    if old.base_fee <> new.base_fee or old.discount <> new.discount
       or old.teacher_discount_share <> new.teacher_discount_share
       or old.registration_active <> new.registration_active
       or old.manual_teacher_share is distinct from new.manual_teacher_share
       or old.manual_office_share is distinct from new.manual_office_share then
      select coalesce(sum(ts.amount),0) into paid_out from public.teacher_settlements ts
        join public.enrollments e on e.class_id = ts.class_id
        where e.id = new.enrollment_id and ts.period_id = new.period_id
          and ts.teacher_id = new.teacher_id and ts.voided_at is null;
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
          or new.manual_teacher_share < 0
          or new.manual_teacher_share + new.manual_office_share <> new.base_fee - new.discount
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

-- Trigger ensuring explicit administrator approval on financial agreements
create or replace function public.guard_approved_agreement() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  is_override boolean;
  std_share numeric;
begin
 if tg_op = 'INSERT' or (new.original_fee, new.base_fee, new.discount, new.teacher_discount_share, new.manual_teacher_share, new.manual_office_share, new.discount_reason, new.agreement_approved_by, new.agreement_approved_at, new.proration_rule)
 is distinct from (old.original_fee, old.base_fee, old.discount, old.teacher_discount_share, old.manual_teacher_share, old.manual_office_share, old.discount_reason, old.agreement_approved_by, old.agreement_approved_at, old.proration_rule) then
  if not public.staff_has_any(array['admin']) then
    raise exception 'Administrator approval required' using errcode='42501';
  end if;

  if new.agreement_approved_by is distinct from auth.uid()
   or new.agreement_approved_at is null
   or new.original_fee::text in ('NaN','Infinity','-Infinity') or new.original_fee < 0
   or new.base_fee::text in ('NaN','Infinity','-Infinity') or new.base_fee < 0
   or new.discount::text in ('NaN','Infinity','-Infinity') or new.discount < 0 or new.discount > new.base_fee
   or new.teacher_discount_share <> 0
   or new.proration_rule <> 'manual_agreement'
   or (new.discount > 0 and length(trim(coalesce(new.discount_reason,''))) < 4) then
   raise exception 'Explicit approved agreement and valid discount reason required';
  end if;

  std_share := round(new.base_fee * 0.50, 2);
  is_override := (new.manual_teacher_share is not null and new.manual_teacher_share <> std_share);

  if is_override then
    if new.manual_teacher_share < 0 or new.manual_office_share is null
       or new.manual_teacher_share + new.manual_office_share <> new.base_fee - new.discount
       or length(trim(coalesce(new.manual_adjustment_reason, ''))) < 4 then
      raise exception 'Manual teacher entitlement override requires non-negative amount, balanced office share, and mandatory exception reason';
    end if;
  else
    if new.manual_teacher_share is not null then
      if new.manual_office_share is null or new.manual_teacher_share + new.manual_office_share <> new.base_fee - new.discount then
        raise exception 'Standard entitlement shares must balance';
      end if;
    end if;
  end if;
 end if;
 return new;
end $$;

drop trigger if exists approved_agreement_guard on public.monthly_memberships;
create trigger approved_agreement_guard before insert or update on public.monthly_memberships
  for each row execute function public.guard_approved_agreement();

-- Legacy entry points: disabled in favor of administrator-approved registration
create or replace function public.register_monthly_student(
  p_month date, p_student_id uuid, p_first_name text, p_last_name text, p_guardian_name text,
  p_phone text, p_guardian_phone text, p_address text, p_registration_date date, p_class_ids uuid[], p_discount numeric default 0
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
begin
  raise exception 'Use the administrator-approved registration form';
end $$;

-- Authoritative student registration RPC with manual financial agreements
create or replace function public.register_dashboard_student(p_payload jsonb, p_request uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  prior registration_requests%rowtype;
  student uuid;
  period uuid;
  enrollment uuid;
  membership uuid;
  item jsonb;
  room class_rooms%rowtype;
  result jsonb;
  requested_month date;
  registration_date date;
  original numeric;
  agreed numeric;
  discount numeric;
  entitlement numeric;
  payment numeric;
  total integer := 0;
  std_teacher_share numeric;
  is_exception boolean;
  v_teacher_share numeric;
  v_office_share numeric;
  v_exception_reason text;
  v_adjusted_by uuid;
  v_adjusted_at timestamptz;
begin
  if not staff_has_any(array['admin']) then
    raise exception 'Administrator approval required' using errcode='42501';
  end if;
  if p_request is null or p_payload is null or (p_payload->>'approved')::boolean is distinct from true then
    raise exception 'Explicit administrator approval required';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
  perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));

  select * into prior from registration_requests where id = p_request;
  if found then
    if prior.actor_id <> auth.uid() or prior.payload <> p_payload or prior.kind <> 'agreement' then
      raise exception 'Request ID reused with different data';
    end if;
    return prior.result;
  end if;

  requested_month := (p_payload->>'month')::date;
  registration_date := (p_payload->>'date')::date;
  if requested_month is null or registration_date is null
     or date_trunc('month', requested_month)::date <> requested_month
     or date_trunc('month', registration_date)::date <> requested_month then
    raise exception 'Registration date must be in the selected month';
  end if;

  if jsonb_typeof(p_payload->'classes') is distinct from 'array' then
    raise exception 'Select at least one class';
  end if;
  if jsonb_array_length(p_payload->'classes') = 0
     or jsonb_array_length(p_payload->'classes') <> (select count(distinct value->>'class_id') from jsonb_array_elements(p_payload->'classes')) then
    raise exception 'Select unique classes';
  end if;

  insert into billing_periods(year_month) values(requested_month) on conflict(year_month) do nothing;
  select id into period from billing_periods where year_month = requested_month and status = 'open' for update;
  if period is null then
    raise exception 'Selected month is closed';
  end if;

  student := nullif(p_payload->>'student_id','')::uuid;
  if student is null then
    if length(trim(coalesce(p_payload->>'first_name',''))) = 0 then
      raise exception 'Student first name is required';
    end if;
    insert into students(first_name, last_name, guardian_name, phone, guardian_phone, address, registered_on, notes)
    values(
      trim(p_payload->>'first_name'),
      coalesce(p_payload->>'last_name',''),
      p_payload->>'guardian_name',
      p_payload->>'phone',
      p_payload->>'guardian_phone',
      p_payload->>'address',
      registration_date,
      p_payload->>'notes'
    ) returning id into student;
  elsif not exists(select 1 from students where id = student) then
    raise exception 'Student not found';
  end if;

  for item in select value from jsonb_array_elements(p_payload->'classes') loop
    select * into room from class_rooms where id = (item->>'class_id')::uuid and active for share;
    if not found then
      raise exception 'Selected active class not found';
    end if;

    original := (item->>'original_fee')::numeric;
    agreed := (item->>'agreed_fee')::numeric;
    discount := (item->>'discount')::numeric;
    entitlement := (item->>'teacher_entitlement')::numeric;
    payment := (item->>'payment')::numeric;

    if original is null or agreed is null or discount is null or entitlement is null or payment is null
       or original < 0 or agreed < 0 or discount < 0 or discount > agreed or entitlement < 0
       or payment < 0 or payment > agreed - discount
       or original <> round(original, 2) or agreed <> round(agreed, 2)
       or discount <> round(discount, 2) or entitlement <> round(entitlement, 2) or payment <> round(payment, 2)
       or original::text in ('NaN','Infinity','-Infinity') or agreed::text in ('NaN','Infinity','-Infinity')
       or entitlement::text in ('NaN','Infinity','-Infinity') or payment::text in ('NaN','Infinity','-Infinity')
       or discount::text in ('NaN','Infinity','-Infinity') then
      raise exception 'Invalid agreement amounts';
    end if;

    if discount > 0 and length(trim(coalesce(item->>'discount_reason',''))) < 4 then
      raise exception 'Discount reason required';
    end if;

    -- Standard teacher entitlement is 50% of approved base tuition.
    -- If entitlement differs from 50%, an exception reason is required.
    std_teacher_share := round(agreed * 0.50, 2);
    is_exception := (entitlement <> std_teacher_share);

    if is_exception then
      v_teacher_share := entitlement;
      v_office_share := agreed - discount - entitlement;
      v_exception_reason := trim(coalesce(item->>'exception_reason', item->>'teacher_exception_reason', item->>'arrangement_notes', ''));
      if length(v_exception_reason) < 4 then
        raise exception 'Teacher entitlement exception requires a mandatory reason (minimum 4 characters)';
      end if;
      v_adjusted_by := auth.uid();
      v_adjusted_at := now();
    else
      v_teacher_share := null;
      v_office_share := null;
      v_exception_reason := null;
      v_adjusted_by := null;
      v_adjusted_at := null;
    end if;

    insert into enrollments(student_id, class_id, enrolled_on, active)
      values(student, room.id, registration_date, true)
      on conflict(student_id, class_id) do update set active = true
      returning id into enrollment;

    if exists(select 1 from monthly_memberships where period_id = period and enrollment_id = enrollment and registration_active) then
      raise exception 'Student already has an active registration for this class and month' using errcode='23505';
    end if;

    perform set_config('rsms.audit_reason', 'Administrator approved monthly agreement', true);
    insert into monthly_memberships(
      period_id, enrollment_id, teacher_id, class_title_snapshot, registered_on,
      original_fee, base_fee, discount, teacher_discount_share,
      manual_teacher_share, manual_office_share,
      manual_adjustment_reason, manual_adjusted_by, manual_adjusted_at,
      agreement_approved_by, agreement_approved_at, discount_reason, notes,
      proration_rule, registration_type
    ) values (
      period, enrollment, room.teacher_id, room.title, registration_date,
      original, agreed, discount, 0,
      v_teacher_share, v_office_share,
      v_exception_reason, v_adjusted_by, v_adjusted_at,
      auth.uid(), now(), item->>'discount_reason', item->>'arrangement_notes',
      'manual_agreement',
      case when nullif(p_payload->>'student_id','') is null then 'new' else 'returning' end
    ) returning id into membership;

    if payment > 0 then
      perform record_tuition_payment(
        membership, payment, (item->>'paid_on')::date,
        item->>'payment_method',
        nullif(concat_ws(' | ', nullif(item->>'payment_reference',''), nullif(item->>'payment_note','')),''),
        gen_random_uuid()
      );
    end if;
    total := total + 1;
  end loop;

  result := jsonb_build_object(
    'student_id', student,
    'student_code', (select student_code from students where id = student),
    'membership_count', total
  );
  insert into registration_requests values(p_request, auth.uid(), 'agreement', p_payload, result, now());
  return result;
end $$;

-- Update approved monthly agreement with full audit log
create or replace function public.update_monthly_agreement(
  p_membership uuid, p_agreement jsonb, p_expected_updated_at timestamptz
) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
<<financial_values>>
declare
  before_row monthly_memberships%rowtype;
  original numeric;
  agreed numeric;
  discount numeric;
  entitlement numeric;
  reason text;
  std_teacher_share numeric;
  is_exception boolean;
  v_teacher_share numeric;
  v_office_share numeric;
  v_exception_reason text;
  v_adjusted_by uuid;
  v_adjusted_at timestamptz;
begin
  if not staff_has_any(array['admin']) then
    raise exception 'Administrator approval required' using errcode='42501';
  end if;
  if (p_agreement->>'approved')::boolean is distinct from true then
    raise exception 'Explicit administrator approval required';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
  select * into before_row from monthly_memberships where id = p_membership for update;
  if not found or not before_row.registration_active then
    raise exception 'Active membership not found';
  end if;
  if p_expected_updated_at is null or before_row.updated_at <> p_expected_updated_at then
    raise exception 'Agreement changed; refresh before editing' using errcode='40001';
  end if;

  original := (p_agreement->>'original_fee')::numeric;
  agreed := (p_agreement->>'agreed_fee')::numeric;
  discount := (p_agreement->>'discount')::numeric;
  entitlement := (p_agreement->>'teacher_entitlement')::numeric;
  reason := trim(p_agreement->>'reason');

  if original is null or agreed is null or discount is null or entitlement is null
     or original < 0 or agreed < 0 or discount < 0 or discount > agreed or entitlement < 0
     or original <> round(original, 2) or agreed <> round(agreed, 2)
     or discount <> round(discount, 2) or entitlement <> round(entitlement, 2)
     or coalesce(length(reason), 0) < 4 then
    raise exception 'Invalid agreement amounts or modification reason';
  end if;

  if discount > 0 and length(trim(coalesce(p_agreement->>'discount_reason',''))) < 4 then
    raise exception 'Discount reason required';
  end if;

  std_teacher_share := round(agreed * 0.50, 2);
  is_exception := (entitlement <> std_teacher_share);

  if is_exception then
    v_teacher_share := entitlement;
    v_office_share := agreed - financial_values.discount - entitlement;
    v_exception_reason := trim(coalesce(p_agreement->>'exception_reason', p_agreement->>'teacher_exception_reason', reason));
    if length(v_exception_reason) < 4 then
      raise exception 'Teacher entitlement exception requires a mandatory reason (minimum 4 characters)';
    end if;
    v_adjusted_by := auth.uid();
    v_adjusted_at := now();
  else
    v_teacher_share := null;
    v_office_share := null;
    v_exception_reason := null;
    v_adjusted_by := null;
    v_adjusted_at := null;
  end if;

  perform set_config('rsms.audit_reason', reason, true);
  update monthly_memberships set
    original_fee = original,
    base_fee = agreed,
    discount = financial_values.discount,
    teacher_discount_share = 0,
    manual_teacher_share = v_teacher_share,
    manual_office_share = v_office_share,
    manual_adjustment_reason = v_exception_reason,
    manual_adjusted_by = v_adjusted_by,
    manual_adjusted_at = v_adjusted_at,
    agreement_approved_by = auth.uid(),
    agreement_approved_at = now(),
    discount_reason = p_agreement->>'discount_reason',
    notes = p_agreement->>'arrangement_notes',
    proration_rule = 'manual_agreement'
  where id = p_membership;

  insert into membership_financial_adjustments(
    monthly_membership_id, previous_teacher_entitlement, new_teacher_entitlement,
    previous_office_entitlement, new_office_entitlement, previous_discount, new_discount,
    previous_values, proposed_values, adjustment_reason, adjustment_type,
    requested_by, approved_by, approval_status, approved_at
  ) select
    p_membership, before_row.effective_teacher_entitlement, m.effective_teacher_entitlement,
    before_row.effective_office_entitlement, m.effective_office_entitlement,
    before_row.discount, m.discount, to_jsonb(before_row), to_jsonb(m),
    reason, 'manual', auth.uid(), auth.uid(), 'approved', now()
  from monthly_memberships m where m.id = p_membership;
end $$;

-- Compatibility for administrator adjustment UI
create or replace function public.adjust_monthly_fee(
  p_membership uuid, p_base_fee numeric, p_discount numeric, p_teacher_discount_share numeric,
  p_manual boolean, p_teacher_share numeric, p_office_share numeric, p_reason text, p_notes text
) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  current_row monthly_memberships%rowtype;
begin
  if not staff_has_any(array['admin']) then
    raise exception 'Administrator approval required' using errcode='42501';
  end if;
  if p_manual is distinct from true or p_teacher_share is null or p_office_share is null
     or p_teacher_share + p_office_share <> p_base_fee - p_discount then
    raise exception 'Explicit agreement required';
  end if;
  select * into current_row from monthly_memberships where id = p_membership;
  perform update_monthly_agreement(
    p_membership,
    jsonb_build_object(
      'original_fee', current_row.original_fee,
      'agreed_fee', p_base_fee,
      'discount', p_discount,
      'teacher_entitlement', p_teacher_share,
      'discount_reason', coalesce(current_row.discount_reason, p_reason),
      'arrangement_notes', p_notes,
      'reason', p_reason,
      'approved', true
    ),
    current_row.updated_at
  );
end $$;

-- Authoritative view: Month Fee Overview with standard share and exception tracking
create or replace view public.month_fee_overview with (security_invoker=true) as
select
  m.id,
  m.period_id,
  m.enrollment_id,
  e.student_id,
  s.student_code,
  concat_ws(' ', s.first_name, s.last_name) as student_name,
  e.class_id,
  m.class_title_snapshot as class_name,
  m.teacher_id,
  t.full_name as teacher_name,
  m.base_fee,
  m.discount,
  m.teacher_discount_share,
  m.amount_due,
  m.effective_teacher_entitlement::numeric(12,2) as teacher_entitlement,
  m.effective_office_entitlement::numeric(12,2) as center_entitlement,
  m.notes,
  coalesce(paid.paid_total, 0)::numeric(12,2) as paid_total,
  (m.amount_due - coalesce(paid.paid_total, 0))::numeric(12,2) as balance_due,
  m.registration_active,
  m.registered_on,
  (m.manual_teacher_share is not null) as manually_adjusted,
  m.manual_adjustment_reason,
  m.manual_adjusted_by,
  m.manual_adjusted_at,
  m.original_fee,
  m.proration_rule,
  m.base_fee as agreed_fee,
  m.discount_reason,
  m.agreement_approved_by,
  m.agreement_approved_at,
  m.updated_at,
  greatest(m.effective_teacher_entitlement - m.amount_due, 0)::numeric(14,2) as institution_funded,
  (m.amount_due = 0 and m.discount > 0) as scholarship,
  m.calculation_mode,
  (m.manual_teacher_share is not null) as is_exception,
  m.manual_adjustment_reason as exception_reason,
  round(m.base_fee * 0.50, 2)::numeric(12,2) as standard_teacher_share
from public.monthly_memberships m
join public.enrollments e on e.id = m.enrollment_id
join public.students s on s.id = e.student_id
join public.class_rooms c on c.id = e.class_id
join public.teachers t on t.id = m.teacher_id
left join lateral (
  select sum(amount) as paid_total from public.payments
  where monthly_membership_id = m.id and voided_at is null
) paid on true
where m.registration_active;

-- Teacher Class Month Totals view
create or replace view public.teacher_class_month_totals with (security_invoker=true) as
select
  m.period_id,
  e.class_id,
  min(m.class_title_snapshot) as class_name,
  m.teacher_id,
  t.full_name as teacher_name,
  count(*)::integer as student_count,
  coalesce(sum(m.original_fee), 0)::numeric(12,2) as base_total,
  coalesce(sum(m.discount), 0)::numeric(12,2) as discounts_total,
  coalesce(sum(m.effective_teacher_entitlement + 0), 0)::numeric(12,2) as teacher_entitlement,
  coalesce(sum(m.effective_office_entitlement + 0), 0)::numeric(12,2) as center_entitlement,
  coalesce(sum(f.paid_total), 0)::numeric(12,2) as received_total,
  coalesce((
    select sum(amount) from public.teacher_settlements ts
    where ts.period_id = m.period_id and ts.class_id = e.class_id
      and ts.teacher_id = m.teacher_id and ts.voided_at is null
  ), 0)::numeric(12,2) as settled_total,
  coalesce(sum(greatest(m.effective_teacher_entitlement - m.amount_due, 0)), 0)::numeric(14,2) as institution_funded
from public.monthly_memberships m
join public.enrollments e on e.id = m.enrollment_id
join public.class_rooms c on c.id = e.class_id
join public.teachers t on t.id = m.teacher_id
join public.month_fee_overview f on f.id = m.id
where m.registration_active
group by m.period_id, e.class_id, m.teacher_id, t.full_name;

-- Month Tuition Summary view
create or replace view public.month_tuition_summary with (security_invoker=true) as
select
  period_id,
  count(*)::bigint as registrations,
  count(distinct student_id)::bigint as unique_students,
  coalesce(sum(original_fee), 0) as original_total,
  coalesce(sum(discount), 0) as discounts_total,
  coalesce(sum(amount_due), 0) as payable_total,
  coalesce(sum(paid_total), 0) as received_total,
  coalesce(sum(balance_due), 0) as outstanding_total,
  coalesce(sum(teacher_entitlement), 0) as teacher_total,
  coalesce(sum(center_entitlement), 0) as office_total,
  coalesce(sum(institution_funded), 0) as institution_funded
from public.month_fee_overview
group by period_id;

-- Teacher Settlement Summary view
create or replace view public.teacher_settlement_summary with (security_invoker=true) as
select
  t.period_id,
  t.class_id,
  t.class_name,
  t.teacher_id,
  t.teacher_name,
  t.student_count,
  t.base_total,
  t.discounts_total,
  t.teacher_entitlement,
  t.center_entitlement,
  t.received_total,
  t.settled_total,
  (t.teacher_entitlement - t.settled_total) as remaining_settlement,
  case
    when t.teacher_entitlement = t.settled_total then 'settled'
    when t.settled_total > 0 then 'partial'
    else 'unpaid'
  end as settlement_status,
  t.institution_funded
from public.teacher_class_month_totals t;

-- Student previous history lookup RPC
create or replace function public.registration_previous(p_student uuid, p_month date) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not staff_has_any(array['admin','registrar']) then
    raise exception 'Registration access required' using errcode='42501';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(f) || jsonb_build_object('year_month', b.year_month) order by b.year_month desc, f.class_name, f.id)
    from month_fee_overview f
    join billing_periods b on b.id = f.period_id
    where f.student_id = p_student and b.year_month < p_month
  ), '[]'::jsonb);
end $$;

-- Teacher settlement recording RPC (admin only, idempotent)
create or replace function public.record_teacher_settlement(
  p_period uuid, p_class uuid, p_teacher uuid, p_amount numeric, p_date date,
  p_method text, p_note text, p_request uuid
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare
  row public.teacher_settlements%rowtype;
  result uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
  if not public.staff_has_any(array['admin']) then
    raise exception 'Financial access required';
  end if;
  if p_request is null or p_period is null or p_class is null or p_teacher is null
    or p_date is null or p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2)
    or p_method is null or p_method not in ('cash','bank','other') then
    raise exception 'Valid amount, date, method, and request ID required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
  select * into row from public.teacher_settlements where request_id = p_request;
  if found then
    if row.period_id <> p_period or row.class_id <> p_class or row.teacher_id <> p_teacher
      or row.amount <> p_amount or row.paid_on <> p_date or row.method <> p_method
      or row.note is distinct from p_note then
      raise exception 'Request ID reused with different data';
    end if;
    return row.id;
  end if;
  insert into public.teacher_settlements(period_id, class_id, teacher_id, amount, paid_on, method, note, request_id)
  values(p_period, p_class, p_teacher, p_amount, p_date, p_method, p_note, p_request) returning id into result;
  return result;
end $$;

-- Office month summary RPC including institution-funded obligation
create or replace function public.office_month_summary(p_month date) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  finish date := (p_month + interval '1 month')::date;
  tuition numeric;
  chapters numeric;
  printing numeric;
  costs numeric;
  entitlement numeric;
  office_entitlement numeric;
  settled numeric;
  outstanding numeric;
  institution_funded numeric;
begin
  if not public.staff_has_any(array['admin','accountant']) then
    raise exception 'Financial access required';
  end if;
  select coalesce(sum(amount),0) into tuition from public.payments
    where voided_at is null and paid_on >= p_month and paid_on < finish;
  select coalesce(sum(amount),0) into chapters from public.material_payments
    where chapter_sale_id is not null and voided_at is null and paid_on >= p_month and paid_on < finish;
  select coalesce(sum(total_print_cost),0) into printing from public.chapters
    where printing_cost_on >= p_month and printing_cost_on < finish;
  select coalesce(sum(amount),0) into costs from public.expenses
    where voided_at is null and spent_on >= p_month and spent_on < finish;
  select coalesce(sum(m.effective_teacher_entitlement),0) into entitlement
    from public.monthly_memberships m join public.billing_periods b on b.id = m.period_id
    where b.year_month = p_month and m.registration_active;
  select coalesce(sum(m.effective_office_entitlement),0) into office_entitlement
    from public.monthly_memberships m join public.billing_periods b on b.id = m.period_id
    where b.year_month = p_month and m.registration_active;
  select coalesce(sum(amount),0) into settled from public.teacher_settlements
    where voided_at is null and paid_on >= p_month and paid_on < finish;
  select coalesce(sum(quantity * unit_price - paid_total),0) into outstanding from public.chapter_sales;
  select coalesce(sum(greatest(m.effective_teacher_entitlement - m.amount_due, 0)),0) into institution_funded
    from public.monthly_memberships m join public.billing_periods b on b.id = m.period_id
    where b.year_month = p_month and m.registration_active;

  return jsonb_build_object(
    'tuition_collected', tuition,
    'chapter_collected', chapters,
    'chapter_outstanding', outstanding,
    'chapter_printing', printing,
    'chapter_net', chapters - printing,
    'gross_collected', tuition + chapters,
    'teacher_entitlement', entitlement,
    'office_entitlement', office_entitlement,
    'teacher_paid', settled,
    'expenses', costs,
    'institution_funded', institution_funded,
    'net_after_entitlement', tuition + chapters - entitlement - printing - costs,
    'cash_after_payments', tuition + chapters - settled - printing - costs
  );
end $$;

-- Permissions
revoke all on function public.guard_approved_agreement() from public, anon, authenticated;
revoke all on function public.update_monthly_agreement(uuid, jsonb, timestamptz) from public, anon, authenticated;
grant execute on function public.update_monthly_agreement(uuid, jsonb, timestamptz) to authenticated;
grant execute on function public.register_dashboard_student(jsonb, uuid) to authenticated;
grant execute on function public.registration_previous(uuid, date) to authenticated;
grant execute on function public.record_teacher_settlement(uuid, uuid, uuid, numeric, date, text, text, uuid) to authenticated;
grant execute on function public.office_month_summary(date) to authenticated;
grant select on public.month_fee_overview, public.teacher_class_month_totals, public.month_tuition_summary, public.teacher_settlement_summary to authenticated;

-- Keep staging intact and disable operational posting until Phase 2 is reviewed
revoke execute on function public.post_historical_import_batch(uuid, boolean) from public, anon, authenticated;

notify pgrst, 'reload schema';
commit;
