<script setup lang="ts">
import { Plus, GraduationCap, Pencil } from 'lucide-vue-next'
import type { Teacher } from '~/types/models'

const supabase = useSupabase()
const auth = useAuth()
const { t } = useLanguage()
const rows = ref<Teacher[]>([])
const error = ref('')
const success = ref('')
const loading = ref(false)
const open = ref(false)
const editId = ref<string | null>(null)
const saving = ref(false)
const form = reactive({ full_name: '', phone: '', active: true })

async function load() {
  if (!supabase) return
  loading.value = true
  const { data, error: loadError } = await supabase.from('teachers')
    .select('*').order('created_at', { ascending: false })
  if (loadError) error.value = errText(loadError)
  else rows.value = data || []
  loading.value = false
}

function edit(teacher?: Teacher) {
  editId.value = teacher?.id || null
  Object.assign(form, {
    full_name: teacher?.full_name || '',
    phone: teacher?.phone || '',
    active: teacher?.active ?? true
  })
  open.value = true
}

async function save() {
  if (!supabase || saving.value) return
  saving.value = true
  error.value = ''
  try {
    const payload = { full_name: form.full_name.trim(), phone: form.phone || null, active: form.active }
    if (!payload.full_name) throw new Error(t('teachers.nameRequired'))
    const result = editId.value
      ? await supabase.from('teachers').update(payload).eq('id', editId.value)
      : await supabase.from('teachers').insert(payload)
    if (result.error) throw result.error
    open.value = false
    success.value = t('teachers.saveSuccess')
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
    <PageTitle :title="t('teachers.title')" :subtitle="t('teachers.subtitle')">
      <button v-if="auth.canEducation.value" class="btn primary" @click="edit()">
        <Plus :size="18" aria-hidden="true" />{{ t('teachers.new') }}
      </button>
    </PageTitle>
    <Notice :message="error" kind="error" />
    <Notice :message="success" kind="success" />
    <section class="card">
      <div class="table-wrap">
        <table class="data-table">
          <thead>
            <tr>
              <th>{{ t('teachers.fullName') }}</th>
              <th>{{ t('common.phone') }}</th>
              <th>{{ t('teachers.share') }}</th>
              <th>{{ t('common.status') }}</th>
              <th>{{ t('common.actions') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="teacher in rows" :key="teacher.id">
              <td><strong>{{ teacher.full_name }}</strong></td>
              <td dir="ltr">{{ teacher.phone || '—' }}</td>
              <td><span class="badge info">{{ t('teachers.standardShare') }}</span></td>
              <td>
                <span :class="['badge', teacher.active ? 'success' : 'warning']">
                  {{ teacher.active ? t('common.active') : t('common.inactive') }}
                </span>
              </td>
              <td>
                <button v-if="auth.canEducation.value" class="btn small-btn" @click="edit(teacher)">
                  <Pencil :size="13" aria-hidden="true" />{{ t('common.edit') }}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
        <div v-if="loading || !rows.length" class="empty">
          <GraduationCap :size="26" aria-hidden="true" />
          {{ loading ? t('common.loading') : t('teachers.notFound') }}
        </div>
      </div>
    </section>
    <ModalBox :open="open" :title="t(editId ? 'teachers.editTitle' : 'teachers.newTitle')" @close="open = false">
      <form @submit.prevent="save">
        <div class="form-grid">
          <label>{{ t('teachers.fullName') }} *<input v-model="form.full_name" required /></label>
          <label>{{ t('common.phone') }}<input v-model="form.phone" type="tel" dir="ltr" /></label>
          <label class="wide">
            {{ t('common.status') }}
            <select v-model="form.active">
              <option :value="true">{{ t('common.active') }}</option>
              <option :value="false">{{ t('common.inactive') }}</option>
            </select>
          </label>
        </div>
        <p class="hint" style="margin-top:13px">{{ t('teachers.shareGuidance') }}</p>
        <div class="form-footer">
          <button type="button" class="btn" @click="open = false">{{ t('common.cancel') }}</button>
          <button class="btn primary" :disabled="saving">{{ saving ? t('common.saving') : t('common.save') }}</button>
        </div>
      </form>
    </ModalBox>
  </div>
</template>
