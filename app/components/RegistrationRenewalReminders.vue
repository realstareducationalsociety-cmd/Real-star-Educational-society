<script setup lang="ts">
import { MessageCircle, RefreshCw, ShieldCheck } from 'lucide-vue-next'

type Recipient = 'student' | 'guardian'
const { t, isDari } = useLanguage()
const db = useSupabase()
const auth = useAuth()
const rows = ref<any[]>([])
const loading = ref(false)
const error = ref('')
const busyId = ref('')
const selectedRecipient = reactive<Record<string, Recipient>>({})

async function load() {
  if (!db || !auth.canEducation.value) return
  loading.value = true
  error.value = ''
  try {
    const result = await db.rpc('get_registration_renewal_reminders')
    if (result.error) throw result.error
    rows.value = result.data || []
    for (const row of rows.value) {
      const key = `${row.enrollment_id}-${row.due_period}`
      if (!selectedRecipient[key]) selectedRecipient[key] = row.default_recipient === 'student' ? 'student' : 'guardian'
    }
  } catch (cause) { error.value = errText(cause) }
  finally { loading.value = false }
}

function recipient(row: any): Recipient { return selectedRecipient[`${row.enrollment_id}-${row.due_period}`] || row.default_recipient || 'guardian' }
function phone(row: any, who = recipient(row)) { return who === 'student' ? row.student_whatsapp_phone : row.guardian_whatsapp_phone }
function hasConsent(row: any, who = recipient(row)) { return who === 'student' ? row.student_has_consent : row.guardian_has_consent }
function recipientName(row: any, who = recipient(row)) { return who === 'student' ? row.student_name : (row.guardian_name || (isDari.value ? 'سرپرست محترم' : 'Dear guardian')) }

function messageFor(row: any) {
  const who = recipient(row)
  const name = recipientName(row, who)
  if (isDari.value) {
    return who === 'student'
      ? `سلام ${name} عزیز، امیدواریم صحت‌مند باشید. موعد تمدید ثبت‌نام شما در صنف ${row.class_name} در تاریخ ${row.due_on} است. لطفاً برای ادامه آموزش با اداره مجتمع آموزشی ریل استار هماهنگ فرمایید. سپاس.`
      : `سلام ${name}، امیدواریم صحت‌مند باشید. موعد تمدید ثبت‌نام فرزندتان ${row.student_name} در صنف ${row.class_name} در تاریخ ${row.due_on} است. لطفاً برای ادامه آموزش با اداره مجتمع آموزشی ریل استار هماهنگ فرمایید. سپاس.`
  }
  return who === 'student'
    ? `Dear ${name}, your registration in ${row.class_name} is due for renewal on ${row.due_on}. Please contact Real Star Educational Society to continue your classes. Thank you.`
    : `Dear ${name}, ${row.student_name}'s registration in ${row.class_name} is due for renewal on ${row.due_on}. Please contact Real Star Educational Society to continue the classes. Thank you.`
}

function whatsappUrl(row: any) {
  const normalized = phone(row)
  return hasConsent(row) && normalized ? `https://wa.me/${normalized}?text=${encodeURIComponent(messageFor(row))}` : undefined
}

async function setConsent(studentId: string, who: Recipient, number: string, consented: boolean, lockId: string) {
  if (!db || auth.profile.value?.role !== 'admin' || busyId.value) return
  const note = window.prompt(t(consented ? 'renewalReminders.consentPrompt' : 'renewalReminders.revokePrompt'))
  if (!note || note.trim().length < 4) return
  busyId.value = lockId
  error.value = ''
  try {
    const result = await db.rpc('record_guardian_message_consent', {
      p_student: studentId, p_recipient: who, p_phone: number, p_consented: consented, p_note: note.trim()
    })
    if (result.error) throw result.error
    await load()
  } catch (cause) { error.value = errText(cause) }
  finally { busyId.value = '' }
}

async function confirmSent(row: any) {
  if (!db || auth.profile.value?.role !== 'admin' || row.reminder_status !== 'pending' || busyId.value || !hasConsent(row)) return
  if (!window.confirm(t('renewalReminders.confirmSentPrompt'))) return
  const note = window.prompt(t('renewalReminders.sentNotePrompt'))
  if (!note || note.trim().length < 4) return
  busyId.value = row.enrollment_id
  error.value = ''
  try {
    const result = await db.rpc('confirm_registration_renewal_reminder_sent', {
      p_enrollment: row.enrollment_id, p_due_period: row.due_period, p_recipient: recipient(row), p_note: note.trim()
    })
    if (result.error) throw result.error
    await load()
  } catch (cause) { error.value = errText(cause) }
  finally { busyId.value = '' }
}

function contactLabel(who: Recipient) { return t(who === 'student' ? 'renewalReminders.student' : 'renewalReminders.guardian') }
onMounted(load)
</script>

<template>
  <section v-if="auth.canEducation.value" class="card renewal-reminders">
    <div class="card-header"><div><h2>{{ t('renewalReminders.title') }}</h2><p>{{ t('renewalReminders.subtitle') }}</p></div><button class="btn" :disabled="loading" @click="load"><RefreshCw :size="16" /> {{ t('renewalReminders.refresh') }}</button></div>
    <Notice :message="error" kind="error" />
    <p v-if="loading" class="empty">{{ t('common.loading') }}</p>
    <p v-else-if="!rows.length" class="empty">{{ t('renewalReminders.empty') }}</p>
    <div v-else class="reminder-list">
      <article v-for="row in rows" :key="`${row.enrollment_id}-${row.due_period}`" class="reminder-item">
        <div class="reminder-person"><strong>{{ row.student_name }}</strong><span>{{ row.class_name }}</span></div>
        <div class="reminder-fact"><small>{{ t('renewalReminders.dueDate') }}</small><strong>{{ row.due_on }}</strong></div>
        <div class="reminder-fact"><small>{{ t('renewalReminders.contact') }}</small>
          <template v-if="auth.profile.value?.role === 'admin'">
            <select v-model="selectedRecipient[`${row.enrollment_id}-${row.due_period}`]" :disabled="row.reminder_status === 'sent_confirmed'"><option value="student">{{ t('renewalReminders.student') }} · {{ row.student_phone || t('renewalReminders.noPhone') }}</option><option value="guardian">{{ t('renewalReminders.guardian') }} · {{ row.guardian_phone || t('renewalReminders.noPhone') }}</option></select>
          </template><span v-else>{{ t('renewalReminders.adminOnlyPhone') }}</span>
        </div>
        <div class="reminder-state"><span :class="['badge', row.reminder_status === 'sent_confirmed' ? 'success' : 'warning']">{{ row.reminder_status === 'sent_confirmed' ? t('renewalReminders.sent') : t('renewalReminders.pending') }}</span><span v-if="row.reminder_status === 'sent_confirmed'" class="small muted">{{ contactLabel(row.sent_recipient) }} · {{ row.sent_confirmed_at }}</span><span v-else-if="auth.profile.value?.role === 'admin' && !hasConsent(row)" class="small muted">{{ phone(row) ? t('renewalReminders.consentMissing') : t('renewalReminders.invalidPhone') }}</span><span v-else-if="auth.profile.value?.role === 'admin'" class="small muted"><ShieldCheck :size="14" /> {{ t('renewalReminders.consentRecorded') }}</span></div>
        <div class="reminder-actions">
          <button v-if="auth.profile.value?.role === 'admin' && row.reminder_status !== 'sent_confirmed' && phone(row)" class="btn small-btn light" :disabled="busyId === row.enrollment_id" @click="setConsent(row.student_id, recipient(row), phone(row), !hasConsent(row), row.enrollment_id)">{{ hasConsent(row) ? t('renewalReminders.revokeConsent') : t('renewalReminders.recordConsent') }} · {{ contactLabel(recipient(row)) }}</button>
          <a v-if="auth.profile.value?.role === 'admin' && row.reminder_status === 'pending' && whatsappUrl(row)" class="btn small-btn" :href="whatsappUrl(row)" target="_blank" rel="noopener noreferrer"><MessageCircle :size="15" /> {{ t('renewalReminders.openWhatsApp') }}</a>
          <button v-if="auth.profile.value?.role === 'admin' && row.reminder_status === 'pending' && hasConsent(row)" class="btn small-btn primary" :disabled="busyId === row.enrollment_id" @click="confirmSent(row)">{{ t('renewalReminders.confirmSent') }}</button>
          <span v-if="auth.profile.value?.role !== 'admin'" class="small muted">{{ t('renewalReminders.adminActionsOnly') }}</span>
        </div>
        <details v-if="auth.profile.value?.role === 'admin' && row.consent_history?.length" class="consent-history"><summary>{{ t('renewalReminders.consentHistory') }}</summary><div v-for="consent in row.consent_history" :key="`${consent.recipient_type}-${consent.phone_e164}`" class="consent-row"><span>{{ contactLabel(consent.recipient_type) }} · <bdi dir="ltr">{{ consent.phone_e164 }}</bdi> · {{ consent.is_active ? t('renewalReminders.consentRecorded') : t('renewalReminders.consentRevoked') }}</span><button v-if="consent.is_active" class="btn small-btn light" :disabled="busyId === row.enrollment_id" @click="setConsent(row.student_id, consent.recipient_type, consent.phone_e164, false, row.enrollment_id)">{{ t('renewalReminders.revokeConsent') }}</button></div></details>
      </article>
    </div>
    <p class="hint">{{ t('renewalReminders.manualOnly') }}</p>
  </section>
</template>

<style scoped>
.renewal-reminders { margin-bottom:18px }.reminder-list{display:grid;gap:10px}.reminder-item{display:grid;grid-template-columns:minmax(130px,1.1fr) minmax(100px,.7fr) minmax(160px,1.1fr) minmax(130px,.8fr) minmax(210px,1.3fr);gap:12px;align-items:center;padding:12px;border:1px solid var(--line,#e5e7eb);border-radius:12px}.reminder-person,.reminder-fact,.reminder-state{display:grid;gap:4px;min-width:0}.reminder-person span,.reminder-fact strong{overflow-wrap:anywhere}.reminder-fact small{color:var(--muted,#667085)}.reminder-state .small{display:flex;align-items:center;gap:4px}.reminder-actions{display:flex;gap:7px;flex-wrap:wrap;align-items:center}.consent-history{grid-column:1/-1}.consent-row{display:flex;gap:8px;align-items:center;justify-content:space-between;padding:5px 0;flex-wrap:wrap}@media(max-width:900px){.reminder-item{grid-template-columns:repeat(2,minmax(0,1fr))}.reminder-actions{grid-column:1/-1}}@media(max-width:520px){.reminder-item{grid-template-columns:minmax(0,1fr)}.reminder-actions{grid-column:auto}.reminder-actions>*{flex:1 1 100%;justify-content:center}}
</style>
