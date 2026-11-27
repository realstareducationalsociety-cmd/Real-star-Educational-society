import { chromium } from 'playwright'
import { readFileSync } from 'node:fs'
import assert from 'node:assert/strict'

const envText = readFileSync('.env','utf8')
const supabaseUrl = envText.match(/^NUXT_PUBLIC_SUPABASE_URL\s*=\s*["']?([^\r\n"']+)/m)?.[1]?.trim()
assert.ok(supabaseUrl, 'Local Supabase URL must be configured for Nuxt')
const projectRef = new URL(supabaseUrl).hostname.split('.')[0]
const userId = '11111111-1111-4111-8111-111111111111'
const studentId = '22222222-2222-4222-8222-222222222222'
const student = { id:studentId,student_code:'RS-BROWSER',first_name:'Browser',last_name:'Student',guardian_name:'Guardian',phone:'03001234567',guardian_phone:'03007654321',address:null,active:true,registered_on:'2025-01-01',notes:null,updated_at:'2025-01-01T00:00:00Z',created_at:'2025-01-01T00:00:00Z',renewal_reminder_recipient:'guardian' }
const registration = { id:'33333333-3333-4333-8333-333333333333',registration_active:true,registered_on:'2026-11-01',registration_status:'registered',payment_status:'unpaid',confirmation_status:'registered',base_fee:1000,discount:0,period:{year_month:'2026-11-01'},enrollment:{id:'44444444-4444-4444-8444-444444444444',student_id:studentId,class_id:'55555555-5555-4555-8555-555555555555',class_item:{title:'History Class A'}} }
const session = { access_token:'local-browser-test-token',refresh_token:'local-browser-test-refresh',token_type:'bearer',expires_in:3600,expires_at:Math.floor(Date.now()/1000)+3600,user:{id:userId,aud:'authenticated',role:'authenticated',email:'admin@example.invalid',app_metadata:{provider:'email',providers:['email']},user_metadata:{},created_at:'2025-01-01T00:00:00Z'} }
const browser = await chromium.launch({headless:true,executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe'})
try {
  const context = await browser.newContext()
  await context.addInitScript(({storageKey,authSession})=>localStorage.setItem(storageKey,JSON.stringify(authSession)),{storageKey:`sb-${projectRef}-auth-token`,authSession:session})
  await context.route('**/auth/v1/user**', route => route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(session.user)}))
  await context.route('**/rest/v1/**', async route => {
    const url = new URL(route.request().url())
    const path = url.pathname
    let body = []
    if (path.endsWith('/staff_profiles')) body = [{id:userId,full_name:'Browser Admin',role:'admin',is_active:true}]
    else if (path.endsWith('/students')) body = [student]
    else if (path.endsWith('/enrollments')) body = [
      {id:'44444444-4444-4444-8444-444444444444',student_id:studentId,class_id:'55555555-5555-4555-8555-555555555555',enrolled_on:'2025-08-01',active:true,class_item:{title:'History Class A',start_time:'08:00:00',end_time:'09:00:00',teacher:{full_name:'Teacher A'}}},
      {id:'66666666-6666-4666-8666-666666666666',student_id:studentId,class_id:'77777777-7777-4777-8777-777777777777',enrolled_on:'2025-09-01',active:true,class_item:{title:'History Class B',start_time:'09:00:00',end_time:'10:00:00',teacher:{full_name:'Teacher B'}}}
    ]
    else if (path.endsWith('/rpc/monthly_registration_list')) body = [registration]
    await route.fulfill({status:200,contentType:'application/json',headers:{'content-range':'0-49/1'},body:JSON.stringify(body)})
  })
  const page = await context.newPage()
  const pageErrors=[]
  page.on('pageerror', error => pageErrors.push(error.message))
  await page.goto('http://127.0.0.1:3001/students', {waitUntil:'networkidle'})
  await page.getByText('RS-BROWSER').waitFor()
  await page.getByRole('button',{name:'Open profile'}).click()
  await page.getByRole('dialog').getByText('History Class A').first().waitFor()
  await page.getByRole('dialog').getByText('History Class B').first().waitFor()
  await page.getByRole('dialog').getByRole('button',{name:'Close'}).click()
  await page.getByRole('button',{name:'Class history'}).click()
  await page.getByRole('dialog').getByText('History Class A').first().waitFor()
  await page.getByRole('dialog').getByText('History Class B').first().waitFor()
  assert.deepEqual(pageErrors,[],'Profile and class-history actions must not throw browser errors')
  console.log(JSON.stringify({result:'PASS',profile_opens:true,history_opens:true,multi_class_links_visible:true,browser_errors:pageErrors.length,mocked_supabase:true},null,2))
} finally { await browser.close() }
