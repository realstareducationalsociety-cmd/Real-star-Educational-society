export function useFinancialError() {
  const { t } = useLanguage()
  return (cause: unknown) => {
    const error = cause as { code?: string; status?: number; message?: string; details?: string | null; hint?: string | null }
    if (import.meta.dev && cause) console.error('[RSMS finance error]', {
      code: error?.code,
      status: error?.status,
      message: error?.message,
      details: error?.details,
      hint: error?.hint
    })
    if (['PGRST202','PGRST204','PGRST205','42P01','42703','42883'].includes(error?.code || '')) return t('agreements.schemaMissing')
    if (error?.code === '42501') return t('agreements.adminOnly')
    if (error?.code === '23505') return t('agreements.duplicate')
    if (error?.code === '40001') return t('agreements.stale')
    if (/closed|بسته/.test(error?.message || '')) return t('registration.closed')
    if (['23514','22P02','22003','P0001'].includes(error?.code || '')) return t('agreements.invalid')
    if (error?.message?.includes('fetch') || cause instanceof TypeError) return t('agreements.network')
    return errText(cause)
  }
}
