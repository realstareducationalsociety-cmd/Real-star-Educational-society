<script setup lang="ts">
const props = defineProps<{ membership: any }>()
const emit = defineEmits<{ saved: [] }>()
const { t } = useLanguage(), db = useSupabase(), auth = useAuth(), financialError = useFinancialError()
const busy = ref(false), error = ref(''), approved = ref(false)

const form = reactive({
  sponsored_confirmed:props.membership.sponsored_confirmed||false,
  custom_teacher_share:props.membership.is_exception||false,
  original_fee: Number(props.membership.original_fee),
  agreed_fee: Number(props.membership.agreed_fee ?? props.membership.base_fee),
  discount: Number(props.membership.discount),
  teacher_entitlement: Number(props.membership.teacher_entitlement),
  discount_reason: props.membership.discount_reason || '',
  arrangement_notes: props.membership.notes || '',
  exception_reason: props.membership.manual_adjustment_reason || '',
  reason: ''
})

const standardShare = computed(() => Math.round(Number(form.agreed_fee || 0) * 0.50 * 100) / 100)
const isException = computed(() => form.custom_teacher_share)

watch(form, () => { approved.value = false; if(!form.custom_teacher_share)form.teacher_entitlement=standardShare.value; if(form.discount!==form.agreed_fee)form.sponsored_confirmed=false }, { deep: true })
const payable = computed(() => Math.round((form.agreed_fee - form.discount) * 100) / 100)

function resetToStandard() {
  form.teacher_entitlement = standardShare.value
  form.exception_reason = '';form.custom_teacher_share=false
}

async function save() {
  if (!db || busy.value || !approved.value || auth.profile.value?.role !== 'admin') return
  busy.value = true
  error.value = ''
  try {
    const result = await db.rpc('update_monthly_agreement', {
      p_membership: props.membership.id,
      p_expected_updated_at: props.membership.updated_at,
      p_agreement: {
        ...form,
        approved: approved.value,
        custom_teacher_share:form.custom_teacher_share,
        teacher_share_reason:isException.value?form.exception_reason:null,
        exception_reason: isException.value ? (form.exception_reason || form.reason) : null
      }
    })
    if (result.error) throw result.error
    emit('saved')
  } catch (e) {
    error.value = financialError(e)
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <form @submit.prevent="save">
    <Notice :message="error" kind="error" />
    <p class="accent-callout">{{ t('agreements.policy') }}</p>
    <p class="hint">{{ t('agreements.standardNote') }}</p><label v-if="form.agreed_fee>0&&form.discount===form.agreed_fee" class="approval"><input v-model="form.sponsored_confirmed" type="checkbox"/>{{t('agreements.confirmSponsored')}}</label>

    <fieldset :disabled="busy" class="agreement-editor">
      <div class="form-grid">
        <label>
          {{ t('registration.original_fee') }}
          <input v-model.number="form.original_fee" type="number" min="0" step="0.01" required />
        </label>

        <label>
          {{ t('registration.agreed_fee') }}
          <input v-model.number="form.agreed_fee" type="number" min="0" step="0.01" required />
        </label>

        <label class="approval"><input v-model="form.custom_teacher_share" type="checkbox"/>{{t('agreements.customShare')}}</label><div class="teacher-share-field">
          <div class="share-header">
            <label>{{ t('registration.teacher_entitlement') }}</label>
            <div class="share-status">
              <span v-if="!isException" class="badge success">{{ t('agreements.standard50') }} ({{ money(standardShare) }})</span>
              <template v-else>
                <span class="badge warning">{{ t('agreements.approvedException') }}</span>
                <button type="button" class="btn small-btn light" @click="resetToStandard">{{ t('agreements.resetStandard') }}</button>
              </template>
            </div>
          </div>
          <input v-model.number="form.teacher_entitlement" :readonly="!form.custom_teacher_share" type="number" min="0" step="0.01" required />
        </div>

        <label>
          {{ t('registration.discount') }}
          <input v-model.number="form.discount" type="number" min="0" :max="form.agreed_fee" step="0.01" required />
        </label>

        <label v-if="isException" class="wide highlight-field">
          {{ t('agreements.exceptionReason') }} *
          <input v-model="form.exception_reason" required minlength="4" :placeholder="t('agreements.exceptionReasonPlaceholder')" />
        </label>

        <label class="wide">
          {{ t('agreements.discountReason') }}
          <input v-model="form.discount_reason" :required="form.discount > 0" :minlength="form.discount > 0 ? 4 : 0" />
        </label>

        <label class="wide">
          {{ t('agreements.notes') }}
          <textarea v-model="form.arrangement_notes" rows="2" />
        </label>

        <label class="wide">
          {{ t('agreements.changeReason') }} *
          <textarea v-model="form.reason" required minlength="4" />
        </label>
      </div>

      <dl class="summary-box">
        <div class="summary-row"><dt>{{ t('registration.amount_due') }}</dt><dd>{{ money(payable) }}</dd></div>
        <div class="summary-row"><dt>{{ t('registration.paid_total') }}</dt><dd>{{ money(membership.paid_total) }}</dd></div>
        <div class="summary-row"><dt>{{ t('registration.balance_due') }}</dt><dd>{{ money(payable - Number(membership.paid_total)) }}</dd></div>
        <div class="summary-row"><dt>{{ t('agreements.funded') }}</dt><dd>{{ money(Math.max(0, form.teacher_entitlement - payable)) }}</dd></div>
      </dl>

      <p>{{ t('agreements.paymentProtection') }}</p>

      <label class="approval">
        <input v-model="approved" type="checkbox" required />
        {{ t('agreements.approve') }} · {{ auth.profile.value?.full_name }}
      </label>

      <div class="form-footer">
        <button class="btn primary" :disabled="busy || !approved || payable < Number(membership.paid_total)">
          {{ t('financialUi.finance.saveAdjustments') }}
        </button>
      </div>
    </fieldset>
  </form>
</template>

<style scoped>
.agreement-editor { border: 0; padding: 0; min-width: 0; }
.approval { display: flex; gap: 12px; align-items: center; margin: 16px 0; }
.approval input { width: auto; }
.share-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 4px; }
.share-status { display: flex; gap: 6px; align-items: center; }
.highlight-field { border-color: #f59e0b; }
dd { margin: 0; font-weight: 600; }
</style>
