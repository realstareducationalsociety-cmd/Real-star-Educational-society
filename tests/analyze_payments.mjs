import { readFileSync } from 'node:fs';
import { parseHistoricalWorkbook } from '../app/utils/historicalWorkbook.js';

const buf = readFileSync('Real_Star_June-Nov_2026_Import_Review.xlsx');
const wb = parseHistoricalWorkbook(new Uint8Array(buf));

const novPayments = wb.rows.filter(r => r.source_sheet === 'Payments' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));

console.log('Payments count:', novPayments.length);
let withDate = 0;
let withAmount = 0;
let withBill = 0;
let totalAmount = 0;

for (const p of novPayments) {
  const pl = p.payload;
  if (pl['Payment Date Parsed'] || pl['Payment Date Raw']) withDate++;
  const amt = Number(pl['Amount Received'] || 0);
  if (amt > 0) withAmount++;
  totalAmount += amt;
  if (pl['Bill No']) withBill++;
}

console.log('Payments with date:', withDate);
console.log('Payments with positive amount:', withAmount);
console.log('Payments with Bill No:', withBill);
console.log('Total verified collections:', totalAmount);
