export type AppLocale = 'en' | 'fa-AF'

export function useLanguage() {
  const { locale, setLocale, t } = useI18n()
  const direction = computed(() => locale.value === 'fa-AF' ? 'rtl' : 'ltr')
  const isDari = computed(() => locale.value === 'fa-AF')

  async function changeLanguage(next: AppLocale) {
    await setLocale(next)
  }

  return { locale, direction, isDari, changeLanguage, t }
}
