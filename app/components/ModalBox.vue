<script setup lang="ts">
const { t } = useLanguage()
const props = defineProps<{ title:string,open:boolean }>()
const emit=defineEmits<{close:[]}>()
</script>
<template><Teleport to="body"><div v-if="open" class="modal-overlay" @click.self="emit('close')"><section class="modal-panel" role="dialog" aria-modal="true" :aria-label="title"><div class="modal-head"><h3>{{title}}</h3><button class="close-btn" :aria-label="t('common.close')" @click="emit('close')">×</button></div><div class="modal-body"><slot /></div></section></div></Teleport></template>
