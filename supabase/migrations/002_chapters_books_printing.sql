-- Apply after 001. Legacy sales are NOT assumed paid. Reconcile against receipts.
begin;
alter table public.books add column description text, add column active boolean not null default true;
alter table public.chapters add column class_id uuid references public.class_rooms(id),
 add column active boolean not null default true,
 add column printing_cost_on date not null default ((now() at time zone 'Asia/Karachi')::date);
update public.chapters set printing_cost_on=created_at::date;

-- A shared ledger references exactly one existing sale; book money is never office money.
alter table public.book_sales add column student_id uuid references public.students(id),
 add column class_id uuid references public.class_rooms(id), add column request_id uuid unique,
 add column created_by uuid references auth.users(id),
 add column paid_total numeric(12,2) not null default 0 check(paid_total>=0 and paid_total<=quantity*unit_price),
 add column payment_status text generated always as (case when paid_total=quantity*unit_price then 'paid' when paid_total>0 then 'partial' else 'unpaid' end) stored;
alter table public.chapter_sales add column student_id uuid references public.students(id),
 add column class_id uuid references public.class_rooms(id), add column request_id uuid unique,
 add column created_by uuid references auth.users(id),
 add column paid_total numeric(12,2) not null default 0 check(paid_total>=0 and paid_total<=quantity*unit_price),
 add column payment_status text generated always as (case when paid_total=quantity*unit_price then 'paid' when paid_total>0 then 'partial' else 'unpaid' end) stored;
create table public.material_payments(
 id uuid primary key default gen_random_uuid(),
 book_sale_id uuid references public.book_sales(id), chapter_sale_id uuid references public.chapter_sales(id),
 amount numeric(12,2) not null check(amount>0), paid_on date not null,
 request_id uuid not null unique, received_by uuid references auth.users(id),
 created_at timestamptz not null default now(), voided_at timestamptz, void_reason text,
 voided_by uuid references auth.users(id), check(num_nonnulls(book_sale_id,chapter_sale_id)=1)
);
create index on public.material_payments(book_sale_id);
create index on public.material_payments(chapter_sale_id);
alter table public.material_payments enable row level security;
create policy finance_read on public.material_payments for select to authenticated using(public.staff_has_any(array['admin','accountant']));
revoke all on public.material_payments from anon,authenticated;
grant select on public.material_payments to authenticated;
revoke insert on public.book_sales,public.chapter_sales from authenticated;
create trigger audit_material_payments after insert or update on public.material_payments for each row execute function public.audit_record();
create trigger audit_books after insert or update on public.books for each row execute function public.audit_record();
create trigger audit_chapters after insert or update on public.chapters for each row execute function public.audit_record();

create function public.freeze_enrollment_identity() returns trigger language plpgsql as $$
begin
 if new.student_id<>old.student_id or new.class_id<>old.class_id then raise exception 'Create a new enrollment; historical identity cannot change'; end if;
 return new;
end $$;
create trigger freeze_enrollment_identity before update on public.enrollments for each row execute function public.freeze_enrollment_identity();

create function public.guard_material_stock() returns trigger language plpgsql security definer set search_path=public as $$
declare used integer;
begin
 if tg_table_name='books' then
 select coalesce(sum(quantity),0) into used from public.book_sales where book_id=new.id;
 if new.opening_stock<used then raise exception 'Stock is below copies sold'; end if;
 else
 select coalesce(sum(quantity),0) into used from public.chapter_sales where chapter_id=new.id;
 if new.produced_quantity<used then raise exception 'Stock is below copies sold'; end if;
 end if;
 return new;
end $$;
create trigger guard_book_stock before update on public.books for each row execute function public.guard_material_stock();
create trigger guard_chapter_stock before update on public.chapters for each row execute function public.guard_material_stock();

create function public.pay_material(p_kind text,p_sale uuid,p_amount numeric,p_date date,p_request uuid,p_complete boolean default false)
returns void language plpgsql security definer set search_path=public as $$
declare sale record; value numeric;
begin
 if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
 if p_kind not in ('book','chapter') or p_kind is null then raise exception 'Invalid material'; end if;
 execute format('select * from public.%I where id=$1 for update',p_kind||'_sales') into sale using p_sale;
 if sale.id is null then raise exception 'Sale not found'; end if;
 if exists(select 1 from public.material_payments where request_id=p_request) then return; end if;
 value:=case when p_complete then sale.quantity*sale.unit_price-sale.paid_total else p_amount end;
 if p_complete and value=0 then return; end if;
 if value is null or value<=0 or value<>round(value,2) or value+sale.paid_total>sale.quantity*sale.unit_price or p_date is null or p_request is null then raise exception 'Invalid payment or overpayment'; end if;
 insert into public.material_payments(book_sale_id,chapter_sale_id,amount,paid_on,request_id,received_by)
 values(case when p_kind='book' then p_sale end,case when p_kind='chapter' then p_sale end,value,p_date,p_request,auth.uid());
 execute format('update public.%I set paid_total=paid_total+$1 where id=$2',p_kind||'_sales') using value,p_sale;
end $$;

create function public.sell_material(p_kind text,p_item uuid,p_student uuid,p_class uuid,p_price numeric,p_paid numeric,p_date date,p_request uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare item record; result uuid; used integer; stock integer;
begin
 if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
 if p_kind not in ('book','chapter') or p_kind is null then raise exception 'Invalid material'; end if;
 execute format('select * from public.%I where id=$1 for update',p_kind||'s') into item using p_item;
 if item.id is null or not item.active then raise exception 'Material unavailable'; end if;
 execute format('select id from public.%I where request_id=$1',p_kind||'_sales') into result using p_request;
 if result is not null then return result; end if;
 if p_student is null or p_class is null or p_request is null or p_date is null or p_price is null or p_paid is null or p_price<0 or p_paid<0 or p_paid>p_price or p_price<>round(p_price,2) or p_paid<>round(p_paid,2) then raise exception 'Invalid sale'; end if;
 if p_kind='chapter' then
 if item.class_id is distinct from p_class then raise exception 'Chapter belongs to another class'; end if;
 stock:=item.produced_quantity;
 else stock:=item.opening_stock; end if;
 execute format('select coalesce(sum(quantity),0) from public.%I where %I=$1',p_kind||'_sales',p_kind||'_id') into used using p_item;
 if used>=stock then raise exception 'No copies available'; end if;
 if p_kind='book' then
 insert into public.book_sales(book_id,quantity,unit_price,unit_commission,student_id,class_id,sold_on,request_id,created_by)
 values(p_item,1,p_price,0,p_student,p_class,p_date,p_request,auth.uid()) returning id into result;
 else
 insert into public.chapter_sales(chapter_id,quantity,unit_price,student_id,class_id,sold_on,request_id,created_by)
 values(p_item,1,p_price,p_student,p_class,p_date,p_request,auth.uid()) returning id into result;
 end if;
 if p_paid>0 then perform public.pay_material(p_kind,result,p_paid,p_date,p_request); end if;
 return result;
end $$;

create function public.void_material_payment(p_id uuid,p_reason text) returns void language plpgsql security definer set search_path=public as $$
declare receipt public.material_payments%rowtype; kind text; sale uuid;
begin
 if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
 if length(trim(coalesce(p_reason,'')))<4 then raise exception 'A correction reason is required'; end if;
 select * into receipt from public.material_payments where id=p_id;
 if not found then raise exception 'Payment not found'; end if;
 kind:=case when receipt.book_sale_id is not null then 'book' else 'chapter' end;
 sale:=coalesce(receipt.book_sale_id,receipt.chapter_sale_id);
 execute format('select id from public.%I where id=$1 for update',kind||'_sales') using sale;
 select * into receipt from public.material_payments where id=p_id for update;
 if receipt.voided_at is not null then raise exception 'Already voided'; end if;
 update public.material_payments set voided_at=now(),void_reason=p_reason,voided_by=auth.uid() where id=p_id;
 execute format('update public.%I set paid_total=paid_total-$1 where id=$2',kind||'_sales') using receipt.amount,sale;
end $$;

create view public.book_sale_overview with(security_invoker=true) as
select s.*,(select max(p.paid_on) from public.material_payments p where p.book_sale_id=s.id and p.voided_at is null) last_paid_on,i.title,concat_ws(' ',st.first_name,st.last_name) student_name,st.student_code,c.title class_name,
 (s.quantity*s.unit_price)::numeric(12,2) total_price,(s.quantity*s.unit_price-s.paid_total)::numeric(12,2) balance_due
from public.book_sales s join public.books i on i.id=s.book_id
left join public.students st on st.id=s.student_id left join public.class_rooms c on c.id=s.class_id;
create view public.chapter_sale_overview with(security_invoker=true) as
select s.*,(select max(p.paid_on) from public.material_payments p where p.chapter_sale_id=s.id and p.voided_at is null) last_paid_on,i.title,concat_ws(' ',st.first_name,st.last_name) student_name,st.student_code,c.title class_name,
 (s.quantity*s.unit_price)::numeric(12,2) total_price,(s.quantity*s.unit_price-s.paid_total)::numeric(12,2) balance_due
from public.chapter_sales s join public.chapters i on i.id=s.chapter_id
left join public.students st on st.id=s.student_id left join public.class_rooms c on c.id=s.class_id;
grant select on public.book_sale_overview,public.chapter_sale_overview to authenticated;

create function public.class_month_report(p_month date,p_class uuid default null,p_teacher uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare period uuid;
begin
 if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
 select id into period from public.billing_periods where year_month=p_month;
 return jsonb_build_object(
 'rows',coalesce((select jsonb_agg(f order by f.class_name,f.student_name) from public.month_fee_overview f where f.period_id=period and (p_class is null or f.class_id=p_class) and (p_teacher is null or f.teacher_id=p_teacher)),'[]'::jsonb),
 'settlements',coalesce((select jsonb_agg(s order by s.paid_on) from public.teacher_settlements s where s.period_id=period and (p_class is null or s.class_id=p_class) and (p_teacher is null or s.teacher_id=p_teacher)),'[]'::jsonb));
end $$;

-- Actual collection dates; chapter costs are recorded here only, not duplicated in expenses.
create function public.office_month_summary(p_month date) returns jsonb language plpgsql security definer set search_path=public as $$
declare finish date:=(p_month+interval '1 month')::date; tuition numeric; chapters numeric; printing numeric; costs numeric; entitlement numeric; settled numeric; outstanding numeric;
begin
 if not public.staff_has_any(array['admin','accountant']) then raise exception 'Financial access required'; end if;
 select coalesce(sum(amount),0) into tuition from public.payments where voided_at is null and paid_on>=p_month and paid_on<finish;
 select coalesce(sum(amount),0) into chapters from public.material_payments where chapter_sale_id is not null and voided_at is null and paid_on>=p_month and paid_on<finish;
 select coalesce(sum(total_print_cost),0) into printing from public.chapters where printing_cost_on>=p_month and printing_cost_on<finish;
 select coalesce(sum(amount),0) into costs from public.expenses where spent_on>=p_month and spent_on<finish;
 select coalesce(sum(m.teacher_entitlement),0) into entitlement from public.monthly_memberships m join public.billing_periods b on b.id=m.period_id where b.year_month=p_month;
 select coalesce(sum(amount),0) into settled from public.teacher_settlements where voided_at is null and paid_on>=p_month and paid_on<finish;
 select coalesce(sum(quantity*unit_price-paid_total),0) into outstanding from public.chapter_sales;
 return jsonb_build_object('tuition_collected',tuition,'chapter_collected',chapters,'chapter_outstanding',outstanding,'chapter_printing',printing,'chapter_net',chapters-printing,'gross_collected',tuition+chapters,'teacher_entitlement',entitlement,'teacher_paid',settled,'expenses',costs,'net_after_entitlement',tuition+chapters-entitlement-printing-costs,'cash_after_payments',tuition+chapters-settled-printing-costs);
end $$;
revoke all on function public.pay_material(text,uuid,numeric,date,uuid,boolean),public.sell_material(text,uuid,uuid,uuid,numeric,numeric,date,uuid),public.void_material_payment(uuid,text),public.class_month_report(date,uuid,uuid),public.office_month_summary(date) from public,anon;
grant execute on function public.pay_material(text,uuid,numeric,date,uuid,boolean),public.sell_material(text,uuid,uuid,uuid,numeric,numeric,date,uuid),public.void_material_payment(uuid,text),public.class_month_report(date,uuid,uuid),public.office_month_summary(date) to authenticated;
commit;
