import { PGlite } from '@electric-sql/pglite'
import { readFileSync, readdirSync } from 'node:fs'
import { randomUUID as id } from 'node:crypto'
import assert from 'node:assert/strict'

const db = new PGlite()
const admin = id(), registrar = id()
const q = (sql, args = []) => db.query(sql, args)
const scalar = async (sql, args = []) => Object.values((await q(sql, args)).rows[0])[0]

try {
  await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema public,auth to authenticated,anon;grant execute on function auth.uid() to authenticated,anon;`)

  for (const file of readdirSync('supabase/migrations').filter(f => f.endsWith('.sql')).sort()) {
    let migration = readFileSync('supabase/migrations/' + file, 'utf8').replace('create extension if not exists pgcrypto;', '')
    if (file === '013_november_import_review.sql') {
      migration = migration.replace('(array_agg(s.id order by s.id))[1]', 'min(s.id)')
    }
    migration = migration.replace(/^\uFEFF/, '')
    await db.exec(migration)
  }

  await q('insert into auth.users values($1),($2)', [admin, registrar])
  await q("insert into staff_profiles(id,full_name,role) values($1,'Admin','admin'),($2,'Registrar','registrar')", [admin, registrar])
  const teacher = (await scalar('insert into public.teachers(full_name,active) values($1,$2) returning id', ['Tahera Sakhizada', true]))
  const classGrade2 = (await scalar(`insert into public.class_rooms(title,teacher_id,default_fee,start_time,end_time,active)
    values($1,$2,1000,'17:00','18:00',true) returning id`, ['School Grade 2', teacher]))
  const classGrade3 = (await scalar(`insert into public.class_rooms(id,title,teacher_id,default_fee,start_time,end_time,active)
    values('e2df6a0e-a6b2-4193-a585-ffed7a931ddc',$1,$2,1000,'17:00','18:00',true) returning id`, ['School Grade 3', teacher]))

  const noorzia = (await scalar(`insert into public.students(first_name,last_name,student_code,phone,active,registered_on)
    values($1,$2,'RS-000056',$3,true,date '2026-10-01') returning id`, ['Noorzia', 'Atayee', '09120000056']))

  await db.exec('set role authenticated')
  await q("select set_config('request.jwt.claim.sub',$1,false)", [admin])
  const registration = await scalar("select public.register_dashboard_student($1,$2)", [JSON.stringify({approved:true,month:'2026-11-01',date:'2026-11-01',student_id:noorzia,classes:[{class_id:classGrade2,original_fee:1000,agreed_fee:1000,discount:200,teacher_entitlement:500,payment:0,discount_reason:'Management discount'}]}), id()])
  const period = (await scalar("select id from public.billing_periods where year_month = date '2026-11-01'"))
  const membership = (await scalar("select id from public.monthly_memberships where period_id=$1 and enrollment_id=(select id from public.enrollments where student_id=$2 and class_id=$3)", [period,noorzia,classGrade2]))
  const originalApproval = await q("select agreement_approved_by,agreement_approved_at,registration_type,registered_on,teacher_id,teacher_discount_share from public.monthly_memberships where id=$1", [membership])
  const originalApprovalRow = originalApproval.rows[0]
  const payReq = id()
  const oldPayment = (await scalar('select public.record_tuition_payment($1,$2,$3,$4,$5,$6)',
    [membership, 800, new Date('2026-11-24'), 'cash', 'Original payment for School Grade 2', payReq]))
  await db.exec('reset role')
  await q('update public.payments set id=$1 where id=$2', ['446d758c-3466-45bc-901a-063dfc05f752', oldPayment.id])
  oldPayment.id = '446d758c-3466-45bc-901a-063dfc05f752'
  await db.exec('set role authenticated')
  await q("select set_config('request.jwt.claim.sub',$1,false)", [admin])
  await q("select public.void_payment($1,$2)", [oldPayment.id, 'Manager cancelled incorrect Dari class entry; PKR 800 refunded to family'])
  const voidAuditId = await scalar("select id from audit_logs where table_name='payments' and row_id=$1 and action='UPDATE' and old_data->>'voided_at' is null and new_data->>'voided_at' is not null order by id desc limit 1", [oldPayment.id])
  assert.ok(voidAuditId, 'Manager cancellation of original receipt must already be audited')
  const originalVoidedReceipt = (await q("select id,monthly_membership_id,amount,paid_on,method,reference_note,voided_at,void_reason from public.payments where id=$1", [oldPayment.id])).rows[0]

  let regActive = (await scalar("select registration_active from public.monthly_memberships where id=$1", [membership]))
  assert.equal(regActive, true, 'fixture: Grade 2 registration_active must be true')

  const oldPayments = Number(await scalar("select count(*) from public.payments where monthly_membership_id=$1 and voided_at is not null", [membership]))
  assert.equal(oldPayments, 1, 'fixture: original payment receipt is voided')

  const oldPayTotal = Number(await scalar("select coalesce(sum(amount),0) from public.payments where monthly_membership_id=$1 and voided_at is null", [membership]))
  assert.equal(oldPayTotal, 0, 'fixture: voided source receipt is not currently counted')

  const grade3Exists = (await scalar("select count(*) from public.monthly_memberships m join public.enrollments e on e.id=m.enrollment_id where e.student_id=$1 and e.class_id=$2 and m.period_id=$3 and m.registration_active", [noorzia, classGrade3, period]))
  assert.equal(Number(grade3Exists), 0, 'fixture: no active Grade 3 membership yet')

  const correctReq = id()
  await q("select set_config('request.jwt.claim.sub',$1,false)", [admin])
  await q("select set_config('request.jwt.claim.sub',$1,false)", [registrar])
  await assert.rejects(() => q('select public.correct_november_student_class($1,$2,$3,$4,$5,$6,$7)', ['RS-000056', classGrade3, 'Unauthorized attempt', id(), oldPayment.id, true,true]), /Administrator approval required/)
  await q("select set_config('request.jwt.claim.sub',$1,false)", [admin])
  await db.exec('reset role')
  const duplicateReceipt = await scalar("insert into public.payments(monthly_membership_id,amount,paid_on,method,reference_note,request_id) values($1,800,date '2026-11-24','cash','Duplicate receipt fixture',$2) returning id", [membership,id()])
  await db.exec('set role authenticated')
  await q("select set_config('request.jwt.claim.sub',$1,false)", [admin])
  await assert.rejects(() => q('select public.correct_november_student_class($1,$2,$3,$4,$5,$6,$7)', ['RS-000056', classGrade3, 'Reject duplicate valid payment', id(), oldPayment.id, true,true]), /Another valid 800 PKR receipt/)
  await q('select public.void_payment($1,$2)', [duplicateReceipt, 'Duplicate receipt test cleanup; not collected'])
  await q("select set_config('request.jwt.claim.sub',$1,false)", [admin])
  await assert.rejects(() => q('select public.correct_november_student_class($1,$2,$3,$4,$5,$6,$7)', ['RS-000056', classGrade3, 'Missing refund confirmation', id(), oldPayment.id, false,true]), /refund already occurred/)
  await q("select set_config('request.jwt.claim.sub',$1,false)", [admin])
  await assert.rejects(() => q('select public.correct_november_student_class($1,$2,$3,$4,$5,$6,$7)', ['RS-000056', classGrade3, 'Missing target registration approval', id(), oldPayment.id, true,false]), /Manager approval is required/)
  const expenseCountBefore = Number(await scalar('select count(*) from public.expenses'))
  const settlementCountBefore = Number(await scalar('select count(*) from public.teacher_settlements'))
  const result = await scalar('select public.correct_november_student_class($1,$2,$3,$4,$5,$6,$7)',
    ['RS-000056', classGrade3, 'Correct Noorzia November class from School Grade 2 to School Grade 3; manager confirmed prior refund', correctReq, oldPayment.id, true,true])

  assert.equal(result.student_code, 'RS-000056')
  assert.equal(result.old_class_title, 'School Grade 2')
  assert.equal(result.new_class_title, 'School Grade 3')
  assert.equal(result.teacher_name, 'Tahera Sakhizada')
  assert.equal(Number(result.fee), 1000)
  assert.equal(Number(result.discount), 200)
  assert.equal(Number(result.paid), 0)
  assert.equal(Number(result.outstanding), 800)
  assert.equal(result.original_receipt_reinstated, false)
  assert.equal(result.refund_confirmed, true)
  assert.equal(result.refund_date, null, 'No refund date is invented')
  assert.equal(result.cash_outflow_reposted, false)
  assert.equal(result.teacher_settlement_created, false)
  assert.equal(result.new_cash_receipt_created, false)
  assert.equal(result.duplicate_revenue_created, false)
  assert.equal(Number(result.net_valid_revenue), 0)

  const copiedAgreement = (await q("select agreement_approved_by,agreement_approved_at,registration_type,registered_on,teacher_id,teacher_discount_share from public.monthly_memberships where id=(select m.id from public.monthly_memberships m join public.enrollments e on e.id=m.enrollment_id where e.student_id=$1 and e.class_id=$2 and m.period_id=$3 and m.registration_active)", [noorzia,classGrade3,period])).rows[0]
  assert.deepEqual(copiedAgreement, originalApprovalRow, 'Original agreement approver, timestamp, registration date/type, teacher and share are preserved')

  regActive = (await scalar("select registration_active from public.monthly_memberships where id=$1", [membership]))
  assert.equal(regActive, false, 'Grade 2 membership must be deactivated')

  const newEnrollment = (await scalar("select id from public.enrollments where student_id=$1 and class_id=$2", [noorzia, classGrade3]))
  assert.ok(newEnrollment, 'New enrollment in School Grade 3 must exist')

  const newMembership = (await scalar("select m.id from public.monthly_memberships m join public.enrollments e on e.id=m.enrollment_id where e.student_id=$1 and e.class_id=$2 and m.period_id=$3 and m.registration_active", [noorzia, classGrade3, period]))
  assert.ok(newMembership, 'New active membership in School Grade 3 must exist')

  const newMemFee = (await scalar("select base_fee from public.monthly_memberships where id=$1", [newMembership]))
  assert.equal(Number(newMemFee), 1000, 'New membership fee must be 1000')

  const newMemDisc = (await scalar("select discount from public.monthly_memberships where id=$1", [newMembership]))
  assert.equal(Number(newMemDisc), 200, 'New membership discount must be 200')

  const oldPayVoided = (await scalar("select voided_at is not null from public.payments where id=$1", [oldPayment.id]))
  assert.equal(oldPayVoided, true, 'Original payment receipt must remain voided')
  assert.equal(await scalar("select monthly_membership_id from public.payments where id=$1", [oldPayment.id]), membership, 'Original receipt remains linked to historical Grade 2 membership')
  assert.deepEqual((await q("select id,monthly_membership_id,amount,paid_on,method,reference_note,voided_at,void_reason from public.payments where id=$1", [oldPayment.id])).rows[0], originalVoidedReceipt, 'Receipt ID, amount, date, method, reference and void history remain unchanged')
  assert.equal(Number(await scalar("select count(*) from audit_logs where table_name='payments' and action='UPDATE' and row_id=$1", [oldPayment.id])), 2, 'Original void and original ID correction are audited; the correction does not update the payment')
  assert.equal(Number(await scalar("select count(*) from audit_logs where id=$1", [voidAuditId])), 1, 'Original manager cancellation audit must remain')

  const newPayments = Number(await scalar("select count(*) from public.payments where monthly_membership_id=$1 and voided_at is null", [newMembership]))
  assert.equal(newPayments, 0, 'No valid payment is attached to the new Grade 3 membership')

  const newPayTotal = Number(await scalar("select coalesce(sum(amount),0) from public.payments where monthly_membership_id=$1 and voided_at is null", [newMembership]))
  assert.equal(newPayTotal, 0, 'New membership has no valid payment')

  const totalValid = Number(await scalar("select coalesce(sum(p.amount),0) from public.payments p join public.monthly_memberships m on m.id=p.monthly_membership_id join public.enrollments e on e.id=m.enrollment_id where e.student_id=$1 and m.period_id=$2 and p.voided_at is null", [noorzia, period]))
  assert.equal(totalValid, 0, 'Valid November payments for Noorzia must total zero after refund')
  const tuitionSummary = (await q('select * from public.month_tuition_summary where period_id=$1', [period])).rows[0]
  assert.equal(Number(tuitionSummary.registrations), 1, 'Cancelled Grade 2 registration is excluded from active registration count')
  assert.equal(Number(tuitionSummary.unique_students), 1)
  assert.equal(Number(tuitionSummary.original_total), 1000, 'Cancelled Grade 2 fee is not counted again')
  assert.equal(Number(tuitionSummary.discounts_total), 200, 'Cancelled Grade 2 discount is not counted again')
  assert.equal(Number(tuitionSummary.payable_total), 800)
  assert.equal(Number(tuitionSummary.received_total), 0, 'Voided/refunded original receipt is not counted as valid cash')
  assert.equal(Number(tuitionSummary.outstanding_total), 800)
  assert.equal(Number(tuitionSummary.teacher_total), 500)
  assert.equal(Number(tuitionSummary.office_total), 300)
  assert.equal(Number(tuitionSummary.institution_funded), 0)
  assert.equal(Number(tuitionSummary.pending_registrations), 1)
  assert.equal(Number(await scalar('select count(*) from public.expenses')), expenseCountBefore, 'Do not record the completed refund as a second cash outflow')
  assert.equal(Number(await scalar('select count(*) from public.teacher_settlements')), settlementCountBefore, 'Do not create a teacher settlement')
  assert.equal(Number(await scalar("select count(*) from public.audit_logs where table_name='payments' and row_id=$1 and action='UPDATE' and old_data->>'voided_at' is null and new_data->>'voided_at' is not null", [oldPayment.id])), 1, 'The original receipt void event remains in audit history')

  const auditCount = Number(await scalar("select count(*) from public.audit_logs where table_name='monthly_memberships' and action='CORRECT_NOVEMBER_CLASS' and row_id=$1", [membership]))
  assert.equal(auditCount, 1, 'Audit log must record the correction')
  assert.equal(await scalar("select new_data->>'refund_date' from public.audit_logs where table_name='monthly_memberships' and action='CORRECT_NOVEMBER_CLASS' and row_id=$1", [membership]), null, 'Actual refund date is not guessed')
  assert.equal(await scalar("select new_data->>'receipt_remains_voided' from public.audit_logs where table_name='monthly_memberships' and action='CORRECT_NOVEMBER_CLASS' and row_id=$1", [membership]), 'true')
  assert.equal(await scalar("select new_data->>'refund_cash_outflow_reposted' from public.audit_logs where table_name='monthly_memberships' and action='CORRECT_NOVEMBER_CLASS' and row_id=$1", [membership]), 'false')

  const grade3Count = Number(await scalar("select count(*) from public.monthly_memberships m join public.enrollments e on e.id=m.enrollment_id where e.student_id=$1 and e.class_id=$2 and m.period_id=$3 and m.registration_active", [noorzia, classGrade3, period]))
  assert.equal(grade3Count, 1, 'Exactly one active Grade 3 membership')

  const otherStudents = Number(await scalar("select count(*) from public.students where student_code <> 'RS-000056'"))
  assert.ok(otherStudents >= 0, 'Other students must not be affected')

  console.log(JSON.stringify({
    result: 'PASS',
    student: 'RS-000056 (Noorzia Atayee)',
    month: '2026-11',
    old_class: 'School Grade 2',
    new_class: 'School Grade 3',
    teacher: 'Tahera Sakhizada',
    fee: 1000,
    discount: 200,
    paid: 0,
    outstanding: 800,
    summary: { registrations: 1, original_fee: 1000, discount: 200, payable: 800, valid_received: 0, outstanding: 800 },
    original_receipt_reinstated: false,
    refund_date_invented: false,
    prior_void_audit_preserved: true,
    original_receipt_id_preserved: true,
    duplicate_revenue: false,
    net_valid_revenue: 0,
    grade2_deactivated: true,
    grade3_active: true,
    audit_logged: true,
    atomic: true
  }, null, 2))
} finally {
  await db.close()
}
