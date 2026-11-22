export const money = (n: number | string | null | undefined) => `\u2066PKR ${Number(n || 0).toLocaleString('en-US', { maximumFractionDigits: 2 })}\u2069`
export const todayKarachi = () => {
  const parts = new Intl.DateTimeFormat('en-US', { timeZone: 'Asia/Karachi', year:'numeric', month:'2-digit', day:'2-digit' }).formatToParts(new Date())
  const part = (name: string) => parts.find(p => p.type === name)?.value || ''
  return `${part('year')}-${part('month')}-${part('day')}`
}
export const nowMonth = () => todayKarachi().slice(0,7)
export const monthStart = (m: string) => `${m}-01`
type SupabaseError = {
  code?: string
  status?: number
  message?: string
  details?: string | null
  hint?: string | null
}

const genericDatabaseError = 'در دریافت یا ثبت معلومات از دیتابیس مشکل پیش آمده است. لطفاً دوباره کوشش کنید یا با مسئول سیستم تماس بگیرید.'
const permissionError = 'برای انجام این عملیات صلاحیت ندارید. با مدیر سیستم تماس بگیرید.'
const missingFunctionError = 'تابع لازم دیتابیس پیدا نشد یا امضای آن یکسان نیست. نصب migration مربوط و همگام‌سازی schema در Supabase بررسی شود.'
const missingRelationError = 'جدول یا view لازم دیتابیس پیدا نشد. migrationهای مربوط در پروژه Supabase بررسی شوند.'
const missingColumnError = 'ستون لازم دیتابیس پیدا نشد. نسخهٔ migration و schema برنامه بررسی شوند.'

export const errText = (error: unknown): string => {
  if (error instanceof Error && !('code' in error) && !('status' in error)) {
    if (error.name === 'TypeError') return 'به نشانی Supabase وصل نشد. اتصال شبکه و Project URL تنظیم‌شده بررسی شوند.'
    return error.message || 'عملیات موفق نشد. دوباره کوشش کنید.'
  }

  const dbError = error as SupabaseError | null
  const code = dbError?.code || ''
  const status = dbError?.status
  const message = dbError?.message || ''
  const loweredMessage = message.toLowerCase()

  if (import.meta.dev && error) {
    console.error('[RSMS database/auth error]', {
      code: code || undefined,
      status,
      message: message || undefined,
      details: dbError?.details || undefined,
      hint: dbError?.hint || undefined
    })
  }

  if (code === 'invalid_credentials' || code === 'email_not_confirmed' || (status === 400 && !code)) {
    return 'ایمیل یا رمز عبور درست نیست.'
  }
  if (status === 429) return 'تلاش‌های ورود زیاد بوده است؛ کمی بعد دوباره کوشش کنید.'
  if (code === '42501' || status === 403) return permissionError
  if (status === 401 || code === 'PGRST301' || /jwt.*(expired|invalid)|unauthenticated/.test(loweredMessage)) {
    return 'ورود کاربر معتبر نیست یا پایان یافته است. دوباره وارد سیستم شوید و تنظیمات آدرس/کلید عمومی Supabase را بررسی کنید.'
  }
  if (code === '23505') return 'این ثبت قبلاً انجام شده است و تکرار آن مجاز نیست.'
  if (code === '23503') return 'یکی از موارد وابسته پیدا نشد یا قبلاً تغییر کرده است.'
  if (code === '23514' || code === '22P02') return 'یکی از مقدارهای واردشده معتبر نیست؛ معلومات را بررسی کنید.'
  if (code === 'PGRST202') return missingFunctionError
  if (code === 'PGRST204') return missingColumnError
  if (code === 'PGRST205') return missingRelationError
  if (code === 'PGRST206') return 'رابطهٔ لازم در schema دیتابیس پیدا نشد. migrationها و روابط جدول‌ها بررسی شوند.'
  if (code === 'P0001' && /صلاحیت|اجازه ندارید|access required|administrator approval/i.test(message)) {
    return permissionError
  }
  if (code) return genericDatabaseError
  if (status) return genericDatabaseError
  return message || genericDatabaseError
}
export const timeShort = (value: string | null) => value ? value.slice(0,5) : '—'
export const isValidMonth = (value: string) => /^\d{4}-(0[1-9]|1[0-2])$/.test(value)
