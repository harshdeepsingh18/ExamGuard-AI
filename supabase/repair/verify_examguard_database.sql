-- Read-only preflight and post-repair verification. Run in Supabase SQL Editor.

-- 1) Inspect the existing profiles definition without changing it.
select column_name, data_type, udt_name, is_nullable, column_default
from information_schema.columns
where table_schema='public' and table_name='profiles'
order by ordinal_position;

select c.conname, c.contype, pg_get_constraintdef(c.oid) as definition
from pg_constraint c
where c.conrelid='public.profiles'::regclass
order by c.contype, c.conname;

select count(*) as profiles_preserved from public.profiles;
select role, teacher_status, count(*)
from public.profiles
group by role, teacher_status
order by role, teacher_status;

-- 2) Required application tables and their presence.
select required.table_name, to_regclass('public.' || required.table_name) is not null as exists
from (values
  ('profiles'),('teacher_requests'),('exams'),('questions'),('exam_attempts'),
  ('student_answers'),('results'),('notifications'),('platform_settings')
) as required(table_name)
order by required.table_name;

-- 3) Foreign keys and delete actions.
select src.relname as table_name, c.conname,
       pg_get_constraintdef(c.oid) as definition,
       c.convalidated as validated
from pg_constraint c
join pg_class src on src.oid=c.conrelid
join pg_namespace n on n.oid=src.relnamespace
where n.nspname='public' and c.contype='f'
  and src.relname in ('profiles','teacher_requests','exams','questions','exam_attempts',
    'student_answers','results','notifications')
order by src.relname,c.conname;

-- 4) App indexes, including unique keys needed by ON CONFLICT.
select schemaname, tablename, indexname, indexdef
from pg_indexes
where schemaname='public' and tablename in (
  'teacher_requests','exams','questions','exam_attempts','student_answers',
  'results','notifications'
)
order by tablename,indexname;

-- 5) RLS and policies. Review any policy beyond the known ExamGuard set before repair.
select n.nspname as schema_name, c.relname as table_name, c.relrowsecurity as rls_enabled,
       c.relforcerowsecurity as rls_forced
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in (
  'profiles','teacher_requests','exams','questions','exam_attempts',
  'student_answers','results','notifications','platform_settings'
)
order by c.relname;

select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where schemaname='public' and tablename in (
  'profiles','teacher_requests','exams','questions','exam_attempts',
  'student_answers','results','notifications','platform_settings'
)
order by tablename,policyname;

-- 6) Auth/profile triggers and repair RPCs.
select n.nspname as schema_name, c.relname as table_name, t.tgname,
       p.proname as function_name, pg_get_triggerdef(t.oid) as definition
from pg_trigger t
join pg_class c on c.oid=t.tgrelid
join pg_namespace n on n.oid=c.relnamespace
join pg_proc p on p.oid=t.tgfoid
where not t.tgisinternal
  and ((n.nspname='auth' and c.relname='users')
    or (n.nspname='public' and c.relname='profiles'))
order by schema_name,table_name,t.tgname;

select routine_name, routine_type, security_type
from information_schema.routines
where specific_schema='public' and routine_name in (
  'current_role','is_admin','is_approved_teacher','handle_new_user',
  'protect_profile_role','start_exam','save_exam_answers','submit_exam','review_teacher'
)
order by routine_name;

-- 7) Check that existing profiles link to auth.users. This is read-only.
select count(*) as profiles_without_auth_user
from public.profiles p
left join auth.users u on u.id=p.id
where u.id is null;

select count(*) as auth_users_without_profile
from auth.users u
left join public.profiles p on p.id=u.id
where p.id is null;
