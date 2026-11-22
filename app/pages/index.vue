<script setup lang="ts">
const financialError=useFinancialError()
import { Wallet, BookOpen, ArrowRight } from 'lucide-vue-next'

const supabase = useSupabase()
const auth = useAuth()
const { t } = useLanguage()
const loading = ref(false)
const registrationRevision = ref(0)
function registrationSaved(){ registrationRevision.value++; load() }
const error = ref('')
const classList = ref<any[]>([])
const tuition = ref<any>(null)
const received = computed(() => Number(tuition.value?.received_total || 0))
const billed = computed(() => Number(tuition.value?.payable_total || 0))
const overdue = computed(() => Number(tuition.value?.outstanding_total || 0))

async function load() {
  if (!supabase) return
  loading.value = true
  error.value = ''
  tuition.value = null
  classList.value = []
  try {
    const [period, classes] = await Promise.all([
      supabase.from('billing_periods').select('id')
        .eq('year_month', monthStart(nowMonth())).maybeSingle(),
      supabase.from('class_rooms').select('id,title,default_fee,teacher:teachers(full_name)')
        .eq('active', true).order('created_at', { ascending: false }).limit(5)
    ])
    if (period.error || classes.error) throw period.error || classes.error
    classList.value = classes.data || []
    if (period.data && auth.canFinance.value) {
      const summary = await supabase.from('month_tuition_summary').select('*')
        .eq('period_id', period.data.id).maybeSingle()
      if (summary.error) throw summary.error
      tuition.value = summary.data
    }
  } catch (cause) {
    error.value = financialError(cause)
  } finally {
    loading.value = false
  }
}

onMounted(load)
</script>

<template>
  <div>
    <PageTitle :title="t('dashboard.title')" :subtitle="t('dashboard.subtitle')"><NuxtLink v-if="auth.profile.value?.role==='admin'" class="btn primary" to="/enrollments#monthly-registration">{{t('agreements.registerStudent')}}</NuxtLink>
      <button class="btn" :disabled="loading" @click="load">{{ t('common.refresh') }}</button>
    </PageTitle>
    <Notice :message="error" kind="error" />
    <RegistrationStatistics :key="registrationRevision" />
    <MonthlyRegistration v-if="auth.canEducation.value" @saved="registrationSaved" />
    <OfficeSummary v-if="auth.canFinance.value" :key="registrationRevision" />
    <div class="grid-two dashboard-grid">
      <section class="card">
        <div class="card-header">
          <div>
            <h3>{{ t('dashboard.monthOverview') }}</h3>
            <p>{{ t('dashboard.calculatedFrom') }}</p>
          </div>
          <Wallet :size="19" class="muted" aria-hidden="true" />
        </div>
        <template v-if="auth.canFinance.value">
          <div v-if="loading && !tuition" class="empty">{{ t('common.loading') }}</div>
          <template v-else-if="tuition">
            <div class="stats-strip">
              <div class="stat-line"><span>{{ t('dashboard.payable') }}</span><strong><bdi>{{ money(billed) }}</bdi></strong></div>
              <div class="stat-line"><span>{{ t('dashboard.collected') }}</span><strong class="positive"><bdi>{{ money(received) }}</bdi></strong></div>
              <div class="stat-line"><span>{{ t('dashboard.outstanding') }}</span><strong class="caution"><bdi>{{ money(overdue) }}</bdi></strong></div>
            </div>
            <div class="progress-bar" :aria-label="t('dashboard.collected')">
              <div :style="{ width: billed ? `${received / billed * 100}%` : '0%' }"></div>
            </div>
            <p class="hint dashboard-hint">{{ t('dashboard.notProfit') }}</p>
            <NuxtLink to="/finance" class="btn light dashboard-link">
              {{ t('nav.tuition') }}<ArrowRight :size="16" aria-hidden="true" />
            </NuxtLink>
          </template>
          <div v-else-if="error" class="accent-callout">{{ t('dashboard.financialUnavailable') }}</div>
          <div v-else class="accent-callout">{{ t('dashboard.noFinancialSummary') }}</div>
        </template>
        <div v-else class="accent-callout">{{ t('dashboard.financeAccess') }}</div>
      </section>
      <section class="card">
        <div class="card-header">
          <div>
            <h3>{{ t('dashboard.latestClasses') }}</h3>
            <p>{{ t('dashboard.teacherAndFee') }}</p>
          </div>
          <BookOpen :size="19" class="muted" aria-hidden="true" />
        </div>
        <div v-if="!classList.length && !loading" class="empty">{{ t('classes.notFound') }}</div>
        <div v-else-if="loading" class="empty">{{ t('common.loading') }}</div>
        <div v-else class="quick-list">
          <div v-for="classItem in classList" :key="classItem.id" class="quick-item">
            <div>
              <strong>{{ classItem.title }}</strong>
              <div class="small muted">{{ (Array.isArray(classItem.teacher) ? classItem.teacher[0] : classItem.teacher)?.full_name || '—' }}</div>
            </div>
            <strong class="small numeric"><bdi>{{ Number(classItem.default_fee) > 0 ? money(classItem.default_fee) : t('financialUi.officeSummary.feeNotSet') }}</bdi></strong>
          </div>
        </div>
        <NuxtLink to="/classes" class="btn light dashboard-link">
          {{ t('nav.classes') }}<ArrowRight :size="16" aria-hidden="true" />
        </NuxtLink>
      </section>
    </div>
    <div class="accent-callout dashboard-guidance">{{ t('dashboard.setupGuidance') }}</div>
  </div>
</template>
