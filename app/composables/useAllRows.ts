// Supabase limits each response; reports must not silently omit later rows.
export async function allRows(query: () => any): Promise<any[]> {
  const rows: any[] = []
  for (let offset = 0; ; offset += 500) {
    const result = await query().range(offset, offset + 499)
    if (result.error) throw result.error
    rows.push(...(result.data || []))
    if ((result.data || []).length < 500) return rows
  }
}
