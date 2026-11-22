import { readFileSync } from 'node:fs';
import { parseHistoricalWorkbook } from '../app/utils/historicalWorkbook.js';

const buf = readFileSync('Real_Star_June-Nov_2026_Import_Review.xlsx');
const wb = parseHistoricalWorkbook(new Uint8Array(buf));

// 1. Teachers
const teacherSheet = wb.rows.filter(r => r.source_sheet === 'Teachers');
console.log('Teachers sheet rows count:', teacherSheet.length);
if (teacherSheet.length > 0) {
  teacherSheet.forEach(t => console.log('Teacher row:', t.payload));
}

// 2. November Classes
const novClasses = wb.rows.filter(r => r.source_sheet === 'Classes' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));
console.log('Nov classes rows count:', novClasses.length);
novClasses.forEach((c, idx) => {
  console.log(`${idx + 1}: ${c.payload['Class Name']} | Teacher: ${c.payload['Teacher']} | Time: ${c.payload['Time']} | Fee: ${c.payload['Default Fee'] || ''} | Key: ${c.payload['Class Key']}`);
});

// 3. November Summary Classes
const novSum = wb.rows.filter(r => r.source_sheet === 'SummaryClasses' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));
console.log('Nov SummaryClasses count:', novSum.length);
novSum.forEach((s, idx) => {
  console.log(`${idx + 1}: Class: ${s.payload['Class']} | Teacher: ${s.payload['Teacher']} | Students: ${s.payload['Reported Students']} | Received: ${s.payload['Reported Received']} | TeacherShare: ${s.payload['Reported Teacher']}`);
});

// 4. November Registrations (140 rows)
const novRegs = wb.rows.filter(r => r.source_sheet === 'Registrations' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));
console.log('Nov Registrations count:', novRegs.length);

// 5. November RegistrationLeads (66 rows)
const novLeads = wb.rows.filter(r => r.source_sheet === 'RegistrationLeads' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));
console.log('Nov Leads count:', novLeads.length);

// 6. November Payments (117 rows)
const novPayments = wb.rows.filter(r => r.source_sheet === 'Payments' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));
console.log('Nov Payments count:', novPayments.length);
