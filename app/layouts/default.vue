<script setup lang="ts">
import {
  BookOpen, ChevronLeft, ChevronRight, GraduationCap, LayoutDashboard,
  LogOut, Menu, Receipt, Users, Wallet, HandCoins, UserPlus, PanelLeftClose,
  PanelLeftOpen, FileSpreadsheet
} from 'lucide-vue-next'

const auth = useAuth()
const route = useRoute()
const { t, isDari, locale, direction } = useLanguage()
useHead(() => ({ htmlAttrs: { lang: locale.value, dir: direction.value } }))
const menuOpen = ref(false)
const collapsed = ref(false)

const groups = computed(() => {
  const academic = [
    { to: '/students', label: t('nav.students'), icon: Users },
    { to: '/teachers', label: t('nav.teachers'), icon: GraduationCap },
    { to: '/classes', label: t('nav.classes'), icon: BookOpen },
    { to: '/enrollments', label: t('nav.registration'), icon: UserPlus }
  ]
  const financial = auth.canFinance.value ? [
    { to: '/finance', label: t('nav.tuition'), icon: Wallet },
    { to: '/settlements', label: t('nav.settlements'), icon: HandCoins },
    { to: '/expenses', label: t('nav.expenses'), icon: Receipt },
    { to: '/reports/monthly', label: t('nav.reports'), icon: Receipt },
    { to: '/adjustments', label: t('nav.adjustments'), icon: Receipt },
    { to: '/partners', label: t('nav.partners'), icon: Wallet }
  ] : []
  const materials = auth.canFinance.value ? [
    { to: '/chapters', label: t('nav.chapters'), icon: BookOpen },
    { to: '/books', label: t('nav.books'), icon: BookOpen }
  ] : []
  const administration = auth.profile.value?.role === 'admin'
    ? [{ to: '/imports', label: t('nav.imports'), icon: FileSpreadsheet }]
    : []

  return [
    { label: t('nav.overview'), items: [{ to: '/', label: t('nav.dashboard'), icon: LayoutDashboard }] },
    { label: t('nav.academic'), items: academic },
    ...(financial.length ? [{ label: t('nav.financial'), items: financial }] : []),
    ...(materials.length ? [{ label: t('nav.materials'), items: materials }] : []),
    ...(administration.length ? [{ label: t('nav.administration'), items: administration }] : [])
  ]
})

const currentTitle = computed(() => groups.value.flatMap(group => group.items).find(item =>
  item.to === route.path || (item.to !== '/' && route.path.startsWith(`${item.to}/`))
)?.label || t('app.panel'))

watch(() => route.path, () => { menuOpen.value = false })
</script>

<template>
  <div class="app-frame" :class="{ 'sidebar-collapsed': collapsed }">
    <button
      v-if="menuOpen"
      type="button"
      class="side-backdrop"
      :aria-label="t('common.close')"
      @click="menuOpen = false"
    />
    <aside :class="['sidebar', { 'sidebar-open': menuOpen }]">
      <NuxtLink to="/" class="brand official-sidebar-brand" :aria-label="t('nav.dashboard')">
        <OfficialLogo size="sidebar" />
        <div class="brand-text">
          <strong dir="ltr">REAL STAR</strong>
          <span>{{ t('app.name') }}</span>
        </div>
      </NuxtLink>

      <nav class="side-nav" :aria-label="t('nav.academic')">
        <section v-for="group in groups" :key="group.label" class="nav-group">
          <h2 class="nav-label">{{ group.label }}</h2>
          <NuxtLink
            v-for="item in group.items"
            :key="item.to"
            :to="item.to"
            :title="collapsed ? item.label : undefined"
            :aria-current="route.path === item.to ? 'page' : undefined"
            :class="['nav-link', { 'is-active': route.path === item.to }]"
          >
            <component :is="item.icon" :size="19" aria-hidden="true" />
            <span class="nav-link-text">{{ item.label }}</span>
            <component
              :is="isDari ? ChevronLeft : ChevronRight"
              v-if="route.path === item.to"
              :size="14"
              class="nav-chevron"
              aria-hidden="true"
            />
          </NuxtLink>
        </section>
      </nav>

      <div class="side-bottom">
        <div class="user-dot"><span aria-hidden="true">{{ auth.profile.value?.full_name?.slice(0, 1) || 'R' }}</span></div>
        <div class="user-info">
          <strong>{{ auth.profile.value?.full_name || t('app.panel') }}</strong>
          <small>{{ auth.profile.value?.role ? t(`roles.${auth.profile.value.role}`) : '' }}</small>
        </div>
        <button class="icon-button" :title="t('common.logout')" :aria-label="t('common.logout')" @click="auth.signOut()">
          <LogOut :size="19" aria-hidden="true" />
        </button>
      </div>
    </aside>

    <div class="main-wrap">
      <header class="topbar official-topbar">
        <button
          type="button"
          class="icon-button mobile-menu"
          :aria-label="t('nav.overview')"
          :aria-expanded="menuOpen"
          @click="menuOpen = true"
        >
          <Menu :size="22" aria-hidden="true" />
        </button>
        <button
          type="button"
          class="icon-button desktop-sidebar-toggle"
          :aria-label="collapsed ? t('nav.academic') : t('common.close')"
          :aria-pressed="collapsed"
          @click="collapsed = !collapsed"
        >
          <PanelLeftOpen v-if="collapsed" :size="20" aria-hidden="true" />
          <PanelLeftClose v-else :size="20" aria-hidden="true" />
        </button>
        <div class="official-header-brand">
          <OfficialLogo size="header" />
          <div>
            <strong dir="ltr">{{ t('app.institution') }}</strong>
            <small>{{ currentTitle }}</small>
          </div>
        </div>
        <div class="topbar-actions">
          <LanguageSwitcher />
          <span class="header-pill">{{ t('app.panel') }}</span>
        </div>
      </header>

      <main class="page-content"><slot /></main>
      <footer class="app-footer">{{ t('app.footer') }}</footer>
    </div>
  </div>
</template>
