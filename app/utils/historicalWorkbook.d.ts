export interface HistoricalSourceRow {
  source_key: string
  source_sheet: string
  source_row: number
  payload: Record<string, unknown>
}

export interface HistoricalReviewSummary {
  sheet: string
  field: string
  decision: string
  count: number
}

export function parseHistoricalWorkbook(buffer: Uint8Array): {
  rows: HistoricalSourceRow[]
  sheetNames: string[]
}

export function summarizeHistoricalReview(rows: HistoricalSourceRow[]): HistoricalReviewSummary[]
