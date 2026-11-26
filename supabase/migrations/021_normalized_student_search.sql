-- Bounded staff-only lookup; search characters are built from Unicode code points.
begin;
create or replace function public.normalize_person_search(p_text text) returns text
language sql immutable parallel safe set search_path=public,pg_temp as $$
 select regexp_replace(translate(lower(normalize(coalesce(p_text,''), NFKC)),
   chr(1610)||chr(1609)||chr(1603)||chr(1571)||chr(1573)||chr(1570)||chr(1577)||chr(1572)||chr(1574)||chr(1649)||chr(1569),
   chr(1740)||chr(1740)||chr(1705)||chr(1575)||chr(1575)||chr(1575)||chr(1607)||chr(1608)||chr(1610)||chr(1575)||chr(1575)),
   '[[:space:]'||chr(8204)||chr(1600)||chr(1611)||'-'||chr(1619)||chr(1648)||chr(1620)||chr(1621)||']+', '', 'g');
$$;
revoke all on function public.normalize_person_search(text) from public,anon,authenticated;
grant execute on function public.normalize_person_search(text) to authenticated;
create or replace function public.registration_student_search(p_query text) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_query text; v_pattern text;
begin
 if not public.staff_has_any(array['admin','registrar','accountant']) then raise exception 'Student search access required' using errcode='42501'; end if;
 v_query := public.normalize_person_search(p_query);
 if length(v_query) < 2 then return '[]'::jsonb; end if;
 v_pattern := replace(replace(replace(v_query, '!', '!!'), '%', '!%'), '_', '!_');
 return coalesce((select jsonb_agg(to_jsonb(matches)) from (
  select s.id,s.student_code,s.first_name,s.last_name,s.guardian_name,s.phone,s.guardian_phone,s.address,s.active,
    recent.year_month as last_month,recent.classes as last_classes from public.students s
  left join lateral (select b.year_month,string_agg(m.class_title_snapshot,', ') classes from public.monthly_memberships m join public.enrollments e on e.id=m.enrollment_id join public.billing_periods b on b.id=m.period_id where e.student_id=s.id and m.registration_active group by b.year_month order by b.year_month desc limit 1) recent on true
  where s.active and public.normalize_person_search(concat_ws(' ',s.first_name,s.last_name,s.student_code,s.guardian_name,s.phone,s.guardian_phone)) like '%'||v_pattern||'%' escape '!'
  order by s.first_name,s.last_name,s.id limit 30) matches),'[]'::jsonb);
end $$;
revoke all on function public.registration_student_search(text) from public,anon;
grant execute on function public.registration_student_search(text) to authenticated;
notify pgrst,'reload schema';
commit;
