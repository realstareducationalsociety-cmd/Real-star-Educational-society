# Chapters, independent books, monthly printing, and student registration

## Deployment

1. Back up the existing database and review existing material sales and printing costs.
2. Run `supabase/migrations/002_chapters_books_printing.sql` once in the Supabase SQL Editor as the migration owner, **after** `001_initial.sql`. The original migration is unchanged. The upgrade is transactional.
3. Run `supabase/migrations/003_confirmed_monthly_registration.sql` once after both earlier migrations. It preserves existing month rows, makes new month setup non-renewing, and adds audited share overrides.
4. Run `supabase/migrations/004_database_integrity.sql` once after `003`. It adds idempotent registration requests, monthly registration statistics, controlled settlement/adjustment RPCs, migration review records, and final RPC permissions.
5. Run `NOTIFY pgrst, 'reload schema';` in the SQL Editor after successful migrations.
6. Run `npm ci`, `npm run typecheck`, `npm test`, `npm run build`, and `npm run test:print`. On Windows PowerShell with script execution disabled, use `npm.cmd`.
7. Deploy the rebuilt application after all database migrations. No new environment variables or production runtime services are required.

## Confirmed monthly registration and manual tuition shares

- **ثبت‌نام شاگردان** (`/enrollments`): search and select a permanent student profile or create one; choose one or more classes, month, registration date, and discount. The database creates monthly class memberships atomically and prevents an active duplicate for the same student/class/month.
- Previous-month active registrations can be selected and renewed in one atomic bulk operation. The system does not auto-renew current permanent class links when a new billing period is opened. Cancelled monthly memberships are retained but excluded from monthly counts and reports; cancellation is blocked when that membership has a payment or its class/teacher has a settlement.
- The dashboard's primary student statistic and class counts use active monthly student-class memberships. Unique active student profiles are shown separately. Class and finance reports use the same confirmed monthly rows.
- Automatic teacher/office shares retain the original 50% teacher rule and apply ordinary discounts to the office share. An admin may choose manual shares with a reason; the database enforces nonnegative values and that the two shares exactly equal the student's payable tuition.
- Every manual adjustment keeps actor, timestamp, reason, and before/after row data in the existing audit log. Manual share changes are rejected after any settlement for the same class/teacher/month, because this system does not yet include a settlement correction workflow. Tuition edits also remain subject to the existing payment and month-lock guards.

Existing material sales retain their IDs, quantities, prices, dates, and legacy commission data. They are initially **unpaid** because the old schema contains no receipts proving collection. Enter verified receipts through payment history workflows; do not assume historical sales were paid. Legacy sales without student/class links remain visible as legacy records rather than being assigned to guessed students. Existing chapters need a class assigned before new sales can be recorded. Stock represents all copies received/produced, including those already sold.

Printing cost dates are initialized from each chapter's creation date. Review those dates and reconcile any printing costs previously entered in general expenses. Record each cost in one place only; the upgrade cannot identify duplicate costs in free-text legacy expenses. A chapter's printing-cost field is its total production cost; editing it corrects that cost with an audit record, rather than creating a new production batch.

## Staff workflow

- **چپترها** (`/chapters`): register a chapter, class, price, total copies, and optional printing cost/date. Register a sale and any initial receipt. Add subsequent payments or inspect/void receipts with a reason. Filter by sale month, class, student/code, and status; print the filtered report.
- **کتاب‌ها** (`/books`): register the external owner, book, price, stock, and description. Sell and record partial/full payments. Clicking an unpaid checkbox opens confirmation of the remaining amount and actual payment date. The checkbox becomes checked only after a successful database receipt. It cannot undo payment; use history and an audited void instead.
- **صنف‌ها**: choose **چاپ راپور ماهانه**, select a month, and display the report. The report reads stored monthly memberships, including students who subsequently left. It does not generate or reconstruct historical membership.
- **تصفیه استادان**: **چاپ صورت‌حساب** opens a class/teacher/month report. **راپور مجموع استاد** opens that teacher's combined report and individual class pages. Both include settlement history and signature spaces.
- Choose **چاپ / ذخیره PDF** to open native browser printing. Use A4 landscape for reports; existing tuition receipts retain portrait printing. Browser headers/footers can be disabled in the print dialog.
- The general dashboard's office summary has its own month selector. Book totals are only shown in Books.

## Financial meaning

- Material payments are positive, immutable receipts, with reasoned voids. A shared ledger has mutually exclusive foreign keys to existing book or chapter sales. RPCs serialize changes by locking the sale row, update totals atomically, and use unique request IDs for retries. Full-payment actions are idempotent even with a different request ID after completion.
- Chapter receipts belong entirely to the office. Outstanding sale balances are not revenue. Printing costs reduce net amounts once in the office query; no duplicate expense row is automatically created.
- Office queries never read book sales, book commissions, or book-owner settlements. New book sales record zero commission. Existing commission fields are preserved solely for historical compatibility.
- Office collections use actual receipt dates. Teacher entitlement uses the billed month and the existing formula, independent of student payment. Cash remaining deducts actual teacher payments; the separate entitlement-adjusted balance deducts monthly teacher entitlement. Neither automatically distributes partner profits.
- Material report totals are lifetime receipts/balances **for sales in the filtered sale month**, as of report generation. They are not receipts collected only in that month. Chapter outstanding on the dashboard includes all sale dates. These bases are labelled in the interface.
- Monthly class reports show receipts and settlements associated with that billing month as of generation, excluding voids. The class title and teacher assignment come from monthly snapshots. Student/teacher names are current names. Historical schedules were never stored; available current schedules are explicitly labelled as current.
- Admin/accountant can use the new financial workflows. Registrar cannot call new financial/report RPCs or read material tables. Existing education permissions remain unchanged. Enrollment student/class identities cannot be reassigned, preventing historical memberships from moving between students/classes; create a new enrollment instead.

## Files

New: `supabase/migrations/002_chapters_books_printing.sql`, `supabase/migrations/003_confirmed_monthly_registration.sql`, `supabase/migrations/004_database_integrity.sql`, `DATABASE_AUDIT.md`, `app/pages/books.vue`, `app/pages/chapters.vue`, `app/pages/reports/monthly.vue`, `app/components/MaterialManager.vue`, `app/components/OfficeSummary.vue`, `app/components/PrintReport.vue`, `app/composables/useAllRows.ts`, `tsconfig.json`, `tests/materials_database.mjs`, `tests/database_audit.mjs`, `tests/database_contracts.mjs`, `tests/error_messages.mjs`, `tests/print_browser.mjs`, and this document.

Updated: `app/layouts/default.vue`, `app/middleware/auth.global.ts`, `app/pages/classes.vue`, `app/pages/enrollments.vue`, `app/pages/finance.vue`, `app/pages/settlements.vue`, `app/pages/index.vue`, `app/pages/reports/monthly.vue`, `app/types/models.ts`, `app/assets/css/main.css`, `app/components/Notice.vue`, `app/components/OfficeSummary.vue`, `app/pages/expenses.vue`, `tests/check_ts.cjs`, `package.json`, `package-lock.json`, `.gitignore`, and `README.md`. Notice formatting, expense date typing, portable syntax-test imports, and TypeScript configuration fix pre-existing check failures.

## Verification and limits

The database tests execute all four migrations against isolated PostgreSQL (PGlite) with simulated Supabase Auth roles. They cover migration compatibility, financial arithmetic, book isolation, receipt dates, statuses, retry handling, overpayments, stock/rollback, void/audit history, monthly reports, historical enrollment, explicit and bulk monthly registration, duplicate/rollback behavior, manual-share arithmetic, cancellation counts, monthly statistics, and role permissions. PGlite uses built-in `gen_random_uuid`; only the initial `CREATE EXTENSION pgcrypto` line is skipped in tests. No production records are changed by tests.

This is not a live Supabase/PostgREST test or a multi-connection concurrency stress test. Deployment, real staff sign-in, and printer-specific pagination still need validation in the target environment. The existing Python arithmetic test requires Python, which is not executable in this workspace; its key entitlement cases are exercised in the PostgreSQL tests instead.

Successful checks: `npm test`, `npm run typecheck`, `npm run build`, and `npm run test:print`. The browser test compiles the actual monthly Vue report and renders 80 synthetic student records in a test-only server. It checks visibility, black text, repeating table-header styling, row breaks, multiple generated PDF pages, and preservation of the existing tuition receipt. A screenshot was visually inspected. The test requires installed Chrome (default) or Edge (`TEST_BROWSER_CHANNEL=msedge`); artifacts go into ignored `.test-artifacts/`. It does not simulate live Supabase sign-in or a physical printer.

The supplied official logo is now used unchanged in reports and application branding; see BRANDING.md. Browser printing supports PDF without a PDF-generation dependency. Development test dependencies are not application runtime dependencies.

## Dashboard registration and withdrawals — 2026-11-20

Implemented the shared `MonthlyRegistration.vue` on the dashboard and `/enrollments`, with English/Dari labels, Karachi month/date defaults, permanent-profile search, prior-month/latest-earlier financial cards, searchable class selection, per-class discounts, and atomic new/returning registration. Existing class fees and teacher assignments are authoritative; manual historical shares are shown for reference and not copied.

Migration `007_dashboard_registration.sql` adds three restricted RPCs:
- `registration_student_search(p_query text) returns jsonb`: normalized partial search, permanent identity and latest class/month suggestions, 30-result cap.
- `registration_previous(p_student uuid, p_month date) returns jsonb`: all active registrations in the latest earlier billing month, actual valid collections and effective historical shares.
- `register_dashboard_student(p_payload jsonb, p_request uuid) returns jsonb`: request-id retry protection around existing registration/payment functions; returns student_id, student_code and membership_count. All selected classes/profile/receipts roll back together on failure. Existing profiles are reused without replacing their contact details.

Migration `008_registration_proration_and_settlements.sql` applies the confirmed fixed half-month tuition rule after day 20 throughout the shared registration function, including single registrations and bulk renewals. It preserves `original_fee` separately from applicable `base_fee`, records the proration basis, and extends registration with per-class initial receipts requiring an explicit actual date and payment method. Registrars may record these initial receipts through the database-authorized payment function; a zero payment creates no receipt.

Teacher settlements require an explicit payment method, store the method with the receipt, and expose an authorized history RPC that includes the recorder's staff name. The prior RPC signature without a method is revoked so outdated clients cannot silently assume cash. Settlement KPIs are hidden until the selected month loads successfully, and dashboard/finance pages no longer render zero totals after failed summary queries.

Partner withdrawal entry now fixes transaction kind to withdrawal. A dedicated history includes partner/month/date-range filters, recorded-by identity, status and monthly totals excluding voids. Full accounting history and its audited reversal controls remain. Capital contribution entry is preserved separately in a collapsed accounting section; no capital data was removed.

### Deployment and remaining work

Migrations 007 and 008 are LOCAL ONLY. Configured project host: `sdknqymjvqpisjedljou.supabase.co`. Prior read-only evidence found migration 002 installed and migrations 003–004 missing; the later status of 005–008 has not been verified. No production SQL or example data was submitted. A restorable backup has not been verified, so no production migration or workbook import was run.

Validation uses isolated PostgreSQL/PGlite migrations and tests for multi-class creation, gap-month history, original/applicable fees, full tuition on day 20 and half tuition on day 21, dashboard and legacy registrations, renewals, explicit initial receipts, role permissions, atomic rollback, idempotency, settlement method/recorder history, and existing financial controls. Nuxt typecheck, browser regression, and production build are run for this update. These local synthetic fixtures are not live Supabase acceptance tests.

Browser regression: `PLAYWRIGHT_CHANNEL=chrome node tests/dashboard_browser.mjs` uses synthetic API fixtures only. It covers returning/new registration payloads, manual selection of previous classes, explicit receipt date/method, half-month pricing after day 20, English, Dari RTL, and mobile layout. It does not certify live integration.
