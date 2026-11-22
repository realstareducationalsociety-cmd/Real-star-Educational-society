import type { SupabaseClient } from '@supabase/supabase-js'
export const useSupabase = () => useNuxtApp().$supabase as SupabaseClient | null
