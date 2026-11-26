import { chromium } from 'playwright'
import { parse, compileScript } from '@vue/compiler-sfc'
import ts from 'typescript'
import { readFileSync } from 'node:fs'
import { createServer } from 'node:http'
import assert from 'node:assert/strict'

const descriptor = parse(readFileSync('app/components/SearchableSelect.vue', 'utf8')).descriptor
const compile = source => ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext } }).outputText
const component = compile(compileScript(descriptor, { id: 'select', inlineTemplate: true }).content)
  .replaceAll('"vue"', '"/vue.js"').replaceAll("'vue'", "'/vue.js'")
  .replaceAll("'~/utils/searchText'", "'/search.js'")
const labels = Object.fromEntries(['en', 'fa-AF'].map(locale => [locale, JSON.parse(readFileSync(`i18n/locales/${locale}.json`, 'utf8'))]))
const templateMarkup = `<form @submit.prevent="submit"><label>Student<Select v-model="chosen" :options="options" label-key="name" selected-suffix-key="code" :search-keys="['code','guardian']" :min-chars="2" required /></label><output>{{chosen}}</output><button>Save</button></form>`
const html = `<meta charset="utf-8"><style>${descriptor.styles[0].content}</style><div id="app"></div><script type="module">
import * as Vue from '/vue.js';import Select from '/component.js';Object.assign(globalThis,Vue);
const lang=location.hash==='#fa'?'fa-AF':'en';document.documentElement.dir=lang==='en'?'ltr':'rtl';
const labels=JSON.parse(${JSON.stringify(JSON.stringify(labels))});globalThis.useLanguage=()=>({t:(key,args={})=>key.split('.').reduce((v,k)=>v[k],labels[lang]).replace('{count}',args.count)});
window.submits=0;const app=Vue.createApp({components:{Select},setup(){const chosen=Vue.ref('s1');return {chosen,options:[{id:'s1',name:'Noorzia Atayee',code:'RS-56',guardian:'Ahmad Ali'},{id:'s2',name:'علی کریمی',code:'RS-57',guardian:'Other'},{id:'s3',name:'Noria Atayee',code:'RS-58',guardian:'Sara'}],submit(){window.submits++}}},template:${JSON.stringify(templateMarkup)}});app.mount('#app');</script>`
const server = createServer((req, res) => {
  const path = new URL(req.url, 'http://localhost').pathname
  const scripts = { '/vue.js': () => readFileSync('node_modules/vue/dist/vue.esm-browser.js'), '/component.js': () => component, '/search.js': () => compile(readFileSync('app/utils/searchText.ts', 'utf8')) }
  res.setHeader('Content-Type', scripts[path] ? 'text/javascript' : 'text/html;charset=utf-8')
  res.end(scripts[path]?.() ?? html)
})
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
let browser
try {
  browser = await chromium.launch({ headless: true, channel: 'chromium', ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE } : {}) })
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } }); page.setDefaultTimeout(5000)
  const errors = []; page.on('pageerror', e => errors.push(e.message))
  const base = `http://127.0.0.1:${server.address().port}`
  await page.goto(base)
  const input = page.getByRole('combobox')
  assert.equal(await input.inputValue(), 'Noorzia Atayee · RS-56')
  await input.fill('n'); assert.equal(await page.getByRole('option').count(), 0)
  await input.fill('no'); assert.equal(await page.getByRole('option').count(), 2)
  await input.fill('noo'); assert.equal(await page.getByRole('option').count(), 1)
  await input.fill('unmatched'); await page.locator('form').evaluate(form => form.requestSubmit())
  assert.equal(await page.locator('output').textContent(), ''); assert.equal(await page.evaluate(() => window.submits), 0)
  await input.fill('noo'); await input.press('Enter'); assert.equal(await page.locator('output').textContent(), 's1')
  await input.fill('علی'); await page.getByRole('option', { name: 'علی کریمی' }).click(); assert.equal(await page.locator('output').textContent(), 's2')
  await input.fill('RS-58'); await page.getByRole('option', { name: /Noria/ }).click(); assert.equal(await page.locator('output').textContent(), 's3')
  await input.fill('Ahmad Ali'); await page.getByRole('option', { name: /Noorzia/ }).click(); assert.equal(await page.locator('output').textContent(), 's1')
  await page.getByRole('button', { name: 'Save' }).click(); assert.equal(await page.evaluate(() => window.submits), 1)
  await input.fill(''); assert.equal(await page.locator('output').textContent(), '')
  const mobile = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true }); mobile.setDefaultTimeout(5000)
  await mobile.goto(base); const mobileInput = mobile.getByRole('combobox'); await mobileInput.fill('no')
  await mobile.getByRole('option').first().tap(); assert.equal(await mobile.locator('output').textContent(), 's1')
  assert.equal(await mobile.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true)
  const rtl = await browser.newPage({ viewport: { width: 390, height: 844 } }); rtl.setDefaultTimeout(5000)
  await rtl.goto(`${base}/#fa`); const faInput = rtl.getByRole('combobox'); await faInput.fill('zz')
  await rtl.getByText(labels['fa-AF'].searchSelect.empty).waitFor()
  assert.equal(await rtl.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true)
  assert.deepEqual(errors, [])
  console.log('PASS: desktop and mobile; two-character suggestions/narrowing; English, Dari, code and guardian searches; keyboard, mouse and touch selection; clearing and invalid-submit protection; en/fa layouts.')
} finally { await browser?.close(); server.close() }
