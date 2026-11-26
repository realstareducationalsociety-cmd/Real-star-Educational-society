import assert from 'node:assert/strict'
import { readdir, readFile } from 'node:fs/promises'
import path from 'node:path'

const appRoot = path.resolve('app')
const migrationRoot = path.resolve('supabase/migrations')
const appFiles = []

async function visit(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name)
    if (entry.isDirectory()) await visit(file)
    else if (/\.(vue|ts|js)$/.test(entry.name)) appFiles.push(file)
  }
}

await visit(appRoot)
const appSources = await Promise.all(appFiles.map(file => readFile(file, 'utf8')))
const migrationFiles = (await readdir(migrationRoot))
  .filter(file => file.endsWith('.sql'))
  .sort()
const migrationSources = await Promise.all(
  migrationFiles.map(file => readFile(path.join(migrationRoot, file), 'utf8'))
)
const schema = migrationSources.join('\n')
const rpcNames = new Set()
const databaseObjects = new Set()

for (const source of appSources) {
  for (const match of source.matchAll(/\.rpc\s*\(\s*['"]([^'"]+)['"]/g)) rpcNames.add(match[1])
  for (const match of source.matchAll(/\.from\s*\(\s*['"]([^'"]+)['"]/g)) databaseObjects.add(match[1])
  if (source.includes('db.from(`${props.kind}s`)')) {
    databaseObjects.add('books')
    databaseObjects.add('chapters')
  }
}

for (const name of rpcNames) {
  const definition = new RegExp(
    `create\\s+(?:or\\s+replace\\s+)?function\\s+public\\.${name}\\s*\\(`,
    'i'
  )
  assert.match(schema, definition, `Missing local SQL function for frontend RPC ${name}`)
}

const apiMigration = migrationSources.find(source => source.includes('api text[]:=array['))
assert.ok(apiMigration, 'The final migration must define the supported RPC allowlist')
const allowlist = apiMigration.match(/api text\[\]:=array\[([\s\S]*?)\];/)?.[1] || ''
const allowedRpcNames = new Set([...allowlist.matchAll(/'([^']+)'/g)].map(match => match[1]))
for (const source of migrationSources) {
  for (const statement of source.matchAll(/grant\s+execute\s+on\s+function\s+([\s\S]*?)\s+to\s+authenticated\s*;/gi)) {
    for (const match of statement[1].matchAll(/public\.([a-z0-9_]+)\s*\(/gi)) {
      allowedRpcNames.add(match[1])
    }
  }
}
for (const name of rpcNames) {
  assert.ok(allowedRpcNames.has(name), `Frontend RPC ${name} is not granted by the final migration`)
}

for (const name of databaseObjects) {
  const relation = new RegExp(
    `create\\s+(?:(?:or\\s+replace)\\s+)?(?:table|view)\\s+(?:if\\s+not\\s+exists\\s+)?public\\.${name}\\b`,
    'i'
  )
  assert.match(schema, relation, `Missing local SQL table/view for frontend query ${name}`)
}

const classesPage = await readFile(path.resolve('app/pages/classes.vue'), 'utf8')
const overviewComponent = await readFile(path.resolve('app/components/ClassRegistrationOverview.vue'), 'utf8')
assert.match(classesPage, /from\('enrollments'\)[\s\S]*?\.eq\('active', true\)/,
  'Classes roster and member counts must be based on active educational enrollments')
assert.match(classesPage, /rpc\('monthly_registration_list'/,
  'Monthly registration metadata must use the staff-scoped registration RPC')
assert.match(classesPage, /from\('month_fee_overview'\)[\s\S]*?confirmation_status|paid_total,balance_due/,
  'Finance roles must get payment totals from the monthly financial view')
assert.doesNotMatch(classesPage.slice(classesPage.indexOf('async function addToClass'), classesPage.indexOf('async function withdrawFromClass(')),
  /monthly_memberships|payments|record_tuition_payment/,
  'Adding an educational class link must not create monthly charges or payments')
assert.match(overviewComponent, /rpc\('ensure_billing_month'/,
  'Month creation must use the established month-creation RPC')
assert.doesNotMatch(overviewComponent.slice(overviewComponent.indexOf('async function createMonth'), overviewComponent.indexOf('onMounted(load)')),
  /monthly_memberships|payments|record_tuition_payment/,
  'Creating a billing month must not create monthly memberships or payments')
assert.match(schema, /drop trigger if exists enrollment_month_sync on public\.enrollments/i,
  'Monthly membership auto-sync trigger must be disabled in the migration chain')
const ensureFunctions = [...schema.matchAll(/create or replace function public\.ensure_billing_month[\s\S]*?as \$\$([\s\S]*?)\$\$;/gi)]
assert.ok(ensureFunctions.length, 'Month creation RPC must exist')
assert.doesNotMatch(ensureFunctions.at(-1)[1], /insert\s+into\s+public\.monthly_memberships/i,
  'The current month creation RPC must not create financial memberships')
assert.match(schema, /create unique index monthly_active_identity on public\.monthly_memberships\(period_id,enrollment_id\) where registration_active/i,
  'A student enrollment must have at most one active monthly registration')
assert.match(schema, /create or replace function public\.change_student_class_membership\([\s\S]*?p_effective_on date[\s\S]*?p_operation text/i,
  'Effective dated class changes must use the guarded transactional RPC')
assert.match(schema, /change_student_class_membership[\s\S]*?staff_has_any\(array\['admin','registrar'\]\)/i,
  'Class membership RPC must enforce education role access')
const registrationStatusMigration = migrationSources.find(s => s.includes("'registration_status'"))
assert.match(registrationStatusMigration, /'registration_status',case when m\.registration_active then 'registered' else 'cancelled' end/i,
  'Educational registration state must not depend on payment status')
assert.match(registrationStatusMigration, /count\(\*\) filter\(where m\.registration_active\)::bigint as registrations/i,
  'Monthly registration totals must include active registrations with unpaid fees')
const tuitionSummaryView = registrationStatusMigration.match(/create or replace view public\.month_tuition_summary[\s\S]*?group by m\.period_id;/i)?.[0] || ''
assert.match(tuitionSummaryView, /sum\(m\.amount_due\) filter\(where m\.registration_active\)/i,
  'Cancelled memberships must not contribute to payable totals')
assert.match(tuitionSummaryView, /sum\(m\.effective_teacher_entitlement\) filter\(where m\.registration_active\)/i,
  'Cancelled memberships must not contribute to teacher entitlement totals')
assert.match(tuitionSummaryView, /sum\(coalesce\(paid\.paid_total,0\)\)/i,
  'Valid historical receipts remain visible independent of membership active status')
const registrationForm = await readFile(path.resolve('app/components/MonthlyRegistration.vue'), 'utf8')
assert.match(registrationForm, /\.eq\('active', true\)[\s\S]*?approvedForClass/,
  'Existing active class links must be offered with an approved prior agreement')
assert.match(registrationForm, /payment_method: 'cash'/,
  'Cash must be the default when an actual payment is entered')
assert.match(registrationForm.match(/<select v-model="row\.payment_method"[\s\S]*?<\/select>/)?.[0] || '', /<option value="cash"[\s\S]*?<option value="bank"[\s\S]*?<option value="other"/,
  'Registration must preserve the cash default and allow actual supported payment methods')
assert.match(registrationForm.match(/<select v-model="existingPaymentMethod"[\s\S]*?<\/select>/)?.[0] || '', /<option value="cash"[\s\S]*?<option value="bank"[\s\S]*?<option value="other"/,
  'Existing account payment must support actual cash, bank, or other method choices')
assert.match(schema, /if payment > 0 then[\s\S]*?record_tuition_payment/i,
  'No payment receipt may be created when the payment amount is zero')
assert.match(schema, /create policy audit_admin_read on public\.audit_logs for select to authenticated using\(public\.staff_has_any\(array\['admin'\]\)\)/i,
  'Enrollment change audit history must remain administrator-only')

console.log(`PASS: ${rpcNames.size} frontend RPCs and ${databaseObjects.size} static tables/views match local migrations and RPC grants.`)
