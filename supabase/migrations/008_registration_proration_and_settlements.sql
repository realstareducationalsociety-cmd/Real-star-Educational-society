begin;

alter table public.monthly_memberships
  add column original_fee numeric(12,2),
  add column proration_rule text not null default 'full_month'
    check (proration_rule in ('full_month','half_after_20th'));

update public.monthly_memberships set original_fee=base_fee where original_fee is null;
alter table public.monthly_memberships alter column original_fee set not null;

create function public.capture_monthly_original_fee() returns trigger
language plpgsql set search_path=public,pg_temp as $$
begin
  if new.original_fee is null then new.original_fee:=new.base_fee; end if;
  return new;
end $$;
create trigger monthly_original_fee_before_insert
  before insert on public.monthly_memberships
  for each row execute function public.capture_monthly_original_fee();

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
  m.manual_adjustment_reason,m.manual_adjusted_by,m.manual_adjusted_at,
  m.original_fee,m.proration_rule
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
  coalesce(sum(m.original_fee),0)::numeric(12,2) as base_total,
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

create or replace function public.register_monthly_student(
  p_month date,p_student_id uuid,p_first_name text,p_last_name text,p_guardian_name text,
  p_phone text,p_guardian_phone text,p_address text,p_registration_date date,p_class_ids uuid[],
  p_discount numeric default 0
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  period uuid;
  student uuid:=p_student_id;
  v_class_id uuid;
  class_row public.class_rooms%rowtype;
  enrollment uuid;
  membership public.monthly_memberships%rowtype;
  added integer:=0;
  class_count integer;
  applicable_fee numeric(12,2);
  fee_rule text;
  registration_kind text:=case when p_student_id is null then 'new' else 'returning' end;
begin
  if not public.staff_has_any(array['admin','registrar']) then
    raise exception 'Registration access required';
  end if;
  if p_month is null or extract(day from p_month)<>1 then
    raise exception 'Registration month is invalid';
  end if;
  if p_registration_date is null or p_registration_date<p_month
    or p_registration_date>=(p_month+interval '1 month')::date then
    raise exception 'Registration date must be in the selected month';
  end if;
  if p_class_ids is null or cardinality(p_class_ids)=0
    or cardinality(p_class_ids)<>(select count(distinct id) from unnest(p_class_ids) as u(id)) then
    raise exception 'Select at least one unique class';
  end if;
  if coalesce(p_discount,0)<0 or p_discount<>round(p_discount,2) then
    raise exception 'Discount amount is invalid';
  end if;
  p_discount:=coalesce(p_discount,0);
  if student is null and length(trim(coalesce(p_first_name,'')))=0 then
    raise exception 'Student first name is required';
  end if;

  fee_rule:=case when extract(day from p_registration_date)>20 then 'half_after_20th' else 'full_month' end;
  insert into public.billing_periods(year_month) values(p_month) on conflict(year_month) do nothing;
  select id into period from public.billing_periods
    where year_month=p_month and status='open' for update;
  if period is null then raise exception 'Selected month is closed'; end if;

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
      phone=nullif(trim(p_phone),''),guardian_phone=nullif(trim(p_guardian_phone),''),
      address=nullif(trim(p_address),''),active=true
      where id=student;
    if not found then raise exception 'Student not found'; end if;
  end if;

  class_count:=cardinality(p_class_ids);
  foreach v_class_id in array p_class_ids loop
    select * into class_row from public.class_rooms where id=v_class_id and active for update;
    if not found then raise exception 'Selected class is missing or inactive'; end if;
    applicable_fee:=case when fee_rule='half_after_20th'
      then round(class_row.default_fee/2,2) else class_row.default_fee end;
    if p_discount>applicable_fee/2 then
      raise exception 'Discount exceeds the permitted share of applicable tuition for class %',class_row.title;
    end if;

    insert into public.enrollments(student_id,class_id,enrolled_on,active)
      values(student,v_class_id,p_registration_date,true)
      on conflict(student_id,class_id) do update set active=true
      returning id into enrollment;

    select * into membership from public.monthly_memberships
      where period_id=period and enrollment_id=enrollment for update;
    if found then
      if membership.registration_active then
        raise exception 'Student is already registered in class % for this month',class_row.title;
      end if;
      if exists(select 1 from public.payments where monthly_membership_id=membership.id and voided_at is null) then
        raise exception 'A cancelled registration with payment cannot be reactivated';
      end if;
      if membership.manual_teacher_share is not null and not public.staff_has_any(array['admin']) then
        raise exception 'Only an administrator can renew a registration with manual shares';
      end if;
      update public.monthly_memberships set registration_active=true,
        registered_on=p_registration_date,base_fee=applicable_fee,original_fee=class_row.default_fee,
        proration_rule=fee_rule,discount=p_discount,teacher_discount_share=0,
        registration_type=registration_kind,
        manual_teacher_share=null,manual_office_share=null,manual_adjustment_reason=null,
        manual_adjusted_by=null,manual_adjusted_at=null
        where id=membership.id;
    else
      insert into public.monthly_memberships(
        period_id,enrollment_id,teacher_id,class_title_snapshot,registered_on,base_fee,original_fee,
        proration_rule,discount,registration_type
      ) values(period,enrollment,class_row.teacher_id,class_row.title,p_registration_date,
        applicable_fee,class_row.default_fee,fee_rule,p_discount,registration_kind);
    end if;
    added:=added+1;
  end loop;

  return jsonb_build_object('student_id',student,'student_code',
    (select student_code from public.students where id=student),
    'membership_count',added,'selected_classes',class_count);
end $$;

create or replace function public.monthly_registration_list(p_month date,p_student uuid default null) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not public.is_staff() then raise exception 'Staff access required'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',m.id,'registration_active',m.registration_active,'registered_on',m.registered_on,
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

create or replace function public.record_tuition_payment(
  p_membership uuid,p_amount numeric,p_date date,p_method text,p_note text,p_request uuid
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare row public.payments%rowtype;
begin
  perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
  if not public.staff_has_any(array['admin','accountant']) then
    raise exception 'Financial access required';
  end if;
  if p_request is null or p_membership is null or p_date is null
    or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2)
    or p_method is null or p_method not in ('cash','bank','other') then
    raise exception 'Valid amount, date, method, and request ID required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
  select * into row from public.payments where request_id=p_request;
  if found then
    if row.monthly_membership_id<>p_membership or row.amount<>p_amount
      or row.paid_on<>p_date or row.method<>p_method
      or row.reference_note is distinct from p_note then
      raise exception 'Request ID reused with different data';
    end if;
    return to_jsonb(row);
  end if;
  insert into public.payments(monthly_membership_id,amount,paid_on,method,reference_note,request_id)
  values(p_membership,p_amount,p_date,p_method,p_note,p_request) returning * into row;
  return to_jsonb(row);
end $$;

create function public.record_initial_registration_payment(
  p_membership uuid,p_amount numeric,p_date date,p_method text,p_note text
) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare membership public.monthly_memberships%rowtype; period_month date; period_status text;
begin
  if not public.staff_has_any(array['admin','registrar']) then
    raise exception 'Registration payment access required';
  end if;
  if p_membership is null or p_date is null or p_amount is null or p_amount<=0
    or p_amount<>round(p_amount,2) or p_method is null or p_method not in ('cash','bank','other') then
    raise exception 'Valid initial payment amount, date, and method required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
  select m.* into membership from public.monthly_memberships m
    where m.id=p_membership for update;
  if not found or not membership.registration_active then
    raise exception 'Active registration account not found';
  end if;
  select b.year_month,b.status into period_month,period_status
    from public.billing_periods b where b.id=membership.period_id for update;
  if period_status<>'open' or date_trunc('month',p_date)::date<>period_month then
    raise exception 'Initial payment date must belong to the open registration month';
  end if;
  insert into public.payments(monthly_membership_id,amount,paid_on,method,reference_note,request_id)
    values(p_membership,p_amount,p_date,p_method,p_note,gen_random_uuid());
end $$;

create or replace function public.register_dashboard_student(p_payload jsonb,p_request uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  prior public.registration_requests%rowtype;
  person public.students%rowtype;
  class_row public.class_rooms%rowtype;
  result jsonb;
  item jsonb;
  student uuid;
  membership uuid;
  period uuid;
  total integer:=0;
  payment numeric;
  discount numeric;
  standard_fee numeric;
  billable_fee numeric;
  registration_date date;
  requested_month date;
  payment_date date;
  payment_method text;
  payment_note text;
  rule text;
begin
  if not public.staff_has_any(array['admin','registrar']) then
    raise exception 'Registration access required';
  end if;
  if p_request is null or p_payload is null then
    raise exception 'Request ID and payload required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
  perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
  select * into prior from public.registration_requests where id=p_request;
  if found then
    if prior.actor_id<>auth.uid() or prior.payload<>p_payload or prior.kind<>'single' then
      raise exception 'Request ID reused with different data';
    end if;
    return prior.result;
  end if;

  requested_month:=(p_payload->>'month')::date;
  registration_date:=(p_payload->>'date')::date;
  if date_trunc('month',requested_month)::date<>requested_month
    or date_trunc('month',registration_date)::date<>requested_month then
    raise exception 'Registration date must be in the selected month';
  end if;
  if jsonb_typeof(p_payload->'classes') is distinct from 'array' then
    raise exception 'Select at least one class';
  end if;
  if jsonb_array_length(p_payload->'classes')=0 then
    raise exception 'Select at least one class';
  end if;
  if (select count(*) from jsonb_array_elements(p_payload->'classes')) <>
    (select count(distinct value->>'class_id') from jsonb_array_elements(p_payload->'classes')) then
    raise exception 'A class may be selected only once';
  end if;

  rule:=case when extract(day from registration_date)>20 then 'half_after_20th' else 'full_month' end;
  student:=nullif(p_payload->>'student_id','')::uuid;
  if student is not null then
    select * into person from public.students where id=student for update;
    if not found then raise exception 'Student not found'; end if;
  elsif length(trim(coalesce(p_payload->>'first_name','')))=0 then
    raise exception 'Student first name is required';
  end if;

  for item in select value from jsonb_array_elements(p_payload->'classes') loop
    select * into class_row from public.class_rooms
      where id=(item->>'class_id')::uuid and active for share;
    if not found then raise exception 'Selected active class not found'; end if;

    standard_fee:=class_row.default_fee;
    billable_fee:=case when rule='half_after_20th' then round(standard_fee/2,2) else standard_fee end;
    discount:=coalesce(nullif(item->>'discount','')::numeric,0);
    payment:=coalesce(nullif(item->>'payment','')::numeric,0);
    if discount<0 or discount<>round(discount,2) or discount>billable_fee/2 then
      raise exception 'Discount exceeds the permitted share of applicable tuition';
    end if;
    if payment<0 or payment<>round(payment,2) or payment>billable_fee-discount then
      raise exception 'Initial payment exceeds the amount due';
    end if;

    result:=public.register_monthly_student(
      requested_month,student,
      case when student is null then p_payload->>'first_name' else person.first_name end,
      case when student is null then p_payload->>'last_name' else person.last_name end,
      case when student is null then p_payload->>'guardian_name' else person.guardian_name end,
      case when student is null then p_payload->>'phone' else person.phone end,
      case when student is null then p_payload->>'guardian_phone' else person.guardian_phone end,
      case when student is null then p_payload->>'address' else person.address end,
      registration_date,array[class_row.id],discount
    );
    student:=(result->>'student_id')::uuid;
    select * into person from public.students where id=student;
    select id into period from public.billing_periods where year_month=requested_month;
    select m.id into membership from public.monthly_memberships m
      join public.enrollments e on e.id=m.enrollment_id
      where m.period_id=period and e.student_id=student
        and e.class_id=class_row.id and m.registration_active for update of m;
    if membership is null then raise exception 'Registered class account was not created'; end if;

    update public.monthly_memberships
      set base_fee=billable_fee,original_fee=standard_fee,proration_rule=rule
      where id=membership;
    if nullif(p_payload->>'student_id','') is null then
      update public.monthly_memberships set registration_type='new' where id=membership;
      update public.students set notes=p_payload->>'notes' where id=student;
    end if;

    if payment>0 then
      payment_date:=nullif(item->>'paid_on','')::date;
      payment_method:=nullif(item->>'payment_method','');
      if payment_date is null or date_trunc('month',payment_date)::date<>requested_month then
        raise exception 'Enter the actual payment date in the selected month';
      end if;
      if payment_method is null or payment_method not in ('cash','bank','other') then
        raise exception 'Choose the actual payment method';
      end if;
      payment_note:=concat_ws(' | ',nullif(trim(item->>'payment_reference'),''),nullif(trim(item->>'payment_note'),''));
      perform public.record_initial_registration_payment(membership,payment,payment_date,payment_method,
        nullif(payment_note,''));
    end if;
    total:=total+1;
  end loop;

  result:=jsonb_build_object('student_id',student,'student_code',person.student_code,'membership_count',total);
  insert into public.registration_requests values(p_request,auth.uid(),'single',p_payload,result,now());
  return result;
end $$;

alter table public.teacher_settlements
  add column method text not null default 'cash'
    check (method in ('cash','bank','other'));

create function public.record_teacher_settlement(
  p_period uuid,p_class uuid,p_teacher uuid,p_amount numeric,p_date date,
  p_method text,p_note text,p_request uuid
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare row public.teacher_settlements%rowtype; result uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
  if not public.staff_has_any(array['admin','accountant']) then
    raise exception 'Financial access required';
  end if;
  if p_request is null or p_period is null or p_class is null or p_teacher is null
    or p_date is null or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2)
    or p_method is null or p_method not in ('cash','bank','other') then
    raise exception 'Valid amount, date, method, and request ID required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
  select * into row from public.teacher_settlements where request_id=p_request;
  if found then
    if row.period_id<>p_period or row.class_id<>p_class or row.teacher_id<>p_teacher
      or row.amount<>p_amount or row.paid_on<>p_date or row.method<>p_method
      or row.note is distinct from p_note then
      raise exception 'Request ID reused with different data';
    end if;
    return row.id;
  end if;
  insert into public.teacher_settlements(period_id,class_id,teacher_id,amount,paid_on,method,note,request_id)
  values(p_period,p_class,p_teacher,p_amount,p_date,p_method,p_note,p_request) returning id into result;
  return result;
end $$;

create function public.teacher_settlement_history(p_period uuid,p_class uuid,p_teacher uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not public.staff_has_any(array['admin','accountant']) then
    raise exception 'Financial access required';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(ts)||jsonb_build_object(
      'recorded_by',coalesce(nullif(trim(sp.full_name),''),ts.paid_by::text)
    ) order by ts.created_at desc)
    from public.teacher_settlements ts
    left join public.staff_profiles sp on sp.id=ts.paid_by
    where ts.period_id=p_period and ts.class_id=p_class and ts.teacher_id=p_teacher
  ),'[]'::jsonb);
end $$;

revoke all on function public.record_teacher_settlement(uuid,uuid,uuid,numeric,date,text,uuid)
  from public,anon,authenticated;
revoke all on function public.capture_monthly_original_fee(),
  public.record_initial_registration_payment(uuid,numeric,date,text,text),
  public.record_teacher_settlement(uuid,uuid,uuid,numeric,date,text,text,uuid),
  public.teacher_settlement_history(uuid,uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.record_tuition_payment(uuid,numeric,date,text,text,uuid),
  public.register_dashboard_student(jsonb,uuid),
  public.record_teacher_settlement(uuid,uuid,uuid,numeric,date,text,text,uuid),
  public.teacher_settlement_history(uuid,uuid,uuid)
  to authenticated;

commit;
