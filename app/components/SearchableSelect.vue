<script setup lang="ts">
import { normalizeSearchText } from '~/utils/searchText'
const { t } = useLanguage()
const listId = useId()
const input = ref<HTMLInputElement | null>(null)

type SelectOption = Record<string, any>
const props = withDefaults(defineProps<{
  modelValue: string
  options: SelectOption[]
  labelKey: string
  valueKey?: string
  selectedSuffixKey?: string
  searchKeys?: string[]
  placeholder?: string
  disabled?: boolean
  required?: boolean
  allowEmpty?: boolean
  emptyLabel?: string
  minChars?: number
  remote?: boolean
}>(), { valueKey: 'id', selectedSuffixKey: '', searchKeys: () => [], placeholder: '', disabled: false, required: false, allowEmpty: false, emptyLabel: '', minChars: 0 })
const emit = defineEmits<{ 'update:modelValue': [value: string]; search: [value: string] }>()
const query = ref('')
const open = ref(false)
const activeIndex = ref(0)
const root = ref<HTMLElement | null>(null)
const selected = computed(() => props.options.find(option => String(option[props.valueKey] ?? '') === props.modelValue))
const selectedText = computed(() => selected.value ? [selected.value[props.labelKey], props.selectedSuffixKey ? selected.value[props.selectedSuffixKey] : ''].filter(Boolean).join(' · ') : '')
const filtered = computed(() => {
  const q = normalizeSearchText(query.value)
  if (q.length < props.minChars) return []
  return props.options.filter(option => props.remote || !q || normalizeSearchText([props.labelKey, ...props.searchKeys].map(key => key.split('.').reduce((value, part) => value?.[part], option)).join(' ')).includes(q)).slice(0, 50)
})
const optionCount = computed(() => filtered.value.length + (props.allowEmpty ? 1 : 0))
watch(selectedText, () => { if (!open.value) query.value = selectedText.value }, { immediate: true })
watch([() => props.modelValue, query], () => input.value?.setCustomValidity(props.required && !props.modelValue ? t('searchSelect.choose') : ''), { flush: 'post' })
watch(activeIndex, () => nextTick(() => document.getElementById(`${listId}-${activeIndex.value}`)?.scrollIntoView({ block: 'nearest' })))
function onInput() { open.value = true; activeIndex.value = 0; if (props.modelValue) emit('update:modelValue', ''); emit('search', query.value) }
watch(() => props.options, () => { if (selected.value && !open.value) query.value = selectedText.value })
function choose(option: SelectOption) { emit('update:modelValue', String(option[props.valueKey] ?? '')); query.value = [option[props.labelKey], props.selectedSuffixKey ? option[props.selectedSuffixKey] : ''].filter(Boolean).join(' · '); open.value = false }
function chooseEmpty() { emit('update:modelValue', ''); query.value = ''; open.value = false }
function onKeydown(event: KeyboardEvent) {
  if (event.key === 'Escape') { open.value = false; query.value = selectedText.value; return }
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') { event.preventDefault(); open.value = true; activeIndex.value = Math.max(0, Math.min(optionCount.value - 1, activeIndex.value + (event.key === 'ArrowDown' ? 1 : -1))); return }
  if (event.key === 'Enter' && open.value) { event.preventDefault(); if (props.allowEmpty && activeIndex.value === 0) chooseEmpty(); else if (filtered.value[activeIndex.value - (props.allowEmpty ? 1 : 0)]) choose(filtered.value[activeIndex.value - (props.allowEmpty ? 1 : 0)]!) }
}
function onFocusOut(event: FocusEvent) { if (!root.value?.contains(event.relatedTarget as Node | null)) { open.value = false; if (!props.modelValue) query.value = '' } }
</script>

<template>
  <div ref="root" class="searchable-select" @focusout="onFocusOut">
    <input ref="input" v-model="query" type="search" role="combobox" aria-autocomplete="list" :aria-controls="listId" :aria-activedescendant="open && optionCount ? `${listId}-${activeIndex}` : undefined" :aria-expanded="open" :placeholder="placeholder" :disabled="disabled" :required="required" autocomplete="off" @focus="open = true; activeIndex = 0" @input="onInput" @keydown="onKeydown" />
    <div v-if="open" :id="listId" class="searchable-options" role="listbox">
      <button v-if="allowEmpty" type="button" role="option" :aria-selected="activeIndex === 0" :class="{ active: activeIndex === 0 }" :id="`${listId}-0`" @pointerdown.prevent @click="chooseEmpty" @mouseenter="activeIndex = 0">{{ emptyLabel || placeholder }}</button>
      <button v-for="(option, index) in filtered" :key="String(option[valueKey])" type="button" role="option" :aria-selected="index + (allowEmpty ? 1 : 0) === activeIndex" :class="{ active: index + (allowEmpty ? 1 : 0) === activeIndex }" :id="`${listId}-${index + (allowEmpty ? 1 : 0)}`" @pointerdown.prevent @click="choose(option)" @mouseenter="activeIndex = index + (allowEmpty ? 1 : 0)">
        <slot name="option" :option="option">{{ option[labelKey] }}</slot>
      </button>
      <p v-if="query.trim().length < minChars" class="searchable-empty">{{ t('searchSelect.minimum', { count: minChars }) }}</p>
      <p v-else-if="!filtered.length" class="searchable-empty">{{ t('searchSelect.empty') }}</p>
    </div>
  </div>
</template>

<style scoped>
.searchable-select { position: relative; min-width: 0; }
.searchable-select input { width: 100%; }
.searchable-options { position: absolute; z-index: 30; inset-inline: 0; top: calc(100% + 4px); max-height: 260px; overflow: auto; padding: 4px; border: 1px solid #d7dce8; border-radius: 8px; background: white; box-shadow: 0 10px 28px #17203324; }
.searchable-options button { display: block; width: 100%; padding: 9px 10px; border: 0; border-radius: 5px; color: #253047; text-align: start; background: transparent; cursor: pointer; }
.searchable-options button:hover, .searchable-options button.active { background: #eef1ff; }
.searchable-empty { margin: 0; padding: 9px 10px; color: #647086; font-size: .9rem; pointer-events: none; }
</style>
