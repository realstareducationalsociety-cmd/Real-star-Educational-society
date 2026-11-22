-- Read-only inventory for the TARGET database. Run before applying migrations.
-- This script does not create objects, alter data, or expose authentication secrets.
select table_name,column_name,data_type,udt_name,is_nullable,column_default,is_generated,generation_expression
from information_schema.columns where table_schema='public' order by table_name,ordinal_position;
select c.relname table_name,k.conname,pg_get_constraintdef(k.oid) definition,k.convalidated
from pg_constraint k join pg_class c on c.oid=k.conrelid join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' order by c.relname,k.conname;
select tablename,indexname,indexdef from pg_indexes where schemaname='public' order by tablename,indexname;
select c.relname table_name,c.relrowsecurity rls_enabled from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind='r' order by c.relname;
select tablename,policyname,roles,cmd,qual,with_check from pg_policies where schemaname='public' order by tablename,policyname;
select c.relname table_name,t.tgname,pg_get_triggerdef(t.oid) definition
from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and not t.tgisinternal order by c.relname,t.tgname;
select p.oid::regprocedure signature,p.prosecdef security_definer,p.proconfig,p.proacl,pg_get_functiondef(p.oid) definition
from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prokind='f'
order by p.proname;
select viewname,definition from pg_views where schemaname='public' order by viewname;
select grantee,table_name,privilege_type from information_schema.table_privileges
where table_schema='public' and grantee in ('anon','authenticated') order by table_name,grantee,privilege_type;
