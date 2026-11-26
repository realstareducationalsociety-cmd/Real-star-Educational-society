<script setup lang="ts">
import { Plus, BookOpen, Pencil, Users, RefreshCcw, UserPlus, Search } from 'lucide-vue-next'
import type { ClassItem, Teacher } from '~/types/models'
import { normalizeSearchText } from '~/utils/searchText'

type RosterStudent = { id: string; student_code: string; first_name: string; last_name: string; active: boolean }
type RosterLink = { id: string; student_id: string; class_id: string; enrolled_on: string; active: boolean; student: RosterStudent | null }
type MonthlyFlag = { enrollment_id: string; registration_active: boolean; registration_status: string | null; payment_status: string | null }

const supabase = useSupabase()
const route = useRoute()
const auth = useAuth()
const { t } = useLanguage()
const rows = ref<ClassItem[]>([])
const teachers = ref<Teacher[]>([])
const classCounts = ref<Record<string, number>>({})
const rosterLinks = ref<RosterLink[]>([])
const monthlyFlags = ref<MonthlyFlag[]>([])
const periodExists = ref(false)
const selectedClassId = ref<string | null>(null)
const rosterSearch = ref('')
const rosterStatusFilter = ref('all')
const { query: studentSearch, results: students, error: studentSearchError } = useStudentSearch()
const newStudentId = ref('')
const addingStudent = ref(false)
const withdrawingEnrollmentId = ref('')
const archiveClassBusy = ref(false)
const classStatusFilter = ref<'active' | 'archived'>('active')
const membershipStatus = computed(() => {
  const statuses = new Map<string, { registration: 'confirmed' | 'cancelled'; payment: string | null }>()
  for (const row of monthlyFlags.value) {
    const status = { registration: !row.registration_active ? 'cancelled' as const : 'confirmed' as const, payment: row.payment_status }
    if (row.registration_active || !statuses.has(row.enrollment_id)) statuses.set(row.enrollment_id, status)
  }
  return statuses
})
const selectedClass = computed(() => rows.value.find(row => row.id === selectedClassId.value) || null)
const classRoster = computed(() => rosterLinks.value
  .filter(link => link.active && link.class_id === selectedClassId.value)
  .filter(link => {
    const status = membershipStatus.value.get(link.id)
    if (rosterStatusFilter.value === 'confirmed' && status?.registration !== 'confirmed') return false
    if (rosterStatusFilter.value === 'pending_payment' && status?.payment !== 'unpaid') return false
    if (rosterStatusFilter.value === 'not_registered' && status?.registration === 'confirmed') return false
    const q = normalizeSearchText(rosterSearch.value)
    if (!q) return true
    return normalizeSearchText(`${link.student?.student_code || ''} ${link.student?.first_name || ''} ${link.student?.last_name || ''}`).includes(q)
  })
  .sort((a, b) => (a.student?.student_code || '').localeCompare(b.student?.student_code || '')))
const classMemberCounts = computed(() => {
  const counts: Record<string, number> = {}
  for (const link of rosterLinks.value) {
    if (!link.active || !link.student?.active) continue
    counts[link.class_id] = (counts[link.class_id] || 0) + 1
  }
  return counts
})
const classUnconfirmedCounts = computed(() => {
  const counts: Record<string, number> = {}
  for (const link of rosterLinks.value) {
    if (!link.active || !link.student?.active) continue
    if (membershipStatus.value.get(link.id)?.registration === 'confirmed') continue
    counts[link.class_id] = (counts[link.class_id] || 0) + 1
  }
  return counts
})
const selectedStudent = computed(() => students.value.find(student => student.id === newStudentId.value))
const currentRoster = computed(() => rosterLinks.value.filter(link => link.class_id === selectedClassId.value && link.active))
const selectedConfirmed = computed(() => currentRoster.value.filter(link => link.student?.active && membershipStatus.value.get(link.id)?.registration === 'confirmed').length)
const selectedPendingPayment = computed(() => currentRoster.value.filter(link => link.student?.active && membershipStatus.value.get(link.id)?.payment === 'unpaid').length)
const selectedInactive = computed(() => currentRoster.value.filter(link => !link.student?.active).length)
const selectedUnregistered = computed(() => currentRoster.value.filter(link => link.student?.active &&
  membershipStatus.value.get(link.id)?.registration !== 'confirmed').length)
const selectedActiveCount = computed(() => currentRoster.value.filter(link => link.student?.active).length)
const selectedRegistrationRate = computed(() => selectedActiveCount.value
  ? Math.round(selectedConfirmed.value * 100 / selectedActiveCount.value)
  : 0)
const selectedPayments = ref({ paid: 0, outstanding: 0 })
const month = ref(nowMonth())
const error = ref('')
const success = ref('')
const loading = ref(false)
const saving = ref(false)
const open = ref(false)
const editId = ref<string | null>(null)
const form = reactive({ title: '', teacher_id: '', default_fee: 0, start_time: '', end_time: '', active: true })

async function load() {
  if (!supabase) return
  loading.value = true
  error.value = ''
  try {
    const [classResult, teacherResult, periodResult, allLinks] = await Promise.all([
      supabase.from('class_rooms').select('*,teacher:teachers(full_name)').eq('active', classStatusFilter.value === 'active').order('created_at', { ascending: false }),
      supabase.from('teachers').select('*').eq('active', true).order('full_name'),
      supabase.from('billing_periods').select('id').eq('year_month', monthStart(month.value)).maybeSingle(),
      allRows(() => supabase.from('enrollments')
        .select('id,student_id,class_id,enrolled_on,active,student:students(id,student_code,first_name,last_name,active)')
        .eq('active', true).order('id'))
    ])
    const queryError = classResult.error || teacherResult.error || periodResult.error
    if (queryError) throw queryError
    rows.value = (classResult.data || []) as unknown as ClassItem[]
    teachers.value = (teacherResult.data || []) as Teacher[]
    rosterLinks.value = allLinks as RosterLink[]
    monthlyFlags.value = []
    periodExists.value = !!periodResult.data
    classCounts.value = {}
    selectedPayments.value = { paid: 0, outstanding: 0 }
    if (periodResult.data) {
      const monthlyResult = await supabase.rpc('monthly_registration_list', { p_month: monthStart(month.value) })
      if (monthlyResult.error) throw monthlyResult.error
      monthlyFlags.value = (Array.isArray(monthlyResult.data) ? monthlyResult.data : [])
        .filter((item: any) => item.enrollment?.id)
        .map((item: any) => ({
          enrollment_id: item.enrollment.id,
          registration_active: item.registration_active === true,
          registration_status: item.registration_status || null,
          payment_status: item.payment_status || null
        })) as MonthlyFlag[]
      selectedPayments.value = { paid: 0, outstanding: 0 }
      if (auth.canFinance.value) {
        const feeRows = await allRows(() => supabase.from('month_fee_overview').select('class_id,paid_total,balance_due')
          .eq('period_id', periodResult.data!.id).order('id'))
        const classFees = feeRows.filter(item => item.class_id === selectedClassId.value)
        selectedPayments.value = classFees.reduce((sum, item) => ({
          paid: sum.paid + Number(item.paid_total || 0),
          outstanding: sum.outstanding + Number(item.balance_due || 0)
        }), { paid: 0, outstanding: 0 })
      }
      const activeLinks = new Map(rosterLinks.value.filter(link => link.active && link.student?.active).map(link => [link.id, link]))
      for (const flag of monthlyFlags.value) {
        if (!flag.registration_active) continue
        const link = activeLinks.get(flag.enrollment_id)
        if (link && membershipStatus.value.get(flag.enrollment_id)?.registration === 'confirmed') {
          classCounts.value[link.class_id] = (classCounts.value[link.class_id] || 0) + 1
        }
      }
    }
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    loading.value = false
  }
}

async function showRoster(classItem: ClassItem) {
  selectedClassId.value = classItem.id
  rosterSearch.value = ''
  rosterStatusFilter.value = 'all'
  studentSearch.value = ''
  newStudentId.value = ''
  students.value = []
  await nextTick()
  document.getElementById('class-roster')?.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

async function addToClass() {
  if (!supabase || !auth.canEducation.value || addingStudent.value || !selectedClass.value) return
  const person = selectedStudent.value
  if (!person || !person.active || !selectedClass.value.active) {
    error.value = t('classes.chooseValidStudent')
    return
  }
  // Educational link only. Never create monthly memberships, a fee, or a receipt here.
  if (!window.confirm(t('classes.confirmAddStudent', { name: `${person.first_name} ${person.last_name}`, className: selectedClass.value.title }))) return
  addingStudent.value = true
  error.value = ''
  success.value = ''
  try {
    const existing = await supabase.from('enrollments').select('id,active')
      .eq('student_id', person.id).eq('class_id', selectedClass.value.id).maybeSingle()
    if (existing.error) throw existing.error
    if (existing.data?.active) {
      success.value = t('classes.alreadyAssigned')
    } else {
      const response = await supabase.rpc('change_student_class_membership', { p_student: person.id, p_prior_enrollment: null, p_class: selectedClass.value.id, p_effective_on: todayKarachi(), p_operation: 'add', p_reason: null })
      if (response.error) throw response.error
      success.value = t('classes.studentAdded')
    }
    newStudentId.value = ''
    studentSearch.value = ''
    await load()
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    addingStudent.value = false
  }
}

async function withdrawFromClass(link: RosterLink) {
  if (!supabase || !auth.canEducation.value || withdrawingEnrollmentId.value) return
  const studentName = `${link.student?.first_name || ''} ${link.student?.last_name || ''}`.trim()
  if (!window.confirm(t('classes.withdrawConfirmation', { student: `${studentName} · ${link.student?.student_code}`, className: selectedClass.value?.title || '' }))) return
  const reason = window.prompt(t('classes.withdrawReason'))
  if (!reason || reason.trim().length < 4) { error.value = t('classes.withdrawReasonRequired'); return }
  withdrawingEnrollmentId.value = link.id
  error.value = ''
  success.value = ''
  try {
    const result = await supabase.rpc('withdraw_student_from_class', { p_student: link.student_id, p_enrollment: link.id, p_reason: reason.trim() })
    if (result.error) throw result.error
    success.value = t('classes.withdrawSuccess', { student: studentName, className: selectedClass.value?.title || '' })
    await load()
  } catch (cause) { error.value = errText(cause) }
  finally { withdrawingEnrollmentId.value = '' }
}

async function archiveOrRestoreClass(classItem: ClassItem) {
  if (!supabase || auth.profile.value?.role !== 'admin' || archiveClassBusy.value) return
  archiveClassBusy.value = true
  error.value = ''
  try {
    if (classItem.active) {
      const activeCount = rosterLinks.value.filter(link => link.class_id === classItem.id && link.active).length
      const enrollments = await allRows(() => supabase!.from('enrollments').select('id').eq('class_id', classItem.id))
      const enrollmentIds = enrollments.map((row: any) => row.id)
      const [memberships, settlements] = await Promise.all([
        enrollmentIds.length ? allRows(() => supabase!.from('monthly_memberships').select('id').in('enrollment_id', enrollmentIds)) : Promise.resolve([]),
        allRows(() => supabase!.from('teacher_settlements').select('id').eq('class_id', classItem.id))
      ])
      const dependencySummary = t('classes.archiveDependencies', { active: activeCount, registrations: memberships.length, settlements: settlements.length })
      if (activeCount) throw new Error(`${t('classes.archiveHasMembers', { count: activeCount })} ${dependencySummary}`)
      if (!window.confirm(`${t('classes.archiveConfirmation', { name: classItem.title, count: activeCount })}\n${dependencySummary}\n\n${t('classes.archiveHistoryPreserved')}`)) return
      const reason = window.prompt(t('classes.archiveReason'))
      if (!reason || reason.trim().length < 4) throw new Error(t('students.archiveReasonRequired'))
      const result = await supabase.rpc('archive_class', { p_class: classItem.id, p_reason: reason.trim() })
      if (result.error) throw result.error
      success.value = t('classes.archivedSuccess')
    } else {
      if (!window.confirm(t('classes.restoreConfirmation', { name: classItem.title }))) return
      const reason = window.prompt(t('classes.archiveReason'))
      if (!reason || reason.trim().length < 4) throw new Error(t('students.archiveReasonRequired'))
      const result = await supabase.rpc('restore_class', { p_class: classItem.id, p_reason: reason.trim() })
      if (result.error) throw result.error
      success.value = t('classes.restoredSuccess')
    }
    await load()
  } catch (cause) { error.value = errText(cause) }
  finally { archiveClassBusy.value = false }
}

function edit(classItem?: ClassItem) {
  editId.value = classItem?.id || null
  Object.assign(form, {
    title: classItem?.title || '',
    teacher_id: classItem?.teacher_id || '',
    default_fee: Number(classItem?.default_fee || 0),
    start_time: classItem && timeShort(classItem.start_time || null) !== '—' ? timeShort(classItem.start_time || null) : '',
    end_time: classItem && timeShort(classItem.end_time || null) !== '—' ? timeShort(classItem.end_time || null) : '',
    active: classItem?.active ?? true
  })
  if (classItem && !teachers.value.some(teacher => teacher.id === classItem.teacher_id)) {
    const currentTeacher = Array.isArray(classItem.teacher) ? classItem.teacher[0] : classItem.teacher
    teachers.value.push({ id: classItem.teacher_id, full_name: currentTeacher?.full_name || t('classes.inactiveTeacher') } as Teacher)
  }
  open.value = true
}

async function save() {
  if (!supabase || saving.value) return
  saving.value = true
  error.value = ''
  try {
    if (!form.title.trim() || !form.teacher_id) throw new Error(t('classes.nameTeacherRequired'))
    const payload = {
      title: form.title.trim(),
      teacher_id: form.teacher_id,
      default_fee: Number(form.default_fee),
      start_time: form.start_time || null,
      end_time: form.end_time || null,
      ...(editId.value ? {} : { active: true })
    }
    const result = editId.value
      ? await supabase.from('class_rooms').update(payload).eq('id', editId.value)
      : await supabase.from('class_rooms').insert(payload)
    if (result.error) throw result.error
    open.value = false
    success.value = t('classes.saveSuccess')
    await load()
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    saving.value = false
  }
}

onMounted(async () => {
  if (typeof route.query.month === 'string' && isValidMonth(route.query.month)) month.value = route.query.month
  await load()
  const classId = typeof route.query.class === 'string' ? route.query.class : ''
  const classItem = rows.value.find(row => row.id === classId)
  if (classItem) await showRoster(classItem)
})
watch(() => route.query.class, classId => {
  if (typeof classId !== 'string') return
  const classItem = rows.value.find(row => row.id === classId)
  if (classItem) showRoster(classItem)
})
</script>

<template>
  <div>
    <PageTitle :title="t('classes.title')" :subtitle="t('classes.subtitle')">
      <label class="month-field">{{ t('classes.monthlyRegistrations') }}
        <input v-model="month" type="month" @change="load" />
      </label>
      <button v-if="auth.canEducation.value" class="btn primary" @click="edit()">
        <Plus :size="18" aria-hidden="true" />{{ t('classes.new') }}
      </button>
    </PageTitle>
    <Notice :message="error || studentSearchError" kind="error" />
    <Notice :message="success" kind="success" />
    <section class="card">
      <div class="table-toolbar"><label>{{ t('classes.classStatusFilter') }}<select v-model="classStatusFilter" @change="load"><option value="active">{{ t('classes.activeClasses') }}</option><option value="archived">{{ t('classes.archivedClasses') }}</option></select></label></div>
      <div class="table-wrap">
        <table class="data-table">
          <thead>
            <tr>
              <th>{{ t('classes.name') }}</th>
              <th>{{ t('teachers.fullName') }}</th>
              <th>{{ t('classes.activeMembers') }}</th>
              <th>{{ t('classes.monthlyRegistrations') }}</th>
              <th>{{ t('classes.awaitingRegistration') }}</th>
              <th>{{ t('classes.schedule') }}</th>
              <th>{{ t('classes.standardTuition') }}</th>
              <th>{{ t('common.status') }}</th>
              <th>{{ t('common.actions') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="classItem in rows" :key="classItem.id">
              <td><strong>{{ classItem.title }}</strong></td>
              <td>{{ (Array.isArray(classItem.teacher) ? classItem.teacher[0] : classItem.teacher)?.full_name || '—' }}</td>
              <td><strong>{{ classMemberCounts[classItem.id] || 0 }}</strong></td>
              <td><strong>{{ classCounts[classItem.id] || 0 }}</strong></td>
              <td>{{ classUnconfirmedCounts[classItem.id] || 0 }}</td>
              <td dir="ltr">{{ timeShort(classItem.start_time) }} – {{ timeShort(classItem.end_time) }}</td>
              <td class="numeric"><bdi>{{ Number(classItem.default_fee) > 0 ? money(classItem.default_fee) : t('financialUi.officeSummary.feeNotSet') }}</bdi></td>
              <td>
                <span :class="['badge', classItem.active ? 'success' : 'warning']">
                  {{ classItem.active ? t('common.active') : t('common.inactive') }}
                </span>
              </td>
              <td class="row-actions">
                <button class="btn small-btn" @click="showRoster(classItem)"><Users :size="14" aria-hidden="true" />{{ t('classes.viewStudents') }}</button>
                <NuxtLink
                  v-if="auth.canFinance.value"
                  class="btn small-btn"
                  :to="{ path: '/reports/monthly', query: { class: classItem.id, month } }"
                >{{ t('classes.printMonthlyReport') }}</NuxtLink>
                <button v-if="auth.canEducation.value" class="btn small-btn" @click="edit(classItem)">
                  <Pencil :size="13" aria-hidden="true" />{{ t('common.edit') }}
                </button>
                <button v-if="auth.profile.value?.role === 'admin'" class="btn small-btn" :disabled="archiveClassBusy" @click="archiveOrRestoreClass(classItem)">{{ classItem.active ? t('classes.archiveClass') : t('classes.restoreClass') }}</button>
              </td>
            </tr>
          </tbody>
        </table>
        <div v-if="loading || !rows.length" class="empty">
          <BookOpen :size="26" aria-hidden="true" />
          {{ loading ? t('common.loading') : t('classes.notFound') }}
        </div>
      </div>
    </section>
    <section v-if="selectedClass" class="card" id="class-roster" style="margin-top:20px">
      <div class="card-header">
        <div>
          <h3>{{ t('classes.rosterTitle') }}: {{ selectedClass.title }}</h3>
          <p>{{ t('classes.rosterHint') }}</p>
          <p v-if="!periodExists" class="hint">{{ t('classes.noPeriodNotice', { month }) }}</p>
        </div>
        <button class="btn" :disabled="loading" @click="load"><RefreshCcw :size="16" />{{ t('classes.refresh') }}</button>
      </div>
      <div class="table-toolbar">
        <span class="badge info">{{ t('classes.activeMembers') }}: {{ currentRoster.filter(link => link.student?.active).length }}</span>
        <span class="badge success">{{ t('classes.confirmedThisMonth') }}: {{ selectedConfirmed }}</span>
        <span class="badge warning">{{ t('classes.notRegisteredThisMonth') }}: {{ selectedUnregistered }}</span>
        <span class="badge warning">{{ t('classes.pendingPayment') }}: {{ selectedPendingPayment }}</span>
        <span class="badge info">{{ t('classes.registrationRate') }}: {{ selectedRegistrationRate }}%</span>
        <span v-if="auth.canFinance.value" class="badge info">{{ t('classes.paidLabel') }} {{ money(selectedPayments.paid) }} · {{ t('classes.outstandingLabel') }} {{ money(selectedPayments.outstanding) }}</span>
        <span v-if="selectedInactive" class="badge warning">{{ t('classes.inactiveProfileWarning') }}: {{ selectedInactive }}</span>
        <label class="search-field"><Search :size="16" /><input v-model="rosterSearch" :placeholder="t('classes.searchRoster')" /></label>
        <label>{{ t('classes.filterRegistration') }}
          <select v-model="rosterStatusFilter">
            <option value="all">{{ t('classes.allStatuses') }}</option>
            <option value="confirmed">{{ t('classes.confirmedThisMonth') }}</option>
            <option value="pending_payment">{{ t('classes.pendingPayment') }}</option>
            <option value="not_registered">{{ t('classes.notRegisteredThisMonth') }}</option>
            <option value="cancelled">{{ t('classes.cancelledThisMonth') }}</option>
          </select>
        </label>
      </div>
      <div class="table-wrap">
        <table class="data-table">
          <thead><tr><th>{{ t('students.studentId') }}</th><th>{{ t('students.studentName') }}</th><th>{{ t('classes.enrolledOn') }}</th><th>{{ t('classes.registrationStatus') }}</th><th>{{ t('common.status') }}</th><th>{{ t('common.actions') }}</th></tr></thead>
          <tbody>
            <tr v-for="link in classRoster" :key="link.id">
              <td dir="ltr">{{ link.student?.student_code || '—' }}</td>
              <td><strong>{{ link.student?.first_name }} {{ link.student?.last_name }}</strong></td>
              <td dir="ltr">{{ link.enrolled_on || '—' }}</td>
              <td>
                <span v-if="membershipStatus.get(link.id)?.registration === 'confirmed'" class="badge success">{{ t('classes.confirmedThisMonth') }}</span>
                <span v-else-if="membershipStatus.get(link.id)?.registration === 'cancelled'" class="badge warning">{{ t('classes.cancelledThisMonth') }}</span>
                <span v-else class="badge info">{{ t('classes.notRegisteredThisMonth') }}</span>
                <span v-if="membershipStatus.get(link.id)?.payment" class="badge">{{ t(`classes.payment_${membershipStatus.get(link.id)?.payment}`) }}</span>
                <span v-else class="badge warning">{{ t('classes.notRegisteredThisMonth') }}</span>
              </td>
              <td><span :class="['badge', link.student?.active ? 'success' : 'warning']">{{ link.student?.active ? t('common.active') : t('common.inactive') }}</span></td>
              <td><button v-if="auth.canEducation.value" class="btn small-btn danger" :disabled="withdrawingEnrollmentId === link.id" @click="withdrawFromClass(link)">{{ withdrawingEnrollmentId === link.id ? t('common.saving') : t('classes.withdrawFromClass') }}</button></td>
            </tr>
          </tbody>
        </table>
        <div v-if="!classRoster.length" class="empty">{{ t('classes.noRosterMembers') }}</div>
      </div>
      <div v-if="auth.canEducation.value && selectedClass.active" style="margin-top:22px">
        <h4>{{ t('classes.addExistingStudent') }}</h4>
        <p class="hint">{{ t('classes.addExistingHint') }}</p>
        <div class="table-toolbar">
          <label class="wide">{{ t('classes.selectMatchingStudent') }}
            <SearchableSelect v-model="newStudentId" :options="students" remote @search="studentSearch = $event" label-key="first_name" :search-keys="['last_name','student_code','guardian_name']" :placeholder="t('classes.searchCodeName')" :min-chars="2" selected-suffix-key="student_code">
              <template #option="{ option }"><strong>{{ option.first_name }} {{ option.last_name }}</strong> · <span dir="ltr">{{ option.student_code }}</span></template>
            </SearchableSelect>
          </label>
          <button class="btn primary" :disabled="!selectedStudent || addingStudent" @click="addToClass"><UserPlus :size="16" />{{ t('classes.addToClass') }}</button>
          <NuxtLink class="btn" to="/enrollments#monthly-registration">{{ t('classes.monthlyRegistrationLink') }}</NuxtLink>
        </div>
      </div>
    </section>
    <ModalBox :open="open" :title="t(editId ? 'classes.editTitle' : 'classes.newTitle')" @close="open = false">
      <form @submit.prevent="save">
        <div class="form-grid">
          <label class="wide">{{ t('classes.name') }} *
            <input v-model="form.title" :placeholder="t('classes.nameExample')" required />
          </label>
          <label class="wide">{{ t('teachers.fullName') }} *
            <SearchableSelect v-model="form.teacher_id" :options="teachers" label-key="full_name" :placeholder="t('classes.chooseTeacher')" />
          </label>
          <label>{{ t('classes.tuitionCurrency') }}
            <input v-model.number="form.default_fee" type="number" min="0" step="0.01" required />
          </label>
          <label>{{ t('common.status') }}
            <select v-model="form.active" disabled>
              <option :value="true">{{ t('common.active') }}</option>
              <option :value="false">{{ t('common.inactive') }}</option>
            </select>
          </label>
          <label>{{ t('classes.startTime') }}<input v-model="form.start_time" type="time" /></label>
          <label>{{ t('classes.endTime') }}<input v-model="form.end_time" type="time" /></label>
        </div>
        <p class="hint" style="margin-top:15px">{{ t('classes.historicalValues') }}</p>
        <div class="form-footer">
          <button type="button" class="btn" @click="open = false">{{ t('common.cancel') }}</button>
          <button class="btn primary" :disabled="saving">{{ saving ? t('common.saving') : t('common.save') }}</button>
        </div>
      </form>
    </ModalBox>
  </div>
</template>
