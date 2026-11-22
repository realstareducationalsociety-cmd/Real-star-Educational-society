import fs from 'node:fs'
const path='supabase/migrations/011_registration_confirmation.sql',prior=fs.readFileSync(path,'utf8'),m10=fs.readFileSync('supabase/migrations/010_manual_financial_agreements.sql','utf8'),m8=fs.readFileSync('supabase/migrations/008_registration_proration_and_settlements.sql','utf8'),m4=fs.readFileSync('supabase/migrations/004_database_integrity.sql','utf8')
function fn(src,name){const match=src.match(new RegExp('create (?:or replace )?function public\\.'+name+'\\([\\s\\S]*?end \\$\\$;','i'));if(!match)throw Error(name);return match[0].replace('create function','create or replace function')}
function view(name){const r=m10.match(new RegExp('create or replace view public\\.'+name+'[\\s\\S]*?;','i'));if(!r)throw Error(name);return r[0]}
let s=prior.slice(0,prior.indexOf('create or replace function public.register_dashboard_student')).replace("new.manual_teacher_share<>round(new.base_fee/2,2)","coalesce(new.manual_teacher_share,round(new.base_fee/2,2))<>round(new.base_fee/2,2)")
let reg=fn(m10,'register_dashboard_student')
reg=reg.replace('  if student is null then',`  if student is null then
    if coalesce((p_payload->>'duplicate_profile_confirmed')::boolean,false) is not true and exists(select 1 from students s
      where lower(trim(s.first_name))=lower(trim(p_payload->>'first_name')) and lower(trim(s.last_name))=lower(trim(coalesce(p_payload->>'last_name','')))
      and coalesce(trim(s.phone),'')=coalesce(trim(p_payload->>'phone'),'')) then raise exception 'Matching permanent profile exists; select it or explicitly confirm a different person' using errcode='P0002'; end if;`)
reg=reg.replace('is_exception := (entitlement <> std_teacher_share);',`is_exception := coalesce((item->>'custom_teacher_share')::boolean,false);
    if not is_exception and entitlement<>std_teacher_share then raise exception 'Standard recommendation does not match approved entitlement'; end if;`)
reg=reg.replace(/v_exception_reason := trim\(coalesce\(item->>'exception_reason',[^\n]+/,"v_exception_reason := trim(coalesce(item->>'teacher_share_reason',''));")
reg=reg.replace('proration_rule, registration_type','proration_rule, registration_type, teacher_share_mode, teacher_share_reason, sponsored_confirmed, start_time_snapshot, end_time_snapshot')
reg=reg.replace("then 'new' else 'returning' end","then 'new' else 'returning' end, case when is_exception then 'custom' else 'standard' end, item->>'teacher_share_reason', coalesce((item->>'sponsored_confirmed')::boolean,false), room.start_time, room.end_time")
let update=fn(m10,'update_monthly_agreement').replace('is_exception := (entitlement <> std_teacher_share);',`is_exception := coalesce((p_agreement->>'custom_teacher_share')::boolean,false);
  if not is_exception and entitlement<>std_teacher_share then raise exception 'Standard recommendation does not match approved entitlement'; end if;`)
update=update.replace(/v_exception_reason := trim\(coalesce\(p_agreement->>'exception_reason',[^\n]+/,"v_exception_reason := trim(coalesce(p_agreement->>'teacher_share_reason',''));")
update=update.replace("discount_reason = p_agreement->>'discount_reason',", "teacher_share_mode=case when is_exception then 'custom' else 'standard' end,teacher_share_reason=p_agreement->>'teacher_share_reason',sponsored_confirmed=coalesce((p_agreement->>'sponsored_confirmed')::boolean,false),\n    discount_reason = p_agreement->>'discount_reason',")
let fee=view('month_fee_overview').replace('as standard_teacher_share\n','as standard_teacher_share\n')
fee=fee.replace(/as standard_teacher_share\r?\nfrom/,`as standard_teacher_share,
 m.teacher_share_mode,m.teacher_share_reason,m.sponsored_confirmed,m.start_time_snapshot,m.end_time_snapshot,
 case when coalesce(paid.paid_total,0)>0 then 'registered'
 when m.sponsored_confirmed and m.amount_due=0 and m.discount=m.base_fee and m.base_fee>0 then 'fully_sponsored'
 else 'pending_payment' end as confirmation_status
from`)
let stats=fn(m4,'monthly_registration_summary').replace('set search_path=public as','set search_path=public,pg_temp as').replace('where b.year_month=p_month and m.registration_active',"where b.year_month=p_month and m.registration_active and exists(select 1 from month_fee_overview f where f.id=m.id and f.confirmation_status in ('registered','fully_sponsored'))")
let sums=view('month_tuition_summary').replace('count(*)::bigint as registrations',"count(*) filter(where confirmation_status in ('registered','fully_sponsored'))::bigint as registrations").replace('count(distinct student_id)::bigint',"count(distinct student_id) filter(where confirmation_status in ('registered','fully_sponsored'))::bigint").replace(/as institution_funded\r?\nfrom/,"as institution_funded, count(*) filter(where confirmation_status='pending_payment')::bigint as pending_registrations\nfrom")
let list=fn(m8,'monthly_registration_list').replace("'registration_type',m.registration_type,'base_fee'","'confirmation_status',case when not m.registration_active then 'cancelled' else (select f.confirmation_status from month_fee_overview f where f.id=m.id) end,\n      'registration_type',m.registration_type,'base_fee'")
let wrapper=fn(m10,'adjust_monthly_fee').replace("'approved', true", "'approved', true, 'custom_teacher_share', true, 'teacher_share_reason', p_reason, 'sponsored_confirmed', current_row.sponsored_confirmed")
s+=[reg,update,fee,stats,sums,list,wrapper].join('\n\n')+"\nnotify pgrst, 'reload schema';\ncommit;\n"
fs.writeFileSync(path,s)
// Move confirmation tests inside the existing isolated test lifecycle.
const test='tests/manual_agreements_database.mjs';let source=fs.readFileSync(test,'utf8');const extra=source.slice(source.indexOf("}await db.exec('reset role')")+1);source=source.slice(0,source.indexOf("}await db.exec('reset role')")+1);const pos=source.indexOf("  console.log('ALL 14");source=source.slice(0,pos)+extra+'\n'+source.slice(pos);fs.writeFileSync(test,source)
