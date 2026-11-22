-- 013_november_import_review.sql
-- Administrator-reviewed operational import of the EXISTING November 2026 staging batch.
-- Principles enforced here:
--   * No new staging rows and no workbook re-import: the batch is located by its SHA-256 checksum.
--   * Teachers and class rooms are matched against the live operational records, never duplicated.
--   * Nothing is posted without an explicit administrator approval of identity, class mapping and money.
--   * Financial agreement rules from 010/011 are honoured (standard 50% entitlement, approved
--     exceptions with a reason, 100% discounts, institution-funded teacher obligations).
--   * No payment transaction is manufactured: a payment row is only written from a verified source receipt.
begin;

-- ---------------------------------------------------------------------------
-- 0. November 2026 must be an open billing period before anything is posted
-- ---------------------------------------------------------------------------
insert into public.billing_periods(year_month,status)
values('2026-11-01','open')
on conflict(year_month) do update set status='open';

-- ---------------------------------------------------------------------------
-- 1. Helper functions: tolerant value readers used by the candidate builder
-- ---------------------------------------------------------------------------
create or replace function public.november_import_first(p_payload jsonb, p_keys text[])
returns text language sql immutable set search_path=public,pg_temp as $$
  select nullif(trim(v.value),'')
  from unnest(p_keys) with ordinality as k(key,ord)
  cross join lateral (select coalesce(p_payload->>k.key,'') as value) v
  where trim(v.value) <> ''
  order by k.ord
  limit 1
$$;

create or replace function public.november_import_number(p_value text)
returns numeric language plpgsql immutable set search_path=public,pg_temp as $$
declare m text[];
begin
  if p_value is null then return null; end if;
  m := regexp_match(p_value,'(-?[0-9]+(?:\.[0-9]+)?)');
  if m is null then return null; end if;
  begin
    return round(m[1]::numeric,2);
  exception when others then
    return null;
  end;
end $$;

create or replace function public.november_import_date(p_value text)
returns date language plpgsql immutable set search_path=public,pg_temp as $$
declare m text[];
begin
  if p_value is null or trim(p_value)='' then return null; end if;
  if trim(p_value) ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' then
    begin
      return substring(trim(p_value) from 1 for 10)::date;
    exception when others then
      return null;
    end;
  end if;
  m := regexp_match(trim(p_value),'([0-9]{1,2})[/-]([0-9]{1,2})[/-]([0-9]{2,4})');
  if m is null then return null; end if;
  begin
    return make_date(
      case when length(m[3])=2 then 2000 + m[3]::integer else m[3]::integer end,
      m[2]::integer, m[1]::integer);
  exception when others then
    return null;
  end;
end $$;

create or replace function public.november_import_parse_hour(p_text text)
returns integer language plpgsql immutable set search_path=public,pg_temp as $$
declare m text[]; h integer; ap text;
begin
  if p_text is null or trim(p_text)='' then return null; end if;
  m := regexp_match(lower(p_text),'([0-9]{1,2})\s*:?\s*([0-9]{2})?\s*(am|pm)?');
  if m is null then return null; end if;
  h := m[1]::integer;
  ap := m[3];
  if ap = 'pm' and h < 12 then h := h + 12;
  elsif ap = 'am' and h = 12 then h := 0;
  elsif ap is null and h between 1 and 9 then h := h + 12;
  end if;
  return h;
end $$;

-- Class titles in the source workbook are abbreviated ('FF 1', 'A2', 'Get 1', 'Excel').
create or replace function public.november_import_class_title(p_title text)
returns text language plpgsql immutable set search_path=public,pg_temp as $$
declare t text := trim(coalesce(p_title,''));
declare u text := upper(regexp_replace(t,'\s+',' ','g'));
begin
  if t = '' then return null; end if;
  if u in ('A2','A 2','SPECIAL A2') then return 'Special A2'; end if;
  if u in ('B1','B 1','SPECIAL B1') then return 'Special B1'; end if;
  if u in ('B2','B 2','SPECIAL B2') then return 'Special B2'; end if;
  if u in ('FF 1','FF1','F&F 1','FAMILY & FRIENDS 1') then return 'Family & Friends 1'; end if;
  if u in ('FF 2','FF2','F&F 2','FAMILY & FRIENDS 2') then return 'Family & Friends 2'; end if;
  if u in ('FF 3','FF3','F&F 3','FAMILY & FRIENDS 3') then return 'Family & Friends 3'; end if;
  if u in ('FF 4','FF4','F&F 4','FAMILY & FRIENDS 4') then return 'Family & Friends 4'; end if;
  if u in ('GET 1','GET INVOLVED 1','GET1') then return 'Get Involved 1'; end if;
  if u in ('GET 2','GET INVOLVED 2','GET2') then return 'Get Involved 2'; end if;
  if u in ('EXCEL','COMPUTER','COMPUTER MS EXCEL','MS EXCEL') then return 'Computer MS Excel'; end if;
  if u in ('INTERMADIATE','INTERMEDIATE','INTERMADIATE CLASS','INTERMEDIATE CLASS') then return 'Intermadiate class'; end if;
  if u in ('ADVANCE','ADVANCED','ADVANCE CLASS','ADVANCED CLASS') then return 'Advance class'; end if;
  if u in ('STARTER','FF 1 STARTER','FAMILY & FRIENDS 1 (STARTER)') then return 'Family & Friends 1 (Starter)'; end if;
  return t;
end $$;

create or replace function public.november_import_identity_key(p_name text, p_phone text)
returns text language sql immutable set search_path=public,pg_temp as $$
  select case when coalesce(trim(p_name),'')='' then null
    else lower(regexp_replace(trim(p_name),'[^a-zA-Z0-9]+',' ','g'))
      || '|' || lower(coalesce(regexp_replace(trim(coalesce(p_phone,'')),'[^0-9]+','','g'),''))
  end
$$;

-- ---------------------------------------------------------------------------
-- 2. Student identity mapping: one person may sit in several November classes
-- ---------------------------------------------------------------------------
create table if not exists public.november_import_students (
  batch_id uuid not null references public.historical_import_batches(id) on delete cascade,
  identity_key text not null check(length(trim(identity_key)) between 1 and 300),
  student_id uuid not null references public.students(id),
  created_new boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  primary key(batch_id,identity_key)
);

-- ---------------------------------------------------------------------------
-- 3. Administrator review queue for the 206 November registration candidates
-- ---------------------------------------------------------------------------
create table if not exists public.november_import_candidates (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.historical_import_batches(id) on delete cascade,
  source_row_id uuid not null unique references public.historical_import_source_rows(id) on delete cascade,
  source_sheet text not null,
  source_key text not null,
  source_row integer not null,
  source_month text,
  identity_key text,
  student_name text,
  first_name text not null default '',
  last_name text not null default '',
  phone text,
  proposed_student_id uuid references public.students(id),
  proposed_student_label text,
  match_confidence text,
  class_id uuid references public.class_rooms(id),
  class_title text,
  teacher_id uuid references public.teachers(id),
  teacher_name text,
  start_time time,
  end_time time,
  schedule_label text,
  source_tuition numeric(12,2) not null default 0,
  source_discount numeric(12,2) not null default 0,
  source_payment numeric(12,2) not null default 0,
  source_payment_date date,
  source_payment_reference text,
  approved_student_action text check (approved_student_action in ('create','match')),
  approved_student_id uuid references public.students(id),
  approved_class_id uuid references public.class_rooms(id),
  approved_tuition numeric(12,2),
  approved_discount numeric(12,2),
  approved_discount_reason text,
  approved_teacher_entitlement numeric(12,2),
  approved_teacher_exception_reason text,
  approved_payment numeric(12,2),
  approved_payment_date date,
  approved_payment_method text check (approved_payment_method in ('cash','bank','other')),
  approved_registered_on date,
  approved_note text,
  status text not null default 'needs_review'
    check (status in ('needs_review','approved','posted','duplicate','rejected')),
  blocking_reasons jsonb not null default '[]'::jsonb
    check (jsonb_typeof(blocking_reasons)='array'),
  review_note text,
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  posted_at timestamptz,
  student_id uuid references public.students(id),
  enrollment_id uuid references public.enrollments(id),
  membership_id uuid references public.monthly_memberships(id),
  payment_id uuid references public.payments(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists november_candidates_status_idx
  on public.november_import_candidates(status,source_sheet,source_row);
create index if not exists november_candidates_identity_idx
  on public.november_import_candidates(batch_id,identity_key);

drop trigger if exists touch_november_candidates on public.november_import_candidates;
create trigger touch_november_candidates before update on public.november_import_candidates
  for each row execute function public.touch_updated_at();

alter table public.november_import_candidates enable row level security;
alter table public.november_import_students enable row level security;

drop policy if exists november_candidates_admin_read on public.november_import_candidates;
create policy november_candidates_admin_read on public.november_import_candidates
  for select to authenticated using (public.staff_has_any(array['admin']));
drop policy if exists november_students_admin_read on public.november_import_students;
create policy november_students_admin_read on public.november_import_students
  for select to authenticated using (public.staff_has_any(array['admin']));

revoke all on public.november_import_candidates, public.november_import_students
  from public, anon, authenticated;
grant select on public.november_import_candidates, public.november_import_students
  to authenticated;
create or replace function public.november_import_name_key(p_name text)
returns text language sql immutable set search_path=public,pg_temp as $$
  select nullif(lower(regexp_replace(trim(coalesce(p_name,'')),'[^a-zA-Z0-9]+',' ','g')),'')
$$;

-- ---------------------------------------------------------------------------
-- 4. Matching against the LIVE teachers and class rooms (never duplicate them)
-- ---------------------------------------------------------------------------
create or replace function public.november_import_match_teacher(p_name text)
returns uuid language plpgsql stable set search_path=public,pg_temp as $$
declare n text; result uuid;
begin
  n := lower(regexp_replace(trim(coalesce(p_name,'')),'\s+',' ','g'));
  if n = '' then return null; end if;
  select t.id into result from public.teachers t
   where lower(regexp_replace(trim(t.full_name),'\s+',' ','g')) = n
   order by t.active desc, t.created_at
   limit 1;
  if result is not null then return result; end if;
  select scored.id into result from (
    select t.id, max(length(tok)) as score
    from public.teachers t
    cross join lateral regexp_split_to_table(
      lower(regexp_replace(trim(t.full_name),'\s+',' ','g')),' ') tok
    where length(tok) >= 3
      and (n = tok or n like '%'||tok||'%' or tok like '%'||n||'%')
    group by t.id
  ) scored
  order by scored.score desc
  limit 1;
  return result;
end $$;

create or replace function public.november_import_match_class(
  p_title text, p_teacher text, p_schedule text
) returns uuid language plpgsql stable set search_path=public,pg_temp as $$
declare
  ntitle text := public.november_import_class_title(p_title);
  tid uuid := public.november_import_match_teacher(p_teacher);
  h integer := public.november_import_parse_hour(p_schedule);
  result uuid;
begin
  if ntitle is null then return null; end if;

  if tid is not null and h is not null then
    select c.id into result from public.class_rooms c
     where lower(trim(c.title)) = lower(ntitle) and c.teacher_id = tid
       and extract(hour from c.start_time) = h
     order by c.active desc, c.created_at limit 1;
    if result is not null then return result; end if;
  end if;

  if tid is not null then
    select c.id into result from public.class_rooms c
     where lower(trim(c.title)) = lower(ntitle) and c.teacher_id = tid
     order by c.active desc, c.created_at limit 1;
    if result is not null then return result; end if;
  end if;

  if h is not null then
    select c.id into result from public.class_rooms c
     where lower(trim(c.title)) = lower(ntitle) and extract(hour from c.start_time) = h
     order by c.active desc, c.created_at limit 1;
    if result is not null then return result; end if;
  end if;

  select c.id into result from public.class_rooms c
   where lower(trim(c.title)) = lower(ntitle)
   order by c.active desc, c.created_at limit 1;
  if result is not null then return result; end if;

  select c.id into result from public.class_rooms c
   where lower(trim(c.title)) like lower(ntitle)||'%'
      or lower(ntitle) like lower(trim(c.title))||'%'
   order by length(c.title), c.active desc, c.created_at limit 1;
  return result;
end $$;
-- ---------------------------------------------------------------------------
-- 5. Build the review queue from the EXISTING staged rows (no new staging rows)
-- ---------------------------------------------------------------------------
create or replace function public.build_november_import_candidates(p_sha256 text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
#variable_conflict use_variable
declare
  v_batch uuid;
  r record;
  v_name text; v_first text; v_last text; v_phone text;
  v_class_source text; v_teacher_source text; v_time text; v_month text;
  v_class_id uuid; v_teacher_id uuid; v_teacher_name text; v_class_title text;
  v_tuition numeric; v_discount numeric;
  v_pay numeric; v_pay_date date; v_pay_ref text; v_pay_key text;
  v_pay_count integer; v_pay_ambiguity boolean;
  v_identity text;
  v_match_count integer; v_match_id uuid; v_match_label text; v_confidence text;
  v_reasons jsonb;
  v_nameless text;
begin
  if not public.staff_has_any(array['admin']) then
    raise exception 'Administrator approval required' using errcode='42501';
  end if;
  select b.id into v_batch from public.historical_import_batches b
    where lower(trim(b.source_sha256)) = lower(trim(coalesce(p_sha256,'')));
  if v_batch is null then
    raise exception 'No import batch exists with checksum %', coalesce(p_sha256,'(none)');
  end if;

  for r in
    select s.id, s.source_key, s.source_sheet, s.source_row, s.source_payload
    from public.historical_import_source_rows s
    where s.batch_id = v_batch
      and s.source_sheet in ('Registrations','RegistrationLeads')
    order by s.source_sheet, s.source_row
  loop
    v_reasons := '[]'::jsonb;

    v_name := public.november_import_first(r.source_payload,
      array['Full Name','Name','Student Name','Student']);
    if v_name is null then
      v_name := nullif(concat_ws(' ',
        public.november_import_first(r.source_payload,array['First Name']),
        public.november_import_first(r.source_payload,array['Last Name'])),'');
    end if;

    v_nameless := public.november_import_name_key(v_name);
    v_first := coalesce(
      public.november_import_first(r.source_payload,array['First Name']),
      case when v_name is null then '' else split_part(v_name,' ',1) end,'');
    v_last := coalesce(
      public.november_import_first(r.source_payload,array['Last Name']),
      case when v_name is null then '' else
        nullif(trim(substr(v_name,length(split_part(v_name,' ',1))+1)),'') end,'');
    v_phone := public.november_import_first(r.source_payload,
      array['Contact','Phone','Mobile','Guardian Phone','Contact Phone']);
    v_class_source := public.november_import_first(r.source_payload,
      array['Class Name','Class','Class Level','Class Or Level','Level']);
    v_teacher_source := public.november_import_first(r.source_payload,array['Teacher','Teacher Name']);
    v_time := public.november_import_first(r.source_payload,array['Time','Schedule','Class Time']);
    v_month := public.november_import_first(r.source_payload,array['Period','Source Month','Month']);
    v_tuition := coalesce(public.november_import_number(public.november_import_first(
      r.source_payload,array['Original Tuition','Base Fee','Monthly Fee','Fee','Tuition'])),0);
    v_discount := coalesce(public.november_import_number(public.november_import_first(
      r.source_payload,array['Discount'])),0);

    v_class_id := public.november_import_match_class(v_class_source,v_teacher_source,v_time);
    v_teacher_id := null; v_teacher_name := v_teacher_source; v_class_title := null;
    if v_class_id is not null then
      select c.teacher_id, c.title, t.full_name
        into v_teacher_id, v_class_title, v_teacher_name
      from public.class_rooms c join public.teachers t on t.id=c.teacher_id
      where c.id=v_class_id;
    else
      v_teacher_id := public.november_import_match_teacher(v_teacher_source);
    end if;

    -- Locate a verified source receipt for this person: class-qualified first, then unique by name.
    v_pay := 0; v_pay_date := null; v_pay_ref := null; v_pay_key := null;
    v_pay_count := 0; v_pay_ambiguity := false;

    if v_nameless is not null then
      select count(*), min(p.source_key) into v_pay_count, v_pay_key
      from public.historical_import_source_rows p
      where p.batch_id = v_batch and p.source_sheet = 'Payments'
        and public.november_import_name_key(public.november_import_first(p.source_payload,
              array['Name Key','Full Name','Name'])) = v_nameless
        and v_class_title is not null
        and public.november_import_class_title(public.november_import_first(p.source_payload,
              array['Class Level','Class Name','Class'])) = v_class_title;
      if v_pay_count > 1 then v_pay_ambiguity := true; end if;
      if v_pay_count = 0 then
        select count(*), min(p.source_key) into v_pay_count, v_pay_key
        from public.historical_import_source_rows p
        where p.batch_id = v_batch and p.source_sheet = 'Payments'
          and public.november_import_name_key(public.november_import_first(p.source_payload,
                array['Name Key','Full Name','Name'])) = v_nameless;
        if v_pay_count > 1 then v_pay_ambiguity := true; v_pay_key := null; end if;
      end if;
    end if;

    if v_pay_key is not null and not v_pay_ambiguity then
      select coalesce(public.november_import_number(public.november_import_first(p.source_payload,
               array['Amount Received','Payment Amount','Amount','Received'])),0),
             public.november_import_date(public.november_import_first(p.source_payload,
               array['Payment Date Parsed','Payment Date','Payment Date Raw','Date Parsed'])),
             concat_ws(' | ',
               nullif(public.november_import_first(p.source_payload,array['Bill No','Receipt No','Bill']),''),
               'Source receipt '||p.source_key)
        into v_pay, v_pay_date, v_pay_ref
      from public.historical_import_source_rows p
      where p.batch_id = v_batch and p.source_key = v_pay_key;
    end if;

    v_identity := public.november_import_identity_key(v_name,v_phone);
    v_match_id := null; v_match_label := null;
    select count(*), (array_agg(s.id order by s.id))[1] into v_match_count, v_match_id
    from public.students s
    where public.november_import_name_key(concat_ws(' ',s.first_name,s.last_name)) = v_nameless;
    if v_nameless is null then
      v_confidence := 'unknown'; v_match_id := null;
    elsif v_match_count = 1 then
      v_confidence := 'exact_name';
      select concat_ws(' · ',s.student_code,concat_ws(' ',s.first_name,s.last_name))
        into v_match_label from public.students s where s.id=v_match_id;
    elsif v_match_count > 1 then
      v_confidence := 'ambiguous'; v_match_id := null;
      v_match_label := v_match_count::text||' existing profiles share this name';
    else
      v_confidence := 'new';
    end if;

    if v_nameless is null then
      v_reasons := v_reasons || jsonb_build_array(jsonb_build_object('code','student_name_missing',
        'message','The source row has no student name.'));
    end if;
    if v_class_id is null then
      v_reasons := v_reasons || jsonb_build_array(jsonb_build_object('code','class_unmatched',
        'message','No live class matches title "'||coalesce(v_class_source,'')||'" with teacher "'
          ||coalesce(v_teacher_source,'')||'". Pick the class explicitly.'));
    end if;
    if v_tuition <= 0 then
      v_reasons := v_reasons || jsonb_build_array(jsonb_build_object('code','tuition_missing',
        'message','No source tuition was found. Enter the approved tuition.'));
    end if;
    if v_discount > v_tuition then
      v_reasons := v_reasons || jsonb_build_array(jsonb_build_object('code','discount_exceeds_tuition',
        'message','Source discount is larger than the tuition.'));
    end if;
    if v_pay_ambiguity then
      v_reasons := v_reasons || jsonb_build_array(jsonb_build_object('code','payment_ambiguous',
        'message','Several source receipts match this student. Choose the correct one.'));
    end if;
    if v_pay > 0 and v_tuition > 0 and v_pay > v_tuition - v_discount then
      v_reasons := v_reasons || jsonb_build_array(jsonb_build_object('code','payment_exceeds_payable',
        'message','The source receipt is larger than tuition minus discount.'));
    end if;
    if v_pay > 0 and v_pay_date is null then
      v_reasons := v_reasons || jsonb_build_array(jsonb_build_object('code','payment_date_missing',
        'message','A receipt exists but its date could not be read.'));
    end if;
    if v_pay_date is not null and date_trunc('month',v_pay_date)::date <> date '2026-11-01' then
      v_reasons := v_reasons || jsonb_build_array(jsonb_build_object('code','payment_date_outside_month',
        'message','The receipt date is outside November 2026: '||v_pay_date::text||'.'));
    end if;
    if v_confidence = 'ambiguous' then
      v_reasons := v_reasons || jsonb_build_array(jsonb_build_object('code','student_match_ambiguous',
        'message','Several existing students share this name. Choose the right profile or create a new one.'));
    end if;

    insert into public.november_import_candidates(
      batch_id,source_row_id,source_sheet,source_key,source_row,source_month,identity_key,
      student_name,first_name,last_name,phone,
      proposed_student_id,proposed_student_label,match_confidence,
      class_id,class_title,teacher_id,teacher_name,start_time,end_time,schedule_label,
      source_tuition,source_discount,source_payment,source_payment_date,source_payment_reference,
      blocking_reasons
    ) values (
      v_batch,r.id,r.source_sheet,r.source_key,r.source_row,v_month,v_identity,
      v_name,v_first,v_last,v_phone,
      v_match_id,v_match_label,v_confidence,
      v_class_id,v_class_title,v_teacher_id,v_teacher_name,
      (select c.start_time from public.class_rooms c where c.id=v_class_id),
      (select c.end_time from public.class_rooms c where c.id=v_class_id),
      v_time,
      v_tuition,v_discount,coalesce(v_pay,0),v_pay_date,v_pay_ref,
      v_reasons
    )
    on conflict (source_row_id) do update set
      source_month = excluded.source_month,
      identity_key = excluded.identity_key,
      student_name = excluded.student_name,
      first_name = excluded.first_name,
      last_name = excluded.last_name,
      phone = excluded.phone,
      proposed_student_id = excluded.proposed_student_id,
      proposed_student_label = excluded.proposed_student_label,
      match_confidence = excluded.match_confidence,
      class_id = excluded.class_id,
      class_title = excluded.class_title,
      teacher_id = excluded.teacher_id,
      teacher_name = excluded.teacher_name,
      start_time = excluded.start_time,
      end_time = excluded.end_time,
      schedule_label = excluded.schedule_label,
      source_tuition = excluded.source_tuition,
      source_discount = excluded.source_discount,
      source_payment = excluded.source_payment,
      source_payment_date = excluded.source_payment_date,
      source_payment_reference = excluded.source_payment_reference,
      blocking_reasons = excluded.blocking_reasons
    where public.november_import_candidates.status = 'needs_review';
  end loop;

  return jsonb_build_object(
    'batch_id',v_batch,
    'candidates',(select count(*) from public.november_import_candidates where batch_id=v_batch),
    'needs_review',(select count(*) from public.november_import_candidates where batch_id=v_batch and status='needs_review'),
    'approved',(select count(*) from public.november_import_candidates where batch_id=v_batch and status='approved'),
    'posted',(select count(*) from public.november_import_candidates where batch_id=v_batch and status='posted'),
    'ready_to_approve',(select count(*) from public.november_import_candidates
       where batch_id=v_batch and status='needs_review' and blocking_reasons='[]'::jsonb),
    'class_unmatched',(select count(*) from public.november_import_candidates
       where batch_id=v_batch and status='needs_review' and blocking_reasons @> '[{"code":"class_unmatched"}]'::jsonb)
  );
end $$;
-- ---------------------------------------------------------------------------
-- 6. Administrator approval of one November candidate
--    Identity, class mapping and money are approved together and validated here.
-- ---------------------------------------------------------------------------
create or replace function public.november_import_approve(p_candidate uuid, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
#variable_conflict use_variable
declare
  c public.november_import_candidates%rowtype;
  v_action text;
  v_student_id uuid;
  v_first text;
  v_last text;
  v_phone text;
  v_class uuid;
  v_room public.class_rooms%rowtype;
  v_tuition numeric;
  v_discount numeric;
  v_reason text;
  v_entitlement numeric;
  v_exception text;
  v_std numeric;
  v_payment numeric;
  v_payment_date date;
  v_payment_method text;
  v_registered_on date;
  v_existing uuid;
begin
  if not public.staff_has_any(array['admin']) then
    raise exception 'Administrator approval required' using errcode='42501';
  end if;
  if p_candidate is null or p_payload is null then
    raise exception 'Candidate and approval payload are required';
  end if;

  select * into c from public.november_import_candidates where id=p_candidate for update;
  if not found then raise exception 'November candidate not found'; end if;
  if c.status not in ('needs_review','approved') then
    raise exception 'Candidate is already % and cannot be re-approved', c.status;
  end if;

  v_action := coalesce(nullif(p_payload->>'student_action',''),'create');
  if v_action not in ('create','match') then
    raise exception 'Student action must be create or match';
  end if;
  v_student_id := nullif(p_payload->>'student_id','')::uuid;
  v_first := nullif(trim(coalesce(p_payload->>'first_name',c.first_name,'')),'');
  v_last := coalesce(nullif(trim(coalesce(p_payload->>'last_name',c.last_name,'')),''),'');
  v_phone := nullif(trim(coalesce(p_payload->>'phone',c.phone,'')),'');

  if v_action='match' then
    if v_student_id is null or not exists(select 1 from public.students s where s.id=v_student_id) then
      raise exception 'Choose the existing student profile to match';
    end if;
  elsif v_first is null then
    raise exception 'Student first name is required to create a profile';
  end if;

  v_class := coalesce(nullif(p_payload->>'class_id','')::uuid, c.class_id);
  if v_class is null then
    raise exception 'Choose the class this registration belongs to';
  end if;
  select * into v_room from public.class_rooms where id=v_class;
  if not found then raise exception 'Selected class does not exist'; end if;

  v_tuition := coalesce(public.november_import_number(p_payload->>'tuition'), c.source_tuition);
  v_discount := coalesce(public.november_import_number(p_payload->>'discount'), c.source_discount);
  v_reason := nullif(trim(coalesce(p_payload->>'discount_reason','')),'');

  if v_tuition is null or v_tuition <= 0 then
    raise exception 'Approved tuition must be greater than zero';
  end if;
  if v_tuition <> round(v_tuition,2) then raise exception 'Tuition must have at most two decimals'; end if;
  if v_discount is null then v_discount := 0; end if;
  if v_discount < 0 or v_discount <> round(v_discount,2) then
    raise exception 'Discount must be a non-negative amount with two decimals';
  end if;
  if v_discount > v_tuition then
    raise exception 'Discount cannot exceed the approved tuition';
  end if;
  if v_discount > 0 and coalesce(length(v_reason),0) < 4 then
    raise exception 'A discount reason of at least 4 characters is required';
  end if;

  v_std := round(v_tuition * 0.50,2);
  v_entitlement := coalesce(public.november_import_number(p_payload->>'teacher_entitlement'), v_std);
  if v_entitlement < 0 or v_entitlement <> round(v_entitlement,2) then
    raise exception 'Teacher entitlement must be a non-negative amount with two decimals';
  end if;
  v_entitlement := least(v_entitlement, v_tuition);
  v_exception := nullif(trim(coalesce(p_payload->>'teacher_exception_reason','')),'');
  if v_entitlement <> v_std and coalesce(length(v_exception),0) < 4 then
    raise exception 'A teacher entitlement exception needs a recorded reason (minimum 4 characters)';
  end if;

  v_payment := coalesce(public.november_import_number(p_payload->>'payment'), c.source_payment);
  if v_payment is null then v_payment := 0; end if;
  if v_payment < 0 or v_payment <> round(v_payment,2) then
    raise exception 'Recorded payment must be a non-negative amount with two decimals';
  end if;
  if v_payment > v_tuition - v_discount then
    raise exception 'Recorded payment cannot exceed tuition minus discount';
  end if;
  v_payment_date := coalesce(public.november_import_date(p_payload->>'payment_date'), c.source_payment_date);
  v_payment_method := coalesce(nullif(p_payload->>'payment_method',''),'cash');
  if v_payment > 0 then
    if v_payment_date is null then
      raise exception 'A payment date is required when a payment amount is recorded';
    end if;
    if date_trunc('month',v_payment_date)::date <> date '2026-11-01' then
      raise exception 'Payment date must fall inside November 2026';
    end if;
    if v_payment_method not in ('cash','bank','other') then
      raise exception 'Payment method must be cash, bank or other';
    end if;
  end if;

  v_registered_on := coalesce(public.november_import_date(p_payload->>'registered_on'), date '2026-11-01');
  if date_trunc('month',v_registered_on)::date <> date '2026-11-01' then
    raise exception 'Registration date must fall inside November 2026';
  end if;

  -- Confirmed identity + confirmed class already present in the books = duplicate, never double-counted.
  v_existing := null;
  if v_action='match' then
    select m.id into v_existing
    from public.monthly_memberships m
    join public.billing_periods b on b.id=m.period_id
    join public.enrollments e on e.id=m.enrollment_id
    where b.year_month = date '2026-11-01'
      and e.student_id = v_student_id and e.class_id = v_class
      and m.registration_active
    limit 1;
  end if;

  update public.november_import_candidates set
    approved_student_action = v_action,
    approved_student_id = v_student_id,
    approved_class_id = v_class,
    approved_tuition = v_tuition,
    approved_discount = v_discount,
    approved_discount_reason = case when v_discount > 0 then v_reason
      else nullif(trim(coalesce(p_payload->>'discount_reason','')),'') end,
    approved_teacher_entitlement = v_entitlement,
    approved_teacher_exception_reason = case when v_entitlement <> v_std then v_exception else null end,
    approved_payment = v_payment,
    approved_payment_date = case when v_payment > 0 then v_payment_date else null end,
    approved_payment_method = case when v_payment > 0 then v_payment_method else null end,
    approved_registered_on = v_registered_on,
    approved_note = nullif(trim(coalesce(p_payload->>'note','')),''),
    student_name = coalesce(c.student_name, v_first),
    first_name = coalesce(v_first,''),
    last_name = coalesce(v_last,''),
    phone = coalesce(v_phone, c.phone),
    class_id = v_class,
    class_title = v_room.title,
    teacher_id = v_room.teacher_id,
    teacher_name = (select t.full_name from public.teachers t where t.id=v_room.teacher_id),
    start_time = v_room.start_time,
    end_time = v_room.end_time,
    status = case when v_existing is not null then 'duplicate' else 'approved' end,
    membership_id = coalesce(v_existing, membership_id),
    blocking_reasons = '[]'::jsonb,
    review_note = coalesce(nullif(trim(coalesce(p_payload->>'note','')),''), review_note),
    approved_by = auth.uid(),
    approved_at = now()
  where id = p_candidate;

  return jsonb_build_object(
    'candidate_id',p_candidate,
    'status',case when v_existing is not null then 'duplicate' else 'approved' end,
    'class_id',v_class,
    'tuition',v_tuition,
    'discount',v_discount,
    'payable',v_tuition - v_discount,
    'teacher_entitlement',v_entitlement,
    'payment',v_payment,
    'duplicate_membership_id',v_existing
  );
end $$;
-- ---------------------------------------------------------------------------
-- 7. Approve every candidate that needs no further information
--    (uncertain identities, receipts and unmatched classes always stay in review)
-- ---------------------------------------------------------------------------
create or replace function public.november_import_approve_ready(p_reason text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  c record;
  v_reason text := trim(coalesce(p_reason,''));
  v_approved integer := 0;
  v_duplicate integer := 0;
  v_failed integer := 0;
  v_result jsonb;
  v_payload jsonb;
begin
  if not public.staff_has_any(array['admin']) then
    raise exception 'Administrator approval required' using errcode='42501';
  end if;
  if length(v_reason) < 4 then
    raise exception 'Record the administrator reason for this approval';
  end if;

  for c in
    select * from public.november_import_candidates
    where status='needs_review' and blocking_reasons='[]'::jsonb
    order by identity_key, class_title
  loop
    v_payload := jsonb_build_object(
      'student_action', case when c.match_confidence='exact_name'
        and c.proposed_student_id is not null then 'match' else 'create' end,
      'student_id', case when c.match_confidence='exact_name' then c.proposed_student_id end,
      'first_name', c.first_name,
      'last_name', c.last_name,
      'phone', c.phone,
      'class_id', c.class_id,
      'tuition', c.source_tuition,
      'discount', c.source_discount,
      'discount_reason', case when c.source_discount > 0 then
        case when c.source_discount >= c.source_tuition
          then 'November roster: confirmed full tuition discount'
          else 'November roster: administrator approved discount' end end,
      'teacher_entitlement', round(c.source_tuition * 0.50, 2),
      'payment', c.source_payment,
      'payment_date', c.source_payment_date,
      'payment_method', 'cash',
      'registered_on', date '2026-11-01',
      'note', v_reason
    );
    begin
      v_result := public.november_import_approve(c.id, v_payload);
      if (v_result->>'status') = 'duplicate' then
        v_duplicate := v_duplicate + 1;
      else
        v_approved := v_approved + 1;
      end if;
    exception when others then
      v_failed := v_failed + 1;
      update public.november_import_candidates
      set blocking_reasons = blocking_reasons || jsonb_build_array(
            jsonb_build_object('code','approval_failed','message',sqlerrm))
      where id = c.id;
    end;
  end loop;

  return jsonb_build_object(
    'approved',v_approved,
    'duplicate',v_duplicate,
    'failed',v_failed,
    'still_awaiting_review',(select count(*) from public.november_import_candidates
      where status='needs_review')
  );
end $$;

-- ---------------------------------------------------------------------------
-- 8. Post approved candidates into the real operational tables
-- ---------------------------------------------------------------------------
create or replace function public.november_import_post(p_limit integer default 50, p_request uuid default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
#variable_conflict use_variable
declare
  c public.november_import_candidates%rowtype;
  v_period uuid;
  v_student uuid;
  v_enrollment uuid;
  v_membership uuid;
  v_payment_id uuid;
  v_payment_json jsonb;
  v_existing uuid;
  v_room public.class_rooms%rowtype;
  v_is_new_student boolean;
  v_is_exception boolean;
  v_std numeric;
  v_office numeric;
  v_sponsored boolean;
  v_note text;
  v_notes text;
  v_registration_type text;
  v_limit integer := greatest(1, least(coalesce(p_limit,50), 200));
  v_posted integer := 0;
  v_duplicates integer := 0;
  v_failed integer := 0;
  v_students_created integer := 0;
  v_students_matched integer := 0;
  v_payments integer := 0;
  v_tuition numeric := 0;
  v_collected numeric := 0;
  v_payable numeric := 0;
  v_teacher numeric := 0;
begin
  if not public.staff_has_any(array['admin']) then
    raise exception 'Administrator approval required' using errcode='42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));

  insert into public.billing_periods(year_month,status) values(date '2026-11-01','open')
  on conflict(year_month) do nothing;
  select p.id into v_period from public.billing_periods p where p.year_month = date '2026-11-01';
  if v_period is null then raise exception 'November 2026 billing period is missing'; end if;

  for c in
    select * from public.november_import_candidates
    where status='approved'
      and approved_class_id is not null
      and approved_tuition is not null
    order by identity_key nulls last, class_title, source_row
    limit v_limit
    for update
  loop
    begin
      select * into v_room from public.class_rooms where id = c.approved_class_id;
      if not found then raise exception 'Approved class no longer exists'; end if;

      -- 1. Resolve the permanent student profile
      v_is_new_student := false;
      v_student := null;
      if c.approved_student_action = 'match' then
        v_student := c.approved_student_id;
        if v_student is null or not exists(select 1 from public.students s where s.id=v_student) then
          raise exception 'The matched student profile no longer exists';
        end if;
      else
        select m.student_id into v_student
        from public.november_import_students m
        where m.batch_id = c.batch_id and m.identity_key = c.identity_key;
        if v_student is not null then
          v_students_matched := v_students_matched + 1;
        end if;
      end if;

      if v_student is null then
        insert into public.students(first_name,last_name,phone,registered_on,active,notes)
        values(
          coalesce(nullif(trim(c.first_name),''),'Unnamed November student'),
          coalesce(trim(c.last_name),''),
          nullif(trim(c.phone),''),
          coalesce(c.approved_registered_on, date '2026-11-01'),
          true,
          'Created by the November 2026 operational import ('||c.source_sheet||' row '||c.source_row||')'
        ) returning id into v_student;
        v_is_new_student := true;
        v_students_created := v_students_created + 1;
        insert into public.november_import_students(batch_id,identity_key,student_id,created_new,created_by)
        values(c.batch_id,coalesce(c.identity_key,c.source_key),v_student,true,auth.uid())
        on conflict (batch_id,identity_key) do update set student_id = excluded.student_id;
      end if;

      if c.approved_student_action = 'match' then
        v_students_matched := v_students_matched + 1;
      end if;

      -- 2. Enrollment in the matched live class
      insert into public.enrollments(student_id,class_id,enrolled_on,active)
      values(v_student, v_room.id, coalesce(c.approved_registered_on, date '2026-11-01'), true)
      on conflict (student_id,class_id) do update set active = true
      returning id into v_enrollment;

      -- 3. Never double-count a registration that already exists in the books
      select m.id into v_existing from public.monthly_memberships m
      where m.period_id = v_period and m.enrollment_id = v_enrollment and m.registration_active
      limit 1;

      if v_existing is not null then
        update public.historical_import_source_rows
        set review_status='accepted', posting_status='duplicate',
            destination_table='monthly_memberships', destination_id=v_existing,
            reviewed_by=auth.uid(), reviewed_at=now(),
            review_reason='Already registered for this class in November 2026'
        where id = c.source_row_id;
        insert into public.historical_import_destinations(
          source_row_id,destination_table,destination_id,mapping_status,created_by)
        values(c.source_row_id,'monthly_memberships',v_existing,'duplicate_excluded',auth.uid())
        on conflict (source_row_id,destination_table) do update set destination_id = excluded.destination_id;
        update public.november_import_candidates
        set status='duplicate', student_id=v_student, enrollment_id=v_enrollment,
            membership_id=v_existing, posted_at=now(),
            review_note=concat_ws(' | ', review_note,'Existing November registration reused')
        where id = c.id;
        v_duplicates := v_duplicates + 1;
        continue;
      end if;

      -- 4. The approved financial agreement (migration 010 / 011 rules)
      v_std := round(c.approved_tuition * 0.50, 2);
      v_is_exception := c.approved_teacher_entitlement is not null
        and c.approved_teacher_entitlement <> v_std;
      v_office := c.approved_tuition - c.approved_discount
        - coalesce(c.approved_teacher_entitlement, v_std);
      v_sponsored := c.approved_tuition > 0 and c.approved_discount = c.approved_tuition;
      v_note := case when v_sponsored then 'November roster: confirmed full tuition discount'
        when c.approved_discount > 0 then 'November roster: administrator approved discount'
        else null end;
      v_registration_type := case when c.approved_student_action = 'match' then 'returning' else 'new' end;
      v_notes := concat_ws(' | ',
        nullif(trim(c.approved_note),''),
        'Source '||c.source_sheet||' row '||c.source_row,
        nullif(trim(c.source_payment_reference),''));

      perform set_config('rsms.audit_reason','November 2026 import: administrator approved',true);

      insert into public.monthly_memberships(
        period_id,enrollment_id,teacher_id,class_title_snapshot,registered_on,
        original_fee,base_fee,discount,teacher_discount_share,
        manual_teacher_share,manual_office_share,manual_adjustment_reason,
        manual_adjusted_by,manual_adjusted_at,
        agreement_approved_by,agreement_approved_at,
        discount_reason,notes,proration_rule,registration_type,
        teacher_share_mode,teacher_share_reason,sponsored_confirmed,
        start_time_snapshot,end_time_snapshot,registration_active
      ) values (
        v_period, v_enrollment, v_room.teacher_id, v_room.title,
        coalesce(c.approved_registered_on, date '2026-11-01'),
        c.approved_tuition, c.approved_tuition, c.approved_discount, 0,
        case when v_is_exception then c.approved_teacher_entitlement end,
        case when v_is_exception then v_office end,
        case when v_is_exception then nullif(trim(c.approved_teacher_exception_reason),'') end,
        case when v_is_exception then auth.uid() end,
        case when v_is_exception then now() end,
        auth.uid(), now(),
        case when c.approved_discount > 0 then coalesce(nullif(trim(c.approved_discount_reason),''), v_note) end,
        v_notes, 'manual_agreement', v_registration_type,
        case when v_is_exception then 'custom' else 'standard' end,
        case when v_is_exception then nullif(trim(c.approved_teacher_exception_reason),'') end,
        v_sponsored,
        v_room.start_time, v_room.end_time, true
      ) returning id into v_membership;

      -- 5. Record only a verified source receipt; never manufacture a payment
      v_payment_id := null;
      if coalesce(c.approved_payment,0) > 0 then
        v_payment_json := public.record_tuition_payment(
          v_membership,
          c.approved_payment,
          coalesce(c.approved_payment_date, date '2026-11-01'),
          coalesce(c.approved_payment_method,'cash'),
          v_notes,
          md5('november-import:'||c.id::text)::uuid
        );
        v_payment_id := (v_payment_json->>'id')::uuid;
        v_payments := v_payments + 1;
        v_collected := v_collected + c.approved_payment;
      end if;

      -- 6. Provenance: source row, destinations, review record
      update public.historical_import_source_rows
      set review_status='accepted', posting_status='posted',
          destination_table='monthly_memberships', destination_id=v_membership,
          reviewed_by=auth.uid(), reviewed_at=now(),
          review_reason='Approved and posted by the November 2026 operational import'
      where id = c.source_row_id;

      insert into public.historical_import_destinations(
        source_row_id,destination_table,destination_id,mapping_status,created_by)
      select c.source_row_id, x.table_name, x.id,
             case when x.matched then 'matched_existing' else 'created' end, auth.uid()
      from (values
        ('students', v_student, not v_is_new_student),
        ('enrollments', v_enrollment, false),
        ('monthly_memberships', v_membership, false)
      ) as x(table_name,id,matched)
      on conflict (source_row_id,destination_table) do update set destination_id = excluded.destination_id;

      if v_payment_id is not null then
        insert into public.historical_import_destinations(
          source_row_id,destination_table,destination_id,mapping_status,created_by)
        values(c.source_row_id,'payments',v_payment_id,'created',auth.uid())
        on conflict (source_row_id,destination_table) do update set destination_id = excluded.destination_id;
      end if;

      update public.november_import_candidates
      set status='posted', student_id=v_student, enrollment_id=v_enrollment,
          membership_id=v_membership, payment_id=v_payment_id,
          blocking_reasons='[]'::jsonb, posted_at=now()
      where id = c.id;

      v_posted := v_posted + 1;
      v_tuition := v_tuition + c.approved_tuition;
      v_payable := v_payable + (c.approved_tuition - c.approved_discount);
      v_teacher := v_teacher + coalesce(c.approved_teacher_entitlement, v_std);

    exception when others then
      v_failed := v_failed + 1;
      update public.november_import_candidates
      set status='needs_review',
          blocking_reasons = blocking_reasons || jsonb_build_array(
            jsonb_build_object('code','posting_failed','message',sqlerrm))
      where id = c.id;
    end;
  end loop;

  return jsonb_build_object(
    'posted',v_posted,
    'duplicates',v_duplicates,
    'failed',v_failed,
    'students_created',v_students_created,
    'students_matched',v_students_matched,
    'payments_recorded',v_payments,
    'total_tuition',v_tuition,
    'total_payable',v_payable,
    'total_collected',v_collected,
    'total_teacher_entitlement',v_teacher,
    'remaining_approved',(select count(*) from public.november_import_candidates where status='approved'),
    'remaining_review',(select count(*) from public.november_import_candidates where status='needs_review')
  );
end $$;
-- ---------------------------------------------------------------------------
-- 9. Read-only verification summary for the November 2026 import
-- ---------------------------------------------------------------------------
create or replace function public.november_import_summary(p_sha256 text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
#variable_conflict use_variable
declare
  v_batch uuid;
  v_sha text := coalesce(
    nullif(trim(coalesce(p_sha256,'')),''),
    '15e9b64e02048eba03e59636e2875c56701c0d1160748da7a85e26c8c1e7cc64');
  v_period uuid;
  v_source_candidates bigint;
  v_source_posted bigint;
  v_source_pending bigint;
  v_students_created bigint;
  v_students_matched bigint;
  v_memberships bigint;
  v_payments bigint;
  v_collected numeric;
  v_payable numeric;
  v_teacher numeric;
  v_sponsorships bigint;
  v_awaiting bigint;
  v_approved bigint;
  v_duplicates bigint;
  v_total_students bigint;
  v_total_enrollments bigint;
begin
  if not public.staff_has_any(array['admin','accountant','registrar']) then
    raise exception 'Staff access required' using errcode='42501';
  end if;

  select b.id into v_batch from public.historical_import_batches b
    where lower(trim(b.source_sha256)) = lower(v_sha);
  select p.id into v_period from public.billing_periods p where p.year_month = date '2026-11-01';

  select count(*) into v_source_candidates
    from public.historical_import_source_rows r
    where v_batch is not null and r.batch_id = v_batch
      and r.source_sheet in ('Registrations','RegistrationLeads');
  select count(*) into v_source_posted
    from public.historical_import_source_rows r
    where v_batch is not null and r.batch_id = v_batch
      and r.source_sheet in ('Registrations','RegistrationLeads')
      and r.posting_status in ('posted','duplicate');
  v_source_pending := greatest(0, coalesce(v_source_candidates,0) - coalesce(v_source_posted,0));

  select count(*) into v_students_created
    from public.november_import_students m
    where v_batch is not null and m.batch_id = v_batch and m.created_new;
  select count(distinct c.student_id) into v_students_matched
    from public.november_import_candidates c
    where v_batch is not null and c.batch_id = v_batch
      and c.status in ('posted','duplicate') and c.approved_student_action = 'match';

  select
    count(*),
    coalesce(sum(f.teacher_entitlement),0),
    coalesce(sum(f.amount_due),0),
    count(*) filter (where f.sponsored_confirmed or (f.discount > 0 and f.amount_due = 0))
  into v_memberships, v_teacher, v_payable, v_sponsorships
  from public.month_fee_overview f
  where v_period is not null and f.period_id = v_period;

  select count(*), coalesce(sum(p.amount),0)
  into v_payments, v_collected
  from public.payments p
  join public.monthly_memberships m on m.id = p.monthly_membership_id
  where v_period is not null and m.period_id = v_period and p.voided_at is null;

  select count(*) filter (where status='needs_review'),
         count(*) filter (where status='approved'),
         count(*) filter (where status='duplicate')
  into v_awaiting, v_approved, v_duplicates
  from public.november_import_candidates c
  where v_batch is not null and c.batch_id = v_batch;

  select count(*) into v_total_students from public.students;
  select count(*) into v_total_enrollments from public.enrollments where active;

  return jsonb_build_object(
    'batch_id',v_batch,
    'checksum',v_sha,
    'source_registration_candidates',coalesce(v_source_candidates,0),
    'source_rows_posted',coalesce(v_source_posted,0),
    'source_rows_pending',coalesce(v_source_pending,0),
    'students_created',coalesce(v_students_created,0),
    'students_matched',coalesce(v_students_matched,0),
    'november_memberships',coalesce(v_memberships,0),
    'verified_payments',coalesce(v_payments,0),
    'payments_total',coalesce(v_collected,0),
    'payable_total',coalesce(v_payable,0),
    'teacher_entitlement_total',coalesce(v_teacher,0),
    'institution_funded',greatest(0, coalesce(v_teacher,0) - coalesce(v_collected,0)),
    'sponsorships',coalesce(v_sponsorships,0),
    'awaiting_review',coalesce(v_awaiting,0),
    'approved_not_posted',coalesce(v_approved,0),
    'duplicates_excluded',coalesce(v_duplicates,0),
    'operational_students',coalesce(v_total_students,0),
    'operational_enrollments',coalesce(v_total_enrollments,0)
  );
end $$;

-- ---------------------------------------------------------------------------
-- 10. Lock the legacy November batch RPCs that bypassed the review workflow
--     (migration 012 posted from an un-reviewed client payload and swallowed
--      posting errors inside a loop, so nothing was ever written)
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.import_november_batch(jsonb,uuid)') is not null then
    revoke execute on function public.import_november_batch(jsonb,uuid) from public, anon, authenticated;
  end if;
  if to_regprocedure('public.import_november_registration(jsonb,uuid)') is not null then
    revoke execute on function public.import_november_registration(jsonb,uuid) from public, anon, authenticated;
  end if;
  if to_regprocedure('public.get_november_import_summary()') is not null then
    revoke execute on function public.get_november_import_summary() from public, anon, authenticated;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 11. Permissions for the review workflow (administrator-only, audited)
-- ---------------------------------------------------------------------------
revoke all on function public.november_import_first(jsonb,text[]),
  public.november_import_number(text),
  public.november_import_date(text),
  public.november_import_parse_hour(text),
  public.november_import_class_title(text),
  public.november_import_identity_key(text,text),
  public.november_import_name_key(text),
  public.november_import_match_teacher(text),
  public.november_import_match_class(text,text,text)
  from public, anon, authenticated;

revoke all on function public.build_november_import_candidates(text),
  public.november_import_approve(uuid,jsonb),
  public.november_import_approve_ready(text),
  public.november_import_post(integer,uuid),
  public.november_import_summary(text)
  from public, anon;

grant execute on function public.build_november_import_candidates(text),
  public.november_import_approve(uuid,jsonb),
  public.november_import_approve_ready(text),
  public.november_import_post(integer,uuid),
  public.november_import_summary(text)
  to authenticated;

notify pgrst, 'reload schema';
commit;
