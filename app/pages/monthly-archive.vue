<script setup lang="ts">
import { Archive, Printer, ReceiptText, Wallet } from 'lucide-vue-next'

const { t } = useLanguage()
const db = useSupabase()
const auth = useAuth()
const periods = ref<any[]>([])
const month = ref('')
const period = computed(() => periods.value.find(item => String(item.year_month).slice(0, 7) === month.value) || null)
const summary = ref<any | null>(null)
const accounts = ref<any[]>([])
const settlements = ref<any[]>([])
const expenses = ref<any[]>([])
const payments = ref<any[]>([])
const chapterSales = ref<any[]>([])
const bookSales = ref<any[]>([])
const bookExpenseRows = ref<any[]>([])
const chapterPayments = ref<any[]>([])
const chapterReceiptsThisMonth = ref<any[]>([])
const chapterReceiptSales = ref<any[]>([])
const bookPayments = ref<any[]>([])
const loading = ref(false)
const error = ref('')

const start = computed(() => month.value ? `${month.value}-01` : '')
const end = computed(() => {
  if (!month.value) return ''
  const [year, value] = month.value.split('-').map(Number)
  return new Date(Date.UTC(year!, value!, 1)).toISOString().slice(0, 10)
})
const total = (rows: any[], field: string) => rows.reduce((sum, row) => sum + Number(row[field] || 0), 0)
const feeTotal = computed(() => total(accounts.value, 'amount_due'))
const discountTotal = computed(() => total(accounts.value, 'discount'))
const collectedTotal = computed(() => total(accounts.value, 'paid_total'))
const arrearsTotal = computed(() => total(accounts.value, 'balance_due'))
const teacherShareTotal = computed(() => total(accounts.value, 'teacher_entitlement'))
const teacherPaidTotal = computed(() => total(settlements.value.filter(row => !row.voided_at), 'amount'))
const receiptLabel = (payment: any) => payment.receipt_number || `TU-${String(payment.id).replaceAll('-', '').toUpperCase()}`
const studentPayments = (accountId: string) => payments.value.filter(payment => payment.monthly_membership_id === accountId)
const monthExpenses = computed(() => total(expenses.value.filter(row => !row.voided_at), 'amount'))
function summaryTeacherGroups(accountRows: any[], settlementRows: any[]) {
  const groups = new Map<string, any>()
  for (const row of accountRows) {
    const key = `${row.teacher_id}:${row.class_id}`
    const current = groups.get(key) || { key, teacher: row.teacher_name, className: row.class_name, entitlement: 0, settled: 0 }
    current.entitlement += Number(row.teacher_entitlement || 0)
    groups.set(key, current)
  }
  for (const item of settlementRows.filter(row => !row.voided_at)) {
    const current = groups.get(`${item.teacher_id}:${item.class_id}`)
    if (current) current.settled += Number(item.amount || 0)
  }
  return [...groups.values()]
}

async function load() {
  if (!db || !auth.canFinance.value) return
  loading.value = true
  error.value = ''
  summary.value = null
  accounts.value = []
  settlements.value = []
  expenses.value = []
  payments.value = []
    chapterSales.value = []
    bookSales.value = []
    bookExpenseRows.value = []
    chapterPayments.value = []
    chapterReceiptsThisMonth.value = []
    chapterReceiptSales.value = []
    bookPayments.value = []
  try {
    if (!periods.value.length) {
      const result = await db.from('billing_periods').select('id,year_month,status,closed_at,closure_notes').order('year_month', { ascending: false })
      if (result.error) throw result.error
      periods.value = result.data || []
      if (!month.value && periods.value.length) month.value = String(periods.value[0].year_month).slice(0, 7)
    }
    const selected = period.value
    if (!selected) return
    const [financial, report, expenseRows, chapterRows, bookRows, chapterReceipts, bookExpenseResult] = await Promise.all([
      db.rpc('office_month_summary', { p_month: start.value }),
      db.rpc('class_month_report', { p_month: start.value, p_class: null, p_teacher: null }),
      db.from('expenses').select('id,category,description,amount,spent_on,voided_at,void_reason').gte('spent_on', start.value).lt('spent_on', end.value).order('spent_on', { ascending: false }),
      db.from('chapter_sale_overview').select('id,chapter_id,quantity,unit_price,sold_on,student_name,student_code,class_name,title,total_price,paid_total,balance_due,payment_status').gte('sold_on', start.value).lt('sold_on', end.value).order('sold_on', { ascending: false }),
      db.from('book_sale_overview').select('id,book_id,quantity,unit_price,sold_on,student_name,student_code,class_name,title,total_price,paid_total,balance_due,payment_status').gte('sold_on', start.value).lt('sold_on', end.value).order('sold_on', { ascending: false }),
      db.from('material_payments').select('id,chapter_sale_id,amount,paid_on,voided_at,void_reason').gte('paid_on', start.value).lt('paid_on', end.value).not('chapter_sale_id', 'is', null).order('paid_on', { ascending: false }),
      db.from('book_expenses').select('id,category,description,amount,spent_on,voided_at,void_reason').gte('spent_on', start.value).lt('spent_on', end.value).order('spent_on', { ascending: false })
    ])
    if (financial.error || report.error || expenseRows.error || chapterRows.error || bookRows.error || chapterReceipts.error || bookExpenseResult.error) throw financial.error || report.error || expenseRows.error || chapterRows.error || bookRows.error || chapterReceipts.error || bookExpenseResult.error
    summary.value = financial.data
    accounts.value = report.data?.rows || []
    settlements.value = report.data?.settlements || []
    expenses.value = expenseRows.data || []
    chapterSales.value = chapterRows.data || []
    bookSales.value = bookRows.data || []
    bookExpenseRows.value = bookExpenseResult.data || []
    chapterReceiptsThisMonth.value = chapterReceipts.data || []
    const collectedChapterSaleIds = [...new Set(chapterReceiptsThisMonth.value.map(row => row.chapter_sale_id))]
    if (collectedChapterSaleIds.length) {
      const saleRows = await db.from('chapter_sale_overview').select('id,title,student_name,student_code').in('id', collectedChapterSaleIds)
      if (saleRows.error) throw saleRows.error
      chapterReceiptSales.value = saleRows.data || []
    }
    const ids = accounts.value.map(row => row.id)
    if (ids.length) {
      const paymentRows = await db.from('payments').select('id,monthly_membership_id,amount,paid_on,method,reference_note,receipt_number,voided_at,void_reason').in('monthly_membership_id', ids).order('paid_on', { ascending: false })
      if (paymentRows.error) throw paymentRows.error
      payments.value = paymentRows.data || []
    }
    const chapterIds = chapterSales.value.map(row => row.id)
    if (chapterIds.length) {
      const receipts = await db.from('material_payments').select('id,chapter_sale_id,amount,paid_on,voided_at,void_reason').in('chapter_sale_id', chapterIds).order('paid_on', { ascending: false })
      if (receipts.error) throw receipts.error
      chapterPayments.value = receipts.data || []
    }
    const bookIds = bookSales.value.map(row => row.id)
    if (bookIds.length) {
      const receipts = await db.from('material_payments').select('id,book_sale_id,amount,paid_on,voided_at,void_reason').in('book_sale_id', bookIds).order('paid_on', { ascending: false })
      if (receipts.error) throw receipts.error
      bookPayments.value = receipts.data || []
    }
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    loading.value = false
  }
}

function printReport() {
  if (period.value) window.print()
}

watch(month, () => { if (periods.value.length) load() })
onMounted(load)
</script>

<template>
  <div class="monthly-archive-page">
    <PageTitle :title="t('nav.monthlyArchive')" :subtitle="t('archive.subtitle')">
      <button class="btn" :disabled="loading || !period" @click="printReport"><Printer :size="17" /> {{ t('archive.print') }}</button>
      <button class="btn" :disabled="loading" @click="load"><Archive :size="17" /> {{ t('financialUi.refresh') }}</button>
    </PageTitle>
    <Notice :message="error" kind="error" />

    <section class="card archive-picker">
      <label>{{ t('archive.chooseMonth') }}
        <select v-model="month" :disabled="loading || !periods.length">
          <option v-for="item in periods" :key="item.id" :value="String(item.year_month).slice(0, 7)">
            {{ String(item.year_month).slice(0, 7) }} · {{ item.status }}
          </option>
        </select>
      </label>
      <span v-if="period" :class="['badge', period.status === 'closed' || period.status === 'locked' ? 'warning' : 'info']">
        {{ period.status === 'closed' || period.status === 'locked' ? t('archive.closedReadOnly') : t('archive.openPeriod') }}
      </span>
      <NuxtLink v-if="period" class="btn light" :to="`/finance?month=${month}`"><Wallet :size="16" /> {{ t('nav.tuition') }}</NuxtLink>
    </section>

    <p v-if="period?.closure_notes" class="hint archive-closure-note">{{ t('archive.closureNote') }}: {{ period.closure_notes }}</p>
    <p v-if="loading" class="card empty">{{ t('financialUi.loading') }}</p>
    <template v-else-if="period && summary">
      <section class="archive-kpis">
        <article class="card archive-kpi"><span>{{ t('archive.registrations') }}</span><strong>{{ accounts.length }}</strong></article>
        <article class="card archive-kpi"><span>{{ t('archive.fees') }}</span><strong>{{ money(feeTotal) }}</strong></article>
        <article class="card archive-kpi"><span>{{ t('archive.discounts') }}</span><strong>{{ money(discountTotal) }}</strong></article>
        <article class="card archive-kpi"><span>{{ t('archive.collected') }}</span><strong>{{ money(collectedTotal) }}</strong></article>
        <article class="card archive-kpi"><span>{{ t('archive.arrears') }}</span><strong>{{ money(arrearsTotal) }}</strong></article>
        <article class="card archive-kpi"><span>{{ t('archive.expenses') }}</span><strong>{{ money(monthExpenses) }}</strong></article>
        <article class="card archive-kpi"><span>{{ t('archive.teacherShare') }}</span><strong>{{ money(teacherShareTotal) }}</strong></article>
        <article class="card archive-kpi"><span>{{ t('archive.teacherSettled') }}</span><strong>{{ money(teacherPaidTotal) }}</strong></article>
      </section>

      <section class="card archive-income">
        <h2>{{ t('archive.incomeSummary') }}</h2>
        <div class="summary-row"><span>{{ t('archive.tuitionCollected') }}</span><strong>{{ money(summary.tuition_collected) }}</strong></div>
        <div class="summary-row"><span>{{ t('archive.learningMaterialsCollected') }}</span><strong>{{ money(summary.chapter_collected) }}</strong></div>
        <div class="summary-row"><span>{{ t('archive.grossIncome') }}</span><strong>{{ money(summary.gross_collected) }}</strong></div>

        <div class="summary-row"><span>{{ t('archive.officeExpenses') }}</span><strong>{{ money(monthExpenses) }}</strong></div>
        <p class="hint">{{ t('archive.historicalLimits') }}</p>
      </section>

      <section class="card archive-section">
        <div class="card-header"><div><h2>{{ t('archive.studentRegistrations') }}</h2><p>{{ t('archive.readOnlyHint') }}</p></div><span class="badge info">{{ accounts.length }}</span></div>
        <div class="table-wrap"><table class="data-table"><thead><tr><th>{{ t('financialUi.student') }}</th><th>{{ t('financialUi.class') }}</th><th>{{ t('financialUi.teacher') }}</th><th>{{ t('archive.fees') }}</th><th>{{ t('archive.discounts') }}</th><th>{{ t('archive.collected') }}</th><th>{{ t('archive.arrears') }}</th><th>{{ t('archive.details') }}</th></tr></thead>
          <tbody><tr v-for="account in accounts" :key="account.id"><td><strong>{{ account.student_name }}</strong><div class="small muted">{{ account.student_code }}</div></td><td>{{ account.class_name }}</td><td>{{ account.teacher_name }}</td><td class="numeric">{{ money(account.amount_due) }}</td><td class="numeric">{{ money(account.discount) }}</td><td class="numeric">{{ money(account.paid_total) }}</td><td class="numeric">{{ money(account.balance_due) }}</td><td><details><summary>{{ t('archive.details') }}</summary><p>{{ t('archive.originalFee') }}: {{ money(account.original_fee) }}</p><p>{{ t('archive.applicableFee') }}: {{ money(account.base_fee) }}</p><p>{{ t('archive.teacherShare') }}: {{ money(account.teacher_entitlement) }}</p><p>{{ t('archive.officeShare') }}: {{ money(account.center_entitlement) }}</p><div v-for="payment in studentPayments(account.id)" :key="payment.id" class="receipt-row"><ReceiptText :size="15"/><span>{{ receiptLabel(payment) }} · {{ payment.paid_on }} · {{ payment.method }}<small v-if="payment.voided_at">{{ t('archive.voided') }}: {{ payment.void_reason }}</small></span><strong>{{ money(payment.amount) }}</strong></div><p v-if="!studentPayments(account.id).length" class="hint">{{ t('archive.noReceipts') }}</p></details></td></tr><tr v-if="!accounts.length"><td colspan="8" class="empty">{{ t('archive.noRegistrations') }}</td></tr></tbody>
        </table></div>
      </section>

      <section class="card archive-section">
        <div class="card-header"><div><h2>{{ t('archive.chapterSales') }}</h2><p>{{ t('financialUi.materials.titleChapterFunds') }}</p></div><span class="badge info">{{ chapterSales.length }}</span></div>
        <div class="table-wrap"><table class="data-table"><thead><tr><th>{{ t('financialUi.materials.chapters') }}</th><th>{{ t('archive.studentRegistrations') }}</th><th>{{ t('financialUi.materials.saleDate') }}</th><th>{{ t('archive.quantity') }}</th><th>{{ t('archive.fees') }}</th><th>{{ t('archive.collected') }}</th><th>{{ t('archive.arrears') }}</th><th>{{ t('archive.details') }}</th></tr></thead><tbody>
          <tr v-for="sale in chapterSales" :key="sale.id"><td>{{ sale.title }}</td><td>{{ sale.student_name || '—' }}<small class="material-id">{{ sale.student_code }}</small></td><td>{{ sale.sold_on }}</td><td>{{ sale.quantity }}</td><td>{{ money(sale.total_price) }}</td><td>{{ money(sale.paid_total) }}</td><td>{{ money(sale.balance_due) }}</td><td><details><summary>{{ t('archive.details') }}</summary><div v-for="receipt in chapterPayments.filter(item => item.chapter_sale_id === sale.id)" :key="receipt.id" class="receipt-row"><ReceiptText :size="15"/><span>{{ receipt.paid_on }}<small v-if="receipt.voided_at">{{ t('archive.voided') }}: {{ receipt.void_reason }}</small></span><strong>{{ money(receipt.amount) }}</strong></div><p v-if="!chapterPayments.some(item => item.chapter_sale_id === sale.id)" class="hint">{{ t('archive.noReceipts') }}</p></details></td></tr>
          <tr v-if="!chapterSales.length"><td colspan="8" class="empty">{{ t('archive.noChapterSales') }}</td></tr>
        </tbody></table></div>
        <h3>{{ t('archive.chapterReceiptsThisMonth') }}</h3>
        <div class="table-wrap"><table class="data-table"><thead><tr><th>{{ t('financialUi.materials.chapters') }}</th><th>{{ t('financialUi.student') }}</th><th>{{ t('financialUi.materials.salePaymentDate') }}</th><th>{{ t('archive.collected') }}</th></tr></thead><tbody>
          <tr v-for="receipt in chapterReceiptsThisMonth" :key="receipt.id"><td>{{ chapterReceiptSales.find(sale => sale.id === receipt.chapter_sale_id)?.title || receipt.chapter_sale_id }}</td><td>{{ chapterReceiptSales.find(sale => sale.id === receipt.chapter_sale_id)?.student_name || '—' }}</td><td>{{ receipt.paid_on }}</td><td>{{ money(receipt.amount) }}<small v-if="receipt.voided_at"> · {{ t('archive.voided') }}: {{ receipt.void_reason }}</small></td></tr>
          <tr v-if="!chapterReceiptsThisMonth.length"><td colspan="4" class="empty">{{ t('archive.noReceipts') }}</td></tr>
        </tbody></table></div>
      </section>

      <section class="card archive-section book-ledger">
        <div class="card-header"><div><h2>{{ t('archive.bookLedger') }}</h2><p>{{ t('financialUi.materials.titleBookFunds') }}</p></div><span class="badge info">{{ bookSales.length }}</span></div>
        <div class="table-wrap"><table class="data-table"><thead><tr><th>{{ t('financialUi.materials.books') }}</th><th>{{ t('archive.studentRegistrations') }}</th><th>{{ t('financialUi.materials.saleDate') }}</th><th>{{ t('archive.quantity') }}</th><th>{{ t('archive.fees') }}</th><th>{{ t('archive.collected') }}</th><th>{{ t('archive.arrears') }}</th><th>{{ t('archive.details') }}</th></tr></thead><tbody>
          <tr v-for="sale in bookSales" :key="sale.id"><td>{{ sale.title }}</td><td>{{ sale.student_name || '—' }}<small class="material-id">{{ sale.student_code }}</small></td><td>{{ sale.sold_on }}</td><td>{{ sale.quantity }}</td><td>{{ money(sale.total_price) }}</td><td>{{ money(sale.paid_total) }}</td><td>{{ money(sale.balance_due) }}</td><td><details><summary>{{ t('archive.details') }}</summary><div v-for="receipt in bookPayments.filter(item => item.book_sale_id === sale.id)" :key="receipt.id" class="receipt-row"><ReceiptText :size="15"/><span>{{ receipt.paid_on }}<small v-if="receipt.voided_at">{{ t('archive.voided') }}: {{ receipt.void_reason }}</small></span><strong>{{ money(receipt.amount) }}</strong></div><p v-if="!bookPayments.some(item => item.book_sale_id === sale.id)" class="hint">{{ t('archive.noReceipts') }}</p></details></td></tr>
          <tr v-if="!bookSales.length"><td colspan="8" class="empty">{{ t('archive.noBookSales') }}</td></tr>
        </tbody></table></div>
        <h3>{{ t('financialUi.materials.books') }} · {{ t('financialUi.expenses.title') }}</h3>
        <div class="table-wrap"><table class="data-table"><thead><tr><th>{{ t('financialUi.date') }}</th><th>{{ t('financialUi.category') }}</th><th>{{ t('financialUi.description') }}</th><th>{{ t('financialUi.amount') }}</th><th>{{ t('archive.status') }}</th></tr></thead><tbody>
          <tr v-for="expense in bookExpenseRows" :key="expense.id"><td>{{ expense.spent_on }}</td><td>{{ expense.category }}</td><td>{{ expense.description }}</td><td>{{ money(expense.amount) }}</td><td>{{ expense.voided_at ? `${t('archive.voided')}: ${expense.void_reason}` : t('financialUi.valid') }}</td></tr>
          <tr v-if="!bookExpenseRows.length"><td colspan="5" class="empty">{{ t('archive.noExpenses') }}</td></tr>
        </tbody></table></div>
      </section>

      <section class="card archive-section">
        <h2>{{ t('archive.teacherSettlements') }}</h2>
        <div class="table-wrap"><table class="data-table"><thead><tr><th>{{ t('financialUi.teacher') }}</th><th>{{ t('financialUi.class') }}</th><th>{{ t('archive.teacherShare') }}</th><th>{{ t('archive.settledAmount') }}</th><th>{{ t('archive.arrears') }}</th></tr></thead><tbody>
          <tr v-for="group in summaryTeacherGroups(accounts, settlements)" :key="group.key"><td>{{ group.teacher }}</td><td>{{ group.className }}</td><td>{{ money(group.entitlement) }}</td><td>{{ money(group.settled) }}</td><td>{{ money(Math.max(0, group.entitlement - group.settled)) }}</td></tr>
          <tr v-if="!accounts.length"><td colspan="5" class="empty">{{ t('archive.noTeacherSettlements') }}</td></tr>
        </tbody></table></div>
        <div v-for="row in settlements" :key="row.id" class="receipt-row"><ReceiptText :size="15"/><span>{{ row.paid_on }} · {{ row.method }} · {{ row.note || '—' }}<small v-if="row.voided_at">{{ t('archive.voided') }}: {{ row.void_reason }}</small></span><strong>{{ money(row.amount) }}</strong></div>
      </section>

      <section class="card archive-section">
        <h2>{{ t('archive.expenses') }}</h2>
        <div class="table-wrap"><table class="data-table"><thead><tr><th>{{ t('financialUi.date') }}</th><th>{{ t('financialUi.category') }}</th><th>{{ t('financialUi.description') }}</th><th>{{ t('financialUi.amount') }}</th><th>{{ t('archive.status') }}</th></tr></thead><tbody>
          <tr v-for="expense in expenses" :key="expense.id"><td>{{ expense.spent_on }}</td><td>{{ expense.category }}</td><td>{{ expense.description }}</td><td>{{ money(expense.amount) }}</td><td>{{ expense.voided_at ? `${t('archive.voided')}: ${expense.void_reason}` : t('financialUi.valid') }}</td></tr>
          <tr v-if="!expenses.length"><td colspan="5" class="empty">{{ t('archive.noExpenses') }}</td></tr>
        </tbody></table></div>
      </section>
    </template>
    <section v-else class="card empty">{{ t('archive.noPeriod') }}</section>
  </div>
</template>

<style scoped>
.monthly-archive-page { display: grid; gap: 18px; }
.archive-picker { display: flex; align-items: end; gap: 14px; flex-wrap: wrap; }
.archive-picker label { display: grid; gap: 7px; min-width: min(100%, 240px); flex: 1; }
.archive-picker select { min-height: 42px; }
.archive-closure-note { margin: 0; }
.archive-kpis { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; }
.archive-kpi { display: grid; gap: 10px; min-width: 0; }
.archive-kpi strong { overflow-wrap: anywhere; font-size: 1.12rem; }
.archive-income h2, .archive-section h2 { margin-top: 0; }
.receipt-row { display: flex; align-items: center; gap: 10px; padding: 10px 0; border-top: 1px solid var(--line, #e5e7eb); }
.receipt-row span { display: grid; flex: 1; min-width: 0; overflow-wrap: anywhere; }
.receipt-row strong { white-space: nowrap; }
@media (max-width: 760px) { .archive-kpis { grid-template-columns: repeat(2, minmax(0, 1fr)); } .archive-picker > * { width: 100%; } }
@media print { .archive-picker, .monthly-archive-page > :deep(.page-title) button { display: none; } .archive-kpis { grid-template-columns: repeat(4, minmax(0, 1fr)); } }
</style>
