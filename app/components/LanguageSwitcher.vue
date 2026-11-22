<script setup lang="ts">
const { locale, changeLanguage, t } = useLanguage()
</script>

<template>
  <div class="language-switcher" role="group" :aria-label="t('language.switch')">
    <button
      type="button"
      :aria-pressed="locale === 'en'"
      :class="{ active: locale === 'en' }"
      @click="changeLanguage('en')"
    >{{ t('language.english') }}</button>
    <span aria-hidden="true">|</span>
    <button
      type="button"
      :aria-pressed="locale === 'fa-AF'"
      :class="{ active: locale === 'fa-AF' }"
      @click="changeLanguage('fa-AF')"
    >{{ t('language.dari') }}</button>
  </div>
</template>
