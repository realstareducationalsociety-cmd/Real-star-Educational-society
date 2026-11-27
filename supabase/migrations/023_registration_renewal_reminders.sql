-- Per-class, consent-gated WhatsApp renewal reminders. This migration never sends messages.
begin;

alter table public.students
  add column if not exists renewal_reminder_recipient text not null default 'guardian';
do $$ begin
  if not exists (select 1 from pg_constraint where conname='students_renewal_reminder_recipient_check') then
    alter table public.students add constraint students_renewal_reminder_recipient_check
      check (renewal_reminder_recipient in ('student','guardian'));
  end if;
end $$;

create or replace function public.whatsapp_phone_e164(p_phone text) returns text
language plpgsql immutable parallel safe set search_path=public,pg_temp as $$
declare digits text;
begin
  if coalesce(p_phone,'') !~ '^[+0-9() .-]+$'
     or length(regexp_replace(coalesce(p_phone,''),'[^+]','','g'))>1
     or (position('+' in coalesce(p_phone,''))>0 and position('+' in coalesce(p_phone,''))<>position('+' in ltrim(coalesce(p_phone,'')))) then
    return null;
  end if;
  digits:=regexp_replace(coalesce(p_phone,''),'[^0-9]','','g');
  if left(digits,2)='00' then digits:=substr(digits,3); end if;
  if length(digits)=11 and left(digits,2)='03' then digits:='92'||substr(digits,2);
  elsif length(digits)=10 and left(digits,1)='3' then digits:='92'||digits;
  elsif length(digits)=10 and left(digits,2)='07' then digits:='93'||substr(digits,2);
  elsif length(digits)=9 and left(digits,1)='7' then digits:='93'||digits;
  end if;
  if digits !~ '^[1-9][0-9]{7,14}$' then return null; end if;
  -- Enforce mobile number lengths for supported Pakistan and Afghanistan country codes.
  if left(digits,2)='92' and (length(digits)<>12 or substr(digits,3,1)<>'3') then return null; end if;
  if left(digits,2)='93' and (length(digits)<>11 or substr(digits,3,1)<>'7') then return null; end if;
  return digits;
end $$;
revoke all on function public.whatsapp_phone_e164(text) from public,anon,authenticated;

create table if not exists public.guardian_message_consents (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id),
  recipient_type text not null check(recipient_type in ('student','guardian')),
  phone_e164 text not null check(phone_e164 ~ '^[1-9][0-9]{7,14}$'),
  is_active boolean not null default true,
  granted_at timestamptz not null default now(),
  granted_by uuid not null references auth.users(id),
  revoked_at timestamptz,
  revoked_by uuid references auth.users(id),
  consent_note text not null check(length(trim(consent_note))>=4),
  created_at timestamptz not null default now(),
  unique(student_id,recipient_type,phone_e164),
  check((is_active and revoked_at is null and revoked_by is null) or not is_active)
);
alter table public.guardian_message_consents enable row level security;
revoke all on public.guardian_message_consents from public,anon,authenticated;
drop trigger if exists audit_guardian_message_consents on public.guardian_message_consents;
create trigger audit_guardian_message_consents after insert or update on public.guardian_message_consents
  for each row execute function public.audit_record();

create table if not exists public.registration_renewal_reminder_sends (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references public.enrollments(id),
  due_period date not null check(extract(day from due_period)=1),
  student_id uuid not null references public.students(id),
  recipient_type text not null check(recipient_type in ('student','guardian')),
  phone_e164 text not null check(phone_e164 ~ '^[1-9][0-9]{7,14}$'),
  consent_id uuid not null references public.guardian_message_consents(id),
  sent_confirmed_at timestamptz not null default now(),
  confirmed_by uuid not null references auth.users(id),
  confirmation_note text not null check(length(trim(confirmation_note))>=4),
  created_at timestamptz not null default now(),
  unique(enrollment_id,due_period)
);
alter table public.registration_renewal_reminder_sends enable row level security;
revoke all on public.registration_renewal_reminder_sends from public,anon,authenticated;
drop trigger if exists audit_registration_renewal_reminder_sends on public.registration_renewal_reminder_sends;
create trigger audit_registration_renewal_reminder_sends after insert or update on public.registration_renewal_reminder_sends
  for each row execute function public.audit_record();

create or replace function public.guard_renewal_reminder_recipient()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.renewal_reminder_recipient is distinct from old.renewal_reminder_recipient
     and not public.staff_has_any(array['admin']) then
    raise exception 'Administrator access required to change the default message recipient' using errcode='42501';
  end if;
  return new;
end $$;
revoke all on function public.guard_renewal_reminder_recipient() from public,anon,authenticated;
drop trigger if exists guard_renewal_reminder_recipient_update on public.students;
create trigger guard_renewal_reminder_recipient_update before update of renewal_reminder_recipient on public.students
  for each row execute function public.guard_renewal_reminder_recipient();

create or replace function public.set_renewal_reminder_recipient(p_student uuid,p_recipient text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not public.staff_has_any(array['admin']) then raise exception 'Administrator access required' using errcode='42501'; end if;
  if p_recipient not in ('student','guardian') then raise exception 'Invalid reminder recipient'; end if;
  update public.students set renewal_reminder_recipient=p_recipient where id=p_student;
  if not found then raise exception 'Student not found'; end if;
end $$;

create or replace function public.get_student_renewal_message_consents(p_student uuid)
returns table(recipient_type text,phone_e164 text,is_active boolean,consent_note text,granted_at timestamptz,revoked_at timestamptz)
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not public.staff_has_any(array['admin']) then raise exception 'Administrator access required' using errcode='42501'; end if;
  return query select c.recipient_type,c.phone_e164,c.is_active,c.consent_note,c.granted_at,c.revoked_at
    from public.guardian_message_consents c where c.student_id=p_student order by c.created_at desc;
end $$;

-- Explicit phone is essential: revocation remains possible after the contact number changes.
create or replace function public.record_guardian_message_consent(p_student uuid,p_recipient text,p_phone text,p_consented boolean,p_note text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_phone text; v_current text; v_id uuid;
begin
  if not public.staff_has_any(array['admin']) then raise exception 'Administrator access required' using errcode='42501'; end if;
  if p_student is null or p_recipient not in ('student','guardian') or p_consented is null or length(trim(coalesce(p_note,'')))<4 then
    raise exception 'Student, recipient, consent choice and audit note are required';
  end if;
  v_phone:=public.whatsapp_phone_e164(p_phone);
  if v_phone is null then raise exception 'A valid WhatsApp mobile number is required'; end if;
  select public.whatsapp_phone_e164(case when p_recipient='student' then phone else guardian_phone end)
    into v_current from public.students where id=p_student for update;
  if not found then raise exception 'Student not found'; end if;
  if p_consented and v_current is distinct from v_phone then
    raise exception 'Consent can only be granted for the current contact number';
  end if;
  if p_consented then
    insert into public.guardian_message_consents(student_id,recipient_type,phone_e164,is_active,granted_by,consent_note)
    values(p_student,p_recipient,v_phone,true,auth.uid(),trim(p_note))
    on conflict(student_id,recipient_type,phone_e164) do update set is_active=true,granted_at=now(),granted_by=auth.uid(),revoked_at=null,revoked_by=null,consent_note=excluded.consent_note
    returning id into v_id;
  else
    update public.guardian_message_consents set is_active=false,revoked_at=now(),revoked_by=auth.uid(),consent_note=trim(p_note)
      where student_id=p_student and recipient_type=p_recipient and phone_e164=v_phone returning id into v_id;
    if v_id is null then raise exception 'No recorded consent exists for this number'; end if;
  end if;
  return jsonb_build_object('consent_id',v_id,'is_active',p_consented,'phone_e164',v_phone,'recipient_type',p_recipient);
end $$;

create or replace function public.get_registration_renewal_reminders()
returns table(
  enrollment_id uuid,student_id uuid,student_name text,class_name text,guardian_name text,
  student_phone text,guardian_phone text,student_whatsapp_phone text,guardian_whatsapp_phone text,
  default_recipient text,registered_on date,due_on date,due_period date,
  student_has_consent boolean,guardian_has_consent boolean,consent_history jsonb,
  reminder_status text,sent_confirmed_at timestamptz,confirmation_note text,sent_recipient text
)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_today date:=(now() at time zone 'Asia/Karachi')::date; v_admin boolean;
begin
  if not public.staff_has_any(array['admin','registrar']) then raise exception 'Education access required' using errcode='42501'; end if;
  v_admin:=public.staff_has_any(array['admin']);
  return query
  with latest_registration as (
    select distinct on (e.id)
      e.id as enrollment_key,e.student_id,e.class_id,
      s.first_name,s.last_name,s.guardian_name,s.phone as student_phone,s.guardian_phone,
      s.renewal_reminder_recipient as default_contact,
      c.title as class_title,m.registered_on as registration_date,
      (b.year_month + interval '1 month')::date as next_period,
      public.whatsapp_phone_e164(s.phone) as student_phone_e164,
      public.whatsapp_phone_e164(s.guardian_phone) as guardian_phone_e164
    from public.enrollments e
    join public.students s on s.id=e.student_id and s.active
    join public.class_rooms c on c.id=e.class_id and c.active
    join public.monthly_memberships m on m.enrollment_id=e.id and m.registration_active
    join public.billing_periods b on b.id=m.period_id
    where e.active and b.year_month<=date_trunc('month',v_today)::date
    order by e.id,b.year_month desc,m.registered_on desc,m.id desc
  ), due as (
    select l.*,(l.registration_date + interval '1 month')::date as renewal_date
    from latest_registration l
    where (l.registration_date + interval '1 month')::date<=v_today
      and not exists (
        select 1 from public.monthly_memberships next_m
        join public.billing_periods next_b on next_b.id=next_m.period_id
        where next_m.enrollment_id=l.enrollment_key and next_b.year_month=l.next_period and next_m.registration_active
      )
  )
  select d.enrollment_key,d.student_id,concat_ws(' ',d.first_name,d.last_name),d.class_title,d.guardian_name,
    case when v_admin then d.student_phone else null end,
    case when v_admin then d.guardian_phone else null end,
    case when v_admin then d.student_phone_e164 else null end,
    case when v_admin then d.guardian_phone_e164 else null end,
    d.default_contact,d.registration_date,d.renewal_date,d.next_period,
    v_admin and exists(select 1 from public.guardian_message_consents c where c.student_id=d.student_id and c.recipient_type='student' and c.phone_e164=d.student_phone_e164 and c.is_active),
    v_admin and exists(select 1 from public.guardian_message_consents c where c.student_id=d.student_id and c.recipient_type='guardian' and c.phone_e164=d.guardian_phone_e164 and c.is_active),
    case when v_admin then coalesce((select jsonb_agg(jsonb_build_object('recipient_type',c.recipient_type,'phone_e164',c.phone_e164,'is_active',c.is_active,'consent_note',c.consent_note,'granted_at',c.granted_at,'revoked_at',c.revoked_at) order by c.created_at desc) from public.guardian_message_consents c where c.student_id=d.student_id),'[]'::jsonb) else '[]'::jsonb end,
    case when sent.id is null then 'pending' else 'sent_confirmed' end,
    sent.sent_confirmed_at,sent.confirmation_note,sent.recipient_type
  from due d
  left join public.registration_renewal_reminder_sends sent on sent.enrollment_id=d.enrollment_key and sent.due_period=d.next_period
  order by d.renewal_date,d.class_title,d.first_name,d.last_name;
end $$;

create or replace function public.confirm_registration_renewal_reminder_sent(p_enrollment uuid,p_due_period date,p_recipient text,p_note text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_due record; v_phone text; v_consent uuid; v_id uuid;
begin
  if not public.staff_has_any(array['admin']) then raise exception 'Administrator access required' using errcode='42501'; end if;
  if p_enrollment is null or p_due_period is null or extract(day from p_due_period)<>1 or p_recipient not in ('student','guardian') or length(trim(coalesce(p_note,'')))<4 then
    raise exception 'Enrollment, valid period, recipient and manual-send confirmation note are required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_enrollment::text||'|'||p_due_period::text,0));
  select * into v_due from public.get_registration_renewal_reminders() r where r.enrollment_id=p_enrollment and r.due_period=p_due_period;
  if not found then raise exception 'This class has no eligible pending renewal reminder'; end if;
  if v_due.reminder_status='sent_confirmed' then
    select id into v_id from public.registration_renewal_reminder_sends where enrollment_id=p_enrollment and due_period=p_due_period;
    return v_id;
  end if;
  v_phone:=case when p_recipient='student' then v_due.student_whatsapp_phone else v_due.guardian_whatsapp_phone end;
  if v_phone is null then raise exception 'Valid WhatsApp contact and recorded consent are required'; end if;
  select id into v_consent from public.guardian_message_consents where student_id=v_due.student_id and recipient_type=p_recipient and phone_e164=v_phone and is_active;
  if v_consent is null then raise exception 'Valid WhatsApp contact and recorded consent are required'; end if;
  insert into public.registration_renewal_reminder_sends(enrollment_id,due_period,student_id,recipient_type,phone_e164,consent_id,confirmed_by,confirmation_note)
  values(p_enrollment,p_due_period,v_due.student_id,p_recipient,v_phone,v_consent,auth.uid(),trim(p_note))
  on conflict(enrollment_id,due_period) do nothing returning id into v_id;
  if v_id is null then select id into v_id from public.registration_renewal_reminder_sends where enrollment_id=p_enrollment and due_period=p_due_period; end if;
  return v_id;
end $$;

revoke all on function public.set_renewal_reminder_recipient(uuid,text),public.get_student_renewal_message_consents(uuid),public.record_guardian_message_consent(uuid,text,text,boolean,text),public.get_registration_renewal_reminders(),public.confirm_registration_renewal_reminder_sent(uuid,date,text,text) from public,anon,authenticated;
grant execute on function public.set_renewal_reminder_recipient(uuid,text),public.get_student_renewal_message_consents(uuid),public.record_guardian_message_consent(uuid,text,text,boolean,text),public.get_registration_renewal_reminders(),public.confirm_registration_renewal_reminder_sent(uuid,date,text,text) to authenticated;

notify pgrst,'reload schema';
commit;
