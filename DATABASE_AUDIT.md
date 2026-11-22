# Database audit and migrations

## Evidence and scope

The repository contains `001_initial.sql`, `002_chapters_books_printing.sql`, and `003_confirmed_monthly_registration.sql`. Migration 003 and its frontend registration/manual-adjustment work appeared during this task and were preserved. This upgrade is `supabase/migrations/004_database_integrity.sql`; none of those earlier migrations is rewritten by the audit upgrade.

The complete chain has been executed against isolated PostgreSQL/PGlite with legacy fixtures and simulated Supabase roles. This is not an inspection or deployment of the live Supabase database. Run `supabase/audit_readonly.sql` on the target environment to compare its actual catalog with the repository before deployment. No service-role key is used in the browser.

## Assessment

| Area | Existing structure | Finding / change |
|---|---|---|
| Permanent students | UUID, unique student code, names, guardian/contact/address, active flag | Retained. Add profile registration date, notes, updated timestamp and auditing. Existing-person registrations reuse UUID. |
| Student/class relationships | Unique enrollment per student/class, monthly FK to enrollment and period, frozen teacher/title | Retained. No duplicate student/class FK columns. Enrollment identity cannot be reassigned. |
| Monthly confirmation | 003 adds explicit registration and cancellation | Retain confirmation. Replace unconditional period/enrollment uniqueness with a unique index for active memberships. Re-registration creates a new membership ID; cancelled records remain. |
| Registration retries | No operation identity | Private request ledger stores actor, exact payload, result; single and bulk RPC retries are idempotent. |
| Statistics | Frontend could count profiles or truncated rows | Server RPC counts confirmed memberships, distinct people, classes, teachers, registration type, and class/teacher breakdowns. No payment join. |
| Shares | Original generated 50% formula plus 003 manual overrides | Add canonical effective amounts and calculation mode. Office share is payable less rounded teacher share, avoiding a half-cent double-rounding error. |
| Adjustments | Generic audit and direct administrator adjustment | Add exact membership adjustment requests, before/after values, reasons and administrator review; accountant cannot approve manual changes. |
| Tuition/settlements | Immutable receipts, partial amounts, overpayment guards | Reuse tables. Add retry keys, tuition receipt/status fields, secured recording RPCs, consistent period locking, and void protection. |
| Chapters/books | Existing sales and shared material ledger | Reuse all tables. Ledger triggers enforce totals; chapter receipts alone feed institutional revenue. Preserve independent book-owner liabilities/payouts. |
| Periods | open/locked with incomplete restrictions | Preserve locked as a legacy closed alias; add under_review/closed, closure/reopening metadata, administrator reasoned transitions, and date/billing-period guards. |
| Partners | Arbitrary ownership units and direct transactions | Add exact denominator 3; new units must be 1, maximum three partners. Approved distribution batches enforce three equal exact-cent payments and profit limits. |
| Financial access | Registrar could read raw membership shares and invoker financial views | Restrict membership financial reads to admin/accountant; registrar gets safe registration/statistics RPCs. Revoke direct sensitive writes. |
| Audit | Several financial triggers already exist | Extend reasons/approval attribution, add missing administrative/approval/period/owner/partner auditing; no API update/delete access to logs. |
| Historical ambiguities | Old registration types/dates, missing sale links, negative office shares, legacy commissions | Create review items; do not invent receipts, reassign students, erase history, or silently fix financial values. |

## Added tables

- `registration_requests`: internal idempotency results, inaccessible through ordinary table reads.
- `membership_financial_adjustments`: exact membership FK; previous/new teacher and office amounts, discount, full snapshots, reason/type, requested/approved actors, status and dates.
- `migration_review_items`: explicit historical issues and administrator resolution notes.
- `profit_distribution_batches`: approved period, exact total, retry key, approver/reason and void history. Existing partner transaction rows reference the batch.

These are approval/transaction-control structures missing from the existing schema. Students, tuition receipts, teacher settlement receipts, and material payment tables are not duplicated.

## Columns, relationships and constraints

- Students: `registered_on`, `notes`, `updated_at`. Existing `active` remains the status.
- Memberships: `registration_type` (`new`, `returning`, `renewal`, `legacy`), `updated_at`, generated `calculation_mode`, `effective_teacher_entitlement`, `effective_office_entitlement`. `registration_active=true` means confirmed; unsubmitted/unconfirmed form state does not create a membership.
- Periods: `closed_at/by`, `reopened_at/by`, `closure_notes`; valid states include the legacy `locked` value.
- Tuition: unique nullable legacy-compatible `request_id`, generated globally identifiable receipt number and valid/void status. Multiple receipts still reference the exact membership and thereby student, class and month.
- Teacher settlements: unique request ID; existing period/class/teacher foreign keys and receipt history retained.
- Material receipts: method, note, receipt number, valid/void status. The existing exclusive book-sale/chapter-sale FK check remains authoritative.
- Book sales: historical owner-name snapshot. Owner payouts: request ID, authenticated actor, created timestamp and void reason/date.
- Expenses: void timestamp/reason; correction is void then replacement, never deletion.
- Partners: exact ownership denominator 3; existing units are constrained to 1 for new/changed rows. Partner transactions gain batch FK, request ID, authenticated actor and void fields.
- Audit: reason and approved-user FK.

New foreign keys reference existing memberships, periods, authentication users, and distribution batches. The active membership unique index checks existing duplicates before installation. Canonical-share and equal-partner checks are `NOT VALID` for legacy data: they enforce new changes without rewriting or falsely certifying old exceptions. Pending historical issues must be reconciled before separately validating those constraints.

Money remains exact PostgreSQL `numeric`; new authoritative shares and approval totals use `numeric(14,2)`. Existing `numeric(12,2)` columns/view contracts are preserved for compatibility. Two-decimal input is required by recording RPCs. NaN/infinity are rejected by database triggers. No unexplained share imbalance or negative new office share is accepted; an exceptional subsidy arrangement needs a separate approved accounting design, rather than a hidden imbalance.

## Functions and reporting

Registration: `submit_monthly_registration`, `renew_monthly_students`, `monthly_registration_list`, `monthly_registration_summary`, and the secured existing cancellation/month-opening workflows. Registration helpers are internal; the frontend uses request-key wrappers. Bulk renewal is atomic: an invalid entry rolls back the whole batch with an error rather than leaving partial registrations.

Approvals: `adjust_monthly_fee` retains the existing form contract and writes an approved before/after record. `request_membership_adjustment` creates a pending manual request; `review_membership_adjustment` requires the current authenticated administrator, checks for stale values, and applies approved changes through the same guarded adjustment path. An approved request and its applied-change record are both retained. Manual changes after a valid settlement are blocked until the settlement is properly reversed in an open period.

Payments: `record_tuition_payment`, `record_teacher_settlement`, existing material sale/payment RPCs, documented void RPCs, and `void_expense`. Material ledger triggers derive cached totals from valid receipts. Idempotent RPCs cannot duplicate a full payment. Receipt and settlement dates are actual user-entered payment dates; dates are checked against the relevant open period.

Books only: `independent_book_summary`, `settle_book_owner`, `void_book_owner_settlement`. Payouts cannot exceed collections held for that owner. A book receipt cannot be voided while doing so would leave an already-paid owner underfunded; reverse the payout first. No institutional reporting query reads book income, commission or owner payout totals.

Partners: `partner_account_summary`, `record_partner_transaction`, `distribute_partner_profit`, `void_partner_transaction`. A distribution requires administrator approval, a closed source period, exactly three equal partners, sufficient source-month profit remaining, and a conservative lifetime reserve after teacher entitlements, valid expenses, printing costs, withdrawals and previous distributions. Capital and external book money are not profit. The total must divide into three exact two-decimal shares; no 33.33% approximation is used. Reversing a distribution reverses the entire three-row batch.

Periods/audit: `set_period_state`, `resolve_migration_review`. Internal month locks serialize close/correction operations. A shared institutional mutation lock coordinates financial changes with profit approval; book funds remain separate. All public SECURITY DEFINER functions have an explicit safe search path with `pg_temp` last; helper/trigger execution and public-schema object creation are denied to API users.

Views: existing `month_fee_overview` and `teacher_class_month_totals` now use canonical effective shares and active memberships. Class totals group once by teacher/class/month even if snapshot titles differ. New `teacher_settlement_summary` derives remaining obligation/status; `month_tuition_summary` aggregates monthly fees/discounts/collections/outstanding without truncating frontend results. Existing `class_month_report` and `office_month_summary` remain compatible with printing/dashboard components.

Reporting distinguishes billing-month entitlements, lifetime receipts on those memberships, actual cash-month receipts/payments, and funds after obligations. The dashboard's cash movement is not a certified bank balance: opening balances and bank reconciliation are not represented. Historical student/teacher display names remain current names; frozen monthly assignment and class title preserve financial identity.

## Indexes and RLS

Indexes cover student names/phone/guardian phone, active membership period/teacher, cash dates of valid tuition/settlement/material receipts, material student/class/date and status/date, adjustment membership/history, class teacher, chapter class, and expense date. Existing PK/FK/relationship indexes remain.

Every new table enables RLS. Admin/accountant can read protected financial views and use authorized payment RPCs. Registrar can read student/class details and the safe monthly list/statistics RPCs, but cannot read raw membership financial values, financial views, partner accounts or adjustments. Sensitive table inserts/updates are revoked, even where an old policy remains, so API clients must pass database validation. Ordinary users cannot change/delete audit history. Approval actors are taken from `auth.uid()`, never frontend-supplied IDs.

## Frontend integration

- `/enrollments`: safe monthly/history RPCs, paginated permanent profiles, transaction-safe new/returning registration and bulk renewal retry keys.
- `/students`: profile registration date and notes.
- Dashboard: primary monthly class-registration statistics and server-aggregated tuition summary.
- `/finance`: idempotent receipt RPC and full receipt number; administrator period review/close/reopen controls.
- `/settlements`: idempotent settlement RPC and canonical settlement summary; existing per-class/combined print links remain.
- `/adjustments`: request manual shares, approve/reject requests, inspect before/after values, historical migration-review queue and latest 100 audit events for administrators.
- `/partners`: three equal partner profiles, capital/withdrawal history, approved profit distributions and audited reversals.
- `/books`: independent owner-liability summary and payout/void workflow, alongside existing sale/payments/printing.
- `/chapters`: existing stock/sale/payment UI now benefits from ledger/period guards.
- `/expenses`: audited void action and totals excluding voids.

Manual TypeScript interfaces are updated; this project does not maintain generated Supabase types. New pages are in finance-only navigation and middleware; database permissions remain decisive.

New audit files: `supabase/migrations/004_database_integrity.sql`, `supabase/audit_readonly.sql`, `app/composables/useRequestKey.ts`, `app/components/RegistrationStatistics.vue`, `app/components/PeriodControls.vue`, `app/components/BookOwnerAccounts.vue`, `app/pages/adjustments.vue`, `app/pages/partners.vue`, `tests/database_audit.mjs`, and `DATABASE_AUDIT.md`.

Updated integration files: `app/pages/enrollments.vue`, `app/pages/students.vue`, `app/pages/index.vue`, `app/pages/finance.vue`, `app/pages/settlements.vue`, `app/pages/books.vue`, `app/pages/expenses.vue`, `app/components/OfficeSummary.vue`, `app/layouts/default.vue`, `app/middleware/auth.global.ts`, `app/types/models.ts`, `tests/materials_database.mjs`, `tests/print_browser.mjs`, and `README.md`. The separate official-logo changes are recorded in `BRANDING.md`.

## Deployment and historical reconciliation

1. Back up the target database. Run `supabase/audit_readonly.sql` and compare the schema/migration history. Test the upgrade on a restored development copy first.
2. Apply only missing migrations, in order: `001`, `002`, `003`, `004_database_integrity.sql`, `005_historical_import_staging.sql`, `006_historical_operational_posting.sql`, `007_dashboard_registration.sql`, `008_registration_proration_and_settlements.sql`, then `009_restore_dashboard_and_settlement_views.sql`. Do not rerun already applied migrations. Migrations 005–009 depend on prior schema and functions. The prior live audit found 001 applied; do not re-run it.
3. Deploy the updated frontend with the matching migrations; older clients that insert receipts directly or query membership financial data as registrar will no longer work.
4. In `/adjustments`, review legacy classification/date flags, negative/unbalanced shares, missing sale links, cached ledger discrepancies and partner configuration. A resolution note records review only; it does not fabricate/alter financial values.
5. Verify old printing costs are not also in general expenses; reconcile any duplicates through documented expense voids. Legacy chapter printing dates and student registration dates inferred from existing timestamps require review when original records differ.
6. Old book sales retain their legacy commission values but these are ignored by all institutional accounts. Old sales are not assumed collected. Verify actual receipts and owner payouts before using opening balances.
7. For a closed-month correction, an administrator reopens it with a reason, staff void/correct through the authorized workflow, then management reviews/closes again. Both the billed month and affected cash-date month must be open where relevant. No direct SQL edits are part of the ordinary workflow.
8. Re-run `npm test`, `npm run typecheck`, `npm run test:print`, and `npm run build`. No new environment variables are required.

## Test results and remaining limits

Automated PostgreSQL tests cover permanent IDs, new/returning/multiple-class registrations, retry protection, renewal, cancelled-row preservation, monthly counts, automatic 1000/500 and approved 900/600 shares, half-cent rounding, full/partial/overpayment/void receipts, separate partial teacher settlements, closed-month denial/reopening, chapter-only office revenue, book isolation, owner payouts, exact three-way distributions, and role/audit permissions. Browser tests cover actual Vue printing, book checkbox confirmation, and original-logo login/header layouts at desktop, 375px and 320px widths.

These tests use isolated PostgreSQL and browser fixtures, not live Supabase/PostgREST sessions. Multi-connection load/concurrency stress, production migration, real staff sign-in and physical printer output remain environment checks. Locking and constraints are implemented but should be load-tested on the intended PostgreSQL deployment. Existing human profiles are not merged based on shared names/phone numbers; staff must choose the existing profile rather than inventing a demographic uniqueness rule.

The original Python arithmetic test cannot run here because the installed Python launcher is inaccessible. Its principal fee/share cases are covered in PostgreSQL. No production migration was executed by this task.

## Historical workbook staging

`supabase/migrations/005_historical_import_staging.sql` adds admin-only batch and source-row storage with file checksum, sheet/row coordinates, raw row payloads, review decisions, reviewer identity, timestamps and reasons. Staging is idempotent by SHA-256; review actions are recorded in `audit_logs`. Direct client writes are revoked and the SECURITY DEFINER RPCs require an active admin profile.

`supabase/migrations/006_historical_operational_posting.sql` adds admin-only resolution, posting preview, destination mappings and a transactional posting RPC that processes at most 500 rows per call. It supports explicit student/teacher/class create-or-match decisions, verified monthly registrations, tuition receipts, approved expenses, verified book/chapter sales and their separately verified receipts, and independently verified partner capital/withdrawal transactions. Registration duplication is checked against operational records and within the batch; source-row mappings and deterministic request IDs make replay of the same staged batch idempotent. Existing period locks, receipt/stock checks, role checks and ledger RPCs remain in force. It intentionally does not import summary rows, book-owner settlements, teacher settlements, or unresolved book/chapter catalog data.

The `/imports` page locally parses `.xlsx`, previews row counts and source flags, stages source rows, and lets an administrator save a reviewed mapping. Its posting preview reports ready, matched, duplicate, review, and financial-verification counts. The **Post Approved Records to System** action requires a browser confirmation and invokes the database posting RPC; rows without supported verified mappings remain staged. Names are never matched automatically. November registrations require an explicit current-registration confirmation, and tuition/payment records require verified dates and a duplicate-source check.

The inspected `Real_Star_June-Nov_2026_Import_Review.xlsx` contains 14 worksheets and 4,221 parsed source rows (including 698 Registrations, 671 Payments, 502 Students, 1,412 ReviewFlags, and reference sheets). These are local dry-run counts only. All 502 student candidates were marked name-only and lack a final verified student ID; all November registrations were deferred as copied October rosters; and material rows were marked do-not-post. The accompanying `IMPORT_INSTRUCTIONS_DARI.md` and normalized source CSV files were not present in the supplied paths. Therefore, no live batch was staged, no operational data was imported, and workbook row totals must not be reported as accepted live records. Keep the workbook outside the Nuxt `public/` directory; its rows contain personal and financial data.

Migrations 005 and 006 and their posting behavior have been exercised against isolated PGlite fixtures after migrations 001–004. No production migration or live import was executed. Do not deploy until the live project and migration state are verified, a backup is taken, and the complete migration chain is tested on a restored staging database first.

## Monthly registration and settlement update

Migration 008 preserves the standard class tuition in `monthly_memberships.original_fee` and records the applicable billed amount in `base_fee`. Registrations dated on days 1–20 use the full standard fee; registrations after day 20 use a fixed half-month fee, rounded to two decimals. Tuition, discounts, balances, and teacher/office entitlements are calculated from the applicable fee. This rule is applied in the shared registration function, including single registrations and bulk renewals.

The shared registration form is used from the dashboard and `/enrollments`. Initial per-class payments require a positive amount plus an explicitly selected payment method and actual date; zero payments create no receipt. The database transaction creates the permanent profile, monthly memberships, and optional receipts atomically. Teacher settlements require an explicit method, retain `paid_by`, and expose an authorized history query with the recorder's staff name. The old settlement RPC signature is revoked so outdated clients cannot silently label settlements as cash.

Migration 008 is additive and has been tested locally against isolated PGlite after migrations 001–007. It has not been applied to production. Before production use, confirm the missing migration state, take and verify a restorable backup, apply missing migrations in order, and verify via the live project. Never treat this local test as evidence of live operational records.

## Missing-object repair and verification

The current frontend references `month_tuition_summary` in `app/pages/index.vue`, `teacher_settlement_summary` in `app/pages/settlements.vue`, and `historical_import_batches` plus `historical_import_source_rows` in `app/pages/imports.vue`. Their original definitions already exist in migrations 004 and 005, respectively; the import review/posting RPCs and extended source-row columns are in 005–006. The live SQL/Network inspection reports all three named objects absent, so creating duplicate placeholders would be incorrect. Apply the missing migration chain rather than hand-creating an empty table or redefining the import schema.

Migration 004 defines the tuition summary from active monthly memberships and their valid payments. Migration 008 preserves standard `original_fee`, applies `base_fee`/`discount` to the actual charge, and rebuilds the teacher/class/month totals using effective teacher entitlement and nonvoid settlements. Migration 009 (additive) recreates the two public summary views after 008: original tuition sums `original_fee`; discounts, payable, received, and outstanding sum the authoritative membership/payment view; teacher settlement balances use active memberships and nonvoid teacher settlements. Both views use `security_invoker=true` and grant SELECT to authenticated users, so underlying RLS remains effective. Migration 005 creates admin-only import batches/source rows with source provenance and RLS; migration 006 adds the review mappings, posting states, and admin-only preview/posting workflow.

For a complete import workflow, run missing migrations 002–009 in numeric order after confirming migration 001 is already present (the prior audit says it is). Migration 009 intentionally fails unless the required 004–008 views and 005 import tables exist. On the restored staging database, run `npm test`; it applies 001–009 in PGlite and checks tuition totals (original 5000, discount 600, payable 3900, received 800, outstanding 3100), teacher entitlement/settled/remaining amounts, accountant access, registrar denial, and import-table admin RLS. This is a local integration test, not a live deployment.

After the administrator applies the missing files to the live project, execute `NOTIFY pgrst, 'reload schema';` in SQL Editor. Then verify `to_regclass('public.month_tuition_summary')`, `to_regclass('public.teacher_settlement_summary')`, and `to_regclass('public.historical_import_batches')` are non-NULL. Finally, while signed in as the active administrator, reload the dashboard, settlements, and `/imports`; each corresponding REST request should return HTTP 200. No live migration has been run by this session because a verified backup and privileged deployment access were not available.
