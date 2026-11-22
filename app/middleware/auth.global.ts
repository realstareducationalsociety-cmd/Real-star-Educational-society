export default defineNuxtRouteMiddleware(async (to) => {
  if (import.meta.server) return
  const auth = useAuth()
  let person: Awaited<ReturnType<typeof auth.loadUser>> = null
  try {
    person = await auth.loadUser()
  } catch (error) {
    auth.authError.value = errText(error)
    if (to.path !== '/login') return navigateTo('/login')
    return
  }
  if (to.path === '/login') {
    if (person) return navigateTo('/')
    return
  }
  if (!person) return navigateTo('/login')
  if (to.path.startsWith('/imports') && person.role !== 'admin') return navigateTo('/')
  if ((to.path.startsWith('/adjustments') || to.path.startsWith('/partners') || to.path.startsWith('/chapters') || to.path.startsWith('/books') || to.path.startsWith('/reports') || to.path.startsWith('/finance') || to.path.startsWith('/settlements') || to.path.startsWith('/expenses')) && !auth.canFinance.value) {
    return navigateTo('/')
  }
})
