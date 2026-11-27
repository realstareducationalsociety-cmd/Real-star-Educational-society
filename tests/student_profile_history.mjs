import { PGlite } from '@electric-sql/pglite'
import { readFileSync, readdirSync } from 'node:fs'
import { randomUUID as uuid } from 'node:crypto'
import assert from 'node:assert/strict'

const db = new PGlite()
const q = (sql, args = []) => db.query(sql, args)
const one = async (sql, args = []) => Object.values((await q(sql, args)).rows[0])[0]

try {
  await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    grant usage on schema public,auth to authenticated,anon;grant execute on function auth.uid() to authenticated,anon;`)
  for (const file of readdirSync('supabase/migrations').filter(name => name.endsWith('.sql')).sort()) {
    let sql = readFileSync(`supabase/migrations/${file}`, 'utf8').replace(/^\uFEFF/, '').replace('create extension if not exists pgcrypto;', '')
    if (file === '013_november_import_review.sql') sql = sql.replace('(array_agg(s.id order by s.id))[1]', 'min(s.id)')
    await db.exec(sql)
  }

  const admin = uuid(), registrar = uuid(), teacher = uuid()
  await q('insert into auth.users values($1),($2)', [admin, registrar])
  await q("insert into staff_profiles(id,full_name,role) values($1,'History Admin','admin'),($2,'History Registrar','registrar')", [admin, registrar])
  await q("select set_config('request.jwt.claim.sub',$1,false)", [admin])
  const teacherId = await one("insert into teachers(full_name,active) values('History Teacher',true) returning id")
  const classA = await one("insert into class_rooms(title,teacher_id,default_fee,active) values('History Class A',$1,1000,true) returning id", [teacherId])
  const classB = await one("insert into class_rooms(title,teacher_id,default_fee,active) values('History Class B',$1,1000,true) returning id", [teacherId])
  const activeStudent = await one("insert into students(first_name,last_name,student_code,active,registered_on) values('Multi','Class','RS-HISTORY-A',true,current_date) returning id")
  const inactiveStudent = await one("insert into students(first_name,last_name,student_code,active,registered_on) values('Inactive','Student','RS-HISTORY-I',false,current_date) returning id")
  const noHistoryStudent = await one("insert into students(first_name,last_name,student_code,active,registered_on) values('No','History','RS-HISTORY-N',true,current_date) returning id")
  const activeA = await one('insert into enrollments(student_id,class_id,enrolled_on,active) values($1,$2,current_date,true) returning id', [activeStudent,classA])
  await one('insert into enrollments(student_id,class_id,enrolled_on,active) values($1,$2,current_date,true) returning id', [activeStudent,classB])
  await one('insert into enrollments(student_id,class_id,enrolled_on,active) values($1,$2,date \'2025-01-15\',false) returning id', [inactiveStudent,classA])
  const periodId = await one("select id from billing_periods where year_month=date_trunc('month',current_date)::date")
  await q(`insert into monthly_memberships(period_id,enrollment_id,teacher_id,class_title_snapshot,registered_on,base_fee,original_fee,discount,
    teacher_discount_share,teacher_share_mode,proration_rule,agreement_approved_by,agreement_approved_at)
    values($1,$2,$3,'History Class A',current_date,1000,1000,0,0,'standard','manual_agreement',$4,now())`, [periodId,activeA,teacherId,admin])

  await db.exec('set role authenticated')
  await q("select set_config('request.jwt.claim.sub',$1,false)", [admin])
  for (const studentId of [activeStudent,inactiveStudent,noHistoryStudent]) {
    const [legacy, registrations, links, periods, audits, fees, payments, books, chapters] = await Promise.all([
      q('select * from v_historical_student_classes where student_id=$1 order by year_month desc', [studentId]),
      q('select public.monthly_registration_list(null,$1)', [studentId]),
      q(`select e.id,e.student_id,e.class_id,e.enrolled_on,e.active,c.title,c.start_time,c.end_time,t.full_name
         from enrollments e left join class_rooms c on c.id=e.class_id left join teachers t on t.id=c.teacher_id
         where e.student_id=$1 order by e.enrolled_on desc,e.id`, [studentId]),
      q('select id,year_month from billing_periods order by year_month'),
      q("select id,action,row_id,created_at,old_data,new_data from audit_logs where table_name='enrollments' and (old_data->>'student_id'=$1 or new_data->>'student_id'=$1) order by created_at desc", [studentId]),
      q("select id,period_id,class_name,paid_total,balance_due,confirmation_status from month_fee_overview where student_id=$1 order by period_id desc", [studentId]),
      q('select p.id,p.monthly_membership_id,p.amount,p.paid_on,p.method,p.voided_at,p.void_reason from payments p join monthly_memberships m on m.id=p.monthly_membership_id join enrollments e on e.id=m.enrollment_id where e.student_id=$1 order by p.paid_on desc,p.id', [studentId]),
      q('select id,title,sold_on,quantity,total_price,paid_total,balance_due,student_id from book_sale_overview where student_id=$1 order by sold_on desc', [studentId]),
      q('select id,title,sold_on,quantity,total_price,paid_total,balance_due,student_id from chapter_sale_overview where student_id=$1 order by sold_on desc', [studentId])
    ])
    assert.equal(legacy.rows.length,studentId===activeStudent ? 1 : 0,'Legacy view returns only preserved historical memberships and valid empty results')
    assert.ok(Array.isArray(registrations.rows[0].monthly_registration_list))
    assert.ok(Array.isArray(links.rows))
    assert.ok(Array.isArray(periods.rows))
    assert.ok(Array.isArray(audits.rows))
    for (const section of [fees,payments,books,chapters]) assert.ok(Array.isArray(section.rows))
  }
  assert.equal(Number(await one('select count(*) from enrollments where student_id=$1 and active', [activeStudent])),2,'Multi-class student history preserves both active classes')
  assert.equal(Number(await one('select count(*) from enrollments where student_id=$1 and not active', [inactiveStudent])),1,'Inactive student history remains queryable')

  await q("select set_config('request.jwt.claim.sub',$1,false)", [registrar])
  assert.equal((await q('select * from v_historical_student_classes where student_id=$1', [activeStudent])).rows.length,0,'Non-admin gets an empty protected legacy-import section')
  assert.ok(Array.isArray((await q('select public.monthly_registration_list(null,$1)', [activeStudent])).rows[0].monthly_registration_list))
  await db.exec('reset role')
  console.log(JSON.stringify({ result:'PASS', admin_profile_queries:true, multi_class_history:true, inactive_student_history:true, no_history_student_empty_state:true, registrar_r_l_s:true }, null, 2))
} finally { await db.close() }
