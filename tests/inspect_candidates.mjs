import { readFileSync } from 'node:fs';
import { parseHistoricalWorkbook } from '../app/utils/historicalWorkbook.js';

const buf = readFileSync('Real_Star_June-Nov_2026_Import_Review.xlsx');
const wb = parseHistoricalWorkbook(new Uint8Array(buf));

const novRegs = wb.rows.filter(r => r.source_sheet === 'Registrations' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));
const novLeads = wb.rows.filter(r => r.source_sheet === 'RegistrationLeads' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));
const novPayments = wb.rows.filter(r => r.source_sheet === 'Payments' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));

console.log('--- 140 REGISTRATIONS ANALYSIS ---');
const sampleReg = novRegs[0].payload;
console.log('Reg fields:', Object.keys(sampleReg));
let regWithDiscount = 0;
let regFullScholarship = 0;
let regTeachers = new Set();
let regClasses = new Set();
for (const r of novRegs) {
  const p = r.payload;
  regTeachers.add(p['Teacher']);
  regClasses.add(p['Class Name'] + ' | ' + p['Teacher'] + ' | ' + p['Time']);
  const tuition = Number(p['Original Tuition'] || 0);
  const disc = Number(p['Discount'] || 0);
  if (disc > 0) regWithDiscount++;
  if (tuition > 0 && disc >= tuition) regFullScholarship++;
}
console.log('Regs with discount:', regWithDiscount);
console.log('Regs full scholarship:', regFullScholarship);
console.log('Reg teachers count:', regTeachers.size, [...regTeachers]);
console.log('Reg classes count:', regClasses.size);

console.log('\n--- 66 LEADS ANALYSIS ---');
const sampleLead = novLeads[0].payload;
console.log('Lead fields:', Object.keys(sampleLead));
let leadClasses = new Set();
for (const l of novLeads) {
  leadClasses.add(l.payload['Class'] + ' | ' + l.payload['Time']);
}
console.log('Lead unique class specs:', leadClasses.size, [...leadClasses]);

console.log('\n--- 117 PAYMENTS ANALYSIS ---');
const samplePayment = novPayments[0].payload;
console.log('Payment fields:', Object.keys(samplePayment));
let paymentTotal = 0;
let paymentTeachers = new Set();
for (const p of novPayments) {
  paymentTotal += Number(p.payload['Amount Received'] || 0);
  paymentTeachers.add(p.payload['Teacher']);
}
console.log('Total payment sum:', paymentTotal);
console.log('Payment teachers count:', paymentTeachers.size, [...paymentTeachers]);
