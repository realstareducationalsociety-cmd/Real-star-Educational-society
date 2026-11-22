export type StaffRole = 'admin' | 'accountant' | 'registrar'
export interface StaffUser { id: string; full_name: string; role: StaffRole; is_active: boolean }
export function useAuth() {
  const profile = useState<StaffUser | null>('rs-profile', () => null)
  const checked = useState<boolean>('rs-auth-checked', () => false)
  const authError = useState<string>('rs-auth-error', () => '')
  const supabase = useSupabase()
  async function loadUser(force = false) {
    if (checked.value && !force) return profile.value
    authError.value = ''
    profile.value = null
    if (!supabase) { checked.value = true; return null }
    const { data: auth, error } = await supabase.auth.getUser()
    if (error) throw error
    if (!auth.user) { checked.value = true; return null }
    const { data: staff, error: profileError } = await supabase.from('staff_profiles')
      .select('id,full_name,role,is_active').eq('id', auth.user.id).maybeSingle()
    if (profileError) throw profileError
    if (!staff?.is_active) {
      await supabase.auth.signOut()
      checked.value = true
      return null
    }
    profile.value = staff as StaffUser
    checked.value = true
    return profile.value
  }
  async function signIn(email: string, password: string) {
    authError.value = ''
    if (!supabase) throw new Error('ابتدا تنظیمات Supabase را در فایل .env انجام بدهید.')
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    if (error) throw error
    checked.value = false
    const person = await loadUser(true)
    if (!person) throw new Error('برای این حساب دسترسی کارمندی فعال نشده است.')
    return person
  }
  async function signOut() {
    await supabase?.auth.signOut()
    profile.value = null; checked.value = true; authError.value = ''
    return navigateTo('/login')
  }
  const canFinance = computed(() => ['admin','accountant'].includes(profile.value?.role || ''))
  const canEducation = computed(() => ['admin','registrar'].includes(profile.value?.role || ''))
  return { profile, checked, authError, loadUser, signIn, signOut, canFinance, canEducation }
}
