// Reuse keys for retries, but never reuse a key after changing the submitted values.
export function useRequestKey() {
  let serialized = '', key = ''
  return {
    forPayload(payload: unknown) {
      const next = JSON.stringify(payload)
      if (!key || next !== serialized) { key = crypto.randomUUID(); serialized = next }
      return key
    },
    reset() { key = ''; serialized = '' }
  }
}
