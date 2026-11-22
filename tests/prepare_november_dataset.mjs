import { readFileSync } from 'node:fs';
import { parseHistoricalWorkbook } from '../app/utils/historicalWorkbook.js';

const buf = readFileSync('Real_Star_June-Nov_2026_Import_Review.xlsx');
const wb = parseHistoricalWorkbook(new Uint8Array(buf));

function norm(s) {
  return String(s || '').trim().toLowerCase().replace(/[\s\-_]+/g, ' ');
}

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

function normalizeClassTitle(title) {
  if (!title) return '';
  const t = title.trim();
  if (t === 'A2' || t === 'A 2') return 'Special A2';
  if (t === 'B1' || t === 'B 1') return 'Special B1';
  if (t === 'B2' || t === 'B 2') return 'Special B2';
  if (t === 'FF 1' || t === 'FF1') return 'Family & Friends 1';
  if (t === 'FF 2') return 'Family & Friends 2';
  if (t === 'FF 3' || t === 'FF3') return 'Family & Friends 3';
  if (t === 'FF 4' || t === 'FF4') return 'Family & Friends 4';
  if (t === 'Get 1') return 'Get Involved 1';
  if (t === 'Get 2') return 'Get Involved 2';
  if (t === 'Excel') return 'Computer MS Excel';
  if (t === 'Intermadiate') return 'Intermadiate class';
  if (t === 'Advance') return 'Advance class';
  if (t === 'Grade 1,2,3' || t === 'Grade, 1,2,3') return 'Grade 1,2,3';
  if (t === 'Grade 1') return 'Grade 1';
  if (t === 'Grade 3') return 'Grade 3';
  if (t === 'Starter') return 'Family & Friends 1 (Starter)';
  return t;
}

const novRegs = wb.rows.filter(r => r.source_sheet === 'Registrations' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));
const novLeads = wb.rows.filter(r => r.source_sheet === 'RegistrationLeads' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));
const novPayments = wb.rows.filter(r => r.source_sheet === 'Payments' && (r.payload['Period'] === '2026-11' || r.payload['Source Month'] === 'Nov'));

console.log(`Source rows: ${novRegs.length} Registrations + ${novLeads.length} Leads = ${novRegs.length + novLeads.length} Candidates. ${novPayments.length} Payments.`);

// Group payments by student name + class
const paymentsByStudentClass = new Map();
for (const p of novPayments) {
  const name = norm(p.payload['Name Key'] || p.payload['Full Name']);
  const cls = normalizeClassTitle(p.payload['Class Level']);
  const key = `${name}::${cls}`;
  if (!paymentsByStudentClass.has(key)) paymentsByStudentClass.set(key, []);
  paymentsByStudentClass.get(key).push(p);
}

// Also group payments by student name only
const paymentsByStudent = new Map();
for (const p of novPayments) {
  const name = norm(p.payload['Name Key'] || p.payload['Full Name']);
  if (!paymentsByStudent.has(name)) paymentsByStudent.set(name, []);
  paymentsByStudent.get(name).push(p);
}

// Build unified candidate records
const candidates = [];

// 1. From Registrations (140 rows)
for (const r of novRegs) {
  const p = r.payload;
  const fullName = (p['Full Name'] || (p['First Name'] + ' ' + (p['Last Name'] || ''))).trim();
  const nameKey = norm(p['Name Key'] || fullName);
  const className = normalizeClassTitle(p['Class Name']);
  const teacherName = normalizeTeacher(p['Teacher']);
  let schedule = p['Time'] || '';
  if (schedule && !schedule.includes('pm') && !schedule.includes(':')) schedule += ' pm';

  const origFee = Number(p['Original Tuition']) || 1500;
  const disc = Number(p['Discount']) || 0;
  const agreedFee = origFee;
  const payable = Math.max(0, agreedFee - disc);
  const teacherShare = Number(p['Teacher Share']) || Math.round(agreedFee * 0.5);

  // Check matching payment
  let matchedPayment = null;
  const classMatches = paymentsByStudentClass.get(`${nameKey}::${className}`);
  if (classMatches && classMatches.length > 0) {
    matchedPayment = classMatches[0];
  } else {
    const studentMatches = paymentsByStudent.get(nameKey);
    if (studentMatches && studentMatches.length === 1) {
      matchedPayment = studentMatches[0];
    }
  }

  const payAmt = matchedPayment ? (Number(matchedPayment.payload['Amount Received']) || 0) : 0;
  const payDate = matchedPayment ? (matchedPayment.payload['Payment Date Parsed'] || matchedPayment.payload['Payment Date Raw']) : null;
  const payBill = matchedPayment ? matchedPayment.payload['Bill No'] : null;
  const payRef = matchedPayment ? `Bill No: ${payBill} | ${matchedPayment.source_key}` : (p['Source Slip'] ? `Slip: ${p['Source Slip']}` : null);

  const isFullScholarship = (agreedFee > 0 && disc >= agreedFee);

  candidates.push({
    source_key: r.source_key,
    source_sheet: 'Registrations',
    source_row: r.source_row,
    student_name: fullName,
    name_key: nameKey,
    first_name: p['First Name'] || fullName.split(' ')[0],
    last_name: p['Last Name'] || fullName.split(' ').slice(1).join(' '),
    class_name: className,
    teacher_name: teacherName,
    class_schedule: schedule,
    original_fee: origFee,
    agreed_fee: agreedFee,
    discount: disc,
    discount_reason: disc > 0 ? (isFullScholarship ? 'Confirmed institutional scholarship' : 'Approved student discount') : '',
    teacher_entitlement: teacherShare,
    is_exception: teacherShare !== Math.round(agreedFee * 0.5),
    exception_reason: teacherShare !== Math.round(agreedFee * 0.5) ? 'Approved teacher entitlement exception' : '',
    payment_amount: payAmt,
    payment_date: payDate,
    payment_method: 'cash',
    payment_reference: payRef,
    is_scholarship: isFullScholarship,
    matched_payment_key: matchedPayment?.source_key || null,
    review_status: (fullName && className && teacherName) ? 'ready' : 'needs_review'
  });
}

// 2. From RegistrationLeads (66 rows)
for (const l of novLeads) {
  const p = l.payload;
  const fullName = String(p['Name'] || '').trim();
  const nameKey = norm(fullName);
  const className = normalizeClassTitle(p['Class'] || '');
  let schedule = p['Time'] || '';
  if (schedule && !schedule.includes('pm') && !schedule.includes(':')) schedule += ' pm';

  // Check matching payment
  let matchedPayment = null;
  const studentMatches = paymentsByStudent.get(nameKey);
  if (studentMatches && studentMatches.length > 0) {
    matchedPayment = studentMatches[0];
  }

  const teacherName = matchedPayment ? normalizeTeacher(matchedPayment.payload['Teacher']) : '';
  const origFee = matchedPayment ? (Number(matchedPayment.payload['Monthly Fee']) || 1500) : 1500;
  const disc = matchedPayment ? (Number(matchedPayment.payload['Discount']) || 0) : 0;
  const agreedFee = origFee;
  const teacherShare = matchedPayment ? (Number(matchedPayment.payload['Teacher Share']) || Math.round(agreedFee * 0.5)) : Math.round(agreedFee * 0.5);
  const payAmt = matchedPayment ? (Number(matchedPayment.payload['Amount Received']) || 0) : 0;
  const payDate = matchedPayment ? (matchedPayment.payload['Payment Date Parsed'] || matchedPayment.payload['Payment Date Raw']) : null;
  const payBill = matchedPayment ? matchedPayment.payload['Bill No'] : null;
  const payRef = matchedPayment ? `Bill No: ${payBill} | ${matchedPayment.source_key}` : (p['Contact'] ? `Contact: ${p['Contact']}` : null);

  const isFullScholarship = (agreedFee > 0 && disc >= agreedFee);
  // Leads with payment or explicit confirmed class are ready; incomplete inquiries need review
  const isReady = !!(fullName && className && (matchedPayment || p['Remarks']?.includes('confirmed')));

  candidates.push({
    source_key: l.source_key,
    source_sheet: 'RegistrationLeads',
    source_row: l.source_row,
    student_name: fullName,
    name_key: nameKey,
    first_name: fullName.split(' ')[0] || '',
    last_name: fullName.split(' ').slice(1).join(' ') || '',
    class_name: className,
    teacher_name: teacherName,
    class_schedule: schedule,
    original_fee: origFee,
    agreed_fee: agreedFee,
    discount: disc,
    discount_reason: disc > 0 ? (isFullScholarship ? 'Confirmed institutional scholarship' : 'Approved student discount') : '',
    teacher_entitlement: teacherShare,
    is_exception: teacherShare !== Math.round(agreedFee * 0.5),
    exception_reason: teacherShare !== Math.round(agreedFee * 0.5) ? 'Approved teacher entitlement exception' : '',
    payment_amount: payAmt,
    payment_date: payDate,
    payment_method: 'cash',
    payment_reference: payRef,
    is_scholarship: isFullScholarship,
    matched_payment_key: matchedPayment?.source_key || null,
    contact_phone: p['Contact'] || '',
    notes: p['Remarks'] || '',
    review_status: isReady ? 'ready' : 'needs_review'
  });
}

console.log(`Total Candidates processed: ${candidates.length}`);
const readyCount = candidates.filter(c => c.review_status === 'ready').length;
const reviewCount = candidates.filter(c => c.review_status === 'needs_review').length;
console.log(`Ready for Approval: ${readyCount}, Needs Review: ${reviewCount}`);
const scholarshipCount = candidates.filter(c => c.is_scholarship).length;
console.log(`Full Scholarships: ${scholarshipCount}`);
const withPaymentCount = candidates.filter(c => c.payment_amount > 0).length;
console.log(`Candidates with verified payments: ${withPaymentCount}`);
