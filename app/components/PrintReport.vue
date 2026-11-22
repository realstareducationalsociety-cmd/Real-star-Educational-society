<script setup lang="ts">
const { t, direction } = useLanguage()
defineProps<{ title: string; subtitle?: string }>()
const generated = todayKarachi()
</script>
<template><article class="print-report" :dir="direction"><header class="report-heading"><OfficialLogo size="report"/><strong dir="ltr">REAL STAR EDUCATIONAL SOCIETY</strong><h2>{{ title }}</h2><p>{{ subtitle }}</p><p>{{ t('financialUi.print.preparedOn',{date:generated}) }}</p></header><slot/><footer class="report-signatures"><span>{{ t('financialUi.print.teacherSignature') }}<br/>_______________________</span><span>{{ t('financialUi.print.accountantSignature') }}<br/>_______________________</span><span>{{ t('financialUi.print.managementSignature') }}<br/>_______________________</span></footer></article></template>
