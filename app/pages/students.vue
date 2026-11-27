<script setup lang="ts">
import { Plus, Search, Users, Pencil, History } from 'lucide-vue-next'
import type { Student } from '~/types/models'
import { normalizeSearchText } from '~/utils/searchText'

type MonthlyRegistration = {
  id?: string
  registration_active: boolean
  registration_status?: string | null
  payment_status?: string | null
  base_fee?: number | null
  discount?: number | null
  registered_on?: string
  confirmation_status?: string | null
  period?: { year_month: string }
  enrollment: {
    id: string
    class_id: string
    student_id: string
    class_item: { title: string } | Array<{ title: string }> | null
  }
}

const supabase = useSupabase()
const auth = useAuth()
const { t } = useLanguage()
const rows = ref<Student[]>([])
const registrationRows = ref<MonthlyRegistration[]>([])
const month = ref(nowMonth())
const query = ref('')
const studentStatusFilter = ref<'active' | 'archived'>('active')
const loading = ref(false)
const error = ref('')
const success = ref('')
const open = ref(false)
const saving = ref(false)
const editId = ref<string | null>(null)
const historyOpen = ref(false)
const historyLoading = ref(false)
const historyRows = ref<any[]>([])
const historyLinks = ref<any[]>([])
const historyEvents = ref<any[]>([])
const historyRegistrations = ref<MonthlyRegistration[]>([])
const historyMissingMonths = ref<any[]>([])
const historyPayments = ref<any[]>([])
const historyAccounts = ref<any[]>([])
const historyMaterials = ref<any[]>([])
const historyStudent = ref<Student | null>(null)
const profileStudent = ref<Student | null>(null)
const profileOpen = ref(false)
const profileLoading = ref(false)
const profileError = ref('')
const renewalMessageConsents = ref<any[]>([])
const renewalConsentBusy = ref('')
const historyError = ref('')
const historyWarning = ref('')
const archiveStudentBusy = ref(false)
const withdrawingProfileLink = ref('')
const studentFinanceGuard = ref<Record<string, any>>({})
const classChangeOpen = ref(false)
const classChangeLoading = ref(false)
const classChangeSaving = ref(false)
const classChangeError = ref('')
const classChangeSuccess = ref('')
const classChangeLinks = ref<any[]>([])
const availableClasses = ref<any[]>([])
const classChangeQuery = ref('')
const classChangeTarget = ref('')
const classChangeSourceEnrollmentId = ref('')
const classChangeOperation = ref<'move' | 'add' | 'correct'>('move')
const classChangeDate = ref(todayKarachi())
const classChangeFinancialRegistrations = ref<any[]>([])
const noorziaCorrectionOpen = ref(false)
const noorziaCorrectionLoading = ref(false)
const noorziaCorrectionSaving = ref(false)
const noorziaCorrectionError = ref('')
const noorziaCorrectionPreflight = ref<any>(null)
const noorziaRefundConfirmed = ref(false)
const noorziaRegistrationApproved = ref(false)
const noorziaCorrectionReason = ref('')
const noorziaCorrectionResult = ref<any>(null)
const noorziaCorrectionReadback = ref<any>(null)

const NOORZIA_CODE = 'RS-000056'
const NOORZIA_RECEIPT_ID = '446d758c-3466-45bc-901a-063dfc05f752'
const NOORZIA_GRADE3_ID = 'e2df6a0e-a6b2-4193-a585-ffed7a931ddc'

const noorziaCorrectionReady = computed(() => Boolean(noorziaCorrectionPreflight.value?.ready)
  && noorziaRefundConfirmed.value && noorziaRegistrationApproved.value
  && noorziaCorrectionReason.value.trim().length >= 4
  && !noorziaCorrectionSaving.value && !noorziaCorrectionResult.value)

function relatedOne(value: any) { return Array.isArray(value) ? value[0] : value }

async function openNoorziaCorrection(student: Student) {
  if (!supabase || auth.profile.value?.role !== 'admin' || student.student_code !== NOORZIA_CODE) return
  noorziaCorrectionOpen.value = true
  noorziaCorrectionLoading.value = true
  noorziaCorrectionError.value = ''
  noorziaCorrectionPreflight.value = null
  noorziaCorrectionResult.value = null
  noorziaCorrectionReadback.value = null
  noorziaRefundConfirmed.value = false
  noorziaRegistrationApproved.value = false
  noorziaCorrectionReason.value = ''
  try {
    const [person, periodRows, grade3Rows, enrollments, registrationResult, receiptRows, settlementRows] = await Promise.all([
      allRows(() => supabase!.from('students').select('id,student_code,first_name,last_name').eq('student_code', NOORZIA_CODE)),
      allRows(() => supabase!.from('billing_periods').select('id,year_month,status').eq('year_month', '2026-11-01')),
      allRows(() => supabase!.from('class_rooms').select('id,title,teacher_id,start_time,end_time,active,teacher:teachers(full_name)').eq('id', NOORZIA_GRADE3_ID)),
      allRows(() => supabase!.from('enrollments').select('id,student_id,class_id,enrolled_on,active,class_item:class_rooms(id,title,teacher_id)').eq('student_id', student.id)),
      supabase!.rpc('monthly_registration_list', { p_month: '2026-11-01', p_student: student.id }),
      allRows(() => supabase!.from('payments').select('id,monthly_membership_id,amount,paid_on,method,reference_note,voided_at,void_reason,created_at').eq('id', NOORZIA_RECEIPT_ID)),
      allRows(() => supabase!.from('teacher_settlements').select('id,period_id,class_id,teacher_id,amount,voided_at').eq('voided_at', null))
    ])
    if (registrationResult.error) throw registrationResult.error
    const actualStudent = person[0] as any
    const period = periodRows[0] as any
    const correctClass = grade3Rows[0] as any
    const gradeTeacher = relatedOne(correctClass?.teacher)
    const allRegistrations = (Array.isArray(registrationResult.data) ? registrationResult.data : []) as any[]
    const membershipIds = allRegistrations.map(row => row.id).filter(Boolean)
    const [paymentRows, voidAuditRows] = await Promise.all([
      membershipIds.length ? allRows(() => supabase!.from('payments').select('id,monthly_membership_id,amount,paid_on,method,voided_at,void_reason').in('monthly_membership_id', membershipIds)) : Promise.resolve([]),
      allRows(() => supabase!.from('audit_logs').select('id,action,row_id,created_at,old_data,new_data').eq('table_name', 'payments').eq('row_id', NOORZIA_RECEIPT_ID).eq('action', 'UPDATE'))
    ])
    const receipt = receiptRows[0] as any
    const sourceRows = allRegistrations.filter(row => row.registration_active && registrationClassName(row) === 'School Grade 2')
    const source = sourceRows.length === 1 ? sourceRows[0] : null
    const sourceEnrollment = source && enrollments.find((row: any) => row.id === source.enrollment?.id && row.class_id === source.enrollment?.class_id)
    const sourceClass = relatedOne(sourceEnrollment?.class_item)
    const historicalVoid = voidAuditRows.some((row: any) => row.old_data?.voided_at == null && row.new_data?.voided_at != null)
    const validPaid = paymentRows.filter((payment: any) => !payment.voided_at).reduce((total: number, payment: any) => total + Number(payment.amount), 0)
    const sourceFeeCorrect = source && Number(source.base_fee) === 1000 && Number(source.discount) === 200 && source.proration_rule === 'manual_agreement'
    const settlementConflict = source && settlementRows.some((row: any) => row.period_id === period?.id && [sourceClass?.id, NOORZIA_GRADE3_ID].includes(row.class_id) && row.teacher_id === source.teacher_id)
    const checks = [
      { key: 'student', ok: actualStudent?.id === student.id && actualStudent?.student_code === NOORZIA_CODE, detail: `${actualStudent?.first_name || ''} ${actualStudent?.last_name || ''} (${actualStudent?.student_code || 'not found'})` },
      { key: 'period', ok: period?.status === 'open', detail: period ? `${period.year_month} · ${period.status}` : 'November 2026 period missing' },
      { key: 'target', ok: correctClass?.active === true && correctClass?.title === 'School Grade 3' && gradeTeacher?.full_name === 'Tahera Sakhizada' && correctClass?.start_time?.startsWith('17:00') && correctClass?.end_time?.startsWith('18:00'), detail: `${correctClass?.title || 'class missing'} · ${gradeTeacher?.full_name || 'teacher missing'} · ${correctClass?.start_time || '?'}–${correctClass?.end_time || '?'}` },
      { key: 'source', ok: !!source && sourceClass?.id === source.enrollment?.class_id && sourceClass?.title === 'School Grade 2' && source.registration_active === true && sourceFeeCorrect, detail: source ? `${sourceClass?.title}; fee ${source.base_fee}; discount ${source.discount}; agreement ${source.proration_rule}` : `${sourceRows.length} active Grade 2 registrations found` },
      { key: 'no_target', ok: !enrollments.some((link: any) => link.class_id === NOORZIA_GRADE3_ID && allRegistrations.some(row => row.enrollment?.id === link.id)), detail: enrollments.some((link: any) => link.class_id === NOORZIA_GRADE3_ID && allRegistrations.some(row => row.enrollment?.id === link.id)) ? 'November Grade 3 membership already exists' : 'No November Grade 3 membership exists' },
      { key: 'receipt', ok: receipt?.monthly_membership_id === source?.id && Number(receipt?.amount) === 800 && receipt?.paid_on === '2026-11-24' && !!receipt?.voided_at && historicalVoid, detail: receipt ? `PKR ${receipt.amount} · ${receipt.paid_on} · ${receipt.method} · ${receipt.voided_at ? 'voided' : 'valid'} · void history ${historicalVoid ? 'found' : 'missing'}` : 'Original receipt not found' },
      { key: 'paid', ok: validPaid === 0, detail: `Valid November payments across all Noorzia memberships: PKR ${validPaid}` },
      { key: 'settlement', ok: !settlementConflict, detail: settlementConflict ? 'An active teacher settlement conflicts with this correction' : 'No active November settlement for the source/target class' }
    ]
    noorziaCorrectionPreflight.value = { ready: checks.every(check => check.ok), checks, student: actualStudent, period, source, receipt, validPaid }
    if (!checks.every(check => check.ok)) noorziaCorrectionError.value = 'Preflight failed. No changes were made; resolve each failed check before trying again.'
  } catch (cause) {
    noorziaCorrectionError.value = `Read-only preflight failed: ${errText(cause)}`
    noorziaCorrectionPreflight.value = { ready: false, checks: [] }
  } finally { noorziaCorrectionLoading.value = false }
}

async function executeNoorziaCorrection() {
  if (!supabase || auth.profile.value?.role !== 'admin' || !noorziaCorrectionReady.value) return
  noorziaCorrectionSaving.value = true
  noorziaCorrectionError.value = ''
  try {
    const response = await supabase.rpc('correct_november_student_class', {
      p_student_code: NOORZIA_CODE,
      p_correct_class_id: NOORZIA_GRADE3_ID,
      p_reason: noorziaCorrectionReason.value.trim(),
      p_payment_request_id: crypto.randomUUID(),
      p_original_receipt_id: NOORZIA_RECEIPT_ID,
      p_manager_confirmed_refunded: noorziaRefundConfirmed.value,
      p_manager_approved_grade3_registration: noorziaRegistrationApproved.value
    })
    if (response.error) throw response.error
    noorziaCorrectionResult.value = response.data
    const oldId = response.data?.old_membership_id
    const newId = response.data?.new_membership_id
    const [oldRows, newRows, receiptRows, postPayments, auditRows] = await Promise.all([
      allRows(() => supabase!.from('monthly_memberships').select('id,registration_active,base_fee,discount,amount_due,teacher_id,enrollment_id').eq('id', oldId)),
      allRows(() => supabase!.from('monthly_memberships').select('id,registration_active,base_fee,discount,amount_due,teacher_id,enrollment_id').eq('id', newId)),
      allRows(() => supabase!.from('payments').select('id,monthly_membership_id,amount,paid_on,method,voided_at,void_reason').eq('id', NOORZIA_RECEIPT_ID)),
      allRows(() => supabase!.from('payments').select('id,monthly_membership_id,amount,voided_at').in('monthly_membership_id', [oldId, newId])),
      allRows(() => supabase!.from('audit_logs').select('id,action,row_id,created_at,old_data,new_data,reason').eq('table_name', 'monthly_memberships').eq('row_id', oldId).eq('action', 'CORRECT_NOVEMBER_CLASS').order('created_at', { ascending: false }))
    ])
    const oldMembership = oldRows[0] as any
    const newMembership = newRows[0] as any
    const keptReceipt = receiptRows[0] as any
    const paymentTotal = postPayments.filter((row: any) => !row.voided_at).reduce((total: number, row: any) => total + Number(row.amount), 0)
    const oldEnrollment = await allRows(() => supabase!.from('enrollments').select('id,class_id,class_item:class_rooms(id,title)').eq('id', oldMembership?.enrollment_id))
    const newEnrollment = await allRows(() => supabase!.from('enrollments').select('id,class_id,class_item:class_rooms(id,title,teacher:teachers(full_name))').eq('id', newMembership?.enrollment_id))
    const targetTeacher = relatedOne(relatedOne((newEnrollment[0] as any)?.class_item)?.teacher)
    const sourceClassName = relatedOne((oldEnrollment[0] as any)?.class_item)?.title
    const targetClass = relatedOne((newEnrollment[0] as any)?.class_item)
    const passed = oldMembership?.registration_active === false && newMembership?.registration_active === true
      && Number(newMembership?.base_fee) === 1000 && Number(newMembership?.discount) === 200 && Number(newMembership?.amount_due) === 800
      && newMembership?.teacher_id === targetClass?.teacher_id && targetClass?.id === NOORZIA_GRADE3_ID
      && targetTeacher?.full_name === 'Tahera Sakhizada' && sourceClassName === 'School Grade 2'
      && keptReceipt?.id === NOORZIA_RECEIPT_ID && !!keptReceipt?.voided_at && Number(keptReceipt?.amount) === 800
      && keptReceipt?.paid_on === '2026-11-24' && paymentTotal === 0 && postPayments.every((row: any) => !!row.voided_at)
      && auditRows.length > 0 && auditRows.some((row: any) => row.new_data?.receipt_remains_voided === true)
    noorziaCorrectionReadback.value = { passed, oldMembership, newMembership, receipt: keptReceipt, paymentTotal, audit: auditRows.find((row: any) => row.new_data?.receipt_remains_voided === true) || null }
    if (!passed) noorziaCorrectionError.value = 'RPC returned success, but the read-back did not match all expected results. Do not retry; request an administrator review.'
  } catch (cause) {
    noorziaCorrectionError.value = `Correction/read-back error: ${errText(cause)}. If the RPC may have completed, do not retry until an administrator checks the audit log.`
  } finally { noorziaCorrectionSaving.value = false }
}

function registrationClassName(item: any) {
  const value = item?.enrollment?.class_item ?? item?.class_item
  return Array.isArray(value) ? value[0]?.title || '' : value?.title || ''
}

const fresh = () => ({
  first_name: '',
  last_name: '',
  guardian_name: '',
  phone: '',
  guardian_phone: '',
  address: '',
  active: true,
  registered_on: todayKarachi(),
  notes: ''
})
const form = reactive(fresh())
const filtered = computed(() => rows.value.filter(student =>
  normalizeSearchText(`${student.student_code} ${student.first_name} ${student.last_name} ${student.phone || ''} ${student.guardian_name || ''}`).includes(normalizeSearchText(query.value))
))
const registrationsByStudent = computed(() => {
  const grouped = new Map<string, { activeClasses: string[]; cancelledClasses: string[] }>()
  for (const registration of registrationRows.value) {
    const studentId = registration.enrollment.student_id
    const status = grouped.get(studentId) || { activeClasses: [], cancelledClasses: [] }
    const classes = registration.registration_active ? status.activeClasses : status.cancelledClasses
    const className = registrationClassName(registration)
    if (className && !classes.includes(className)) {
      classes.push(className)
    }
    grouped.set(studentId, status)
  }
  return grouped
})

async function load() {
  if (!supabase) return
  loading.value = true
  error.value = ''
  try {
    const [people, registrations] = await Promise.all([
      allRows(() => supabase.from('students').select('*').eq('active', studentStatusFilter.value === 'active').order('created_at', { ascending: false })),
      supabase.rpc('monthly_registration_list', { p_month: monthStart(month.value) })
    ])
    if (registrations.error) throw registrations.error
    rows.value = people as Student[]
    registrationRows.value = (registrations.data || []) as MonthlyRegistration[]
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    loading.value = false
  }
}

async function archiveOrRestoreStudent(student: Student) {
  if (!supabase || auth.profile.value?.role !== 'admin' || archiveStudentBusy.value) return
  archiveStudentBusy.value = true
  error.value = ''
  try {
    if (student.active) {
      const [accounts, links, registrationResult] = await Promise.all([
        allRows(() => supabase!.from('month_fee_overview').select('id,balance_due,paid_total,registration_active').eq('student_id', student.id)),
        allRows(() => supabase!.from('enrollments').select('id,active').eq('student_id', student.id)),
        supabase.rpc('monthly_registration_list', { p_month: null, p_student: student.id })
      ])
      if (registrationResult.error) throw registrationResult.error
      const activeFinance = (Array.isArray(registrationResult.data) ? registrationResult.data : []).filter((row: any) => row.registration_active)
      const due = accounts.reduce((sum: number, row: any) => sum + Number(row.balance_due || 0), 0)
      studentFinanceGuard.value[student.id] = { activeFinance: activeFinance.length, due, paidHistory: accounts.some((row: any) => Number(row.paid_total) > 0), educationHistory: links.length }
      const warning = activeFinance.length || due > 0
        ? t('students.archiveFinancialWarning', { registrations: activeFinance.length, balance: money(due) })
        : t('students.archiveConfirmation', { name: `${student.first_name} ${student.last_name}` })
      if (!window.confirm(`${warning}\n\n${t('students.archiveHistoryPreserved')}`)) return
      if (activeFinance.length || due > 0) throw new Error(t('students.archiveBlockedFinancial'))
      const reason = window.prompt(t('students.archiveReason'))
      if (!reason || reason.trim().length < 4) throw new Error(t('students.archiveReasonRequired'))
      const result = await supabase.rpc('archive_student', { p_student: student.id, p_reason: reason.trim() })
      if (result.error) throw result.error
      success.value = t('students.archivedSuccess')
    } else {
      if (!window.confirm(t('students.restoreConfirmation', { name: `${student.first_name} ${student.last_name}` }))) return
      const reason = window.prompt(t('students.restoreReason'))
      if (!reason || reason.trim().length < 4) throw new Error(t('students.archiveReasonRequired'))
      const result = await supabase.rpc('restore_student', { p_student: student.id, p_reason: reason.trim() })
      if (result.error) throw result.error
      success.value = t('students.restoredSuccess')
    }
    await load()
    if (profileStudent.value?.id === student.id) {
      const refreshed = await supabase.from('students').select('*').eq('id', student.id).single()
      if (refreshed.error) throw refreshed.error
      profileStudent.value = refreshed.data as Student
    }
  } catch (cause) { error.value = errText(cause); if (profileOpen.value) profileError.value = error.value }
  finally { archiveStudentBusy.value = false }
}

async function withdrawProfileClass(link: any) {
  if (!supabase || !auth.canEducation.value || withdrawingProfileLink.value) return
  const classItem = relatedOne(link.class_item)
  if (!window.confirm(t('students.withdrawProfileConfirmation', { name: `${profileStudent.value?.first_name || ''} ${profileStudent.value?.last_name || ''}`, className: classItem?.title || '' }))) return
  const reason = window.prompt(t('students.withdrawProfileReason'))
  if (!reason || reason.trim().length < 4) { profileError.value = t('students.archiveReasonRequired'); return }
  withdrawingProfileLink.value = link.id
  profileError.value = ''
  try {
    const result = await supabase.rpc('withdraw_student_from_class', { p_student: profileStudent.value?.id, p_enrollment: link.id, p_reason: reason.trim() })
    if (result.error) throw result.error
    success.value = t('students.withdrawProfileSuccess', { className: classItem?.title || '' })
    if (profileStudent.value) await openHistory(profileStudent.value, false)
  } catch (cause) { profileError.value = errText(cause) }
  finally { withdrawingProfileLink.value = '' }
}

function add() {
  editId.value = null
  Object.assign(form, fresh())
  open.value = true
}

function edit(student: Student) {
  editId.value = student.id
  Object.assign(form, {
    first_name: student.first_name,
    last_name: student.last_name,
    guardian_name: student.guardian_name || '',
    phone: student.phone || '',
    guardian_phone: student.guardian_phone || '',
    address: student.address || '',
    active: student.active,
    registered_on: student.registered_on,
    notes: student.notes || ''
  })
  open.value = true
}

async function save() {
  if (!supabase || saving.value) return
  saving.value = true
  error.value = ''
  success.value = ''
  try {
    const payload = {
      first_name: form.first_name.trim(),
      last_name: form.last_name.trim(),
      guardian_name: form.guardian_name || null,
      phone: form.phone || null,
      guardian_phone: form.guardian_phone || null,
      address: form.address || null,
      ...(editId.value ? {} : { active: true }),
      registered_on: form.registered_on,
      notes: form.notes || null
    }
    if (!payload.first_name) throw new Error(t('students.nameRequired'))
    const result = editId.value
      ? await supabase.from('students').update(payload).eq('id', editId.value)
      : await supabase.from('students').insert(payload)
    if (result.error) throw result.error
    open.value = false
    success.value = t('students.saveSuccess')
    await load()
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    saving.value = false
  }
}

async function openHistory(student: Student, showStandalone = true) {
  if (!supabase || !auth.canEducation.value) return
  historyStudent.value = student
  historyRows.value = []
  historyLinks.value = []
  historyEvents.value = []
  historyRegistrations.value = []
  historyMissingMonths.value = []
  historyPayments.value = []
  historyAccounts.value = []
  historyMaterials.value = []
  historyError.value = ''
  historyWarning.value = ''
  historyOpen.value = showStandalone
  historyLoading.value = true
  try {
    const historyRequests = await Promise.allSettled([
      allRows(() => supabase.from('v_historical_student_classes')
        .select('*').eq('student_id', student.id).order('year_month', { ascending: false })),
      (async () => {
        const result = await supabase!.rpc('monthly_registration_list', { p_month: null, p_student: student.id })
        if (result.error) throw result.error
        return Array.isArray(result.data) ? result.data : []
      })(),
      allRows(() => supabase!.from('enrollments')
        .select('id,student_id,class_id,enrolled_on,active,class_item:class_rooms(title,start_time,end_time,teacher:teachers(full_name))')
        .eq('student_id', student.id).order('enrolled_on', { ascending: false }).order('id')),
      allRows(() => supabase!.from('billing_periods').select('id,year_month').order('year_month')),
      auth.profile.value?.role === 'admin' ? allRows(() => supabase!.from('audit_logs')
        .select('id,action,row_id,created_at,old_data,new_data')
        .eq('table_name', 'enrollments')
        .or(`old_data->>student_id.eq.${student.id},new_data->>student_id.eq.${student.id}`)
        .order('created_at', { ascending: false })) : Promise.resolve([])
    ])
    const requestNames = ['historical import rows', 'monthly registration RPC', 'class enrollment links', 'billing periods', 'class audit events']
    const values: any[] = []
    for (let index = 0; index < historyRequests.length; index++) {
      const request = historyRequests[index]
      if (!request) continue
      if (request.status === 'fulfilled') { values.push(request.value); continue }
      const cause = request.reason
      const detail = cause && typeof cause === 'object' ? { code: cause.code, message: cause.message } : { message: String(cause) }
      console.error(`[student-history] ${requestNames[index]} failed`, detail)
      if (index === 1 || index === 2 || index === 3) throw cause
      historyWarning.value = t('students.historyPartialWarning')
      values.push([])
    }
    const [legacyRows, registrations, links, periods, auditRows] = values
    historyRows.value = legacyRows as any[]
    historyRegistrations.value = registrations as MonthlyRegistration[]
    historyLinks.value = links as any[]
    historyEvents.value = auditRows as any[]

    const registrationsByLinkMonth = new Set(historyRegistrations.value.map(row => `${row.enrollment.id}|${row.period?.year_month || ''}`))
    const currentMonth = nowMonth()
    const monthlyGaps = new Map<string, any>()
    for (const link of historyLinks.value) {
      const linkEvents = historyEvents.value.filter(event => event.row_id === link.id)
      if (!link.active && !linkEvents.length) continue
      const intervals: Array<{ start: string; end: string }> = []
      let activeFrom: string | null = String(link.enrolled_on || '').slice(0, 7) || null
      for (const event of [...linkEvents].sort((a, b) => a.created_at.localeCompare(b.created_at))) {
        if (event.new_data?.active === false && activeFrom) {
          intervals.push({ start: activeFrom, end: String(event.created_at).slice(0, 7) })
          activeFrom = null
        } else if (event.new_data?.active === true && !activeFrom) {
          activeFrom = String(event.created_at).slice(0, 7)
        }
      }
      if (link.active && activeFrom) intervals.push({ start: activeFrom, end: currentMonth })
      for (const interval of intervals) for (const period of periods as any[]) {
        const periodMonth = String(period.year_month).slice(0, 7)
        if (periodMonth < interval.start || periodMonth > interval.end) continue
        if (!registrationsByLinkMonth.has(`${link.id}|${periodMonth}`)) {
          monthlyGaps.set(`${link.id}|${periodMonth}`, { ...link, year_month: periodMonth })
        }
      }
    }
    historyMissingMonths.value = [...monthlyGaps.values()].sort((a, b) => b.year_month.localeCompare(a.year_month))

    if (auth.canFinance.value) {
      const financeRows = await allRows(() => supabase.from('month_fee_overview')
        .select('id,period_id,class_name,paid_total,balance_due,confirmation_status')
        .eq('student_id', student.id).order('period_id', { ascending: false }))
      historyAccounts.value = financeRows
      const monthByPeriod = new Map((periods as any[]).map(period => [period.id, period.year_month]))
      const feeByMembership = new Map(financeRows.map((row: any) => [row.id, row]))
      const registrationById = new Map(historyRegistrations.value.map(row => [row.id, row]))
      const membershipIds = historyRegistrations.value.map(row => row.id).filter((id): id is string => !!id)
      const paymentRows = membershipIds.length
        ? await allRows(() => supabase.from('payments').select('id,monthly_membership_id,amount,paid_on,method,voided_at,void_reason')
          .in('monthly_membership_id', membershipIds).order('paid_on', { ascending: false }).order('id'))
        : []
      const [bookSales, chapterSales] = await Promise.all([
        allRows(() => supabase.from('book_sale_overview').select('id,title,sold_on,quantity,total_price,paid_total,balance_due,student_id').eq('student_id', student.id).order('sold_on', { ascending: false })),
        allRows(() => supabase.from('chapter_sale_overview').select('id,title,sold_on,quantity,total_price,paid_total,balance_due,student_id').eq('student_id', student.id).order('sold_on', { ascending: false }))
      ])
      historyMaterials.value = [...bookSales.map((item: any) => ({ ...item, kind: 'book' })), ...chapterSales.map((item: any) => ({ ...item, kind: 'chapter' }))]
      historyPayments.value = paymentRows.map((payment: any) => {
        const registration = registrationById.get(payment.monthly_membership_id)
        const fee = feeByMembership.get(payment.monthly_membership_id)
        return {
          ...payment,
          year_month: registration?.period?.year_month || monthByPeriod.get(fee?.period_id) || '',
          class_name: registrationClassName(registration) || fee?.class_name || '',
          balance_due: fee?.balance_due ?? null
        }
      })
    }
  } catch (cause) {
    historyError.value = errText(cause)
  } finally {
    historyLoading.value = false
  }
}

async function openStudentProfile(student: Student) {
  profileStudent.value = student
  profileOpen.value = true
  profileLoading.value = true
  profileError.value = ''
  try {
    renewalMessageConsents.value = []
    await openHistory(student, false)
    if (supabase && auth.profile.value?.role === 'admin') {
      const consents = await supabase.rpc('get_student_renewal_message_consents', { p_student: student.id })
      if (consents.error) {
        console.error('[student-profile] renewal consent history failed', { code: consents.error.code, message: consents.error.message })
        historyWarning.value = t('students.historyPartialWarning')
      } else renewalMessageConsents.value = consents.data || []
    }
  }
  catch (cause) { profileError.value = errText(cause) }
  finally { profileLoading.value = false }
}

async function revokeHistoricalRenewalConsent(consent: any) {
  if (!supabase || auth.profile.value?.role !== 'admin' || !profileStudent.value || renewalConsentBusy.value) return
  const note = window.prompt(t('renewalReminders.revokePrompt'))
  if (!note || note.trim().length < 4) return
  renewalConsentBusy.value = consent.phone_e164
  profileError.value = ''
  try {
    const result = await supabase.rpc('record_guardian_message_consent', {
      p_student: profileStudent.value.id,
      p_recipient: consent.recipient_type,
      p_phone: consent.phone_e164,
      p_consented: false,
      p_note: note.trim()
    })
    if (result.error) throw result.error
    const refreshed = await supabase.rpc('get_student_renewal_message_consents', { p_student: profileStudent.value.id })
    if (refreshed.error) throw refreshed.error
    renewalMessageConsents.value = refreshed.data || []
  } catch (cause) { profileError.value = errText(cause) }
  finally { renewalConsentBusy.value = '' }
}

async function setRenewalReminderRecipient(recipient: 'student' | 'guardian') {
  if (!supabase || auth.profile.value?.role !== 'admin' || !profileStudent.value) return
  profileError.value = ''
  try {
    const result = await supabase.rpc('set_renewal_reminder_recipient', {
      p_student: profileStudent.value.id,
      p_recipient: recipient
    })
    if (result.error) throw result.error
    profileStudent.value.renewal_reminder_recipient = recipient
    const listStudent = rows.value.find(row => row.id === profileStudent.value?.id)
    if (listStudent) listStudent.renewal_reminder_recipient = recipient
  } catch (cause) { profileError.value = errText(cause) }
}

async function openClassChange(student: Student) {
  if (!supabase || !auth.canEducation.value) return
  historyStudent.value = student
  classChangeOpen.value = true
  classChangeLoading.value = true
  classChangeError.value = ''
  classChangeSuccess.value = ''
  classChangeTarget.value = ''
  classChangeSourceEnrollmentId.value = ''
  classChangeOperation.value = 'move'
  classChangeDate.value = todayKarachi()
  classChangeFinancialRegistrations.value = []
  classChangeQuery.value = ''
  try {
    const [links, classes, financialResult] = await Promise.all([
      allRows(() => supabase.from('enrollments').select('id,student_id,class_id,enrolled_on,active,class_item:class_rooms(id,title,teacher_id,start_time,end_time,teacher:teachers(full_name))').eq('student_id', student.id).order('enrolled_on', { ascending: false })),
      allRows(() => supabase.from('class_rooms').select('id,title,teacher_id,start_time,end_time,active,teacher:teachers(full_name)').eq('active', true).order('title')),
      supabase.rpc('monthly_registration_list', { p_month: null, p_student: student.id })
    ])
    if (financialResult.error) throw financialResult.error
    classChangeLinks.value = links.filter((link: any) => link.active)
    availableClasses.value = classes
    classChangeFinancialRegistrations.value = (Array.isArray(financialResult.data) ? financialResult.data : []).filter((row: any) => row.registration_active && row.period?.year_month && new Date(`${row.period.year_month}T00:00:00Z`) >= new Date(`${nowMonth()}-01T00:00:00Z`))
  } catch (cause) { classChangeError.value = errText(cause) }
  finally { classChangeLoading.value = false }
}

const targetClass = computed(() => availableClasses.value.find(item => item.id === classChangeTarget.value))
const matchingClasses = computed(() => availableClasses.value.filter(item => normalizeSearchText(`${item.title} ${item.teacher?.full_name || ''}`).includes(normalizeSearchText(classChangeQuery.value))))

async function saveClassChange(operation: 'move' | 'add' | 'correct') {
  if (!supabase || !historyStudent.value || !classChangeTarget.value || classChangeSaving.value) return
  const previousLink = classChangeLinks.value.find(link => link.id === classChangeSourceEnrollmentId.value)
  if (operation === 'add' && classChangeSourceEnrollmentId.value) { classChangeError.value = t('students.addClassDoesNotChangeSource'); return }
  if (operation !== 'add' && !previousLink) { classChangeError.value = t('students.selectSourceClass'); return }
  const sourceHasFinancialRegistration = operation !== 'add' && classChangeFinancialRegistrations.value.some(row => row.enrollment?.id === classChangeSourceEnrollmentId.value)
  if (sourceHasFinancialRegistration) { classChangeError.value = t('students.financialClassCorrectionSeparate'); return }
  if (classChangeDate.value !== todayKarachi()) { classChangeError.value = t('students.classChangeImmediateOnly'); return }
  const reason = operation === 'correct' ? window.prompt(t('students.correctionReasonPrompt')) : null
  if (operation === 'correct' && (!reason || reason.trim().length < 4)) return
  if (!window.confirm(t('students.classOperationConfirmation', { action: t(operation === 'add' ? 'students.addSecondClass' : operation === 'move' ? 'students.transferClass' : 'students.correctWrongClass'), className: targetClass.value?.title || '' }))) return
  classChangeSaving.value = true
  classChangeError.value = ''
  try {
    const result = await supabase.rpc('change_student_class_membership', { p_student: historyStudent.value.id, p_prior_enrollment: operation === 'add' ? null : classChangeSourceEnrollmentId.value, p_class: classChangeTarget.value, p_effective_on: classChangeDate.value, p_operation: operation, p_reason: reason })
    if (result.error) throw result.error
    classChangeSuccess.value = t('students.classChangeSaved')
    await Promise.all([load(), openClassChange(historyStudent.value)])
  } catch (cause) { classChangeError.value = errText(cause) }
  finally { classChangeSaving.value = false }
}

onMounted(load)
watch(month, load)
</script>

<template>
  <div>
    <PageTitle :title="t('students.title')" :subtitle="t('students.subtitle')"><NuxtLink v-if="auth.profile.value?.role==='admin'" class="btn primary" to="/enrollments#monthly-registration">{{t('agreements.newRegistration')}}</NuxtLink>
      <button v-if="auth.canEducation.value" class="btn primary" @click="add">
        <Plus :size="18" aria-hidden="true" />{{ t('students.new') }}
      </button>
    </PageTitle>
    <Notice :message="error" kind="error" />
    <Notice :message="success" kind="success" />
    <section class="card">
      <div class="table-toolbar">
        <label>{{ t('students.profileStatus') }}<select v-model="studentStatusFilter" @change="load"><option value="active">{{ t('students.activeProfiles') }}</option><option value="archived">{{ t('students.archivedProfiles') }}</option></select></label>
        <label>{{ t('students.registrationMonth') }}<input v-model="month" type="month" /></label>
        <div class="search-field">
          <Search :size="18" aria-hidden="true" />
          <input v-model="query" :placeholder="t('students.search')" :aria-label="t('students.search')" />
        </div>
        <span class="badge info">{{ t('students.count', { count: filtered.length }) }}</span>
      </div>
      <div class="table-wrap">
        <table class="data-table">
          <thead>
            <tr>
              <th>{{ t('students.studentId') }}</th>
              <th>{{ t('students.studentName') }}</th>
              <th>{{ t('students.guardian') }}</th>
              <th>{{ t('common.phone') }}</th>
              <th>{{ t('students.monthlyStatus') }}</th>
              <th>{{ t('common.status') }}</th>
              <th>{{ t('common.actions') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="student in filtered" :key="student.id">
              <td><strong dir="ltr">{{ student.student_code }}</strong></td>
              <td><strong class="student-name">{{ student.first_name }} {{ student.last_name }}</strong></td>
              <td>{{ student.guardian_name || '—' }}</td>
              <td dir="ltr">{{ student.phone || student.guardian_phone || '—' }}</td>
              <td>
                <template v-if="registrationsByStudent.has(student.id)">
                  <span v-if="registrationsByStudent.get(student.id)?.activeClasses.length" class="badge success">{{ t('students.registered') }}</span>
                  <span v-else class="badge warning">{{ t('students.cancelled') }}</span>
                  <small v-if="registrationsByStudent.get(student.id)?.activeClasses.length" class="muted" style="display:block">
                    {{ registrationsByStudent.get(student.id)?.activeClasses.join('، ') }}
                  </small>
                  <small v-if="registrationsByStudent.get(student.id)?.cancelledClasses.length" class="muted" style="display:block">
                    {{ t('students.cancelled') }}: {{ registrationsByStudent.get(student.id)?.cancelledClasses.join('، ') }}
                  </small>
                </template>
                <span v-else class="badge">{{ t('students.notRegistered') }}</span>
              </td>
              <td>
                <span :class="['badge', student.active ? 'success' : 'warning']">
                  {{ student.active ? t('common.active') : t('common.inactive') }}
                </span>
              </td>
              <td>
                <button class="btn small-btn" @click="openStudentProfile(student)">{{ t('students.openProfile') }}</button>
                <button v-if="auth.canEducation.value" class="btn small-btn" @click="edit(student)">
                  <Pencil :size="13" aria-hidden="true" />{{ t('common.edit') }}
                </button>
                <button v-if="auth.canEducation.value" class="btn small-btn" @click="openClassChange(student)">{{ t('students.changeClass') }}</button>
                <button v-if="auth.profile.value?.role === 'admin' && student.student_code === NOORZIA_CODE" class="btn small-btn" @click="openNoorziaCorrection(student)">{{ t('students.noorziaCorrection') }}</button>
                <button v-if="auth.profile.value?.role === 'admin'" class="btn small-btn history-button" @click="openHistory(student)">
                  <History :size="13" aria-hidden="true" />{{ t('students.classHistory') }}
                </button>
                <NuxtLink v-if="auth.canEducation.value && student.active" class="btn small-btn" :to="{ path: '/enrollments', query: { student: student.id } }">{{ t('students.monthlyRegistrationShortcut') }}</NuxtLink>
                <button v-if="auth.profile.value?.role === 'admin'" class="btn small-btn" :disabled="archiveStudentBusy" @click="archiveOrRestoreStudent(student)">{{ student.active ? t('students.archiveStudent') : t('students.restoreStudent') }}</button>
              </td>
            </tr>
          </tbody>
        </table>
        <div v-if="loading || !filtered.length" class="empty">
          <Users :size="26" aria-hidden="true" />
          {{ loading ? t('common.loading') : t('students.notFound') }}
        </div>
      </div>
    </section>

    <ModalBox :open="open" :title="t(editId ? 'students.editTitle' : 'students.newTitle')" @close="open = false">
      <form @submit.prevent="save">
        <div class="form-grid">
          <label>{{ t('students.form.firstName') }} *<input v-model="form.first_name" required maxlength="100" /></label>
          <label>{{ t('students.form.lastName') }}<input v-model="form.last_name" maxlength="100" /></label>
          <label>{{ t('students.form.guardianName') }}<input v-model="form.guardian_name" /></label>
          <label>{{ t('students.form.studentPhone') }}<input v-model="form.phone" type="tel" dir="ltr" /></label>
          <label>{{ t('students.form.guardianPhone') }}<input v-model="form.guardian_phone" type="tel" dir="ltr" /></label>
          <label>
            {{ t('common.status') }}
            <select v-model="form.active" disabled>
              <option :value="true">{{ t('common.active') }}</option>
              <option :value="false">{{ t('common.inactive') }}</option>
            </select>
          </label>
          <label>{{ t('students.profileDate') }}<input v-model="form.registered_on" type="date" required /></label>
          <label class="wide">{{ t('students.notes') }}<textarea v-model="form.notes" rows="2" /></label>
          <label class="wide">{{ t('students.address') }}<textarea v-model="form.address" rows="2" /></label>
        </div>
        <div class="form-footer">
          <button type="button" class="btn" @click="open = false">{{ t('common.cancel') }}</button>
          <button class="btn primary" :disabled="saving">
            {{ saving ? t('common.saving') : t('common.save') }}
          </button>
        </div>
      </form>
    </ModalBox>
    <ModalBox :open="profileOpen" :title="t('students.profileTitle')" @close="profileOpen = false">
      <Notice :message="profileError || historyError" kind="error" />
      <Notice :message="historyWarning" kind="info" />
      <div v-if="profileStudent" class="student-profile-overview">
        <header><h3>{{ profileStudent.first_name }} {{ profileStudent.last_name }}</h3><span class="badge info" dir="ltr">{{ profileStudent.student_code }}</span></header>
        <p>{{ profileStudent.active ? t('students.activeProfiles') : t('students.archivedProfiles') }}</p>
        <p>{{ profileStudent.guardian_name || '—' }} · {{ profileStudent.phone || profileStudent.guardian_phone || '—' }}</p>
        <label v-if="auth.profile.value?.role === 'admin'" class="reminder-recipient-setting">{{ t('renewalReminders.defaultRecipient') }}
          <select :value="profileStudent.renewal_reminder_recipient || 'guardian'" @change="setRenewalReminderRecipient(($event.target as HTMLSelectElement).value as 'student' | 'guardian')"><option value="guardian">{{ t('renewalReminders.guardian') }}</option><option value="student">{{ t('renewalReminders.student') }}</option></select>
        </label>
        <details v-if="auth.profile.value?.role === 'admin'" class="renewal-consent-profile"><summary>{{ t('renewalReminders.consentHistory') }}</summary>
          <p v-if="!renewalMessageConsents.length" class="hint">{{ t('renewalReminders.noConsentHistory') }}</p>
          <div v-for="consent in renewalMessageConsents" :key="`${consent.recipient_type}-${consent.phone_e164}`" class="summary-row"><span>{{ t(consent.recipient_type === 'student' ? 'renewalReminders.student' : 'renewalReminders.guardian') }} · <bdi dir="ltr">{{ consent.phone_e164 }}</bdi> · {{ consent.is_active ? t('renewalReminders.consentRecorded') : t('renewalReminders.consentRevoked') }}</span><button v-if="consent.is_active" class="btn small-btn light" :disabled="renewalConsentBusy === consent.phone_e164" @click="revokeHistoricalRenewalConsent(consent)">{{ t('renewalReminders.revokeConsent') }}</button></div>
        </details>
        <div class="profile-shortcuts">
          <button v-if="auth.canEducation.value && profileStudent.active" class="btn primary" @click="profileOpen = false; navigateTo({ path: '/enrollments', query: { student: profileStudent.id } })">{{ t('students.monthlyRegistrationShortcut') }}</button>
          <button v-if="auth.profile.value?.role === 'admin' && profileStudent.student_code === NOORZIA_CODE" class="btn" @click="profileOpen = false; openNoorziaCorrection(profileStudent)">{{ t('students.noorziaCorrection') }}</button>
          <button v-if="auth.canEducation.value" class="btn" @click="profileOpen = false; openClassChange(profileStudent)">{{ t('students.classChange') }}</button>
          <button v-if="auth.canEducation.value" class="btn" @click="edit(profileStudent)">{{ t('common.edit') }}</button>
          <button v-if="auth.profile.value?.role === 'admin'" class="btn" @click="archiveOrRestoreStudent(profileStudent)">{{ profileStudent.active ? t('students.archiveStudent') : t('students.restoreStudent') }}</button>
        </div>
        <div v-if="profileLoading || historyLoading" class="empty">{{ t('common.loading') }}</div>
        <template v-else>
          <h4>{{ t('students.activeClasses') }}</h4>
          <ul><li v-for="link in historyLinks.filter((row: any) => row.active)" :key="link.id">{{ (Array.isArray(link.class_item) ? link.class_item[0] : link.class_item)?.title }} · {{ relatedOne(relatedOne(link.class_item)?.teacher)?.full_name || '—' }} · {{ timeShort(relatedOne(link.class_item)?.start_time) }}–{{ timeShort(relatedOne(link.class_item)?.end_time) }} · {{ link.enrolled_on }} <button v-if="auth.canEducation.value" class="btn small-btn danger" :disabled="withdrawingProfileLink === link.id" @click="withdrawProfileClass(link)">{{ t('classes.withdrawFromClass') }}</button></li></ul>
          <details><summary>{{ t('students.educationHistory') }}</summary><ul><li v-for="link in historyLinks.filter((row: any) => !row.active)" :key="link.id">{{ relatedOne(link.class_item)?.title }} · {{ relatedOne(relatedOne(link.class_item)?.teacher)?.full_name || '—' }} · {{ link.enrolled_on }}</li></ul><div v-for="event in historyEvents" :key="event.id" class="summary-row">{{ event.created_at }} · {{ event.action }}</div></details>
          <h4>{{ t('students.monthlyHistory') }}</h4>
          <div class="table-wrap history-table"><table class="data-table"><thead><tr><th>{{ t('students.registrationMonth') }}</th><th>{{ t('students.historyClass') }}</th><th>{{ t('registration.agreed_fee') }}</th><th>{{ t('registration.discount') }}</th><th>{{ t('students.balance') }}</th><th>{{ t('students.membershipStatus') }}</th></tr></thead><tbody>
            <tr v-for="item in historyRegistrations" :key="item.id"><td>{{ item.period?.year_month }}</td><td>{{ registrationClassName(item) }}</td><td>{{ item.base_fee === undefined ? '—' : money(item.base_fee) }}</td><td>{{ item.discount === undefined ? '—' : money(item.discount) }}</td><td>{{ historyAccounts.find((account: any) => account.id === item.id)?.balance_due == null ? '—' : money(historyAccounts.find((account: any) => account.id === item.id).balance_due) }}</td><td>{{ item.registration_active ? t('students.registered') : t('students.cancelled') }}</td></tr>
          </tbody></table></div>
          <h4>{{ t('students.paymentHistory') }}</h4>
          <div v-for="payment in historyPayments" :key="payment.id" class="summary-row"><span>{{ payment.year_month }} · {{ payment.class_name }} · {{ payment.paid_on }} · {{ payment.voided_at ? t('financialUi.voided') : t('financialUi.valid') }}</span><strong>{{ money(payment.amount) }}</strong></div>
          <p v-if="!historyPayments.length" class="hint">{{ t('students.noPayments') }}</p>
          <h4>{{ t('students.booksChaptersHistory') }}</h4>
          <div v-if="historyMaterials.length" class="table-wrap history-table"><table class="data-table"><thead><tr><th>{{ t('students.historyClass') }}</th><th>{{ t('financialUi.materials.name') }}</th><th>{{ t('financialUi.materials.saleDate') }}</th><th>{{ t('financialUi.materials.totalPrice') }}</th><th>{{ t('financialUi.monthlyReport.received') }}</th><th>{{ t('financialUi.materials.remaining') }}</th></tr></thead><tbody><tr v-for="sale in historyMaterials" :key="`${sale.kind}-${sale.id}`"><td>{{ t(sale.kind === 'book' ? 'nav.books' : 'nav.chapters') }}</td><td>{{ sale.title }} × {{ sale.quantity }}</td><td>{{ sale.sold_on }}</td><td>{{ money(sale.total_price) }}</td><td>{{ money(sale.paid_total) }}</td><td>{{ money(sale.balance_due) }}</td></tr></tbody></table></div>
          <p v-else class="hint">{{ t('students.noBookChapterSales') }}</p>
          <p class="hint">{{ t('students.booksChaptersProfileHint') }} <NuxtLink to="/books">{{ t('nav.books') }}</NuxtLink> · <NuxtLink to="/chapters">{{ t('nav.chapters') }}</NuxtLink></p>
        </template>
      </div>
    </ModalBox>
    <ModalBox :open="classChangeOpen" :title="t('students.changeClass')" @close="classChangeOpen = false">
      <Notice :message="classChangeError" kind="error" />
      <Notice :message="classChangeSuccess" kind="success" />
      <p v-if="historyStudent" class="hint">{{ historyStudent.first_name }} {{ historyStudent.last_name }} · {{ historyStudent.student_code }}</p>
      <p class="hint">{{ t('students.classChangeSafety') }}</p>
      <div v-if="classChangeLoading" class="empty">{{ t('common.loading') }}</div>
      <template v-else>
        <h4>{{ t('students.currentClasses') }}</h4>
        <div v-if="!classChangeLinks.length" class="empty">{{ t('students.noCurrentClasses') }}</div>
        <ul v-else><li v-for="link in classChangeLinks" :key="link.id">{{ (Array.isArray(link.class_item) ? link.class_item[0] : link.class_item)?.title }} · {{ link.enrolled_on }}</li></ul>
        <p class="hint">{{ t('students.classChangeOptions') }}</p>
        <label>{{ t('students.classChangeOperation') }}
          <select v-model="classChangeOperation"><option value="move">{{ t('students.transferClass') }}</option><option value="add">{{ t('students.addSecondClass') }}</option><option value="correct">{{ t('students.correctWrongClass') }}</option></select>
        </label>
        <label>{{ t('students.sourceClass') }}
          <select v-model="classChangeSourceEnrollmentId" :disabled="classChangeOperation === 'add'" @change="classChangeTarget = ''">
            <option value="">{{ t('students.selectSourceClass') }}</option>
            <option v-for="link in classChangeLinks" :key="link.id" :value="link.id" :disabled="classChangeOperation === 'add'">{{ (Array.isArray(link.class_item) ? link.class_item[0] : link.class_item)?.title }} · {{ link.enrolled_on }}</option>
          </select>
        </label>
        <label>{{ t('students.classChangeDate') }}<input v-model="classChangeDate" type="date" :max="todayKarachi()" required /></label>
        <Notice v-if="classChangeFinancialRegistrations.length" :message="t('students.financialClassCorrectionSeparate')" kind="error" />
        <label>{{ t('students.newClass') }}
          <SearchableSelect v-model="classChangeTarget" :options="matchingClasses" label-key="title" :search-keys="['teacher.full_name']" :placeholder="t('students.searchClass')" :min-chars="2">
            <template #option="{ option }">{{ option.title }} · {{ option.teacher?.full_name || '—' }}</template>
          </SearchableSelect>
        </label>
        <p v-if="targetClass" class="hint">{{ t('students.classTeacher') }}: {{ targetClass.teacher?.full_name || '—' }} · {{ t('classes.startTime') }}: {{ targetClass.start_time || '—' }}–{{ targetClass.end_time || '—' }}</p>
        <div class="form-footer">
          <button class="btn primary" :disabled="classChangeSaving || !targetClass || (classChangeOperation !== 'add' && !classChangeSourceEnrollmentId) || !!classChangeFinancialRegistrations.some((row: any) => row.enrollment?.id === classChangeSourceEnrollmentId)" @click="saveClassChange(classChangeOperation)">{{ classChangeSaving ? t('common.saving') : t(classChangeOperation === 'add' ? 'students.addSecondClass' : classChangeOperation === 'move' ? 'students.transferClass' : 'students.correctWrongClass') }}</button>
        </div>
      </template>
    </ModalBox>
    <ModalBox :open="noorziaCorrectionOpen" :title="t('students.noorziaCorrectionTitle')" @close="noorziaCorrectionOpen = false">
      <Notice :message="noorziaCorrectionError" kind="error" />
      <p class="hint">{{ t('students.noorziaCorrectionDescription') }}</p>
      <p class="hint"><strong>{{ t('students.noorziaCorrectionTarget') }}</strong>: School Grade 3 · Tahera Sakhizada · 17:00–18:00 · November 2026</p>
      <div v-if="noorziaCorrectionLoading" class="empty">{{ t('students.noorziaPreflightLoading') }}</div>
      <template v-else-if="noorziaCorrectionPreflight">
        <h4>{{ t('students.noorziaPreflight') }}</h4>
        <ul class="preflight-list">
          <li v-for="check in noorziaCorrectionPreflight.checks" :key="check.key" :class="check.ok ? 'check-ok' : 'check-failed'">
            <strong>{{ check.ok ? '✓' : '✗' }} {{ t(`students.noorziaCheck_${check.key}`) }}</strong><span>{{ check.detail }}</span>
          </li>
        </ul>
        <div v-if="noorziaCorrectionPreflight.ready && !noorziaCorrectionResult" class="noorzia-confirmations">
          <label><input v-model="noorziaRefundConfirmed" type="checkbox" /> {{ t('students.noorziaRefundConfirmation') }}</label>
          <label><input v-model="noorziaRegistrationApproved" type="checkbox" /> {{ t('students.noorziaRegistrationConfirmation') }}</label>
          <label>{{ t('students.noorziaReason') }}<textarea v-model="noorziaCorrectionReason" rows="3" minlength="4" required /></label>
          <p class="hint">{{ t('students.noorziaNoNewCash') }}</p>
          <button class="btn primary" :disabled="!noorziaCorrectionReady" @click="executeNoorziaCorrection">
            {{ noorziaCorrectionSaving ? t('students.noorziaExecuting') : t('students.noorziaFinalAction') }}
          </button>
        </div>
        <section v-if="noorziaCorrectionReadback" class="noorzia-result" :class="noorziaCorrectionReadback.passed ? 'check-ok' : 'check-failed'">
          <h4>{{ noorziaCorrectionReadback.passed ? t('students.noorziaResultSuccess') : t('students.noorziaResultReview') }}</h4>
          <p>{{ t('students.noorziaResultClass') }}: {{ noorziaCorrectionReadback.passed ? 'School Grade 3 · Tahera Sakhizada' : 'Read-back mismatch' }}</p>
          <p>{{ t('students.noorziaResultFee') }}: {{ money(noorziaCorrectionReadback.newMembership?.base_fee || 0) }} · {{ t('students.noorziaResultDiscount') }}: {{ money(noorziaCorrectionReadback.newMembership?.discount || 0) }}</p>
          <p>{{ t('students.noorziaResultPaid') }}: {{ money(noorziaCorrectionReadback.paymentTotal || 0) }} · {{ t('students.noorziaResultBalance') }}: {{ money(noorziaCorrectionReadback.newMembership?.amount_due || 0) }}</p>
          <p>{{ t('students.noorziaResultReceipt') }}: {{ noorziaCorrectionReadback.receipt?.voided_at ? t('financialUi.voided') : t('financialUi.valid') }} · {{ noorziaCorrectionReadback.receipt?.id }}</p>
          <p>{{ t('students.noorziaResultAudit') }}: {{ noorziaCorrectionReadback.audit?.created_at || 'missing' }}</p>
        </section>
      </template>
    </ModalBox>
    <ModalBox :open="historyOpen" :title="t('students.classHistory')" @close="historyOpen = false">
      <Notice :message="historyError" kind="error" />
      <Notice :message="historyWarning" kind="info" />
      <p v-if="historyStudent" class="hint">{{ historyStudent.first_name }} {{ historyStudent.last_name }} · {{ historyStudent.student_code }}</p>
      <p class="hint">{{ t('students.historyDisclaimer') }}</p>
      <div v-if="historyLoading" class="empty">{{ t('common.loading') }}</div>
      <template v-else>
      <h4>{{ t('students.classLinksHistory') }}</h4>
      <div v-if="!historyLinks.length" class="empty">{{ t('students.noClassHistory') }}</div>
      <div v-else class="table-wrap history-table">
        <table class="data-table">
          <thead><tr><th>{{ t('students.historyClass') }}</th><th>{{ t('classes.enrolledOn') }}</th><th>{{ t('students.membershipStatus') }}</th></tr></thead>
          <tbody><tr v-for="link in historyLinks" :key="link.id">
            <td>{{ (Array.isArray(link.class_item) ? link.class_item[0] : link.class_item)?.title || '—' }}</td><td>{{ link.enrolled_on }}</td>
            <td><span :class="['badge', link.active ? 'success' : 'warning']">{{ link.active ? t('common.active') : t('common.inactive') }}</span></td>
          </tr></tbody>
        </table>
      </div>
      <h4>{{ t('students.monthlyHistory') }}</h4>
      <div v-if="historyRegistrations.length" class="table-wrap history-table">
        <table class="data-table">
          <thead><tr><th>{{ t('students.registrationMonth') }}</th><th>{{ t('students.historyClass') }}</th><th>{{ t('classes.enrolledOn') }}</th><th>{{ t('classes.registrationStatus') }}</th></tr></thead>
          <tbody><tr v-for="item in historyRegistrations" :key="item.id">
            <td>{{ item.period?.year_month }}</td><td>{{ registrationClassName(item) || '—' }}</td><td>{{ item.registered_on }}</td>
            <td><span :class="['badge', item.registration_active && item.registration_status === 'registered' ? 'success' : 'warning']">{{ !item.registration_active ? t('classes.cancelledThisMonth') : item.registration_status === 'registered' ? t('classes.confirmedThisMonth') : t('classes.notRegisteredThisMonth') }}</span><small v-if="item.registration_active" class="material-id">{{ t(`classes.payment_${item.payment_status || 'unpaid'}`) }}</small></td>
          </tr></tbody>
        </table>
      </div>
      <p v-else class="empty">{{ t('students.noClassHistory') }}</p>
      <h4>{{ t('students.monthsWithoutRegistration') }}</h4>
      <div v-if="historyMissingMonths.length" class="table-wrap history-table">
        <table class="data-table"><thead><tr><th>{{ t('students.registrationMonth') }}</th><th>{{ t('students.historyClass') }}</th></tr></thead><tbody>
          <tr v-for="(item, index) in historyMissingMonths" :key="`${item.id}-${item.year_month}-${index}`"><td>{{ item.year_month }}</td><td>{{ registrationClassName(item) || '—' }}</td></tr>
        </tbody></table>
      </div>
      <p v-else class="hint">{{ t('students.noMissingMonths') }}</p>
      <template v-if="auth.canFinance.value">
        <h4>{{ t('students.paymentHistory') }}</h4>
        <div v-if="historyPayments.length" class="table-wrap history-table">
          <table class="data-table"><thead><tr><th>{{ t('students.registrationMonth') }}</th><th>{{ t('students.historyClass') }}</th><th>{{ t('financialUi.paymentDate') }}</th><th>{{ t('financialUi.amount') }}</th><th>{{ t('students.balance') }}</th><th>{{ t('financialUi.status') }}</th></tr></thead><tbody>
            <tr v-for="payment in historyPayments" :key="payment.id"><td>{{ payment.year_month }}</td><td>{{ payment.class_name }}</td><td>{{ payment.paid_on }}</td><td>{{ money(payment.amount) }}</td><td>{{ payment.balance_due === null ? '—' : money(payment.balance_due) }}</td><td>{{ payment.voided_at ? t('financialUi.voided') : t('financialUi.valid') }}</td></tr>
          </tbody></table>
        </div>
        <p v-else class="hint">{{ t('students.noPayments') }}</p>
      </template>
      <h4>{{ t('students.classChangeTimeline') }}</h4>
      <div v-if="historyEvents.length" class="table-wrap history-table"><table class="data-table">
        <thead><tr><th>{{ t('financialUi.date') }}</th><th>{{ t('students.historyClass') }}</th><th>{{ t('students.classChange') }}</th></tr></thead><tbody>
          <tr v-for="event in historyEvents" :key="event.id"><td>{{ event.created_at }}</td><td>{{ registrationClassName(historyLinks.find(link => link.id === event.row_id)) || '—' }}</td><td>{{ event.new_data?.active === false ? t('students.membershipDeactivated') : event.old_data?.active === false && event.new_data?.active === true ? t('students.membershipReactivated') : event.action === 'INSERT' ? t('students.membershipAdded') : t('students.membershipUpdated') }}</td></tr>
        </tbody></table></div>
      <section v-if="historyRows.length" class="history-table">
        <h4>{{ t('students.legacyHistory') }}</h4>
        <div class="table-wrap"><table class="data-table">
          <thead><tr><th>{{ t('students.historyMonth') }}</th><th>{{ t('students.historyClass') }}</th><th>{{ t('students.historyTeacher') }}</th><th>{{ t('agreements.schedule') }}</th><th>{{ t('students.historySourceName') }}</th><th>{{ t('students.historyIdentity') }}</th></tr></thead>
          <tbody><tr v-for="(item, index) in historyRows" :key="item.id || `${item.year_month}-${index}`"><td>{{ item.year_month }}</td><td>{{ item.class_name || item.class_title || '—' }}</td><td>{{ item.teacher_name || '—' }}</td><td>{{ item.start_time && item.end_time ? `${timeShort(item.start_time)} – ${timeShort(item.end_time)}` : '—' }}</td><td>{{ item.source_student_name || item.registered_name || '—' }}</td><td><span :class="['badge', item.identity_status === 'confirmed' ? 'success' : 'warning']">{{ item.identity_status === 'confirmed' ? t('students.identityConfirmed') : t('students.identityNeedsReview') }}</span></td></tr></tbody>
        </table></div>
      </section>
      </template>
    </ModalBox>
  </div>
</template>

<style scoped>
.student-name { display: inline-block; font-size: 17px; font-weight: 650; line-height: 1.5; color: #26334c; }
.history-button { margin-inline-start: 5px; }
.history-table { margin-top: 14px; }
.student-profile-overview header,.profile-shortcuts { display:flex;align-items:center;gap:8px;flex-wrap:wrap; }
.student-profile-overview header h3 { margin:0; }
.profile-shortcuts { margin:14px 0; }
.preflight-list { padding-inline-start: 22px; }
.preflight-list li { margin: 8px 0; }
.preflight-list li span { display: block; color: #667085; font-size: 13px; }
.check-ok { color: #18794e; }
.check-failed { color: #b42318; }
.noorzia-confirmations { display: grid; gap: 12px; margin-block: 16px; }
.noorzia-confirmations label { display: flex; align-items: flex-start; gap: 8px; }
.noorzia-confirmations label:last-of-type { display: grid; }
.noorzia-result { margin-top: 16px; padding: 12px; border: 1px solid currentColor; border-radius: 8px; }
@media (max-width: 780px) { .student-name { font-size: 17px; } .history-table { overflow-x: auto; } }
</style>
