-- Confirmation states are derived from real receipts; no historical DML.
begin;
alter table public.monthly_memberships
 add column teacher_share_mode text check(teacher_share_mode in ('standard','custom')),
 add column teacher_share_reason text,
 add column sponsored_confirmed boolean not null default false,
 add column start_time_snapshot time,
 add column end_time_snapshot time;
create function public.guard_entitlement_confirmation() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if tg_op='INSERT' or (new.agreement_approved_at,new.manual_teacher_share,new.base_fee,new.teacher_share_mode,new.teacher_share_reason,new.sponsored_confirmed)
 is distinct from (old.agreement_approved_at,old.manual_teacher_share,old.base_fee,old.teacher_share_mode,old.teacher_share_reason,old.sponsored_confirmed) then
 if not staff_has_any(array['admin']) then raise exception 'Administrator approval required' using errcode='42501'; end if;
 if new.teacher_share_mode is null or (new.teacher_share_mode='standard' and coalesce(new.manual_teacher_share,round(new.base_fee/2,2))<>round(new.base_fee/2,2))
 or (new.teacher_share_mode='custom' and length(trim(coalesce(new.teacher_share_reason,'')))<4) then raise exception 'Approve the standard recommendation or provide a custom entitlement reason'; end if;
 if new.sponsored_confirmed and (new.base_fee<=0 or new.discount<>new.base_fee) then raise exception 'Sponsorship confirmation requires a full discount'; end if;
 end if;
 return new;
end $$;
create trigger entitlement_confirmation_guard before insert or update on public.monthly_memberships for each row execute function public.guard_entitlement_confirmation();
revoke all on function public.guard_entitlement_confirmation() from public,anon,authenticated;
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
    if coalesce((p_payload->>'duplicate_profile_confirmed')::boolean,false) is not true and exists(select 1 from students s
      where lower(trim(s.first_name))=lower(trim(p_payload->>'first_name')) and lower(trim(s.last_name))=lower(trim(coalesce(p_payload->>'last_name','')))
      and coalesce(trim(s.phone),'')=coalesce(trim(p_payload->>'phone'),'')) then raise exception 'Matching permanent profile exists; select it or explicitly confirm a different person' using errcode='P0002'; end if;
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
    is_exception := coalesce((item->>'custom_teacher_share')::boolean,false);
    if not is_exception and entitlement<>std_teacher_share then raise exception 'Standard recommendation does not match approved entitlement'; end if;

    if is_exception then
      v_teacher_share := entitlement;
      v_office_share := agreed - discount - entitlement;
      v_exception_reason := trim(coalesce(item->>'teacher_share_reason',''));
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
      proration_rule, registration_type, teacher_share_mode, teacher_share_reason, sponsored_confirmed, start_time_snapshot, end_time_snapshot
    ) values (
      period, enrollment, room.teacher_id, room.title, registration_date,
      original, agreed, discount, 0,
      v_teacher_share, v_office_share,
      v_exception_reason, v_adjusted_by, v_adjusted_at,
      auth.uid(), now(), item->>'discount_reason', item->>'arrangement_notes',
      'manual_agreement',
      case when nullif(p_payload->>'student_id','') is null then 'new' else 'returning' end, case when is_exception then 'custom' else 'standard' end, item->>'teacher_share_reason', coalesce((item->>'sponsored_confirmed')::boolean,false), room.start_time, room.end_time
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
  is_exception := coalesce((p_agreement->>'custom_teacher_share')::boolean,false);
  if not is_exception and entitlement<>std_teacher_share then raise exception 'Standard recommendation does not match approved entitlement'; end if;

  if is_exception then
    v_teacher_share := entitlement;
    v_office_share := agreed - financial_values.discount - entitlement;
    v_exception_reason := trim(coalesce(p_agreement->>'teacher_share_reason',''));
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
    teacher_share_mode=case when is_exception then 'custom' else 'standard' end,teacher_share_reason=p_agreement->>'teacher_share_reason',sponsored_confirmed=coalesce((p_agreement->>'sponsored_confirmed')::boolean,false),
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
  round(m.base_fee * 0.50, 2)::numeric(12,2) as standard_teacher_share,
 m.teacher_share_mode,m.teacher_share_reason,m.sponsored_confirmed,m.start_time_snapshot,m.end_time_snapshot,
 case when coalesce(paid.paid_total,0)>0 then 'registered'
 when m.sponsored_confirmed and m.amount_due=0 and m.discount=m.base_fee and m.base_fee>0 then 'fully_sponsored'
 else 'pending_payment' end as confirmation_status
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

create or replace function public.monthly_registration_summary(p_month date) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
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
 where b.year_month=p_month and m.registration_active and exists(select 1 from month_fee_overview f where f.id=m.id and f.confirmation_status in ('registered','fully_sponsored'))
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

create or replace view public.month_tuition_summary with (security_invoker=true) as
select
  period_id,
  count(*) filter(where confirmation_status in ('registered','fully_sponsored'))::bigint as registrations,
  count(distinct student_id) filter(where confirmation_status in ('registered','fully_sponsored'))::bigint as unique_students,
  coalesce(sum(original_fee), 0) as original_total,
  coalesce(sum(discount), 0) as discounts_total,
  coalesce(sum(amount_due), 0) as payable_total,
  coalesce(sum(paid_total), 0) as received_total,
  coalesce(sum(balance_due), 0) as outstanding_total,
  coalesce(sum(teacher_entitlement), 0) as teacher_total,
  coalesce(sum(center_entitlement), 0) as office_total,
  coalesce(sum(institution_funded), 0) as institution_funded, count(*) filter(where confirmation_status='pending_payment')::bigint as pending_registrations
from public.month_fee_overview
group by period_id;

create or replace function public.monthly_registration_list(p_month date,p_student uuid default null) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not public.is_staff() then raise exception 'Staff access required'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',m.id,'registration_active',m.registration_active,'registered_on',m.registered_on,
      'confirmation_status',case when not m.registration_active then 'cancelled' else (select f.confirmation_status from month_fee_overview f where f.id=m.id) end,
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
      'approved', true, 'custom_teacher_share', true, 'teacher_share_reason', p_reason, 'sponsored_confirmed', current_row.sponsored_confirmed
    ),
    current_row.updated_at
  );
end $$;
notify pgrst, 'reload schema';
commit;
