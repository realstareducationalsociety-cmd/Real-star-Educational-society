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

// Student sheet persons (502 candidate persons)
const studentSheet = wb.rows.filter(r => r.source_sheet === 'Students');
const studentByNorm = new Map();
for (const s of studentSheet) {
  const n = norm(s.payload['Normalized Name'] || s.payload['Display Name Candidate']);
  studentByNorm.set(n, s.payload);
}

console.log('Students in Student sheet:', studentSheet.length);

// Analyze unique names in November
const allNovPersons = new Map();

function addPerson(name, source, extra = {}) {
  const n = norm(name);
  if (!n) return;
  if (!allNovPersons.has(n)) {
    allNovPersons.set(n, {
      name: name.trim(),
      norm: n,
      sources: new Set(),
      contacts: new Set(),
      classes: new Set(),
      studentSheetMatch: studentByNorm.get(n) || null
    });
  }
  const entry = allNovPersons.get(n);
  entry.sources.add(source);
  if (extra.contact) entry.contacts.add(extra.contact);
  if (extra.class) entry.classes.add(extra.class);
}

for (const r of novRegs) {
  addPerson(r.payload['Full Name'] || (r.payload['First Name'] + ' ' + (r.payload['Last Name'] || '')), 'Registrations', {
    class: r.payload['Class Name']
  });
}

for (const l of novLeads) {
  addPerson(l.payload['Name'], 'RegistrationLeads', {
    contact: l.payload['Contact'],
    class: l.payload['Class']
  });
}

for (const p of novPayments) {
  addPerson(p.payload['Full Name'] || (p.payload['First Name'] + ' ' + (p.payload['Last Name'] || '')), 'Payments', {
    class: p.payload['Class Level']
  });
}

console.log('Total unique student identities identified in Nov across all 3 sheets:', allNovPersons.size);

// Check if any name has conflicting information or multiple entries in same source
let multipleClasses = 0;
for (const [k, v] of allNovPersons) {
  if (v.classes.size > 1) multipleClasses++;
}
console.log('Students enrolled in > 1 class:', multipleClasses);
