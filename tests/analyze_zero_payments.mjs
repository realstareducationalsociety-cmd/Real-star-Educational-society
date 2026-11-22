import { readFileSync } from 'node:fs';
import { parseHistoricalWorkbook } from '../app/utils/historicalWorkbook.js';

const buf = readFileSync('Real_Star_June-Nov_2026_Import_Review.xlsx');
const wb = parseHistoricalWorkbook(new Uint8Array(buf));

const novPayments = wb.rows.filter(r => r.source_sheet === 'Payments' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));

const zeroPayments = novPayments.filter(p => Number(p.payload['Amount Received'] || 0) === 0);
console.log('Zero payments count:', zeroPayments.length);
for (const p of zeroPayments) {
  console.log(p.payload);
}
