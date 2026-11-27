import { PGlite } from '@electric-sql/pglite'
import { readFileSync, readdirSync } from 'node:fs'
import { randomUUID as id } from 'node:crypto'
import assert from 'node:assert/strict'

const db = new PGlite()
const q = (sql,args=[]) => db.query(sql,args)
const scalar = async (sql,args=[]) => Object.values((await q(sql,args)).rows[0])[0]
const admin=id(),registrar=id(),teacher=id()

try {
  await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    grant usage on schema public,auth to authenticated,anon;grant execute on function auth.uid() to authenticated,anon;`)
  for (const file of readdirSync('supabase/migrations').filter(f=>f.endsWith('.sql')).sort()) {
    let migration=readFileSync('supabase/migrations/'+file,'utf8').replace('create extension if not exists pgcrypto;','').replace(/^\uFEFF/,'')
    if(file==='013_november_import_review.sql') migration=migration.replace('(array_agg(s.id order by s.id))[1]','min(s.id)')
    await db.exec(migration)
  }
  await q('insert into auth.users values($1),($2)',[admin,registrar])
  await q("insert into staff_profiles(id,full_name,role) values($1,'Admin','admin'),($2,'Registrar','registrar')",[admin,registrar])
  const teacherId=await scalar("insert into teachers(full_name,active) values('Reminder Teacher',true) returning id")
  const classA=await scalar("insert into class_rooms(title,teacher_id,default_fee,active) values('Reminder A',$1,1000,true) returning id",[teacherId])
  const classB=await scalar("insert into class_rooms(title,teacher_id,default_fee,active) values('Reminder B',$1,1000,true) returning id",[teacherId])
  const today=await scalar("select (now() at time zone 'Asia/Karachi')::date::text")
  const [year,month]=today.split('-').map(Number)
  const currentMonth=new Date(Date.UTC(year,month-1,1)).toISOString().slice(0,10)
  const previousMonth=new Date(Date.UTC(year,month-2,1)).toISOString().slice(0,10)
  const beforePrevious=new Date(Date.UTC(year,month-3,1)).toISOString().slice(0,10)
  await q('insert into billing_periods(year_month) values($1),($2),($3) on conflict(year_month) do nothing',[beforePrevious,previousMonth,currentMonth])

  const multiStudent=await scalar(`insert into students(first_name,last_name,guardian_name,phone,guardian_phone,active)
    values('Multi','Class','Guardian','03001234567','0791234567',true) returning id`)
  const invalidPhoneStudent=await scalar(`insert into students(first_name,last_name,guardian_phone,active)
    values('No','Phone','call me',true) returning id`)
  const overdueA=await scalar('insert into enrollments(student_id,class_id,enrolled_on,active) values($1,$2,$3,true) returning id',[multiStudent,classA,beforePrevious])
  const renewedB=await scalar('insert into enrollments(student_id,class_id,enrolled_on,active) values($1,$2,$3,true) returning id',[multiStudent,classB,beforePrevious])
  const invalidEnrollment=await scalar('insert into enrollments(student_id,class_id,enrolled_on,active) values($1,$2,$3,true) returning id',[invalidPhoneStudent,classA,beforePrevious])
  const prevPeriod=await scalar('select id from billing_periods where year_month=$1',[previousMonth])
  const currentPeriod=await scalar('select id from billing_periods where year_month=$1',[currentMonth])
  await q("select set_config('request.jwt.claim.sub',$1,false)",[admin])
  const membership=async(period,enrollment,title,registered)=>scalar(`insert into monthly_memberships(
    period_id,enrollment_id,teacher_id,class_title_snapshot,registered_on,base_fee,original_fee,discount,
    teacher_discount_share,teacher_share_mode,proration_rule,agreement_approved_by,agreement_approved_at)
    values($1,$2,$3,$4,$5,1000,1000,0,0,'standard','manual_agreement',$6,now()) returning id`,[period,enrollment,teacherId,title,registered,admin])
  const priorA=await membership(prevPeriod,overdueA,'Reminder A',beforePrevious)
  await membership(prevPeriod,renewedB,'Reminder B',beforePrevious)
  await membership(currentPeriod,renewedB,'Reminder B',today)
  await membership(prevPeriod,invalidEnrollment,'Reminder A',beforePrevious)

  await db.exec('set role authenticated')
  await q("select set_config('request.jwt.claim.sub',$1,false)",[admin])
  await q(`select public.record_tuition_payment($1,100,$2::date,'cash','Payment does not control reminders',$3)`,[priorA,today,id()])
  let reminders=(await q('select * from public.get_registration_renewal_reminders()')).rows
  assert.equal(reminders.length,2,'Reminder is per class: the renewed second class is excluded')
  assert.deepEqual(new Set(reminders.map(row=>row.enrollment_id)),new Set([overdueA,invalidEnrollment]))
  const validRow=reminders.find(row=>row.enrollment_id===overdueA)
  const invalidRow=reminders.find(row=>row.enrollment_id===invalidEnrollment)
  assert.equal(validRow.student_has_consent,false)
  assert.equal(validRow.guardian_has_consent,false)
  assert.equal(validRow.reminder_status,'pending')
  assert.equal(validRow.guardian_whatsapp_phone,'93791234567','Afghan national mobile number is normalized for WhatsApp')
  assert.equal(validRow.student_whatsapp_phone,'923001234567','Pakistani local mobile number is normalized for WhatsApp')
  assert.equal(invalidRow.guardian_whatsapp_phone,null,'Invalid guardian contact is not made sendable')
  await db.exec('reset role')
  assert.equal(await scalar("select public.whatsapp_phone_e164('+92 300 123 4567')"),'923001234567')
  assert.equal(await scalar("select public.whatsapp_phone_e164('03001234567')"),'923001234567')
  assert.equal(await scalar("select public.whatsapp_phone_e164('0712345678')"),'93712345678')
  assert.equal(await scalar("select public.whatsapp_phone_e164('+93 712345678')"),'93712345678')
  assert.equal(await scalar("select public.whatsapp_phone_e164('call me')"),null)
  await db.exec('set role authenticated')
  assert.equal(new Date(validRow.due_period).toISOString().slice(0,10),currentMonth,'Expected renewal period comes from billing_periods, not payment date')

  await q("select set_config('request.jwt.claim.sub',$1,false)",[registrar])
  await assert.rejects(()=>q("select public.record_guardian_message_consent($1,'guardian','0791234567',true,'Consent obtained by phone')",[multiStudent]),/Administrator access required/)
  await assert.rejects(()=>q("select public.confirm_registration_renewal_reminder_sent($1,$2,'guardian','Sent manually')",[overdueA,currentMonth]),/Administrator access required/)
  await assert.rejects(()=>q("select public.set_renewal_reminder_recipient($1,'student')",[multiStudent]),/Administrator access required/)
  await assert.rejects(()=>q("update students set renewal_reminder_recipient='student' where id=$1",[multiStudent]),/Administrator access required/)
  await assert.rejects(()=>q('select * from public.get_student_renewal_message_consents($1)',[multiStudent]),/Administrator access required/)
  const registrarRows=(await q('select * from public.get_registration_renewal_reminders()')).rows
  assert.equal(registrarRows[0].guardian_phone,null,'Registrar cannot read contact numbers through reminders RPC')
  await q("select set_config('request.jwt.claim.sub',$1,false)",[admin])
  await q("select public.record_guardian_message_consent($1,'guardian','0791234567',true,'Guardian gave consent in person')",[multiStudent])
  await q("select public.record_guardian_message_consent($1,'student','03001234567',true,'Student gave consent in person')",[multiStudent])
  reminders=(await q('select * from public.get_registration_renewal_reminders()')).rows
  assert.equal(reminders.find(row=>row.enrollment_id===overdueA).guardian_has_consent,true,'Guardian consent is scoped to that exact phone')
  assert.equal(reminders.find(row=>row.enrollment_id===overdueA).student_has_consent,true,'Student consent is separate from guardian consent')
  await q("select public.set_renewal_reminder_recipient($1,'student')",[multiStudent])
  assert.equal(await scalar('select renewal_reminder_recipient from students where id=$1',[multiStudent]),'student','Administrator can set the default reminder recipient')
  const sentId=await scalar("select public.confirm_registration_renewal_reminder_sent($1,$2,'student','WhatsApp message sent manually')",[overdueA,currentMonth])
  assert.equal(await scalar("select public.confirm_registration_renewal_reminder_sent($1,$2,'guardian','Duplicate confirmation retry')",[overdueA,currentMonth]),sentId,'Repeated confirmation does not create a second reminder even after changing recipient')
  reminders=(await q('select * from public.get_registration_renewal_reminders()')).rows
  assert.equal(reminders.find(row=>row.enrollment_id===overdueA).reminder_status,'sent_confirmed')
  await db.exec('reset role')
  assert.equal(Number(await scalar('select count(*) from registration_renewal_reminder_sends where enrollment_id=$1 and due_period=$2',[overdueA,currentMonth])),1)
  assert.equal(Number(await scalar("select count(*) from audit_logs where table_name='registration_renewal_reminder_sends' and row_id=$1 and action='INSERT'",[sentId])),1)
  const consentRows=(await q('select * from public.get_student_renewal_message_consents($1)',[multiStudent])).rows
  assert.ok(consentRows.some(row=>row.recipient_type==='student' && row.phone_e164==='923001234567'))

  await db.exec('set role authenticated')
  await q("select set_config('request.jwt.claim.sub',$1,false)",[admin])
  await q("select public.record_guardian_message_consent($1,'guardian','0791234567',false,$2)",[multiStudent,'Guardian withdrew consent'])
  reminders=(await q('select * from public.get_registration_renewal_reminders()')).rows
  assert.equal(reminders.find(row=>row.enrollment_id===overdueA).guardian_has_consent,false,'Revoked consent disables future WhatsApp actions')
  await db.exec('reset role')
  assert.equal(Number(await scalar("select count(*) from audit_logs where table_name='guardian_message_consents' and action='UPDATE'")),1,'Consent revocation is audited')

  // Number changes do not carry consent; prior numbers remain revocable by exact recipient and phone.
  await q("update students set phone='03007654321' where id=$1",[multiStudent])
  reminders=(await q('select * from public.get_registration_renewal_reminders()')).rows
  assert.equal(reminders.find(row=>row.enrollment_id===overdueA).student_has_consent,false,'A replacement number does not inherit consent')
  assert.ok(reminders.find(row=>row.enrollment_id===overdueA).consent_history.some(c=>c.phone_e164==='923001234567' && c.recipient_type==='student'),'Old number remains in consent history')
  await q("select public.record_guardian_message_consent($1,'student','03001234567',false,'Old number consent revoked')",[multiStudent])
  assert.equal((await q('select * from public.get_student_renewal_message_consents($1)',[multiStudent])).rows.find(c=>c.phone_e164==='923001234567').is_active,false,'Old-number consent remains revocable after contact change')

  // A registration for the expected next period clears this class reminder only.
  await q("select set_config('request.jwt.claim.sub',$1,false)",[admin])
  await membership(currentPeriod,overdueA,'Reminder A',today)
  reminders=(await q('select * from public.get_registration_renewal_reminders()')).rows
  assert.equal(reminders.some(row=>row.enrollment_id===overdueA),false,'Early next-period registration clears that class reminder')
  assert.equal(reminders.some(row=>row.enrollment_id===invalidEnrollment),true,'A different class still has its own reminder')

  await db.exec('reset role')
  await db.exec('set role anon')
  await assert.rejects(()=>q('select * from public.get_registration_renewal_reminders()'),/permission denied/)
  await db.exec('reset role')
  const reminderUi=readFileSync('app/components/RegistrationRenewalReminders.vue','utf8')
  assert.match(reminderUi,/موعد تمدید ثبت‌نام شما/,'Student recipient gets a direct-to-student message')
  assert.match(reminderUi,/موعد تمدید ثبت‌نام فرزندتان/,'Guardian recipient gets a child-focused message')
  console.log(JSON.stringify({result:'PASS',per_class_reminders:true,early_renewal_excluded:true,payment_date_ignored:true,consent_by_recipient_and_exact_phone:true,old_number_revocation:true,phone_format_afghanistan_pakistan:true,admin_only_recipient_and_contact_access:true,adult_and_guardian_message_templates:true,whatsapp_sent_only_by_admin_confirmation:true,confirmation_idempotent:true,audited:true},null,2))
} finally {
  await db.close()
}
