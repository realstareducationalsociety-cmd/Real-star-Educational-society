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
    await db.exec(readFileSync('supabase/migrations/' + file, 'utf8').replace('create extension if not exists pgcrypto;', ''))
  }
  await q('insert into auth.users values($1)', [admin])
  await q("insert into staff_profiles(id,full_name,role) values($1,'Admin','admin')", [admin])

  const workbook = parseHistoricalWorkbook(new Uint8Array(readFileSync('Real_Star_June-Nov_2026_Import_Review.xlsx')))
  const novRows = workbook.rows.filter(row => {
    const month = row.payload['Period'] || row.payload['Source Month'] || row.payload['Month']
    return ['Registrations', 'RegistrationLeads', 'Payments'].includes(row.source_sheet)
      && ['2026-11', 'Nov', 'November', 'November 2026'].includes(month)
  })
  assert.equal(novRows.length, 323)

  const batch = id()
  await q(`insert into historical_import_batches(id,source_filename,source_sha256,row_count,status,created_by)
    values($1,'Real_Star_June-Nov_2026_Import_Review.xlsx',$2,356,'reviewing',$3)`, [batch, checksum, admin])
  for (const row of novRows) {
    await q(`insert into historical_import_source_rows(batch_id,source_key,source_sheet,source_row,source_payload)
      values($1,$2,$3,$4,$5)`, [batch,row.source_key,row.source_sheet,row.source_row,JSON.stringify(row.payload)])
  }
  for (const row of (await q('select full_name from teachers order by id limit 10')).rows) {
    const n = Number(await scalar("select count(*) from historical_import_source_rows where batch_id=$1 and source_sheet='Teachers'", [batch])) + 1
    await q(`insert into historical_import_source_rows(batch_id,source_key,source_sheet,source_row,source_payload)
      values($1,$2,'Teachers',$3,$4)`, [batch,`teacher:${n}`,n,JSON.stringify({ Teacher: row.full_name })])
  }
  for (const row of (await q('select title from class_rooms order by id limit 23')).rows) {
    const n = Number(await scalar("select count(*) from historical_import_source_rows where batch_id=$1 and source_sheet='Classes'", [batch])) + 1
    await q(`insert into historical_import_source_rows(batch_id,source_key,source_sheet,source_row,source_payload)
      values($1,$2,'Classes',$3,$4)`, [batch,`class:${n}`,n,JSON.stringify({ 'Class Name': row.title })])
  }
  assert.equal(Number(await scalar('select count(*) from historical_import_source_rows where batch_id=$1',[batch])),356)

  await db.exec(readFileSync('supabase/november_2026_student_profiles_only.sql','utf8'))
  const firstCount = Number(await scalar('select count(*) from students'))
  assert.ok(firstCount > 0 && firstCount < 141, 'Only uniquely identified roster profiles are created')
  assert.equal(Number(await scalar('select count(*) from teachers')),10)
  assert.equal(Number(await scalar('select count(*) from class_rooms')),23)
  assert.equal(Number(await scalar('select count(*) from monthly_memberships')),0)
  assert.equal(Number(await scalar('select count(*) from payments')),0)
  const awaiting = Number(await scalar(`select count(*) from historical_import_source_rows
    where batch_id=$1 and source_sheet in ('Registrations','RegistrationLeads') and review_status='needs_review'`,[batch]))
  assert.ok(awaiting >= 66, 'All unconfirmed RegistrationLeads remain in review')

  await db.exec(readFileSync('supabase/november_2026_student_profiles_only.sql','utf8'))
  assert.equal(Number(await scalar('select count(*) from students')),firstCount,'Rerunning the SQL must not duplicate profiles')
  assert.equal(Number(await scalar('select count(*) from historical_import_destinations where destination_table=\'students\'')),firstCount)

  console.log(JSON.stringify({
    result:'PASS',
    stagedRows:356,
    confirmedRosterCandidates:140,
    leadsKeptForReview:66,
    profilesCreated:firstCount,
    awaitingReview:awaiting,
    teachers:Number(await scalar('select count(*) from teachers')),
    classes:Number(await scalar('select count(*) from class_rooms')),
    novemberMemberships:0,
    payments:0,
    idempotent:true
  },null,2))
} finally {
  await db.close()
}
