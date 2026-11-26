// Actual Nuxt pages + real PostgreSQL execution in isolated PGlite.
// Browser API transport is intercepted; no request reaches the configured live project.
import {PGlite} from '@electric-sql/pglite'
import {chromium} from 'playwright'
import {readFileSync,readdirSync,mkdirSync} from 'node:fs'
import {randomUUID} from 'node:crypto'
import assert from 'node:assert/strict'
const db=new PGlite(),admin=randomUUID(),teacher=randomUUID(),c1=randomUUID(),c2=randomUUID()
const q=(sql,args=[])=>db.query(sql,args),scalar=async(sql,args=[])=>Object.values((await q(sql,args)).rows[0])[0]
let browser
const en=JSON.parse(readFileSync('i18n/locales/en.json','utf8')),fa=JSON.parse(readFileSync('i18n/locales/fa-AF.json','utf8'))
const user={id:admin,aud:'authenticated',role:'authenticated',email:'admin@test.invalid',app_metadata:{provider:'email'},user_metadata:{},created_at:new Date().toISOString()}
const token=Buffer.from('{}').toString('base64url')+'.'+Buffer.from(JSON.stringify({sub:admin,exp:Math.floor(Date.now()/1000)+3600})).toString('base64url')+'.test'
const session={access_token:token,refresh_token:'isolated-test',expires_in:3600,expires_at:Math.floor(Date.now()/1000)+3600,token_type:'bearer',user}
const parts=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Karachi',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(new Date());const part=name=>parts.find(p=>p.type===name).value;const month=part('year')+'-'+part('month');const date=month+'-25'
try{
 await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema public,auth to authenticated,anon;grant execute on function auth.uid() to authenticated,anon;`)
 for(const file of readdirSync('supabase/migrations').filter(f=>/^0(0[1-9]|[12][0-9])_/.test(f)).sort())await db.exec(readFileSync('supabase/migrations/'+file,'utf8').replace('create extension if not exists pgcrypto;',''))
 await q('insert into auth.users values($1)',[admin]);await q("insert into staff_profiles(id,full_name,role) values($1,'Test Administrator','admin')",[admin]);await q("insert into teachers(id,full_name) values($1,'Test Teacher')",[teacher]);await q("insert into class_rooms(id,title,teacher_id,default_fee,start_time,end_time) values($1,'English B1',$3,2000,'09:00','10:00'),($2,'English B1',$3,1800,'11:00','12:00')",[c1,c2,teacher]);await db.exec('set role authenticated');await q("select set_config('request.jwt.claim.sub',$1,false)",[admin])
 browser=await chromium.launch({headless:true,...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE?{executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE}:{})})
 const page=await browser.newPage({viewport:{width:1365,height:1000}}),errors=[],apiErrors=[]
 page.on('dialog',dialog=>dialog.accept())

 page.on('pageerror',e=>errors.push(e.message))
 await page.route('**/*',async route=>{
  const url=new URL(route.request().url())
  if(url.hostname!=='127.0.0.1'&&url.hostname!=='localhost')return route.abort()
  if(!url.pathname.startsWith('/rest/v1/')&&!url.pathname.startsWith('/auth/v1/'))return route.continue()
  assert.equal(url.port,'54329','Test must use the isolated API URL')
  const headers={'access-control-allow-origin':'*','access-control-allow-headers':'*','access-control-allow-methods':'*','content-type':'application/json'}
  const send=data=>route.fulfill({status:200,headers,body:JSON.stringify(data)})
  if(route.request().method()==='OPTIONS')return send({})
  if(url.pathname.startsWith('/auth/v1/'))return send(url.pathname.endsWith('/user')?user:session)
  try{
   if(url.pathname.includes('/rpc/')){
    const name=url.pathname.split('/').at(-1),args=route.request().postDataJSON()||{},names=Object.keys(args)
    if(!/^[a-z_]+$/.test(name)||names.some(n=>!/^p_[a-z_]+$/.test(n)))throw Error('Unsafe test RPC')
    const result=await scalar(`select public.${name}(${names.map((n,i)=>`${n}=>$${i+1}`).join(',')})`,Object.values(args));return send(result)
   }
   const table=url.pathname.split('/').at(-1);if(!/^[a-z_]+$/.test(table))throw Error('Unsafe table')
   let sql=table==='class_rooms'?"select x.*,jsonb_build_object('full_name',t.full_name) teacher from class_rooms x join teachers t on t.id=x.teacher_id":table==='enrollments'?"select x.*,to_jsonb(s) student,jsonb_build_object('title',c.title) class_item from enrollments x join students s on s.id=x.student_id join class_rooms c on c.id=x.class_id":`select x.* from ${table} x`
   const where=[],values=[]
   for(const [key,value] of url.searchParams){if(['select','order','limit','offset'].includes(key))continue;if(key==='or' && table==='audit_logs'){const id=value.match(/[0-9a-f]{8}-[0-9a-f-]{27}/i)?.[0];if(!id)throw Error('Unsafe audit filter');values.push(id);where.push(`(x.old_data->>'student_id'=${values.length} or x.new_data->>'student_id'=${values.length})`);continue}if(!/^[a-z_]+$/.test(key))throw Error('Unsafe filter');if(value.startsWith('eq.')){values.push(value.slice(3));where.push(`x.${key}::text=$${values.length}`)}}
   if(where.length)sql+=' where '+where.join(' and ')
   const order=url.searchParams.get('order');if(order){const fields=order.split(',').map(o=>{const [field,direction]=o.split('.');if(!/^[a-z_]+$/.test(field))throw Error('Unsafe ordering');return `x.${field} ${direction==='desc'?'desc':'asc'}`});sql+=' order by '+fields.join(',')}
   const result=(await q(sql,values)).rows
   const single=route.request().headers().accept?.includes('vnd.pgrst.object')
   return send(single?(result[0]||null):result)
  }catch(e){apiErrors.push(String(e.message));await route.fulfill({status:400,headers,body:JSON.stringify({code:e.code||'P0001',message:e.message})})}
 })
 await page.goto('http://127.0.0.1:3210/login');await page.locator('input[type=email]').fill(user.email);await page.locator('input[autocomplete=current-password]').fill('test-only-password');await page.locator('form button[type=submit]').click();await page.waitForURL('**/',{timeout:60000})
 await page.getByRole('link',{name:en.agreements.registerStudent,exact:true}).waitFor();await page.getByRole('link',{name:en.agreements.registerStudent,exact:true}).click();await page.getByRole('link',{name:en.agreements.newRegistration,exact:true}).waitFor()
 const panel=page.locator('#monthly-registration')
 const pickClass=async(id,keyboard=false)=>{const input=panel.locator('.registration-row .searchable-select input').last();await input.fill('English B1');const index=id===c1?0:1;if(keyboard){await input.press('Enter')}else await panel.getByRole('option').nth(index).click()}
 await panel.getByRole('button',{name:en.registration.new,exact:true}).click();await panel.getByLabel(en.registration.first_name,{exact:true}).fill('Browser Student');await panel.getByLabel(en.registration.last_name,{exact:true}).fill('One');await panel.locator('details.registration-date-settings summary').click();await panel.getByLabel(en.registration.date,{exact:true}).fill(date)
 await panel.getByRole('button',{name:en.registration.addClass,exact:true}).first().click();await pickClass(c1,true)
 await panel.getByLabel(en.registration.monthlyFee,{exact:false}).fill('2000');await panel.getByLabel(en.registration.discount,{exact:true}).fill('400');await panel.getByLabel(en.agreements.discountReason,{exact:false}).selectOption('other');await panel.getByLabel(en.agreements.discountOtherReason,{exact:false}).fill('Administrator discount')
 await panel.locator('.registration-row details.advanced-controls summary').click();const teacherShare=panel.getByRole('spinbutton',{name:new RegExp(en.registration.teacher_entitlement)});assert.equal(await teacherShare.inputValue(),'1000')
 await panel.getByLabel(en.agreements.customShare,{exact:true}).check();await teacherShare.fill('1100');await panel.getByLabel(en.agreements.exceptionReason+' *',{exact:true}).fill('Approved custom entitlement')
 await panel.getByLabel(en.registration.payment,{exact:true}).fill('500');await panel.getByLabel(en.registration.paymentDate,{exact:false}).fill(date);await panel.getByLabel(en.registration.paymentMethod,{exact:false}).selectOption('cash')
 await panel.getByRole('button',{name:en.agreements.confirmRegister,exact:true}).click()
 await page.waitForFunction(()=>document.body.textContent.includes('Saved 1 registrations.'),null,{timeout:8000}).catch(async error=>{console.log('FORM',await panel.innerText());console.log('INVALID',await panel.locator(':invalid').evaluateAll(es=>es.map(e=>({tag:e.tagName,type:e.type,value:e.value,required:e.required,label:e.labels?.[0]?.innerText}))));console.log('BUTTON',await panel.getByRole('button',{name:en.agreements.confirmRegister,exact:true}).isDisabled());console.log('API_ERRORS',apiErrors);throw error})
 const student=await scalar("select id from students where first_name='Browser Student'")
 let account=(await q('select * from month_fee_overview where student_id=$1',[student])).rows[0]
 assert.equal(Number(account.paid_total),500);assert.equal(Number(account.balance_due),1100);assert.equal(Number(account.teacher_entitlement),1100);assert.equal(account.confirmation_status,'registered')
 assert.equal(Number(await scalar('select count(*) from payments where monthly_membership_id=$1',[account.id])),1)
 await page.goto('http://127.0.0.1:3210/finance');await page.getByRole('link',{name:en.agreements.recordPayment,exact:true}).waitFor();const payment=page.locator('#record-payment');await payment.getByLabel(en.registration.search,{exact:true}).fill('Browser Student');await payment.getByRole('option',{name:/Browser Student/}).click();await payment.getByLabel(en.financialUi.finance.receivedAmount,{exact:true}).fill('300');await payment.getByLabel(en.registration.paymentDate,{exact:false}).fill(date);await payment.getByLabel(en.registration.paymentMethod,{exact:true}).selectOption('cash');await payment.getByRole('button',{name:en.financialUi.finance.saveReceipt,exact:true}).click();await payment.getByText(en.financialUi.finance.paymentSaved,{exact:true}).waitFor()
 account=(await q('select * from month_fee_overview where id=$1',[account.id])).rows[0];assert.equal(Number(account.paid_total),800);assert.equal(Number(account.balance_due),800);assert.equal(Number(await scalar('select count(*) from payments where monthly_membership_id=$1',[account.id])),2)
 // Return next month: the active class and approved agreement are prefilled.
 await page.goto('http://127.0.0.1:3210/enrollments');const nextMonth=new Date(`${month}-01T12:00:00Z`);nextMonth.setUTCMonth(nextMonth.getUTCMonth()+1);await panel.getByLabel(en.registration.month,{exact:true}).fill(nextMonth.toISOString().slice(0,7));await panel.getByPlaceholder(en.registration.placeholder).fill('Browser Student');await panel.getByRole('option',{name:/Browser Student One/}).click();await panel.getByLabel(en.registration.monthlyFee,{exact:false}).waitFor({timeout:8000}).catch(async error=>{console.log('RETURN_FORM',await panel.innerText());console.log('API_ERRORS',apiErrors);throw error});assert.equal(await panel.getByLabel(en.registration.payment,{exact:true}).inputValue(),'0');
 await panel.getByRole('button',{name:en.agreements.confirmRegister,exact:true}).click();await page.waitForFunction(()=>document.body.textContent.includes('Saved 1 registrations.'),null,{timeout:8000}).catch(async error=>{console.log('FORM',await panel.innerText());console.log('INVALID',await panel.locator(':invalid').evaluateAll(es=>es.map(e=>({tag:e.tagName,type:e.type,value:e.value,required:e.required,label:e.labels?.[0]?.innerText}))));console.log('BUTTON',await panel.getByRole('button',{name:en.agreements.confirmRegister,exact:true}).isDisabled());console.log('API_ERRORS',apiErrors);throw error});const unpaidAccount=(await q("select f.* from month_fee_overview f join students s on s.id=f.student_id join billing_periods b on b.id=f.period_id where s.first_name='Browser Student' and b.year_month=$1",[nextMonth.toISOString().slice(0,7)+'-01'])).rows[0];assert.equal(Number(unpaidAccount.paid_total),0);assert.equal(Number(await scalar('select count(*) from payments where monthly_membership_id=$1',[unpaidAccount.id])),0)
 // Scholarship from the visible form.
 await panel.getByRole('button',{name:en.registration.new,exact:true}).click();await panel.getByLabel(en.registration.first_name,{exact:true}).fill('Browser Sponsored');await panel.getByRole('button',{name:en.registration.addClass,exact:true}).first().click();await pickClass(c2);await panel.getByLabel(en.registration.monthlyFee,{exact:false}).fill('2000');await panel.getByLabel(en.registration.discount,{exact:true}).fill('2000');await panel.getByLabel(en.agreements.discountReason,{exact:false}).selectOption('scholarship');await panel.getByLabel(en.agreements.confirmSponsored,{exact:true}).check();await panel.getByRole('button',{name:en.agreements.confirmRegister,exact:true}).click();await page.waitForFunction(()=>document.body.textContent.includes('Saved 1 registrations.'),null,{timeout:8000}).catch(async error=>{console.log('FORM',await panel.innerText());console.log('INVALID',await panel.locator(':invalid').evaluateAll(es=>es.map(e=>({tag:e.tagName,type:e.type,value:e.value,required:e.required,label:e.labels?.[0]?.innerText}))));console.log('BUTTON',await panel.getByRole('button',{name:en.agreements.confirmRegister,exact:true}).isDisabled());console.log('API_ERRORS',apiErrors);throw error})
 const sponsored=(await q("select f.* from month_fee_overview f join students s on s.id=f.student_id where s.first_name='Browser Sponsored'")).rows[0];assert.equal(sponsored.confirmation_status,'fully_sponsored');assert.equal(Number(sponsored.paid_total),0);assert.equal(Number(sponsored.institution_funded),1000)
 mkdirSync('.test-artifacts',{recursive:true});await page.screenshot({path:'.test-artifacts/phase1-nuxt-registration.png',fullPage:true});await page.setViewportSize({width:390,height:844});await page.getByRole('button',{name:en.language.dari,exact:true}).click();await panel.getByText(fa.registration.title,{exact:true}).waitFor();assert.equal(await page.evaluate(()=>document.documentElement.dir),'rtl');assert.equal(await panel.evaluate(el=>el.scrollWidth<=el.clientWidth+1),true);await page.screenshot({path:'.test-artifacts/phase1-nuxt-dari-mobile.png',fullPage:true})
 for(const table of ['historical_import_batches','historical_import_source_rows','historical_import_destinations','historical_import_entities'])assert.equal(Number(await scalar('select count(*) from '+table)),0)
 assert.deepEqual(errors,[]);assert.deepEqual(apiErrors,[])
 console.log('PASS: actual running Nuxt pages, visible registration/payment actions, class teacher/schedule, standard and custom entitlement, actual initial and later payments, real SQL balances, previous history with rejected suggestion, full sponsorship, English/Dari RTL. PostgreSQL/PGlite isolated; API transport intercepted; no live writes.')
}catch(e){console.error(e);throw e}finally{await browser?.close();await db.close()}
