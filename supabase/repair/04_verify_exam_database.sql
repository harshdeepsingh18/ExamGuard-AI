-- ExamGuard AI repair, step 4 of 4: read-only verification.
-- This file contains SELECT statements only. Run after steps 1 through 3.

select required.table_name,
       to_regclass('public.' || required.table_name) is not null as exists
from (values ('profiles'),('teacher_requests'),('exams'),('questions'),
             ('exam_attempts'),('student_answers'),('results'),('notifications'),('platform_settings')) required(table_name)
order by required.table_name;

select table_name, column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema='public' and table_name in
 ('profiles','teacher_requests','exams','questions','exam_attempts','student_answers','results','notifications','platform_settings')
order by table_name, ordinal_position;

select c.relname as table_name, con.conname as constraint_name,
       case con.contype when 'p' then 'primary key' when 'f' then 'foreign key' when 'u' then 'unique' when 'c' then 'check' else con.contype::text end as constraint_type,
       pg_get_constraintdef(con.oid) as definition, con.convalidated as validated
from pg_constraint con join pg_class c on c.oid=con.conrelid join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in
 ('profiles','teacher_requests','exams','questions','exam_attempts','student_answers','results','notifications','platform_settings')
order by c.relname, con.contype, con.conname;

select tablename, indexname, indexdef
from pg_indexes where schemaname='public' and tablename in
 ('profiles','teacher_requests','exams','questions','exam_attempts','student_answers','results','notifications','platform_settings')
order by tablename,indexname;

select tablename, policyname, roles, cmd, qual, with_check
from pg_policies where schemaname='public' and tablename in
 ('profiles','teacher_requests','exams','questions','exam_attempts','student_answers','results','notifications','platform_settings')
order by tablename,policyname;

select c.relname as table_name, c.relrowsecurity as rls_enabled, c.relforcerowsecurity as rls_forced
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in
 ('profiles','teacher_requests','exams','questions','exam_attempts','student_answers','results','notifications','platform_settings')
order by c.relname;

select event_object_table as table_name, trigger_name, event_manipulation,
       action_timing, action_statement
from information_schema.triggers
where trigger_schema='public' and event_object_table in
 ('profiles','teacher_requests','exams','questions','exam_attempts','student_answers','results','notifications','platform_settings')
union all
select 'auth.users', trigger_name, event_manipulation, action_timing, action_statement
from information_schema.triggers where trigger_schema='auth' and event_object_table='users'
order by 1,2,3;

select n.nspname as schema_name, p.proname as function_name,
       pg_get_function_identity_arguments(p.oid) as arguments,
       pg_get_function_result(p.oid) as result_type
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in
 ('current_role','is_admin','is_approved_teacher','handle_new_user','protect_profile_role','start_exam','save_exam_answers','submit_exam','review_teacher')
order by p.proname;

select table_name, grantee, privilege_type
from information_schema.role_table_grants
where table_schema='public' and grantee in ('anon','authenticated','service_role') and table_name in
 ('profiles','teacher_requests','exams','questions','exam_attempts','student_answers','results','notifications','platform_settings')
order by table_name,grantee,privilege_type;

select table_name, column_name, grantee, privilege_type
from information_schema.column_privileges
where table_schema='public' and grantee in ('anon','authenticated','service_role') and table_name='results'
order by table_name,column_name,grantee,privilege_type;

select 'profiles_role_check' as check_name, pg_get_constraintdef(oid) as definition
from pg_constraint where conrelid='public.profiles'::regclass and conname='profiles_role_check'
union all
select 'profiles_requested_role_check', pg_get_constraintdef(oid)
from pg_constraint where conrelid='public.profiles'::regclass and conname='profiles_requested_role_check';

select count(*) as preserved_profile_rows from public.profiles;
