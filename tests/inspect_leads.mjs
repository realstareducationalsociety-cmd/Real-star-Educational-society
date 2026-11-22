import { readFileSync } from 'node:fs'
import { parseHistoricalWorkbook } from '../app/utils/historicalWorkbook.js'

const buf = readFileSync('Real_Star_June-Nov_2026_Import_Review.xlsx')
const wb = parseHistoricalWorkbook(new Uint8Array(buf))

const novLeads = wb.rows.filter(r => r.source_sheet === 'RegistrationLeads' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'))
const novPayments = wb.rows.filter(r => r.source_sheet === 'Payments' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'))

function norm(s) {
  return String(s || '').trim().toLowerCase().replace(/[\s\-_]+/g, ' ')
}

const payMap = new Map()
for (const p of novPayments) {
  const k = norm(p.payload['Student Name'])
  if (!payMap.has(k)) payMap.set(k, [])
  payMap.get(k).push(p)
}

for (const l of novLeads) {
  const name = norm(l.payload['Student Name'])
  if (payMap.has(name)) {
    console.log({
      leadName: l.payload['Student Name'],
      leadClass: l.payload['Class'],
      leadTime: l.payload['Time'],
      paymentMatches: payMap.get(name).map(p => ({
        teacher: p.payload['Teacher'],
        fee: p.payload['Monthly Fee'],
        amount: p.payload['Amount Received'],
        bill: p.payload['Bill No'],
        date: p.payload['Payment Date Parsed'] || p.payload['Payment Date Raw']
      }))
    })
  }
}
