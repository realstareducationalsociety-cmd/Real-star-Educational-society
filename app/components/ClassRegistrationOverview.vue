<script setup lang="ts">
import { RefreshCcw, CalendarPlus } from 'lucide-vue-next'

type ClassRow = { id: string; title: string; active: boolean }
type EnrollmentRow = { id: string; student_id: string; class_id: string; active: boolean; student: { active: boolean } | null }
type RegistrationFlag = { enrollment_id: string; registration_active: boolean; registration_status: string | null; payment_status: string | null }
type ClassStats = { id: string; title: string; members: number; registered: number; pending: number; unregistered: number; percent: number; paid: number; outstanding: number }

const { t } = useLanguage()
const db = useSupabase()
const auth = useAuth()
const month = ref(nowMonth())
const classes = ref<ClassRow[]>([])
const enrollments = ref<EnrollmentRow[]>([])
const registrations = ref<RegistrationFlag[]>([])
const financials = ref<any[]>([])
const periodExists = ref(false)
const loading = ref(false)
const creating = ref(false)
const error = ref('')
const success = ref('')

const stats = computed<ClassStats[]>(() => {
  const byEnrollment = new Map<string, RegistrationFlag>()
  for (const row of registrations.value) {
    if (row.registration_active || !byEnrollment.has(row.enrollment_id)) byEnrollment.set(row.enrollment_id, row)
  }
  const financeByClass = new Map<string, { paid: number; outstanding: number }>()
  for (const row of financials.value) {
    const tally = financeByClass.get(row.class_id) || { paid: 0, outstanding: 0 }
    tally.paid += Number(row.paid_total || 0)
    tally.outstanding += Number(row.balance_due || 0)
    financeByClass.set(row.class_id, tally)
  }
  return classes.value.map(classItem => {
    const members = enrollments.value.filter(row => row.active && row.student?.active && row.class_id === classItem.id)
    let registered = 0
    let pending = 0
    for (const member of members) {
      const status = byEnrollment.get(member.id)
      if (!status?.registration_active || status.registration_status !== 'registered') continue
      registered++
      if (status.payment_status === 'unpaid') pending++
    }
    const unregistered = Math.max(0, members.length - registered - pending)
    const finance = financeByClass.get(classItem.id) || { paid: 0, outstanding: 0 }
    return {
      id: classItem.id,
      title: classItem.title,
      members: members.length,
      registered,
      pending,
      unregistered,
      percent: members.length ? Math.round(registered * 100 / members.length) : 0,
      ...finance
    }
  }).sort((a, b) => a.title.localeCompare(b.title))
})
const totals = computed(() => stats.value.reduce((result, row) => ({
  members: result.members + row.members,
  registered: result.registered + row.registered,
  pending: result.pending + row.pending,
  unregistered: result.unregistered + row.unregistered,
  paid: result.paid + row.paid,
  outstanding: result.outstanding + row.outstanding
}), { members: 0, registered: 0, pending: 0, unregistered: 0, paid: 0, outstanding: 0 }))
const totalPercent = computed(() => totals.value.members ? Math.round(totals.value.registered * 100 / totals.value.members) : 0)

async function load() {
  if (!db || !isValidMonth(month.value)) return
  loading.value = true
  error.value = ''
  try {
    const [classRows, links, period] = await Promise.all([
      allRows(() => db.from('class_rooms').select('id,title,active').eq('active', true).order('title')),
      allRows(() => db.from('enrollments').select('id,student_id,class_id,active,student:students(active)').eq('active', true).order('id')),
      db.from('billing_periods').select('id').eq('year_month', monthStart(month.value)).maybeSingle()
    ])
    if (period.error) throw period.error
    classes.value = classRows as ClassRow[]
    enrollments.value = links as EnrollmentRow[]
    periodExists.value = !!period.data
    registrations.value = []
    financials.value = []
    if (period.data) {
      const result = await db.rpc('monthly_registration_list', { p_month: monthStart(month.value) })
      if (result.error) throw result.error
      registrations.value = (Array.isArray(result.data) ? result.data : [])
        .filter((row: any) => row.enrollment?.id)
        .map((row: any) => ({
          enrollment_id: row.enrollment.id,
          registration_active: row.registration_active === true,
          registration_status: row.registration_status || null,
          payment_status: row.payment_status || null
        }))
      if (auth.canFinance.value) {
        financials.value = await allRows(() => db.from('month_fee_overview').select('class_id,paid_total,balance_due')
          .eq('period_id', period.data!.id).order('id'))
      }
    }
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    loading.value = false
  }
}

async function createMonth() {
  if (!db || creating.value || auth.profile.value?.role !== 'admin' || !isValidMonth(month.value)) return
  creating.value = true
  error.value = ''
  success.value = ''
  try {
    const result = await db.rpc('ensure_billing_month', { p_month: monthStart(month.value) })
    if (result.error) throw result.error
    success.value = t('classes.monthCreated')
    await load()
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    creating.value = false
  }
}

onMounted(load)
</script>

<template>
  <section class="card class-overview">
    <div class="card-header">
      <div>
        <h3>{{ t('classes.monthlyOverview') }}</h3>
        <p>{{ t('classes.monthlyOverviewHint') }}</p>
      </div>
      <div class="table-toolbar">
        <label>{{ t('classes.monthlyRegistrations') }}<input v-model="month" type="month" @change="load" /></label>
        <button v-if="auth.profile.value?.role === 'admin' && !periodExists" class="btn primary" :disabled="creating || loading" @click="createMonth">
          <CalendarPlus :size="16" />{{ creating ? t('common.saving') : t('classes.createMonth') }}
        </button>
        <button class="btn" :disabled="loading" @click="load"><RefreshCcw :size="16" />{{ t('common.refresh') }}</button>
      </div>
    </div>
    <Notice :message="error" kind="error" />
    <Notice :message="success" kind="success" />
    <p v-if="!periodExists" class="hint">{{ t('classes.monthNotCreated') }}</p>
    <div v-if="loading" class="empty">{{ t('common.loading') }}</div>
    <template v-else>
      <div class="kpi-grid compact-kpis">
        <div class="card kpi"><div><small>{{ t('classes.activeMembers') }}</small><strong>{{ totals.members }}</strong></div></div>
        <div class="card kpi"><div><small>{{ t('classes.confirmedThisMonth') }}</small><strong>{{ totals.registered }}</strong></div></div>
        <div class="card kpi"><div><small>{{ t('classes.pendingPayment') }}</small><strong>{{ totals.pending }}</strong></div></div>
        <div class="card kpi"><div><small>{{ t('classes.notRegisteredThisMonth') }}</small><strong>{{ totals.unregistered }}</strong></div></div>
        <div class="card kpi"><div><small>{{ t('classes.registrationRate') }}</small><strong>{{ totalPercent }}%</strong></div></div>
      </div>
      <div class="table-wrap">
        <table class="data-table">
          <thead><tr><th>{{ t('classes.name') }}</th><th>{{ t('classes.activeMembers') }}</th><th>{{ t('classes.confirmedThisMonth') }}</th><th>{{ t('classes.pendingPayment') }}</th><th>{{ t('classes.notRegisteredThisMonth') }}</th><th>{{ t('classes.registrationRate') }}</th><th v-if="auth.canFinance.value">{{ t('classes.paymentStatus') }}</th></tr></thead>
          <tbody>
            <tr v-for="row in stats" :key="row.id">
              <td><NuxtLink :to="{ path: '/classes', query: { class: row.id, month } }">{{ row.title }}</NuxtLink></td><td>{{ row.members }}</td><td>{{ row.registered }}</td><td>{{ row.pending }}</td><td>{{ row.unregistered }}</td><td>{{ row.percent }}%</td>
              <td v-if="auth.canFinance.value"><span>{{ t('classes.paidLabel') }} {{ money(row.paid) }}</span><br /><span>{{ t('classes.outstandingLabel') }} {{ money(row.outstanding) }}</span></td>
            </tr>
            <tr v-if="!stats.length"><td :colspan="auth.canFinance.value ? 7 : 6" class="empty">{{ t('classes.notFound') }}</td></tr>
          </tbody>
        </table>
      </div>
      <p v-if="!auth.canFinance.value" class="hint">{{ t('classes.financeCountsRestricted') }}</p>
    </template>
  </section>
</template>

<style scoped>
.class-overview { margin: 18px 0; }
.class-overview h3 { margin: 0; }
.class-overview .card-header > div:first-child p { margin: 5px 0 0; }
.class-overview .table-toolbar { margin: 0; }
.compact-kpis { margin: 12px 0 18px; }
</style>
