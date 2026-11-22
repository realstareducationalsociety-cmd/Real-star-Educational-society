import { readFileSync } from 'node:fs';
import { parseHistoricalWorkbook } from '../app/utils/historicalWorkbook.js';

const buf = readFileSync('Real_Star_June-Nov_2026_Import_Review.xlsx');
const wb = parseHistoricalWorkbook(new Uint8Array(buf));

const novRegs = wb.rows.filter(r => r.source_sheet === 'Registrations' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));
const novLeads = wb.rows.filter(r => r.source_sheet === 'RegistrationLeads' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));
const novPayments = wb.rows.filter(r => r.source_sheet === 'Payments' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));

console.log('Nov Regs:', novRegs.length);
console.log('Nov Leads:', novLeads.length);
console.log('Nov Payments:', novPayments.length);

// Check student names matching between Regs and Payments
const regStudents = new Set(novRegs.map(r => (r.payload['Name Key'] || r.payload['Full Name']).toLowerCase().trim()));
const leadStudents = new Set(novLeads.map(r => (r.payload['Name'] || '').toLowerCase().trim()));
const paymentStudents = new Set(novPayments.map(p => (p.payload['Name Key'] || p.payload['Full Name']).toLowerCase().trim()));

let matchRegPayment = 0;
let matchLeadPayment = 0;
for (const p of paymentStudents) {
  if (regStudents.has(p)) matchRegPayment++;
  if (leadStudents.has(p)) matchLeadPayment++;
}

console.log('Payments matching Regs by name:', matchRegPayment, '/', paymentStudents.size);
console.log('Payments matching Leads by name:', matchLeadPayment, '/', paymentStudents.size);

// Look at linked roster keys in Payments
const paymentsWithRosterKey = novPayments.filter(p => p.payload['Linked Roster Source Keys']);
console.log('Payments with explicit Linked Roster Source Keys:', paymentsWithRosterKey.length);

// Look at Linked Payment Source Key in Regs
const regsWithPaymentKey = novRegs.filter(r => r.payload['Linked Payment Source Key']);
console.log('Regs with explicit Linked Payment Source Key:', regsWithPaymentKey.length);
