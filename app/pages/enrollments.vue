<script setup lang="ts">
import { SearchableSelect } from '#components'
import { Users, RefreshCcw, CalendarPlus } from 'lucide-vue-next'
import type { Student, ClassItem } from '~/types/models'

type RegistrationRow = {
  id: string
  registration_active: boolean
  registered_on: string
  base_fee: number
  original_fee: number
  proration_rule: 'full_month' | 'half_after_20th'
  discount: number
  enrollment: {
    id: string
    student_id: string
    class_id: string
    student: Pick<Student, 'student_code' | 'first_name' | 'last_name' | 'phone'>
    class_item: Pick<ClassItem, 'title'>
  }
}
type PreviousRegistration = { student_id: string; student_code: string; student_name: string; class_ids: string[]; classes: string[] }
const {t}=useLanguage()
const supabase = useSupabase()
const renewalKey=useRequestKey()
const auth = useAuth()
const classes = ref<ClassItem[]>([])
const rows = ref<any[]>([])
const monthlyRows = ref<RegistrationRow[]>([])
const previousRenewals = ref<PreviousRegistration[]>([])
const month = ref(nowMonth())
const error = ref('')
const success = ref('')
const loading = ref(false)
const loaded = ref(false)
const saving = ref(false)
const showInactive = ref(false)
const selectedClass = ref('')
const discount = ref(0)
const selectedBulkStudents = ref<string[]>([])

const filtered = computed(() => rows.value.filter(r =>
  (!selectedClass.value || r.class_id === selectedClass.value) && (showInactive.value || r.active)))
const eligibleBulk = computed(() => previousRenewals.value.filter(s => !selectedClass.value || s.class_ids.some(id => id === selectedClass.value)))
const monthStartDate = computed(() => monthStart(month.value))

function monthBefore(value: string) {
  const date = new Date(`${value}-01T00:00:00Z`)
  date.setUTCMonth(date.getUTCMonth() - 1)
  return date.toISOString().slice(0, 7)
}

async function load() {
 if(!supabase)return;loading.value=true;loaded.value=false;error.value='';monthlyRows.value=[];previousRenewals.value=[];rows.value=[];
 try {
  if(!isValidMonth(month.value))throw Error('ماه معتبر انتخاب کنید');
  const [rooms,links,current,previous]=await Promise.all([
   allRows(()=>supabase.from('class_rooms').select('*').eq('active',true).order('id')),
   allRows(()=>supabase.from('enrollments').select('*,student:students(student_code,first_name,last_name),class_item:class_rooms(title)').order('id')),
   supabase.rpc('monthly_registration_list',{p_month:monthStart(month.value)}),
   supabase.rpc('monthly_registration_list',{p_month:monthStart(monthBefore(month.value))})
  ]);
  if(current.error||previous.error)throw current.error||previous.error;
  classes.value=rooms as ClassItem[];rows.value=links;
  monthlyRows.value=current.data||[];
  const grouped=new Map<string,PreviousRegistration>();
  for(const item of previous.data||[]){
   if(!item.registration_active)continue;
   const e=item.enrollment,person=e.student;
   const row:PreviousRegistration=grouped.get(e.student_id)||{student_id:e.student_id,student_code:person.student_code,student_name:person.first_name+' '+person.last_name,class_ids:[],classes:[]};
   if(!row.class_ids.includes(e.class_id)){row.class_ids.push(e.class_id);row.classes.push(e.class_item.title)}
   grouped.set(e.student_id,row);
  }
  previousRenewals.value=[...grouped.values()];
  loaded.value=true
 }catch(e){error.value=errText(e)}finally{loading.value=false}
}

async function bulkRenew() {
  if (!supabase || saving.value || !selectedBulkStudents.value.length) return
  const selected = eligibleBulk.value.filter(s => selectedBulkStudents.value.includes(s.student_id))
  const records = selected.map(s => ({
    student_id: s.student_id,
    class_ids: selectedClass.value ? s.class_ids.filter(id => id === selectedClass.value) : s.class_ids,
    discount: Number(discount.value || 0)
  }))
  const date = month.value === nowMonth() ? todayKarachi() : monthStartDate.value
  if (!window.confirm(`تمدید ${selected.length} شاگرد برای ماه ${month.value} تأیید شود؟`)) return
  saving.value = true
  error.value = ''
  success.value = ''
  try {
    const result = await supabase.rpc('renew_monthly_students', {
      p_month: monthStart(month.value),
      p_registration_date: date,
      p_registrations: records,
      p_request: renewalKey.forPayload({month:month.value,date,records})
    })
    if (result.error) throw result.error
    success.value = `ثبت‌نام ماهانه ${selected.length} شاگرد با موفقیت تمدید شد.`
    selectedBulkStudents.value = []
    renewalKey.reset()
    await load()
  } catch (e: any) {
    error.value = errText(e)
  } finally {
    saving.value = false
  }
}

async function cancelRegistration(row: RegistrationRow) {
  if (!supabase) return
  const reason = window.prompt('دلیل لغو ثبت‌نام این ماه را بنویسید (حداقل ۴ حرف):')
  if (!reason) return
  error.value = ''
  success.value = ''
  const result = await supabase.rpc('cancel_monthly_registration', { p_membership: row.id, p_reason: reason })
  if (result.error) error.value = errText(result.error)
  else {
    success.value = 'ثبت‌نام این ماه با حفظ سابقه لغو شد.'
    await load()
  }
}

async function changeEnrollment(row: any) {
  if (!supabase || !auth.canEducation.value) return
  error.value = ''
  let result
  if (row.active) {
    if (!window.confirm('این شاگرد از صنف خارج شود؟ سابقه آموزشی و مالی حفظ می‌شود.')) return
    const reason = window.prompt('دلیل خارج‌کردن شاگرد از صنف را بنویسید (حداقل ۴ حرف):')
    if (!reason || reason.trim().length < 4) { error.value = 'دلیل باید حداقل ۴ حرف باشد.'; return }
    result = await supabase.rpc('withdraw_student_from_class', {
      p_student: row.student_id,
      p_enrollment: row.id,
      p_reason: reason.trim()
    })
  } else {
    if (!window.confirm('ارتباط این شاگرد با صنف دوباره فعال شود؟')) return
    result = await supabase.rpc('change_student_class_membership', {
      p_student: row.student_id,
      p_prior_enrollment: null,
      p_class: row.class_id,
      p_effective_on: todayKarachi(),
      p_operation: 'add',
      p_reason: null
    })
  }
  if (result.error) error.value = errText(result.error)
  else {
    success.value = 'وضعیت ارتباط دائمی صنف تغییر کرد؛ سوابق ثبت‌نام ماهانه دست‌نخورده باقی ماند.'
    await load()
  }
}

onMounted(load)
watch(month, () => {
  selectedBulkStudents.value = []
  load()
})
</script>

<template>
  <div>
    <PageTitle title="ثبت‌نام شاگردان" subtitle="ثبت ماهانه تأییدشده؛ پروفایل دائمی شاگرد برای صنف‌ها و ماه‌های مختلف مشترک می‌ماند."><NuxtLink v-if="auth.profile.value?.role==='admin'" class="btn primary" to="/enrollments#monthly-registration">{{t('agreements.newRegistration')}}</NuxtLink>
      <button class="btn" :disabled="loading" @click="load"><RefreshCcw :size="16" /> تازه‌سازی</button>
    </PageTitle>
    <Notice :message="error" kind="error" />
    <Notice :message="success" kind="success" />
    <MonthlyRegistration v-if="auth.profile.value?.role === 'admin'" @saved="load" />

    <section class="card" style="margin-bottom:20px">
      <div class="table-toolbar">
        <label>ماه ثبت‌نام<input v-model="month" type="month" /></label>
        <span v-if="loaded" class="badge info">{{ monthlyRows.filter(row => row.registration_active).length }} اشتراک فعال در این ماه</span>
      </div>
      <div v-if="!loaded" class="hint">{{ loading ? 'در حال بارگذاری...' : 'معلومات ثبت‌نام در دسترس نیست؛ خطای بالا را بررسی کنید.' }}</div>
      <div v-else-if="!previousRenewals.length" class="hint">برای ماه قبلی ثبت فعال پیدا نشد؛ ثبت شاگردان جدید یا قبلی را از فورم ثبت‌نام بالا انجام دهید.</div>
      <p class="hint">{{ t('agreements.noBulk') }}</p>
    </section>

    <section class="card" style="margin-bottom:20px">
      <div class="card-header"><div><h3>اشتراک‌های ماه انتخاب‌شده</h3><p>هر ردیف نشان‌دهندهٔ یک اشتراک شاگرد در یک صنف برای همین ماه است.</p></div><Users class="muted" :size="21" /></div>
      <div class="table-toolbar">
        <SearchableSelect v-model="selectedClass" :options="classes" label-key="title" :placeholder="t('financialUi.monthlyReport.allClasses')" :allow-empty="true" :empty-label="t('financialUi.monthlyReport.allClasses')" />
        <span v-if="loaded" class="badge info">{{ monthlyRows.filter(row => row.registration_active && (!selectedClass || row.enrollment.class_id === selectedClass)).length }} اشتراک</span>
      </div>
      <div class="table-wrap">
        <table class="data-table">
          <thead><tr><th>نمبر شاگرد</th><th>نام شاگرد</th><th>صنف</th><th>تاریخ ثبت</th><th>فیس اصلی</th><th>فیس قابل محاسبه</th><th>تخفیف</th><th>وضعیت</th><th>عملیات</th></tr></thead>
          <tbody>
            <tr v-for="row in monthlyRows.filter(r => !selectedClass || r.enrollment.class_id === selectedClass)" :key="row.id">
              <td>{{ row.enrollment.student.student_code }}</td>
              <td><strong>{{ row.enrollment.student.first_name }} {{ row.enrollment.student.last_name }}</strong></td>
              <td>{{ row.enrollment.class_item.title }}</td><td>{{ row.registered_on }}</td>
              <td>{{ money(row.original_fee) }}</td><td>{{ money(row.base_fee) }}<small class="material-id">{{ row.proration_rule === 'half_after_20th' ? 'نصف پس از روز بیستم' : 'فیس کامل' }}</small></td><td>{{ money(row.discount) }}</td>
              <td><span :class="['badge', row.registration_active ? 'success' : 'warning']">{{ row.registration_active ? 'فعال' : 'لغوشده' }}</span></td>
              <td><button v-if="auth.canEducation.value && row.registration_active" class="btn small-btn danger" @click="cancelRegistration(row)">لغو این ماه</button></td>
            </tr>
          </tbody>
        </table>
        <div v-if="loading" class="empty">در حال بارگذاری...</div>
        <div v-else-if="loaded && !monthlyRows.length" class="empty">برای این ماه ثبت‌نامی انجام نشده است.</div>
      </div>
    </section>

    <section class="card">
      <div class="card-header"><div><h3>پروفایل‌ها و ارتباط دایمی با صنف‌ها</h3><p>غیرفعال‌کردن ارتباط صنف، سابقه ماهانه را حذف نمی‌کند.</p></div><Users class="muted" :size="21" /></div>
      <div class="table-toolbar">
        <SearchableSelect v-model="selectedClass" :options="classes" label-key="title" :placeholder="t('financialUi.monthlyReport.allClasses')" :allow-empty="true" :empty-label="t('financialUi.monthlyReport.allClasses')" />
        <label style="display:flex;align-items:center;gap:9px"><input v-model="showInactive" type="checkbox" style="width:auto" />نمایش ارتباط‌های غیرفعال</label>
        <span v-if="loaded" class="badge info">{{ filtered.length }} ارتباط</span>
      </div>
      <div class="table-wrap">
        <table class="data-table">
          <thead><tr><th>نمبر شاگرد</th><th>نام شاگرد</th><th>صنف</th><th>تاریخ آغاز</th><th>وضعیت</th><th>عملیات</th></tr></thead>
          <tbody>
            <tr v-for="row in filtered" :key="row.id">
              <td>{{ row.student?.student_code }}</td><td><strong>{{ row.student?.first_name }} {{ row.student?.last_name }}</strong></td>
              <td>{{ row.class_item?.title }}</td><td>{{ row.enrolled_on }}</td>
              <td><span :class="['badge', row.active ? 'success' : 'warning']">{{ row.active ? 'فعال' : 'غیرفعال' }}</span></td>
              <td><button v-if="auth.canEducation.value" class="btn small-btn" @click="changeEnrollment(row)">{{ row.active ? 'غیرفعال کردن' : 'فعال کردن' }}</button></td>
            </tr>
          </tbody>
        </table>
        <div v-if="loading" class="empty">در حال بارگذاری...</div>
        <div v-else-if="loaded && !filtered.length" class="empty">پروفایلی در این فهرست نیست.</div>
      </div>
    </section>

  </div>
</template>
