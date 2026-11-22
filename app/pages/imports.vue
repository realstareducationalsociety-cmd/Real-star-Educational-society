<script setup lang="ts">
import { Download, FileSpreadsheet, RefreshCw, Upload } from 'lucide-vue-next'
import { parseHistoricalWorkbook, summarizeHistoricalReview } from '~/utils/historicalWorkbook.js'

interface SourceRow {
  source_key: string
  source_sheet: string
  source_row: number
  payload: Record<string, unknown>
}

interface ImportBatch {
  id: string
  source_filename: string
  source_sha256: string
  row_count: number
  status: string
  created_at: string
}

interface StagedRow extends SourceRow {
  id: string
  batch_id: string
  review_status: 'pending' | 'accepted' | 'rejected' | 'needs_review'
  review_resolution: Record<string, unknown>
  posting_status: 'pending' | 'posted' | 'duplicate'
  destination_table: string | null
  destination_id: string | null
  reviewed_by: string | null
  reviewed_at: string | null
  review_reason: string | null
}

interface PostingPreview {
  records_ready: number
  existing_records_matched: number
  duplicate_records_excluded: number
  records_requiring_review: number
  financial_transactions_requiring_verification: number
  already_posted: number
}

interface SheetStatusCounts {
  total: number
  pending: number
  accepted: number
  rejected: number
  needs_review: number
}

const db = useSupabase()
const auth = useAuth()
const { t } = useLanguage()
const batches = ref<ImportBatch[]>([])
const sourceRows = ref<StagedRow[]>([])
const workbookRows = ref<SourceRow[]>([])
const workbookSheets = ref<string[]>([])
const selectedBatchId = ref('')
const selectedFileName = ref('')
const checksum = ref('')
const sheetFilter = ref('')
const statusFilter = ref('')
const monthFilter = ref('')
const classFilter = ref('')
const teacherFilter = ref('')
const studentFilter = ref('')
const search = ref('')
const reasonDrafts = reactive<Record<string, string>>({})
const resolutionDrafts = reactive<Record<string, string>>({})
const postingPreview = ref<PostingPreview | null>(null)
const page = ref(0)
const busy = ref(false)
const busyRow = ref('')
const posting = ref(false)
const error = ref('')
const success = ref('')
const pageSize = 100

const isAdmin = computed(() => auth.profile.value?.role === 'admin')
const previewCounts = computed(() => countBySheet(workbookRows.value))
const previewReview = computed(() => summarizeHistoricalReview(workbookRows.value))
const stagedCounts = computed(() => {
  const grouped = new Map<string, SheetStatusCounts>()
  for (const row of sourceRows.value) {
    const counts: SheetStatusCounts = grouped.get(row.source_sheet) || { total: 0, pending: 0, accepted: 0, rejected: 0, needs_review: 0 }
    counts.total += 1
    counts[row.review_status] = counts[row.review_status] + 1
    grouped.set(row.source_sheet, counts)
  }
  return [...grouped].map(([sheet, counts]) => ({ sheet, ...counts }))
})
function payloadText(row: SourceRow, fields: string[]) {
  return fields.map(field => String(row.payload[field] ?? '')).filter(Boolean).join(' ')
}

function payloadValue(row: SourceRow, fields: string[]) {
  return fields.map(field => String(row.payload[field] ?? '').trim()).find(Boolean) || ''
}

const monthOptions = computed(() => [...new Set(sourceRows.value.map(row =>
  payloadValue(row, ['Source Month', 'Period', 'Period Of Workbook', 'Month'])
).filter(Boolean))].sort())
const classOptions = computed(() => [...new Set(sourceRows.value.map(row =>
  payloadValue(row, ['Class Name', 'Class', 'Class Or Level', 'Class Key'])
).filter(Boolean))].sort())
const teacherOptions = computed(() => [...new Set(sourceRows.value.map(row =>
  payloadValue(row, ['Teacher'])
).filter(Boolean))].sort())
const filteredRows = computed(() => sourceRows.value.filter(row =>
  (!sheetFilter.value || row.source_sheet === sheetFilter.value) &&
  (!statusFilter.value || row.review_status === statusFilter.value) &&
  (!monthFilter.value || payloadText(row, ['Source Month', 'Period', 'Period Of Workbook', 'Month']).includes(monthFilter.value)) &&
  (!classFilter.value || payloadText(row, ['Class Name', 'Class', 'Class Or Level', 'Class Key']).includes(classFilter.value)) &&
  (!teacherFilter.value || payloadText(row, ['Teacher']).includes(teacherFilter.value)) &&
  (!studentFilter.value || payloadText(row, ['Full Name', 'Display Name Candidate', 'Name', 'First Name', 'Last Name']).toLowerCase().includes(studentFilter.value.toLowerCase())) &&
  (!search.value || `${row.source_key} ${JSON.stringify(row.payload)}`.toLowerCase().includes(search.value.toLowerCase()))
))
const visibleRows = computed(() => filteredRows.value.slice(page.value * pageSize, (page.value + 1) * pageSize))
const rejectedRows = computed(() => sourceRows.value.filter(row => row.review_status === 'rejected'))
const postableSheets = new Set(['Students', 'Teachers', 'Classes', 'Registrations', 'Payments', 'Expenses', 'Books', 'Chapters', 'PartnerNotes'])

function isPostable(row: SourceRow) {
  return postableSheets.has(row.source_sheet)
}

function makeResolutionTemplate(row: StagedRow) {
  const value = (keys: string[]) => payloadValue(row, keys)
  const entityKey = value(['Provisional Person Key', 'Class Key', 'Teacher Key']) || row.source_key
  if (row.source_sheet === 'Students') {
    return {
      kind: 'student', action: 'create', entity_key: entityKey, identity_confirmed: false,
      first_name: value(['Display Name Candidate', 'Full Name', 'Name', 'First Name']), last_name: '',
      profile_active: false
    }
  }
  if (row.source_sheet === 'Teachers') {
    return { kind: 'teacher', action: 'match', entity_key: entityKey, teacher_id: '', active: false }
  }
  if (row.source_sheet === 'Classes') {
    return {
      kind: 'class', action: 'create', entity_key: entityKey, title: value(['Class Name', 'Class', 'Class Key']),
      teacher_id: '', teacher_entity_key: value(['Teacher Key']), teacher_name: value(['Teacher']),
      teacher_identity_confirmed: false, teacher_active: false, default_fee: value(['Default Fee']), active: false
    }
  }
  if (row.source_sheet === 'Registrations') {
    const month = value(['Source Month', 'Period', 'Period Of Workbook', 'Month']).match(/\d{4}-\d{2}/)?.[0] || ''
    return {
      kind: 'registration', student_entity_key: value(['Name Key']),
      class_entity_key: value(['Class Key']), month, registered_on: '',
      registration_date_verified: false, registration_verified: false,
      base_fee: value(['Original Tuition', 'Base Fee']), discount: value(['Discount']) || 0,
      enrollment_active: false
    }
  }
  if (row.source_sheet === 'Payments') {
    return {
      kind: 'tuition_payment', registration_source_key: '', amount: value(['Amount Received', 'Payment Amount']),
      paid_on: value(['Payment Date Parsed', 'Date Parsed']), payment_verified: false,
      duplicate_source_checked: false, method: 'cash'
    }
  }
  if (row.source_sheet === 'Expenses') {
    return {
      kind: 'expense', category: value(['Category']), description: value(['Description', 'Expense']),
      amount: value(['Amount', 'Expense Amount', 'Total Price']),
      spent_on: value(['Date Parsed', 'Date']), expense_verified: false
    }
  }
  if (row.source_sheet === 'Books' || row.source_sheet === 'Chapters') {
    return {
      kind: 'material_sale', material_kind: row.source_sheet === 'Books' ? 'book' : 'chapter',
      item_id: '', student_id: '', class_id: '',
      unit_price: value(['Reported Component Amount', 'Amount']), sold_on: '',
      sale_verified: false, payment_expected: false, payment_verified: false
    }
  }
  return {
    kind: 'partner_transaction', partner_id: '', transaction_kind: '',
    amount: value(['Amount']), transacted_on: '', transaction_verified: false, note: ''
  }
}

function resolutionDraft(row: StagedRow) {
  const draft = resolutionDrafts[row.id]
  if (draft !== undefined) return draft
  return JSON.stringify(makeResolutionTemplate(row), null, 2)
}

function updateResolutionDraft(rowId: string, event: Event) {
  resolutionDrafts[rowId] = (event.target as HTMLTextAreaElement).value
}

function countBySheet(rows: SourceRow[]) {
  const counts = new Map<string, number>()
  for (const row of rows) counts.set(row.source_sheet, (counts.get(row.source_sheet) || 0) + 1)
  return [...counts].map(([sheet, count]) => ({ sheet, count }))
}

function resetFileInput(event: Event) {
  const input = event.target as HTMLInputElement
  if (input.files?.length) void parseFile(input.files[0])
  input.value = ''
}

async function parseFile(file?: File) {
  error.value = ''
  success.value = ''
  workbookRows.value = []
  workbookSheets.value = []
  selectedFileName.value = ''
  checksum.value = ''
  if (!file) return
  if (!file.name.toLowerCase().endsWith('.xlsx')) {
    error.value = t('historicalImport.parseError')
    return
  }
  if (file.size > 5_000_000) {
    error.value = t('historicalImport.fileLimit')
    return
  }
  busy.value = true
  try {
    const bytes = new Uint8Array(await file.arrayBuffer())
    const parsed = parseHistoricalWorkbook(bytes)
    if (!parsed.rows.length) throw new Error(t('historicalImport.parseError'))
    const serialized = new TextEncoder().encode(JSON.stringify(parsed.rows))
    if (serialized.byteLength > 7_500_000) throw new Error(t('historicalImport.fileLimit'))
    const digest = await crypto.subtle.digest('SHA-256', bytes)
    checksum.value = [...new Uint8Array(digest)].map(value => value.toString(16).padStart(2, '0')).join('')
    workbookRows.value = parsed.rows
    workbookSheets.value = parsed.sheetNames
    selectedFileName.value = file.name
  } catch (cause) {
    error.value = cause instanceof Error ? cause.message : t('historicalImport.parseError')
  } finally {
    busy.value = false
  }
}

async function loadBatches() {
  if (!db || !isAdmin.value) return
  busy.value = true
  error.value = ''
  try {
    const result = await allRows(() => db.from('historical_import_batches')
      .select('id,source_filename,source_sha256,row_count,status,created_at')
      .order('created_at', { ascending: false }))
    batches.value = result as ImportBatch[]
    if (selectedBatchId.value && !batches.value.some(batch => batch.id === selectedBatchId.value)) {
      selectedBatchId.value = ''
    }
    if (!selectedBatchId.value && batches.value.length) selectedBatchId.value = batches.value[0]?.id || ''
    await loadRows()
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    busy.value = false
  }
}

async function loadRows() {
  if (!db || !selectedBatchId.value || !isAdmin.value) {
    sourceRows.value = []
    return
  }
  const result = await allRows(() => db.from('historical_import_source_rows')
    .select('id,batch_id,source_key,source_sheet,source_row,source_payload,review_status,review_resolution,posting_status,destination_table,destination_id,reviewed_by,reviewed_at,review_reason')
    .eq('batch_id', selectedBatchId.value)
    .order('source_sheet').order('source_row'))
  sourceRows.value = (result as Array<StagedRow & { source_payload: Record<string, unknown> }>)
    .map(row => ({ ...row, payload: row.source_payload }))
  page.value = 0
  await refreshPostingPreview()
}

async function stageWorkbook() {
  if (!db || !isAdmin.value || !workbookRows.value.length || busy.value) return
  busy.value = true
  error.value = ''
  success.value = ''
  try {
    const result = await db.rpc('stage_historical_import', {
      p_filename: selectedFileName.value,
      p_sha256: checksum.value,
      p_rows: workbookRows.value
    })
    if (result.error) throw result.error
    const response = result.data as { batch_id?: string; already_staged?: boolean } | null
    if (!response?.batch_id) throw new Error(t('historicalImport.parseError'))
    selectedBatchId.value = response.batch_id
    success.value = t('historicalImport.stageSuccess')
    workbookRows.value = []
    workbookSheets.value = []
    selectedFileName.value = ''
    checksum.value = ''
    await loadBatches()
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    busy.value = false
  }
}

async function reviewRow(row: StagedRow, decision: StagedRow['review_status']) {
  if (!db || !isAdmin.value || busyRow.value) return
  const reason = (reasonDrafts[row.id] || '').trim()
  if (reason.length < 4) {
    error.value = t('historicalImport.reasonRequired')
    return
  }
  busyRow.value = row.id
  error.value = ''
  success.value = ''
  try {
    const result = await db.rpc('review_historical_import_row', {
      p_row_id: row.id,
      p_decision: decision,
      p_reason: reason
    })
    if (result.error) throw result.error
    await loadRows()
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    busyRow.value = ''
  }
}

async function saveResolution(row: StagedRow) {
  if (!db || !isAdmin.value || busyRow.value || !isPostable(row)) return
  const reason = (reasonDrafts[row.id] || '').trim()
  if (reason.length < 4) {
    error.value = t('historicalImport.reasonRequired')
    return
  }
  let resolution: Record<string, unknown>
  try {
    const parsed: unknown = JSON.parse(resolutionDraft(row))
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error(t('historicalImport.invalidMapping'))
    resolution = parsed as Record<string, unknown>
  } catch (cause) {
    error.value = cause instanceof Error ? cause.message : t('historicalImport.invalidMapping')
    return
  }
  busyRow.value = row.id
  error.value = ''
  success.value = ''
  try {
    const result = await db.rpc('resolve_historical_import_row', {
      p_row_id: row.id,
      p_resolution: resolution,
      p_reason: reason
    })
    if (result.error) throw result.error
    await loadRows()
    success.value = t('historicalImport.mappingSaved')
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    busyRow.value = ''
  }
}

async function refreshPostingPreview() {
  if (!db || !isAdmin.value || !selectedBatchId.value) {
    postingPreview.value = null
    return
  }
  try {
    const result = await db.rpc('preview_historical_import_batch', { p_batch_id: selectedBatchId.value })
    if (result.error) throw result.error
    postingPreview.value = result.data as PostingPreview
  } catch (cause) {
    postingPreview.value = null
    error.value = errText(cause)
  }
}

async function postApprovedRecords() {
  if (!db || !isAdmin.value || posting.value || !selectedBatchId.value) return
  posting.value = true
  error.value = ''
  success.value = ''
  const totals = { posted: 0, matched: 0, duplicates: 0, requiring_review: 0, financial_transactions: 0 }
  try {
    await refreshPostingPreview()
    const preview = postingPreview.value
    if (!preview || preview.records_ready < 1) return
    const confirmation = [
      t('historicalImport.confirmPost'),
      `${t('historicalImport.recordsReady')}: ${preview.records_ready}`,
      `${t('historicalImport.existingMatched')}: ${preview.existing_records_matched}`,
      `${t('historicalImport.duplicateExcluded')}: ${preview.duplicate_records_excluded}`,
      `${t('historicalImport.requiresReview')}: ${preview.records_requiring_review}`,
      `${t('historicalImport.financialVerification')}: ${preview.financial_transactions_requiring_verification}`
    ].join('\n')
    if (!window.confirm(confirmation)) return
    let remainingReady = preview.records_ready
    for (let index = 0; index < 20 && remainingReady > 0; index += 1) {
      const result = await db.rpc('post_historical_import_batch', {
        p_batch_id: selectedBatchId.value,
        p_confirm: true
      })
      if (result.error) throw result.error
      const counts = result.data as typeof totals | null
      if (!counts || Object.values(counts).some(value => typeof value !== 'number')) {
        throw new Error(t('historicalImport.previewError'))
      }
      totals.posted += counts.posted
      totals.matched += counts.matched
      totals.duplicates += counts.duplicates
      totals.requiring_review = counts.requiring_review
      totals.financial_transactions += counts.financial_transactions
      await refreshPostingPreview()
      if (!postingPreview.value) throw new Error(t('historicalImport.previewError'))
      remainingReady = postingPreview.value.records_ready
      if (index === 19 && remainingReady > 0) throw new Error(t('historicalImport.moreBatches'))
    }
    await loadRows()
    success.value = t('historicalImport.postSuccess', totals)
  } catch (cause) {
    error.value = errText(cause)
    if (totals.posted + totals.matched + totals.duplicates > 0) {
      success.value = t('historicalImport.postPartial', totals)
    }
    await loadRows()
  } finally {
    posting.value = false
  }
}

function csvCell(value: unknown) {
  const text = String(value ?? '')
  const safeText = /^\s*[=+\-@]/.test(text) ? `'${text}` : text
  return `"${safeText.replace(/"/g, '""')}"`
}

function downloadRejected() {
  if (!rejectedRows.value.length) {
    error.value = t('historicalImport.downloadEmpty')
    return
  }
  const lines = [
    ['source_sheet', 'source_row', 'source_key', 'review_status', 'review_reason', 'source_payload'].map(csvCell).join(','),
    ...rejectedRows.value.map(row => [
      row.source_sheet, row.source_row, row.source_key, row.review_status, row.review_reason,
      JSON.stringify(row.payload)
    ].map(csvCell).join(','))
  ]
  const url = URL.createObjectURL(new Blob([`\uFEFF${lines.join('\r\n')}`], { type: 'text/csv;charset=utf-8' }))
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = 'historical-import-rejections.csv'
  anchor.click()
  URL.revokeObjectURL(url)
}

watch([sheetFilter, statusFilter, monthFilter, classFilter, teacherFilter, studentFilter, search], () => { page.value = 0 })
watch(selectedBatchId, () => { void loadRows() })
onMounted(loadBatches)
</script>

<template>
  <div>
    <NovemberFeeFinalization />
    <NovemberImport />
    <PageTitle :title="t('historicalImport.title')" :subtitle="t('historicalImport.subtitle')">
      <button class="btn" :disabled="busy" @click="loadBatches">
        <RefreshCw :size="16" aria-hidden="true" />{{ t('common.refresh') }}
      </button>
    </PageTitle>
    <Notice :message="error" kind="error" />
    <Notice :message="success" kind="success" />
    <section class="card import-privacy">
      <strong>{{ t('historicalImport.privacyNotice') }}</strong>
      <p>{{ t('historicalImport.reviewPhaseOnly') }}</p>
    </section>

    <section class="card import-upload">
      <h2>{{ t('historicalImport.preview') }}</h2>
      <label>{{ t('historicalImport.file') }}
        <input type="file" accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" :disabled="busy" @change="resetFileInput" />
      </label>
      <p v-if="busy">{{ t('common.loading') }}</p>
      <template v-if="workbookRows.length">
        <p><strong>{{ selectedFileName }}</strong> · {{ t('historicalImport.rows') }}: {{ workbookRows.length }} · {{ t('historicalImport.sheets') }}: {{ workbookSheets.length }}</p>
        <div class="table-wrap">
          <table class="data-table">
            <thead><tr><th>{{ t('historicalImport.sheet') }}</th><th>{{ t('historicalImport.rows') }}</th></tr></thead>
            <tbody><tr v-for="item in previewCounts" :key="item.sheet"><td>{{ item.sheet }}</td><td>{{ item.count }}</td></tr></tbody>
          </table>
        </div>
        <h3>{{ t('historicalImport.decisionPreview') }}</h3>
        <p class="hint">{{ t('historicalImport.sourceFlagsOnly') }}</p>
        <div v-if="previewReview.length" class="table-wrap">
          <table class="data-table">
            <thead><tr><th>{{ t('historicalImport.sheet') }}</th><th>{{ t('historicalImport.decisionField') }}</th><th>{{ t('historicalImport.status') }}</th><th>{{ t('historicalImport.rows') }}</th></tr></thead>
            <tbody>
              <tr v-for="item in previewReview" :key="`${item.sheet}-${item.field}-${item.decision}`">
                <td>{{ item.sheet }}</td><td>{{ item.field }}</td><td dir="ltr">{{ item.decision }}</td><td>{{ item.count }}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <div class="form-footer">
          <button class="btn primary" :disabled="busy || !isAdmin" @click="stageWorkbook">
            <Upload :size="16" aria-hidden="true" />{{ t('historicalImport.stage') }}
          </button>
        </div>
      </template>
    </section>

    <section class="card import-batches">
      <div class="card-header">
        <h2>{{ t('historicalImport.batches') }}</h2>
        <button class="btn" :disabled="busy || !rejectedRows.length" @click="downloadRejected">
          <Download :size="16" aria-hidden="true" />{{ t('historicalImport.downloadRejected') }}
        </button>
      </div>
      <p v-if="!batches.length">{{ t('historicalImport.noBatches') }}</p>
      <div v-else class="table-wrap">
        <table class="data-table">
          <thead><tr><th>{{ t('historicalImport.file') }}</th><th>{{ t('historicalImport.rows') }}</th><th>{{ t('historicalImport.status') }}</th><th>{{ t('common.date') }}</th><th>{{ t('common.actions') }}</th></tr></thead>
          <tbody>
            <tr v-for="batch in batches" :key="batch.id">
              <td>{{ batch.source_filename }}<small class="material-id">{{ batch.source_sha256 }}</small></td>
              <td>{{ batch.row_count }}</td><td>{{ batch.status }}</td><td>{{ batch.created_at.slice(0, 10) }}</td>
              <td><button class="btn small-btn" :disabled="busy" @click="selectedBatchId = batch.id">{{ t('historicalImport.review') }}</button></td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>

    <section v-if="selectedBatchId" class="card import-review">
      <div class="card-header"><h2>{{ t('historicalImport.review') }}</h2><FileSpreadsheet :size="20" aria-hidden="true" /></div>
      <section v-if="postingPreview" class="posting-preview">
        <h3>{{ t('historicalImport.postPreview') }}</h3>
        <dl class="posting-counts">
          <div><dt>{{ t('historicalImport.recordsReady') }}</dt><dd>{{ postingPreview.records_ready }}</dd></div>
          <div><dt>{{ t('historicalImport.existingMatched') }}</dt><dd>{{ postingPreview.existing_records_matched }}</dd></div>
          <div><dt>{{ t('historicalImport.duplicateExcluded') }}</dt><dd>{{ postingPreview.duplicate_records_excluded }}</dd></div>
          <div><dt>{{ t('historicalImport.requiresReview') }}</dt><dd>{{ postingPreview.records_requiring_review }}</dd></div>
          <div><dt>{{ t('historicalImport.financialVerification') }}</dt><dd>{{ postingPreview.financial_transactions_requiring_verification }}</dd></div>
          <div><dt>{{ t('historicalImport.alreadyPosted') }}</dt><dd>{{ postingPreview.already_posted }}</dd></div>
        </dl>
        <p class="hint">{{ t('historicalImport.postingGuardNotice') }}</p>
        <button class="btn primary" :disabled="busy || posting || postingPreview.records_ready < 1" @click="postApprovedRecords">
          {{ posting ? t('common.saving') : t('historicalImport.postApproved') }}
        </button>
      </section>
      <div v-if="stagedCounts.length" class="table-wrap">
        <table class="data-table">
          <thead><tr><th>{{ t('historicalImport.sheet') }}</th><th>{{ t('historicalImport.rows') }}</th><th>{{ t('historicalImport.pending') }}</th><th>{{ t('historicalImport.accepted') }}</th><th>{{ t('historicalImport.rejected') }}</th><th>{{ t('historicalImport.needsReviewStatus') }}</th></tr></thead>
          <tbody><tr v-for="item in stagedCounts" :key="item.sheet"><td>{{ item.sheet }}</td><td>{{ item.total }}</td><td>{{ item.pending }}</td><td>{{ item.accepted }}</td><td>{{ item.rejected }}</td><td>{{ item.needs_review }}</td></tr></tbody>
        </table>
      </div>
      <div class="table-toolbar">
        <label>{{ t('historicalImport.month') }}
          <select v-model="monthFilter"><option value="">{{ t('historicalImport.allMonths') }}</option><option v-for="item in monthOptions" :key="item" :value="item">{{ item }}</option></select>
        </label>
        <label>{{ t('historicalImport.class') }}
          <select v-model="classFilter"><option value="">{{ t('historicalImport.allClasses') }}</option><option v-for="item in classOptions" :key="item" :value="item">{{ item }}</option></select>
        </label>
        <label>{{ t('historicalImport.teacher') }}
          <select v-model="teacherFilter"><option value="">{{ t('historicalImport.allTeachers') }}</option><option v-for="item in teacherOptions" :key="item" :value="item">{{ item }}</option></select>
        </label>
        <label>{{ t('historicalImport.student') }}
          <input v-model="studentFilter" type="search" :placeholder="t('historicalImport.student')" />
        </label>
        <label>{{ t('historicalImport.sheet') }}
          <select v-model="sheetFilter"><option value="">{{ t('historicalImport.allSheets') }}</option><option v-for="item in stagedCounts" :key="item.sheet" :value="item.sheet">{{ item.sheet }}</option></select>
        </label>
        <label>{{ t('historicalImport.status') }}
          <select v-model="statusFilter">
            <option value="">{{ t('historicalImport.allStatuses') }}</option>
            <option value="pending">{{ t('historicalImport.pending') }}</option>
            <option value="accepted">{{ t('historicalImport.accepted') }}</option>
            <option value="rejected">{{ t('historicalImport.rejected') }}</option>
            <option value="needs_review">{{ t('historicalImport.needsReviewStatus') }}</option>
          </select>
        </label>
        <input v-model="search" type="search" :aria-label="t('common.search')" :placeholder="t('common.search')" />
      </div>
      <div class="table-wrap">
        <table class="data-table">
          <thead><tr><th>{{ t('historicalImport.sheet') }}</th><th>{{ t('historicalImport.sourceRow') }}</th><th>{{ t('historicalImport.sourceKey') }}</th><th>{{ t('historicalImport.status') }}</th><th>{{ t('historicalImport.payload') }}</th><th>{{ t('historicalImport.reason') }}</th><th>{{ t('common.actions') }}</th></tr></thead>
          <tbody>
            <tr v-for="row in visibleRows" :key="row.id">
              <td>{{ row.source_sheet }}</td><td dir="ltr">{{ row.source_row }}</td><td dir="ltr">{{ row.source_key }}</td>
              <td>{{ t(`historicalImport.${row.review_status === 'needs_review' ? 'needsReviewStatus' : row.review_status}`) }}<small>{{ t(`historicalImport.posting_${row.posting_status}`) }}</small></td>
              <td><details><summary>{{ t('historicalImport.payload') }}</summary><pre dir="ltr">{{ JSON.stringify(row.payload, null, 2) }}</pre></details></td>
              <td>
                <textarea v-model="reasonDrafts[row.id]" rows="2" minlength="4" :disabled="busyRow === row.id" :placeholder="t('historicalImport.reason')" />
                <details v-if="isPostable(row)">
                  <summary>{{ t('historicalImport.resolution') }}</summary>
                  <textarea :value="resolutionDraft(row)" rows="10" dir="ltr" spellcheck="false" :disabled="busyRow === row.id || row.posting_status !== 'pending'" @input="updateResolutionDraft(row.id, $event)" />
                  <small>{{ t('historicalImport.resolutionHelp') }}</small>
                </details>
              </td>
              <td class="import-row-actions">
                <button v-if="isPostable(row)" class="btn small-btn" :disabled="busyRow === row.id || row.posting_status !== 'pending'" @click="saveResolution(row)">{{ t('historicalImport.saveMapping') }}</button>
                <button class="btn small-btn danger" :disabled="busyRow === row.id" @click="reviewRow(row, 'rejected')">{{ t('historicalImport.reject') }}</button>
                <button class="btn small-btn" :disabled="busyRow === row.id" @click="reviewRow(row, 'needs_review')">{{ t('historicalImport.needsReview') }}</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <div class="form-footer import-pagination">
        <span>{{ t('historicalImport.showing', { start: filteredRows.length ? page * pageSize + 1 : 0, end: Math.min((page + 1) * pageSize, filteredRows.length), total: filteredRows.length }) }}</span>
        <button class="btn" :disabled="page === 0" @click="page--">{{ t('historicalImport.previous') }}</button>
        <button class="btn" :disabled="(page + 1) * pageSize >= filteredRows.length" @click="page++">{{ t('historicalImport.next') }}</button>
      </div>
    </section>
  </div>
</template>

<style scoped>
.import-privacy { border-inline-start: 4px solid var(--primary, #3565b7); margin-bottom: 18px; }
.import-privacy p { margin-bottom: 0; }
.import-upload, .import-batches, .import-review { margin-bottom: 20px; }
.import-row-actions { min-width: 190px; }
.import-row-actions .btn { margin: 2px; }
.import-row-actions small, .import-review td small { display: block; opacity: .75; }
.posting-preview { border: 1px solid var(--border, #d7dce3); border-radius: 8px; padding: 14px; margin-bottom: 16px; }
.posting-counts { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 8px 18px; }
.posting-counts div { display: flex; justify-content: space-between; gap: 12px; }
.posting-counts dt { font-weight: 600; }
.posting-counts dd { margin: 0; }
.import-review td textarea { display: block; width: 100%; min-width: 180px; }
.import-pagination { justify-content: flex-end; align-items: center; gap: 8px; }
.import-review pre { max-width: 420px; max-height: 260px; overflow: auto; white-space: pre-wrap; font-size: 12px; }
</style>
