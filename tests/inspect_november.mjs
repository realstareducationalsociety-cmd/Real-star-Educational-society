import { readFileSync } from 'node:fs';
import { parseHistoricalWorkbook } from '../app/utils/historicalWorkbook.js';

const buf = readFileSync('Real_Star_June-Nov_2026_Import_Review.xlsx');
const wb = parseHistoricalWorkbook(new Uint8Array(buf));

const groups = new Map();
for (const r of wb.rows) {
  if (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov') {
    const cls = r.payload['Class Name'] || r.payload['Class'];
    const teacher = r.payload['Teacher'];
    const time = r.payload['Time'] || '';
    const key = (r.payload['Class Key'] || (cls + ' | ' + teacher + ' | ' + time)).toLowerCase();
    if (cls) {
      if (!groups.has(key)) {
        groups.set(key, { cls, teacher, time, key, sources: new Set() });
      }
      groups.get(key).sources.add(r.source_sheet);
    }
  }
}
console.log('Class groups found:', groups.size);
let i = 1;
for (const [k, v] of groups) {
  console.log(`${i++}. ${v.cls} | Teacher: ${v.teacher} | Time: ${v.time} | Sheet: ${[...v.sources].join(',')}`);
}
