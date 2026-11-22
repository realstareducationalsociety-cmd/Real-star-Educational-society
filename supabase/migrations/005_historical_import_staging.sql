begin;

create table public.historical_import_batches (
  id uuid primary key default gen_random_uuid(),
  source_filename text not null check(length(trim(source_filename)) between 1 and 255),
  source_sha256 text not null unique check(source_sha256 ~ '^[0-9a-f]{64}$'),
  row_count integer not null check(row_count > 0),
  status text not null default 'staged' check(status in ('staged','reviewing','archived')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table public.historical_import_source_rows (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.historical_import_batches(id),
  source_key text not null check(length(trim(source_key)) between 1 and 300),
  source_sheet text not null check(length(trim(source_sheet)) between 1 and 80),
  source_row integer not null check(source_row > 0),
  source_payload jsonb not null check(jsonb_typeof(source_payload)='object'),
  review_status text not null default 'pending'
    check(review_status in ('pending','accepted','rejected','needs_review')),
  destination_table text,
  destination_id uuid,
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  review_reason text,
  created_at timestamptz not null default now(),
  unique(batch_id,source_key),
  unique(batch_id,source_sheet,source_row)
);

alter table public.historical_import_batches enable row level security;
alter table public.historical_import_source_rows enable row level security;
create policy historical_import_batches_admin_read on public.historical_import_batches
  for select to authenticated using(public.staff_has_any(array['admin']));
create policy historical_import_rows_admin_read on public.historical_import_source_rows
  for select to authenticated using(public.staff_has_any(array['admin']));
revoke all on public.historical_import_batches,public.historical_import_source_rows from public,anon,authenticated;
grant select on public.historical_import_batches,public.historical_import_source_rows to authenticated;

create function public.stage_historical_import(
  p_filename text,
  p_sha256 text,
  p_rows jsonb
) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  batch_id uuid;
  row_total integer;
begin
  if not public.staff_has_any(array['admin']) then raise exception 'Administrator approval required'; end if;
  if length(trim(coalesce(p_filename,''))) not between 1 and 255
     or p_filename ~ '[/\\]' then raise exception 'Invalid source filename'; end if;
  if coalesce(p_sha256,'') !~ '^[0-9a-f]{64}$' then raise exception 'Invalid source checksum'; end if;
  if coalesce(jsonb_typeof(p_rows),'')<>'array' then raise exception 'Source rows must be an array'; end if;
  row_total:=jsonb_array_length(p_rows);
  if row_total<1 or row_total>6000 or pg_column_size(p_rows)>8000000 then
    raise exception 'Import workbook exceeds staging limits';
  end if;
  if exists(
    select 1 from jsonb_array_elements(p_rows) e
    where jsonb_typeof(e)<>'object'
       or coalesce(trim(e->>'source_key'),'')=''
       or length(e->>'source_key')>300
       or coalesce(trim(e->>'source_sheet'),'')=''
       or length(e->>'source_sheet')>80
       or coalesce((e->>'source_row')::integer,0)<1
       or jsonb_typeof(e->'payload')<>'object'
  ) then raise exception 'Invalid source row or provenance'; end if;
  if exists(
    select 1 from jsonb_array_elements(p_rows) e
    group by e->>'source_key' having count(*)>1
  ) then raise exception 'Duplicate source keys in import batch'; end if;

  insert into public.historical_import_batches(source_filename,source_sha256,row_count,created_by)
  values(p_filename,p_sha256,row_total,auth.uid())
  on conflict(source_sha256) do nothing
  returning id into batch_id;

  if batch_id is null then
    select id into batch_id from public.historical_import_batches where source_sha256=p_sha256;
    return jsonb_build_object('batch_id',batch_id,'already_staged',true);
  end if;

  insert into public.historical_import_source_rows(batch_id,source_key,source_sheet,source_row,source_payload)
  select batch_id,e->>'source_key',e->>'source_sheet',(e->>'source_row')::integer,e->'payload'
  from jsonb_array_elements(p_rows) e;

  insert into public.audit_logs(table_name,action,row_id,actor_id,new_data,reason)
  values('historical_import_batches','STAGE',batch_id::text,auth.uid(),
    jsonb_build_object('source_filename',p_filename,'source_sha256',p_sha256,'row_count',row_total),
    'Staged for review; no operational records were created');
  return jsonb_build_object('batch_id',batch_id,'already_staged',false,'row_count',row_total);
end $$;

create function public.review_historical_import_row(
  p_row_id uuid,
  p_decision text,
  p_reason text
) returns void
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  source_row public.historical_import_source_rows%rowtype;
begin
  if not public.staff_has_any(array['admin']) then raise exception 'Administrator approval required'; end if;
  if p_decision not in ('accepted','rejected','needs_review') then raise exception 'Invalid review decision'; end if;
  if length(trim(coalesce(p_reason,'')))<4 then raise exception 'Review reason required'; end if;
  select * into source_row from public.historical_import_source_rows where id=p_row_id for update;
  if not found then raise exception 'Import source row not found'; end if;
  update public.historical_import_source_rows
    set review_status=p_decision,reviewed_by=auth.uid(),reviewed_at=now(),review_reason=trim(p_reason)
    where id=p_row_id;
  update public.historical_import_batches set status='reviewing' where id=source_row.batch_id;
  insert into public.audit_logs(table_name,action,row_id,actor_id,old_data,new_data,reason)
  values('historical_import_source_rows','REVIEW',p_row_id::text,auth.uid(),
    jsonb_build_object('batch_id',source_row.batch_id,'source_key',source_row.source_key,'review_status',source_row.review_status),
    jsonb_build_object('review_status',p_decision),trim(p_reason));
end $$;

revoke all on function public.stage_historical_import(text,text,jsonb),
  public.review_historical_import_row(uuid,text,text) from public,anon,authenticated;
grant execute on function public.stage_historical_import(text,text,jsonb),
  public.review_historical_import_row(uuid,text,text) to authenticated;

commit;
