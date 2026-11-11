-- Read-only verification for the monitoring switch and event table.
-- This file contains SELECT statements only.

select
  to_regclass('public.exams') is not null as exams_exists,
  exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'exams'
      and column_name = 'monitoring_enabled'
      and udt_name = 'bool'
      and is_nullable = 'NO'
      and replace(coalesce(column_default, ''), ' ', '') = 'false'
  ) as monitoring_enabled_matches_expected;

select
  to_regclass('public.exam_monitoring_events') is not null
    as exam_monitoring_events_exists;

select
  table_name,
  column_name,
  data_type,
  udt_name,
  is_nullable,
  column_default
from information_schema.columns
where table_schema = 'public'
  and (
    (table_name = 'exams' and column_name = 'monitoring_enabled')
    or table_name = 'exam_monitoring_events'
  )
order by table_name, ordinal_position;

select
  c.conname as constraint_name,
  case c.contype
    when 'p' then 'primary key'
    when 'f' then 'foreign key'
    when 'u' then 'unique'
    when 'c' then 'check'
    else c.contype::text
  end as constraint_type,
  pg_get_constraintdef(c.oid) as definition,
  c.convalidated as validated
from pg_constraint c
join pg_class t on t.oid = c.conrelid
join pg_namespace n on n.oid = t.relnamespace
where n.nspname = 'public'
  and t.relname = 'exam_monitoring_events'
order by c.contype, c.conname;

select
  schemaname,
  tablename,
  indexname,
  indexdef
from pg_indexes
where schemaname = 'public'
  and tablename = 'exam_monitoring_events'
order by indexname;

select
  n.nspname as schema_name,
  c.relname as table_name,
  c.relrowsecurity as rls_enabled,
  c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = 'exam_monitoring_events';

select
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd,
  qual,
  with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('exam_monitoring_events', 'exams', 'exam_attempts')
order by tablename, policyname;

select
  grantee,
  privilege_type
from information_schema.table_privileges
where table_schema = 'public'
  and table_name = 'exam_monitoring_events'
  and grantee in ('PUBLIC', 'anon', 'authenticated', 'service_role')
order by grantee, privilege_type;
