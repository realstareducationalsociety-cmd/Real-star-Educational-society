begin;

alter table public.historical_import_source_rows
  add column review_resolution jsonb not null default '{}'::jsonb
    check (jsonb_typeof(review_resolution)='object'),
  add column posting_status text not null default 'pending'
    check (posting_status in ('pending','posted','duplicate'));

create table public.historical_import_destinations (
  source_row_id uuid not null references public.historical_import_source_rows(id) on delete restrict,
  destination_table text not null check (destination_table in (
    'students','teachers','class_rooms','enrollments','monthly_memberships',
    'payments','books','book_sales','chapters','chapter_sales','expenses',
    'partner_transactions','material_payments'
  )),
  destination_id uuid not null,
  mapping_status text not null check (mapping_status in ('created','matched_existing','duplicate_excluded')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (source_row_id,destination_table)
);

create table public.historical_import_entities (
  batch_id uuid not null references public.historical_import_batches(id) on delete restrict,
  entity_type text not null check (entity_type in ('student','teacher','class')),
  entity_key text not null check (length(trim(entity_key)) between 1 and 300),
  destination_id uuid not null,
  destination_table text not null check (destination_table in ('students','teachers','class_rooms')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (batch_id,entity_type,entity_key),
  check ((entity_type='student' and destination_table='students')
      or (entity_type='teacher' and destination_table='teachers')
      or (entity_type='class' and destination_table='class_rooms'))
);

alter table public.historical_import_destinations enable row level security;
alter table public.historical_import_entities enable row level security;
create policy historical_import_destinations_admin_read on public.historical_import_destinations
  for select to authenticated using (public.staff_has_any(array['admin']));
create policy historical_import_entities_admin_read on public.historical_import_entities
  for select to authenticated using (public.staff_has_any(array['admin']));
revoke all on public.historical_import_destinations,public.historical_import_entities
  from public,anon,authenticated;
grant select on public.historical_import_destinations,public.historical_import_entities to authenticated;

create function public.validate_historical_import_resolution(p_sheet text,p_resolution jsonb)
returns void language plpgsql immutable set search_path=public,pg_temp as $$
declare kind text:=p_resolution->>'kind';
begin
  if p_resolution is null or jsonb_typeof(p_resolution)<>'object' then raise exception 'Resolution must be an object'; end if;
  if p_sheet='Students' and kind='student' then
    if length(trim(coalesce(p_resolution->>'entity_key','')))=0 then
      raise exception 'A stable student candidate key is required'; end if;
    if p_resolution->>'action'='match' then
      if coalesce(p_resolution->>'student_id','') !~* '^[0-9a-f-]{36}$' then raise exception 'Select an existing student'; end if;
    elsif p_resolution->>'action'='create' then
      if coalesce(p_resolution->>'identity_confirmed','false')<>'true'
        or length(trim(coalesce(p_resolution->>'first_name','')))=0
        or coalesce(p_resolution->>'profile_active','') not in ('true','false')
      then raise exception 'Confirm this identity and provide a stable candidate key'; end if;
    else raise exception 'Choose create or match for this student'; end if;
  elsif p_sheet='Teachers' and kind='teacher' then
    if length(trim(coalesce(p_resolution->>'entity_key','')))=0 then
      raise exception 'A stable teacher candidate key is required'; end if;
    if p_resolution->>'action'='match' then
      if coalesce(p_resolution->>'teacher_id','') !~* '^[0-9a-f-]{36}$' then raise exception 'Select an existing teacher'; end if;
    elsif p_resolution->>'action'='create' then
      if coalesce(p_resolution->>'identity_confirmed','false')<>'true'
        or length(trim(coalesce(p_resolution->>'full_name','')))=0
        or coalesce(p_resolution->>'active','') not in ('true','false')
      then raise exception 'Confirm this teacher and provide a stable candidate key'; end if;
    else raise exception 'Choose create or match for this teacher'; end if;
  elsif p_sheet='Classes' and kind='class' then
    if length(trim(coalesce(p_resolution->>'entity_key','')))=0 then
      raise exception 'A stable class candidate key is required'; end if;
    if p_resolution->>'action'='match' then
      if coalesce(p_resolution->>'class_id','') !~* '^[0-9a-f-]{36}$' then raise exception 'Select an existing class'; end if;
    elsif p_resolution->>'action'='create' then
      if length(trim(coalesce(p_resolution->>'title','')))=0
        or coalesce(p_resolution->>'default_fee','') !~ '^[0-9]+([.][0-9]{1,2})?$'
        or coalesce(p_resolution->>'active','') not in ('true','false')
        or (nullif(p_resolution->>'teacher_id','') is not null
          and (p_resolution->>'teacher_id') !~* '^[0-9a-f-]{36}$')
        or (nullif(p_resolution->>'teacher_id','') is null and (
          length(trim(coalesce(p_resolution->>'teacher_entity_key','')))=0
          or length(trim(coalesce(p_resolution->>'teacher_name','')))=0
          or coalesce(p_resolution->>'teacher_active','') not in ('true','false')
          or coalesce(p_resolution->>'teacher_identity_confirmed','false')<>'true'))
      then raise exception 'Class title, teacher, fee, and stable class key are required'; end if;
    else raise exception 'Choose create or match for this class'; end if;
  elsif p_sheet='Registrations' and kind='registration' then
    if (p_resolution->>'student_id' is null and length(trim(coalesce(p_resolution->>'student_entity_key','')))=0)
      or (p_resolution->>'class_id' is null and length(trim(coalesce(p_resolution->>'class_entity_key','')))=0)
      or coalesce(p_resolution->>'month','') !~ '^[0-9]{4}-[0-9]{2}$'
      or coalesce(p_resolution->>'registered_on','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      or coalesce(p_resolution->>'registration_date_verified','false')<>'true'
      or coalesce(p_resolution->>'registration_verified','false')<>'true'
      or coalesce(p_resolution->>'base_fee','') !~ '^[0-9]+([.][0-9]{1,2})?$'
      or coalesce(p_resolution->>'discount','0') !~ '^[0-9]+([.][0-9]{1,2})?$'
      or coalesce(p_resolution->>'enrollment_active','') not in ('true','false')
    then raise exception 'Verified student, class, month, registration date, and fee mapping are required'; end if;
    if p_resolution->>'month'='2026-11'
      and coalesce(p_resolution->>'november_registration_confirmed','false')<>'true'
    then raise exception 'November registrations require individual confirmation'; end if;
    if p_resolution ? 'manual_teacher_share' or p_resolution ? 'manual_office_share' then
      if coalesce(p_resolution->>'manual_teacher_share','') !~ '^[0-9]+([.][0-9]{1,2})?$'
        or coalesce(p_resolution->>'manual_office_share','') !~ '^[0-9]+([.][0-9]{1,2})?$'
        or length(trim(coalesce(p_resolution->>'manual_share_reason','')))<4
      then raise exception 'Manual shares require two amounts and a reason'; end if;
    end if;
  elsif p_sheet='Payments' and kind='tuition_payment' then
    if (p_resolution->>'monthly_membership_id' is null and length(trim(coalesce(p_resolution->>'registration_source_key','')))=0)
      or coalesce(p_resolution->>'amount','') !~ '^[0-9]+([.][0-9]{1,2})?$'
      or coalesce(p_resolution->>'paid_on','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      or coalesce(p_resolution->>'payment_verified','false')<>'true'
      or coalesce(p_resolution->>'duplicate_source_checked','false')<>'true'
      or coalesce(p_resolution->>'method','cash') not in ('cash','bank','other')
    then raise exception 'Verified payment, date, membership, and duplicate-source check are required'; end if;
  elsif p_sheet='Expenses' and kind='expense' then
    if coalesce(p_resolution->>'amount','') !~ '^[0-9]+([.][0-9]{1,2})?$'
      or coalesce(p_resolution->>'spent_on','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      or length(trim(coalesce(p_resolution->>'category','')))=0
      or length(trim(coalesce(p_resolution->>'description','')))=0
      or coalesce(p_resolution->>'expense_verified','false')<>'true'
    then raise exception 'Verified expense, date, category, and description are required'; end if;
  elsif p_sheet in ('Books','Chapters') and kind='material_sale' then
    if (p_sheet='Books' and coalesce(p_resolution->>'material_kind','')<>'book')
      or (p_sheet='Chapters' and coalesce(p_resolution->>'material_kind','')<>'chapter')
      or coalesce(p_resolution->>'item_id','') !~* '^[0-9a-f-]{36}$'
      or coalesce(p_resolution->>'student_id','') !~* '^[0-9a-f-]{36}$'
      or coalesce(p_resolution->>'class_id','') !~* '^[0-9a-f-]{36}$'
      or coalesce(p_resolution->>'unit_price','') !~ '^[0-9]+([.][0-9]{1,2})?$'
      or coalesce(p_resolution->>'sold_on','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      or coalesce(p_resolution->>'sale_verified','false')<>'true'
    then raise exception 'Verified sale, existing item, student, class, price, and date are required'; end if;
    if coalesce(p_resolution->>'payment_verified','false')='true'
      and (coalesce(p_resolution->>'payment_amount','') !~ '^[0-9]+([.][0-9]{1,2})?$'
        or coalesce(p_resolution->>'payment_paid_on','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
        or coalesce(p_resolution->>'receipt_verified','false')<>'true')
    then raise exception 'Material receipts require a verified amount and date'; end if;
  elsif p_sheet='PartnerNotes' and kind='partner_transaction' then
    if coalesce(p_resolution->>'partner_id','') !~* '^[0-9a-f-]{36}$'
      or coalesce(p_resolution->>'transaction_kind','') not in ('capital','withdrawal')
      or coalesce(p_resolution->>'amount','') !~ '^[0-9]+([.][0-9]{1,2})?$'
      or coalesce(p_resolution->>'transacted_on','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      or coalesce(p_resolution->>'transaction_verified','false')<>'true'
    then raise exception 'Partner transaction requires independent verification'; end if;
  else
    raise exception 'This source sheet is not eligible for operational posting';
  end if;
end $$;

create function public.resolve_historical_import_row(
  p_row_id uuid,p_resolution jsonb,p_reason text
) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare source_row public.historical_import_source_rows%rowtype;
begin
  if not public.staff_has_any(array['admin']) then raise exception 'Administrator approval required'; end if;
  if length(trim(coalesce(p_reason,'')))<4 or p_resolution is null or pg_column_size(p_resolution)>16000 then
    raise exception 'A review reason and a resolution under 16 KB are required'; end if;
  select * into source_row from public.historical_import_source_rows where id=p_row_id for update;
  if not found then raise exception 'Import source row not found'; end if;
  if source_row.posting_status<>'pending' then raise exception 'Already posted import rows cannot be changed'; end if;
  perform public.validate_historical_import_resolution(source_row.source_sheet,p_resolution);
  update public.historical_import_source_rows
    set review_resolution=p_resolution,review_status='accepted',reviewed_by=auth.uid(),
        reviewed_at=now(),review_reason=trim(p_reason)
    where id=p_row_id;
  update public.historical_import_batches set status='reviewing' where id=source_row.batch_id;
  insert into public.audit_logs(table_name,action,row_id,actor_id,old_data,new_data,reason,approved_by)
  values('historical_import_source_rows','RESOLVE',p_row_id::text,auth.uid(),
    jsonb_build_object('source_sheet',source_row.source_sheet,'source_key',source_row.source_key),
    jsonb_build_object('review_status','accepted','resolution',p_resolution),trim(p_reason),auth.uid());
end $$;

create function public.preview_historical_import_batch(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare result jsonb;
begin
  if not public.staff_has_any(array['admin']) then raise exception 'Administrator approval required'; end if;
  if not exists(select 1 from public.historical_import_batches where id=p_batch_id) then
    raise exception 'Import batch not found'; end if;
  with registration_candidates as (
    select r.id,
      coalesce(nullif(r.review_resolution->>'student_id',''),
        'entity:'||nullif(r.review_resolution->>'student_entity_key','')) student_ref,
      coalesce(nullif(r.review_resolution->>'class_id',''),
        'entity:'||nullif(r.review_resolution->>'class_entity_key','')) class_ref,
      coalesce(nullif(r.review_resolution->>'student_id','')::uuid,
        (select e.destination_id from public.historical_import_entities e
          where e.batch_id=r.batch_id and e.entity_type='student'
            and e.entity_key=r.review_resolution->>'student_entity_key')) student_id,
      coalesce(nullif(r.review_resolution->>'class_id','')::uuid,
        (select e.destination_id from public.historical_import_entities e
          where e.batch_id=r.batch_id and e.entity_type='class'
            and e.entity_key=r.review_resolution->>'class_entity_key')) class_id,
      ((r.review_resolution->>'month')||'-01')::date month_start
    from public.historical_import_source_rows r
    where r.batch_id=p_batch_id and r.source_sheet='Registrations'
      and r.posting_status='pending' and r.review_status='accepted'
      and r.review_resolution<>'{}'::jsonb
  ), ranked_registrations as (
    select c.*,row_number() over(partition by c.student_ref,c.class_ref,c.month_start order by c.id) duplicate_rank
    from registration_candidates c
    where c.student_ref is not null and c.class_ref is not null
  ), duplicate_registrations as (
    select r.id from ranked_registrations r
    where r.duplicate_rank>1 or (r.student_id is not null and r.class_id is not null and exists(
      select 1 from public.monthly_memberships m
      join public.billing_periods b on b.id=m.period_id
      join public.enrollments e on e.id=m.enrollment_id
      where b.year_month=r.month_start and e.student_id=r.student_id
        and e.class_id=r.class_id and m.registration_active
    ))
  )
  select jsonb_build_object(
    'records_ready',count(*) filter(where r.review_status='accepted' and r.posting_status='pending'
      and r.review_resolution<>'{}'::jsonb and r.source_sheet in
      ('Students','Teachers','Classes','Registrations','Payments','Expenses','Books','Chapters','PartnerNotes')
      and d.id is null),
    'existing_records_matched',count(*) filter(where r.review_status='accepted'
      and r.review_resolution->>'action'='match'),
    'duplicate_records_excluded',count(*) filter(where r.posting_status='duplicate' or d.id is not null),
    'records_requiring_review',count(*) filter(where r.posting_status='pending'
      and (r.review_status<>'accepted' or r.review_resolution='{}'::jsonb
        or r.source_sheet not in ('Students','Teachers','Classes','Registrations','Payments','Expenses','Books','Chapters','PartnerNotes'))),
    'financial_transactions_requiring_verification',count(*) filter(where r.source_sheet in
      ('Payments','Books','Chapters','Expenses','PartnerNotes') and
      (r.review_status<>'accepted' or
       (r.source_sheet='Payments' and coalesce(r.review_resolution->>'payment_verified','false')<>'true') or
       (r.source_sheet in ('Books','Chapters') and (
         coalesce(r.review_resolution->>'sale_verified','false')<>'true'
         or (coalesce(r.review_resolution->>'payment_expected','false')='true'
           and coalesce(r.review_resolution->>'payment_verified','false')<>'true'))) or
       (r.source_sheet='Expenses' and coalesce(r.review_resolution->>'expense_verified','false')<>'true') or
       (r.source_sheet='PartnerNotes' and coalesce(r.review_resolution->>'transaction_verified','false')<>'true'))),
    'already_posted',count(*) filter(where r.posting_status='posted'))
  into result
  from public.historical_import_source_rows r
  left join duplicate_registrations d on d.id=r.id
  where r.batch_id=p_batch_id;
  return result;
end $$;

create function public.post_historical_import_batch(p_batch_id uuid,p_confirm boolean)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
#variable_conflict use_variable
declare
  source_row public.historical_import_source_rows%rowtype;
  resolution jsonb;
  student_id uuid;
  teacher_id uuid;
  class_id uuid;
  enrollment_id uuid;
  enrollment_mapping_status text;
  period_id uuid;
  membership_id uuid;
  class_teacher_id uuid;
  class_title text;
  destination_id uuid;
  request_id uuid;
  existing_id uuid;
  month_start date;
  payment_result jsonb;
  posted_count integer:=0;
  matched_count integer:=0;
  duplicate_count integer:=0;
  review_count integer:=0;
  financial_count integer:=0;
  mapping_status text;
begin
  if not public.staff_has_any(array['admin']) then raise exception 'Administrator approval required'; end if;
  if p_confirm is distinct from true then raise exception 'Explicit administrator confirmation is required'; end if;
  if not exists(select 1 from public.historical_import_batches where id=p_batch_id for update) then
    raise exception 'Import batch not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('historical-import-'||p_batch_id::text,0));

  for source_row in
    select r.* from public.historical_import_source_rows r
    where r.batch_id=p_batch_id and r.posting_status='pending'
      and r.review_status='accepted' and r.review_resolution<>'{}'::jsonb
      and r.source_sheet in ('Students','Teachers','Classes','Registrations','Payments','Expenses','Books','Chapters','PartnerNotes')
    order by case r.source_sheet
      when 'Students' then 1 when 'Teachers' then 2 when 'Classes' then 3
      when 'Registrations' then 4 when 'Payments' then 5 when 'Expenses' then 6
      when 'Books' then 7 when 'Chapters' then 8 else 9 end,r.source_row
    limit 500
    for update of r
  loop
    resolution:=source_row.review_resolution;
    perform public.validate_historical_import_resolution(source_row.source_sheet,resolution);
    perform set_config('rsms.audit_reason',source_row.review_reason,true);
    destination_id:=null;
    mapping_status:='created';

    if source_row.source_sheet='Students' then
      if resolution->>'action'='match' then
        student_id:=(resolution->>'student_id')::uuid;
        if not exists(select 1 from public.students where id=student_id) then raise exception 'Matched student does not exist'; end if;
        mapping_status:='matched_existing';
      else
        select e.destination_id into existing_id from public.historical_import_entities e
          where e.batch_id=p_batch_id and e.entity_type='student' and e.entity_key=resolution->>'entity_key';
        if existing_id is not null then
          student_id:=existing_id; mapping_status:='matched_existing';
        else
          insert into public.students(first_name,last_name,guardian_name,phone,guardian_phone,address,active)
          values(trim(resolution->>'first_name'),coalesce(trim(resolution->>'last_name'), ''),
            nullif(trim(resolution->>'guardian_name'),''),nullif(trim(resolution->>'phone'),''),
            nullif(trim(resolution->>'guardian_phone'),''),nullif(trim(resolution->>'address'),''),
            (resolution->>'profile_active')::boolean)
          returning id into student_id;
        end if;
      end if;
      insert into public.historical_import_entities(batch_id,entity_type,entity_key,destination_id,destination_table,created_by)
        values(p_batch_id,'student',resolution->>'entity_key',student_id,'students',auth.uid())
        on conflict(batch_id,entity_type,entity_key) do nothing;
      if not exists(select 1 from public.historical_import_entities e
        where e.batch_id=p_batch_id and e.entity_type='student' and e.entity_key=resolution->>'entity_key'
          and e.destination_id=student_id) then raise exception 'Student candidate key maps to another profile'; end if;
      destination_id:=student_id;
      insert into public.historical_import_destinations
        values(source_row.id,'students',destination_id,mapping_status,auth.uid(),now())
        on conflict(source_row_id,destination_table) do nothing;

    elsif source_row.source_sheet='Teachers' then
      if resolution->>'action'='match' then
        teacher_id:=(resolution->>'teacher_id')::uuid;
        if not exists(select 1 from public.teachers where id=teacher_id) then raise exception 'Matched teacher does not exist'; end if;
        mapping_status:='matched_existing';
      else
        select e.destination_id into existing_id from public.historical_import_entities e
          where e.batch_id=p_batch_id and e.entity_type='teacher' and e.entity_key=resolution->>'entity_key';
        if existing_id is not null then
          teacher_id:=existing_id; mapping_status:='matched_existing';
        else
          insert into public.teachers(full_name,phone,active)
          values(trim(resolution->>'full_name'),nullif(trim(resolution->>'phone'),''),
            (resolution->>'active')::boolean)
          returning id into teacher_id;
        end if;
      end if;
      insert into public.historical_import_entities(batch_id,entity_type,entity_key,destination_id,destination_table,created_by)
        values(p_batch_id,'teacher',resolution->>'entity_key',teacher_id,'teachers',auth.uid())
        on conflict(batch_id,entity_type,entity_key) do nothing;
      if not exists(select 1 from public.historical_import_entities e
        where e.batch_id=p_batch_id and e.entity_type='teacher' and e.entity_key=resolution->>'entity_key'
          and e.destination_id=teacher_id) then raise exception 'Teacher candidate key maps to another profile'; end if;
      destination_id:=teacher_id;
      insert into public.historical_import_destinations
        values(source_row.id,'teachers',destination_id,mapping_status,auth.uid(),now())
        on conflict(source_row_id,destination_table) do nothing;

    elsif source_row.source_sheet='Classes' then
      if resolution->>'action'='match' then
        class_id:=(resolution->>'class_id')::uuid;
        if not exists(select 1 from public.class_rooms where id=class_id) then raise exception 'Matched class does not exist'; end if;
        mapping_status:='matched_existing';
      else
        select e.destination_id into existing_id from public.historical_import_entities e
          where e.batch_id=p_batch_id and e.entity_type='class' and e.entity_key=resolution->>'entity_key';
        if existing_id is not null then
          class_id:=existing_id; mapping_status:='matched_existing';
        else
          if nullif(resolution->>'teacher_id','') is not null then
            teacher_id:=(resolution->>'teacher_id')::uuid;
          else
            select e.destination_id into existing_id from public.historical_import_entities e
              where e.batch_id=p_batch_id and e.entity_type='teacher'
                and e.entity_key=resolution->>'teacher_entity_key';
            if existing_id is not null then
              teacher_id:=existing_id;
            else
              insert into public.teachers(full_name,active)
                values(trim(resolution->>'teacher_name'),
                  coalesce((resolution->>'teacher_active')::boolean,false)) returning id into teacher_id;
            end if;
            insert into public.historical_import_entities(batch_id,entity_type,entity_key,destination_id,destination_table,created_by)
              values(p_batch_id,'teacher',resolution->>'teacher_entity_key',teacher_id,'teachers',auth.uid())
              on conflict(batch_id,entity_type,entity_key) do nothing;
            if not exists(select 1 from public.historical_import_entities e
              where e.batch_id=p_batch_id and e.entity_type='teacher'
                and e.entity_key=resolution->>'teacher_entity_key' and e.destination_id=teacher_id)
            then raise exception 'Teacher candidate key maps to another profile'; end if;
          end if;
          if not exists(select 1 from public.teachers where id=teacher_id) then raise exception 'Class teacher does not exist'; end if;
          insert into public.class_rooms(title,teacher_id,default_fee,start_time,end_time,active)
          values(trim(resolution->>'title'),teacher_id,(resolution->>'default_fee')::numeric,
            nullif(resolution->>'start_time','')::time,nullif(resolution->>'end_time','')::time,
            coalesce((resolution->>'active')::boolean,false))
          returning id into class_id;
        end if;
      end if;
      insert into public.historical_import_entities(batch_id,entity_type,entity_key,destination_id,destination_table,created_by)
        values(p_batch_id,'class',resolution->>'entity_key',class_id,'class_rooms',auth.uid())
        on conflict(batch_id,entity_type,entity_key) do nothing;
      if not exists(select 1 from public.historical_import_entities e
        where e.batch_id=p_batch_id and e.entity_type='class' and e.entity_key=resolution->>'entity_key'
          and e.destination_id=class_id) then raise exception 'Class candidate key maps to another class'; end if;
      destination_id:=class_id;
      insert into public.historical_import_destinations
        values(source_row.id,'class_rooms',destination_id,mapping_status,auth.uid(),now())
        on conflict(source_row_id,destination_table) do nothing;

    elsif source_row.source_sheet='Registrations' then
      if resolution->>'student_id' is not null then
        student_id:=(resolution->>'student_id')::uuid;
      else
        select e.destination_id into student_id from public.historical_import_entities e
          where e.batch_id=p_batch_id and e.entity_type='student' and e.entity_key=resolution->>'student_entity_key';
      end if;
      if resolution->>'class_id' is not null then
        class_id:=(resolution->>'class_id')::uuid;
      else
        select e.destination_id into class_id from public.historical_import_entities e
          where e.batch_id=p_batch_id and e.entity_type='class' and e.entity_key=resolution->>'class_entity_key';
      end if;
      if student_id is null or not exists(select 1 from public.students where id=student_id)
        or class_id is null or not exists(select 1 from public.class_rooms where id=class_id)
      then raise exception 'Registration identity must resolve to an approved student and class'; end if;
      month_start:=((resolution->>'month')||'-01')::date;
      if extract(day from month_start)<>1 then raise exception 'Invalid billing month'; end if;
      perform public.lock_open_months(array[month_start]);
      select id into period_id from public.billing_periods where year_month=month_start;
      if (resolution->>'registered_on')::date<month_start
        or (resolution->>'registered_on')::date>=(month_start+interval '1 month')::date
      then raise exception 'Registration date must be within its billing month'; end if;
      insert into public.enrollments(student_id,class_id,enrolled_on,active)
        values(student_id,class_id,(resolution->>'registered_on')::date,
          coalesce((resolution->>'enrollment_active')::boolean,false))
        on conflict do nothing returning id into enrollment_id;
      if enrollment_id is null then
        enrollment_mapping_status:='matched_existing';
        select e.id into enrollment_id from public.enrollments e
          where e.student_id=student_id and e.class_id=class_id;
      else
        enrollment_mapping_status:='created';
      end if;
      if enrollment_id is null then raise exception 'Could not resolve class membership'; end if;
      select m.id into existing_id from public.monthly_memberships m
        where m.period_id=period_id and m.enrollment_id=enrollment_id;
      if existing_id is not null then
        insert into public.historical_import_destinations
          values(source_row.id,'monthly_memberships',existing_id,'duplicate_excluded',auth.uid(),now())
          on conflict(source_row_id,destination_table) do nothing;
        update public.historical_import_source_rows
          set posting_status='duplicate',destination_table='monthly_memberships',destination_id=existing_id
          where id=source_row.id;
        insert into public.audit_logs(table_name,action,row_id,actor_id,new_data,reason,approved_by)
          values('historical_import_source_rows','POST_DUPLICATE',source_row.id::text,auth.uid(),
            jsonb_build_object('source_key',source_row.source_key,'source_sheet',source_row.source_sheet,
              'destination_table','monthly_memberships','destination_id',existing_id),
            'Excluded because this student already has a registration for the class and month',auth.uid());
        duplicate_count:=duplicate_count+1;
        continue;
      end if;
      select c.teacher_id,c.title into class_teacher_id,class_title
        from public.class_rooms c where c.id=class_id;
      teacher_id:=coalesce(nullif(resolution->>'teacher_id','')::uuid,class_teacher_id);
      insert into public.monthly_memberships(
        period_id,enrollment_id,teacher_id,class_title_snapshot,registered_on,base_fee,discount,
        registration_type,registration_active,manual_teacher_share,manual_office_share,
        manual_adjustment_reason,manual_adjusted_by,manual_adjusted_at
      ) values (
        period_id,enrollment_id,teacher_id,
        coalesce(nullif(trim(resolution->>'class_title_snapshot'),''),class_title),
        (resolution->>'registered_on')::date,(resolution->>'base_fee')::numeric,
        coalesce((resolution->>'discount')::numeric,0),'legacy',true,
        nullif(resolution->>'manual_teacher_share','')::numeric,
        nullif(resolution->>'manual_office_share','')::numeric,
        nullif(trim(resolution->>'manual_share_reason'),''),
        case when resolution ? 'manual_teacher_share' then auth.uid() end,
        case when resolution ? 'manual_teacher_share' then now() end
      ) returning id into membership_id;
      insert into public.historical_import_destinations
        values(source_row.id,'enrollments',enrollment_id,enrollment_mapping_status,auth.uid(),now())
        on conflict(source_row_id,destination_table) do nothing;
      insert into public.historical_import_destinations
        values(source_row.id,'monthly_memberships',membership_id,'created',auth.uid(),now())
        on conflict(source_row_id,destination_table) do nothing;
      destination_id:=membership_id;

    elsif source_row.source_sheet='Payments' then
      if resolution->>'monthly_membership_id' is not null then
        membership_id:=(resolution->>'monthly_membership_id')::uuid;
      else
        select d.destination_id into membership_id
        from public.historical_import_source_rows r
        join public.historical_import_destinations d on d.source_row_id=r.id
        where r.batch_id=p_batch_id and r.source_key=resolution->>'registration_source_key'
          and d.destination_table='monthly_memberships';
      end if;
      if membership_id is null or not exists(select 1 from public.monthly_memberships where id=membership_id)
      then raise exception 'Payment membership could not be resolved'; end if;
      request_id:=md5('historical-tuition:'||source_row.id::text)::uuid;
      payment_result:=public.record_tuition_payment(membership_id,(resolution->>'amount')::numeric,
        (resolution->>'paid_on')::date,coalesce(resolution->>'method','cash'),
        'Historical import source '||source_row.source_key,request_id);
      destination_id:=(payment_result->>'id')::uuid;
      insert into public.historical_import_destinations
        values(source_row.id,'payments',destination_id,'created',auth.uid(),now())
        on conflict(source_row_id,destination_table) do nothing;
      financial_count:=financial_count+1;

    elsif source_row.source_sheet='Expenses' then
      insert into public.expenses(category,description,amount,spent_on,entered_by)
        values(trim(resolution->>'category'),trim(resolution->>'description'),
          (resolution->>'amount')::numeric,(resolution->>'spent_on')::date,auth.uid())
        returning id into destination_id;
      insert into public.historical_import_destinations
        values(source_row.id,'expenses',destination_id,'created',auth.uid(),now())
        on conflict(source_row_id,destination_table) do nothing;
      financial_count:=financial_count+1;

    elsif source_row.source_sheet in ('Books','Chapters') then
      request_id:=md5('historical-sale:'||source_row.id::text)::uuid;
      destination_id:=public.sell_material(resolution->>'material_kind',(resolution->>'item_id')::uuid,
        (resolution->>'student_id')::uuid,(resolution->>'class_id')::uuid,
        (resolution->>'unit_price')::numeric,0,(resolution->>'sold_on')::date,request_id);
      if resolution->>'material_kind'='book' then
        insert into public.historical_import_destinations
          values(source_row.id,'book_sales',destination_id,'created',auth.uid(),now())
          on conflict(source_row_id,destination_table) do nothing;
      else
        insert into public.historical_import_destinations
          values(source_row.id,'chapter_sales',destination_id,'created',auth.uid(),now())
          on conflict(source_row_id,destination_table) do nothing;
      end if;
      if coalesce((resolution->>'payment_verified')::boolean,false) then
        request_id:=md5('historical-material-receipt:'||source_row.id::text)::uuid;
        perform public.pay_material(resolution->>'material_kind',destination_id,
          (resolution->>'payment_amount')::numeric,(resolution->>'payment_paid_on')::date,request_id,false);
        select m.id into existing_id from public.material_payments m where m.request_id=request_id;
        insert into public.historical_import_destinations
          values(source_row.id,'material_payments',existing_id,'created',auth.uid(),now())
          on conflict(source_row_id,destination_table) do nothing;
      end if;
      financial_count:=financial_count+1;

    elsif source_row.source_sheet='PartnerNotes' then
      request_id:=md5('historical-partner:'||source_row.id::text)::uuid;
      destination_id:=public.record_partner_transaction((resolution->>'partner_id')::uuid,
        resolution->>'transaction_kind',(resolution->>'amount')::numeric,
        (resolution->>'transacted_on')::date,nullif(trim(resolution->>'note'),''),request_id);
      insert into public.historical_import_destinations
        values(source_row.id,'partner_transactions',destination_id,'created',auth.uid(),now())
        on conflict(source_row_id,destination_table) do nothing;
      financial_count:=financial_count+1;
    end if;

    update public.historical_import_source_rows
      set posting_status='posted',destination_table=case
        when source_row.source_sheet in ('Students','Teachers','Classes') then
          case source_row.source_sheet when 'Students' then 'students' when 'Teachers' then 'teachers' else 'class_rooms' end
        when source_row.source_sheet='Registrations' then 'monthly_memberships'
        when source_row.source_sheet='Payments' then 'payments'
        when source_row.source_sheet='Books' then 'book_sales'
        when source_row.source_sheet='Chapters' then 'chapter_sales'
        when source_row.source_sheet='PartnerNotes' then 'partner_transactions'
        else 'expenses' end,
        destination_id=destination_id
      where id=source_row.id;
    insert into public.audit_logs(table_name,action,row_id,actor_id,new_data,reason,approved_by)
      values('historical_import_source_rows','POST',source_row.id::text,auth.uid(),
        jsonb_build_object('source_key',source_row.source_key,'source_sheet',source_row.source_sheet,
          'destination_table',case
            when source_row.source_sheet='Students' then 'students'
            when source_row.source_sheet='Teachers' then 'teachers'
            when source_row.source_sheet='Classes' then 'class_rooms'
            when source_row.source_sheet='Registrations' then 'monthly_memberships'
            when source_row.source_sheet='Payments' then 'payments'
            when source_row.source_sheet='Books' then 'book_sales'
            when source_row.source_sheet='Chapters' then 'chapter_sales'
            when source_row.source_sheet='PartnerNotes' then 'partner_transactions'
            else 'expenses' end,
          'destination_id',destination_id,'posting_status','posted'),
        source_row.review_reason,auth.uid());
    if mapping_status='matched_existing' then matched_count:=matched_count+1;
    else posted_count:=posted_count+1; end if;
  end loop;

  select count(*) into review_count from public.historical_import_source_rows
    where batch_id=p_batch_id and posting_status='pending'
      and (review_status<>'accepted' or review_resolution='{}'::jsonb
        or source_sheet not in ('Students','Teachers','Classes','Registrations','Payments','Expenses','Books','Chapters','PartnerNotes'));
  insert into public.audit_logs(table_name,action,row_id,actor_id,new_data,reason,approved_by)
    values('historical_import_batches','POST',p_batch_id::text,auth.uid(),
      jsonb_build_object('posted',posted_count,'matched',matched_count,'duplicates',duplicate_count,
        'requiring_review',review_count,'financial_transactions',financial_count),
      'Administrator confirmed operational posting',auth.uid());
  return jsonb_build_object('posted',posted_count,'matched',matched_count,
    'duplicates',duplicate_count,'requiring_review',review_count,
    'financial_transactions',financial_count);
end $$;

revoke all on function public.validate_historical_import_resolution(text,jsonb),
  public.resolve_historical_import_row(uuid,jsonb,text),
  public.preview_historical_import_batch(uuid),
  public.post_historical_import_batch(uuid,boolean) from public,anon,authenticated;
grant execute on function public.resolve_historical_import_row(uuid,jsonb,text),
  public.preview_historical_import_batch(uuid),
  public.post_historical_import_batch(uuid,boolean) to authenticated;

commit;
