import { chromium } from 'playwright'
import { parse, compileScript } from '@vue/compiler-sfc'
import ts from 'typescript'
import { readFileSync, mkdirSync } from 'node:fs'
import { createServer } from 'node:http'
import assert from 'node:assert/strict'

const source = readFileSync('app/components/MonthlyRegistration.vue', 'utf8')
const { descriptor } = parse(source)
const js = ts.transpileModule(compileScript(descriptor, {
  id: 'registration',
  inlineTemplate: true
}).content, {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext }
}).outputText.replaceAll('from "vue"', 'from "/vue.js"').replaceAll("from 'vue'", "from '/vue.js'")
const en = JSON.parse(readFileSync('i18n/locales/en.json'))
const fa = JSON.parse(readFileSync('i18n/locales/fa-AF.json'))
const html = `<html><meta charset="utf-8"><link rel="stylesheet" href="/style.css"><style>${descriptor.styles[0].content}</style><div id="app"></div><script type="module">
import * as Vue from '/vue.js';import Panel from '/panel.js';Object.assign(globalThis,Vue);
const locale=Vue.ref(location.hash==='#fa'?'fa-AF':'en'),labels=${JSON.stringify({ en, 'fa-AF': fa })};document.documentElement.dir=locale.value==='en'?'ltr':'rtl';
const t=(key,args={})=>{let value=key.split('.').reduce((v,k)=>v?.[k],labels[locale.value])||key;for(const [k,v] of Object.entries(args))value=value.replace('{'+k+'}',v);return value};
const student={id:'s1',first_name:'Ahmad',last_name:'Test',student_code:'RS-001',guardian_name:'Father',last_month:'2026-08-01',last_classes:'English, Computer'};
const rooms=[{id:'c1',title:'English',default_fee:2000,teacher:{full_name:'Teacher'}},{id:'c2',title:'Computer',default_fee:1000,teacher:{full_name:'Teacher'}}];
window.calls=[];const db={from:()=>({select:()=>({eq:()=>({order:()=>rooms,maybeSingle:async()=>({data:{status:'open'}})})})}),rpc:async(name,args)=>{window.calls.push({name,args});if(name==='registration_student_search')return {data:[student]};if(name==='registration_previous')return {data:rooms.map((c,i)=>({id:'m'+i,class_id:c.id,class_name:c.title,year_month:'2026-08-01',teacher_name:'Teacher',original_fee:c.default_fee,base_fee:c.default_fee,proration_rule:'full_month',discount:100,amount_due:c.default_fee-100,teacher_entitlement:c.default_fee/2,center_entitlement:c.default_fee/2-100,paid_total:500,balance_due:c.default_fee-600}))};return {data:{student_code:'RS-001',membership_count:args.p_payload.classes.length}}}};
Object.assign(globalThis,{useSupabase:()=>db,useAuth:()=>({canEducation:Vue.ref(true)}),useLanguage:()=>({t,locale}),useRequestKey:()=>({reset(){},forPayload:()=> 'request'}),nowMonth:()=> '2026-11',todayKarachi:()=> '2026-11-20',monthStart:m=>m+'-01',isValidMonth:m=>/^\\d{4}-\\d{2}$/.test(m),allRows:async f=>f(),errText:e=>e.message,money:n=>'PKR '+Number(n||0).toFixed(2)});
const app=Vue.createApp(Panel);Object.assign(app.config.globalProperties,{money:globalThis.money,monthStart:globalThis.monthStart});app.component('Notice',{props:['message','kind'],template:'<p role="status">{{message}}</p>'});app.mount('#app');</script></html>`

const server = createServer((req, res) => {
  const files = { '/vue.js': 'node_modules/vue/dist/vue.esm-browser.js', '/style.css': 'app/assets/css/main.css' }
  if (req.url === '/panel.js') {
    res.setHeader('Content-Type', 'text/javascript')
    res.end(js)
  } else if (files[req.url]) {
    res.setHeader('Content-Type', req.url.endsWith('.js') ? 'text/javascript' : 'text/css')
    res.end(readFileSync(files[req.url]))
  } else {
    res.setHeader('Content-Type', 'text/html;charset=utf-8')
    res.end(html)
  }
})

await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
let browser
try {
  browser = await chromium.launch({
    headless: true,
    ...(process.env.PLAYWRIGHT_CHANNEL ? { channel: process.env.PLAYWRIGHT_CHANNEL } : {})
  })
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } })
  const errors = []
  page.on('pageerror', cause => {
    errors.push(cause.message)
    console.error(cause.message)
  })
  const url = `http://127.0.0.1:${server.address().port}`
  await page.goto(url)
  await page.getByPlaceholder('Enter student first and last name...').fill('Ahmad')
  await page.getByRole('button', { name: /Ahmad Test/ }).click()
  await page.getByRole('button', { name: 'Continue this class' }).first().waitFor()
  assert.equal(await page.getByRole('button', { name: 'Continue this class' }).count(), 2)
  await page.getByRole('button', { name: 'Continue this class' }).first().click()
  await page.getByRole('button', { name: 'Confirm Monthly Registration', exact: true }).click()
  await page.getByText('Saved 1 registrations. Student ID: RS-001.').waitFor()
  let calls = await page.evaluate(() => window.calls)
  assert.equal(calls.at(-1).args.p_payload.student_id, 's1')
  assert.equal(calls.at(-1).args.p_payload.classes.length, 1)

  await page.getByRole('button', { name: 'New Student', exact: true }).click()
  await page.getByRole('button', { name: 'Add Class', exact: true }).click()
  await page.getByLabel('First Name', { exact: true }).fill('New Person')
  await page.getByLabel('Class', { exact: true }).selectOption('c2')
  await page.getByLabel('Initial Payment (PKR)', { exact: true }).fill('100')
  await page.getByLabel('Actual payment date', { exact: true }).fill('2026-11-20')
  await page.getByLabel(/Actual payment method/).selectOption('bank')
  await page.getByRole('button', { name: 'Save Student & Register' }).click()
  calls = await page.evaluate(() => window.calls)
  assert.equal(calls.at(-1).args.p_payload.student_id, null)
  assert.equal(calls.at(-1).args.p_payload.classes[0].payment, 100)
  assert.equal(calls.at(-1).args.p_payload.classes[0].paid_on, '2026-11-20')
  assert.equal(calls.at(-1).args.p_payload.classes[0].payment_method, 'bank')

  await page.getByRole('button', { name: 'Add Class', exact: true }).click()
  await page.getByLabel('Class', { exact: true }).selectOption('c2')
  await page.getByLabel('Registration Date', { exact: true }).fill('2026-11-21')
  await page.getByText(/half the original monthly class fee/).waitFor()
  assert.ok(await page.getByText('PKR 500.00', { exact: true }).count() >= 1)
  assert.equal(await page.getByRole('button', { name: 'Save Student & Register' }).isDisabled(), false)
  mkdirSync('.test-artifacts', { recursive: true })
  await page.screenshot({ path: '.test-artifacts/dashboard-registration-prorated-en.png', fullPage: true })

  await page.setViewportSize({ width: 390, height: 844 })
  await page.goto(url + '/#fa')
  await page.reload()
  await page.getByText('ثبت‌نام ماهانه شاگردان', { exact: true }).waitFor()
  assert.equal(await page.evaluate(() => document.documentElement.dir), 'rtl')
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true)
  await page.screenshot({ path: '.test-artifacts/dashboard-registration-prorated-fa-mobile.png', fullPage: true })
  assert.deepEqual(errors, [])
  console.log('PASS: returning search/history, searchable classes, actual receipt fields, full/half-month tuition preview, new/returning payloads, English, Dari RTL and mobile overflow. Synthetic API fixtures only.')
} finally {
  await browser?.close()
  server.close()
}
