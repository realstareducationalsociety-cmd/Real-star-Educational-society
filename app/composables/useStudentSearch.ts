/** Bounded remote search; stale responses never replace a newer query. */
export function useStudentSearch() {
  const db = useSupabase()
  const query = ref('')
  const results = ref<any[]>([])
  const loading = ref(false)
  const error = ref('')
  let version = 0
  let timer: ReturnType<typeof setTimeout> | undefined
  watch(query, value => {
    clearTimeout(timer)
    const own = ++version
    results.value = []
    loading.value = false
    error.value = ''
    if (!db || value.trim().length < 2) return
    timer = setTimeout(async () => {
      loading.value = true
      try {
        const response = await db.rpc('registration_student_search', { p_query: value.trim() })
        if (own !== version) return
        if (response.error) throw response.error
        results.value = (response.data || []).filter((student: any) => student.active)
      } catch (cause) { if (own === version) error.value = errText(cause) }
      finally { if (own === version) loading.value = false }
    }, 250)
  })
  onBeforeUnmount(() => { clearTimeout(timer); version++ })
  return { query, results, loading, error }
}
