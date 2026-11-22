<script setup lang="ts">
withDefaults(defineProps<{size?:'login'|'header'|'sidebar'|'report'}>(),{size:'header'})
</script>
<template><img src="/branding/real-star-official.png" alt="Real Star Educational Society — official logo" width="1024" height="1024" :class="['official-logo',`official-logo--${size}`]" decoding="async"/></template>
