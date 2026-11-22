# Official Real Star logo

The exact supplied image is stored at `public/branding/real-star-official.png` and served as `/branding/real-star-official.png`.

Original source: `d:/real star/file_00000000458871fa8d03acf68334fbe0.png`.

Source and copied asset SHA-256:

`30C2FC0A006F32002A4BFCF2721BDE4D2E5A7AF3BFCCA301DF6B1E945CFEE981`

The original 1024 × 1024 PNG was copied without resizing, cropping, recoloring, recompressing, redrawing or substituting another image. CSS controls its display dimensions with `object-fit: contain`, square proportions and automatic height. The bitmap has a white background, which is retained.

`app/components/OfficialLogo.vue` provides accessible alternative text and consistent login/header/sidebar/report sizes. It works independently of document text direction. The login form is centered and responsive; institution and system names are included, and the existing Supabase sign-in method and error handling remain in use. The header logo stays visible on mobile. Sidebar and printed reports/tuition receipts also use the exact asset.

Files: the asset, `OfficialLogo.vue`, `app/pages/login.vue`, `app/layouts/default.vue`, `app/components/PrintReport.vue`, `app/pages/finance.vue`, `app/assets/css/main.css`, and browser regression tests in `tests/print_browser.mjs`.

Verified checksum equality, desktop and 375px/320px mobile rendering, intrinsic dimensions/proportions, no horizontal page overflow, and invocation of the existing sign-in action. Screenshots are generated under ignored `.test-artifacts/`. Browser authentication tests use a test stub; no real credentials are submitted.

This integration does not implement the later complete interface redesign or a full bilingual language system; those await the user's next instructions. No AI-generated logo or replacement mark was used.
