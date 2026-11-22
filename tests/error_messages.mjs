import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import ts from 'typescript'

const source = await readFile('app/composables/useHelpers.ts', 'utf8')
const { outputText } = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 }
})
const moduleUrl = `data:text/javascript;base64,${Buffer.from(outputText).toString('base64')}`
const { errText } = await import(moduleUrl)

assert.match(errText({ code: 'PGRST202', message: 'Could not find function public.private_name(p_secret)' }), /تابع لازم دیتابیس پیدا نشد/)
assert.doesNotMatch(errText({ code: 'PGRST202', message: 'Could not find function public.private_name(p_secret)' }), /private_name|p_secret/)
assert.match(errText({ code: 'PGRST205', message: 'Could not find table public.students in schema cache' }), /جدول یا view/)
assert.match(errText({ code: 'PGRST204', message: 'Column missing' }), /ستون لازم دیتابیس/)
assert.match(errText({ code: '42501', message: 'permission denied for table students' }), /صلاحیت ندارید/)
assert.match(errText({ status: 401, message: 'Invalid JWT' }), /دوباره وارد سیستم شوید/)
assert.match(errText({ code: '23505', message: 'duplicate key value violates unique constraint' }), /قبلاً انجام شده/)
assert.equal(errText(new Error('نام شاگرد ضروری است')), 'نام شاگرد ضروری است')
assert.match(errText(new TypeError('Failed to fetch from internal endpoint')), /Supabase/)
console.log('PASS: database errors are safe and user-friendly; local validation errors remain actionable.')
