import { PGlite } from '@electric-sql/pglite'
import { readFileSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import assert from 'node:assert/strict'

const db=new PGlite()
const id=()=>randomUUID()
const admin=id(),accountant=id(),registrar=id(),student=id(),teacher=id(),classId=id(),classId2=id(),enrollment=id(),period=id(),membership=id(),book=id(),chapter=id()
const query=(sql,args=[])=>db.query(sql,args)
const scalar=async(sql,args=[])=>Object.values((await query(sql,args)).rows[0])[0]
const reject=async(sql,args=[])=>assert.rejects(()=>query(sql,args))
await db.exec(`create role anon; create role authenticated; create schema auth;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
grant usage on schema public,auth to authenticated,anon;
grant execute on function auth.uid() to authenticated,anon;`)
// PGlite has built-in gen_random_uuid but does not ship pgcrypto. All other migration SQL is unchanged.
await db.exec(readFileSync('supabase/migrations/001_initial.sql','utf8').replace('create extension if not exists pgcrypto;',''))
await query(`insert into auth.users values ($1),($2),($3)`,[admin,accountant,registrar])
await query(`insert into staff_profiles(id,full_name,role) values($1,'Admin','admin'),($2,'Accountant','accountant'),($3,'Registrar','registrar')`,[admin,accountant,registrar])
await query(`insert into students(id,first_name) values($1,'Ahmad')`,[student])
await query(`insert into teachers(id,full_name) values($1,'Teacher')`,[teacher])
await query(`insert into class_rooms(id,title,teacher_id,default_fee) values($1,'A2',$2,2000)`,[classId,teacher])
await query(`insert into class_rooms(id,title,teacher_id,default_fee) values($1,'B1',$2,2000)`,[classId2,teacher])
await query(`insert into enrollments(id,student_id,class_id) values($1,$2,$3)`,[enrollment,student,classId])
await query(`insert into billing_periods(id,year_month) values($1,'2025-01-01')`,[period])
await query(`insert into monthly_memberships(id,period_id,enrollment_id,teacher_id,class_title_snapshot,base_fee,discount) values($1,$2,$3,$4,'Historical A2',2000,500)`,[membership,period,enrollment,teacher])
await query(`insert into books(id,title,owner_name,opening_stock,sale_price,commission_per_book) values($1,'Book','External',10,500,100)`,[book])
const legacy=id()
await query(`insert into book_sales(id,book_id,quantity,unit_price,unit_commission) values($1,$2,1,500,100)`,[legacy,book])
await db.exec(readFileSync('supabase/migrations/002_chapters_books_printing.sql','utf8'))
await db.exec(readFileSync('supabase/migrations/003_confirmed_monthly_registration.sql','utf8'))
assert.equal(Number(await scalar('select paid_total from book_sales where id=$1',[legacy])),0)
await query(`insert into chapters(id,title,class_id,produced_quantity,default_sale_price,total_print_cost,printing_cost_on) values($1,'Chapter',$2,5,100,30,'2025-01-03')`,[chapter,classId])
await db.exec('set role authenticated')
await query(`select set_config('request.jwt.claim.sub',$1,false)`,[admin])
const sell=async(kind,item,price,paid,request=id())=>scalar(`select sell_material($1,$2,$3,$4,$5,$6,'2025-01-10',$7)`,[kind,item,student,classId,price,paid,request])
const pay=(kind,sale,amount,request=id(),complete=false)=>query(`select pay_material($1,$2,$3,'2025-01-11',$4,$5)`,[kind,sale,amount,request,complete])
const office=()=>scalar(`select office_month_summary('2025-01-01')`)
const before=await office()
const request=id(),bookSale=await sell('book',book,500,100,request)
assert.equal(await sell('book',book,500,100,request),bookSale)
assert.equal(await scalar('select payment_status from book_sales where id=$1',[bookSale]),'partial')
assert.equal(Number(await scalar('select unit_commission from book_sales where id=$1',[bookSale])),0)
assert.deepEqual(await office(),before,'Book sales must not change any office figure')
await reject(`select pay_material('book',$1,-1,'2025-01-11',$2)`,[bookSale,id()])
await reject(`select pay_material('book',$1,401,'2025-01-11',$2)`,[bookSale,id()])
await pay('book',bookSale,0,id(),true)
await pay('book',bookSale,0,id(),true)
assert.equal(Number(await scalar('select count(*) from material_payments where book_sale_id=$1',[bookSale])),2)
assert.equal(await scalar('select payment_status from book_sales where id=$1',[bookSale]),'paid')
assert.equal(await scalar('select last_paid_on::text from book_sale_overview where id=$1',[bookSale]),'2025-01-11')
assert.deepEqual(await office(),before)
const receipt=await scalar('select id from material_payments where book_sale_id=$1 and amount=400',[bookSale])
await query(`select void_material_payment($1,'Correction documented')`,[receipt])
await reject(`select void_material_payment($1,'Again')`,[receipt])
assert.equal(Number(await scalar('select paid_total from book_sales where id=$1',[bookSale])),100)
const unpaid=await sell('book',book,500,0)
assert.equal(await scalar('select payment_status from book_sales where id=$1',[unpaid]),'unpaid')
const chapterSale=await sell('chapter',chapter,100,40)
let summary=await office()
assert.equal(summary.chapter_collected,40);assert.equal(summary.chapter_outstanding,60)
assert.equal(summary.chapter_printing,30);assert.equal(summary.chapter_net,10)
assert.equal(summary.gross_collected,40);assert.equal(summary.teacher_entitlement,1000)
const paymentRequest=id();await pay('chapter',chapterSale,60,paymentRequest);await pay('chapter',chapterSale,60,paymentRequest)
summary=await office();assert.equal(summary.chapter_collected,100);assert.equal(summary.chapter_net,70)
assert.equal(await scalar('select last_paid_on::text from chapter_sale_overview where id=$1',[chapterSale]),'2025-01-11')
const spare=await scalar(`insert into chapters(title,class_id,produced_quantity,default_sale_price) values('One copy',$1,1,100) returning id`,[classId])
await assert.rejects(()=>sell('chapter',spare,100,101))
assert.equal(Number(await scalar('select count(*) from chapter_sales where chapter_id=$1',[spare])),0,'Invalid sale must roll back')
await sell('chapter',spare,100,0)
await assert.rejects(()=>sell('chapter',spare,100,0),'Stock must not be oversold')
await reject(`update chapter_sales set paid_total=0 where id=$1`,[chapterSale])
await reject(`delete from material_payments where chapter_sale_id=$1`,[chapterSale])
await reject(`insert into book_sales(book_id,quantity,unit_price,unit_commission) values($1,1,500,0)`,[book])
await reject(`update chapters set produced_quantity=0 where id=$1`,[chapter])
await query('update monthly_memberships set teacher_discount_share=200 where id=$1',[membership])
assert.equal(Number(await scalar('select teacher_entitlement from monthly_memberships where id=$1',[membership])),800)
assert.equal(Number(await scalar('select center_entitlement from monthly_memberships where id=$1',[membership])),700)
await query('update monthly_memberships set teacher_discount_share=0 where id=$1',[membership])
await query(`insert into payments(monthly_membership_id,amount,paid_on) values($1,600,'2025-01-11')`,[membership])
const voidTuition=await scalar(`insert into payments(monthly_membership_id,amount,paid_on) values($1,100,'2025-01-11') returning id`,[membership])
await query(`select void_payment($1,'Wrong receipt')`,[voidTuition])
await query(`insert into teacher_settlements(period_id,class_id,teacher_id,amount,paid_on) values($1,$2,$3,300,'2025-01-12')`,[period,classId,teacher])
const report=()=>scalar(`select class_month_report('2025-01-01',$1,$2)`,[classId,teacher])
const originalReport=await report(),row=originalReport.rows[0]
assert.equal(row.base_fee,2000);assert.equal(row.discount,500);assert.equal(row.amount_due,1500)
assert.equal(row.paid_total,600);assert.equal(row.balance_due,900);assert.equal(row.teacher_entitlement,1000);assert.equal(row.center_entitlement,500)
assert.equal(originalReport.settlements[0].amount,300)
await query(`update enrollments set active=false where id=$1`,[enrollment])
await query(`update class_rooms set title='New title',default_fee=4000 where id=$1`,[classId])
assert.deepEqual(await report(),originalReport,'Current class changes must not change historical financial reports')
await reject(`update enrollments set student_id=$1 where id=$2`,[id(),enrollment])

assert.equal(Number(await scalar(`select ensure_billing_month('2025-02-01')`)),0)
assert.equal(Number(await scalar(`select count(*) from monthly_memberships where period_id=(select id from billing_periods where year_month='2025-02-01')`)),0,'Opening a month must not assume active students renew')
const registration=async(month,studentId,classes,discount=0,firstName='Ahmad')=>scalar(
  `select register_monthly_student($1,$2,$3,'Test','Father','555',null,null,$4,$5,$6)`,
  [month,studentId,firstName,`${month.slice(0,7)}-05`,classes,discount])
const february=await registration('2025-02-01',student,[classId,classId2],500)
assert.equal(february.membership_count,2,'One student can register in multiple classes')
assert.equal(Number(await scalar(`select count(*) from students where id=$1`,[student])),1,'Returning registration must reuse the permanent student')
const febPeriod=await scalar(`select id from billing_periods where year_month='2025-02-01'`)
assert.equal(Number(await scalar(`select count(*) from monthly_memberships where period_id=$1 and registration_active`,[febPeriod])),2)
await assert.rejects(()=>registration('2025-02-01',student,[classId],500),'Duplicate class/month registration must be rejected')
const manualMembership=await scalar(`select id from monthly_memberships where period_id=$1 and enrollment_id=(select id from enrollments where student_id=$2 and class_id=$3)`,[febPeriod,student,classId2])
await query(`select adjust_monthly_fee($1,2000,500,0,true,900,600,'Approved special agreement','Manual shares')`,[manualMembership])
let adjusted=(await query(`select * from month_fee_overview where id=$1`,[manualMembership])).rows[0]
assert.equal(Number(adjusted.teacher_entitlement),900)
assert.equal(Number(adjusted.center_entitlement),600)
assert.equal(adjusted.manually_adjusted,true)
const adjustmentAudit=(await query(`select actor_id,old_data,new_data from audit_logs where table_name='monthly_memberships' and row_id=$1 and action='UPDATE' order by id desc limit 1`,[manualMembership])).rows[0]
assert.equal(adjustmentAudit.actor_id,admin)
assert.equal(adjustmentAudit.old_data.teacher_entitlement,1000)
assert.equal(Number(adjustmentAudit.new_data.manual_teacher_share),900)
assert.equal(Number(adjustmentAudit.new_data.manual_office_share),600)
assert.equal(adjustmentAudit.new_data.manual_adjustment_reason,'Approved special agreement')
await assert.rejects(()=>query(`select adjust_monthly_fee($1,2000,500,0,true,900,500,'Wrong total','')`,[manualMembership]))
const februarySummary=await scalar(`select office_month_summary('2025-02-01')`)
assert.equal(februarySummary.teacher_entitlement,2900,'Office summary must use manually adjusted teacher entitlement')
assert.equal(februarySummary.office_entitlement,2100,'Office summary must include the effective office share')
await query(`select cancel_monthly_registration($1,'Student withdrew')`,[manualMembership])
assert.equal(Number(await scalar(`select count(*) from month_fee_overview where period_id=$1`,[febPeriod])),1,'Cancelled monthly registrations must not count')
const classOneFebruary=await scalar(`select id from monthly_memberships where period_id=$1 and enrollment_id=(select id from enrollments where student_id=$2 and class_id=$3)`,[febPeriod,student,classId])
await query(`insert into teacher_settlements(period_id,class_id,teacher_id,amount,paid_on) values($1,$2,$3,500,'2025-02-10')`,[febPeriod,classId,teacher])
await assert.rejects(()=>query(`select adjust_monthly_fee($1,4000,500,0,true,1500,2000,'After settlement','')`,[classOneFebruary]))
const marchClasses=JSON.stringify([{student_id:student,class_ids:[classId,classId2],discount:0}])
const renewed=await scalar(`select bulk_renew_monthly_students('2025-03-01','2025-03-03',$1::jsonb)`,[marchClasses])
assert.equal(renewed.length,1)
assert.equal(renewed[0].membership_count,2,'Bulk renewal must add one row per selected student-class pair')
assert.equal(Number(await scalar(`select count(*) from students where id=$1`,[student])),1)
const april=await registration('2025-04-01',null,[classId2],0,'New')
assert.ok(april.student_id)
assert.equal(Number(await scalar(`select count(*) from monthly_memberships where period_id=(select id from billing_periods where year_month='2025-04-01') and registration_active`)),1)
const invalidBulk=JSON.stringify([
  {student_id:student,class_ids:[classId],discount:0},
  {student_id:april.student_id,class_ids:[id()],discount:0}
])
await assert.rejects(()=>query(`select bulk_renew_monthly_students('2025-05-01','2025-05-05',$1::jsonb)`,[invalidBulk]))
assert.equal(Number(await scalar(`select count(*) from billing_periods where year_month='2025-05-01'`)),0,'Failed bulk renewal must roll back its month and prior student insertions')
await query(`select set_config('request.jwt.claim.sub',$1,false)`,[accountant])
await pay('book',unpaid,50)
assert.equal((await report()).rows.length,1)
await query(`select set_config('request.jwt.claim.sub',$1,false)`,[registrar])
const marchMembership=await scalar(`select id from monthly_memberships where period_id=(select id from billing_periods where year_month='2025-03-01') and registration_active limit 1`)
await assert.rejects(()=>query(`select adjust_monthly_fee($1,2000,0,0,true,1000,1000,'Unauthorized change','')`,[marchMembership]))
await reject(`select office_month_summary('2025-01-01')`)
await reject(`select class_month_report('2025-01-01')`)
await assert.rejects(()=>pay('book',unpaid,50))
assert.equal(Number(await scalar('select count(*) from material_payments')),0)
assert.equal(Number(await scalar('select count(*) from book_sale_overview')),0)
await db.exec('reset role')
assert.ok(Number(await scalar(`select count(*) from audit_logs where table_name='material_payments' and action='UPDATE'`))>0)
console.log('PASS: migrations, financial arithmetic, book isolation, receipts, stock, audit/voids, monthly reports, confirmed and bulk registrations, duplicate/atomic rollback, cancellation counts, manual-share audit and totals, settlement guards, and role permissions.')
await db.exec(readFileSync('supabase/migrations/004_database_integrity.sql','utf8'))
console.log('PASS: migrations 003 and 004 applied after legacy fixtures.')
const {verifyAudit}=await import('./database_audit.mjs')
await verifyAudit(db,{admin,accountant,registrar,teacher})
await db.exec(readFileSync('supabase/migrations/005_historical_import_staging.sql','utf8'))
await db.exec('set role authenticated')
await query(`select set_config('request.jwt.claim.sub',$1,false)`,[admin])
const importRows=[
  {source_key:'Registrations:11:source-a',source_sheet:'Registrations',source_row:11,payload:{name:'Review only',month:'2026-06'}},
  {source_key:'ReviewFlags:20:source-b',source_sheet:'ReviewFlags',source_row:20,payload:{severity:'HIGH',decision:'pending'}}
]
const operationalCounts=await query(`select
  (select count(*) from students) students,
  (select count(*) from monthly_memberships) memberships,
  (select count(*) from payments) payments,
  (select count(*) from expenses) expenses,
  (select count(*) from teacher_settlements) settlements,
  (select count(*) from partner_transactions) partner_transactions`)
const checksum='a'.repeat(64)
const staged=await scalar(`select stage_historical_import($1,$2,$3::jsonb)`,['review.xlsx',checksum,JSON.stringify(importRows)])
assert.equal(staged.row_count,2)
assert.equal(staged.already_staged,false)
assert.equal(Number(await scalar(`select count(*) from historical_import_source_rows where batch_id=$1`,[staged.batch_id])),2)
const replay=await scalar(`select stage_historical_import($1,$2,$3::jsonb)`,['review.xlsx',checksum,JSON.stringify(importRows)])
assert.equal(replay.batch_id,staged.batch_id)
assert.equal(replay.already_staged,true)
assert.equal(Number(await scalar(`select count(*) from historical_import_batches`)),1)
const reviewId=await scalar(`select id from historical_import_source_rows where source_key='Registrations:11:source-a'`)
await query(`select review_historical_import_row($1,'accepted','Identity crosschecked')`,[reviewId])
assert.equal(await scalar(`select review_status from historical_import_source_rows where id=$1`,[reviewId]),'accepted')
assert.equal(Number(await scalar(`select count(*) from audit_logs where table_name='historical_import_source_rows' and action='REVIEW'`)),1)
assert.deepEqual((await query(`select
  (select count(*) from students) students,
  (select count(*) from monthly_memberships) memberships,
  (select count(*) from payments) payments,
  (select count(*) from expenses) expenses,
  (select count(*) from teacher_settlements) settlements,
  (select count(*) from partner_transactions) partner_transactions`)).rows,operationalCounts.rows,'Staging and row review must not write operational ledgers')
await query(`select set_config('request.jwt.claim.sub',$1,false)`,[accountant])
await assert.rejects(()=>query(`select stage_historical_import($1,$2,$3::jsonb)`,['other.xlsx','b'.repeat(64),JSON.stringify(importRows)]))
assert.equal(Number(await scalar(`select count(*) from historical_import_source_rows`)),0,'Non-admin users cannot read staged personal data')
await db.exec('reset role')
console.log('PASS: migration 005 admin-only staging, provenance retention, idempotent workbook replay, row review audit, and RLS.')
await db.exec(readFileSync('supabase/migrations/006_historical_operational_posting.sql','utf8'))
await db.exec('set role authenticated')
await query(`select set_config('request.jwt.claim.sub',$1,false)`,[admin])
const postingRows=[
  {source_key:'Students:1:person-a',source_sheet:'Students',source_row:1,payload:{'Provisional Person Key':'person-a','Display Name Candidate':'Import Test'}},
  {source_key:'Classes:2:class-a',source_sheet:'Classes',source_row:2,payload:{'Class Key':'class-a','Class Name':'Import Test Class','Teacher':'Import Teacher'}},
  {source_key:'Registrations:3:registration-a',source_sheet:'Registrations',source_row:3,payload:{'Name Key':'person-a','Class Key':'class-a'}},
  {source_key:'Registrations:4:registration-duplicate',source_sheet:'Registrations',source_row:4,payload:{'Name Key':'person-a','Class Key':'class-a'}},
  {source_key:'Payments:5:receipt-a',source_sheet:'Payments',source_row:5,payload:{'Amount Received':500}},
  {source_key:'Expenses:6:expense-a',source_sheet:'Expenses',source_row:6,payload:{'Amount':75}}
]
const postingChecksum='c'.repeat(64)
const postingBatch=await scalar(`select stage_historical_import($1,$2,$3::jsonb)`,
  ['posting-test.xlsx',postingChecksum,JSON.stringify(postingRows)])
const postingSource=async key=>scalar(`select id from historical_import_source_rows where batch_id=$1 and source_key=$2`,[postingBatch.batch_id,key])
const resolveSource=async(key,resolution,reason='Verified by isolated posting test')=>query(
  `select resolve_historical_import_row($1,$2::jsonb,$3)`,
  [await postingSource(key),JSON.stringify(resolution),reason])
const commonRegistration={
  kind:'registration',student_entity_key:'person-a',class_entity_key:'class-a',month:'2026-06',
  registered_on:'2026-06-01',registration_date_verified:true,registration_verified:true,
  base_fee:2000,discount:0,enrollment_active:false
}
await resolveSource('Students:1:person-a',{
  kind:'student',action:'create',identity_confirmed:true,entity_key:'person-a',first_name:'Import Test',last_name:'Student',profile_active:false
})
await resolveSource('Classes:2:class-a',{
  kind:'class',action:'create',entity_key:'class-a',title:'Import Test Class',
  teacher_entity_key:'teacher-a',teacher_name:'Import Teacher',teacher_identity_confirmed:true,teacher_active:false,
  default_fee:2000,active:false
})
await assert.rejects(()=>resolveSource('Registrations:4:registration-duplicate',{
  ...commonRegistration,month:'2026-11',registered_on:'2026-11-01'
}))
await resolveSource('Registrations:3:registration-a',commonRegistration)
await resolveSource('Registrations:4:registration-duplicate',commonRegistration)
await assert.rejects(()=>resolveSource('Payments:5:receipt-a',{
  kind:'tuition_payment',registration_source_key:'Registrations:3:registration-a',
  amount:500,paid_on:'2026-06-05',payment_verified:false,duplicate_source_checked:true,method:'cash'
}))
await resolveSource('Payments:5:receipt-a',{
  kind:'tuition_payment',registration_source_key:'Registrations:3:registration-a',
  amount:500,paid_on:'2026-06-05',payment_verified:true,duplicate_source_checked:true,method:'cash'
})
await resolveSource('Expenses:6:expense-a',{
  kind:'expense',category:'Test',description:'Verified test expense',
  amount:75,spent_on:'2026-06-07',expense_verified:true
})
const postingPreview=await scalar(`select preview_historical_import_batch($1)`,[postingBatch.batch_id])
assert.equal(postingPreview.records_ready,5)
assert.equal(postingPreview.duplicate_records_excluded,1)
assert.equal(postingPreview.financial_transactions_requiring_verification,0)
await query(`select set_config('request.jwt.claim.sub',$1,false)`,[accountant])
await assert.rejects(()=>scalar(`select preview_historical_import_batch($1)`,[postingBatch.batch_id]))
await assert.rejects(()=>scalar(`select post_historical_import_batch($1,true)`,[postingBatch.batch_id]))
await query(`select set_config('request.jwt.claim.sub',$1,false)`,[admin])
await assert.rejects(()=>scalar(`select post_historical_import_batch($1,false)`,[postingBatch.batch_id]))
const beforePost=await scalar(`select jsonb_build_object(
  'students',(select count(*) from students),
  'teachers',(select count(*) from teachers),
  'classes',(select count(*) from class_rooms),
  'memberships',(select count(*) from monthly_memberships),
  'payments',(select count(*) from payments),
  'expenses',(select count(*) from expenses),
  'settlements',(select count(*) from teacher_settlements),
  'partner_transactions',(select count(*) from partner_transactions))`)
const posted=await scalar(`select post_historical_import_batch($1,true)`,[postingBatch.batch_id])
assert.equal(posted.posted,5)
assert.equal(posted.duplicates,1)
assert.equal(posted.requiring_review,0)
assert.equal(posted.financial_transactions,2)
const afterPost=await scalar(`select jsonb_build_object(
  'students',(select count(*) from students),
  'teachers',(select count(*) from teachers),
  'classes',(select count(*) from class_rooms),
  'memberships',(select count(*) from monthly_memberships),
  'payments',(select count(*) from payments),
  'expenses',(select count(*) from expenses),
  'settlements',(select count(*) from teacher_settlements),
  'partner_transactions',(select count(*) from partner_transactions))`)
assert.equal(afterPost.students,beforePost.students+1)
assert.equal(afterPost.teachers,beforePost.teachers+1)
assert.equal(afterPost.classes,beforePost.classes+1)
assert.equal(afterPost.memberships,beforePost.memberships+1)
assert.equal(afterPost.payments,beforePost.payments+1)
assert.equal(afterPost.expenses,beforePost.expenses+1)
assert.equal(afterPost.settlements,beforePost.settlements,'Tuition import must not create teacher settlements')
assert.equal(afterPost.partner_transactions,beforePost.partner_transactions,'Unrelated partner ledgers must remain unchanged')
assert.equal(Number(await scalar(`select count(*) from historical_import_destinations where source_row_id=$1 and mapping_status='duplicate_excluded'`,[await postingSource('Registrations:4:registration-duplicate')])),1)
assert.equal(Number(await scalar(`select count(*) from audit_logs where table_name='historical_import_source_rows' and action='POST'`)),5)
assert.equal(Number(await scalar(`select count(*) from audit_logs where table_name='historical_import_source_rows' and action='POST_DUPLICATE'`)),1)
const replayPost=await scalar(`select post_historical_import_batch($1,true)`,[postingBatch.batch_id])
assert.equal(replayPost.posted,0)
assert.equal(replayPost.duplicates,0)
assert.equal((await scalar(`select count(*) from payments where reference_note like 'Historical import source %'`)),1)
assert.equal((await scalar(`select count(*) from expenses where description='Verified test expense'`)),1)
await db.exec('reset role')
console.log('PASS: migration 006 admin resolution, preview, transactional posting, duplicate exclusions, and idempotent replay.')
await db.exec(readFileSync('supabase/live_import_status.sql','utf8'))
console.log('PASS: live status SQL reports schema, operational, and posting counts without data changes.')
await db.exec(readFileSync('supabase/migrations/007_dashboard_registration.sql','utf8'))
await db.exec(readFileSync('supabase/migrations/008_registration_proration_and_settlements.sql','utf8'))
await db.exec(readFileSync('supabase/migrations/009_restore_dashboard_and_settlement_views.sql','utf8'))
const {verifyDashboard}=await import('./dashboard_database.mjs')
await verifyDashboard(db,{admin,registrar,accountant,teacher})
await db.close()
