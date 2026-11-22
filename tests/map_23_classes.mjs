import { readFileSync } from 'node:fs';
import { parseHistoricalWorkbook } from '../app/utils/historicalWorkbook.js';

const buf = readFileSync('Real_Star_June-Nov_2026_Import_Review.xlsx');
const wb = parseHistoricalWorkbook(new Uint8Array(buf));

// Collect classes from Classes sheet, SummaryClasses, Registrations, and Payments
const classesSheet = wb.rows.filter(r => r.source_sheet === 'Classes' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));
const novPayments = wb.rows.filter(r => r.source_sheet === 'Payments' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));

function normalizeTeacher(name) {
  if (!name) return '';
  const n = name.trim().toLowerCase();
  if (n.includes('malali') || n.includes('malaly')) return 'Malali Naziri';
  if (n.includes('farzan')) return 'Farzan Noori';
  if (n.includes('mohaddisa') || n.includes('yasin')) return 'Mohaddisa Yasin';
  if (n.includes('hassani') || n === 'ali' || n.startsWith('ali ')) return 'Ali Hassani';
  if (n.includes('shakila')) return 'Shakila';
  if (n.includes('wahida') || n.includes('mohassel')) return 'Wahida Mohassel';
  if (n.includes('danish')) return 'Danish';
  if (n.includes('khatima')) return 'Khatima';
  if (n.includes('tahira') || n.includes('sakhizada')) return 'Tahira Sakhizada';
  if (n.includes('freshta')) return 'Freshta';
  return name.trim();
}

console.log('--- Canonical Class Groups Mapping ---');
const classGroups = new Map();

for (const c of classesSheet) {
  let title = c.payload['Class Name'];
  const teacher = normalizeTeacher(c.payload['Teacher']);
  let time = c.payload['Time'] || '';
  if (time === '46148') continue; // duplicate row
  if (title === 'FF 1') title = 'Family & Friends 1';
  if (title === 'FF 2') title = 'Family & Friends 2';
  if (time && !time.includes('pm') && !time.includes(':')) time += ' pm';
  const key = `${title} | ${teacher} | ${time}`.toLowerCase();
  if (!classGroups.has(key)) {
    classGroups.set(key, { title, teacher, time, source: 'Classes sheet', fee: 2000 });
  }
}

for (const p of novPayments) {
  let title = p.payload['Class Level'];
  const teacher = normalizeTeacher(p.payload['Teacher']);
  let time = p.payload['Class Time'] || '';
  if (time && !time.includes('pm') && !time.includes(':')) time += ' pm';
  if (title === 'A2' || title === 'A 2') title = 'Special A2';
  else if (title === 'B1' || title === 'B 1') title = 'Special B1';
  else if (title === 'B2' || title === 'B 2') title = 'Special B2';
  else if (title === 'FF 1') title = 'Family & Friends 1';
  else if (title === 'FF 2') title = 'Family & Friends 2';
  else if (title === 'FF 3') title = 'Family & Friends 3';
  else if (title === 'FF 4') title = 'Family & Friends 4';
  else if (title === 'Get 1') title = 'Get Involved 1';
  else if (title === 'Get 2') title = 'Get Involved 2';
  else if (title === 'Excel') title = 'Computer MS Excel';
  else if (title === 'Intermadiate') title = 'Intermadiate class';
  else if (title === 'Advance') title = 'Advance class';
  else if (title === 'Grade 1') title = 'Grade 1';
  else if (title === 'Grade 3') title = 'Grade 3';
  else if (title === 'Art') title = 'Art';

  const key = `${title} | ${teacher} | ${time}`.toLowerCase();
  if (!classGroups.has(key)) {
    classGroups.set(key, { title, teacher, time, source: 'Payments sheet', fee: Number(p.payload['Monthly Fee']) || 2000 });
  }
}

console.log('Total Class Groups found:', classGroups.size);
let i = 1;
for (const [k, v] of classGroups) {
  console.log(`${i++}. "${v.title}" | Teacher: "${v.teacher}" | Schedule: "${v.time}" | Fee: ${v.fee}`);
}
