// Browser layout regression test. Synthetic records are confined to this test server.
import { chromium } from 'playwright'
import { parse, compileScript } from '@vue/compiler-sfc'
import ts from 'typescript'
import { readFileSync, mkdirSync } from 'node:fs'
import { createServer } from 'node:http'
import assert from 'node:assert/strict'

const output='.test-artifacts'
mkdirSync(output,{recursive:true})
function compile(path){
  const {descriptor}=parse(readFileSync(path,'utf8'))
  let source=compileScript(descriptor,{id:path,inlineTemplate:true}).content
  source=source.replace(/import\s+\{\s*([^{}]*?)\s*\}\s+from\s+['"]lucide-vue-next['"]/,(_,names)=>names.split(',').map(name=>`const ${name.trim()}={template:'<span></span>'}`).join(';'))
  return ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.ESNext}}).outputText.replaceAll('from "vue"','from "/vue.js"').replaceAll("from 'vue'","from '/vue.js'")
}
const files={'/monthly.js':'app/pages/reports/monthly.vue','/report.js':'app/components/PrintReport.vue','/title.js':'app/components/PageTitle.vue','/notice.js':'app/components/Notice.vue','/material.js':'app/components/MaterialManager.vue','/modal.js':'app/components/ModalBox.vue','/logo.js':'app/components/OfficialLogo.vue','/login.js':'app/pages/login.vue','/header.js':'app/layouts/default.vue'}
const modules=Object.fromEntries(Object.entries(files).map(([url,file])=>[url,compile(file)]))
const html=`<!doctype html><html dir="rtl"><meta charset="utf-8"><link rel="stylesheet" href="/style.css"><body><div id="app"></div><script type="module">
import * as Vue from '/vue.js'; import Monthly from '/monthly.js'; import Report from '/report.js'; import Title from '/title.js'; import Notice from '/notice.js'; import Material from '/material.js'; import Modal from '/modal.js'; import Logo from '/logo.js'; import Login from '/login.js'; import Header from '/header.js';
Object.assign(globalThis,Vue);
Object.assign(globalThis,{definePageMeta:()=>{},useRuntimeConfig:()=>({public:{supabaseUrl:'test',supabaseAnonKey:'test'}}),navigateTo:async()=>{},useAuth:()=>({profile:Vue.ref({role:'admin',full_name:'Administrator'}),canFinance:Vue.ref(true),authError:Vue.ref(''),signIn:async(email,password)=>{window.signInArguments=[email,password]},signOut:async()=>{}})});
Object.assign(globalThis,{useLanguage:()=>({locale:Vue.ref('en'),isDari:Vue.ref(false),changeLanguage:async()=>{},t:(key,values)=>({'app.institution':'REAL STAR EDUCATIONAL SOCIETY','app.name':'Real Star Management System','app.panel':'Management Portal','app.footer':'Real Star Educational Society','language.switch':'Change language','language.english':'English','language.dari':'دری','nav.overview':'Overview','nav.dashboard':'Dashboard','nav.academic':'Academic Management','nav.students':'Students','nav.teachers':'Teachers','nav.classes':'Classes','nav.registration':'Class Registration','nav.financial':'Financial Management','nav.tuition':'Tuition & Payments','nav.settlements':'Teacher Settlements','nav.expenses':'Office Expenses','nav.reports':'Financial Reports','nav.adjustments':'Financial Adjustments','nav.partners':'Partner Accounts','nav.materials':'Learning Materials','nav.chapters':'Chapters','nav.books':'Books','roles.admin':'Administrator','common.close':'Close','common.logout':'Sign out','login.title':'Sign in to your account','login.subtitle':'Use your staff account to access the management portal.','login.email':'Email address','login.password':'Password','login.staffOnly':'Access is restricted to authorized staff.','login.missingConfig':'Missing Supabase configuration','login.showPassword':'Show password','login.hidePassword':'Hide password','login.signIn':'Sign in','login.signingIn':'Signing in…','financialUi.materials.confirmPayment':'تأیید دریافت پول'})[key]||key})});
Object.assign(globalThis,{todayKarachi:()=> '2025-01-31',nowMonth:()=> '2025-01',monthStart:m=>m+'-01',isValidMonth:m=>/^\\d{4}-\\d{2}$/.test(m),timeShort:v=>v?.slice(0,5)||'—',money:v=>'\u2066PKR '+Number(v||0).toLocaleString('en-US')+'\u2069',errText:e=>e.message,useRoute:()=>({path:location.pathname,query:{class:'class-1',teacher:'teacher-1',month:'2025-01'}})});
const rows=Array.from({length:80},(_,i)=>({id:String(i),class_id:'class-1',teacher_id:'teacher-1',class_name:'صنف انگلیسی تاریخی',teacher_name:'استاد آزمایشی',student_name:'شاگرد آزمایشی '+(i+1),student_code:'RS-'+(i+1),base_fee:2000,discount:500,amount_due:1500,paid_total:600,balance_due:900,teacher_discount_share:0,teacher_entitlement:1000,center_entitlement:500}));
Object.assign(globalThis,{allRows:async fn=>fn(),useSupabase:()=>({from:table=>({select:()=>({order:()=>table==='teachers'?[{id:'teacher-1',full_name:'استاد آزمایشی'}]:[{id:'class-1',title:'صنف انگلیسی',start_time:'10:00',end_time:'11:00'}]})}),rpc:async()=>({data:{rows,settlements:[{id:'s-1',class_id:'class-1',teacher_id:'teacher-1',amount:300,paid_on:'2025-01-12',voided_at:null,note:'پرداخت قسمی'}]}})})});
if(location.pathname==='/books'){
 const sale={id:'sale-1',book_id:'book-1',student_id:'student-1',class_id:'class-1',student_name:'شاگرد آزمایشی',student_code:'RS-1',title:'کتاب آزمایشی',quantity:1,unit_price:500,total_price:500,paid_total:100,balance_due:400,payment_status:'partial',sold_on:'2025-01-10',last_paid_on:'2025-01-10'};
 const tables={books:[{id:'book-1',title:'کتاب آزمایشی',owner_name:'مالک بیرونی',opening_stock:5,sale_price:500,active:true,created_at:'2025-01-01'}],book_sale_overview:[sale],students:[{id:'student-1',first_name:'شاگرد',last_name:'آزمایشی',student_code:'RS-1'}],class_rooms:[{id:'class-1',title:'صنف آزمایشی'}]};
 window.paymentCalls=0;
 globalThis.useSupabase=()=>({from:table=>({select:()=>({order:()=>structuredClone(tables[table]||[])})}),rpc:async(name,args)=>{if(name==='pay_material'){window.paymentCalls++;Object.assign(sale,{paid_total:500,balance_due:0,payment_status:'paid',last_paid_on:args.p_date});return {error:null}}throw Error('Unexpected test RPC')}});
}
if(location.pathname==='/login')document.body.classList.add('auth-shell');
const component=location.pathname==='/books'?Material:location.pathname==='/login'?Login:location.pathname==='/header'?Header:Monthly;
const app=Vue.createApp(component,{kind:'book'});Object.assign(app.config.globalProperties,{money:globalThis.money,timeShort:globalThis.timeShort});app.component('PrintReport',Report);app.component('PageTitle',Title);app.component('Notice',Notice);app.component('ModalBox',Modal);app.component('OfficialLogo',Logo);app.component('LanguageSwitcher',{template:'<div></div>'});app.component('NuxtLink',{props:['to'],template:'<a><slot/></a>'});app.mount('#app');
</script></body></html>`
const server=createServer((req,res)=>{
 const url=req.url
 if(['/','/books','/login','/header'].includes(url)){res.setHeader('Content-Type','text/html; charset=utf-8');res.end(html)}
 else if(url==='/branding/real-star-official.png'){res.setHeader('Content-Type','image/png');res.end(readFileSync('public/branding/real-star-official.png'))}
 else if(url==='/style.css'){res.setHeader('Content-Type','text/css');res.end(readFileSync('app/assets/css/main.css','utf8').replace(/^@import.*;\r?\n/,''))}
 else if(url==='/vue.js'){res.setHeader('Content-Type','text/javascript');res.end(readFileSync('node_modules/vue/dist/vue.esm-browser.js'))}
 else if(modules[url]){res.setHeader('Content-Type','text/javascript');res.end(modules[url])}
 else{res.statusCode=404;res.end()}
})
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve))
const browser=await chromium.launch({channel:process.env.TEST_BROWSER_CHANNEL||'chrome',headless:true})
try{
 const page=await browser.newPage({viewport:{width:1400,height:1000}})
 const errors=[];page.on('pageerror',e=>{errors.push(e.message);console.error(e.stack)});page.on('console',message=>{if(message.type()==='error')console.error(message.text())})
 await page.goto(`http://127.0.0.1:${server.address().port}`)
 await page.waitForSelector('.print-report tbody tr').catch(async e=>{console.error(await page.locator('body').innerText());throw e})
 assert.equal(await page.locator('.print-report tbody tr').count(),81)
 assert.equal(errors.length,0,errors.join('\n'))
 await page.emulateMedia({media:'print'})
 const layout=await page.evaluate(()=>({
  report:getComputedStyle(document.querySelector('.print-report')).visibility,
  header:getComputedStyle(document.querySelector('thead')).display,
  controls:getComputedStyle(document.querySelector('.no-print')).display,
  color:getComputedStyle(document.querySelector('.summary-row span')).color,
  rows:[...document.querySelectorAll('tbody tr')].every(r=>getComputedStyle(r).breakInside==='avoid')
 }))
 assert.equal(layout.report,'visible');assert.equal(layout.header,'table-header-group');assert.equal(layout.controls,'none');assert.equal(layout.color,'rgb(0, 0, 0)');assert.equal(layout.rows,true)
 await page.screenshot({path:output+'/monthly-print.png',fullPage:true})
 const pdf=await page.pdf({path:output+'/monthly-print.pdf',preferCSSPageSize:true,printBackground:false})
 const count=(pdf.toString('latin1').match(/\/Type \/Page\b/g)||[]).length
 assert.ok(count>=3,`Expected multi-page report, received ${count}`)
 // Verify the existing receipt remains printable when teleported into a modal.
 await page.evaluate(()=>{document.body.insertAdjacentHTML('beforeend','<div class="modal-overlay"><section class="modal-panel"><div id="fee-receipt">REAL STAR receipt</div></section></div>')})
 const receipt=await page.evaluate(()=>({display:getComputedStyle(document.querySelector('.modal-overlay')).display,visibility:getComputedStyle(document.querySelector('#fee-receipt')).visibility,reportVisibility:getComputedStyle(document.querySelector('.print-report')).visibility}))
 assert.equal(receipt.display,'block');assert.equal(receipt.visibility,'visible');assert.equal(receipt.reportVisibility,'hidden')
 await page.emulateMedia({media:'screen'})
 await page.goto(`http://127.0.0.1:${server.address().port}/books`)
 const checkbox=page.locator('.paid-label input')
 await checkbox.waitFor();assert.equal(await checkbox.isChecked(),false)
 assert.equal(await page.locator('.print-report thead th').count(),await page.locator('.print-report tbody td').count(),'Material report headers must align with cells')
 await checkbox.click()
 await page.getByRole('dialog').waitFor()
 assert.equal(await checkbox.isChecked(),false,'Opening confirmation must not mark a partial sale paid')
 await page.getByRole('button',{name:'تأیید دریافت پول'}).click()
 await page.getByRole('dialog').waitFor({state:'hidden'})
 assert.equal(await checkbox.isChecked(),true);assert.equal(await checkbox.isDisabled(),true)
 assert.equal(await page.evaluate(()=>window.paymentCalls),1)
 await page.emulateMedia({media:'print'})
 assert.equal(await page.locator('.print-report').evaluate(e=>getComputedStyle(e).visibility),'visible')
 await page.screenshot({path:output+'/books-print.png',fullPage:true})
 assert.equal(errors.length,0,errors.join('\n'))
 console.log(`PASS: actual monthly Vue report renders 80 students; print controls hidden, black text, repeating headers, protected rows, ${count} PDF pages; existing receipt remains visible.`)
 console.log('PASS: actual Books component confirms payment before checking, records one RPC, disables the paid checkbox, and aligns printed columns.')
 await page.emulateMedia({media:'screen'})
 await page.goto(`http://127.0.0.1:${server.address().port}/login`)
 await page.locator('.official-logo--login').waitFor()
 await page.getByLabel('Email address').fill('staff@example.com')
 await page.locator('input[autocomplete="current-password"]').fill('test-only-password')
 await page.getByRole('button',{name:'Sign in'}).click()
 assert.deepEqual(await page.evaluate(()=>window.signInArguments),['staff@example.com','test-only-password'])
 for(const width of [1440,375,320]){
  await page.setViewportSize({width,height:1000})
  const layout=await page.locator('.official-logo--login').evaluate(e=>({width:e.clientWidth,height:e.clientHeight,natural:e.naturalWidth,fit:getComputedStyle(e).objectFit,overflow:document.documentElement.scrollWidth>innerWidth}))
  assert.equal(layout.width,layout.height);assert.equal(layout.natural,1024);assert.equal(layout.fit,'contain');assert.equal(layout.overflow,false)
  await page.screenshot({path:output+'/login-'+width+'.png',fullPage:true})
 }
 await page.goto(`http://127.0.0.1:${server.address().port}/header`)
 await page.locator('.official-logo--header').waitFor()
 for(const width of [1440,375,320]){
  await page.setViewportSize({width,height:1000})
  assert.equal(await page.locator('.official-logo--header').isVisible(),true)
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false)
  await page.screenshot({path:output+'/header-'+width+'.png',fullPage:true})
 }
 assert.equal(errors.length,0,errors.join('\n'))
 console.log('PASS: exact official logo renders proportionally on desktop and 375/320px mobile login/header; sign-in still invokes existing authentication.')
}finally{await browser.close();server.close()}
