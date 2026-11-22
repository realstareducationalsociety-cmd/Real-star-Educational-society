import fs from 'node:fs'
const m10=fs.readFileSync('supabase/migrations/010_manual_financial_agreements.sql','utf8'),m4=fs.readFileSync('supabase/migrations/004_database_integrity.sql','utf8')
let s=`-- Confirmation states are derived from real receipts; no historical DML.
begin;
alter table public.monthly_memberships
 add column teacher_share_mode text check(teacher_share_mode in ('standard','custom')),
 add column teacher_share_reason text,
 add column sponsored_confirmed boolean not null default false,
 add column start_time_snapshot time,
 add column end_time_snapshot time;
create function public.guard_entitlement_confirmation() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if tg_op='INSERT' or (new.agreement_approved_at,new.manual_teacher_share,new.base_fee,new.teacher_share_mode,new.teacher_share_reason,new.sponsored_confirmed)
 is distinct from (old.agreement_approved_at,old.manual_teacher_share,old.base_fee,old.teacher_share_mode,old.teacher_share_reason,old.sponsored_confirmed) then
 if not staff_has_any(array['admin']) then raise exception 'Administrator approval required' using errcode='42501'; end if;
 if new.teacher_share_mode is null or (new.teacher_share_mode='standard' and new.manual_teacher_share<>round(new.base_fee/2,2))
 or (new.teacher_share_mode='custom' and length(trim(coalesce(new.teacher_share_reason,'')))<4) then raise exception 'Approve the standard recommendation or provide a custom entitlement reason'; end if;
 if new.sponsored_confirmed and (new.base_fee<=0 or new.discount<>new.base_fee) then raise exception 'Sponsorship confirmation requires a full discount'; end if;
 end if;
 return new;
end $$;
create trigger entitlement_confirmation_guard before insert or update on public.monthly_memberships for each row execute function public.guard_entitlement_confirmation();
revoke all on function public.guard_entitlement_confirmation() from public,anon,authenticated;
`
let reg=m10.slice(m10.indexOf('create or replace function public.register_dashboard_student'),m10.indexOf('create function public.update_monthly_agreement'))
reg=reg.replace("if student is null then\n  if length",`if student is null then
  if coalesce((p_payload->>'duplicate_profile_confirmed')::boolean,false) is not true and exists(select 1 from students s
   where lower(trim(s.first_name))=lower(trim(p_payload->>'first_name')) and lower(trim(s.last_name))=lower(trim(coalesce(p_payload->>'last_name','')))
   and coalesce(trim(s.phone),'')=coalesce(trim(p_payload->>'phone'),'')) then raise exception 'Matching permanent profile exists; select it or explicitly confirm a different person' using errcode='P0002'; end if;
  if length`)
reg=reg.replace('discount_reason,notes,proration_rule,registration_type)','discount_reason,notes,proration_rule,registration_type,teacher_share_mode,teacher_share_reason,sponsored_confirmed,start_time_snapshot,end_time_snapshot)')
reg=reg.replace("then 'new' else 'returning' end) returning id", "then 'new' else 'returning' end,case when (item->>'custom_teacher_share')::boolean is true then 'custom' else 'standard' end,item->>'teacher_share_reason',coalesce((item->>'sponsored_confirmed')::boolean,false),room.start_time,room.end_time) returning id")
s+=reg
let update=m10.slice(m10.indexOf('create function public.update_monthly_agreement'),m10.indexOf('-- Compatibility'))
update=update.replace('create function','create or replace function').replace("discount_reason=p_agreement->>'discount_reason',notes=", "teacher_share_mode=case when (p_agreement->>'custom_teacher_share')::boolean is true then 'custom' else 'standard' end,teacher_share_reason=p_agreement->>'teacher_share_reason',sponsored_confirmed=coalesce((p_agreement->>'sponsored_confirmed')::boolean,false),\n discount_reason=p_agreement->>'discount_reason',notes=")
s+=update
let view=m10.slice(m10.indexOf('create or replace view public.month_fee_overview'),m10.indexOf('create or replace view public.teacher_class_month_totals'))
view=view.replace('(m.amount_due=0 and m.discount>0) as scholarship',`(m.amount_due=0 and m.discount>0) as scholarship,
 m.teacher_share_mode,m.teacher_share_reason,m.sponsored_confirmed,m.start_time_snapshot,m.end_time_snapshot,
 case when coalesce(paid.paid_total,0)>0 then 'registered'
 when m.sponsored_confirmed and m.amount_due=0 and m.discount=m.base_fee and m.base_fee>0 then 'fully_sponsored'
 else 'pending_payment' end as confirmation_status`)
s+=view
let stats=m4.slice(m4.indexOf('create function public.monthly_registration_summary'),m4.indexOf('create function public.request_membership_adjustment'))
stats=stats.replace('create function','create or replace function').replace('set search_path=public as','set search_path=public,pg_temp as').replace('where b.year_month=p_month and m.registration_active',"where b.year_month=p_month and m.registration_active and exists(select 1 from month_fee_overview f where f.id=m.id and f.confirmation_status in ('registered','fully_sponsored'))")
s+=stats
let sums=m10.slice(m10.indexOf('create or replace view public.month_tuition_summary'),m10.indexOf('create or replace view public.teacher_settlement_summary'))
sums=sums.replace('count(*)::bigint as registrations',"count(*) filter(where confirmation_status in ('registered','fully_sponsored'))::bigint as registrations").replace('count(distinct student_id)::bigint',"count(distinct student_id) filter(where confirmation_status in ('registered','fully_sponsored'))::bigint").replace('as institution_funded\nfrom',"as institution_funded, count(*) filter(where confirmation_status='pending_payment')::bigint as pending_registrations\nfrom")
s+=sums+`notify pgrst, 'reload schema';
commit;
`
fs.writeFileSync('supabase/migrations/011_registration_confirmation.sql',s)
