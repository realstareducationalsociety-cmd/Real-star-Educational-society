-- REAL STAR EDUCATIONAL SOCIETY | November 2026 | SAFE administrator finalization
-- Requires candidate/identity schema from migrations 013/014, the local
-- migration chain through 015, and register_dashboard_student(jsonb,uuid)
-- from migration 010 with confirmation guard from migration 011.
-- This is a BACKEND CAPABILITY, not an instruction to assume financial approval.
-- 140 November roster source rows: 107 already have documented class links.
-- Others (including 66 separate registration leads) stay for individual review.
-- Nothing is posted when this file is installed. Only an authenticated ADMIN
-- may later explicitly approve specific rows via the new RPC, supplying amounts.
-- No receipts or payments are ever imported or fabricated by this RPC.
-- IMPORTANT: Test in staging first and back up the production database.

BEGIN;

-- Display the roster with sourced fee SUGGESTIONS, NOT approved tuition.
-- Security-invoker means underlying admin-only RLS still applies.
CREATE OR REPLACE VIEW public.november_2026_fee_approval_queue
WITH (security_invoker=true) AS
SELECT
  c.id AS candidate_id,
  c.source_row_id,
  c.source_key,
  r.source_row,
  s.student_code,
  COALESCE(s.first_name,c.first_name) AS first_name,
  COALESCE(s.last_name,c.last_name) AS last_name,
  COALESCE(NULLIF(btrim(concat_ws(' ',s.first_name,s.last_name)),''),c.student_name) AS student_name,
  COALESCE(c.student_id,c.identity_student_id,c.approved_student_id) AS student_id,
  c.enrollment_id,
  e.class_id,
  COALESCE(cr.title,c.class_title) AS current_class,
  COALESCE(t.full_name,c.teacher_name) AS current_teacher,
  COALESCE(cr.start_time,c.start_time) AS start_time,
  COALESCE(cr.end_time,c.end_time) AS end_time,
  NULLIF(src.original_tuition_text,'') AS source_tuition_text,
  NULLIF(src.discount_text,'') AS source_discount_text,
  CASE WHEN src.original_tuition_text ~ '^[0-9]+([.][0-9]{1,2})?$'
       THEN src.original_tuition_text::numeric(12,2) ELSE NULL END AS fee_proposal,
  CASE WHEN src.discount_text ~ '^[0-9]+([.][0-9]{1,2})?$'
       THEN src.discount_text::numeric(12,2) ELSE NULL END AS discount_proposal,
  CASE WHEN src.original_tuition_text ~ '^[0-9]+([.][0-9]{1,2})?$'
       THEN round(src.original_tuition_text::numeric * 0.50,2) ELSE NULL END AS standard_teacher_50_percent_proposal,
  CASE WHEN src.original_tuition_text ~ '^[0-9]+([.][0-9]{1,2})?$'
         AND src.discount_text ~ '^[0-9]+([.][0-9]{1,2})?$'
       THEN (src.original_tuition_text::numeric - src.discount_text::numeric) ELSE NULL END AS proposed_payable,
  CASE
    WHEN COALESCE(c.student_id,c.identity_student_id,c.approved_student_id) IS NULL
      OR c.enrollment_id IS NULL OR e.id IS NULL
      OR e.student_id IS DISTINCT FROM COALESCE(c.student_id,c.identity_student_id,c.approved_student_id)
      THEN 'REVIEW_IDENTITY_OR_CLASS'
    WHEN lower(regexp_replace(COALESCE(t.full_name,c.teacher_name),'[^a-zA-Z]','','g')) ~ '^tah(e|i)rasakhizada$' THEN 'MANUAL_SCHOOL_GROUP_REVIEW'
    WHEN src.original_tuition_text = '' THEN 'FEE_MISSING'
    WHEN src.original_tuition_text !~ '^[0-9]+([.][0-9]{1,2})?$' THEN 'FEE_INVALID'
    WHEN src.discount_text = '' THEN 'DISCOUNT_NOT_RECORDED'
    WHEN src.discount_text !~ '^[0-9]+([.][0-9]{1,2})?$' THEN 'DISCOUNT_INVALID'
    WHEN src.discount_text::numeric > src.original_tuition_text::numeric THEN 'DISCOUNT_GREATER_THAN_FEE'
    WHEN src.original_tuition_text::numeric = 0 THEN 'ZERO_TUITION_REQUIRES_EXPLICIT_APPROVAL'
    ELSE 'READY_FOR_ADMIN_TO_VERIFY'
  END AS review_flag,
  m.id AS existing_november_membership_id,
  c.status AS import_status,
  c.approved_tuition,
  c.approved_discount,
  c.membership_id AS imported_membership_id
FROM public.november_import_candidates c
JOIN public.historical_import_batches b ON b.id=c.batch_id
JOIN public.historical_import_source_rows r ON r.id=c.source_row_id
CROSS JOIN LATERAL (SELECT
  btrim(coalesce(r.source_payload->>'Original Tuition',r.source_payload->>'original_tuition','')) AS original_tuition_text,
  btrim(coalesce(r.source_payload->>'Discount',r.source_payload->>'discount','')) AS discount_text
) src
LEFT JOIN public.students s ON s.id=COALESCE(c.student_id,c.identity_student_id,c.approved_student_id)
LEFT JOIN public.enrollments e ON e.id=c.enrollment_id
LEFT JOIN public.class_rooms cr ON cr.id=e.class_id
LEFT JOIN public.teachers t ON t.id=cr.teacher_id
LEFT JOIN public.billing_periods p ON p.year_month=DATE '2026-11-01'
LEFT JOIN public.monthly_memberships m
  ON m.period_id=p.id AND m.enrollment_id=c.enrollment_id AND m.registration_active
WHERE b.source_sha256='15e9b64e02048eba03e59636e2875c56701c0d1160748da7a85e26c8c1e7cc64'
  AND c.source_sheet='Registrations';

REVOKE ALL ON public.november_2026_fee_approval_queue FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.november_2026_fee_approval_queue TO authenticated;

-- POST ONLY MANAGER-CONFIRMED student/class/fee rows, atomically.
-- Use from a logged-in ADMIN's Supabase client. Do not invoke via SQL Editor
-- as "postgres": that session is NOT an authenticated administrative user.
-- p_items is an array with entries like:
-- {
--   "candidate_id":"<UUID>", "confirmed":true,
--   "original_fee":1500,"agreed_fee":1500,"discount":200,
--   "discount_reason":"Management approved November discount",
--   "teacher_entitlement":750,
--   "registration_date":"2026-11-22",
--   "notes":"Original November registration day unknown; entered on this date"
-- }
-- When teacher_entitlement omitted, 50% of agreed_fee is applied.
-- To override teacher share, add teacher_exception_reason (>=4 chars).
-- If 0 tuition is a genuine scholarship, provide zero_fee_reason >=4 chars.
-- NO 'payment' field is allowed: historical receipts are unverified.
-- Any invalid item aborts the WHOLE batch without partial registration.
CREATE OR REPLACE FUNCTION public.november_finalize_confirmed_roster(
  p_items jsonb, p_request uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE
  v_item jsonb;
  v_candidate public.november_import_candidates%rowtype;
  v_enrollment public.enrollments%rowtype;
  v_class public.class_rooms%rowtype;
  v_existing uuid;
  v_student uuid;
  v_membership uuid;
  v_period uuid;
  v_date date;
  v_original numeric;
  v_fee numeric;
  v_discount numeric;
  v_teacher numeric;
  v_std numeric;
  v_discount_reason text;
  v_teacher_reason text;
  v_zero_reason text;
  v_payload jsonb;
  v_registration_request uuid;
  v_count integer := 0;
  v_already integer := 0;
  v_result jsonb;
BEGIN
  IF NOT public.staff_has_any(ARRAY['admin']) OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Logged-in administrator approval required' USING errcode='42501';
  END IF;
  IF p_request IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_items) < 1 OR jsonb_array_length(p_items) > 140 THEN
    RAISE EXCEPTION 'Supply a nonempty batch of at most 140 reviewed rows and a request UUID';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_items) AS x(value)
    GROUP BY x.value->>'candidate_id' HAVING count(*)>1
  ) THEN RAISE EXCEPTION 'Duplicate candidate IDs in the same request'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) AS x(value)
    WHERE x.value->'confirmed' IS DISTINCT FROM 'true'::jsonb
      OR x.value ? 'payment' OR x.value ? 'paid_on' OR x.value ? 'source_payment') THEN
    RAISE EXCEPTION 'Explicit approval required for each row; payments must be verified separately';
  END IF;
  IF to_regprocedure('public.register_dashboard_student(jsonb,uuid)') IS NULL THEN
    RAISE EXCEPTION 'Verified administrator registration RPC is missing; check migrations 010 and 011';
  END IF;
  -- Migration 010's deployed guard must permit NULL manual share columns when
  -- the entitlement is the standard 50% and the admin approval fields are set.
  -- Do not search for the phrase manual_teacher_share-is-null: the correct
  -- guard also checks NULL values inside its custom-share branch.
  PERFORM pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
  SELECT id INTO v_period FROM public.billing_periods
    WHERE year_month=DATE '2026-11-01';
  IF v_period IS NOT NULL AND EXISTS(
    SELECT 1 FROM public.billing_periods WHERE id=v_period AND status<>'open'
  ) THEN RAISE EXCEPTION 'November billing period is not open'; END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    IF v_item->>'candidate_id' IS NULL THEN RAISE EXCEPTION 'candidate_id is required'; END IF;
    SELECT c.* INTO v_candidate
    FROM public.november_import_candidates c
    JOIN public.historical_import_batches b ON b.id=c.batch_id
    WHERE c.id=(v_item->>'candidate_id')::uuid
      AND b.source_sha256='15e9b64e02048eba03e59636e2875c56701c0d1160748da7a85e26c8c1e7cc64'
      AND c.source_sheet='Registrations'
    FOR UPDATE OF c;
    IF NOT FOUND THEN RAISE EXCEPTION 'Verified November roster candidate not found'; END IF;
    IF v_candidate.status='rejected' THEN
      RAISE EXCEPTION 'This source row was rejected: %',v_candidate.id;
    END IF;
    IF v_candidate.status='duplicate' THEN
      IF v_candidate.membership_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.monthly_memberships
          WHERE id=v_candidate.membership_id AND registration_active) THEN
        v_already := v_already + 1;
        CONTINUE;
      END IF;
      RAISE EXCEPTION 'Duplicate source without verified membership: %',v_candidate.id;
    END IF;
    v_student := COALESCE(v_candidate.student_id,v_candidate.identity_student_id,v_candidate.approved_student_id);
    IF v_student IS NULL OR v_candidate.enrollment_id IS NULL THEN
      RAISE EXCEPTION 'Identity/class review still required for candidate: %',v_candidate.id;
    END IF;
    SELECT * INTO v_enrollment FROM public.enrollments
      WHERE id=v_candidate.enrollment_id AND student_id=v_student;
    IF NOT FOUND THEN RAISE EXCEPTION 'Class link mismatch for candidate %',v_candidate.id; END IF;
    SELECT * INTO v_class FROM public.class_rooms
      WHERE id=v_enrollment.class_id AND active;
    IF NOT FOUND THEN RAISE EXCEPTION 'Inactive or missing class for candidate %',v_candidate.id; END IF;
    IF (SELECT lower(regexp_replace(full_name,'[^a-zA-Z]','','g'))
        FROM public.teachers WHERE id=v_class.teacher_id) ~ '^tah(e|i)rasakhizada$' THEN
      RAISE EXCEPTION 'School group handled manually; candidate %',v_candidate.id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.historical_import_destinations d
       WHERE d.source_row_id=v_candidate.source_row_id AND d.destination_table='students'
         AND d.destination_id=v_student)
      OR NOT EXISTS (SELECT 1 FROM public.historical_import_destinations d
       WHERE d.source_row_id=v_candidate.source_row_id AND d.destination_table='enrollments'
         AND d.destination_id=v_candidate.enrollment_id) THEN
      RAISE EXCEPTION 'Missing audited source-to-student/class mapping for %',v_candidate.id;
    END IF;

    -- Values come ONLY from the manager-confirmed payload (not source guesses).
    v_original := NULLIF(v_item->>'original_fee','')::numeric;
    v_fee := NULLIF(v_item->>'agreed_fee','')::numeric;
    v_discount := NULLIF(v_item->>'discount','')::numeric;
    v_date := NULLIF(v_item->>'registration_date','')::date;
    v_discount_reason := NULLIF(btrim(v_item->>'discount_reason'),'');
    v_teacher_reason := NULLIF(btrim(v_item->>'teacher_exception_reason'),'');
    v_zero_reason := NULLIF(btrim(v_item->>'zero_fee_reason'),'');
    IF v_original IS NULL OR v_fee IS NULL OR v_discount IS NULL OR v_date IS NULL
       OR v_original < 0 OR v_fee < 0 OR v_discount < 0 OR v_discount>v_fee
       OR v_original<>round(v_original,2) OR v_fee<>round(v_fee,2)
       OR v_discount<>round(v_discount,2)
       OR v_original::text IN ('NaN','Infinity','-Infinity')
       OR v_fee::text IN ('NaN','Infinity','-Infinity')
       OR v_discount::text IN ('NaN','Infinity','-Infinity')
       OR date_trunc('month',v_date)::date<>DATE '2026-11-01' THEN
       RAISE EXCEPTION 'Invalid/unsigned fee, discount or November registration date: %',v_candidate.id;
    END IF;
    IF v_discount>0 AND coalesce(length(v_discount_reason),0)<4 THEN
      RAISE EXCEPTION 'Discount reason required for %',v_candidate.id;
    END IF;
    IF v_fee=0 AND coalesce(length(v_zero_reason),0)<4 THEN
      RAISE EXCEPTION 'Explicit free-tuition reason required for %',v_candidate.id;
    END IF;
    v_std := round(v_fee*0.50,2);
    v_teacher := COALESCE(NULLIF(v_item->>'teacher_entitlement','')::numeric,v_std);
    IF v_teacher<0 OR v_teacher<>round(v_teacher,2)
       OR v_teacher::text IN ('NaN','Infinity','-Infinity') THEN
      RAISE EXCEPTION 'Invalid teacher entitlement for %',v_candidate.id;
    END IF;
    IF v_teacher<>v_std AND coalesce(length(v_teacher_reason),0)<4 THEN
      RAISE EXCEPTION 'Teacher-share exception reason required for %',v_candidate.id;
    END IF;

    -- If admin already registered this source, return idempotently; no double charge.
    IF v_candidate.status='posted' AND v_candidate.membership_id IS NOT NULL THEN
      IF NOT EXISTS (SELECT 1 FROM public.monthly_memberships m
        JOIN public.billing_periods b ON b.id=m.period_id
        WHERE m.id=v_candidate.membership_id AND b.year_month=DATE '2026-11-01'
          AND m.enrollment_id=v_candidate.enrollment_id AND m.registration_active
          AND m.original_fee=v_original AND m.base_fee=v_fee AND m.discount=v_discount
          AND m.effective_teacher_entitlement=v_teacher) THEN
        RAISE EXCEPTION 'Already posted but approved amounts or membership changed: %',v_candidate.id;
      END IF;
      v_already := v_already + 1;
      CONTINUE;
    END IF;

    SELECT m.id INTO v_existing FROM public.monthly_memberships m
    JOIN public.billing_periods b ON b.id=m.period_id
    WHERE b.year_month=DATE '2026-11-01'
      AND m.enrollment_id=v_candidate.enrollment_id AND m.registration_active;
    IF v_existing IS NOT NULL THEN
      -- Another legitimate workflow posted this membership. Do not overwrite its fees.
      UPDATE public.november_import_candidates
      SET status='duplicate', membership_id=v_existing,
          review_note='November membership exists; no additional posting was performed.'
      WHERE id=v_candidate.id;
      v_already := v_already + 1;
      CONTINUE;
    END IF;

    v_payload := jsonb_build_object(
      'approved',true,'month','2026-11-01','date',v_date,
      'student_id',v_student,
      'classes',jsonb_build_array(jsonb_build_object(
        'class_id',v_enrollment.class_id,
        'original_fee',v_original,'agreed_fee',v_fee,'discount',v_discount,
        'discount_reason',v_discount_reason,
        'teacher_entitlement',v_teacher,
        'custom_teacher_share',(v_teacher<>v_std),
        'teacher_share_reason',v_teacher_reason,
        'payment',0,
        'sponsored_confirmed',coalesce((v_item->>'sponsored_confirmed')::boolean,false),
        'arrangement_notes',concat('November 2026 roster ',v_candidate.source_key,
          ' | Administrative entry; exact original entry day not verified. ',
          COALESCE(v_item->>'notes',''))
      ))
    );
    -- Deterministic per-row retry IDs inside this explicitly approved batch.
    v_registration_request := md5(p_request::text||':'||v_candidate.id::text)::uuid;
    v_result := public.register_dashboard_student(v_payload,v_registration_request);

    SELECT m.id INTO v_membership FROM public.monthly_memberships m
    JOIN public.billing_periods b ON b.id=m.period_id
    WHERE b.year_month=DATE '2026-11-01' AND m.enrollment_id=v_candidate.enrollment_id
      AND m.registration_active;
    IF v_membership IS NULL THEN
      RAISE EXCEPTION 'Registration RPC did not create expected membership for %',v_candidate.id;
    END IF;

    INSERT INTO public.historical_import_destinations
      (source_row_id,destination_table,destination_id,mapping_status,created_by)
    VALUES(v_candidate.source_row_id,'monthly_memberships',v_membership,'created',auth.uid())
    ON CONFLICT(source_row_id,destination_table) DO NOTHING;
    IF NOT EXISTS (SELECT 1 FROM public.historical_import_destinations
      WHERE source_row_id=v_candidate.source_row_id AND destination_table='monthly_memberships'
        AND destination_id=v_membership) THEN
      RAISE EXCEPTION 'Conflicting provenance for posted November membership: %',v_candidate.id;
    END IF;

    UPDATE public.november_import_candidates
    SET status='posted', student_id=v_student, enrollment_id=v_candidate.enrollment_id,
      membership_id=v_membership,
      identity_status=CASE WHEN v_candidate.identity_status='created' THEN 'created' ELSE 'matched' END,
      identity_student_id=v_student,
      approved_student_action=CASE WHEN v_candidate.identity_status='created' THEN 'create' ELSE 'match' END,
      approved_student_id=v_student,
      approved_class_id=v_enrollment.class_id,approved_tuition=v_fee,
      approved_discount=v_discount,approved_discount_reason=v_discount_reason,
      approved_teacher_entitlement=v_teacher,
      approved_teacher_exception_reason=v_teacher_reason,
      approved_registered_on=v_date,approved_payment=0,
      approved_payment_verified=false,approved_payment_date=null,
      approved_by=auth.uid(),approved_at=now(),posted_at=now(),
      blocking_reasons='[]'::jsonb,
      review_note='Fee and monthly membership approved by administrator. No receipt was imported.'
    WHERE id=v_candidate.id;

    INSERT INTO public.audit_logs(table_name,action,row_id,actor_id,new_data,reason,approved_by)
    VALUES('november_import_candidates','POST_APPROVED',v_candidate.id::text,auth.uid(),
      jsonb_build_object('membership_id',v_membership,'month','2026-11',
       'agreed_fee',v_fee,'discount',v_discount,'teacher_entitlement',v_teacher,'payment_posted',false),
      'Administrator-confirmed November enrollment and financial agreement; receipts excluded',auth.uid());
    v_count := v_count + 1;
  END LOOP;
  RETURN jsonb_build_object('month','2026-11','new_monthly_registrations',v_count,
    'already_registered_or_posted',v_already,
    'payments_created',0,
    'total_monthly_registrations',(SELECT count(*) FROM public.monthly_memberships m
      JOIN public.billing_periods b ON b.id=m.period_id
      WHERE b.year_month=DATE '2026-11-01' AND m.registration_active));
END;
$fn$;

REVOKE ALL ON FUNCTION public.november_finalize_confirmed_roster(jsonb,uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.november_finalize_confirmed_roster(jsonb,uuid)
  TO authenticated;

-- Disable the older generic bulk poster when it exists. It can include
-- RegistrationLeads, while this finalizer intentionally accepts only the
-- verified 140-row Registrations roster.
DO $disable_old_poster$
BEGIN
  IF to_regprocedure('public.november_import_post(integer,uuid)') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON FUNCTION public.november_import_post(integer,uuid) FROM PUBLIC,anon,authenticated';
  END IF;
END;
$disable_old_poster$;

-- Resolve the remaining roster-only identity/class gaps using existing
-- profiles and classes. This RPC never creates students or monthly finances.
CREATE OR REPLACE FUNCTION public.november_link_existing_roster_candidate(
  p_candidate uuid, p_student uuid, p_class uuid, p_reason text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $link$
DECLARE
  v_candidate public.november_import_candidates%rowtype;
  v_enrollment uuid;
  v_enrollment_active boolean;
  v_class public.class_rooms%rowtype;
BEGIN
  IF auth.uid() IS NULL OR NOT public.staff_has_any(ARRAY['admin']) THEN
    RAISE EXCEPTION 'Logged-in administrator access required' USING errcode='42501';
  END IF;
  IF p_student IS NULL OR p_class IS NULL OR length(trim(coalesce(p_reason,''))) < 4 THEN
    RAISE EXCEPTION 'Choose an existing student, an existing class and record a review reason';
  END IF;
  SELECT c.* INTO v_candidate FROM public.november_import_candidates c
    JOIN public.historical_import_batches b ON b.id=c.batch_id
    WHERE c.id=p_candidate AND c.source_sheet='Registrations'
      AND b.source_sha256='15e9b64e02048eba03e59636e2875c56701c0d1160748da7a85e26c8c1e7cc64'
    FOR UPDATE OF c;
  IF NOT FOUND THEN RAISE EXCEPTION 'November roster candidate not found'; END IF;
  IF v_candidate.status IN ('posted','duplicate','rejected') THEN
    RAISE EXCEPTION 'This roster row is already posted, excluded or rejected';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.students WHERE id=p_student) THEN
    RAISE EXCEPTION 'Selected student profile does not exist';
  END IF;
  SELECT * INTO v_class FROM public.class_rooms WHERE id=p_class AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Selected active class does not exist'; END IF;
  IF EXISTS(SELECT 1 FROM public.monthly_memberships m
    JOIN public.billing_periods b ON b.id=m.period_id
    JOIN public.enrollments e ON e.id=m.enrollment_id
    WHERE b.year_month=DATE '2026-11-01' AND e.student_id=p_student
      AND e.class_id=p_class AND m.registration_active) THEN
    RAISE EXCEPTION 'An active November financial registration already exists for this student and class';
  END IF;

  INSERT INTO public.enrollments(student_id,class_id,enrolled_on,active)
    VALUES(p_student,p_class,DATE '2026-11-01',true)
    ON CONFLICT(student_id,class_id) DO NOTHING
    RETURNING id INTO v_enrollment;
  IF v_enrollment IS NULL THEN
    SELECT id,active INTO v_enrollment,v_enrollment_active FROM public.enrollments
      WHERE student_id=p_student AND class_id=p_class FOR UPDATE;
    IF NOT coalesce(v_enrollment_active,false) THEN
      RAISE EXCEPTION 'An inactive enrollment already exists; review it before linking this November row';
    END IF;
  END IF;

  UPDATE public.november_import_candidates SET
    student_id=p_student, identity_student_id=p_student, identity_status='matched',
    identity_scope='row', identity_review_reason=trim(p_reason), enrollment_id=v_enrollment,
    class_id=p_class, approved_class_id=p_class, class_title=v_class.title,
    teacher_id=v_class.teacher_id,
    teacher_name=(SELECT full_name FROM public.teachers WHERE id=v_class.teacher_id),
    start_time=v_class.start_time, end_time=v_class.end_time, review_note=trim(p_reason)
  WHERE id=p_candidate;

  INSERT INTO public.historical_import_destinations
    (source_row_id,destination_table,destination_id,mapping_status,created_by)
  VALUES(v_candidate.source_row_id,'students',p_student,'matched_existing',auth.uid())
  ON CONFLICT(source_row_id,destination_table) DO UPDATE SET
    destination_id=excluded.destination_id,mapping_status='matched_existing',created_by=excluded.created_by;
  INSERT INTO public.historical_import_destinations
    (source_row_id,destination_table,destination_id,mapping_status,created_by)
  VALUES(v_candidate.source_row_id,'enrollments',v_enrollment,'matched_existing',auth.uid())
  ON CONFLICT(source_row_id,destination_table) DO UPDATE SET
    destination_id=excluded.destination_id,mapping_status='matched_existing',created_by=excluded.created_by;

  INSERT INTO public.audit_logs(table_name,action,row_id,actor_id,new_data,reason,approved_by)
  VALUES('november_import_candidates','LINK_EXISTING_ROSTER',p_candidate::text,auth.uid(),
    jsonb_build_object('student_id',p_student,'enrollment_id',v_enrollment,'class_id',p_class),
    trim(p_reason),auth.uid());
  RETURN jsonb_build_object('student_id',p_student,'enrollment_id',v_enrollment,'class_id',p_class,
    'monthly_membership_created',false,'payment_created',false);
END;
$link$;

REVOKE ALL ON FUNCTION public.november_link_existing_roster_candidate(uuid,uuid,uuid,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.november_link_existing_roster_candidate(uuid,uuid,uuid,text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;

-- READ ONLY: this reports eligibility; installing the migration DOES NOT post fees.
SELECT
  count(*) AS november_roster_candidates,
  count(*) FILTER(WHERE student_id IS NOT NULL AND enrollment_id IS NOT NULL) AS linked_identity_and_class,
  count(*) FILTER(WHERE review_flag='READY_FOR_ADMIN_TO_VERIFY') AS numeric_source_proposals_needing_approval,
  count(*) FILTER(WHERE review_flag<>'READY_FOR_ADMIN_TO_VERIFY') AS needing_manual_correction_or_identity_review,
  count(*) FILTER(WHERE existing_november_membership_id IS NOT NULL) AS already_monthly_registered,
  (SELECT count(*) FROM public.payments WHERE voided_at IS NULL) AS actual_tuition_payments
FROM public.november_2026_fee_approval_queue;
