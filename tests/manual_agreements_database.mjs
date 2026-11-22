import { PGlite } from '@electric-sql/pglite'
import { readFileSync, readdirSync } from 'node:fs'
import { randomUUID as id } from 'node:crypto'
import assert from 'node:assert/strict'

const db = new PGlite()
const admin = id()
const registrar = id()
const accountant = id()
const teacher = id()

const q = (sql, args = []) => db.query(sql, args)
const scalar = async (sql, args = []) => Object.values((await q(sql, args)).rows[0])[0]
const user = async (uid) => {
  await db.exec('set role authenticated')
  await q("select set_config('request.jwt.claim.sub',$1,false)", [uid])
}

try {
  // Setup Auth schema & users
  await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema public,auth to authenticated,anon;grant execute on function auth.uid() to authenticated,anon;`)

  // Apply migrations 001 to 009
  for (const file of readdirSync('supabase/migrations').filter(f => /^00[1-9]_/.test(f)).sort()) {
    await db.exec(readFileSync('supabase/migrations/' + file, 'utf8').replace('create extension if not exists pgcrypto;', ''))
  }

  await q('insert into auth.users values($1),($2),($3)', [admin, registrar, accountant])
  await q("insert into staff_profiles(id,full_name,role) values($1,'Admin','admin'),($2,'Registrar','registrar'),($3,'Accountant','accountant')", [admin, registrar, accountant])
  await q("insert into teachers(id,full_name) values($1,'Teacher')", [teacher])

  await user(admin)
  const c1 = await scalar("insert into class_rooms(title,teacher_id,default_fee,start_time,end_time) values('Family & Friends 4 Group A',$1,2000,'09:00','10:00') returning id", [teacher])
  const c2 = await scalar("insert into class_rooms(title,teacher_id,default_fee,start_time,end_time) values('Family & Friends 4 Group B',$1,900,'11:00','12:00') returning id", [teacher])

  // Legacy registration before migration 010
  const old = await scalar('select register_dashboard_student($1,$2)', [{
    month: '2034-01-01', date: '2034-01-10', student_id: null, first_name: 'Legacy',
    classes: [{ class_id: c1, discount: 0, payment: 0 }]
  }, id()])
  const snapshot = await scalar("select jsonb_agg(to_jsonb(m)) from monthly_memberships m")

  // Apply migration 010
  await db.exec('reset role')
  await db.exec(readFileSync('supabase/migrations/010_manual_financial_agreements.sql', 'utf8'))
  await user(admin)

  // Verify legacy preservation
  const after = await scalar("select jsonb_agg(to_jsonb(m)-'agreement_approved_by'-'agreement_approved_at'-'discount_reason') from monthly_memberships m")
  assert.deepEqual(after, snapshot, 'Migration 010 must preserve all existing financial values')

  // Helper functions
  const agreement = (class_id, more = {}) => ({
    class_id, original_fee: 2000, agreed_fee: 2000, discount: 0, discount_reason: '',
    teacher_entitlement: 1000, payment: 0, arrangement_notes: 'Approved individually', ...more
  })
  const payload = (classes, more = {}) => ({
    month: '2035-01-01', date: '2035-01-25', approved: true, student_id: null,
    first_name: 'Test', last_name: 'Person', notes: 'Profile note', classes, ...more
  })
  const save = (p, request = id()) => scalar('select register_dashboard_student($1,$2)', [p, request])
  const accounts = student => q('select * from month_fee_overview where student_id=$1 order by class_id', [student])

  console.log('Testing 14 required cases from user prompt...')

  // Case 1: A new student with regular tuition (no discount, standard 50% teacher entitlement)
  const regularNew = await save(payload([agreement(c1, {
    original_fee: 2000, agreed_fee: 2000, discount: 0, teacher_entitlement: 1000, payment: 0
  })]))
  let regularNewRow = (await accounts(regularNew.student_id)).rows[0]
  assert.equal(Number(regularNewRow.original_fee), 2000)
  assert.equal(Number(regularNewRow.agreed_fee), 2000)
  assert.equal(Number(regularNewRow.amount_due), 2000)
  assert.equal(Number(regularNewRow.balance_due), 2000)
  assert.equal(Number(regularNewRow.paid_total), 0)
  assert.equal(Number(regularNewRow.teacher_entitlement), 1000)
  assert.equal(Number(regularNewRow.center_entitlement), 1000)
  assert.equal(Number(regularNewRow.institution_funded), 0)
  assert.equal(regularNewRow.scholarship, false)
  assert.equal(regularNewRow.calculation_mode, 'automatic', 'Standard 50% must be stored in automatic mode')
  assert.equal(regularNewRow.is_exception, false, 'Standard 50% must not be marked as exception')
  assert.equal(Number(regularNewRow.standard_teacher_share), 1000)

  // Case 1b: Rejection of manual exception without mandatory exception reason
  await assert.rejects(
    () => save(payload([agreement(c1, {
      agreed_fee: 2000, teacher_entitlement: 1200, arrangement_notes: '', exception_reason: ''
    })])),
    /Teacher entitlement exception requires a mandatory reason/,
    'Database must reject manual teacher entitlement exception without a valid reason'
  )

  // Case 2: A returning student with previous financial history & manual exception
  // Register initial student in January 2035 with approved manual exception (875 instead of standard 900)
  const regularPayload = payload([agreement(c1, {
    agreed_fee: 1800, discount: 300, discount_reason: 'Approved reduction',
    teacher_entitlement: 875, exception_reason: 'Special rate approved for senior faculty',
    payment: 400, paid_on: '2035-01-26', payment_method: 'bank'
  })])
  const request = id()
  const regular = await save(regularPayload, request)
  let row = (await accounts(regular.student_id)).rows[0]
  assert.equal(Number(row.base_fee), 1800, 'Late date must not halve the approved fee')
  assert.equal(Number(row.amount_due), 1500)
  assert.equal(Number(row.teacher_entitlement), 875)
  assert.equal(Number(row.paid_total), 400)
  assert.equal(Number(row.balance_due), 1100)
  assert.equal(row.agreement_approved_by, admin)
  assert.equal(row.proration_rule, 'manual_agreement')
  assert.equal(row.calculation_mode, 'manual', 'Override must be stored in manual mode')
  assert.equal(row.is_exception, true, 'Override must be flagged as exception')
  assert.equal(Number(row.standard_teacher_share), 900)
  assert.equal(row.manual_adjustment_reason, 'Special rate approved for senior faculty')

  // Check history retrieval: shows previous arrangement with exception status
  const prev = await scalar("select registration_previous($1,'2035-03-01')", [regular.student_id])
  assert.equal(prev.length, 1)
  assert.equal(prev[0].class_name, 'Family & Friends 4 Group A')
  assert.equal(Number(prev[0].paid_total), 400)
  assert.equal(Number(prev[0].balance_due), 1100)
  assert.equal(prev[0].discount_reason, 'Approved reduction')
  assert.equal(prev[0].is_exception, true, 'History must reveal whether arrangement was exception')
  assert.equal(Number(prev[0].standard_teacher_share), 900)
  assert.equal(Number(prev[0].teacher_entitlement), 875)
  assert.equal(prev[0].exception_reason, 'Special rate approved for senior faculty')

  // Case 3: A student with partial discount and standard 50% teacher entitlement
  // Base tuition: 2000, Discount: 600, Payable: 1400.
  // Standard teacher entitlement is 50% of 2000 = 1000.
  // Ordinary discount reduces institution share (1400 - 1000 = 400), not teacher entitlement!
  const partialDiscountStudent = await save(payload([agreement(c1, {
    original_fee: 2000, agreed_fee: 2000, discount: 600, discount_reason: 'Sibling discount approved',
    teacher_entitlement: 1000, payment: 0
  })]))
  const partialRow = (await accounts(partialDiscountStudent.student_id)).rows[0]
  assert.equal(Number(partialRow.base_fee), 2000)
  assert.equal(Number(partialRow.discount), 600)
  assert.equal(Number(partialRow.amount_due), 1400)
  assert.equal(Number(partialRow.teacher_entitlement), 1000, 'Teacher entitlement remains 50% of base fee before discount')
  assert.equal(Number(partialRow.center_entitlement), 400, 'Discount reduced institution share, not teacher entitlement')
  assert.equal(Number(partialRow.institution_funded), 0)
  assert.equal(partialRow.calculation_mode, 'automatic')
  assert.equal(partialRow.is_exception, false)

  // Case 4: A student with a 100% discount (full scholarship)
  // Original tuition: PKR 2,000, Discount: PKR 2,000, Student payable: PKR 0, Teacher entitlement: PKR 1,000
  const full = await save(payload([agreement(c1, {
    original_fee: 2000, agreed_fee: 2000, discount: 2000, discount_reason: 'Full scholarship', teacher_entitlement: 1000
  })]))
  const fullRow = (await accounts(full.student_id)).rows[0]
  assert.equal(Number(fullRow.amount_due), 0)
  assert.equal(Number(fullRow.balance_due), 0)
  assert.equal(Number(fullRow.paid_total), 0)
  assert.equal(Number(fullRow.institution_funded), 1000)
  assert.equal(Number(fullRow.teacher_entitlement), 1000)
  assert.equal(Number(fullRow.center_entitlement), -1000)
  assert.equal(fullRow.scholarship, true)
  assert.equal(fullRow.calculation_mode, 'automatic', 'Full scholarship with standard 50% must remain automatic')
  assert.equal(fullRow.is_exception, false)
  assert.equal(Number(fullRow.standard_teacher_share), 1000)
  assert.equal(Number(await scalar('select count(*) from payments where monthly_membership_id=$1', [fullRow.id])), 0, 'No artificial payment created')

  // Case 5: A student whose teacher entitlement is funded by the institution (partial tuition < teacher entitlement)
  // Student payable: PKR 500, Teacher entitlement: PKR 1,200 => Institution funded: PKR 700
  const multiple = await save(payload([
    agreement(c1, { agreed_fee: 500, discount: 0, teacher_entitlement: 1200, exception_reason: 'Institution-backed rate' }),
    agreement(c2, { original_fee: 800, agreed_fee: 700, discount: 100, discount_reason: 'Agreed reduction', teacher_entitlement: 400, exception_reason: 'Non-standard group rate' })
  ]))
  assert.equal((await accounts(multiple.student_id)).rows.length, 2)
  const c1Row = (await accounts(multiple.student_id)).rows.find(r => r.class_id === c1)
  assert.equal(Number(c1Row.amount_due), 500)
  assert.equal(Number(c1Row.teacher_entitlement), 1200)
  assert.equal(Number(c1Row.institution_funded), 700)

  // Case 6: A student registering after the 20th with a manually selected fee
  // Notice registered on '2035-01-25'. Verified that base_fee is 1800, not halved!
  assert.equal(Number(row.base_fee), 1800)
  // Verify changing class reference fee later does NOT modify previously approved agreements
  await q('update class_rooms set default_fee=9999 where id=$1', [c1])
  assert.equal(Number((await accounts(regular.student_id)).rows[0].base_fee), 1800, 'Class default fee change must not alter approved agreement')

  // Case 7: One student attending two classes with different tuition agreements
  // Handled in `multiple`: c1 has agreed 500 / teacher 1200; c2 has agreed 700 / discount 100 / teacher 400
  const c2Row = (await accounts(multiple.student_id)).rows.find(r => r.class_id === c2)
  assert.equal(Number(c2Row.original_fee), 800)
  assert.equal(Number(c2Row.base_fee), 700)
  assert.equal(Number(c2Row.discount), 100)
  assert.equal(Number(c2Row.amount_due), 600)
  assert.equal(Number(c2Row.teacher_entitlement), 400)
  assert.equal(Number(c2Row.center_entitlement), 200)
  assert.equal(Number(c2Row.institution_funded), 0)

  // Case 8: Partial tuition payment
  // Handled in regular: amount_due=1500, initial payment=400, balance_due=1100
  assert.equal(Number(row.paid_total), 400)
  assert.equal(Number(row.balance_due), 1100)

  // Case 10: Changing tuition after a payment exists
  // Student paid 400. Modify agreement from 1500 to 1400 (agreed 1600, discount 200).
  const change = {
    original_fee: 2000, agreed_fee: 1600, discount: 200, teacher_entitlement: 900,
    discount_reason: 'Approved discount', arrangement_notes: 'Changed explicitly',
    reason: 'Revised agreement', approved: true
  }
  await q('select update_monthly_agreement($1,$2,$3)', [row.id, change, row.updated_at])
  row = (await accounts(regular.student_id)).rows.find(r => r.id === row.id)
  assert.equal(Number(row.amount_due), 1400)
  assert.equal(Number(row.paid_total), 400)
  assert.equal(Number(row.balance_due), 1000)

  // Attempt to reduce tuition payable below actual received payments (400) -> must fail!
  await assert.rejects(
    () => q('select update_monthly_agreement($1,$2,$3)', [row.id, { ...change, agreed_fee: 300, discount: 0 }, row.updated_at]),
    /مبلغ جدید کمتر از پرداخت‌های ثبت‌شده است/
  )
  // Verify adjustment audit record
  assert.equal(Number(await scalar("select count(*) from membership_financial_adjustments where monthly_membership_id=$1 and approved_by=$2", [row.id, admin])), 1)
  assert.equal(Number(await scalar("select count(*) from audit_logs where table_name='monthly_memberships' and row_id=$1", [row.id])) > 0, true)

  // Case 9: Partial teacher settlement
  const sumBefore = (await q('select * from teacher_settlement_summary where period_id=$1 and class_id=$2', [row.period_id, c1])).rows[0]
  const settleReq = id()
  const settlement = await scalar("select record_teacher_settlement($1,$2,$3,350,'2035-01-28','cash','Actual partial settlement',$4)", [row.period_id, c1, teacher, settleReq])
  assert.equal(await scalar("select record_teacher_settlement($1,$2,$3,350,'2035-01-28','cash','Actual partial settlement',$4)", [row.period_id, c1, teacher, settleReq]), settlement, 'Settlement retry must be idempotent')
  const summary = (await q('select * from teacher_settlement_summary where period_id=$1 and class_id=$2', [row.period_id, c1])).rows[0]
  assert.equal(Number(summary.teacher_entitlement), Number(sumBefore.teacher_entitlement))
  assert.equal(Number(summary.settled_total), 350)
  assert.equal(summary.settlement_status, 'partial')
  const history = await scalar('select teacher_settlement_history($1,$2,$3)', [row.period_id, c1, teacher])
  assert.equal(history[0].recorded_by, 'Admin')
  assert.equal(history[0].method, 'cash')
  assert.equal(Number(history[0].amount), 350)

  // Attempt to change entitlement after teacher settlement exists -> must fail!
  await assert.rejects(
    () => q('select update_monthly_agreement($1,$2,$3)', [row.id, { ...change, teacher_entitlement: 901 }, row.updated_at]),
    /پس از تصفیه استاد، ابتدا اسناد مالی را بررسی کنید/
  )

  // Case 11: Administrator rejecting a previous-month recommendation
  // Student had previous arrangement (agreed 1800, teacher 875).
  // Admin rejects that recommendation and enters a completely new arrangement (agreed 900, teacher 300).
  const returned = await save(payload([agreement(c1, { agreed_fee: 900, teacher_entitlement: 300 })], {
    student_id: regular.student_id, month: '2035-03-01', date: '2035-03-29'
  }))
  assert.equal(returned.student_id, regular.student_id)
  const next = (await accounts(regular.student_id)).rows.find(r => r.period_id !== row.period_id)
  assert.equal(Number(next.paid_total), 0, 'Previous payments must NEVER be copied into the new month')
  assert.equal(Number(next.base_fee), 900)
  assert.equal(Number(next.teacher_entitlement), 300)
  // Historical outstanding balance remains attached to original month!
  assert.equal(Number((await accounts(regular.student_id)).rows.find(r => r.id === row.id).balance_due), 1000)

  // Case 12: Unauthorized financial modification
  for (const actor of [registrar, accountant]) {
    await user(actor)
    await assert.rejects(() => save(payload([agreement(c1)])), /Administrator approval required/)
    await assert.rejects(() => q('select update_monthly_agreement($1,$2,$3)', [row.id, change, row.updated_at]), /Administrator approval required/)
    await assert.rejects(() => scalar("select record_teacher_settlement($1,$2,$3,1,'2035-01-28','cash','Not approved',$4)", [row.period_id, c1, teacher, id()]), /Financial access required/)
  }
  await user(admin)

  // Case 13: Repeated registration submission without duplicate records (Idempotency)
  assert.deepEqual(await save(regularPayload, request), regular)
  await assert.rejects(() => save({ ...regularPayload, first_name: 'Different' }, request), /Request ID reused with different data/)

  // Case 14: Empty database and empty monthly reports
  assert.equal(Number((await scalar("select monthly_registration_summary('2040-01-01')")).registrations), 0)
  assert.equal((await q("select * from teacher_settlement_summary where period_id in(select id from billing_periods where year_month='2040-01-01')")).rows.length, 0)
  const emptyOffice = await scalar("select office_month_summary('2040-01-01')")
  assert.equal(emptyOffice.teacher_entitlement, 0)
  assert.equal(emptyOffice.institution_funded, 0)

  // Case 15: Cancellation of active registration with and without payments
  // Membership with payment cannot be cancelled without voiding payment
  await assert.rejects(
    () => q("select cancel_monthly_registration($1,'Cancellation reason')", [row.id]),
    /ثبت‌نامی که پرداخت دارد قابل لغو نیست/
  )
  // Register a student in month 2035-02-01 (no teacher settlements in this month)
  const cancelTestStudent = await save(payload([agreement(c1, {
    agreed_fee: 1500, discount: 0, teacher_entitlement: 750, payment: 0
  })], { month: '2035-02-01', date: '2035-02-05' }))
  const cancelTestRow = (await accounts(cancelTestStudent.student_id)).rows[0]
  // Membership without payment in an unsettled class/month can be cancelled with audit reason
  await q("select cancel_monthly_registration($1,'Valid student departure reason')", [cancelTestRow.id])
  const cancelledRow = (await q("select * from monthly_memberships where id=$1", [cancelTestRow.id])).rows[0]
  assert.equal(cancelledRow.registration_active, false)
  assert.match(cancelledRow.notes, /Valid student departure reason/)

  // Staging preservation check
  assert.equal(await scalar("select has_function_privilege('authenticated','public.post_historical_import_batch(uuid,boolean)','execute')"), false)
  for (const table of ['historical_import_batches', 'historical_import_source_rows', 'historical_import_destinations', 'historical_import_entities']) {
    assert.equal(Number(await scalar('select count(*) from ' + table)), 0)
  }

  // Dashboard and settlement view confirmation
  const office = await scalar("select office_month_summary('2035-01-01')")
  assert.equal(office.tuition_collected, 400)
  assert.equal(office.expenses, 0)
  assert.equal(office.teacher_paid, 350)
  assert.equal(office.institution_funded, 1700)

await db.exec('reset role')
await db.exec(readFileSync('supabase/migrations/011_registration_confirmation.sql','utf8'))
await user(admin)
const beforeStats=(await scalar("select monthly_registration_summary('2036-01-01')")).registrations
const pending=await save(payload([agreement(c1)],{month:'2036-01-01',date:'2036-01-25',first_name:'Pending'}))
let pendingRow=(await accounts(pending.student_id)).rows[0]
assert.equal(pendingRow.confirmation_status,'pending_payment')
assert.equal((await scalar("select monthly_registration_summary('2036-01-01')")).registrations,beforeStats)
const paymentRequest=id(),receipt=await scalar("select record_tuition_payment($1,500,'2036-01-26','cash','Actual payment',$2)",[pendingRow.id,paymentRequest])
assert.deepEqual(await scalar("select record_tuition_payment($1,500,'2036-01-26','cash','Actual payment',$2)",[pendingRow.id,paymentRequest]),receipt)
pendingRow=(await accounts(pending.student_id)).rows[0];assert.equal(pendingRow.confirmation_status,'registered');assert.equal(Number(pendingRow.balance_due),1500)
assert.equal((await scalar("select monthly_registration_summary('2036-01-01')")).registrations,1)
await q("select void_payment($1,'Audited payment reversal')",[receipt.id])
assert.equal((await accounts(pending.student_id)).rows[0].confirmation_status,'pending_payment')
assert.equal((await scalar("select monthly_registration_summary('2036-01-01')")).registrations,0)
const sponsor=await save(payload([agreement(c1,{discount:2000,discount_reason:'Full scholarship',sponsored_confirmed:true})],{month:'2036-01-01',date:'2036-01-26',first_name:'Sponsored'}))
const sponsored=(await accounts(sponsor.student_id)).rows[0];assert.equal(sponsored.confirmation_status,'fully_sponsored');assert.equal(Number(sponsored.paid_total),0);assert.equal(Number(sponsored.institution_funded),1000)
assert.equal((await scalar("select monthly_registration_summary('2036-01-01')")).registrations,1)
await assert.rejects(()=>save(payload([agreement(c1,{teacher_entitlement:1300})],{first_name:'InvalidRecommendation'})))
await assert.rejects(()=>save(payload([agreement(c1,{teacher_entitlement:1300,custom_teacher_share:true})],{first_name:'MissingReason'})))
const custom=await save(payload([agreement(c1,{teacher_entitlement:1300,custom_teacher_share:true,teacher_share_reason:'Administrator arrangement'})],{first_name:'Custom'}))
assert.equal(Number((await accounts(custom.student_id)).rows[0].teacher_entitlement),1300)
await assert.rejects(()=>save(payload([agreement(c2)],{first_name:'Custom'})))
assert.equal((await accounts(custom.student_id)).rows[0].start_time_snapshot,'09:00:00')
assert.equal((await scalar("select monthly_registration_list('2036-01-01',$1)",[pending.student_id]))[0].confirmation_status,'pending_payment')
console.log('PASS: migration 011 real-payment confirmation, pending-count exclusion, scholarship enrollment without fake receipts, payment replay/void states, 50% recommendation and custom-reason guards, duplicate-profile guard, schedule snapshots.')


  console.log('ALL 14 REQUIRED TEST CASES PASSED SUCCESSFULLY!')
} finally {
  await db.close()
}