-- Additive dashboard workflow; requires migrations 001–006.
begin;
create function public.registration_student_search(p_query text) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if not public.staff_has_any(array['admin','registrar']) then raise exception 'Registration access required'; end if;
 if length(trim(coalesce(p_query,'')))<2 then return '[]'::jsonb; end if;
 return coalesce((select jsonb_agg(to_jsonb(matches)) from (
 select s.*, recent.year_month as last_month,recent.classes as last_classes from students s
 left join lateral (select b.year_month,string_agg(m.class_title_snapshot,', ') classes
 from monthly_memberships m join enrollments e on e.id=m.enrollment_id join billing_periods b on b.id=m.period_id
 where e.student_id=s.id and m.registration_active group by b.year_month order by b.year_month desc limit 1) recent on true
 where position(regexp_replace(translate(lower(trim(p_query)),'يكى','یکی'),'[[:space:]‌]+','','g') in
 regexp_replace(translate(lower(concat_ws(' ',s.first_name,s.last_name,s.student_code,s.guardian_name,s.phone,s.guardian_phone)),'يكى','یکی'),'[[:space:]‌]+','','g'))>0
 order by s.first_name,s.last_name,s.id limit 30) matches),'[]'::jsonb);
end $$;
create function public.registration_previous(p_student uuid,p_month date) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if not public.staff_has_any(array['admin','registrar']) then raise exception 'Registration access required'; end if;
 return coalesce((select jsonb_agg(to_jsonb(f)||jsonb_build_object('year_month',b.year_month))
 from month_fee_overview f join billing_periods b on b.id=f.period_id
 where f.student_id=p_student and b.year_month=(select max(bp.year_month) from monthly_memberships m
 join enrollments e on e.id=m.enrollment_id join billing_periods bp on bp.id=m.period_id
 where e.student_id=p_student and m.registration_active and bp.year_month<p_month)),'[]'::jsonb);
end $$;
create function public.register_dashboard_student(p_payload jsonb,p_request uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare prior registration_requests%rowtype; person students%rowtype; result jsonb; item jsonb;
 student uuid; membership uuid; period uuid; total integer:=0; payment numeric; registration_date date;
begin
 if not public.staff_has_any(array['admin','registrar']) then raise exception 'Registration access required'; end if;
 if p_request is null or p_payload is null then raise exception 'Request ID and payload required'; end if;
 perform pg_advisory_xact_lock(hashtextextended('rsms-institution-ledger',0));
 perform pg_advisory_xact_lock(hashtextextended(p_request::text,0));
 select * into prior from registration_requests where id=p_request;
 if found then
 if prior.actor_id<>auth.uid() or prior.payload<>p_payload or prior.kind<>'single' then raise exception 'Request ID reused with different data'; end if;
 return prior.result; end if;
 registration_date:=(p_payload->>'date')::date;
 -- Existing migrations contain no proration formula or instructional schedule.
 if extract(day from registration_date)>20 then raise exception 'Late registration requires the confirmed institutional proration policy'; end if;
 if jsonb_typeof(p_payload->'classes') is distinct from 'array' or jsonb_array_length(p_payload->'classes')=0 then raise exception 'Select at least one class'; end if;
 student:=(p_payload->>'student_id')::uuid;
 if student is not null then
 select * into person from students where id=student for update;
 if not found then raise exception 'Student not found'; end if;
 end if;
 for item in select value from jsonb_array_elements(p_payload->'classes') loop
 result:=register_monthly_student((p_payload->>'month')::date,student,
 case when student is null then p_payload->>'first_name' else person.first_name end,
 case when student is null then p_payload->>'last_name' else person.last_name end,
 case when student is null then p_payload->>'guardian_name' else person.guardian_name end,
 case when student is null then p_payload->>'phone' else person.phone end,
 case when student is null then p_payload->>'guardian_phone' else person.guardian_phone end,
 case when student is null then p_payload->>'address' else person.address end,
 registration_date,array[(item->>'class_id')::uuid],(item->>'discount')::numeric);
 student:=(result->>'student_id')::uuid;
 select * into person from students where id=student;
 select id into period from billing_periods where year_month=(p_payload->>'month')::date;
 select m.id into membership from monthly_memberships m join enrollments e on e.id=m.enrollment_id
 where m.period_id=period and e.student_id=student and e.class_id=(item->>'class_id')::uuid and m.registration_active;
 if nullif(p_payload->>'student_id','') is null then
 update monthly_memberships set registration_type='new' where id=membership;
 update students set notes=p_payload->>'notes' where id=student;
 end if;
 payment:=coalesce((item->>'payment')::numeric,0);
 if payment<0 then raise exception 'Invalid initial payment'; end if;
 if payment>0 then
 perform record_tuition_payment(membership,payment,registration_date,'cash','Initial registration payment',gen_random_uuid());
 end if;
 total:=total+1;
 end loop;
 result:=jsonb_build_object('student_id',student,'student_code',person.student_code,'membership_count',total);
 insert into registration_requests values(p_request,auth.uid(),'single',p_payload,result,now());
 return result;
end $$;
revoke all on function public.registration_student_search(text),public.registration_previous(uuid,date),public.register_dashboard_student(jsonb,uuid) from public,anon;
grant execute on function public.registration_student_search(text),public.registration_previous(uuid,date),public.register_dashboard_student(jsonb,uuid) to authenticated;
commit;
