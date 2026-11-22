<script setup lang="ts">
import { ArrowRight, Eye, EyeOff, LockKeyhole } from 'lucide-vue-next'

definePageMeta({ layout: 'auth' })

const email = ref('')
const password = ref('')
const busy = ref(false)
const showPassword = ref(false)
const error = ref('')
const config = useRuntimeConfig()
const ready = Boolean(config.public.supabaseUrl && config.public.supabaseAnonKey)
const auth = useAuth()
const { t } = useLanguage()

async function submit() {
  if (busy.value) return
  busy.value = true
  error.value = ''
  try {
    await auth.signIn(email.value.trim(), password.value)
    await navigateTo('/')
  } catch (cause) {
    error.value = errText(cause)
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="official-login">
    <div class="login-language"><LanguageSwitcher /></div>
    <form class="login-card official-login-card" @submit.prevent="submit">
      <header class="official-login-brand">
        <OfficialLogo size="login" />
        <h1 dir="ltr">{{ t('app.institution') }}</h1>
        <p>{{ t('app.name') }}</p>
      </header>
      <div class="official-login-intro">
        <div class="login-icon"><LockKeyhole :size="22" aria-hidden="true" /></div>
        <h2>{{ t('login.title') }}</h2>
        <p>{{ t('login.subtitle') }}</p>
      </div>
      <Notice v-if="!ready" :message="t('login.missingConfig')" kind="error" />
      <Notice :message="auth.authError.value" kind="error" />
      <Notice :message="error" kind="error" />
      <label>
        {{ t('login.email') }}
        <input
          v-model="email"
          type="email"
          dir="ltr"
          autocomplete="username"
          required
          placeholder="name@example.com"
        />
      </label>
      <label>
        {{ t('login.password') }}
        <span class="password-field">
          <input
            v-model="password"
            :type="showPassword ? 'text' : 'password'"
            dir="ltr"
            autocomplete="current-password"
            required
            :placeholder="t('login.password')"
          />
          <button
            type="button"
            class="password-toggle icon-button"
            :aria-label="showPassword ? t('login.hidePassword') : t('login.showPassword')"
            :aria-pressed="showPassword"
            @click="showPassword = !showPassword"
          >
            <EyeOff v-if="showPassword" :size="18" aria-hidden="true" />
            <Eye v-else :size="18" aria-hidden="true" />
          </button>
        </span>
      </label>
      <button type="submit" class="btn primary full login-submit" :disabled="!ready || busy">
        {{ busy ? t('login.signingIn') : t('login.signIn') }}
        <ArrowRight :size="18" aria-hidden="true" />
      </button>
      <small class="login-footnote">{{ t('login.staffOnly') }}</small>
    </form>
  </div>
</template>
