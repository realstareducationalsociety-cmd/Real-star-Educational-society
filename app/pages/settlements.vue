<script setup lang="ts">
const financialError=useFinancialError()
import { HandCoins, RefreshCcw } from 'lucide-vue-next'

const { t } = useLanguage()
const supabase = useSupabase()
const auth = useAuth()
const month = ref(nowMonth())
const periodId = ref('')
const periodStatus = ref('')
const rows = ref<any[]>([])
const error = ref('')
const success = ref('')
const loading = ref(false)
const loaded = ref(false)
const saving = ref(false)
const modal = ref(false)
const historyOpen = ref(false)
const chosen = ref<any | null>(null)
const history = ref<any[]>([])
const settlementKey = useRequestKey()
const form = reactive({ amount: 0, paid_on: '', method: '', note: '' })
const due = (row: any) => Math.max(0, Number(row.teacher_entitlement) - Number(row.settled_total))
const total = (key: string) => rows.value.reduce((sum, row) => sum + Number(row[key] || 0), 0)

async function load() {
  if (!supabase) return
  loading.value = true
  loaded.value = false
  error.value = ''
  periodId.value = ''
  periodStatus.value = ''
  rows.value = []
  try {
    if (!isValidMonth(month.value)) throw Error(t('financialUi.finance.monthInvalid'))
    const period = await supabase.from('billing_periods').select('id,status')
      .eq('year_month', monthStart(month.value)).maybeSingle()
    if (period.error) throw period.error
    periodId.value = period.data?.id || ''
    periodStatus.value = period.data?.status || ''
    if (periodId.value) {
      rows.value = await allRows(() => supabase.from('teacher_settlement_summary')
        .select('*').eq('period_id', periodId.value).order('teacher_id').order('class_id'))
    }
    loaded.value = true
  } catch (cause) {
    error.value = financialError(cause)
  } finally {
    loading.value = false
  }
}

function openPay(row: any) {
  settlementKey.reset()
  chosen.value = row
  Object.assign(form, { amount: due(row), paid_on: '', method: '', note: '' })
  modal.value = true
}

async function settle() {
  if (!supabase || !chosen.value || saving.value || auth.profile.value?.role !== 'admin') return
  saving.value = true
  error.value = ''
  success.value = ''
  try {
    if (form.amount <= 0 || form.amount > due(chosen.value) || !form.paid_on || !form.method) {
      throw Error(t('financialUi.teacherSettlements.amountInvalid'))
    }
    const payload = {
      id: chosen.value.class_id,
      teacher: chosen.value.teacher_id,
      period: chosen.value.period_id,
      ...form
    }
    const result = await supabase.rpc('record_teacher_settlement', {
      p_period: chosen.value.period_id,
      p_class: chosen.value.class_id,
      p_teacher: chosen.value.teacher_id,
      p_amount: Number(form.amount),
      p_date: form.paid_on,
      p_method: form.method,
      p_note: form.note || null,
      p_request: settlementKey.forPayload(payload)
    })
    if (result.error) throw result.error
    modal.value = false
    success.value = t('financialUi.teacherSettlements.saved')
    await load()
  } catch (cause) {
    error.value = financialError(cause)
  } finally {
    saving.value = false
  }
}

async function openHistory(row: any) {
  if (!supabase) return
  chosen.value = row
  error.value = ''
  const result = await supabase.rpc('teacher_settlement_history', {
    p_period: row.period_id,
    p_class: row.class_id,
    p_teacher: row.teacher_id
  })
  if (result.error) {
    error.value = financialError(result.error)
  } else {
    history.value = result.data || []
    historyOpen.value = true
  }
}

async function voidSettle(row: any) {
  if (!supabase || !chosen.value) return
  const reason = window.prompt(t('financialUi.teacherSettlements.voidPrompt'))
  if (!reason) return
  const result = await supabase.rpc('void_teacher_settlement', { p_id: row.id, p_reason: reason })
  if (result.error) {
    error.value = financialError(result.error)
  } else {
    success.value = t('financialUi.teacherSettlements.voidSaved')
    await openHistory(chosen.value)
    await load()
  }
}

onMounted(load)
</script>

<template>
  <div>
    <PageTitle :title="t('financialUi.teacherSettlements.title')" :subtitle="t('financialUi.teacherSettlements.subtitle')">
      <button class="btn" :disabled="loading" @click="load">
        <RefreshCcw :size="17" /> {{ t('financialUi.refresh') }}
      </button>
    </PageTitle>
    <Notice :message="error" kind="error" />
    <Notice :message="success" kind="success" />
    <section class="card" style="margin-bottom:20px">
      <div class="table-toolbar">
        <label>{{ t('financialUi.teacherSettlements.accountingMonth') }}
          <input v-model="month" type="month" @change="load" />
        </label>
        <span v-if="periodId" :class="['badge', periodStatus === 'open' ? 'success' : 'warning']">
          {{ periodStatus === 'open' ? t('financialUi.teacherSettlements.openMonth') : t('financialUi.teacherSettlements.closedMonth') }}
        </span>
      </div>
      <div class="accent-callout">{{ t('financialUi.teacherSettlements.formula') }}</div>
    </section>

    <div v-if="loaded && periodId" class="kpi-grid">
      <div class="card kpi"><div><small>{{ t('financialUi.teacherSettlements.totalEntitlement') }}</small><strong>{{ money(total('teacher_entitlement')) }}</strong></div></div>
      <div class="card kpi"><div><small>{{ t('financialUi.teacherSettlements.settled') }}</small><strong>{{ money(total('settled_total')) }}</strong></div></div>
      <div class="card kpi"><div><small>{{ t('financialUi.teacherSettlements.remaining') }}</small><strong>{{ money(total('teacher_entitlement') - total('settled_total')) }}</strong></div></div>
      <div class="card kpi"><div><small>{{ t('financialUi.teacherSettlements.classFeesReceived') }}</small><strong>{{ money(total('received_total')) }}</strong></div></div>
    </div>
    <section class="card">
      <div class="card-header">
        <div><h3>{{ t('financialUi.teacherSettlements.byClass') }}</h3><p>{{ t('financialUi.teacherSettlements.multipleClasses') }}</p></div>
        <HandCoins class="muted" :size="21" />
      </div>
      <div class="table-wrap">
        <table class="data-table">
          <thead><tr>
            <th>{{ t('financialUi.teacher') }}</th><th>{{ t('financialUi.class') }}</th>
            <th>{{ t('financialUi.studentPlural') }}</th><th>{{ t('financialUi.teacherSettlements.originalFeeTotal') }}</th>
            <th>{{ t('financialUi.monthlyReport.teacherEntitlement') }}</th><th>{{ t('financialUi.teacherSettlements.teacherPayment') }}</th>
            <th>{{t('agreements.funded')}}</th><th>{{ t('financialUi.monthlyReport.remainingSettlement') }}</th><th>{{ t('financialUi.actions') }}</th>
          </tr></thead>
          <tbody>
            <tr v-for="row in rows" :key="row.class_id + '-' + row.teacher_id">
              <td><strong>{{ row.teacher_name }}</strong></td><td>{{ row.class_name }}</td><td>{{ row.student_count }}</td>
              <td class="numeric">{{ money(row.base_total) }}</td><td class="numeric">{{ money(row.teacher_entitlement) }}</td>
              <td class="numeric">{{ money(row.settled_total) }}</td>
              <td class="numeric">{{money(row.institution_funded)}}</td><td class="numeric"><span class="badge warning">{{ money(due(row)) }}</span></td>
              <td><div style="display:flex;gap:7px">
                <button class="btn small-btn primary" :disabled="auth.profile.value?.role !== 'admin' || due(row) <= 0 || periodStatus !== 'open'" @click="openPay(row)">
                  {{ t('financialUi.teacherSettlements.settle') }}
                </button>
                <NuxtLink class="btn small-btn" :to="{ path: '/reports/monthly', query: { class: row.class_id, teacher: row.teacher_id, month } }">
                  {{ t('financialUi.teacherSettlements.printStatement') }}
                </NuxtLink>
                <NuxtLink class="btn small-btn" :to="{ path: '/reports/monthly', query: { teacher: row.teacher_id, month } }">
                  {{ t('financialUi.teacherSettlements.teacherSummary') }}
                </NuxtLink>
                <button class="btn small-btn" @click="openHistory(row)">{{ t('financialUi.history') }}</button>
              </div></td>
            </tr>
          </tbody>
        </table>
        <div v-if="loading" class="empty">{{ t('financialUi.loading') }}</div>
        <div v-else-if="loaded && !rows.length" class="empty">{{ t('financialUi.teacherSettlements.noStatement') }}</div>
      </div>
    </section>

    <ModalBox :open="modal" :title="t('financialUi.teacherSettlements.teacherPayment')" @close="modal = false">
      <Notice :message="error" kind="error" />
      <form v-if="chosen" @submit.prevent="settle">
        <div class="summary-box" style="margin-bottom:16px">
          <strong>{{ chosen.teacher_name }} — {{ chosen.class_name }}</strong>
          <div class="summary-row"><span>{{ t('financialUi.teacherSettlements.payableBalance') }}</span><strong>{{ money(due(chosen)) }}</strong></div>
          <div class="summary-row"><span>{{ t('financialUi.teacherSettlements.recordedBy') }}</span><strong>{{ auth.profile.value?.full_name || '—' }}</strong></div>
        </div>
        <div class="form-grid">
          <label>{{ t('financialUi.teacherSettlements.paidAmount') }}
            <input v-model.number="form.amount" type="number" min="0.01" step="0.01" :max="due(chosen)" required />
          </label>
          <label>{{ t('financialUi.date') }}<input v-model="form.paid_on" type="date" required /></label>
          <label>{{ t('financialUi.teacherSettlements.paymentMethod') }}
            <select v-model="form.method" required>
              <option value="">{{ t('financialUi.teacherSettlements.choosePaymentMethod') }}</option>
              <option value="cash">{{ t('financialUi.finance.cash') }}</option>
              <option value="bank">{{ t('financialUi.finance.bank') }}</option>
              <option value="other">{{ t('financialUi.expenses.other') }}</option>
            </select>
          </label>
          <label class="wide">{{ t('financialUi.note') }}<textarea v-model="form.note" rows="2" /></label>
        </div>
        <div class="form-footer">
          <button type="button" class="btn" @click="modal = false">{{ t('financialUi.cancel') }}</button>
          <button class="btn primary" :disabled="saving">{{ t('financialUi.teacherSettlements.saveSettlement') }}</button>
        </div>
      </form>
    </ModalBox>

    <ModalBox :open="historyOpen" :title="t('financialUi.teacherSettlements.settleClassHistory')" @close="historyOpen = false">
      <div v-if="chosen" class="hint" style="margin-bottom:15px">{{ chosen.teacher_name }} — {{ chosen.class_name }}</div>
      <div v-if="!history.length" class="empty">{{ t('financialUi.teacherSettlements.noSettlements') }}</div>
      <div v-for="row in history" :key="row.id" class="quick-item" style="margin-bottom:8px">
        <div>
          <strong>{{ money(row.amount) }}</strong>
          <div class="small muted">
            {{ row.paid_on }} · {{ t(`financialUi.finance.${row.method}`) }} ·
            {{ t('financialUi.teacherSettlements.recordedBy') }}: {{ row.recorded_by || '—' }}
            · {{ row.note || t('financialUi.teacherSettlements.noNote') }}
            {{ row.voided_at ? ` · ${t('financialUi.teacherSettlements.voided')}` : '' }}
          </div>
        </div>
        <button v-if="auth.profile.value?.role === 'admin' && !row.voided_at && periodStatus === 'open'" class="btn small-btn danger" @click="voidSettle(row)">
          {{ t('financialUi.void') }}
        </button>
      </div>
    </ModalBox>
  </div>
</template>
