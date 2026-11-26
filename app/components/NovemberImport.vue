<script setup lang="ts">
import { SearchableSelect } from '#components'
import { AlertCircle, CheckCircle2, DatabaseZap, RefreshCw, Upload } from 'lucide-vue-next'

/** Checksum of the existing November 2026 staging batch. No new staging rows are created. */
const NOVEMBER_BATCH_SHA256 = '15e9b64e02048eba03e59636e2875c56701c0d1160748da7a85e26c8c1e7cc64'
const PAGE_SIZE = 25

interface BlockingReason {
  code: string
  message: string
}

interface Candidate {
  id: string
  source_sheet: string
  source_key: string
  source_row: number
  student_name: string | null
  first_name: string
  last_name: string
  phone: string | null
  proposed_student_id: string | null
  proposed_student_label: string | null
  match_confidence: string | null
  identity_key: string | null
  class_id: string | null
  class_title: string | null
  teacher_name: string | null
  start_time: string | null
  end_time: string | null
  schedule_label: string | null
  source_tuition: number
  source_discount: number
  source_payment: number
  source_payment_date: string | null
  source_payment_reference: string | null
  approved_student_action: 'create' | 'match' | null
  approved_student_id: string | null
  approved_class_id: string | null
  approved_tuition: number | null
  approved_discount: number | null
  approved_discount_reason: string | null
  approved_teacher_entitlement: number | null
  approved_teacher_exception_reason: string | null
  approved_payment: number | null
  approved_payment_date: string | null
  approved_payment_method: 'cash' | 'bank' | 'other' | null
  approved_registered_on: string | null
  approved_note: string | null
  status: 'needs_review' | 'approved' | 'posted' | 'duplicate' | 'rejected'
  blocking_reasons: BlockingReason[]
  review_note: string | null
  student_id: string | null
  membership_id: string | null
  payment_id: string | null
  identity_status: 'pending' | 'created' | 'matched' | 'ambiguous'
  identity_student_id: string | null
  identity_scope: 'group' | 'row' | null
  identity_review_reason: string | null
  enrollment_id: string | null
  approved_payment_verified: boolean
}

interface ClassOption {
  id: string
  title: string
  default_fee: number
  start_time: string | null
  end_time: string | null
  teacherName: string
}

interface StudentOption {
  id: string
  student_code: string
  first_name: string
  last_name: string
}

interface Draft {
  student_action: 'create' | 'match'
  student_id: string
  first_name: string
  last_name: string
  phone: string
  class_id: string
  tuition: string
  discount: string
  discount_reason: string
  teacher_entitlement: string
  teacher_exception_reason: string
  payment: string
  payment_date: string
  payment_method: 'cash' | 'bank' | 'other'
  registered_on: string
  note: string
  identity_scope: 'group' | 'row'
  identity_confirmed: boolean
  distinct_person_confirmed: boolean
  class_confirmed: boolean
  payment_verified: boolean
}

const db = useSupabase()
const auth = useAuth()
const { t } = useLanguage()

const isAdmin = computed(() => auth.profile.value?.role === 'admin')

const candidates = ref<Candidate[]>([])
const classes = ref<ClassOption[]>([])
const students = ref<StudentOption[]>([])
const summary = ref<Record<string, unknown> | null>(null)
const profileSummary = ref<Record<string, unknown> | null>(null)
const drafts = reactive<Record<string, Draft>>({})
const statusFilter = ref('')
const search = ref('')
const page = ref(0)
const loading = ref(false)
const busy = ref(false)
const busyRow = ref('')
const posting = ref(false)
const error = ref('')
const success = ref('')

const queueBuilt = computed(() => candidates.value.length > 0)
const statusOptions = ['needs_review', 'approved', 'posted', 'duplicate', 'rejected'] as const

const filtered = computed(() => {
  const needle = search.value.trim().toLowerCase()
  return candidates.value.filter(row => {
    if (statusFilter.value && row.status !== statusFilter.value) return false
    if (!needle) return true
    return [row.student_name, row.class_title, row.teacher_name, row.source_key]
      .some(value => String(value ?? '').toLowerCase().includes(needle))
  })
})
const visible = computed(() => filtered.value.slice(page.value * PAGE_SIZE, (page.value + 1) * PAGE_SIZE))
const pendingCount = computed(() => candidates.value.filter(row => row.status === 'needs_review').length)
const approvedCount = computed(() => candidates.value.filter(row => row.status === 'approved').length)
const postedCount = computed(() => candidates.value.filter(row => row.status === 'posted').length)

function money(value: unknown) {
  return `PKR ${Number(value ?? 0).toLocaleString('en-US', { maximumFractionDigits: 2 })}`
}

function timeLabel(start: string | null, end: string | null, fallback: string | null) {
  if (start && end) return `${start.slice(0, 5)} – ${end.slice(0, 5)}`
  return fallback || '—'
}

function statusLabel(status: Candidate['status']) {
  return t(`novemberImport.${status}`)
}

function standardShare(tuition: string) {
  const value = Number(tuition || 0)
  return Number.isFinite(value) ? Math.round(value * 50) / 100 : 0
}

function isCustomShare(draft: Draft) {
  return Number(draft.teacher_entitlement || 0) !== standardShare(draft.tuition)
}

function blockedReasons(row: Candidate): BlockingReason[] {
  return Array.isArray(row.blocking_reasons) ? row.blocking_reasons : []
}

function draftFor(row: Candidate): Draft {
  const existing = drafts[row.id]
  if (existing) return existing
  const draft: Draft = {
    student_action: row.identity_student_id ? 'match' : (row.approved_student_action ?? 'create'),
    student_id: row.identity_student_id ?? row.approved_student_id ?? '',
    first_name: row.first_name,
    last_name: row.last_name,
    phone: row.phone ?? '',
    class_id: row.approved_class_id ?? row.class_id ?? '',
    tuition: String(row.approved_tuition ?? row.source_tuition ?? ''),
    discount: String(row.approved_discount ?? row.source_discount ?? 0),
    discount_reason: row.approved_discount_reason ?? '',
    teacher_entitlement: String(
      row.approved_teacher_entitlement ?? standardShare(String(row.approved_tuition ?? row.source_tuition ?? 0))
    ),
    teacher_exception_reason: row.approved_teacher_exception_reason ?? '',
    payment: String(row.approved_payment ?? 0),
    payment_date: row.approved_payment_date ?? '',
    payment_method: row.approved_payment_method ?? 'cash',
    registered_on: row.approved_registered_on ?? '2026-11-01',
    note: row.identity_review_reason ?? row.review_note ?? '',
    identity_scope: row.identity_scope ?? 'group',
    identity_confirmed: row.identity_status !== 'pending',
    distinct_person_confirmed: row.identity_scope === 'row',
    class_confirmed: false,
    payment_verified: row.approved_payment_verified ?? false
  }
  drafts[row.id] = draft
  return draft
}

async function loadReferenceData() {
  if (!db) return
  const classRows = await allRows(() => db.from('class_rooms')
    .select('id,title,default_fee,start_time,end_time,teacher_id')
    .eq('active', true)
    .order('title'))
  const teacherRows = await allRows(() => db.from('teachers').select('id,full_name'))
  const teacherName = new Map(teacherRows.map((row: { id: string; full_name: string }) => [row.id, row.full_name]))
  classes.value = classRows.map((row: { id: string; title: string; default_fee: number; start_time: string | null; end_time: string | null; teacher_id: string }) => ({
    id: row.id,
    title: row.title,
    default_fee: row.default_fee,
    start_time: row.start_time,
    end_time: row.end_time,
    teacherName: String(teacherName.get(row.teacher_id) ?? '')
  }))
  const studentRows = await allRows(() => db.from('students')
    .select('id,student_code,first_name,last_name')
    .order('first_name'))
  students.value = studentRows as StudentOption[]
}

async function loadCandidates() {
  if (!db || !isAdmin.value) return
  const rows = await allRows(() => db.from('november_import_candidates')
    .select('*')
    .order('source_sheet')
    .order('source_row'))
  candidates.value = rows as Candidate[]
  for (const key of Object.keys(drafts)) delete drafts[key]
  page.value = 0
}

async function loadSummary() {
  if (!db || !isAdmin.value) return
  const result = await db.rpc('november_import_summary', { p_sha256: NOVEMBER_BATCH_SHA256 })
  if (result.error) throw result.error
  summary.value = (result.data || null) as Record<string, unknown> | null
  const profiles = await db.rpc('november_import_profile_summary', { p_sha256: NOVEMBER_BATCH_SHA256 })
  if (profiles.error) throw profiles.error
  profileSummary.value = (profiles.data || null) as Record<string, unknown> | null
}

async function refreshAll() {
  if (!db || !isAdmin.value || loading.value) return
  loading.value = true
  error.value = ''
  try {
    await loadCandidates()
    await loadSummary()
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    loading.value = false
  }
}

async function buildQueue() {
  if (!db || !isAdmin.value || busy.value) return
  busy.value = true
  error.value = ''
  success.value = ''
  try {
    const result = await db.rpc('build_november_import_candidates', { p_sha256: NOVEMBER_BATCH_SHA256 })
    if (result.error) throw result.error
    const data = (result.data || {}) as Record<string, number>
    await refreshAll()
    success.value = t('novemberImport.queueBuilt', {
      candidates: data.candidates ?? 0,
      ready: data.ready_to_approve ?? 0,
      needsInfo: Math.max(0, (data.needs_review ?? 0) - (data.ready_to_approve ?? 0))
    })
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    busy.value = false
  }
}

async function approveRow(row: Candidate) {
  if (!db || !isAdmin.value || busyRow.value) return
  const draft = draftFor(row)
  if (draft.note.trim().length < 4) {
    error.value = t('novemberImport.reasonRequired')
    return
  }
  busyRow.value = row.id
  error.value = ''
  success.value = ''
  try {
    if (Number(draft.payment) > 0) {
      if (!draft.payment_verified) throw new Error(t('novemberImport.verifyPaymentFirst'))
      const paymentCheck = await db.rpc('november_import_verify_payment', {
        p_candidate: row.id,
        p_amount: draft.payment,
        p_paid_on: draft.payment_date,
        p_reason: draft.note.trim()
      })
      if (paymentCheck.error) throw paymentCheck.error
    }
    const payload = {
      student_action: draft.student_action,
      student_id: draft.student_action === 'match' ? draft.student_id || null : null,
      first_name: draft.first_name,
      last_name: draft.last_name,
      phone: draft.phone,
      class_id: draft.class_id,
      tuition: draft.tuition,
      discount: draft.discount,
      discount_reason: draft.discount_reason,
      teacher_entitlement: draft.teacher_entitlement,
      teacher_exception_reason: draft.teacher_exception_reason,
      payment: draft.payment,
      payment_date: draft.payment_date || null,
      payment_method: draft.payment_method,
      registered_on: draft.registered_on,
      note: draft.note
    }
    const result = await db.rpc('november_import_approve', { p_candidate: row.id, p_payload: payload })
    if (result.error) throw result.error
    const data = (result.data || {}) as { status?: string }
    success.value = data.status === 'duplicate'
      ? t('novemberImport.approvedDuplicate')
      : t('novemberImport.approvedSaved')
    await refreshAll()
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    busyRow.value = ''
  }
}

function sameIdentityCount(row: Candidate) {
  return row.identity_key
    ? candidates.value.filter(candidate => candidate.identity_key === row.identity_key).length
    : 1
}

async function saveProfile(row: Candidate) {
  if (!db || !isAdmin.value || busyRow.value) return
  const draft = draftFor(row)
  const peers = sameIdentityCount(row)
  if (!draft.identity_confirmed || draft.note.trim().length < 4) {
    error.value = t('novemberImport.identityConfirmRequired')
    return
  }
  if (draft.identity_scope === 'row' && peers > 1 && !draft.distinct_person_confirmed) {
    error.value = t('novemberImport.distinctPersonRequired')
    return
  }
  if (draft.identity_scope === 'group' && peers > 1 && !window.confirm(t('novemberImport.confirmIdentityGroup', { count: peers }))) return
  if (draft.class_confirmed && !draft.class_id) {
    error.value = t('novemberImport.classRequired')
    return
  }
  busyRow.value = row.id
  error.value = ''
  success.value = ''
  try {
    const result = await db.rpc('november_import_save_profile', {
      p_candidate: row.id,
      p_payload: {
        action: draft.student_action,
        student_id: draft.student_action === 'match' ? draft.student_id || null : null,
        first_name: draft.first_name,
        last_name: draft.last_name,
        phone: draft.phone,
        scope: draft.identity_scope,
        identity_confirmed: draft.identity_confirmed,
        distinct_person_confirmed: draft.distinct_person_confirmed,
        class_id: draft.class_id || null,
        class_confirmed: draft.class_confirmed,
        reason: draft.note
      }
    })
    if (result.error) throw result.error
    const data = (result.data || {}) as { profile_created?: boolean; linked_candidates?: number; enrollment_id?: string | null }
    success.value = t(data.profile_created ? 'novemberImport.profileCreated' : 'novemberImport.profileMatched', {
      linked: data.linked_candidates ?? 1,
      enrollment: data.enrollment_id ? 1 : 0
    })
    await refreshAll()
    await loadReferenceData()
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    busyRow.value = ''
  }
}

async function postApproved() {
  if (!db || !isAdmin.value || posting.value) return
  if (approvedCount.value < 1) {
    error.value = t('novemberImport.nothingToPost')
    return
  }
  if (!window.confirm(t('novemberImport.confirmPost'))) return
  posting.value = true
  error.value = ''
  success.value = ''
  const total = { posted: 0, duplicates: 0, failed: 0, studentsCreated: 0, payments: 0 }
  try {
    for (let attempt = 0; attempt < 12; attempt += 1) {
      const result = await db.rpc('november_import_post', { p_limit: 50, p_request: null })
      if (result.error) throw result.error
      const data = (result.data || {}) as Record<string, number>
      total.posted += data.posted ?? 0
      total.duplicates += data.duplicates ?? 0
      total.failed += data.failed ?? 0
      total.studentsCreated += data.students_created ?? 0
      total.payments += data.payments_recorded ?? 0
      if (!data.remaining_approved) break
      if (!(data.posted || data.duplicates || data.failed)) break
    }
    await refreshAll()
    success.value = total.posted + total.duplicates > 0
      ? t('novemberImport.postingDone', {
        posted: total.posted,
        duplicates: total.duplicates,
        failed: total.failed,
        studentsCreated: total.studentsCreated,
        payments: total.payments
      })
      : t('novemberImport.postingFailed')
  } catch (cause) {
    error.value = errText(cause)
    await refreshAll().catch(() => undefined)
  } finally {
    posting.value = false
  }
}

watch([statusFilter, search], () => { page.value = 0 })

onMounted(async () => {
  if (!db || !isAdmin.value) return
  loading.value = true
  try {
    await loadReferenceData()
    await loadCandidates()
    await loadSummary()
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    loading.value = false
  }
})
</script>

<template>
  <section v-if="isAdmin" class="november-import card">
    <header class="import-heading">
      <div>
        <h2>{{ t('novemberImport.title') }}</h2>
        <p>{{ t('novemberImport.subtitle') }}</p>
      </div>
      <button class="btn" :disabled="loading || busy" @click="refreshAll">{{ t('novemberImport.refresh') }}</button>
    </header>
    <Notice :message="error" kind="error" />
    <Notice :message="success" kind="success" />
    <p class="hint">{{ t('novemberImport.checksumNote') }}</p>

    <div class="profile-summary">
      <span>{{ t('novemberImport.sourceCandidates') }}: <strong>{{ profileSummary?.source_registration_candidates ?? '—' }}</strong></span>
      <span>{{ t('novemberImport.profilesCreated') }}: <strong>{{ profileSummary?.profiles_created ?? 0 }}</strong></span>
      <span>{{ t('novemberImport.profilesMatched') }}: <strong>{{ profileSummary?.profiles_matched ?? 0 }}</strong></span>
      <span>{{ t('novemberImport.identityPending') }}: <strong>{{ profileSummary?.identities_pending ?? 0 }}</strong></span>
      <span>{{ t('novemberImport.novemberEnrollments') }}: <strong>{{ profileSummary?.november_enrollments ?? 0 }}</strong></span>
      <span>{{ t('novemberImport.financialReview') }}: <strong>{{ profileSummary?.financial_review ?? 0 }}</strong></span>
    </div>

    <div class="toolbar">
      <button v-if="!queueBuilt" class="btn primary" :disabled="busy || loading" @click="buildQueue">{{ t('novemberImport.buildQueue') }}</button>
      <label>{{ t('novemberImport.filterStatus') }}
        <select v-model="statusFilter"><option value="">{{ t('novemberImport.filterAll') }}</option><option v-for="value in statusOptions" :key="value" :value="value">{{ statusLabel(value) }}</option></select>
      </label>
      <label class="search-label">{{ t('novemberImport.search') }}<input v-model="search" /></label>
      <span>{{ t('novemberImport.showing', { start: filtered.length ? page * PAGE_SIZE + 1 : 0, end: Math.min((page + 1) * PAGE_SIZE, filtered.length), total: filtered.length }) }}</span>
    </div>

    <div v-if="loading" class="empty">{{ t('novemberImport.loading') }}</div>
    <div v-else-if="!candidates.length" class="empty">{{ t('novemberImport.queueNotBuilt') }}</div>
    <div v-else-if="!visible.length" class="empty">{{ t('novemberImport.noCandidates') }}</div>
    <article v-for="row in visible" :key="row.id" class="candidate-card">
      <div class="candidate-heading">
        <div>
          <strong>{{ row.student_name || `${row.first_name} ${row.last_name}` }}</strong>
          <small dir="ltr">{{ row.source_sheet }} · {{ row.source_row }} · {{ row.source_key }}</small>
        </div>
        <div class="badges"><span class="badge" :class="row.identity_status === 'pending' ? 'warning' : 'success'">{{ t(`novemberImport.identity_${row.identity_status}`) }}</span><span class="badge">{{ statusLabel(row.status) }}</span></div>
      </div>
      <div class="source-details">
        <span>{{ t('novemberImport.class') }}: <strong>{{ row.class_title || '—' }}</strong></span>
        <span>{{ t('novemberImport.teacher') }}: <strong>{{ row.teacher_name || '—' }}</strong></span>
        <span>{{ t('novemberImport.schedule') }}: <strong>{{ timeLabel(row.start_time, row.end_time, row.schedule_label) }}</strong></span>
        <span>{{ t('novemberImport.sourceTuition') }}: {{ money(row.source_tuition) }}</span>
        <span>{{ t('novemberImport.sourceDiscount') }}: {{ money(row.source_discount) }}</span>
        <span>{{ t('novemberImport.sourcePayment') }}: {{ money(row.source_payment) }} ({{ row.source_payment_date || '—' }})</span>
      </div>
      <p v-if="row.proposed_student_label" class="hint">{{ t('novemberImport.proposedMatch') }}: {{ row.proposed_student_label }}. {{ t('novemberImport.matchWarning') }}</p>
      <p v-if="blockedReasons(row).length" class="hint warning-text">{{ blockedReasons(row).map(reason => reason.message).join(' ') }}</p>

      <div v-if="row.identity_status === 'pending' || row.identity_status === 'ambiguous'" class="profile-review">
        <h3>{{ t('novemberImport.identityFirst') }}</h3>
        <div class="form-grid">
          <label>{{ t('novemberImport.identity') }}
            <select v-model="draftFor(row).student_action"><option value="create">{{ t('novemberImport.createNew') }}</option><option value="match">{{ t('novemberImport.matchExisting') }}</option></select>
          </label>
          <label v-if="draftFor(row).student_action === 'match'">{{ t('novemberImport.selectStudent') }}
            <SearchableSelect v-model="draftFor(row).student_id" :options="students" label-key="first_name" :search-keys="['last_name','student_code']" :placeholder="t('financialUi.select')" :min-chars="2" required selected-suffix-key="student_code"><template #option="{option}">{{option.student_code}} · {{option.first_name}} {{option.last_name}}</template></SearchableSelect>
          </label>
          <template v-if="draftFor(row).student_action === 'create'">
            <label>{{ t('students.form.firstName') }}<input v-model="draftFor(row).first_name" /></label>
            <label>{{ t('students.form.lastName') }}<input v-model="draftFor(row).last_name" /></label>
            <label>{{ t('common.phone') }}<input v-model="draftFor(row).phone" /></label>
          </template>
          <label>{{ t('novemberImport.identityScope') }}
            <select v-model="draftFor(row).identity_scope"><option value="group">{{ t('novemberImport.samePersonGroup', { count: sameIdentityCount(row) }) }}</option><option value="row">{{ t('novemberImport.separateSourceRow') }}</option></select>
          </label>
          <label>{{ t('novemberImport.class') }}
            <SearchableSelect v-model="draftFor(row).class_id" :options="classes" label-key="title" :search-keys="['teacherName','start_time']" :placeholder="t('novemberImport.selectClass')" :allow-empty="true" :empty-label="t('novemberImport.noClassYet')"><template #option="{option}">{{option.title}} · {{option.teacherName}} · {{timeLabel(option.start_time, option.end_time, null)}}</template></SearchableSelect>
          </label>
          <label class="wide">{{ t('novemberImport.note') }}<input v-model="draftFor(row).note" minlength="4" /></label>
        </div>
        <label class="approval-check"><input v-model="draftFor(row).identity_confirmed" type="checkbox" />{{ t('novemberImport.confirmIdentity') }}</label>
        <label v-if="sameIdentityCount(row) > 1 && draftFor(row).identity_scope === 'row'" class="approval-check"><input v-model="draftFor(row).distinct_person_confirmed" type="checkbox" />{{ t('novemberImport.confirmDistinctPerson') }}</label>
        <label v-if="draftFor(row).class_id" class="approval-check"><input v-model="draftFor(row).class_confirmed" type="checkbox" />{{ t('novemberImport.confirmClass') }}</label>
        <button class="btn primary" :disabled="busyRow === row.id" @click="saveProfile(row)">{{ busyRow === row.id ? t('common.saving') : t('novemberImport.saveProfile') }}</button>
      </div>

      <details v-if="row.source_sheet === 'Registrations' && (row.identity_status === 'created' || row.identity_status === 'matched')" class="finance-review">
        <summary>{{ t('novemberImport.financialApproval') }}</summary>
        <p class="hint">{{ t('novemberImport.financeHint') }}</p>
        <div class="form-grid">
          <label>{{ t('novemberImport.class') }}
            <SearchableSelect v-model="draftFor(row).class_id" :options="classes" label-key="title" :search-keys="['teacherName','start_time']" :placeholder="t('novemberImport.selectClass')" required><template #option="{option}">{{option.title}} · {{option.teacherName}} · {{timeLabel(option.start_time, option.end_time, null)}}</template></SearchableSelect>
          </label>
          <label>{{ t('novemberImport.tuition') }}<input v-model="draftFor(row).tuition" type="number" min="0" step="0.01" /></label>
          <label>{{ t('novemberImport.discount') }}<input v-model="draftFor(row).discount" type="number" min="0" step="0.01" /></label>
          <label>{{ t('novemberImport.discountReason') }}<input v-model="draftFor(row).discount_reason" /></label>
          <label>{{ t('novemberImport.teacherEntitlement') }}<input v-model="draftFor(row).teacher_entitlement" type="number" min="0" step="0.01" /></label>
          <label>{{ t('novemberImport.exceptionReason') }}<input v-model="draftFor(row).teacher_exception_reason" /></label>
          <label>{{ t('novemberImport.payment') }}<input v-model="draftFor(row).payment" type="number" min="0" step="0.01" /></label>
          <label>{{ t('novemberImport.paymentDate') }}<input v-model="draftFor(row).payment_date" type="date" /></label>
          <label>{{ t('novemberImport.registeredOn') }}<input v-model="draftFor(row).registered_on" type="date" /></label>
          <label class="wide">{{ t('novemberImport.note') }}<input v-model="draftFor(row).note" minlength="4" /></label>
        </div>
        <label v-if="row.source_payment > 0" class="approval-check"><input v-model="draftFor(row).payment_verified" type="checkbox" />{{ t('novemberImport.verifyPayment') }}: {{ row.source_payment_reference || row.source_key }}</label>
        <button class="btn primary" :disabled="busyRow === row.id" @click="approveRow(row)">{{ t('novemberImport.approve') }}</button>
      </details>
      <div v-if="(row.identity_status === 'created' || row.identity_status === 'matched') && !row.enrollment_id" class="profile-review">
        <h3>{{ t('novemberImport.linkClassOnly') }}</h3>
        <label>{{ t('novemberImport.class') }}
          <SearchableSelect v-model="draftFor(row).class_id" :options="classes" label-key="title" :search-keys="['teacherName','start_time']" :placeholder="t('novemberImport.selectClass')" required><template #option="{option}">{{option.title}} · {{option.teacherName}} · {{timeLabel(option.start_time, option.end_time, null)}}</template></SearchableSelect>
        </label>
        <label class="approval-check"><input v-model="draftFor(row).class_confirmed" type="checkbox" />{{ t('novemberImport.confirmClass') }}</label>
        <label>{{ t('novemberImport.note') }}<input v-model="draftFor(row).note" minlength="4" /></label>
        <button class="btn" :disabled="busyRow === row.id" @click="saveProfile(row)">{{ t('novemberImport.saveClassLink') }}</button>
      </div>
    </article>

    <footer class="pagination"><button class="btn" :disabled="page === 0" @click="page--">{{ t('novemberImport.previous') }}</button><button class="btn" :disabled="(page + 1) * PAGE_SIZE >= filtered.length" @click="page++">{{ t('novemberImport.next') }}</button></footer>
  </section>
</template>

<style scoped>
.november-import { margin: 0 0 24px; }
.import-heading,.candidate-heading,.toolbar,.pagination { display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap; }
.import-heading p { margin:.3rem 0 0; }
.profile-summary,.source-details,.badges { display:flex;gap:10px 18px;flex-wrap:wrap; }
.profile-summary { padding:12px;background:rgba(0,0,0,.12);border-radius:8px;margin:14px 0; }
.toolbar { margin:14px 0; }
.toolbar label { display:flex;align-items:center;gap:8px; }
.search-label input { min-width:220px; }
.candidate-card { border:1px solid rgba(255,255,255,.12);border-radius:8px;padding:16px;margin:12px 0; }
.candidate-heading small { display:block;opacity:.75;margin-top:4px; }
.source-details { font-size:.9rem;margin:12px 0; }
.profile-review,.finance-review { border-top:1px solid rgba(255,255,255,.12);padding-top:12px;margin-top:12px; }
.profile-review h3 { margin:0 0 12px; }
.approval-check { display:flex;align-items:center;gap:8px;margin:10px 0; }
.pagination { justify-content:flex-end;margin-top:16px; }
.warning-text { color:#fbbf24; }
</style>
