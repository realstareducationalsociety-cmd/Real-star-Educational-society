-- REAL STAR: November 2026 profile-only import (existing staged batch only)
-- Target project: Realstar / ref sdknqymjvqpisjedljou. Confirm the SQL Editor project first.
-- No staging, teacher, class, enrollment, monthly-membership, or payment writes are performed.
-- Safe rule: create only a Registrations-sheet identity that occurs once in the source batch
-- and whose normalized name occurs zero times in operational students. All others stay in review.
-- Run in Supabase SQL Editor as project owner AFTER taking a database backup.

-- Deployment/schema preflight. These values are emitted before the transaction results.
select
  current_database() as database_name,
  current_user as sql_editor_role,
  to_regclass('public.historical_import_batches') is not null as migration_005_staging_present,
  to_regclass('public.historical_import_destinations') is not null as migration_006_destinations_present,
  to_regprocedure('public.build_november_import_candidates(text)') is not null as migration_013_review_function_present,
  to_regprocedure('public.november_import_save_profile(uuid,jsonb)') is not null as migration_014_profile_rpc_present,
  exists(select 1 from information_schema.columns where table_schema='public' and table_name='monthly_memberships' and column_name='agreement_approved_by') as migration_010_agreement_column_present;

begin;

drop table if exists pg_temp.november_profile_import_work;

do $$
declare
  expected_checksum constant text := '15e9b64e02048eba03e59636e2875c56701c0d1160748da7a85e26c8c1e7cc64';
  import_batch_id uuid;
  administrator_id uuid;
  administrator_count integer;
  staged_count integer;
  roster_count integer;
  teacher_count integer;
  class_count integer;
  imported integer := 0;
  reviewed integer := 0;
  r record;
  student_row public.students%rowtype;
  identity_norm text;
begin
  if current_user not in ('postgres','supabase_admin') then
    raise exception 'Run this script in the Supabase SQL Editor as a project owner';
  end if;

  select id into import_batch_id
  from public.historical_import_batches
  where source_sha256=expected_checksum;
  if import_batch_id is null then
    raise exception 'Existing November batch checksum % was not found; no rows were changed',expected_checksum;
  end if;

  select count(*) into staged_count from public.historical_import_source_rows where batch_id=import_batch_id;
  if staged_count<>356 then
    raise exception 'Expected 356 already-staged rows for the verified batch; found %; no rows were changed',staged_count;
  end if;
  select count(*) into roster_count
  from public.historical_import_source_rows s
  where s.batch_id=import_batch_id and s.source_sheet='Registrations'
    and coalesce(s.source_payload->>'Period',s.source_payload->>'Source Month',s.source_payload->>'Month','')
      in ('2026-11','Nov','November','November 2026');
  if roster_count<>140 then
    raise exception 'Expected 140 November rows on the confirmed Registrations roster; found %; no rows were changed',roster_count;
  end if;

  select count(*) into teacher_count from public.teachers;
  select count(*) into class_count from public.class_rooms;
  if teacher_count<10 or class_count<23 then
    raise exception 'Operational reference data check failed (teachers %, classes %); no rows were changed',teacher_count,class_count;
  end if;
  if to_regclass('public.historical_import_destinations') is null
     or to_regclass('public.historical_import_entities') is null then
    raise exception 'Historical provenance tables from migration 006 are missing; no rows were changed';
  end if;

  select count(*) into administrator_count
  from public.staff_profiles where role::text='admin' and is_active;
  if administrator_count<>1 then
    raise exception 'Expected exactly one active administrator for an unambiguous audit actor; found %. No rows were changed.',administrator_count;
  end if;
  select id into administrator_id
  from public.staff_profiles where role::text='admin' and is_active;

  create temporary table november_profile_import_work on commit drop as
  with parsed as (
    select s.id as source_row_id,s.batch_id,s.source_key,s.source_sheet,s.source_row,s.source_payload,
      coalesce(
        nullif(trim(s.source_payload->>'Full Name'),''),
        nullif(trim(s.source_payload->>'Student Name'),''),
        nullif(trim(s.source_payload->>'Name'),''),
        nullif(trim(concat_ws(' ',
          nullif(trim(s.source_payload->>'First Name'),''),
          nullif(trim(s.source_payload->>'Last Name'),''))),''),
        nullif(trim(s.source_payload->>'Student'),'')
      ) as student_name,
      nullif(trim(coalesce(s.source_payload->>'First Name','')),'') as source_first_name,
      nullif(trim(coalesce(s.source_payload->>'Last Name','')),'') as source_last_name,
      nullif(trim(coalesce(s.source_payload->>'Contact',s.source_payload->>'Phone',
        s.source_payload->>'Mobile',s.source_payload->>'Guardian Phone',s.source_payload->>'Contact Phone','')),'') as phone
    from public.historical_import_source_rows s
    where s.batch_id=import_batch_id and s.source_sheet='Registrations'
      and coalesce(s.source_payload->>'Period',s.source_payload->>'Source Month',s.source_payload->>'Month','')
        in ('2026-11','Nov','November','November 2026')
  ), normalized as (
    select p.*,
      nullif(btrim(regexp_replace(lower(coalesce(p.student_name,'')),'[^[:alnum:]]+',' ','g')),'') as identity_name,
      coalesce(p.source_first_name,split_part(regexp_replace(trim(coalesce(p.student_name,'')),'\s+',' ','g'),' ',1),'') as first_name,
      coalesce(p.source_last_name,nullif(btrim(regexp_replace(
        regexp_replace(trim(coalesce(p.student_name,'')),'\s+',' ','g'),'^\S+\s*','')),''),'') as last_name
    from parsed p
  ), counted as (
    select n.*,
      count(*) over(partition by n.identity_name) as source_name_count,
      (select count(*) from public.students s
        where btrim(regexp_replace(lower(concat_ws(' ',s.first_name,s.last_name)),'[^[:alnum:]]+',' ','g'))=n.identity_name
      ) as existing_name_count
    from normalized n
  )
  select * from counted;

  for r in
    select * from november_profile_import_work
    where identity_name is not null and first_name<>''
      and source_name_count=1 and existing_name_count=0
      and not exists(select 1 from public.historical_import_destinations d
        where d.source_row_id=november_profile_import_work.source_row_id)
      and exists(select 1 from public.historical_import_source_rows s
        where s.id=november_profile_import_work.source_row_id
          and s.review_status in ('pending','needs_review') and s.destination_id is null)
    order by source_row
  loop
    perform 1 from public.historical_import_source_rows s
    where s.id=r.source_row_id and s.review_status in ('pending','needs_review')
      and s.destination_id is null for update;
    if not found then continue; end if;

    identity_norm := r.identity_name;
    perform pg_advisory_xact_lock(hashtextextended('november-profile-only:'||import_batch_id::text||':'||identity_norm,0));

    -- Recheck while holding the identity lock so a rerun or concurrent import cannot duplicate it.
    if exists(select 1 from public.students s
      where btrim(regexp_replace(lower(concat_ws(' ',s.first_name,s.last_name)),'[^[:alnum:]]+',' ','g'))=identity_norm) then
      update public.historical_import_source_rows
      set review_status='needs_review',reviewed_by=administrator_id,reviewed_at=now(),
        review_reason='Identity review required: an operational profile with this normalized name now exists.'
      where id=r.source_row_id and review_status in ('pending','needs_review') and destination_id is null;
      reviewed := reviewed + 1;
      continue;
    end if;

    if exists(select 1 from public.historical_import_entities e
      where e.batch_id=import_batch_id and e.entity_type='student'
        and e.entity_key=left(r.source_key,300) and e.destination_table='students') then
      raise exception 'A student provenance key already exists for source row %; transaction rolled back',r.source_key;
    end if;

    perform set_config('rsms.audit_reason','November roster profile-only import; financial agreement remains pending review',true);
    insert into public.students(first_name,last_name,phone,registered_on,active,notes)
    values(trim(r.first_name),coalesce(trim(r.last_name),''),r.phone,date '2026-11-01',true,
      'November 2026 roster source '||r.source_key||'; profile-only import; financial agreement pending review.')
    returning * into student_row;

    insert into public.historical_import_entities(batch_id,entity_type,entity_key,destination_id,destination_table,created_by)
    values(import_batch_id,'student',left(r.source_key,300),student_row.id,'students',administrator_id);
    insert into public.historical_import_destinations(source_row_id,destination_table,destination_id,mapping_status,created_by)
    values(r.source_row_id,'students',student_row.id,'created',administrator_id);
    update public.historical_import_source_rows
    set review_status='accepted',destination_table='students',destination_id=student_row.id,
      reviewed_by=administrator_id,reviewed_at=now(),
      review_reason='Unique November Registrations roster identity; no same-name operational profile; profile only.'
    where id=r.source_row_id and review_status in ('pending','needs_review') and destination_id is null;

    insert into public.audit_logs(table_name,action,row_id,actor_id,new_data,reason,approved_by)
    values('students','NOVEMBER_PROFILE_IMPORT',student_row.id::text,administrator_id,to_jsonb(student_row),
      'Unique November roster identity confirmed; financial agreement not approved or created.',administrator_id);
    imported := imported + 1;
  end loop;

  -- Keep names already present, repeated source identities and incomplete names in review.
  update public.historical_import_source_rows s
  set review_status='needs_review',reviewed_by=administrator_id,reviewed_at=now(),
    review_reason=case
      when w.identity_name is null then 'Identity review required: student name is missing or unreadable.'
      when w.source_name_count>1 then 'Identity review required: this normalized name occurs on multiple roster rows; do not merge by name alone.'
      when w.existing_name_count>0 then 'Identity review required: one or more operational profiles share this normalized name; select or create the correct identity.'
      else 'Identity review required: student first name is missing.' end
  from november_profile_import_work w
  where s.id=w.source_row_id
    and (w.identity_name is null or w.source_name_count>1 or w.existing_name_count>0 or w.first_name='')
    and s.review_status in ('pending','needs_review') and s.destination_id is null;
  get diagnostics reviewed = row_count;

  -- Registration leads are not treated as attending students without explicit roster review.
  update public.historical_import_source_rows s
  set review_status='needs_review',reviewed_by=administrator_id,reviewed_at=now(),
    review_reason='Attendance review required: this row is on RegistrationLeads, not the confirmed Registrations roster.'
  where s.batch_id=import_batch_id and s.source_sheet='RegistrationLeads'
    and coalesce(s.source_payload->>'Period',s.source_payload->>'Source Month',s.source_payload->>'Month','')
      in ('2026-11','Nov','November','November 2026')
    and s.review_status in ('pending','needs_review') and s.destination_id is null;

  raise notice 'Profile-only import complete: % profiles created. Ambiguous roster rows remain in review.',imported;
end $$;

commit;

-- Required post-run verification. No November memberships or payments are created by this script.
select count(*) as operational_students from public.students;
select count(*) as november_monthly_memberships
from public.monthly_memberships m
join public.billing_periods b on b.id=m.period_id
where b.year_month=date '2026-11-01';
select
  count(*) filter(where r.source_sheet='Registrations' and r.destination_table='students') as roster_profiles_created,
  count(*) filter(where r.review_status='needs_review') as source_rows_awaiting_review
from public.historical_import_source_rows r
join public.historical_import_batches b on b.id=r.batch_id
where b.source_sha256='15e9b64e02048eba03e59636e2875c56701c0d1160748da7a85e26c8c1e7cc64'
  and r.source_sheet in ('Registrations','RegistrationLeads');
