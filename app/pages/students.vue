<script setup lang="ts">
import { Plus, Search, Users, Pencil, History } from 'lucide-vue-next'
import type { Student } from '~/types/models'

type MonthlyRegistration = {
  registration_active: boolean
  enrollment: {
    student_id: string
    class_item: { title: string }
  }
}

const supabase = useSupabase()
const auth = useAuth()
const { t } = useLanguage()
const rows = ref<Student[]>([])
const registrationRows = ref<MonthlyRegistration[]>([])
const month = ref(nowMonth())
const query = ref('')
const loading = ref(false)
const error = ref('')
const success = ref('')
const open = ref(false)
const saving = ref(false)
const editId = ref<string | null>(null)
const historyOpen = ref(false)
const historyLoading = ref(false)
const historyRows = ref<any[]>([])
const historyStudent = ref<Student | null>(null)
const historyError = ref('')

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
  `${student.student_code} ${student.first_name} ${student.last_name} ${student.phone || ''} ${student.guardian_name || ''}`
    .toLowerCase().includes(query.value.toLowerCase())
))
const registrationsByStudent = computed(() => {
  const grouped = new Map<string, { activeClasses: string[]; cancelledClasses: string[] }>()
  for (const registration of registrationRows.value) {
    const studentId = registration.enrollment.student_id
    const status = grouped.get(studentId) || { activeClasses: [], cancelledClasses: [] }
    const classes = registration.registration_active ? status.activeClasses : status.cancelledClasses
    if (!classes.includes(registration.enrollment.class_item.title)) {
      classes.push(registration.enrollment.class_item.title)
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
      allRows(() => supabase.from('students').select('*').order('created_at', { ascending: false })),
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
      active: form.active,
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

async function openHistory(student: Student) {
  if (!supabase || auth.profile.value?.role !== 'admin') return
  historyStudent.value = student
  historyRows.value = []
  historyError.value = ''
  historyOpen.value = true
  historyLoading.value = true
  try {
    const result = await allRows(() => supabase.from('v_historical_student_classes')
      .select('*').eq('student_id', student.id).order('year_month', { ascending: false }))
    historyRows.value = result as any[]
  } catch (cause) {
    historyError.value = errText(cause)
  } finally {
    historyLoading.value = false
  }
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
                <button v-if="auth.canEducation.value" class="btn small-btn" @click="edit(student)">
                  <Pencil :size="13" aria-hidden="true" />{{ t('common.edit') }}
                </button>
                <button v-if="auth.profile.value?.role === 'admin'" class="btn small-btn history-button" @click="openHistory(student)">
                  <History :size="13" aria-hidden="true" />{{ t('students.classHistory') }}
                </button>
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
            <select v-model="form.active">
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
    <ModalBox :open="historyOpen" :title="t('students.classHistory')" @close="historyOpen = false">
      <Notice :message="historyError" kind="error" />
      <p v-if="historyStudent" class="hint">{{ historyStudent.first_name }} {{ historyStudent.last_name }} · {{ historyStudent.student_code }}</p>
      <p class="hint">{{ t('students.historyDisclaimer') }}</p>
      <div v-if="historyLoading" class="empty">{{ t('common.loading') }}</div>
      <div v-else-if="!historyRows.length" class="empty">{{ t('students.noClassHistory') }}</div>
      <div v-else class="table-wrap history-table">
        <table class="data-table">
          <thead><tr><th>{{ t('students.historyMonth') }}</th><th>{{ t('students.historyClass') }}</th><th>{{ t('students.historyTeacher') }}</th><th>{{ t('agreements.schedule') }}</th><th>{{ t('students.historySourceName') }}</th><th>{{ t('students.historyIdentity') }}</th></tr></thead>
          <tbody><tr v-for="(item, index) in historyRows" :key="item.id || `${item.year_month}-${index}`">
            <td>{{ item.year_month }}</td><td>{{ item.class_name || item.class_title || '—' }}</td><td>{{ item.teacher_name || '—' }}</td>
            <td>{{ item.start_time && item.end_time ? `${timeShort(item.start_time)} – ${timeShort(item.end_time)}` : '—' }}</td>
            <td>{{ item.source_student_name || item.registered_name || '—' }}</td>
            <td><span :class="['badge', item.identity_status === 'confirmed' ? 'success' : 'warning']">{{ item.identity_status === 'confirmed' ? t('students.identityConfirmed') : t('students.identityNeedsReview') }}</span></td>
          </tr></tbody>
        </table>
      </div>
    </ModalBox>
  </div>
</template>

<style scoped>
.student-name { display: inline-block; font-size: 17px; font-weight: 650; line-height: 1.5; color: #26334c; }
.history-button { margin-inline-start: 5px; }
.history-table { margin-top: 14px; }
@media (max-width: 780px) { .student-name { font-size: 17px; } .history-table { overflow-x: auto; } }
</style>
