<script setup lang="ts">
import { Plus, BookOpen, Pencil } from 'lucide-vue-next'
import type { ClassItem, Teacher } from '~/types/models'

const supabase = useSupabase()
const auth = useAuth()
const { t } = useLanguage()
const rows = ref<ClassItem[]>([])
const teachers = ref<Teacher[]>([])
const classCounts = ref<Record<string, number>>({})
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
  const [classResult, teacherResult, periodResult] = await Promise.all([
    supabase.from('class_rooms').select('*,teacher:teachers(full_name)').order('created_at', { ascending: false }),
    supabase.from('teachers').select('*').eq('active', true).order('full_name'),
    supabase.from('billing_periods').select('id').eq('year_month', monthStart(month.value)).maybeSingle()
  ])
  const queryError = classResult.error || teacherResult.error || periodResult.error
  if (queryError) error.value = errText(queryError)
  else {
    rows.value = (classResult.data || []) as unknown as ClassItem[]
    teachers.value = teacherResult.data || []
    classCounts.value = {}
    if (periodResult.data) {
      const membershipResult = await supabase.from('monthly_memberships')
        .select('enrollment:enrollments!inner(class_id)')
        .eq('period_id', periodResult.data.id)
        .eq('registration_active', true)
      if (membershipResult.error) error.value = errText(membershipResult.error)
      else {
        for (const membership of membershipResult.data || []) {
          const enrollment = membership.enrollment as unknown as { class_id: string }
          classCounts.value[enrollment.class_id] = (classCounts.value[enrollment.class_id] || 0) + 1
        }
      }
    }
  }
  loading.value = false
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
      active: form.active
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

onMounted(load)
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
    <Notice :message="error" kind="error" />
    <Notice :message="success" kind="success" />
    <section class="card">
      <div class="table-wrap">
        <table class="data-table">
          <thead>
            <tr>
              <th>{{ t('classes.name') }}</th>
              <th>{{ t('teachers.fullName') }}</th>
              <th>{{ t('classes.monthlyRegistrations') }}</th>
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
              <td><strong>{{ classCounts[classItem.id] || 0 }}</strong></td>
              <td dir="ltr">{{ timeShort(classItem.start_time) }} – {{ timeShort(classItem.end_time) }}</td>
              <td class="numeric"><bdi>{{ Number(classItem.default_fee) > 0 ? money(classItem.default_fee) : t('financialUi.officeSummary.feeNotSet') }}</bdi></td>
              <td>
                <span :class="['badge', classItem.active ? 'success' : 'warning']">
                  {{ classItem.active ? t('common.active') : t('common.inactive') }}
                </span>
              </td>
              <td class="row-actions">
                <NuxtLink
                  v-if="auth.canFinance.value"
                  class="btn small-btn"
                  :to="{ path: '/reports/monthly', query: { class: classItem.id, month } }"
                >{{ t('classes.printMonthlyReport') }}</NuxtLink>
                <button v-if="auth.canEducation.value" class="btn small-btn" @click="edit(classItem)">
                  <Pencil :size="13" aria-hidden="true" />{{ t('common.edit') }}
                </button>
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
    <ModalBox :open="open" :title="t(editId ? 'classes.editTitle' : 'classes.newTitle')" @close="open = false">
      <form @submit.prevent="save">
        <div class="form-grid">
          <label class="wide">{{ t('classes.name') }} *
            <input v-model="form.title" :placeholder="t('classes.nameExample')" required />
          </label>
          <label class="wide">{{ t('teachers.fullName') }} *
            <select v-model="form.teacher_id" required>
              <option value="">{{ t('classes.chooseTeacher') }}</option>
              <option v-for="teacher in teachers" :key="teacher.id" :value="teacher.id">{{ teacher.full_name }}</option>
            </select>
          </label>
          <label>{{ t('classes.tuitionCurrency') }}
            <input v-model.number="form.default_fee" type="number" min="0" step="0.01" required />
          </label>
          <label>{{ t('common.status') }}
            <select v-model="form.active">
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
