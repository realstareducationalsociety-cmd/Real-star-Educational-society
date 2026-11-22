import { strFromU8, unzipSync } from 'fflate'

const xmlText = value => String(value)
  .replace(/&lt;/g, '<')
  .replace(/&gt;/g, '>')
  .replace(/&quot;/g, '"')
  .replace(/&apos;/g, "'")
  .replace(/&amp;/g, '&')
  .replace(/&#(\d+);/g, (_, code) => String.fromCodePoint(Number(code)))
  .replace(/&#x([\da-f]+);/gi, (_, code) => String.fromCodePoint(parseInt(code, 16)))

const attribute = (xml, name) => {
  const match = xml.match(new RegExp(`(?:^|\\s)${name}="([^"]*)"`, 'i'))
  return match ? xmlText(match[1]) : ''
}

const textTags = xml => [...xml.matchAll(/<(?:[\w.-]+:)?t(?:\s[^>]*)?>([\s\S]*?)<\/(?:[\w.-]+:)?t>/g)]
  .map(match => xmlText(match[1].replace(/<[^>]+>/g, '')))
  .join('')

const excelColumn = reference => {
  let value = 0
  for (const char of reference.match(/^[A-Z]+/i)?.[0].toUpperCase() || '') {
    value = value * 26 + char.charCodeAt(0) - 64
  }
  return value - 1
}

const sheetPath = target => {
  const normalized = target.replace(/\\/g, '/').replace(/^\/+/, '')
  const path = normalized.startsWith('xl/') ? normalized : `xl/${normalized}`
  if (path.split('/').includes('..')) throw new Error('Invalid workbook worksheet path.')
  return path
}

const reviewFields = new Map([
  ['Periods', 'Readiness'],
  ['Students', 'Identity Status'],
  ['Classes', 'Validation'],
  ['Registrations', 'Posting Decision'],
  ['Payments', 'Posting Decision'],
  ['Books', 'Posting Decision'],
  ['Chapters', 'Posting Decision'],
  ['OtherMaterials', 'Posting Decision'],
  ['ReviewFlags', 'Severity']
])

export function summarizeHistoricalReview(rows) {
  const counts = new Map()
  for (const row of rows) {
    const field = reviewFields.get(row.source_sheet)
    if (!field) continue
    const decision = String(row.payload[field] ?? '').trim() || 'NOT_SPECIFIED'
    const key = JSON.stringify([row.source_sheet, field, decision])
    counts.set(key, (counts.get(key) || 0) + 1)
  }
  return [...counts].map(([key, count]) => {
    const [sheet, field, decision] = JSON.parse(key)
    return { sheet, field, decision, count }
  })
}

function validateArchive(buffer) {
  const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength)
  let end = -1
  for (let offset = Math.max(0, buffer.length - 65557); offset <= buffer.length - 22; offset++) {
    if (view.getUint32(offset, true) === 0x06054b50) end = offset
  }
  if (end < 0) throw new Error('The selected file is not a supported Excel workbook.')
  const entryCount = view.getUint16(end + 10, true)
  const directorySize = view.getUint32(end + 12, true)
  const directoryOffset = view.getUint32(end + 16, true)
  if (!entryCount || entryCount > 1000 || directoryOffset + directorySize > end) {
    throw new Error('The workbook archive is invalid or too large.')
  }
  let offset = directoryOffset
  let totalUncompressed = 0
  const decoder = new TextDecoder()
  for (let index = 0; index < entryCount; index++) {
    if (offset + 46 > buffer.length || view.getUint32(offset, true) !== 0x02014b50) {
      throw new Error('The workbook archive is invalid.')
    }
    const flags = view.getUint16(offset + 8, true)
    const method = view.getUint16(offset + 10, true)
    const uncompressedSize = view.getUint32(offset + 24, true)
    const nameLength = view.getUint16(offset + 28, true)
    const extraLength = view.getUint16(offset + 30, true)
    const commentLength = view.getUint16(offset + 32, true)
    const nameEnd = offset + 46 + nameLength
    const next = nameEnd + extraLength + commentLength
    const name = decoder.decode(buffer.subarray(offset + 46, nameEnd)).replace(/\\/g, '/')
    if ((flags & 1) || ![0, 8].includes(method) || next > buffer.length || name.startsWith('/') || name.split('/').includes('..')) {
      throw new Error('The workbook archive contains unsupported entries.')
    }
    totalUncompressed += uncompressedSize
    if (uncompressedSize > 16000000 || totalUncompressed > 24000000) {
      throw new Error('The workbook archive exceeds the safe parsing limit.')
    }
    offset = next
  }
}

function parseCells(rowXml, sharedStrings) {
  const values = new Map()
  for (const match of rowXml.matchAll(/<(?:[\w.-]+:)?c\b([^>]*?)(?:\/>|>([\s\S]*?)<\/(?:[\w.-]+:)?c>)/g)) {
    const ref = attribute(match[1], 'r')
    const type = attribute(match[1], 't')
    const cellXml = match[2] || ''
    const value = cellXml.match(/<(?:[\w.-]+:)?v(?:\s[^>]*)?>([\s\S]*?)<\/(?:[\w.-]+:)?v>/)?.[1]
    let parsed = ''
    if (type === 's' && value !== undefined) {
      parsed = sharedStrings[Number(value)] ?? ''
    } else if (type === 'inlineStr') {
      parsed = textTags(cellXml)
    } else if (value !== undefined) {
      const raw = xmlText(value)
      parsed = type === 'b' ? raw === '1' : type === 'n' || !type ? Number.isFinite(Number(raw)) ? Number(raw) : raw : raw
    }
    if (ref) values.set(excelColumn(ref), parsed)
  }
  return values
}

function parseRows(xml, sharedStrings) {
  return [...xml.matchAll(/<(?:[\w.-]+:)?row\b([^>]*?)(?:\/>|>([\s\S]*?)<\/(?:[\w.-]+:)?row>)/g)].map(match => ({
    number: Number(attribute(match[1], 'r')) || 0,
    cells: parseCells(match[2] || '', sharedStrings)
  }))
}

export function parseHistoricalWorkbook(buffer) {
  validateArchive(buffer)
  const files = unzipSync(buffer)
  const workbookXml = files['xl/workbook.xml']
  const relationshipsXml = files['xl/_rels/workbook.xml.rels']
  if (!workbookXml || !relationshipsXml) throw new Error('The selected file is not a supported Excel workbook.')

  const sharedStrings = files['xl/sharedStrings.xml']
    ? [...strFromU8(files['xl/sharedStrings.xml']).matchAll(/<(?:[\w.-]+:)?si\b[^>]*>([\s\S]*?)<\/(?:[\w.-]+:)?si>/g)]
      .map(match => textTags(match[1]))
    : []
  const relationships = new Map()
  for (const match of strFromU8(relationshipsXml).matchAll(/<(?:[\w.-]+:)?Relationship\b([^>]*?)\/?>/g)) {
    relationships.set(attribute(match[1], 'Id'), attribute(match[1], 'Target'))
  }

  const rows = []
  const sheetNames = []
  for (const match of strFromU8(workbookXml).matchAll(/<(?:[\w.-]+:)?sheet\b([^>]*?)\/?>/g)) {
    const name = attribute(match[1], 'name')
    const target = relationships.get(attribute(match[1], 'r:id'))
    if (!name || !target) continue
    const worksheet = files[sheetPath(target)]
    if (!worksheet) throw new Error(`Worksheet file is missing for "${name}".`)
    sheetNames.push(name)
    const sheetRows = parseRows(strFromU8(worksheet), sharedStrings)
    const candidates = sheetRows.filter(row => row.number && row.number <= 15)
    const filledCells = row => [...row.cells.values()].filter(value => value !== '' && value !== null && value !== undefined).length
    const header = candidates.reduce((best, row) => filledCells(row) > (best ? filledCells(best) : 0) ? row : best, null)
    if (!header || filledCells(header) < 2) continue

    const headerNames = []
    const usedNames = new Map()
    for (let column = 0; column <= Math.max(...header.cells.keys()); column++) {
      const rawName = String(header.cells.get(column) ?? '').trim()
      if (!rawName) {
        headerNames[column] = `column_${column + 1}`
        continue
      }
      const occurrence = (usedNames.get(rawName) || 0) + 1
      usedNames.set(rawName, occurrence)
      headerNames[column] = occurrence === 1 ? rawName : `${rawName}_${occurrence}`
    }

    for (const row of sheetRows) {
      if (row.number <= header.number || !row.cells.size) continue
      const payload = {}
      let hasValue = false
      for (const [column, value] of row.cells) {
        if (value !== '' && value !== null && value !== undefined) hasValue = true
        payload[headerNames[column] || `column_${column + 1}`] = value
      }
      if (!hasValue) continue
      const originalKey = String(row.cells.get(0) ?? '').trim()
      rows.push({
        source_key: `${name}:${row.number}:${originalKey || 'row'}`,
        source_sheet: name,
        source_row: row.number,
        payload
      })
    }
  }
  if (!sheetNames.length) throw new Error('The workbook contains no readable worksheets.')
  if (rows.length > 6000) throw new Error('The workbook contains more rows than the staging limit.')
  return { rows, sheetNames }
}
