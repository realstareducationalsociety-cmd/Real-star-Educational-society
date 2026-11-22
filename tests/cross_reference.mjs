import { readFileSync } from 'node:fs';
import { parseHistoricalWorkbook } from '../app/utils/historicalWorkbook.js';

const buf = readFileSync('Real_Star_June-Nov_2026_Import_Review.xlsx');
const wb = parseHistoricalWorkbook(new Uint8Array(buf));

const novRegs = wb.rows.filter(r => r.source_sheet === 'Registrations' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));
const novLeads = wb.rows.filter(r => r.source_sheet === 'RegistrationLeads' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));
const novPayments = wb.rows.filter(r => r.source_sheet === 'Payments' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));

function norm(s) {
  return String(s || '').trim().toLowerCase().replace(/[\s\-_]+/g, ' ');
}

// Map payments by normalized student name
const paymentByName = new Map();
for (const p of novPayments) {
  const name = norm(p.payload['Name Key'] || p.payload['Full Name']);
  if (!paymentByName.has(name)) paymentByName.set(name, []);
  paymentByName.get(name).push(p);
}

let regMatchedToPayment = 0;
let regUnmatchedPayment = 0;
for (const r of novRegs) {
  const name = norm(r.payload['Name Key'] || r.payload['Full Name']);
  const matches = paymentByName.get(name);
  if (matches && matches.length > 0) {
    regMatchedToPayment++;
  } else {
    regUnmatchedPayment++;
  }
}
console.log('140 Registrations: matched to payments =', regMatchedToPayment, ', unpaid/unmatched =', regUnmatchedPayment);

let leadMatchedToPayment = 0;
let leadUnmatchedPayment = 0;
for (const l of novLeads) {
  const name = norm(l.payload['Name']);
  const matches = paymentByName.get(name);
  if (matches && matches.length > 0) {
    leadMatchedToPayment++;
  } else {
    leadUnmatchedPayment++;
  }
}
console.log('66 Leads: matched to payments =', leadMatchedToPayment, ', unmatched =', leadUnmatchedPayment);

// Which payments did not match any of the 140 registrations?
let paymentsInReg = 0;
let paymentsNotInReg = 0;
const regNames = new Set(novRegs.map(r => norm(r.payload['Name Key'] || r.payload['Full Name'])));
for (const p of novPayments) {
  const name = norm(p.payload['Name Key'] || p.payload['Full Name']);
  if (regNames.has(name)) paymentsInReg++;
  else paymentsNotInReg++;
}
console.log('117 Payments: matching a registration =', paymentsInReg, ', not in registrations =', paymentsNotInReg);
