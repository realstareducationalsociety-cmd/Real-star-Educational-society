<script setup lang="ts">
import { SearchableSelect } from '#components'
import { RefreshCw } from 'lucide-vue-next'

interface FeeCandidate {
  candidate_id: string
  source_key: string
  source_row: number
  student_code: string | null
  first_name: string | null
  last_name: string | null
  student_name: string | null
  student_id: string | null
  enrollment_id: string | null
  class_id: string | null
  current_class: string | null
  current_teacher: string | null
  start_time: string | null
  end_time: string | null
  source_tuition_text: string | null
  source_discount_text: string | null
  fee_proposal: number | null
  discount_proposal: number | null
  proposed_payable: number | null
  review_flag: string
  existing_november_membership_id: string | null
  import_status: string
}

interface FeeDraft {
  original_fee: string
  agreed_fee: string
  discount: string
  discount_reason: string
  teacher_entitlement: string
  teacher_exception: boolean
  teacher_exception_reason: string
  registration_date: string
  notes: string
  zero_fee_reason: string
  sponsored_confirmed: boolean
}

interface StudentReference { id: string; student_code: string; first_name: string; last_name: string }
interface ClassReference { id: string; title: string; teacher_id: string; teacher_name: string; start_time: string | null; end_time: string | null }
interface LinkDraft { student_id: string; class_id: string; reason: string }

const db = useSupabase()
const auth = useAuth()
const { t } = useLanguage()
const requestKey = useRequestKey()
const rows = ref<FeeCandidate[]>([])
const drafts = reactive<Record<string, FeeDraft>>({})
const linkDrafts = reactive<Record<string, LinkDraft>>({})
const existingStudents = ref<StudentReference[]>([])
const activeClasses = ref<ClassReference[]>([])
const selectedIds = ref<string[]>([])
const search = ref('')
const loading = ref(false)
const saving = ref(false)
const error = ref('')
const success = ref('')
const leadCount = ref<number | null>(null)
const monthlyCount = ref<number | null>(null)
const paymentCount = ref<number | null>(null)
const unverifiedReceiptCount = ref<number | null>(null)
const isAdmin = computed(() => auth.profile.value?.role === 'admin')
const linkedCount = computed(() => rows.value.filter(row => row.student_id && row.enrollment_id).length)
const reviewLinkCount = computed(() => rows.value.length - linkedCount.value)
const filtered = computed(() => {
  const q = search.value.trim().toLocaleLowerCase()
  return rows.value.filter(row => !q || [row.student_name, row.first_name, row.last_name, row.student_code, row.current_class, row.current_teacher, row.source_key]
    .some(value => String(value ?? '').toLocaleLowerCase().includes(q)))
})
const selectedRows = computed(() => rows.value.filter(row => selectedIds.value.includes(row.candidate_id)))
const needsIdentityClassReview = computed(() => rows.value.filter(row =>
  (!row.student_id || !row.enrollment_id) && !['duplicate', 'rejected', 'posted'].includes(row.import_status)
))

function normalizeTeacher(value: string | null) {
  return String(value ?? '').toLocaleLowerCase().replace(/[^a-z]/g, '')
}
function manualTeacher(row: FeeCandidate) {
  return /^tah[ei]rasakhizada$/.test(normalizeTeacher(row.current_teacher))
}
function eligible(row: FeeCandidate) {
  return !!row.student_id && !!row.enrollment_id && !row.existing_november_membership_id
    && !manualTeacher(row) && !['duplicate', 'rejected', 'posted'].includes(row.import_status)
}
function money(value: unknown) {
  const amount = Number(value)
  return Number.isFinite(amount) ? `PKR ${amount.toLocaleString('en-US', { maximumFractionDigits: 2 })}` : '—'
}
function draftFor(row: FeeCandidate): FeeDraft {
  if (drafts[row.candidate_id]) return drafts[row.candidate_id]!
  const suggestedFee = row.fee_proposal == null ? '' : String(row.fee_proposal)
  const draft: FeeDraft = {
    original_fee: suggestedFee,
    agreed_fee: suggestedFee,
    discount: row.discount_proposal == null ? '' : String(row.discount_proposal),
    discount_reason: '',
    teacher_entitlement: suggestedFee ? String(Math.round(Number(suggestedFee) * 50) / 100) : '0',
    teacher_exception: false,
    teacher_exception_reason: '',
    registration_date: '2026-11-22',
    notes: '',
    zero_fee_reason: '',
    sponsored_confirmed: false
  }
  drafts[row.candidate_id] = draft
  return draft
}
function linkDraftFor(row: FeeCandidate): LinkDraft {
  return linkDrafts[row.candidate_id] ??= { student_id: row.student_id ?? '', class_id: row.class_id ?? '', reason: '' }
}
function classLabel(item: ClassReference) {
  const schedule = item.start_time && item.end_time ? ` · ${item.start_time.slice(0, 5)}–${item.end_time.slice(0, 5)}` : ''
  return `${item.title} · ${item.teacher_name}${schedule}`
}
async function linkExisting(row: FeeCandidate) {
  if (!db || !isAdmin.value || saving.value) return
  const draft = linkDraftFor(row)
  if (!draft.student_id || !draft.class_id || draft.reason.trim().length < 4) {
    error.value = t('novemberFinalize.linkRequired')
    return
  }
  saving.value = true
  error.value = ''
  try {
    const result = await db.rpc('november_link_existing_roster_candidate', {
      p_candidate: row.candidate_id, p_student: draft.student_id, p_class: draft.class_id, p_reason: draft.reason.trim()
    })
    if (result.error) throw result.error
    success.value = t('novemberFinalize.linkSaved')
    await load()
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    saving.value = false
  }
}
function updateFee(row: FeeCandidate) {
  const draft = draftFor(row)
  if (!draft.teacher_exception) draft.teacher_entitlement = String(Math.round(Number(draft.agreed_fee || 0) * 50) / 100)
  if (Number(draft.agreed_fee) !== Number(draft.discount)) draft.sponsored_confirmed = false
}
function toggle(row: FeeCandidate, value: boolean) {
  selectedIds.value = value
    ? [...new Set([...selectedIds.value, row.candidate_id])]
    : selectedIds.value.filter(id => id !== row.candidate_id)
  if (value) draftFor(row)
}
function timeLabel(row: FeeCandidate) {
  return row.start_time && row.end_time ? `${row.start_time.slice(0, 5)}–${row.end_time.slice(0, 5)}` : '—'
}

async function load() {
  if (!db || !isAdmin.value || loading.value) return
  loading.value = true
  error.value = ''
  try {
    const [queue, summary, leads, students, classes, teachers, receipts] = await Promise.all([
      allRows(() => db.from('november_2026_fee_approval_queue').select('*').order('source_row')),
      db.rpc('november_import_summary', { p_sha256: '15e9b64e02048eba03e59636e2875c56701c0d1160748da7a85e26c8c1e7cc64' }),
      db.from('november_import_candidates').select('id', { count: 'exact', head: true }).eq('source_sheet', 'RegistrationLeads'),
      allRows(() => db.from('students').select('id,student_code,first_name,last_name').order('first_name')),
      allRows(() => db.from('class_rooms').select('id,title,teacher_id,start_time,end_time').eq('active', true).order('title')),
      allRows(() => db.from('teachers').select('id,full_name')),
      db.from('november_import_candidates').select('id', { count: 'exact', head: true }).gt('source_payment', 0).eq('approved_payment_verified', false)
    ])
    if (summary.error || leads.error || receipts.error) throw summary.error || leads.error || receipts.error
    rows.value = queue as FeeCandidate[]
    const teacherNames = new Map((teachers as { id: string; full_name: string }[]).map(teacher => [teacher.id, teacher.full_name]))
    existingStudents.value = students as StudentReference[]
    activeClasses.value = (classes as Omit<ClassReference, 'teacher_name'>[]).map(item => ({ ...item, teacher_name: teacherNames.get(item.teacher_id) ?? '' }))
    monthlyCount.value = Number(summary.data?.november_memberships ?? 0)
    paymentCount.value = Number(summary.data?.verified_payments ?? 0)
    leadCount.value = leads.count ?? 0
    unverifiedReceiptCount.value = receipts.count ?? 0
    selectedIds.value = selectedIds.value.filter(id => rows.value.some(row => row.candidate_id === id && eligible(row)))
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    loading.value = false
  }
}

function validateDraft(row: FeeCandidate, draft: FeeDraft) {
  const original = Number(draft.original_fee)
  const fee = Number(draft.agreed_fee)
  const discount = Number(draft.discount)
  const entitlement = Number(draft.teacher_entitlement)
  if ([draft.original_fee, draft.agreed_fee, draft.discount, draft.teacher_entitlement].some(value => !value.trim())
    || ![original, fee, discount, entitlement].every(Number.isFinite) || original < 0 || fee < 0 || discount < 0 || discount > fee || entitlement < 0) return false
  if (discount > 0 && draft.discount_reason.trim().length < 4) return false
  if (fee === 0 && draft.zero_fee_reason.trim().length < 4) return false
  if (draft.teacher_exception && draft.teacher_exception_reason.trim().length < 4) return false
  if (!draft.teacher_exception && entitlement !== Math.round(fee * 50) / 100) return false
  if (fee === discount && fee > 0 && !draft.sponsored_confirmed) return false
  return draft.registration_date.startsWith('2026-11-') && !!row.student_id && !!row.enrollment_id
}

async function finalizeSelected() {
  if (!db || !isAdmin.value || saving.value || !selectedRows.value.length) return
  const invalid = selectedRows.value.find(row => !validateDraft(row, draftFor(row)))
  if (invalid) {
    error.value = t('novemberFinalize.validationError', { student: invalid.student_name || invalid.source_key })
    return
  }
  if (!window.confirm(t('novemberFinalize.confirm', { count: selectedRows.value.length }))) return
  const items = selectedRows.value.map(row => {
    const draft = draftFor(row)
    return {
      candidate_id: row.candidate_id,
      confirmed: true,
      original_fee: Number(draft.original_fee),
      agreed_fee: Number(draft.agreed_fee),
      discount: Number(draft.discount),
      discount_reason: draft.discount_reason.trim() || null,
      teacher_entitlement: Number(draft.teacher_entitlement),
      teacher_exception_reason: draft.teacher_exception ? draft.teacher_exception_reason.trim() : null,
      registration_date: draft.registration_date,
      notes: draft.notes.trim() || null,
      zero_fee_reason: Number(draft.agreed_fee) === 0 ? draft.zero_fee_reason.trim() : null,
      sponsored_confirmed: draft.sponsored_confirmed
    }
  })
  saving.value = true
  error.value = ''
  success.value = ''
  try {
    const result = await db.rpc('november_finalize_confirmed_roster', {
      p_items: items,
      p_request: requestKey.forPayload(items)
    })
    if (result.error) throw result.error
    const data = result.data as { new_monthly_registrations?: number; already_registered_or_posted?: number; payments_created?: number }
    success.value = t('novemberFinalize.saved', {
      created: data.new_monthly_registrations ?? 0,
      existing: data.already_registered_or_posted ?? 0,
      payments: data.payments_created ?? 0
    })
    selectedIds.value = []
    requestKey.reset()
    await load()
    window.dispatchEvent(new CustomEvent('november-finalized'))
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    saving.value = false
  }
}

watch(isAdmin, value => { if (value) void load() }, { immediate: true })
</script>

<template>
  <section v-if="isAdmin" class="card november-finalizer">
    <header class="header-row">
      <div><h2>{{ t('novemberFinalize.title') }}</h2><p>{{ t('novemberFinalize.subtitle') }}</p></div>
      <button class="btn" :disabled="loading || saving" @click="load"><RefreshCw :size="16" />{{ t('novemberFinalize.refresh') }}</button>
    </header>
    <Notice :message="error" kind="error" />
    <Notice :message="success" kind="success" />
    <div class="summary-strip">
      <span>{{ t('novemberFinalize.roster') }} <strong>{{ rows.length || '—' }}</strong></span>
      <span>{{ t('novemberFinalize.linked') }} <strong>{{ linkedCount }}</strong></span>
      <span>{{ t('novemberFinalize.needsReview') }} <strong>{{ reviewLinkCount }}</strong></span>
      <span>{{ t('novemberFinalize.leadsExcluded') }} <strong>{{ leadCount ?? '—' }}</strong></span>
      <span>{{ t('novemberFinalize.monthlyAccounts') }} <strong>{{ monthlyCount ?? '—' }}</strong></span>
      <span>{{ t('novemberFinalize.verifiedPayments') }} <strong>{{ paymentCount ?? '—' }}</strong></span>
      <span>{{ t('novemberFinalize.unverifiedReceipts') }} <strong>{{ unverifiedReceiptCount ?? '—' }}</strong></span>
    </div>
    <p class="hint">{{ t('novemberFinalize.noReceiptNotice') }}</p>
    <details v-if="needsIdentityClassReview.length" class="identity-review card">
      <summary>{{ t('novemberFinalize.identityReviewTitle', { count: needsIdentityClassReview.length }) }}</summary>
      <p class="hint">{{ t('novemberFinalize.identityReviewHint') }}</p>
      <div v-for="row in needsIdentityClassReview" :key="row.candidate_id" class="identity-review-row">
        <strong>{{ row.student_name || '—' }}</strong><small>{{ row.source_key }} · {{ row.current_class || t('novemberFinalize.needsClass') }}</small>
        <div class="form-grid">
          <label>{{ t('novemberFinalize.existingStudent') }}<SearchableSelect v-model="linkDraftFor(row).student_id" :options="existingStudents" label-key="first_name" :search-keys="['last_name','student_code']" selected-suffix-key="student_code" :placeholder="t('financialUi.select')" :min-chars="2" required><template #option="{option}">{{option.student_code}} · {{option.first_name}} {{option.last_name}}</template></SearchableSelect></label>
          <label>{{ t('novemberFinalize.existingClass') }}<SearchableSelect v-model="linkDraftFor(row).class_id" :options="activeClasses" label-key="title" :search-keys="['teacher_name','start_time','end_time']" :placeholder="t('financialUi.select')" :min-chars="2" required><template #option="{option}">{{option.title}} · {{option.teacher_name}} · {{option.start_time}}–{{option.end_time}}</template></SearchableSelect></label>
          <label class="wide">{{ t('novemberFinalize.reviewReason') }}<input v-model="linkDraftFor(row).reason" minlength="4" /></label>
        </div>
        <button class="btn" :disabled="saving" @click="linkExisting(row)">{{ t('novemberFinalize.linkExisting') }}</button>
      </div>
    </details>
    <div class="toolbar">
      <input v-model="search" type="search" :placeholder="t('novemberFinalize.search')" />
      <span>{{ t('novemberFinalize.selected', { count: selectedIds.length }) }}</span>
      <button class="btn primary" :disabled="saving || loading || !selectedIds.length" @click="finalizeSelected">{{ saving ? t('common.saving') : t('novemberFinalize.finalize') }} ({{ selectedIds.length }})</button>
    </div>
    <div v-if="loading" class="empty">{{ t('common.loading') }}</div>
    <div v-else-if="!rows.length" class="empty">{{ t('novemberFinalize.queueMissing') }}</div>
    <div v-else class="table-wrap">
      <table class="data-table fee-table">
        <thead><tr><th>{{ t('novemberFinalize.select') }}</th><th>{{ t('students.form.firstName') }}</th><th>{{ t('students.form.lastName') }}</th><th>{{ t('students.studentId') }}</th><th>{{ t('novemberFinalize.classTeacher') }}</th><th>{{ t('agreements.schedule') }}</th><th>{{ t('novemberFinalize.feeProposal') }}</th><th>{{ t('novemberFinalize.discountProposal') }}</th><th>{{ t('novemberFinalize.state') }}</th></tr></thead>
        <tbody>
          <template v-for="row in filtered" :key="row.candidate_id">
            <tr>
              <td><input type="checkbox" :checked="selectedIds.includes(row.candidate_id)" :disabled="!eligible(row) || saving" :aria-label="t('novemberFinalize.select')" @change="toggle(row, ($event.target as HTMLInputElement).checked)" /></td>
              <td><strong>{{ row.first_name || '—' }}</strong><small>{{ row.source_key }}</small></td>
              <td>{{ row.last_name || '—' }}</td>
              <td dir="ltr">{{ row.student_code || '—' }}</td>
              <td>{{ row.current_class || t('novemberFinalize.needsClass') }}<small>{{ row.current_teacher || '—' }}</small></td>
              <td>{{ timeLabel(row) }}</td>
              <td>{{ row.fee_proposal == null ? '—' : money(row.fee_proposal) }}</td>
              <td>{{ row.discount_proposal == null ? '—' : money(row.discount_proposal) }}</td>
              <td><span :class="['badge', row.existing_november_membership_id ? 'success' : eligible(row) ? 'warning' : 'danger']">{{ row.existing_november_membership_id ? t('novemberFinalize.alreadyRegistered') : manualTeacher(row) ? t('novemberFinalize.manualReview') : row.student_id && row.enrollment_id ? t(`novemberFinalize.flag.${row.review_flag}`) : t('novemberFinalize.identityClassReview') }}</span></td>
            </tr>
            <tr v-if="selectedIds.includes(row.candidate_id)" class="draft-row"><td colspan="9">
              <div class="form-grid">
                <label>{{ t('novemberFinalize.originalFee') }}<input v-model="draftFor(row).original_fee" type="number" min="0" step="0.01" /></label>
                <label>{{ t('novemberFinalize.agreedFee') }} *<input v-model="draftFor(row).agreed_fee" type="number" min="0" step="0.01" @input="updateFee(row)" /></label>
                <label>{{ t('novemberFinalize.discount') }}<input v-model="draftFor(row).discount" type="number" min="0" step="0.01" @input="updateFee(row)" /></label>
                <label>{{ t('novemberFinalize.teacherShare') }}<input v-model="draftFor(row).teacher_entitlement" type="number" min="0" step="0.01" :readonly="!draftFor(row).teacher_exception" /></label>
                <label>{{ t('novemberFinalize.registrationDate') }}<input v-model="draftFor(row).registration_date" type="date" min="2026-11-01" max="2026-11-30" /></label>
                <label class="wide">{{ t('novemberFinalize.discountReason') }}<input v-model="draftFor(row).discount_reason" :required="Number(draftFor(row).discount) > 0" /></label>
                <label class="approval-check"><input v-model="draftFor(row).teacher_exception" type="checkbox" />{{ t('novemberFinalize.customShare') }}</label>
                <label v-if="draftFor(row).teacher_exception" class="wide">{{ t('novemberFinalize.exceptionReason') }} *<input v-model="draftFor(row).teacher_exception_reason" minlength="4" /></label>
                <label v-if="Number(draftFor(row).agreed_fee) === 0" class="wide">{{ t('novemberFinalize.zeroFeeReason') }} *<input v-model="draftFor(row).zero_fee_reason" minlength="4" /></label>
                <label v-if="Number(draftFor(row).agreed_fee) > 0 && Number(draftFor(row).discount) === Number(draftFor(row).agreed_fee)" class="approval-check wide"><input v-model="draftFor(row).sponsored_confirmed" type="checkbox" />{{ t('novemberFinalize.confirmScholarship') }}</label>
                <label class="wide">{{ t('novemberFinalize.notes') }}<input v-model="draftFor(row).notes" /></label>
              </div>
              <p class="hint">{{ t('novemberFinalize.shareHint', { amount: money(Math.round(Number(draftFor(row).agreed_fee || 0) * 50) / 100) }) }} · {{ t('novemberFinalize.noPayment') }}</p>
            </td></tr>
          </template>
        </tbody>
      </table>
    </div>
  </section>
</template>

<style scoped>
.november-finalizer { margin: 0 0 24px; }
.header-row,.toolbar { display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap; }
.header-row p { margin:.3rem 0 0; }
.summary-strip { display:flex;flex-wrap:wrap;gap:10px 20px;padding:12px;background:#f6f8fc;border-radius:9px;margin:14px 0; }
.summary-strip span { display:flex;gap:6px; }
.toolbar { margin:14px 0; }
.toolbar input { min-width:min(320px,100%); }
.fee-table { min-width:1100px; }
.fee-table td small { display:block;opacity:.75;margin-top:3px; }
.draft-row td { background:#fbfcff; }
.draft-row .form-grid { max-width:980px; }
.draft-row .approval-check { display:flex;align-items:center;gap:8px; }
.identity-review { margin:16px 0; }
.identity-review > summary { cursor:pointer;font-weight:700; }
.identity-review-row { padding:14px 0;border-top:1px solid #e5e9f0; }
.identity-review-row small { display:block;opacity:.75;margin:3px 0 10px; }
</style>
