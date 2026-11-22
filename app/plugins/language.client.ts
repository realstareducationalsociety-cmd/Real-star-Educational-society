export default defineNuxtPlugin((nuxtApp) => {
  const { locale } = nuxtApp.$i18n
  const preference = useCookie<'en' | 'fa-AF'>('rs-language', {
    maxAge: 60 * 60 * 24 * 365,
    sameSite: 'lax'
  })

  watch(locale, (value) => {
    const language = value === 'fa-AF' ? 'fa-AF' : 'en'
    document.documentElement.lang = language
    document.documentElement.dir = language === 'fa-AF' ? 'rtl' : 'ltr'
    preference.value = language
  }, { immediate: true })

  nuxtApp.hook('app:mounted', () => {
    if (preference.value === 'fa-AF') locale.value = 'fa-AF'
    else preference.value = 'en'
  })
})
