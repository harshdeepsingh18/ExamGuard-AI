-- Read-only checks for ExamGuard AI. Run after examguard_database_repair.sql.

-- Existing profile columns and authorization fields.
select column_name, data_type, udt_name, is_nullable, column_default
from information_schema.columns
where table_schema='public' and table_name='profiles'
order by ordinal_position;

select count(*) as profile_rows from public.profiles;

select c.conname, pg_get_constraintdef(c.oid) as definition
from pg_constraint c
where c.conrelid='public.profiles'::regclass
  and c.conname in ('profiles_role_check','profiles_requested_role_check');

select role, requested_role, teacher_approved, teacher_status, count(*) as row_count
from public.profiles
group by role, requested_role, teacher_approved, teacher_status
order by role, requested_role, teacher_approved, teacher_status;

-- Required application tables. Every row should have present=true.
select required.table_name,
       to_regclass('public.' || required.table_name) is not null as present
from (values
  ('profiles'),('teacher_requests'),('exams'),('questions'),('exam_attempts'),
  ('student_answers'),('results'),('notifications'),('platform_settings')
) as required(table_name)
order by required.table_name;

-- Required application columns and types. Every row should have present=true.
select required.table_name, required.column_name, required.udt_name,
       exists(select 1 from information_schema.columns c
         where c.table_schema='public' and c.table_name=required.table_name
           and c.column_name=required.column_name
           and (c.udt_name=required.udt_name
             or (required.udt_name='text or varchar' and c.udt_name in ('text','varchar')))) as present
from (values
  ('profiles','id','uuid'),('profiles','full_name','text'),('profiles','role','text'),('profiles','requested_role','text or varchar'),('profiles','teacher_approved','bool'),('profiles','teacher_status','text'),('profiles','created_at','timestamptz'),
  ('teacher_requests','id','uuid'),('teacher_requests','user_id','uuid'),('teacher_requests','status','text'),('teacher_requests','note','text'),('teacher_requests','reviewed_by','uuid'),('teacher_requests','reviewed_at','timestamptz'),('teacher_requests','created_at','timestamptz'),
  ('exams','id','uuid'),('exams','teacher_id','uuid'),('exams','title','text'),('exams','description','text'),('exams','duration_minutes','int4'),('exams','passing_marks','numeric'),('exams','available_from','timestamptz'),('exams','available_until','timestamptz'),('exams','published','bool'),('exams','created_at','timestamptz'),('exams','updated_at','timestamptz'),
  ('questions','id','uuid'),('questions','exam_id','uuid'),('questions','prompt','text'),('questions','description','text'),('questions','options','jsonb'),('questions','correct_answer','int4'),('questions','points','numeric'),('questions','position','int4'),('questions','created_at','timestamptz'),
  ('exam_attempts','id','uuid'),('exam_attempts','exam_id','uuid'),('exam_attempts','student_id','uuid'),('exam_attempts','started_at','timestamptz'),('exam_attempts','submitted_at','timestamptz'),('exam_attempts','status','text'),
  ('student_answers','id','uuid'),('student_answers','attempt_id','uuid'),('student_answers','question_id','uuid'),('student_answers','selected_answer','int4'),('student_answers','updated_at','timestamptz'),
  ('results','id','uuid'),('results','attempt_id','uuid'),('results','student_id','uuid'),('results','exam_id','uuid'),('results','score','numeric'),('results','max_score','numeric'),('results','passed','bool'),('results','created_at','timestamptz'),
  ('notifications','id','uuid'),('notifications','user_id','uuid'),('notifications','title','text'),('notifications','body','text'),('notifications','read_at','timestamptz'),('notifications','created_at','timestamptz'),
  ('platform_settings','key','text'),('platform_settings','value','jsonb'),('platform_settings','updated_at','timestamptz')
) as required(table_name,column_name,udt_name)
order by required.table_name,required.column_name;

-- Keys, relationships, and their validation state.
select src.relname as table_name, c.conname, c.contype,
       pg_get_constraintdef(c.oid) as definition, c.convalidated as validated
from pg_constraint c
join pg_class src on src.oid=c.conrelid
join pg_namespace n on n.oid=src.relnamespace
where n.nspname='public' and src.relname in (
  'profiles','teacher_requests','exams','questions','exam_attempts',
  'student_answers','results','notifications','platform_settings'
)
order by src.relname,c.contype,c.conname;

select schemaname, tablename, indexname, indexdef
from pg_indexes
where schemaname='public' and tablename in (
  'teacher_requests','exams','questions','exam_attempts','student_answers',
  'results','notifications'
)
order by tablename,indexname;

-- Row security state and all installed policies.
select n.nspname as schema_name, c.relname as table_name,
       c.relrowsecurity as rls_enabled, c.relforcerowsecurity as rls_forced
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

-- Auth and profile triggers.
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

select expected.trigger_name,
       exists(select 1 from pg_trigger t
         where t.tgrelid=expected.table_oid::regclass and t.tgname=expected.trigger_name
           and not t.tgisinternal) as present
from (values
  ('on_auth_user_created','auth.users'::regclass),
  ('profile_role_guard','public.profiles'::regclass)
) as expected(trigger_name,table_oid)
order by expected.trigger_name;

-- Required callable routines and invoker/definer mode.
select routine_name, routine_type, security_type
from information_schema.routines
where specific_schema='public' and routine_name in (
  'current_role','is_admin','is_approved_teacher','handle_new_user',
  'protect_profile_role','start_exam','save_exam_answers','submit_exam','review_teacher'
)
order by routine_name;

select expected.signature,
       to_regprocedure(expected.signature) is not null as present
from (values
  ('public.current_role()'),('public.is_admin()'),('public.is_approved_teacher()'),
  ('public.start_exam(uuid)'),('public.save_exam_answers(uuid,jsonb)'),
  ('public.submit_exam(uuid,jsonb)'),('public.review_teacher(uuid,boolean)')
) as expected(signature)
order by expected.signature;

-- Relationship consistency counts. Both should be zero after any profile backfill.
select count(*) as profiles_without_auth_user
from public.profiles p left join auth.users u on u.id=p.id
where u.id is null;

select count(*) as auth_users_without_profile
from auth.users u left join public.profiles p on p.id=u.id
where p.id is null;
