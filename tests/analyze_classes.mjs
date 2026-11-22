import { readFileSync } from 'node:fs';
import { parseHistoricalWorkbook } from '../app/utils/historicalWorkbook.js';

const buf = readFileSync('Real_Star_June-Nov_2026_Import_Review.xlsx');
const wb = parseHistoricalWorkbook(new Uint8Array(buf));

// Let's inspect teachers and classes from all November sheets:
const novSheets = ['Classes', 'SummaryClasses', 'Registrations', 'Payments', 'RegistrationLeads'];
const teacherSet = new Set();
const classMap = new Map();

for (const r of wb.rows) {
  if (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov') {
    const t = r.payload['Teacher'];
    if (t) teacherSet.add(t.trim());
  }
}
console.log('Distinct teacher names in Nov:', [...teacherSet]);

// Check payments in November
const novPayments = wb.rows.filter(r => r.source_sheet === 'Payments' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));
const paymentTeachers = new Set(novPayments.map(p => p.payload['Teacher']));
const paymentClasses = new Set(novPayments.map(p => `${p.payload['Class Level']} | ${p.payload['Teacher']} | ${p.payload['Class Time']}`));
console.log('Payment teachers:', [...paymentTeachers]);
console.log('Payment class groups (count ' + paymentClasses.size + '):', [...paymentClasses]);

// Check registrations in November
const novRegs = wb.rows.filter(r => r.source_sheet === 'Registrations' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));
const regClasses = new Set(novRegs.map(r => `${r.payload['Class Name']} | ${r.payload['Teacher']} | ${r.payload['Time']}`));
console.log('Reg class groups (count ' + regClasses.size + '):', [...regClasses]);
