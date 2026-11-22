import assert from 'node:assert/strict'
import { strToU8, zipSync } from 'fflate'
import { parseHistoricalWorkbook, summarizeHistoricalReview } from '../app/utils/historicalWorkbook.js'

const entries = {
  'xl/workbook.xml': `<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Registrations" sheetId="1" r:id="rId1"/></sheets></workbook>`,
  'xl/_rels/workbook.xml.rels': `<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>`,
  'xl/sharedStrings.xml': `<sst><si><t>Report title</t></si><si><t>Source Key</t></si><si><t>Student Name</t></si><si><t>Amount</t></si><si><t>REG-1</t></si><si><t>A &amp; B</t></si></sst>`,
  'xl/worksheets/sheet1.xml': `<worksheet><sheetData>
    <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"/></row>
    <row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2" t="s"><v>2</v></c><c r="C2" t="s"><v>3</v></c></row>
    <row r="3"><c r="A3" t="s"><v>4</v></c><c r="B3" t="s"><v>5</v></c><c r="C3"><v>1250</v></c></row>
  </sheetData></worksheet>`
}
const buffer = zipSync(Object.fromEntries(Object.entries(entries).map(([name, value]) => [name, strToU8(value)])))
const workbook = parseHistoricalWorkbook(buffer)
assert.deepEqual(workbook.sheetNames, ['Registrations'])
assert.equal(workbook.rows.length, 1)
assert.equal(workbook.rows[0].source_key, 'Registrations:3:REG-1')
assert.equal(workbook.rows[0].source_row, 3)
assert.deepEqual(workbook.rows[0].payload, {
  'Source Key': 'REG-1',
  'Student Name': 'A & B',
  Amount: 1250
})
assert.deepEqual(summarizeHistoricalReview([
  { source_sheet: 'Students', payload: { 'Identity Status': 'REVIEW_REQUIRED' } },
  { source_sheet: 'Students', payload: { 'Identity Status': 'REVIEW_REQUIRED' } },
  { source_sheet: 'Registrations', payload: { 'Posting Decision': 'REVIEW_FOR_IMPORT' } },
  { source_sheet: 'Unknown', payload: { Status: 'ignored' } }
]), [
  { sheet: 'Students', field: 'Identity Status', decision: 'REVIEW_REQUIRED', count: 2 },
  { sheet: 'Registrations', field: 'Posting Decision', decision: 'REVIEW_FOR_IMPORT', count: 1 }
])
assert.throws(() => parseHistoricalWorkbook(strToU8('not an xlsx')), /workbook|file/i)
console.log('PASS: historical workbook parser preserves sheet, row, source key, text, and numeric provenance.')
