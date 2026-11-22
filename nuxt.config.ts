export default defineNuxtConfig({
  compatibilityDate: '2025-10-01',
  ssr: false,
  modules: ['@nuxtjs/i18n'],
  css: ['~/assets/css/main.css'],
  devtools: { enabled: false },
  i18n: {
    defaultLocale: 'en',
    strategy: 'no_prefix',
    langDir: 'locales',
    defaultDirection: 'ltr',
    locales: [
      { code: 'en', language: 'en-US', name: 'English', file: 'en.json' },
      { code: 'fa-AF', language: 'fa-AF', name: 'دری', file: 'fa-AF.json' }
    ],
    detectBrowserLanguage: false,
    vueI18n: './i18n.config.ts'
  },
  runtimeConfig: {
    public: {
      supabaseUrl: process.env.NUXT_PUBLIC_SUPABASE_URL || '',
      supabaseAnonKey: process.env.NUXT_PUBLIC_SUPABASE_ANON_KEY || ''
    }
  },
  app: { head: { title: 'Real Star | Management System', meta: [{ name: 'viewport', content: 'width=device-width, initial-scale=1' }] } }
})
