<script setup lang="ts">
import type { ClassItem, Student } from '~/types/models'

interface RegistrationClassRow {
  class_id: string
  sponsored_confirmed: boolean
  original_fee: number | null
  agreed_fee: number | null
  teacher_entitlement: number | null
  is_exception: boolean
  exception_reason: string
  discount: number
  discount_reason: string
  arrangement_notes: string
  payment: number
  paid_on: string
  payment_method: string
  payment_reference: string
  payment_note: string
  is_modifying?: boolean
  is_suggestion?: boolean
  original_fee_is_custom?: boolean
  discount_reason_type?: '' | 'management' | 'family' | 'scholarship' | 'other'
}

const financialError = useFinancialError()
const db = useSupabase()
const auth = useAuth()
const { t, locale } = useLanguage()
const key = useRequestKey()
const emit = defineEmits<{ saved: [] }>()

const month = ref(nowMonth())
const date = ref(todayKarachi())
const mode = ref<'returning' | 'new'>('returning')
const query = ref('')
const classQuery = ref('')
const results = ref<any[]>([])
const selected = ref<Student | null>(null)
const previous = ref<any[]>([])
const currentAccounts = ref<any[]>([])
const currentPayments = ref<any[]>([])
const existingPaymentAccount = ref<any | null>(null)
const existingPaymentAmount = ref<number | null>(null)
const existingPaymentDate = ref(todayKarachi())
const existingPaymentMethod = ref('')
const existingPaymentNote = ref('')
const classes = ref<ClassItem[]>([])
const error = ref('')
const success = ref('')
const saving = ref(false)
const loading = ref(false)
const searching = ref(false)
const closed = ref(false)
const duplicateConfirmed=ref(false),duplicateMatches=ref<any[]>([])
const person = reactive({
  first_name: '',
  last_name: '',
  guardian_name: '',
  phone: '',
  guardian_phone: '',
  address: '',
  notes: ''
})

const rows = ref<RegistrationClassRow[]>([])
let duplicateVersion=0
watch(()=>[person.first_name,person.last_name,person.phone],async()=>{duplicateConfirmed.value=false;duplicateMatches.value=[];const version=++duplicateVersion;if(!db||mode.value!=='new'||person.first_name.trim().length<2)return;const r=await db.rpc('registration_student_search',{p_query:(person.first_name+' '+person.last_name).trim()});if(version===duplicateVersion&&!r.error)duplicateMatches.value=r.data||[]})
watch(rows,()=>{for(const row of rows.value){if(!row.is_exception)row.teacher_entitlement=row.agreed_fee===null?null:Math.round(Number(row.agreed_fee)*50)/100;if(Number(row.agreed_fee)<=0||row.discount!==row.agreed_fee)row.sponsored_confirmed=false}},{deep:true})


const isAdmin = computed(() => auth.profile.value?.role === 'admin')

const monthLabel = computed(() => isValidMonth(month.value)
  ? new Intl.DateTimeFormat(locale.value === 'en' ? 'en' : 'fa-AF', {
      calendar: 'gregory',
      month: 'long',
      year: 'numeric',
      timeZone: 'Asia/Karachi'
    }).format(new Date(`${month.value}-01T12:00:00Z`))
  : month.value)

const monthEnd = computed(() => isValidMonth(month.value)
  ? `${month.value}-${new Date(Number(month.value.slice(0, 4)), Number(month.value.slice(5)), 0).getDate().toString().padStart(2, '0')}`
  : '')

const visibleClasses = computed(() => {
  const search = classQuery.value.trim().toLocaleLowerCase()
  return classes.value.filter(classItem => !search
    || `${classItem.title} ${classItem.teacher?.full_name || ''}`.toLocaleLowerCase().includes(search))
})

// Standard teacher entitlement is 50% of the approved base tuition
const standardTeacherShare = (row: RegistrationClassRow) =>
  Math.round(Number(row.agreed_fee || 0) * 0.50 * 100) / 100

const fee = (row: RegistrationClassRow) => Number(row.agreed_fee || 0)
const teacherShare = (row: RegistrationClassRow) => Number(row.teacher_entitlement || 0)
const maxDiscount = (row: RegistrationClassRow) => fee(row)
const payableAmount = (row: RegistrationClassRow) => Math.max(0, fee(row) - Number(row.discount || 0))
const balanceDue = (row: RegistrationClassRow) => Math.max(0, payableAmount(row) - Number(row.payment || 0))
const institutionFunded = (row: RegistrationClassRow) => Math.max(0, teacherShare(row) - payableAmount(row))

const totalAgreed = computed(() => rows.value.reduce((s, r) => s + fee(r), 0))
const totalDiscount = computed(() => rows.value.reduce((s, r) => s + Number(r.discount || 0), 0))
const totalPayable = computed(() => rows.value.reduce((s, r) => s + payableAmount(r), 0))
const totalPayment = computed(() => rows.value.reduce((s, r) => s + Number(r.payment || 0), 0))
const totalBalance = computed(() => rows.value.reduce((s, r) => s + balanceDue(r), 0))

const latest = (record: any) => !previous.value.some(other => other.class_id === record.class_id && other.year_month > record.year_month)
const financiallyApproved = (record: any) => !!(record.agreement_approved_at && record.agreement_approved_by)
const alreadyRegisteredClassIds = computed(() => new Set(currentAccounts.value.filter(row => row.registration_active !== false).map(row => row.class_id)))
function accountPaymentStatus(account: any) {
  if (account.confirmation_status === 'fully_sponsored') return 'sponsored'
  if (Number(account.paid_total) > 0 && Number(account.balance_due) <= 0) return 'paid'
  if (Number(account.paid_total) > 0) return 'partial'
  return 'unpaid'
}

function classReferenceFee(value: unknown) {
  const amount = Number(value)
  return Number.isFinite(amount) && amount > 0 ? money(amount) : t('registration.feeNotSet')
}

function discountReasonType(reason: string): RegistrationClassRow['discount_reason_type'] {
  if (reason === 'Management standard discount') return 'management'
  if (reason === 'Family discount') return 'family'
  if (reason === 'Family full scholarship') return 'scholarship'
  return reason ? 'other' : ''
}

function setDiscountReason(row: RegistrationClassRow, type: NonNullable<RegistrationClassRow['discount_reason_type']>) {
  row.discount_reason_type = type
  if (type === 'management') row.discount_reason = 'Management standard discount'
  else if (type === 'family') row.discount_reason = 'Family discount'
  else if (type === 'scholarship') {
    row.discount = fee(row)
    row.discount_reason = 'Family full scholarship'
    row.sponsored_confirmed = false
  } else if (type === 'other') row.discount_reason = ''
  else row.discount_reason = ''
}

function suggestLatestApprovedArrangement() {
  if (rows.value.length || !previous.value.length) return
  const suggestion = [...previous.value]
    .filter(record => financiallyApproved(record)
      && latest(record)
      && classes.value.some(item => item.id === record.class_id && item.active !== false)
      && !alreadyRegisteredClassIds.value.has(record.class_id))
    .sort((a, b) => String(b.year_month).localeCompare(String(a.year_month)))[0]
  if (suggestion) applyPreviousArrangement(suggestion, false, true)
}

let searchVersion = 0
let historyVersion = 0
let timer: ReturnType<typeof setTimeout> | undefined

watch(query, () => {
  clearTimeout(timer)
  const version = ++searchVersion
  searching.value = false
  results.value = []
  timer = setTimeout(async () => {
    if (!db || query.value.trim().length < 2) return
    searching.value = true
    error.value = ''
    try {
      const result = await db.rpc('registration_student_search', { p_query: query.value })
      if (version !== searchVersion) return
      if (result.error) throw result.error
      results.value = result.data || []
    } catch (cause) {
      if (version === searchVersion) error.value = financialError(cause)
    } finally {
      if (version === searchVersion) searching.value = false
    }
  }, 250)
})

onBeforeUnmount(() => {
  clearTimeout(timer)
  searchVersion++
  historyVersion++
})

async function choose(student: Student) {
  selected.value = student
  results.value = []
  query.value = ''
  await history()
}

async function history() {
  const version = ++historyVersion
  previous.value = []
  currentAccounts.value = []
  currentPayments.value = []
  existingPaymentAccount.value = null
  rows.value = []
  if (!db || !selected.value || !isValidMonth(month.value)) return
  loading.value = true
  error.value = ''
  try {
    const [result, period] = await Promise.all([db.rpc('registration_previous', {
      p_student: selected.value.id,
      p_month: monthStart(month.value)
    }), db.from('billing_periods').select('id,status').eq('year_month', monthStart(month.value)).maybeSingle()])
    if (period.error) throw period.error
    if (version !== historyVersion) return
    if (result.error) throw result.error
    previous.value = result.data || []
    if (period.data && auth.canFinance.value) {
      const accounts = await allRows(() => db.from('month_fee_overview').select('*')
        .eq('period_id', period.data!.id).eq('student_id', selected.value!.id).order('class_name'))
      if (version !== historyVersion) return
      currentAccounts.value = accounts
      const ids = accounts.map((account: any) => account.id)
      if (ids.length) currentPayments.value = await allRows(() => db.from('payments').select('*')
        .in('monthly_membership_id', ids).order('paid_on', { ascending: false }))
    }
    suggestLatestApprovedArrangement()
  } catch (cause) {
    if (version === historyVersion) error.value = financialError(cause)
  } finally {
    if (version === historyVersion) loading.value = false
  }
}

function startExistingPayment(account: any) {
  if (Number(account.balance_due) <= 0 || !account.registration_active || closed.value || !auth.canFinance.value) return
  key.reset()
  existingPaymentAccount.value = account
  existingPaymentAmount.value = Number(account.balance_due)
  existingPaymentDate.value = todayKarachi()
  existingPaymentMethod.value = ''
  existingPaymentNote.value = ''
}

async function saveExistingPayment() {
  if (!db || !existingPaymentAccount.value || saving.value) return
  const account = existingPaymentAccount.value
  if (!existingPaymentAmount.value || existingPaymentAmount.value <= 0 || existingPaymentAmount.value > Number(account.balance_due) || !existingPaymentDate.value || !existingPaymentMethod.value) {
    error.value = t('registration.invalidFinancials')
    return
  }
  saving.value = true
  error.value = ''
  success.value = ''
  try {
    const payload = {
      p_membership: account.id,
      p_amount: Number(existingPaymentAmount.value),
      p_date: existingPaymentDate.value,
      p_method: existingPaymentMethod.value,
      p_note: existingPaymentNote.value || null
    }
    const result = await db.rpc('record_tuition_payment', { ...payload, p_request: key.forPayload(payload) })
    if (result.error) throw result.error
    success.value = t('financialUi.finance.paymentSaved')
    existingPaymentAccount.value = null
    existingPaymentAmount.value = null
    existingPaymentMethod.value = ''
    existingPaymentNote.value = ''
    key.reset()
    await history()
    emit('saved')
  } catch (cause) {
    error.value = financialError(cause)
  } finally {
    saving.value = false
  }
}

function blankRow(classId = ''): RegistrationClassRow {
  return {
    class_id: classId,
    sponsored_confirmed:false,
    original_fee: null,
    agreed_fee: null,
    teacher_entitlement: null,
    is_exception: false,
    exception_reason: '',
    discount: 0,
    discount_reason: '',
    discount_reason_type: '',
    original_fee_is_custom: false,
    arrangement_notes: '',
    payment: 0,
    paid_on: '',
    payment_method: '',
    payment_reference: '',
    payment_note: '',
    is_modifying: false
  }
}

function onClassSelected(row: RegistrationClassRow) { Object.assign(row,blankRow(row.class_id)) }

function onAgreedFeeChange(row: RegistrationClassRow) {
  if (!row.original_fee_is_custom) row.original_fee = row.agreed_fee
  if (!row.is_exception) {
    row.teacher_entitlement = standardTeacherShare(row)
  }
  if (row.discount_reason_type === 'scholarship') {
    row.discount = fee(row)
    row.discount_reason = 'Family full scholarship'
  }
}

function onDiscountChange(row: RegistrationClassRow) {
  if (row.discount_reason_type === 'scholarship' && row.discount !== fee(row)) {
    row.discount_reason_type = ''
    row.discount_reason = ''
    row.sponsored_confirmed = false
  }
  if (row.discount !== fee(row)) row.sponsored_confirmed = false
}

function onTeacherEntitlementInput(row: RegistrationClassRow) {
  const std = standardTeacherShare(row)
  if (row.teacher_entitlement !== null && Number(row.teacher_entitlement) !== std) {
    row.is_exception = true
  } else {
    row.is_exception = false
    row.exception_reason = ''
  }
}

function resetToStandard(row: RegistrationClassRow) {
  row.teacher_entitlement = standardTeacherShare(row)
  row.is_exception = false
  row.exception_reason = ''
}

function applyPreviousArrangement(record: any, modifying = false, suggestion = false) {
  if (!financiallyApproved(record)) {
    error.value = t('registration.previousAgreementNotApproved')
    return
  }
  let existingIndex = rows.value.findIndex(row => row.class_id === record.class_id)
  const isExc = !!(record.is_exception || record.calculation_mode === 'manual')
  const targetRow: RegistrationClassRow = {
    class_id: classes.value.some(c=>c.id===record.class_id)?record.class_id:'',
    sponsored_confirmed:!!record.sponsored_confirmed,
    original_fee: Number(record.original_fee),
    agreed_fee: Number(record.agreed_fee ?? record.base_fee),
    teacher_entitlement: Number(record.teacher_entitlement),
    is_exception: isExc,
    exception_reason: isExc ? (record.manual_adjustment_reason || '') : '',
    discount: Number(record.discount),
    discount_reason: record.discount_reason || '',
    discount_reason_type: discountReasonType(record.discount_reason || ''),
    original_fee_is_custom: Number(record.original_fee) !== Number(record.agreed_fee ?? record.base_fee),
    arrangement_notes: record.notes || '',
    payment: 0,
    paid_on: '',
    payment_method: '',
    payment_reference: '',
    payment_note: '',
    is_modifying: modifying,
    is_suggestion: suggestion
  }
  if (existingIndex >= 0) {
    rows.value[existingIndex] = targetRow
  } else {
    rows.value.push(targetRow)
  }
  const el = document.getElementById('current-agreements-section')
  if (el) el.scrollIntoView({ behavior: 'smooth' })
}

function startNewArrangement(record: any) {
  rows.value = rows.value.filter(row => row.class_id !== record.class_id)
  const row = blankRow(classes.value.some(c => c.id === record.class_id) ? record.class_id : '')
  rows.value.push(row)
  const el = document.getElementById('current-agreements-section')
  if (el) el.scrollIntoView({ behavior: 'smooth' })
}

async function checkPeriod() {
  if (!db || !isValidMonth(month.value)) {
    closed.value = true
    return
  }
  closed.value = true
  const requested = month.value
  const result = await db.from('billing_periods').select('status')
    .eq('year_month', monthStart(requested)).maybeSingle()
  if (requested !== month.value) return
  if (result.error) {
    error.value = financialError(result.error)
  } else {
    closed.value = !!result.data && result.data.status !== 'open'
  }
}

watch(month, () => {
  date.value = month.value === nowMonth() ? todayKarachi() : monthStart(month.value)
  key.reset()
  checkPeriod()
  history()
})

watch(mode, () => {
  historyVersion++
  loading.value = false
  selected.value = null
  previous.value = []
  currentAccounts.value = []
  currentPayments.value = []
  existingPaymentAccount.value = null
  rows.value = []
  query.value = ''
  classQuery.value = ''
  error.value = ''
  success.value = ''
  key.reset()
})

onMounted(async () => {
  if (!db) return
  try {
    classes.value = await allRows(() => db.from('class_rooms')
      .select('*,teacher:teachers(full_name)').eq('active', true).order('id')) as ClassItem[]
    await checkPeriod()
  } catch (cause) {
    error.value = financialError(cause)
  }
})

async function save() {
  if (!db || saving.value || !isAdmin.value) return
  error.value = ''
  success.value = ''
  if (!rows.value.length || new Set(rows.value.map(row => row.class_id)).size !== rows.value.length) {
    error.value = t('registration.selectClasses')
    return
  }
  if (mode.value === 'returning' && !selected.value) {
    error.value = t('registration.selectStudent')
    return
  }
  if (rows.value.some(row => alreadyRegisteredClassIds.value.has(row.class_id))) {
    error.value = t('agreements.duplicate')
    return
  }
  if (!isValidMonth(month.value) || date.value.slice(0, 7) !== month.value) {
    error.value = t('registration.invalidDate')
    return
  }
  if (rows.value.some(row =>
    row.original_fee === null || row.agreed_fee === null || row.teacher_entitlement === null
    || Number(row.original_fee) < 0 || Number(row.agreed_fee) <= 0 || Number(row.teacher_entitlement) < 0
    || (row.discount > 0 && row.discount_reason.trim().length < 4)
    || (row.discount === fee(row) && !row.sponsored_confirmed)
    || (row.is_exception && (!row.exception_reason || row.exception_reason.trim().length < 4))
    || row.discount < 0 || row.discount > maxDiscount(row)
    || row.payment < 0 || row.payment > fee(row) - row.discount
    || (row.payment > 0 && (!row.paid_on || !row.payment_method))
  )) {
    error.value = t('registration.invalidFinancials')
    return
  }

  if (!window.confirm(t('agreements.shortConfirm', {
    student: selected.value ? `${selected.value.first_name} ${selected.value.last_name}` : `${person.first_name} ${person.last_name}`.trim(),
    month: monthLabel.value,
    count: rows.value.length
  }))) return

  saving.value = true
  try {
    const payload = {
      approved: true,
      duplicate_profile_confirmed: duplicateConfirmed.value,
      ...person,
      student_id: mode.value === 'returning' ? selected.value?.id : null,
      month: monthStart(month.value),
      date: date.value,
      classes: rows.value.map(row => ({
        ...row,
        custom_teacher_share:row.is_exception,
        teacher_share_reason:row.is_exception?row.exception_reason:null,
        exception_reason: row.is_exception ? row.exception_reason : null
      }))
    }
    const result = await db.rpc('register_dashboard_student', {
      p_payload: payload,
      p_request: key.forPayload(payload)
    })
    if (result.error) throw result.error
    success.value = t('registration.saved', {
      code: result.data.student_code,
      count: result.data.membership_count
    })
    rows.value = []
    key.reset()
    emit('saved')
  } catch (cause) {
    error.value = financialError(cause)
  } finally {
    saving.value = false
  }
}

function nextStudent() {
  selected.value = null
  previous.value = []
  rows.value = []
  query.value = ''
  results.value = []
  success.value = ''
  key.reset()
}
</script>

<template>
  <section id="monthly-registration" class="card monthly-registration">
    <!-- Header: Title and Month Selection -->
    <div class="card-header">
      <div>
        <h2>{{ t('registration.title') }}</h2>
        <p>{{ t('registration.subtitle') }}</p>
      </div>
      <label class="month-selector">
        {{ t('registration.month') }}
        <input v-model="month" type="month" required :disabled="saving" />
      </label>
    </div>

    <div class="registration-heading">
      <div class="heading-month">
        <strong>{{ monthLabel }}</strong>
        <span :class="['badge', closed ? 'warning' : 'success']">
          {{ closed ? t('financialUi.teacherSettlements.closedMonth') : t('financialUi.teacherSettlements.openMonth') }}
        </span>
      </div>
      <span class="badge info">{{ t('registration.confirmation') }}</span>
    </div>

    <Notice :message="error" kind="error" />
    <Notice :message="success" kind="success" />
    <button v-if="success" class="btn primary" type="button" @click="nextStudent">{{ t('registration.nextStudent') }}</button>
    <Notice v-if="!isAdmin" :message="t('agreements.adminOnly')" kind="error" />

    <form @submit.prevent="save">
      <fieldset :disabled="saving || !isAdmin" class="registration-fields">

        <!-- ============================================== -->
        <!-- SECTION 1: STUDENT INFORMATION                 -->
        <!-- ============================================== -->
        <section class="form-section">
          <div class="section-header">
            <span class="section-number">1</span>
            <h3>{{ t('agreements.studentSection') }}</h3>
          </div>


        <div class="registration-tabs">
            <button
              v-for="tab in (['returning', 'new'] as const)"
              :key="tab"
              type="button"
              :class="['btn', mode === tab ? 'primary' : '']"
              :aria-pressed="mode === tab"
              @click="mode = tab"
            >
              {{ t(`registration.${tab}`) }}
            </button>
          </div>

          <!-- Returning Student Search -->
          <template v-if="mode === 'returning'">
            <label class="student-search-input">
              {{ t('registration.search') }}
              <input v-model="query" :placeholder="t('registration.placeholder')" autocomplete="off" />
            </label>
            <p v-if="searching" role="status">{{ t('common.loading') }}</p>
            <div v-if="results.length" class="registration-results">
              <button
                v-for="student in results"
                :key="student.id"
                type="button"
                class="quick-item"
                @click="choose(student)"
              >
                <strong>{{ student.first_name }} {{ student.last_name }} · {{ student.student_code }}</strong>
                <span>{{ student.guardian_name ? `${student.guardian_name} · ` : '' }}{{ student.last_classes || t('registration.noHistory') }} · {{ student.last_month || '—' }}</span>
              </button>
            </div>
            <p v-if="query.trim().length >= 2 && !searching && !results.length" class="hint">
              {{ t('registration.noResults') }}
            </p>

            <div v-if="selected" class="student-profile-card">
              <div class="profile-header">
                <div>
                  <h4>{{ selected.first_name }} {{ selected.last_name }}</h4>
                  <span class="badge info">{{ selected.student_code }}</span>
                </div>

                <button type="button" class="btn small-btn" @click="selected = null; previous = []; rows = []">
                  {{ t('common.close') }}
                </button>
              </div>
              <div class="profile-details">
                <span v-if="selected.guardian_name">{{ t('registration.guardian_name') }}: <strong>{{ selected.guardian_name }}</strong></span>
                <span v-if="selected.phone">{{ t('registration.phone') }}: <strong>{{ selected.phone }}</strong></span>
                <span v-if="selected.address">{{ t('registration.address') }}: <strong>{{ selected.address }}</strong></span>
                <span v-if="selected.notes">{{ t('registration.notes') }}: <em>{{ selected.notes }}</em></span>
              </div>
            </div>
            <section v-if="currentAccounts.length" class="form-section current-accounts-section">
              <div class="section-header"><span class="section-number">!</span><div><h3>{{ t('registration.registeredAlready') }}</h3><p class="section-subtitle">{{ monthLabel }}</p></div></div>
              <article v-for="account in currentAccounts" :key="account.id" class="summary-box current-account">
                <div class="history-card-header"><div><h4>{{ account.class_name }}</h4><p>{{ account.teacher_name }}<span v-if="account.start_time_snapshot"> · {{ timeShort(account.start_time_snapshot) }}–{{ timeShort(account.end_time_snapshot) }}</span></p></div>
                  <span :class="['badge', accountPaymentStatus(account)==='paid' ? 'success' : accountPaymentStatus(account)==='sponsored' ? 'info' : accountPaymentStatus(account)==='partial' ? 'warning' : 'danger']">{{ t(accountPaymentStatus(account)==='sponsored' ? 'registration.fullySponsored' : `registration.${accountPaymentStatus(account)}`) }} · {{ t('registration.balance_due') }}: {{ money(account.balance_due) }}</span></div>
                <dl class="registration-finances"><dt>{{ t('registration.agreed_fee') }}</dt><dd>{{ money(account.agreed_fee ?? account.base_fee) }}</dd><dt>{{ t('registration.discount') }}</dt><dd>{{ money(account.discount) }}</dd><dt>{{ t('registration.paid_total') }}</dt><dd>{{ money(account.paid_total) }}</dd></dl>
                <p v-if="!account.registration_active" class="hint">{{ t('students.cancelled') }}</p>
                <button v-if="auth.canFinance.value && Number(account.balance_due) > 0 && account.registration_active" type="button" class="btn primary" :disabled="closed || saving" @click="startExistingPayment(account)">{{ t('registration.registerPayment') }}</button>
                <div v-if="existingPaymentAccount?.id === account.id" class="existing-payment-form">
                  <div class="form-grid"><label>{{ t('registration.payment') }} *<input v-model.number="existingPaymentAmount" type="number" min="0.01" :max="account.balance_due" step="0.01" required /></label>
                    <label>{{ t('registration.paymentDate') }} *<input v-model="existingPaymentDate" type="date" required /></label>
                    <label>{{ t('registration.paymentMethod') }} *<select v-model="existingPaymentMethod" required><option value="">{{ t('registration.choosePaymentMethod') }}</option><option value="cash">{{ t('financialUi.finance.cash') }}</option><option value="bank">{{ t('financialUi.finance.bank') }}</option><option value="other">{{ t('financialUi.expenses.other') }}</option></select></label>
                    <label>{{ t('registration.paymentNote') }}<input v-model="existingPaymentNote" /></label></div>
                  <div class="form-footer"><button type="button" class="btn" @click="existingPaymentAccount = null">{{ t('common.cancel') }}</button><button type="button" class="btn primary" :disabled="saving || closed" @click="saveExistingPayment">{{ t('registration.registerPayment') }}</button></div>
                </div>
                <details v-if="currentPayments.some(payment => payment.monthly_membership_id === account.id)" class="payment-history-list"><summary>{{ t('financialUi.finance.paymentHistory') }}</summary><div v-for="payment in currentPayments.filter(item => item.monthly_membership_id === account.id)" :key="payment.id" class="summary-row"><span>{{ payment.paid_on }} · {{ payment.method }}{{ payment.voided_at ? ` · ${t('financialUi.voided')}` : '' }}</span><strong>{{ money(payment.amount) }}</strong></div></details>
              </article>
            </section>
          </template>

          <!-- New Student Input Fields -->
          <div v-else class="form-grid">
            <label v-for="field in (['first_name', 'last_name'] as const)" :key="field">
              {{ t(`registration.${field}`) }}
              <input
                v-model="person[field]"
                :required="field === 'first_name'"
                :type="field.includes('phone') ? 'tel' : 'text'"
              />
            </label>
            <details class="advanced-controls wide">
              <summary>{{ t('registration.advanced') }}</summary>
              <div class="form-grid">
                <label v-for="field in (['guardian_name', 'phone', 'guardian_phone', 'address', 'notes'] as const)" :key="field">
                  {{ t(`registration.${field}`) }}
                  <input v-model="person[field]" :type="field.includes('phone') ? 'tel' : 'text'" />
                </label>
              </div>
            </details>
          </div>
        </section>

        
<div v-if="mode==='new' && duplicateMatches.length" class="accent-callout"><p>{{t('agreements.possibleDuplicate')}}</p><button v-for="match in duplicateMatches" :key="match.id" class="btn" type="button" @click="mode='returning';nextTick(()=>choose(match))">{{match.first_name}} {{match.last_name}} · {{match.student_code}}</button><label class="approval-check"><input v-model="duplicateConfirmed" type="checkbox"/>{{t('agreements.distinctPerson')}}</label></div>
        <!-- ============================================== -->
        <!-- SECTION 2: PREVIOUS FINANCIAL HISTORY          -->
        <!-- ============================================== -->
        <section v-if="mode === 'returning' && selected" class="form-section">
          <div class="section-header">
            <span class="section-number">2</span>
            <div>
              <h3>{{ t('agreements.historySection') }}</h3>
              <p class="section-subtitle">{{ selected.first_name }} {{ selected.last_name }} ({{ selected.student_code }})</p>
            </div>
          </div>

          <div v-if="selected" class="form-grid"><label v-for="field in (['first_name','last_name','guardian_name','phone','guardian_phone','address'] as const)" :key="field">{{t('registration.'+field)}}<input :value="selected[field]||''" readonly/></label></div>
          <p v-if="loading">{{ t('common.loading') }}</p>
          <div v-else-if="!previous.length" class="empty-history-callout">
            {{ t('registration.noHistory') }}
          </div>
          <details v-else class="registration-history-details">
            <summary>{{ t('agreements.historySection') }}</summary>
            <div class="registration-history">
            <article v-for="record in previous" :key="record.id" class="summary-box history-card">
              <div class="history-card-header">
                <div>
                  <h4>{{ record.class_name }}</h4><p v-if="record.start_time_snapshot">{{t('agreements.schedule')}}: {{timeShort(record.start_time_snapshot)}} – {{timeShort(record.end_time_snapshot)}}</p>
                  <p class="small muted">{{ t('registration.lastMonth') }}: <strong>{{ record.year_month }}</strong> · {{ record.teacher_name }}</p>
                </div>
                <div class="history-badges">
                  <span v-if="latest(record)" class="badge info">{{ t('agreements.suggestion') }}</span>
                  <span v-if="!financiallyApproved(record)" class="badge warning">{{ t('registration.previousAgreementNotApproved') }}</span>
                  <span v-if="record.scholarship" class="badge info">{{ t('agreements.scholarship') }}</span>
                  <!-- Show whether teacher share was standard 50% or manual exception -->
                  <span v-if="record.is_exception" class="badge warning">{{ t('agreements.approvedException') }}</span>
                  <span v-else class="badge success">{{ t('agreements.standard50') }}</span>
                  <span :class="['badge', accountPaymentStatus(record)==='paid' ? 'success' : accountPaymentStatus(record)==='sponsored' ? 'info' : accountPaymentStatus(record)==='partial' ? 'warning' : 'danger']">
                    {{ t(accountPaymentStatus(record)==='sponsored' ? 'registration.fullySponsored' : `registration.${accountPaymentStatus(record)}`) }}
                  </span>
                </div>
              </div>

              <dl class="registration-finances">
                <template v-for="field in ['original_fee', 'agreed_fee', 'discount', 'amount_due', 'teacher_entitlement', 'center_entitlement', 'paid_total', 'balance_due']" :key="field">
                  <dt>{{ t(`registration.${field}`) }}</dt>
                  <dd>{{ money(record[field]) }}</dd>
                </template>
                <template v-if="Number(record.institution_funded) > 0">
                  <dt>{{ t('agreements.funded') }}</dt>
                  <dd>{{ money(record.institution_funded) }}</dd>
                </template>
              </dl>

              <div v-if="record.discount_reason || record.notes || record.manual_adjustment_reason" class="history-notes">
                <p v-if="record.discount_reason"><strong>{{ t('agreements.discountReason') }}:</strong> {{ record.discount_reason }}</p>
                <p v-if="record.is_exception && record.manual_adjustment_reason"><strong>{{ t('agreements.exceptionReason') }}:</strong> {{ record.manual_adjustment_reason }}</p>
                <p v-if="record.notes"><strong>{{ t('agreements.notes') }}:</strong> {{ record.notes }}</p>
              </div>

              <!-- 3 Actions: Use previous, Modify previous, Enter new arrangement -->
              <div class="history-actions">
                <button
                  class="btn small-btn primary"
                  type="button"
                  :disabled="!financiallyApproved(record)"
                  @click="applyPreviousArrangement(record, false)"
                >
                  {{ t('agreements.usePrevious') }}
                </button>
                <button
                  class="btn small-btn"
                  type="button"
                  :disabled="!financiallyApproved(record)"
                  @click="applyPreviousArrangement(record, true)"
                >
                  {{ t('agreements.modifyPrevious') }}
                </button>
                <button
                  class="btn small-btn light"
                  type="button"
                  @click="startNewArrangement(record)"
                >
                  {{ t('agreements.newArrangement') }}
                </button>
              </div>
            </article>
            </div>
          </details>
        </section>

        <!-- ============================================== -->
        <!-- SECTION 3: CURRENT MONTH AGREEMENT             -->
        <!-- ============================================== -->
        <section id="current-agreements-section" class="form-section">
          <div class="section-header">
            <span class="section-number">{{ mode === 'returning' && selected ? '3' : '2' }}</span>
            <div>
              <h3>{{ t('agreements.agreementSection') }}</h3>
              <p class="section-subtitle">{{ monthLabel }}</p>
            </div>
          </div>

          <Notice v-if="closed" :message="t('registration.closed')" kind="error" />
          <details class="advanced-controls registration-date-settings">
            <summary>{{ t('registration.advanced') }}</summary>
            <label>{{ t('registration.date') }}
              <input v-model="date" type="date" :min="monthStart(month)" :max="monthEnd" required />
            </label>
          </details>

          <!-- Class Search / Filter -->
          <h3>{{t('agreements.classSection')}}</h3>
        <label class="class-search">
            {{ t('registration.classSearch') }}
            <input v-model="classQuery" :placeholder="t('registration.classSearchPlaceholder')" />
          </label>

          <!-- Class Agreements List -->
          <div v-if="!rows.length" class="empty-classes-notice">
            <p>{{ t('registration.selectClasses') }}</p>
            <button class="btn primary" type="button" @click="rows.push(blankRow())">
              {{ t('registration.addClass') }}
            </button>
          </div>

          <article
            v-for="(row, index) in rows"
            :key="index"
            :class="['summary-box', 'registration-row', row.is_modifying ? 'modifying-highlight' : '']"
          >
            <div class="row-header">
              <span class="row-badge">#{{ index + 1 }}</span>
            <div v-if="row.class_id" class="class-summary-info">
                <h4>{{ classes.find(item => item.id === row.class_id)?.title }}</h4>
                <div class="class-meta-details">
                  <span>{{ t('registration.teacher') }}: <strong>{{ classes.find(item => item.id === row.class_id)?.teacher?.full_name || '—' }}</strong></span>
                  <span>{{ t('agreements.schedule') }}: <strong>{{ classes.find(item => item.id === row.class_id)?.start_time ? `${timeShort(classes.find(item => item.id === row.class_id)?.start_time ?? null)} – ${timeShort(classes.find(item => item.id === row.class_id)?.end_time ?? null)}` : t('agreements.noSchedule') }}</strong></span>
                  <span>{{ t('agreements.referenceFee') }}: <strong>{{ classReferenceFee(classes.find(item => item.id === row.class_id)?.default_fee) }}</strong></span>
                </div>
              </div>
              <button class="btn small-btn danger remove-btn" type="button" @click="rows.splice(index, 1)">
                {{ t('registration.remove') }}
              </button>
            </div>

            <p v-if="row.is_suggestion" class="hint modifying-alert">
              {{ t('agreements.suggestion') }}
            </p>
            <p v-else-if="row.is_modifying" class="hint modifying-alert">
              {{ t('agreements.modifyingHint') }}
            </p>

            <div class="form-grid registration-compact-grid">
              <label class="wide">
                {{ t('registration.class') }}
                <select
                  v-model="row.class_id"
                  required
                  :aria-label="t('registration.class')"
                  @change="onClassSelected(row)"
                >
                  <option value="">{{ t('financialUi.select') }}</option>
                  <option v-for="classItem in visibleClasses" :key="classItem.id" :value="classItem.id" :disabled="mode === 'returning' && alreadyRegisteredClassIds.has(classItem.id)">
                    {{ classItem.title }} · {{ classItem.teacher?.full_name }} · {{ classItem.start_time ? `${timeShort(classItem.start_time)}–${timeShort(classItem.end_time)}` : t('agreements.noSchedule') }}
                  </option>
                </select>
              </label>

              <label>
                {{ t('registration.monthlyFee') }} *
                <input
                  v-model.number="row.agreed_fee"
                  type="number"
                  min="0"
                  step="0.01"
                  required
                  @input="onAgreedFeeChange(row)"
                  :placeholder="t('registration.feeNotSet')"
                />
              </label>

              <label>
                {{ t('registration.discount') }}
                <input
                  v-model.number="row.discount"
                  type="number"
                  min="0"
                  :max="maxDiscount(row)"
                  step="0.01"
                  @input="onDiscountChange(row)"
                />
              </label>

              <label v-if="row.discount > 0" class="wide">
                {{ t('agreements.discountReason') }} *
                <select v-model="row.discount_reason_type" required @change="setDiscountReason(row, row.discount_reason_type || 'other')">
                  <option value="">{{ t('financialUi.select') }}</option>
                  <option value="management">{{ t('agreements.discountManagement') }}</option>
                  <option value="family">{{ t('agreements.discountFamily') }}</option>
                  <option value="scholarship">{{ t('agreements.discountFamilyFull') }}</option>
                  <option value="other">{{ t('agreements.discountOther') }}</option>
                </select>
              </label>
              <label v-if="row.discount > 0 && row.discount_reason_type === 'other'" class="wide">
                {{ t('agreements.discountOtherReason') }} *
                <input v-model="row.discount_reason" required minlength="4" />
              </label>
              <label v-if="row.discount > 0 && row.discount_reason_type !== 'other' && !row.discount_reason_type" class="wide">
                {{ t('agreements.discountOtherReason') }} *
                <input v-model="row.discount_reason" required minlength="4" />
              </label>

              <label>{{ t('registration.payment') }}
                <input v-model.number="row.payment" type="number" min="0" :max="payableAmount(row)" step="0.01" required />
              </label>

              <template v-if="row.payment > 0">
                <label>{{ t('registration.paymentDate') }} *
                  <input v-model="row.paid_on" type="date" :min="monthStart(month)" :max="monthEnd" required />
                </label>
                <label>{{ t('registration.paymentMethod') }} *
                  <select v-model="row.payment_method" required>
                    <option value="">{{ t('registration.choosePaymentMethod') }}</option>
                    <option value="cash">{{ t('financialUi.finance.cash') }}</option>
                    <option value="bank">{{ t('financialUi.finance.bank') }}</option>
                    <option value="other">{{ t('financialUi.expenses.other') }}</option>
                  </select>
                </label>
                <label class="wide">{{ t('registration.paymentReference') }}
                  <input v-model="row.payment_reference" />
                </label>
              </template>

              <label v-if="fee(row) > 0 && row.discount === fee(row)" class="approval-check wide">
                <input v-model="row.sponsored_confirmed" type="checkbox" required />{{ t('agreements.confirmSponsored') }}
              </label>

              <details class="advanced-controls wide">
                <summary>{{ t('registration.advanced') }}</summary>
                <div class="form-grid">
                  <label class="approval-check wide">
                    <input v-model="row.original_fee_is_custom" type="checkbox" @change="!row.original_fee_is_custom && (row.original_fee = row.agreed_fee)" />
                    {{ t('registration.differentOriginalFee') }}
                  </label>
                  <label v-if="row.original_fee_is_custom">
                    {{ t('registration.original_fee') }}
                    <input v-model.number="row.original_fee" type="number" min="0" step="0.01" required />
                  </label>
                  <label class="approval-check wide"><input v-model="row.is_exception" type="checkbox" />{{ t('agreements.customShare') }}</label>
                  <label>
                    {{ t('registration.teacher_entitlement') }} · {{ t('agreements.recommendedShare') }}
                    <input v-model.number="row.teacher_entitlement" type="number" min="0" step="0.01" required :readonly="!row.is_exception" />
                  </label>
                  <label v-if="row.is_exception" class="wide highlight-field">
                    {{ t('agreements.exceptionReason') }} *
                    <input v-model="row.exception_reason" required minlength="4" :placeholder="t('agreements.exceptionReasonPlaceholder')" />
                  </label>
                  <label class="wide">
                    {{ t('agreements.notes') }}
                    <textarea v-model="row.arrangement_notes" rows="2" />
                  </label>
                </div>
              </details>
            </div>

          </article>

          <p v-if="classQuery && !visibleClasses.length" class="hint">
            {{ t('registration.noClassesMatch') }}
          </p>

          <button class="btn" type="button" @click="rows.push(blankRow())">+ {{ t('registration.addClass') }}</button>
        </section>

        <!-- ============================================== -->
        <!-- SECTION 5: FINAL ADMINISTRATOR CONFIRMATION    -->
        <!-- ============================================== -->
        <section v-if="rows.length" class="form-section confirmation-section">
          <div class="section-header"><span class="section-number">✓</span><div><h3>{{ t('agreements.approvalSection') }}</h3><p class="section-subtitle">{{ auth.profile.value?.full_name || 'Administrator' }}</p></div></div>
          <div class="totals-strip">
            <div class="stat-line"><span>{{ t('registration.monthlyFee') }}</span><strong>{{ money(totalAgreed) }}</strong></div>
            <div class="stat-line"><span>{{ t('registration.discount') }}</span><strong>- {{ money(totalDiscount) }}</strong></div>
            <div class="stat-line"><span>{{ t('agreements.totalPayable') }}</span><strong class="positive">{{ money(totalPayable) }}</strong></div>
            <div class="stat-line"><span>{{ t('agreements.totalPayment') }}</span><strong>{{ money(totalPayment) }}</strong></div>
            <div class="stat-line"><span>{{ t('agreements.totalBalance') }}</span><strong class="caution">{{ money(totalBalance) }}</strong></div>
          </div>
        <div class="form-footer">
            <button
              class="btn primary large-btn"
              :disabled="saving || loading || closed || !rows.length || !isAdmin || (mode==='new' && duplicateMatches.length>0 && !duplicateConfirmed)"
            >
              {{ saving ? t('common.loading') : t('agreements.confirmRegister') }}
            </button>
          </div>
        </section>

      </fieldset>
    </form>
  </section>
</template>

<style scoped>
.monthly-registration {
  margin: 24px 0;
  border-top: 4px solid #6366f1;
}
.card-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  flex-wrap: wrap;
  gap: 16px;
}
.month-selector {
  display: flex;
  align-items: center;
  gap: 8px;
  font-weight: 500;
}
.registration-heading {
  display: flex;
  justify-content: space-between;
  align-items: center;
  flex-wrap: wrap;
  gap: 12px;
  margin: 16px 0;
}
.heading-month {
  display: flex;
  align-items: center;
  gap: 10px;
}
.policy-banner {
  margin-bottom: 24px;
}
.advanced-controls { border: 1px solid #e8ebf3; border-radius: 10px; padding: 12px 15px; background: #fbfcff; }
.advanced-controls summary { cursor: pointer; color: #4e5a75; font-size: 13px; font-weight: 700; }
.advanced-controls[open] summary { margin-bottom: 14px; }
.policy-subnote {
  margin-top: 6px;
  font-size: 0.88rem;
  opacity: 0.9;
}
.registration-fields {
  border: 0;
  padding: 0;
  min-width: 0;
}

/* Sections */
.form-section {
  background: rgba(255, 255, 255, 0.02);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 8px;
  padding: 20px;
  margin-bottom: 24px;
}
.section-header {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-bottom: 16px;
}
.section-number {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 28px;
  height: 28px;
  background: #6366f1;
  color: #fff;
  border-radius: 50%;
  font-weight: 700;
  font-size: 0.9rem;
}
.section-header h3 {
  margin: 0;
  font-size: 1.15rem;
}
.section-subtitle {
  margin: 2px 0 0;
  font-size: 0.85rem;
  color: #94a3b8;
}

/* Tabs & Search */
.registration-tabs {
  display: flex;
  gap: 12px;
  margin-bottom: 16px;
}
.student-search-input {
  max-width: 520px;
}
.registration-results {
  max-height: 260px;
  overflow-y: auto;
  border: 1px solid rgba(255, 255, 255, 0.1);
  border-radius: 6px;
  margin-top: 8px;
}
.registration-results .quick-item {
  width: 100%;
  text-align: start;
  cursor: pointer;
  background: transparent;
  border: none;
  border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  padding: 10px 14px;
  display: flex;
  flex-direction: column;
  gap: 4px;
}
.registration-results .quick-item:hover {
  background: rgba(99, 102, 241, 0.1);
}

/* Selected Student Profile Card */
.student-profile-card {
  background: rgba(99, 102, 241, 0.06);
  border: 1px solid rgba(99, 102, 241, 0.2);
  border-radius: 8px;
  padding: 16px;
  margin-top: 16px;
}
.profile-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 10px;
}
.profile-header h4 {
  margin: 0 0 4px;
  font-size: 1.1rem;
}
.profile-details {
  display: flex;
  flex-wrap: wrap;
  gap: 16px;
  font-size: 0.9rem;
}

/* History Cards */
.registration-history {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(100%, 320px), 1fr));
  gap: 16px;
  margin-top: 16px;
}
.history-card {
  display: flex;
  flex-direction: column;
  justify-content: space-between;
}
.history-card-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 8px;
  margin-bottom: 12px;
}
.history-card-header h4 {
  margin: 0;
  font-size: 1.05rem;
}
.history-badges {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 4px;
}
.history-notes {
  margin: 10px 0;
  font-size: 0.85rem;
  background: rgba(0, 0, 0, 0.1);
  padding: 8px;
  border-radius: 4px;
}
.history-notes p {
  margin: 2px 0;
}
.history-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-top: 14px;
  padding-top: 10px;
  border-top: 1px solid rgba(255, 255, 255, 0.08);
}
.empty-history-callout {
  padding: 16px;
  color: #94a3b8;
  font-style: italic;
}

/* Current Month Class Agreements */
.date-row {
  margin-bottom: 16px;
}
.class-search {
  max-width: 480px;
  margin-bottom: 20px;
}
.empty-classes-notice {
  text-align: center;
  padding: 30px;
  background: rgba(0, 0, 0, 0.1);
  border-radius: 8px;
}
.registration-row {
  margin-bottom: 20px;
  border-left: 4px solid #6366f1;
}
.registration-row.modifying-highlight {
  border-left-color: #f59e0b;
}
.row-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 12px;
  margin-bottom: 14px;
}
.row-badge {
  background: #6366f1;
  color: #fff;
  font-weight: 700;
  font-size: 0.8rem;
  padding: 2px 8px;
  border-radius: 4px;
}
.class-summary-info {
  flex: 1;
}
.class-summary-info h4 {
  margin: 0 0 4px;
  font-size: 1.1rem;
}
.class-meta-details {
  display: flex;
  flex-wrap: wrap;
  gap: 16px;
  font-size: 0.85rem;
  color: #94a3b8;
}
.modifying-alert {
  background: rgba(245, 158, 11, 0.1);
  border-left: 3px solid #f59e0b;
  padding: 6px 10px;
  margin-bottom: 12px;
}

/* Teacher Share Control */
.teacher-share-control {
  display: flex;
  flex-direction: column;
}
.share-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 4px;
}
.share-status {
  display: flex;
  gap: 6px;
  align-items: center;
}

/* Calculations Display */
.calculation-box {
  background: rgba(0, 0, 0, 0.15);
  border-radius: 6px;
  padding: 14px;
  margin: 16px 0;
}
.calculation-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 10px;
}
.registration-finances {
  display: grid;
  grid-template-columns: 1fr auto;
  gap: 6px;
  font-size: 0.95rem;
  margin: 0;
}
.registration-finances dd {
  margin: 0;
  font-weight: 600;
  text-align: end;
}
.registration-finances .negative {
  color: #f43f5e;
}
.highlight-dt, .highlight-dd {
  color: #38bdf8 !important;
  font-weight: 700 !important;
}

/* Initial Payment Box */
.initial-payment-box {
  background: rgba(255, 255, 255, 0.02);
  border: 1px dashed rgba(255, 255, 255, 0.15);
  border-radius: 6px;
  padding: 14px;
  margin-top: 14px;
}
.initial-payment-box h5 {
  margin: 0 0 12px;
  font-size: 0.95rem;
  color: #cbd5e1;
}

/* Totals Strip & Confirmation */
.confirmation-section {
  background: rgba(99, 102, 241, 0.03);
  border-color: rgba(99, 102, 241, 0.2);
}
.totals-strip {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
  gap: 12px;
  background: rgba(0, 0, 0, 0.2);
  border-radius: 8px;
  padding: 16px;
  margin-bottom: 20px;
}
.stat-line {
  display: flex;
  flex-direction: column;
  gap: 4px;
}
.stat-line span {
  font-size: 0.8rem;
  color: #94a3b8;
}
.stat-line strong {
  font-size: 1.1rem;
}
.highlight-stat {
  border-left: 2px solid #38bdf8;
  padding-left: 8px;
}
.approval-check {
  display: flex;
  gap: 12px;
  align-items: center;
  margin: 20px 0;
  cursor: pointer;
  font-size: 1.05rem;
}
.approval-check input {
  width: 20px;
  height: 20px;
}
.form-footer {
  display: flex;
  justify-content: flex-end;
  gap: 12px;
}
.large-btn {
  padding: 10px 24px;
  font-size: 1.05rem;
}
.highlight-field {
  border-color: #f59e0b;
}
</style>
