-- Read-only verification for public.ai_question_drafts.
-- Run after the migration or standalone repair.

select
  to_regclass('public.ai_question_drafts') is not null
    as ai_question_drafts_exists;

select
  column_name,
  data_type,
  udt_name,
  is_nullable,
  column_default
from information_schema.columns
where table_schema = 'public'
  and table_name = 'ai_question_drafts'
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
  and t.relname = 'ai_question_drafts'
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
  and tablename = 'ai_question_drafts'
order by policyname;

select
  n.nspname as schema_name,
  c.relname as table_name,
  c.relrowsecurity as rls_enabled,
  c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = 'ai_question_drafts';

select
  grantee,
  privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name = 'ai_question_drafts'
  and grantee in ('anon', 'authenticated', 'service_role')
order by grantee, privilege_type;

select
  status,
  count(*) as draft_count
from public.ai_question_drafts
group by status
order by status;

select
  count(*) filter (
    where status not in ('needs_review', 'approved', 'discarded')
  ) as invalid_status_count
from public.ai_question_drafts;
