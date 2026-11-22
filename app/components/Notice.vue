<script setup lang="ts">
defineProps<{message:string,kind?:'error'|'success'|'info'}>()
</script>
<template><div v-if="message" :class="['notice',kind||'info']">{{message}}</div></template>
