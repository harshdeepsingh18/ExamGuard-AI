-- Read-only verification for public.exam_monitoring_events.
-- Run after migration 202611110002 or repair 08_create_exam_monitoring_events.sql.

select
  to_regclass('public.exam_monitoring_events') is not null
    as exam_monitoring_events_exists;

select
  column_name,
  data_type,
  udt_name,
  is_nullable,
  column_default
from information_schema.columns
where table_schema = 'public'
  and table_name = 'exam_monitoring_events'
order by ordinal_position;

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
  policyname,
  permissive,
  roles,
  cmd,
  qual,
  with_check
from pg_policies
where schemaname = 'public'
  and tablename = 'exam_monitoring_events'
order by policyname;

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
  grantee,
  privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name = 'exam_monitoring_events'
  and grantee in ('anon', 'authenticated', 'service_role')
order by grantee, privilege_type;

select
  event_type,
  count(*) as event_count
from public.exam_monitoring_events
group by event_type
order by event_type;

select
  count(*) filter (
    where event_type not in (
      'tab_hidden',
      'window_blur',
      'camera_started',
      'camera_stopped',
      'face_absent',
      'multiple_people',
      'camera_unsupported',
      'camera_denied'
    )
  ) as invalid_event_type_count
from public.exam_monitoring_events;
