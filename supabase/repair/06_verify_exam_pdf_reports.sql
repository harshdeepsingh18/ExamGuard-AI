-- Read-only inspection of PDF report schema, links, policies, and grants.

select to_regclass('public.exam_pdf_reports') is not null as table_exists;

select column_name,data_type,udt_name,is_nullable,column_default
from information_schema.columns
where table_schema='public' and table_name='exam_pdf_reports'
order by ordinal_position;

select c.conname as constraint_name,
       case c.contype when 'p' then 'primary key' when 'f' then 'foreign key' when 'c' then 'check' else c.contype::text end as constraint_type,
       pg_get_constraintdef(c.oid) as definition,c.convalidated as validated
from pg_constraint c
where c.conrelid=to_regclass('public.exam_pdf_reports')
order by c.contype,c.conname;

select indexname,indexdef
from pg_indexes
where schemaname='public' and tablename='exam_pdf_reports'
order by indexname;

select tablename,policyname,roles,cmd,qual,with_check
from pg_policies
where schemaname='public' and tablename='exam_pdf_reports'
order by policyname;

select c.relrowsecurity as rls_enabled,c.relforcerowsecurity as rls_forced
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname='exam_pdf_reports';

select source.relname as source_table,c.conname as foreign_key_name,
       target.relname as target_table,pg_get_constraintdef(c.oid) as definition
from pg_constraint c
join pg_class source on source.oid=c.conrelid
join pg_class target on target.oid=c.confrelid
where c.contype='f' and c.conrelid=to_regclass('public.exam_pdf_reports')
order by c.conname;

select table_name,grantee,privilege_type
from information_schema.role_table_grants
where table_schema='public' and table_name='exam_pdf_reports'
  and grantee in ('anon','authenticated','service_role')
order by grantee,privilege_type;

