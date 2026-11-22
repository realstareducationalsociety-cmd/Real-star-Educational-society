import { PGlite } from '@electric-sql/pglite'
import { readFileSync, readdirSync } from 'node:fs'
import { randomUUID as id } from 'node:crypto'
import assert from 'node:assert/strict'
import { parseHistoricalWorkbook } from '../app/utils/historicalWorkbook.js'

const db = new PGlite()
const admin = id()
const checksum = '15e9b64e02048eba03e59636e2875c56701c0d1160748da7a85e26c8c1e7cc64'
const q = (sql, args = []) => db.query(sql, args)
const scalar = async (sql, args = []) => Object.values((await q(sql, args)).rows[0])[0]

try {
  await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema public,auth to authenticated,anon;grant execute on function auth.uid() to authenticated,anon;`)

  for (const file of readdirSync('supabase/migrations').filter(f => f.endsWith('.sql')).sort()) {
    let migration = readFileSync('supabase/migrations/' + file, 'utf8').replace('create extension if not exists pgcrypto;', '')
    // Simulate a project where 013 is already deployed with the original min(uuid) defect.
    if (file === '013_november_import_review.sql') {
      migration = migration.replace('(array_agg(s.id order by s.id))[1]', 'min(s.id)')
    }
    await db.exec(migration)
  }
  await q('insert into auth.users values($1)', [admin])
  await q("insert into staff_profiles(id,full_name,role) values($1,'Admin','admin')", [admin])
  await db.exec('set role authenticated')
  await q("select set_config('request.jwt.claim.sub',$1,false)", [admin])

  const workbook = parseHistoricalWorkbook(new Uint8Array(readFileSync('Real_Star_June-Nov_2026_Import_Review.xlsx')))
  const novRows = workbook.rows.filter(row => {
    const month = row.payload['Period'] || row.payload['Source Month']
    return (row.source_sheet === 'Registrations' || row.source_sheet === 'RegistrationLeads' || row.source_sheet === 'Payments')
      && (month === '2026-11' || month === 'Nov')
  })
  const registrationCount = novRows.filter(row => ['Registrations', 'RegistrationLeads'].includes(row.source_sheet)).length
  const paymentCount = novRows.filter(row => row.source_sheet === 'Payments').length
  assert.equal(registrationCount, 206)
  assert.equal(paymentCount, 117)

  await db.exec('reset role')
  const batch = id()
  await q(`insert into historical_import_batches(id,source_filename,source_sha256,row_count,status,created_by)
    values($1,'Real_Star_June-Nov_2026_Import_Review.xlsx',$2,$3,'reviewing',$4)`,
  [batch, checksum, novRows.length, admin])
  for (const row of novRows) {
    await q(`insert into historical_import_source_rows(batch_id,source_key,source_sheet,source_row,source_payload)
      values($1,$2,$3,$4,$5)`, [batch, row.source_key, row.source_sheet, row.source_row, JSON.stringify(row.payload)])
  }
  await db.exec('set role authenticated')
  const built = await scalar('select public.build_november_import_candidates($1)', [checksum])
  assert.equal(Number(built.candidates), 206)

  // The locked 012 endpoint is the exact earlier failure mode: migration 013 revokes it.
  await assert.rejects(() => q('select public.import_november_batch($1,$2)', ['[]', id()]), /permission denied for function import_november_batch/)

  const candidate = (await q(`select * from november_import_candidates
    where source_sheet='Registrations' and class_id is not null and source_tuition>0 and source_discount<=source_tuition
      and (source_payment=0 or (source_payment_date is not null and source_payment_reference is not null))
      and blocking_reasons='[]'::jsonb
      and lower(regexp_replace(coalesce(teacher_name,''),'[^a-zA-Z]','','g')) !~ '^tah(e|i)rasakhizada$'
    order by source_payment desc,source_row limit 1`)).rows[0]
  assert.ok(candidate, 'A reviewable November roster candidate should map to an existing class')
  const feeQueueRow = (await q('select * from public.november_2026_fee_approval_queue where candidate_id=$1', [candidate.id])).rows[0]
  assert.equal(Number(feeQueueRow.fee_proposal), Number(candidate.source_tuition), 'Fee proposal reads the workbook Original Tuition column')
  assert.equal(Number(feeQueueRow.source_tuition_text), Number(candidate.source_tuition))
  const studentsBefore = Number(await scalar('select count(*) from students'))
  const membershipsBefore = Number(await scalar("select count(*) from monthly_memberships m join billing_periods p on p.id=m.period_id where p.year_month=date '2026-11-01'"))

  const identityPayload = {
    action: 'create', first_name: candidate.first_name, last_name: candidate.last_name, phone: candidate.phone,
    scope: 'row', identity_confirmed: true, distinct_person_confirmed: true,
    class_id: candidate.class_id, class_confirmed: true, reason: 'Roster identity confirmed'
  }
  const profile = await scalar('select public.november_import_save_profile($1,$2)', [candidate.id, JSON.stringify(identityPayload)])
  assert.equal(profile.profile_created, true)
  assert.equal(Number(await scalar('select count(*) from students')), studentsBefore + 1)
  assert.equal(Number(await scalar('select count(*) from enrollments where student_id=$1', [profile.student_id])), 1)
  assert.equal(Number(await scalar("select count(*) from monthly_memberships m join billing_periods p on p.id=m.period_id where p.year_month=date '2026-11-01'")), membershipsBefore,
    'Profile and verified enrollment must not require or invent a financial agreement')

  // A retry must reuse the first profile and class enrollment.
  const retry = await scalar('select public.november_import_save_profile($1,$2)', [candidate.id, JSON.stringify(identityPayload)])
  assert.equal(retry.student_id, profile.student_id)
  assert.equal(Number(await scalar('select count(*) from students')), studentsBefore + 1)

  if (candidate.source_payment > 0) {
    await db.exec('reset role')
    await assert.rejects(() => q('update november_import_candidates set approved_payment=$1 where id=$2', [candidate.source_payment, candidate.id]),
      /source receipt must be verified/)
    await db.exec('set role authenticated')
  }

  // The generic legacy batch poster is disabled; only the verified roster RPC can post.
  await assert.rejects(() => q('select public.november_import_post(10,null)'), /permission denied for function november_import_post/)
  const fee = Number(candidate.source_tuition)
  const discount = Number(candidate.source_discount)
  const items = [{
    candidate_id: candidate.id, confirmed: true, original_fee: fee, agreed_fee: fee, discount,
    discount_reason: discount > 0 ? 'Administrator approved November discount' : null,
    teacher_entitlement: Math.round(fee * 50) / 100,
    registration_date: '2026-11-01', notes: 'Tested administrator confirmation; no receipt imported'
  }]
  const posting = await scalar('select public.november_finalize_confirmed_roster($1,$2)', [JSON.stringify(items), id()])
  assert.equal(Number(posting.new_monthly_registrations), 1)
  assert.equal(Number(posting.payments_created), 0)
  assert.equal(Number(await scalar('select count(*) from students')), studentsBefore + 1)
  assert.equal(Number(await scalar("select count(*) from monthly_memberships m join billing_periods p on p.id=m.period_id where p.year_month=date '2026-11-01' and m.registration_active")), 1)
  assert.equal(Number(await scalar(`select count(*) from payments p
    join monthly_memberships m on m.id=p.monthly_membership_id
    join enrollments e on e.id=m.enrollment_id
    where e.student_id=$1 and p.voided_at is null`, [profile.student_id])), 0,
    'An unverified historical receipt must not become a payment')

  const linkedCandidate = (await q(`select c.* from november_import_candidates c
    join class_rooms r on r.id=c.class_id
    where c.source_sheet='Registrations' and c.id<>$1 and c.class_id is not null
      and c.class_id<>$2 and c.source_tuition>0 and c.source_discount<=c.source_tuition
      and lower(regexp_replace(coalesce(c.teacher_name,''),'[^a-zA-Z]','','g')) !~ '^tah(e|i)rasakhizada$'
    order by c.source_row limit 1`, [candidate.id, candidate.class_id])).rows[0]
  assert.ok(linkedCandidate, 'Another roster row should be available for existing-profile class-link review')
  const studentsBeforeLink = Number(await scalar('select count(*) from students'))
  const membershipsBeforeLink = Number(await scalar("select count(*) from monthly_memberships m join billing_periods p on p.id=m.period_id where p.year_month=date '2026-11-01' and m.registration_active"))
  await scalar('select public.november_link_existing_roster_candidate($1,$2,$3,$4)',
    [linkedCandidate.id, profile.student_id, linkedCandidate.class_id, 'Verified from November class roster'])
  assert.equal(Number(await scalar('select count(*) from students')), studentsBeforeLink, 'Linking a roster row reuses the selected profile')
  assert.equal(Number(await scalar("select count(*) from monthly_memberships m join billing_periods p on p.id=m.period_id where p.year_month=date '2026-11-01' and m.registration_active")), membershipsBeforeLink,
    'Identity/class review must not create financial registration')

  const unlinkedCandidate = (await q(`select id from november_import_candidates
    where source_sheet='Registrations' and id not in ($1,$2) and identity_student_id is null and enrollment_id is null
    order by source_row limit 1`, [candidate.id, linkedCandidate.id])).rows[0]
  assert.ok(unlinkedCandidate, 'At least one unmatched roster row should remain reviewable')
  const linkedFee = Number(linkedCandidate.source_tuition)
  const linkedDiscount = Number(linkedCandidate.source_discount)
  const linkedItem = {
    candidate_id: linkedCandidate.id, confirmed: true, original_fee: linkedFee, agreed_fee: linkedFee,
    discount: linkedDiscount, discount_reason: linkedDiscount > 0 ? 'Approved November discount' : null,
    teacher_entitlement: Math.round(linkedFee * 50) / 100, registration_date: '2026-11-01'
  }
  const invalidItem = { candidate_id: unlinkedCandidate.id, confirmed: true, original_fee: 500, agreed_fee: 500,
    discount: 0, teacher_entitlement: 250, registration_date: '2026-11-01' }
  await assert.rejects(() => q('select public.november_finalize_confirmed_roster($1,$2)',
    [JSON.stringify([linkedItem, invalidItem]), id()]), /Identity\/class review still required/)
  assert.equal(Number(await scalar("select count(*) from monthly_memberships m join billing_periods p on p.id=m.period_id where p.year_month=date '2026-11-01' and m.registration_active")), membershipsBeforeLink,
    'A failure in a multi-row batch must roll back earlier rows')

  const linkedPost = await scalar('select public.november_finalize_confirmed_roster($1,$2)', [JSON.stringify([linkedItem]), id()])
  assert.equal(Number(linkedPost.new_monthly_registrations), 1)
  assert.equal(Number(await scalar('select count(*) from students')), studentsBeforeLink)

  const retryPosting = await scalar('select public.november_finalize_confirmed_roster($1,$2)', [JSON.stringify(items), id()])
  assert.equal(Number(retryPosting.new_monthly_registrations), 0)
  assert.equal(Number(retryPosting.already_registered_or_posted), 1)

  const summary = await scalar('select public.november_import_profile_summary($1)', [checksum])
  assert.equal(Number(summary.source_registration_candidates), 206)
  assert.equal(Number(summary.profiles_created), 1)
  assert.equal(Number(summary.november_enrollments), 2)
  console.log(JSON.stringify({
    result: 'PASS',
    legacyFailure: 'permission denied for generic November poster',
    candidates: registrationCount,
    profilesCreated: Number(await scalar('select count(*) from november_import_students')),
    operationalStudents: Number(await scalar('select count(*) from students')),
    novemberEnrollments: Number(await scalar("select count(*) from enrollments where student_id=$1", [profile.student_id])),
    memberships: Number(await scalar("select count(*) from monthly_memberships m join billing_periods p on p.id=m.period_id where p.year_month=date '2026-11-01' and m.registration_active")),
    payments: Number(await scalar('select count(*) from payments where voided_at is null')),
    financialApprovalRequired: true
  }, null, 2))
} finally {
  await db.close()
}
