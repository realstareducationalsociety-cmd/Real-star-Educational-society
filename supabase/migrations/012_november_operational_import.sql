-- 012_november_operational_import.sql
-- Phase 2: Operational Import of Confirmed November 2026 Students
-- Reuses existing teachers and class_rooms; creates students, enrollments, monthly memberships, and payments.

begin;

-- ============================================================================
-- 1. SEED / CONFIRM THE 10 TEACHERS
-- ============================================================================
insert into public.teachers(full_name, active)
values
  ('Farzan Noori', true),
  ('Mohaddisa Yasin', true),
  ('Ali Hassani', true),
  ('Shakila', true),
  ('Wahida Mohassel', true),
  ('Malali Naziri', true),
  ('Danish', true),
  ('Khatima', true),
  ('Tahira Sakhizada', true),
  ('Freshta', true)
on conflict do nothing;

-- ============================================================================
-- 2. SEED / CONFIRM THE 23 CLASS GROUPS
-- ============================================================================
do $$
declare
  t_farzan uuid;
  t_mohaddisa uuid;
  t_ali uuid;
  t_shakila uuid;
  t_wahida uuid;
  t_malali uuid;
  t_danish uuid;
  t_khatima uuid;
  t_tahira uuid;
  t_freshta uuid;
begin
  select id into t_farzan from public.teachers where full_name = 'Farzan Noori' limit 1;
  select id into t_mohaddisa from public.teachers where full_name = 'Mohaddisa Yasin' limit 1;
  select id into t_ali from public.teachers where full_name = 'Ali Hassani' limit 1;
  select id into t_shakila from public.teachers where full_name = 'Shakila' limit 1;
  select id into t_wahida from public.teachers where full_name = 'Wahida Mohassel' limit 1;
  select id into t_malali from public.teachers where full_name = 'Malali Naziri' limit 1;
  select id into t_danish from public.teachers where full_name = 'Danish' limit 1;
  select id into t_khatima from public.teachers where full_name = 'Khatima' limit 1;
  select id into t_tahira from public.teachers where full_name = 'Tahira Sakhizada' limit 1;
  select id into t_freshta from public.teachers where full_name = 'Freshta' limit 1;

  -- 1. Special A2 (5-6 pm)
  if not exists(select 1 from class_rooms where title = 'Special A2' and teacher_id = t_farzan and start_time = '17:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Special A2', t_farzan, 2000, '17:00', '18:00', true);
  end if;

  -- 2. Special A2 (4-5 pm)
  if not exists(select 1 from class_rooms where title = 'Special A2' and teacher_id = t_farzan and start_time = '16:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Special A2', t_farzan, 1000, '16:00', '17:00', true);
  end if;

  -- 3. Special B1 (4-5 pm)
  if not exists(select 1 from class_rooms where title = 'Special B1' and teacher_id = t_farzan and start_time = '16:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Special B1', t_farzan, 2000, '16:00', '17:00', true);
  end if;

  -- 4. Special B1 (3-4 pm)
  if not exists(select 1 from class_rooms where title = 'Special B1' and teacher_id = t_farzan and start_time = '15:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Special B1', t_farzan, 1200, '15:00', '16:00', true);
  end if;

  -- 5. Special Class (2-3 pm)
  if not exists(select 1 from class_rooms where title = 'Special Class' and teacher_id = t_farzan and start_time = '14:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Special Class', t_farzan, 2000, '14:00', '15:00', true);
  end if;

  -- 6. Special B2 (3-4 pm)
  if not exists(select 1 from class_rooms where title = 'Special B2' and teacher_id = t_farzan and start_time = '15:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Special B2', t_farzan, 1500, '15:00', '16:00', true);
  end if;

  -- 7. Intermadiate class (3-4 pm)
  if not exists(select 1 from class_rooms where title = 'Intermadiate class' and teacher_id = t_wahida and start_time = '15:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Intermadiate class', t_wahida, 1500, '15:00', '16:00', true);
  end if;

  -- 8. Advance class (2-3 pm)
  if not exists(select 1 from class_rooms where title = 'Advance class' and teacher_id = t_wahida and start_time = '14:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Advance class', t_wahida, 2000, '14:00', '15:00', true);
  end if;

  -- 9. Get Involved 1 (3-4 pm)
  if not exists(select 1 from class_rooms where title = 'Get Involved 1' and teacher_id = t_danish and start_time = '15:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Get Involved 1', t_danish, 1500, '15:00', '16:00', true);
  end if;

  -- 10. Get Involved 2 (5-6 pm)
  if not exists(select 1 from class_rooms where title = 'Get Involved 2' and teacher_id = t_danish and start_time = '17:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Get Involved 2', t_danish, 1500, '17:00', '18:00', true);
  end if;

  -- 11. Computer MS Excel (4-5 pm)
  if not exists(select 1 from class_rooms where title = 'Computer MS Excel' and teacher_id = t_danish and start_time = '16:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Computer MS Excel', t_danish, 1500, '16:00', '17:00', true);
  end if;

  -- 12. Computer MS Excel (2-3 pm)
  if not exists(select 1 from class_rooms where title = 'Computer MS Excel' and teacher_id = t_danish and start_time = '14:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Computer MS Excel', t_danish, 1500, '14:00', '15:00', true);
  end if;

  -- 13. Family & Friends 1 (4-5 pm)
  if not exists(select 1 from class_rooms where title = 'Family & Friends 1' and teacher_id = t_ali and start_time = '16:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Family & Friends 1', t_ali, 1000, '16:00', '17:00', true);
  end if;

  -- 14. Family & Friends 1 (Starter) (3-4 pm)
  if not exists(select 1 from class_rooms where title = 'Family & Friends 1' and teacher_id = t_ali and start_time = '15:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Family & Friends 1', t_ali, 1000, '15:00', '16:00', true);
  end if;

  -- 15. Family & Friends 2 (2-3 pm)
  if not exists(select 1 from class_rooms where title = 'Family & Friends 2' and teacher_id = t_shakila and start_time = '14:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Family & Friends 2', t_shakila, 1000, '14:00', '15:00', true);
  end if;

  -- 16. Family & Friends 4 (5-6 pm)
  if not exists(select 1 from class_rooms where title = 'Family & Friends 4' and teacher_id = t_shakila and start_time = '17:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Family & Friends 4', t_shakila, 1000, '17:00', '18:00', true);
  end if;

  -- 17. Family & Friends 3 (4-5 pm)
  if not exists(select 1 from class_rooms where title = 'Family & Friends 3' and teacher_id = t_malali and start_time = '16:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Family & Friends 3', t_malali, 1000, '16:00', '17:00', true);
  end if;

  -- 18. Family & Friends 4 (5-6 pm)
  if not exists(select 1 from class_rooms where title = 'Family & Friends 4' and teacher_id = t_malali and start_time = '17:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Family & Friends 4', t_malali, 1000, '17:00', '18:00', true);
  end if;

  -- 19. Family & Friends 3 (2-3 pm)
  if not exists(select 1 from class_rooms where title = 'Family & Friends 3' and teacher_id = t_mohaddisa and start_time = '14:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Family & Friends 3', t_mohaddisa, 1000, '14:00', '15:00', true);
  end if;

  -- 20. Family & Friends 4 (4-5 pm)
  if not exists(select 1 from class_rooms where title = 'Family & Friends 4' and teacher_id = t_mohaddisa and start_time = '16:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Family & Friends 4', t_mohaddisa, 1000, '16:00', '17:00', true);
  end if;

  -- 21. Grade 1,2,3 (5-6 pm)
  if not exists(select 1 from class_rooms where title = 'Grade 1,2,3' and teacher_id = t_tahira and start_time = '16:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Grade 1,2,3', t_tahira, 1000, '16:00', '18:00', true);
  end if;

  -- 22. Family & Friends 2 (3-4 pm) - Khatima
  if not exists(select 1 from class_rooms where title = 'Family & Friends 2' and teacher_id = t_khatima and start_time = '15:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Family & Friends 2', t_khatima, 1000, '15:00', '16:00', true);
  end if;

  -- 23. Art (4-5 pm) - Freshta
  if not exists(select 1 from class_rooms where title = 'Art' and teacher_id = t_freshta and start_time = '16:00') then
    insert into class_rooms(title, teacher_id, default_fee, start_time, end_time, active)
    values('Art', t_freshta, 1000, '16:00', '17:00', true);
  end if;
end $$;

-- ============================================================================
-- 3. ENSURE NOVEMBER 2026 BILLING PERIOD IS OPEN
-- ============================================================================
insert into public.billing_periods(year_month, status)
values('2026-11-01', 'open')
on conflict(year_month) do update set status = 'open';

-- ============================================================================
-- 4. AUTHORITATIVE NOVEMBER REGISTRATION & PAYMENT IMPORT RPC
-- ============================================================================
create or replace function public.import_november_registration(
  p_candidate jsonb,
  p_request uuid
) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  prior registration_requests%rowtype;
  v_student_id uuid;
  v_student_code text;
  v_is_new_student boolean := false;
  v_class_id uuid;
  v_room class_rooms%rowtype;
  v_enrollment_id uuid;
  v_membership_id uuid;
  v_period_id uuid;
  v_payment_id uuid := null;
  v_first_name text;
  v_last_name text;
  v_phone text;
  v_class_title text;
  v_teacher_name text;
  v_schedule text;
  v_original_fee numeric;
  v_agreed_fee numeric;
  v_discount numeric;
  v_discount_reason text;
  v_entitlement numeric;
  v_std_share numeric;
  v_is_exception boolean;
  v_exception_reason text;
  v_is_scholarship boolean;
  v_pay_amount numeric;
  v_pay_date date;
  v_pay_method text;
  v_pay_ref text;
  v_source_key text;
  v_source_row_id uuid;
  v_source_batch_id uuid;
  v_result jsonb;
begin
  -- 1. Authorization check: administrator only
  if not staff_has_any(array['admin']) then
    raise exception 'Administrator approval required' using errcode='42501';
  end if;
  if p_request is null or p_candidate is null then
    raise exception 'Candidate data and request ID required';
  end if;

  -- 2. Concurrency and Idempotency check
  perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger', 0));
  perform pg_advisory_xact_lock(hashtextextended(p_request::text, 0));

  select * into prior from registration_requests where id = p_request;
  if found then
    return prior.result;
  end if;

  -- 3. Extract candidate parameters
  v_first_name := trim(coalesce(p_candidate->>'first_name', split_part(trim(p_candidate->>'student_name'), ' ', 1), ''));
  v_last_name := trim(coalesce(p_candidate->>'last_name', substr(trim(p_candidate->>'student_name'), length(v_first_name) + 2), ''));
  v_phone := nullif(trim(coalesce(p_candidate->>'contact_phone', p_candidate->>'phone', '')), '');
  v_class_title := trim(coalesce(p_candidate->>'class_name', ''));
  v_teacher_name := trim(coalesce(p_candidate->>'teacher_name', ''));
  v_schedule := trim(coalesce(p_candidate->>'class_schedule', ''));
  v_source_key := trim(coalesce(p_candidate->>'source_key', ''));

  if length(v_first_name) = 0 then
    raise exception 'Student first name is required';
  end if;

  -- 4. Lookup or create student profile
  v_student_id := nullif(p_candidate->>'student_id', '')::uuid;
  if v_student_id is not null and exists(select 1 from students where id = v_student_id) then
    select student_code into v_student_code from students where id = v_student_id;
    v_is_new_student := false;
  else
    -- Match by exact name and phone if available
    select id, student_code into v_student_id, v_student_code from students s
    where lower(trim(s.first_name)) = lower(v_first_name)
      and lower(trim(s.last_name)) = lower(v_last_name)
      and (v_phone is null or s.phone = v_phone)
    order by s.created_at asc limit 1;

    if v_student_id is not null then
      v_is_new_student := false;
    else
      -- Create new permanent student profile
      insert into students(first_name, last_name, phone, registered_on, active, notes)
      values(v_first_name, v_last_name, v_phone, '2026-11-01', true, 'Imported from November 2026 source candidate')
      returning id, student_code into v_student_id, v_student_code;
      v_is_new_student := true;
    end if;
  end if;

  -- 5. Match class room
  v_class_id := nullif(p_candidate->>'class_id', '')::uuid;
  if v_class_id is not null then
    select * into v_room from class_rooms where id = v_class_id;
  end if;

  if v_room.id is null then
    -- Match by title and teacher name
    select c.* into v_room from class_rooms c
    join teachers t on t.id = c.teacher_id
    where (lower(trim(c.title)) = lower(v_class_title) or lower(trim(c.title)) like lower(v_class_title) || '%')
      and (length(v_teacher_name) = 0 or lower(trim(t.full_name)) like '%' || lower(v_teacher_name) || '%')
    order by c.id limit 1;
  end if;

  if v_room.id is null then
    -- Fallback to any class matching title
    select * into v_room from class_rooms
    where lower(trim(title)) = lower(v_class_title) or lower(trim(title)) like lower(v_class_title) || '%'
    order by id limit 1;
  end if;

  if v_room.id is null then
    raise exception 'Class room not found for title: %, teacher: %', v_class_title, v_teacher_name;
  end if;

  -- 6. Enrollment
  insert into enrollments(student_id, class_id, enrolled_on, active)
  values(v_student_id, v_room.id, '2026-11-01', true)
  on conflict(student_id, class_id) do update set active = true
  returning id into v_enrollment_id;

  -- 7. Billing period
  select id into v_period_id from billing_periods where year_month = '2026-11-01' and status = 'open';
  if v_period_id is null then
    raise exception 'Billing period 2026-11-01 is not open';
  end if;

  -- 8. Financial values
  v_original_fee := coalesce((p_candidate->>'original_fee')::numeric, v_room.default_fee, 1500);
  v_agreed_fee := coalesce((p_candidate->>'agreed_fee')::numeric, v_original_fee);
  v_discount := coalesce((p_candidate->>'discount')::numeric, 0);
  if v_discount > v_agreed_fee then
    v_discount := v_agreed_fee;
  end if;
  v_discount_reason := coalesce(p_candidate->>'discount_reason', '');
  v_std_share := round(v_agreed_fee * 0.50, 2);
  v_entitlement := coalesce((p_candidate->>'teacher_entitlement')::numeric, v_std_share);
  v_is_exception := (v_entitlement <> v_std_share);
  v_exception_reason := coalesce(p_candidate->>'exception_reason', '');
  v_is_scholarship := (v_agreed_fee > 0 and v_discount >= v_agreed_fee);

  if v_discount > 0 and length(trim(v_discount_reason)) < 4 then
    v_discount_reason := case when v_is_scholarship then 'Full scholarship confirmed' else 'Approved student discount' end;
  end if;
  if v_is_exception and length(trim(v_exception_reason)) < 4 then
    v_exception_reason := 'Approved teacher entitlement exception';
  end if;

  -- 9. Monthly Membership
  select id into v_membership_id from monthly_memberships
  where period_id = v_period_id and enrollment_id = v_enrollment_id and registration_active;

  if v_membership_id is null then
    insert into monthly_memberships(
      period_id, enrollment_id, teacher_id, class_title_snapshot, registered_on,
      original_fee, base_fee, discount, teacher_discount_share,
      manual_teacher_share, manual_office_share, manual_adjustment_reason,
      teacher_share_mode, teacher_share_reason,
      manual_adjusted_by, manual_adjusted_at,
      agreement_approved_by, agreement_approved_at,
      discount_reason, notes,
      sponsored_confirmed, start_time_snapshot, end_time_snapshot,
      proration_rule, registration_type, registration_active
    ) values (
      v_period_id, v_enrollment_id, v_room.teacher_id, v_room.title, '2026-11-01',
      v_original_fee, v_agreed_fee, v_discount, 0,
      case when v_is_exception then v_entitlement else null end,
      case when v_is_exception then (v_agreed_fee - v_discount - v_entitlement) else null end,
      case when v_is_exception then v_exception_reason else null end,
      case when v_is_exception then 'custom' else 'standard' end,
      case when v_is_exception then v_exception_reason else null end,
      case when v_is_exception then auth.uid() else null end,
      case when v_is_exception then now() else null end,
      auth.uid(), now(),
      v_discount_reason,
      coalesce(p_candidate->>'notes', 'Imported from November candidate ' || v_source_key),
      v_is_scholarship,
      v_room.start_time, v_room.end_time,
      'manual_agreement',
      case when v_is_new_student then 'new' else 'returning' end,
      true
    ) returning id into v_membership_id;
  end if;

  -- 10. Record genuine payment if present
  v_pay_amount := coalesce((p_candidate->>'payment_amount')::numeric, 0);
  v_pay_date := nullif(p_candidate->>'payment_date', '')::date;
  v_pay_method := coalesce(p_candidate->>'payment_method', 'cash');
  v_pay_ref := coalesce(p_candidate->>'payment_reference', 'Historical import November candidate: ' || v_source_key);

  if v_pay_amount > 0 and v_pay_date is not null and not v_is_scholarship then
    if not exists(select 1 from payments where monthly_membership_id = v_membership_id and voided_at is null) then
      v_payment_id := (select record_tuition_payment(
        v_membership_id, v_pay_amount, v_pay_date, v_pay_method, v_pay_ref,
        md5('pay-' || p_request::text)::uuid
      ))->>'id';
    end if;
  end if;

  -- 11. Staging table provenance tracking
  if length(v_source_key) > 0 then
    select id, batch_id into v_source_row_id, v_source_batch_id
    from historical_import_source_rows
    where source_key = v_source_key limit 1;

    if v_source_row_id is not null then
      update historical_import_source_rows
      set review_status = 'accepted',
          posting_status = 'posted',
          destination_table = 'monthly_memberships',
          destination_id = v_membership_id,
          reviewed_by = auth.uid(),
          reviewed_at = now(),
          review_reason = 'Approved in November operational import'
      where id = v_source_row_id;

      insert into historical_import_destinations(source_row_id, destination_table, destination_id, mapping_status, created_by)
      values(v_source_row_id, 'monthly_memberships', v_membership_id, 'created', auth.uid())
      on conflict(source_row_id, destination_table) do update set destination_id = v_membership_id;
    end if;
  end if;

  -- 12. Build result and audit
  v_result := jsonb_build_object(
    'success', true,
    'student_id', v_student_id,
    'student_code', v_student_code,
    'is_new_student', v_is_new_student,
    'class_id', v_room.id,
    'class_title', v_room.title,
    'membership_id', v_membership_id,
    'payment_id', v_payment_id,
    'payment_amount', v_pay_amount,
    'is_scholarship', v_is_scholarship,
    'amount_due', greatest(0, v_agreed_fee - v_discount),
    'teacher_entitlement', v_entitlement
  );

  insert into registration_requests(id, actor_id, kind, payload, result, created_at)
  values(p_request, auth.uid(), 'november_import', p_candidate, v_result, now());

  return v_result;
end $$;

-- ============================================================================
-- 5. BATCH IMPORT RPC
-- ============================================================================
create or replace function public.import_november_batch(
  p_candidates jsonb,
  p_batch_request uuid
) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  candidate jsonb;
  single_req uuid;
  single_res jsonb;
  v_reviewed integer := 0;
  v_created integer := 0;
  v_matched integer := 0;
  v_memberships integer := 0;
  v_payments integer := 0;
  v_unresolved integer := 0;
  v_scholarships integer := 0;
  v_total_tuition numeric := 0;
  v_total_collected numeric := 0;
  v_total_teacher numeric := 0;
  v_total_outstanding numeric := 0;
  prior registration_requests%rowtype;
  v_batch_result jsonb;
begin
  if not staff_has_any(array['admin']) then
    raise exception 'Administrator approval required' using errcode='42501';
  end if;

  select * into prior from registration_requests where id = p_batch_request;
  if found then
    return prior.result;
  end if;

  for candidate in select value from jsonb_array_elements(p_candidates) loop
    v_reviewed := v_reviewed + 1;
    if (candidate->>'review_status') = 'needs_review' and (candidate->>'force_approve')::boolean is not true then
      v_unresolved := v_unresolved + 1;
      continue;
    end if;

    single_req := md5(p_batch_request::text || '-' || coalesce(candidate->>'source_key', v_reviewed::text))::uuid;
    begin
      single_res := import_november_registration(candidate, single_req);
      if (single_res->>'success')::boolean is true then
        v_memberships := v_memberships + 1;
        if (single_res->>'is_new_student')::boolean is true then
          v_created := v_created + 1;
        else
          v_matched := v_matched + 1;
        end if;
        if (single_res->>'is_scholarship')::boolean is true then
          v_scholarships := v_scholarships + 1;
        end if;
        if single_res->>'payment_id' is not null then
          v_payments := v_payments + 1;
          v_total_collected := v_total_collected + (single_res->>'payment_amount')::numeric;
        end if;
        v_total_tuition := v_total_tuition + (single_res->>'amount_due')::numeric;
        v_total_teacher := v_total_teacher + (single_res->>'teacher_entitlement')::numeric;
        v_total_outstanding := v_total_outstanding + greatest(0, (single_res->>'amount_due')::numeric - coalesce((single_res->>'payment_amount')::numeric, 0));
      else
        v_unresolved := v_unresolved + 1;
      end if;
    exception when others then
      v_unresolved := v_unresolved + 1;
    end;
  end loop;

  v_batch_result := jsonb_build_object(
    'reviewed_count', v_reviewed,
    'created_students', v_created,
    'matched_students', v_matched,
    'memberships_saved', v_memberships,
    'payments_posted', v_payments,
    'unresolved_count', v_unresolved,
    'scholarships_count', v_scholarships,
    'total_tuition', v_total_tuition,
    'total_collected', v_total_collected,
    'total_teacher_entitlement', v_total_teacher,
    'total_outstanding', v_total_outstanding
  );

  insert into registration_requests(id, actor_id, kind, payload, result, created_at)
  values(p_batch_request, auth.uid(), 'november_batch_import', jsonb_build_object('count', v_reviewed), v_batch_result, now());

  return v_batch_result;
end $$;

-- ============================================================================
-- 6. REAL-TIME NOVEMBER OPERATIONAL SUMMARY RPC
-- ============================================================================
create or replace function public.get_november_import_summary()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_period_id uuid;
  v_unique_students bigint;
  v_new_students bigint;
  v_matched_students bigint;
  v_memberships bigint;
  v_scholarships bigint;
  v_verified_payments bigint;
  v_total_tuition numeric;
  v_total_collected numeric;
  v_total_outstanding numeric;
  v_total_teacher numeric;
  v_awaiting_review bigint;
begin
  if not staff_has_any(array['admin','accountant','registrar']) then
    raise exception 'Staff access required' using errcode='42501';
  end if;

  select id into v_period_id from billing_periods where year_month = '2026-11-01';

  select
    count(distinct e.student_id),
    count(*) filter(where m.registration_type = 'new'),
    count(*) filter(where m.registration_type <> 'new'),
    count(*),
    count(*) filter(where m.sponsored_confirmed or (m.amount_due = 0 and m.discount > 0)),
    coalesce(sum(m.amount_due), 0),
    coalesce(sum(m.effective_teacher_entitlement), 0)
  into
    v_unique_students, v_new_students, v_matched_students, v_memberships,
    v_scholarships, v_total_tuition, v_total_teacher
  from monthly_memberships m
  join enrollments e on e.id = m.enrollment_id
  where m.period_id = v_period_id and m.registration_active;

  select
    count(*),
    coalesce(sum(amount), 0)
  into
    v_verified_payments, v_total_collected
  from payments
  where monthly_membership_id in (select id from monthly_memberships where period_id = v_period_id and registration_active)
    and voided_at is null;

  v_total_outstanding := greatest(0, coalesce(v_total_tuition, 0) - coalesce(v_total_collected, 0));

  select count(*) into v_awaiting_review
  from historical_import_source_rows
  where review_status = 'needs_review' or (posting_status = 'pending' and source_sheet in ('Registrations','RegistrationLeads'));

  return jsonb_build_object(
    'unique_students', coalesce(v_unique_students, 0),
    'new_students', coalesce(v_new_students, 0),
    'matched_students', coalesce(v_matched_students, 0),
    'memberships', coalesce(v_memberships, 0),
    'scholarships', coalesce(v_scholarships, 0),
    'verified_payments', coalesce(v_verified_payments, 0),
    'total_tuition', coalesce(v_total_tuition, 0),
    'total_collected', coalesce(v_total_collected, 0),
    'total_outstanding', coalesce(v_total_outstanding, 0),
    'total_teacher_entitlement', coalesce(v_total_teacher, 0),
    'awaiting_review', coalesce(v_awaiting_review, 0)
  );
end $$;

-- Permissions
grant execute on function public.import_november_registration(jsonb, uuid) to authenticated;
grant execute on function public.import_november_batch(jsonb, uuid) to authenticated;
grant execute on function public.get_november_import_summary() to authenticated;

notify pgrst, 'reload schema';
commit;
