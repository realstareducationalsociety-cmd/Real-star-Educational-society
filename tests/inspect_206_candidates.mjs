import { readFileSync } from 'node:fs';
import { parseHistoricalWorkbook } from '../app/utils/historicalWorkbook.js';

const buf = readFileSync('Real_Star_June-Nov_2026_Import_Review.xlsx');
const wb = parseHistoricalWorkbook(new Uint8Array(buf));

const novRegs = wb.rows.filter(r => r.source_sheet === 'Registrations' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));
const novLeads = wb.rows.filter(r => r.source_sheet === 'RegistrationLeads' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));
const novPayments = wb.rows.filter(r => r.source_sheet === 'Payments' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));

console.log('206 Candidates breakdown:');
console.log('140 Registrations:');
for (let i = 0; i < 5; i++) {
  const r = novRegs[i];
  console.log(`  ${r.source_key}: Name="${r.payload['Full Name']}" Class="${r.payload['Class Name']}" Teacher="${r.payload['Teacher']}" Time="${r.payload['Time']}" Fee=${r.payload['Original Tuition']} Disc=${r.payload['Discount']} Recv=${r.payload['Roster Received']}`);
}

console.log('66 Leads:');
for (let i = 0; i < 5; i++) {
  const l = novLeads[i];
  console.log(`  ${l.source_key}: Name="${l.payload['Name']}" Class="${l.payload['Class']}" Time="${l.payload['Time']}" Contact="${l.payload['Contact']}" Remarks="${l.payload['Remarks']}"`);
}
