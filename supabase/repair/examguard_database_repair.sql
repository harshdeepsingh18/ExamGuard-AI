-- ExamGuard AI additive repair for a partially applied schema.
-- Existing public.profiles contains user data and is never dropped or recreated.
-- The current project report includes requested_role and teacher_approved and
-- does not include updated_at. Those fields are guarded by the profile trigger.
-- Missing profiles for Auth users are inserted; existing profile rows stay unchanged.
-- The existing "Users can view own profile" policy is retained.

-- READ-ONLY PREFLIGHT: run this section by itself before running the repair.
select column_name, data_type, udt_name, is_nullable, column_default
from information_schema.columns
where table_schema='public' and table_name='profiles'
order by ordinal_position;

select c.conname, c.contype, pg_get_constraintdef(c.oid) as definition
from pg_constraint c
where c.conrelid='public.profiles'::regclass
order by c.contype,c.conname;

select count(*) as existing_profiles from public.profiles;

select schemaname,tablename,policyname,permissive,roles,cmd,qual,with_check
from pg_policies
where schemaname='public' and tablename in (
  'profiles','teacher_requests','exams','questions','exam_attempts',
  'student_answers','results','notifications','platform_settings'
)
order by tablename,policyname;

begin;

create extension if not exists pgcrypto;

do $$
declare
  missing_columns text;
  profile_id_att smallint;
begin
  if to_regclass('public.profiles') is null then
    raise exception 'public.profiles does not exist; stop and inspect the database before using this repair';
  end if;

  select string_agg(required.column_name || ' (expected ' || required.udt_name || ')', ', ' order by required.column_name)
    into missing_columns
  from (values
    ('id','uuid'), ('full_name','text'), ('role','text'),
    ('teacher_approved','bool'), ('teacher_status','text'), ('created_at','timestamptz')
  ) as required(column_name, udt_name)
  where not exists (
    select 1 from information_schema.columns c
    where c.table_schema='public' and c.table_name='profiles'
      and c.column_name=required.column_name and c.udt_name=required.udt_name
  );

  if missing_columns is not null then
    raise exception 'Existing public.profiles is incompatible. Missing/mismatched required columns: %. No repair changes were made.', missing_columns;
  end if;

  if not exists (
    select 1 from information_schema.columns c
    where c.table_schema='public' and c.table_name='profiles'
      and c.column_name='requested_role' and c.data_type in ('text','character varying')
  ) then
    raise exception 'public.profiles.requested_role must be a text column for signup role synchronization. No repair changes were made.';
  end if;

  if not exists (
    select 1 from pg_constraint c
    where c.conrelid='public.profiles'::regclass
      and c.conname='profiles_requested_role_check' and c.contype='c'
      and pg_get_constraintdef(c.oid) ilike '%student%'
      and pg_get_constraintdef(c.oid) ilike '%teacher%'
      and pg_get_constraintdef(c.oid) not ilike '%admin%'
  ) then
    raise exception 'The expected student/teacher-only profiles_requested_role_check is missing or differs. No repair changes were made.';
  end if;

  select string_agg(c.column_name, ', ' order by c.column_name) into missing_columns
  from information_schema.columns c
  where c.table_schema='public' and c.table_name='profiles'
    and c.is_nullable='NO' and c.column_default is null
    and c.is_generated='NEVER'
    and c.is_identity='NO'
    and c.column_name not in ('id','full_name','role','requested_role','teacher_approved','teacher_status');
  if missing_columns is not null then
    raise exception 'public.profiles has additional required columns with no defaults (%); automatic profile creation would fail. No repair changes were made.', missing_columns;
  end if;

  select a.attnum into profile_id_att
  from pg_attribute a
  where a.attrelid='public.profiles'::regclass and a.attname='id' and not a.attisdropped;

  if not exists (
    select 1 from pg_constraint c where c.conrelid='public.profiles'::regclass
      and c.contype='p' and c.conkey=array[profile_id_att]::smallint[]
  ) then
    raise exception 'public.profiles.id is not the primary key. No repair changes were made; inspect its live definition first.';
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname='public' and tablename in (
      'profiles','teacher_requests','exams','questions','exam_attempts',
      'student_answers','results','notifications','platform_settings'
    ) and policyname <> all(array[
      'profile_read','profile_update','profile_teacher_result_read','Users can view own profile',
      'request_read','request_admin_update','exam_read','exam_insert','exam_update','exam_delete',
      'question_teacher_all','attempts_read','results_read','answers_read',
      'notification_self','settings_read','settings_admin_write'
    ])
  ) then
    raise exception 'Unexpected custom RLS policies exist on ExamGuard tables. Review them with the verification queries before applying the policy repair.';
  end if;
end;
$$;

-- Tables are created in dependency order. IF NOT EXISTS preserves any table
-- already present; later checks stop if an existing table has an incompatible shape.
create table if not exists public.teacher_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null constraint teacher_requests_user_id_fkey references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  note text,
  reviewed_by uuid constraint teacher_requests_reviewed_by_fkey references public.profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint teacher_requests_user_id_key unique (user_id)
);

create table if not exists public.exams (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null constraint exams_teacher_id_fkey references public.profiles(id),
  title text not null,
  description text not null default '',
  duration_minutes integer not null check (duration_minutes between 1 and 600),
  passing_marks numeric not null default 0 check (passing_marks >= 0),
  available_from timestamptz,
  available_until timestamptz,
  published boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (available_until is null or available_from is null or available_until > available_from)
);

create table if not exists public.questions (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null constraint questions_exam_id_fkey references public.exams(id) on delete cascade,
  prompt text not null,
  description text not null default '',
  options jsonb not null check (jsonb_typeof(options)='array' and jsonb_array_length(options)>=2),
  correct_answer integer not null check (correct_answer>=0),
  points numeric not null default 1 check (points>0),
  position integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.exam_attempts (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null constraint exam_attempts_exam_id_fkey references public.exams(id),
  student_id uuid not null constraint exam_attempts_student_id_fkey references public.profiles(id),
  started_at timestamptz not null default now(),
  submitted_at timestamptz,
  status text not null default 'in_progress' check (status in ('in_progress','submitted','expired')),
  constraint exam_attempts_exam_id_student_id_id_key unique (exam_id,student_id,id)
);

create table if not exists public.student_answers (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null constraint student_answers_attempt_id_fkey references public.exam_attempts(id) on delete cascade,
  question_id uuid not null constraint student_answers_question_id_fkey references public.questions(id),
  selected_answer integer,
  updated_at timestamptz not null default now(),
  constraint student_answers_attempt_id_question_id_key unique (attempt_id,question_id)
);

create table if not exists public.results (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null constraint results_attempt_id_fkey references public.exam_attempts(id) on delete cascade,
  student_id uuid not null constraint results_student_id_fkey references public.profiles(id),
  exam_id uuid not null constraint results_exam_id_fkey references public.exams(id),
  score numeric not null,
  max_score numeric not null,
  passed boolean not null,
  created_at timestamptz not null default now(),
  constraint results_attempt_id_key unique (attempt_id)
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null constraint notifications_user_id_fkey references public.profiles(id) on delete cascade,
  title text not null,
  body text not null default '',
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.platform_settings (
  key text primary key,
  value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- Fail closed on partially-created tables instead of silently treating them as repaired.
do $$
declare
  required record;
begin
  for required in
    select * from (values
      ('teacher_requests','id','uuid'),('teacher_requests','user_id','uuid'),('teacher_requests','status','text'),('teacher_requests','note','text'),('teacher_requests','reviewed_by','uuid'),('teacher_requests','reviewed_at','timestamptz'),('teacher_requests','created_at','timestamptz'),
      ('exams','id','uuid'),('exams','teacher_id','uuid'),('exams','title','text'),('exams','description','text'),('exams','duration_minutes','int4'),('exams','passing_marks','numeric'),('exams','available_from','timestamptz'),('exams','available_until','timestamptz'),('exams','published','bool'),('exams','created_at','timestamptz'),('exams','updated_at','timestamptz'),
      ('questions','id','uuid'),('questions','exam_id','uuid'),('questions','prompt','text'),('questions','description','text'),('questions','options','jsonb'),('questions','correct_answer','int4'),('questions','points','numeric'),('questions','position','int4'),('questions','created_at','timestamptz'),
      ('exam_attempts','id','uuid'),('exam_attempts','exam_id','uuid'),('exam_attempts','student_id','uuid'),('exam_attempts','started_at','timestamptz'),('exam_attempts','submitted_at','timestamptz'),('exam_attempts','status','text'),
      ('student_answers','id','uuid'),('student_answers','attempt_id','uuid'),('student_answers','question_id','uuid'),('student_answers','selected_answer','int4'),('student_answers','updated_at','timestamptz'),
      ('results','id','uuid'),('results','attempt_id','uuid'),('results','student_id','uuid'),('results','exam_id','uuid'),('results','score','numeric'),('results','max_score','numeric'),('results','passed','bool'),('results','created_at','timestamptz'),
      ('notifications','id','uuid'),('notifications','user_id','uuid'),('notifications','title','text'),('notifications','body','text'),('notifications','read_at','timestamptz'),('notifications','created_at','timestamptz'),
      ('platform_settings','key','text'),('platform_settings','value','jsonb'),('platform_settings','updated_at','timestamptz')
    ) as v(table_name,column_name,udt_name)
  loop
    if not exists (
      select 1 from information_schema.columns c
      where c.table_schema='public' and c.table_name=required.table_name
        and c.column_name=required.column_name and c.udt_name=required.udt_name
    ) then
      raise exception 'public.% is not repaired: required column % with type % is missing or has a different type. No data was removed.', required.table_name, required.column_name, required.udt_name;
    end if;
  end loop;
end;
$$;

-- Ensure each app table has the key the client and PostgREST expect. A table
-- with a different existing primary key is not rewritten; it stops for review.
do $$
declare
  pk record;
  att smallint;
  existing_key smallint[];
begin
  for pk in select * from (values
    ('profiles','id'),('teacher_requests','id'),('exams','id'),('questions','id'),
    ('exam_attempts','id'),('student_answers','id'),('results','id'),
    ('notifications','id'),('platform_settings','key')
  ) as v(table_name,column_name)
  loop
    select a.attnum into att from pg_attribute a
      where a.attrelid=format('public.%I',pk.table_name)::regclass
        and a.attname=pk.column_name and not a.attisdropped;
    select c.conkey into existing_key from pg_constraint c
      where c.conrelid=format('public.%I',pk.table_name)::regclass and c.contype='p';
    if existing_key is null then
      execute format('alter table public.%I add constraint %I primary key (%I)',
        pk.table_name,pk.table_name || '_repair_pkey',pk.column_name);
    elsif existing_key <> array[att]::smallint[] then
      raise exception 'public.% has a different primary key; inspect it before repair',pk.table_name;
    end if;
    existing_key := null;
  end loop;
end;
$$;

-- Add missing FKs as NOT VALID: existing rows remain untouched, while new writes
-- are checked. Existing matching FKs are preserved.
do $$
declare
  fk record;
  source_att smallint;
  target_att smallint;
begin
  for fk in select * from (values
    ('profiles','id','auth','users','id','CASCADE'),
    ('teacher_requests','user_id','public','profiles','id','CASCADE'),
    ('teacher_requests','reviewed_by','public','profiles','id','NO ACTION'),
    ('exams','teacher_id','public','profiles','id','NO ACTION'),
    ('questions','exam_id','public','exams','id','CASCADE'),
    ('exam_attempts','exam_id','public','exams','id','NO ACTION'),
    ('exam_attempts','student_id','public','profiles','id','NO ACTION'),
    ('student_answers','attempt_id','public','exam_attempts','id','CASCADE'),
    ('student_answers','question_id','public','questions','id','NO ACTION'),
    ('results','attempt_id','public','exam_attempts','id','CASCADE'),
    ('results','student_id','public','profiles','id','NO ACTION'),
    ('results','exam_id','public','exams','id','NO ACTION'),
    ('notifications','user_id','public','profiles','id','CASCADE')
  ) as v(src_table,src_col,ref_schema,ref_table,ref_col,delete_action)
  loop
    select attnum into source_att from pg_attribute
    where attrelid=format('public.%I',fk.src_table)::regclass and attname=fk.src_col and not attisdropped;
    select attnum into target_att from pg_attribute
    where attrelid=format('%I.%I',fk.ref_schema,fk.ref_table)::regclass and attname=fk.ref_col and not attisdropped;

    if not exists (
      select 1 from pg_constraint c
      where c.contype='f'
        and c.conrelid=format('public.%I',fk.src_table)::regclass
        and c.confrelid=format('%I.%I',fk.ref_schema,fk.ref_table)::regclass
        and c.conkey=array[source_att]::smallint[]
        and c.confkey=array[target_att]::smallint[]
    ) then
      execute format(
        'alter table public.%I add constraint %I foreign key (%I) references %I.%I(%I) on delete %s not valid',
        fk.src_table, fk.src_table || '_' || fk.src_col || '_repair_fkey', fk.src_col,
        fk.ref_schema, fk.ref_table, fk.ref_col, fk.delete_action
      );
    end if;
  end loop;
end;
$$;

-- Replace the legacy role check that excludes admin. requested_role's existing
-- student/teacher-only check is deliberately preserved unchanged.
do $$
begin
  if exists (
    select 1 from pg_constraint where conrelid='public.profiles'::regclass
      and contype='c' and conname not in ('profiles_role_check','profiles_role_repair_check','profiles_teacher_status_repair_check')
      and pg_get_constraintdef(oid) ~* '\mrole\M'
  ) then
    raise exception 'An additional profile role check exists. Review the preflight constraint output before changing the role constraint.';
  end if;
  alter table public.profiles drop constraint if exists profiles_role_check;
  alter table public.profiles drop constraint if exists profiles_role_repair_check;
  alter table public.profiles add constraint profiles_role_check
    check (role in ('student','teacher','admin'));
  if not exists (select 1 from pg_constraint where conrelid='public.profiles'::regclass and conname='profiles_teacher_status_repair_check') then
    alter table public.profiles add constraint profiles_teacher_status_repair_check
      check (teacher_status in ('none','pending','approved','rejected')) not valid;
  end if;
end;
$$;

-- Required unique indexes preserve the application's ON CONFLICT behavior.
create unique index if not exists teacher_requests_user_id_key on public.teacher_requests(user_id);
create unique index if not exists exam_attempts_exam_id_student_id_id_key on public.exam_attempts(exam_id,student_id,id);
create unique index if not exists student_answers_attempt_id_question_id_key on public.student_answers(attempt_id,question_id);
create unique index if not exists results_attempt_id_key on public.results(attempt_id);

create index if not exists exams_published_window on public.exams(published,available_from,available_until);
create index if not exists exams_teacher on public.exams(teacher_id,created_at desc);
create index if not exists questions_exam_position on public.questions(exam_id,position);
create index if not exists attempts_student on public.exam_attempts(student_id,started_at desc);
create index if not exists attempts_exam on public.exam_attempts(exam_id,status);
create index if not exists results_student on public.results(student_id,created_at desc);
create index if not exists notifications_user on public.notifications(user_id,created_at desc);

create or replace function public.current_role() returns text
language sql stable security definer set search_path = '' as $$
  select p.role from public.profiles p where p.id=auth.uid()
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(public.current_role()='admin',false)
$$;

create or replace function public.is_approved_teacher() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(exists(
    select 1 from public.profiles p where p.id=auth.uid()
      and p.role='teacher' and p.teacher_status='approved'
  ),false)
$$;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  account_type text := coalesce(new.raw_user_meta_data->>'account_type','student');
  display_name text := coalesce(
    nullif(btrim(new.raw_user_meta_data->>'full_name'),''),
    nullif(btrim(new.raw_user_meta_data->>'name'),''),
    nullif(split_part(coalesce(new.email,''),'@',1),''), ''
  );
begin
  if account_type not in ('student','teacher') then account_type := 'student'; end if;
  insert into public.profiles(id,full_name,role,requested_role,teacher_approved,teacher_status)
    values(new.id,display_name,account_type,account_type,false,case when account_type='teacher' then 'pending' else 'none' end)
    on conflict (id) do nothing;
  if account_type='teacher' then
    insert into public.teacher_requests(user_id) values(new.id) on conflict (user_id) do nothing;
  end if;
  return new;
end;
$$;

create or replace function public.protect_profile_role() returns trigger
language plpgsql set search_path = '' as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    new.role := old.role;
    new.requested_role := old.requested_role;
    new.teacher_approved := old.teacher_approved;
    new.teacher_status := old.teacher_status;
  elsif new.role is distinct from old.role or new.teacher_status is distinct from old.teacher_status then
    new.teacher_approved := (new.role='teacher' and new.teacher_status='approved');
  else
    new.teacher_approved := old.teacher_approved;
  end if;
  return new;
end;
$$;

create or replace function public.start_exam(p_exam uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  e public.exams;
  aid uuid;
  qs jsonb;
begin
  if auth.uid() is null or public.current_role() not in ('student','admin') then
    raise exception 'Student access required';
  end if;
  select * into e from public.exams where id=p_exam and published
    and (available_from is null or available_from<=now())
    and (available_until is null or available_until>now());
  if not found then raise exception 'Exam unavailable'; end if;
  select id into aid from public.exam_attempts
    where exam_id=p_exam and student_id=auth.uid() and status='in_progress' limit 1;
  if aid is null then
    insert into public.exam_attempts(exam_id,student_id) values(p_exam,auth.uid()) returning id into aid;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',q.id,'prompt',q.prompt,'description',q.description,'options',q.options,
    'points',q.points,'position',q.position
  ) order by q.position),'[]'::jsonb) into qs
  from public.questions q where q.exam_id=p_exam;
  return jsonb_build_object(
    'attempt_id',aid,
    'attempt_started_at',(select started_at from public.exam_attempts where id=aid),
    'saved_answers',(select coalesce(jsonb_agg(jsonb_build_object(
      'question_id',question_id,'selected_answer',selected_answer
    )),'[]'::jsonb) from public.student_answers where attempt_id=aid),
    'exam',jsonb_build_object('id',e.id,'title',e.title,'description',e.description,'duration_minutes',e.duration_minutes),
    'questions',qs
  );
end;
$$;

create or replace function public.save_exam_answers(p_attempt uuid,p_answers jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  a public.exam_attempts;
  e public.exams;
begin
  select * into a from public.exam_attempts
    where id=p_attempt and student_id=auth.uid() and status='in_progress' for update;
  if not found then raise exception 'Attempt unavailable'; end if;
  select * into e from public.exams where id=a.exam_id;
  if now()>a.started_at+make_interval(mins=>e.duration_minutes) then raise exception 'Time limit expired'; end if;
  if jsonb_typeof(p_answers) is distinct from 'array' then raise exception 'Invalid answers'; end if;
  if exists(
    select 1 from jsonb_array_elements(p_answers) x
    left join public.questions q on q.id=(x->>'question_id')::uuid and q.exam_id=a.exam_id
    where q.id is null or coalesce((x->>'selected_answer')::integer,-1)<0
      or coalesce((x->>'selected_answer')::integer,-1)>=jsonb_array_length(q.options)
  ) then raise exception 'Invalid answer selection'; end if;
  insert into public.student_answers(attempt_id,question_id,selected_answer)
    select a.id,(x->>'question_id')::uuid,(x->>'selected_answer')::integer
    from jsonb_array_elements(p_answers) x
    on conflict(attempt_id,question_id) do update
      set selected_answer=excluded.selected_answer,updated_at=now();
end;
$$;

create or replace function public.submit_exam(p_attempt uuid,p_answers jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a public.exam_attempts;
  e public.exams;
  score numeric := 0;
  maxscore numeric := 0;
  passed boolean;
begin
  select * into a from public.exam_attempts
    where id=p_attempt and student_id=auth.uid() and status='in_progress' for update;
  if not found then raise exception 'Attempt unavailable'; end if;
  select * into e from public.exams where id=a.exam_id;
  if now()>a.started_at+make_interval(mins=>e.duration_minutes) then
    update public.exam_attempts set status='expired',submitted_at=now() where id=a.id;
    raise exception 'Time limit expired';
  end if;
  perform public.save_exam_answers(p_attempt,p_answers);
  select coalesce(sum(q.points) filter(where sa.selected_answer=q.correct_answer),0),
         coalesce(sum(q.points),0)
    into score,maxscore
    from public.questions q left join public.student_answers sa
      on sa.question_id=q.id and sa.attempt_id=a.id
    where q.exam_id=a.exam_id;
  passed := score>=e.passing_marks;
  update public.exam_attempts set status='submitted',submitted_at=now() where id=a.id;
  insert into public.results(attempt_id,student_id,exam_id,score,max_score,passed)
    values(a.id,a.student_id,a.exam_id,score,maxscore,passed)
    on conflict(attempt_id) do update set score=excluded.score,max_score=excluded.max_score,passed=excluded.passed;
  return jsonb_build_object('score',score,'max_score',maxscore,'passed',passed);
end;
$$;

create or replace function public.review_teacher(p_request uuid,p_approve boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid;
begin
  if not public.is_admin() then raise exception 'Admin access required'; end if;
  update public.teacher_requests
    set status=case when p_approve then 'approved' else 'rejected' end,
        reviewed_by=auth.uid(),reviewed_at=now()
    where id=p_request and status='pending' returning user_id into uid;
  if uid is null then raise exception 'Pending request not found'; end if;
  update public.profiles
    set teacher_status=case when p_approve then 'approved' else 'rejected' end,
        teacher_approved=p_approve
    where id=uid;
  insert into public.notifications(user_id,title,body)
    values(uid,'Teacher request reviewed',case when p_approve then 'Your teacher access has been approved.' else 'Your teacher access request was declined.' end);
end;
$$;

revoke all on function public.current_role() from public;
revoke all on function public.is_admin() from public;
revoke all on function public.is_approved_teacher() from public;
revoke all on function public.handle_new_user() from public;
revoke all on function public.protect_profile_role() from public;
revoke all on function public.start_exam(uuid) from public;
revoke all on function public.save_exam_answers(uuid,jsonb) from public;
revoke all on function public.submit_exam(uuid,jsonb) from public;
revoke all on function public.review_teacher(uuid,boolean) from public;
grant execute on function public.current_role() to authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.is_approved_teacher() to authenticated;
grant execute on function public.start_exam(uuid) to authenticated;
grant execute on function public.save_exam_answers(uuid,jsonb) to authenticated;
grant execute on function public.submit_exam(uuid,jsonb) to authenticated;
grant execute on function public.review_teacher(uuid,boolean) to authenticated;

revoke all on function public.current_role() from anon;
revoke all on function public.is_admin() from anon;
revoke all on function public.is_approved_teacher() from anon;
revoke all on function public.handle_new_user() from anon;
revoke all on function public.protect_profile_role() from anon;
revoke all on function public.start_exam(uuid) from anon;
revoke all on function public.save_exam_answers(uuid,jsonb) from anon;
revoke all on function public.submit_exam(uuid,jsonb) from anon;
revoke all on function public.review_teacher(uuid,boolean) from anon;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();
drop trigger if exists profile_role_guard on public.profiles;
create trigger profile_role_guard before update on public.profiles
  for each row execute function public.protect_profile_role();

-- Backfill only users whose profile is absent. Existing profile rows, roles,
-- approval states, and any extra profile columns are left untouched.
insert into public.profiles(id,full_name,role,requested_role,teacher_approved,teacher_status)
select u.id,
  coalesce(nullif(btrim(u.raw_user_meta_data->>'full_name'),''),
           nullif(btrim(u.raw_user_meta_data->>'name'),''),
           nullif(split_part(coalesce(u.email,''),'@',1),''),''),
  case when u.raw_user_meta_data->>'account_type'='teacher' then 'teacher' else 'student' end,
  case when u.raw_user_meta_data->>'account_type'='teacher' then 'teacher' else 'student' end,
  false,
  case when u.raw_user_meta_data->>'account_type'='teacher' then 'pending' else 'none' end
from auth.users u
where not exists(select 1 from public.profiles p where p.id=u.id)
on conflict (id) do nothing;

insert into public.teacher_requests(user_id)
select p.id from public.profiles p
where p.role='teacher' and p.teacher_status='pending'
on conflict (user_id) do nothing;

alter table public.profiles enable row level security;
alter table public.teacher_requests enable row level security;
alter table public.exams enable row level security;
alter table public.questions enable row level security;
alter table public.exam_attempts enable row level security;
alter table public.student_answers enable row level security;
alter table public.results enable row level security;
alter table public.notifications enable row level security;
alter table public.platform_settings enable row level security;

-- Replace only the known ExamGuard policy names. Unknown policies fail preflight
-- above, so no custom authorization rules are silently removed.
do $$
declare p record;
begin
  for p in select schemaname,tablename,policyname from pg_policies
    where schemaname='public' and tablename in (
      'profiles','teacher_requests','exams','questions','exam_attempts',
      'student_answers','results','notifications','platform_settings'
    )
    and not (tablename='profiles' and policyname='Users can view own profile')
  loop
    execute format('drop policy %I on public.%I',p.policyname,p.tablename);
  end loop;
end;
$$;

create policy profile_read on public.profiles for select to authenticated
  using (id=auth.uid() or public.is_admin());
create policy profile_update on public.profiles for update to authenticated
  using (id=auth.uid() or public.is_admin()) with check (id=auth.uid() or public.is_admin());
create policy profile_teacher_result_read on public.profiles for select to authenticated
  using (exists(select 1 from public.results r join public.exams e on e.id=r.exam_id
    where r.student_id=profiles.id and e.teacher_id=auth.uid()));

create policy request_read on public.teacher_requests for select to authenticated
  using (user_id=auth.uid() or public.is_admin());
create policy request_admin_update on public.teacher_requests for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy exam_read on public.exams for select to authenticated
  using (published or teacher_id=auth.uid() or public.is_admin());
create policy exam_insert on public.exams for insert to authenticated
  with check (teacher_id=auth.uid() and public.is_approved_teacher());
create policy exam_update on public.exams for update to authenticated
  using ((teacher_id=auth.uid() and public.is_approved_teacher()) or public.is_admin())
  with check ((teacher_id=auth.uid() and public.is_approved_teacher()) or public.is_admin());
create policy exam_delete on public.exams for delete to authenticated
  using ((teacher_id=auth.uid() and public.is_approved_teacher()) or public.is_admin());

create policy question_teacher_all on public.questions for all to authenticated
  using (exists(select 1 from public.exams e where e.id=exam_id
    and ((e.teacher_id=auth.uid() and public.is_approved_teacher()) or public.is_admin())))
  with check (exists(select 1 from public.exams e where e.id=exam_id
    and ((e.teacher_id=auth.uid() and public.is_approved_teacher()) or public.is_admin())));
create policy attempts_read on public.exam_attempts for select to authenticated
  using (student_id=auth.uid() or exists(select 1 from public.exams e
    where e.id=exam_id and e.teacher_id=auth.uid()) or public.is_admin());
create policy results_read on public.results for select to authenticated
  using (student_id=auth.uid() or exists(select 1 from public.exams e
    where e.id=exam_id and e.teacher_id=auth.uid()) or public.is_admin());
create policy answers_read on public.student_answers for select to authenticated
  using (exists(select 1 from public.exam_attempts a where a.id=attempt_id
    and (a.student_id=auth.uid() or exists(select 1 from public.exams e
      where e.id=a.exam_id and e.teacher_id=auth.uid()) or public.is_admin())));
create policy notification_self on public.notifications for all to authenticated
  using (user_id=auth.uid() or public.is_admin()) with check (user_id=auth.uid() or public.is_admin());
create policy settings_read on public.platform_settings for select to authenticated using (true);
create policy settings_admin_write on public.platform_settings for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

grant select,update on public.profiles to authenticated;
grant select,update on public.teacher_requests to authenticated;
grant select,insert,update,delete on public.exams to authenticated;
grant select,insert,update,delete on public.questions to authenticated;
grant select on public.exam_attempts,public.student_answers,public.results to authenticated;
grant select,insert,update,delete on public.notifications to authenticated;
grant select,insert,update,delete on public.platform_settings to authenticated;
grant usage on schema public to authenticated;
revoke all on public.profiles,public.teacher_requests,public.exams,public.questions,
  public.exam_attempts,public.student_answers,public.results,public.notifications,
  public.platform_settings from anon;
revoke insert,delete on public.profiles from authenticated;
revoke insert,delete on public.teacher_requests from authenticated;
revoke insert,update,delete on public.exam_attempts,public.student_answers,public.results from authenticated;

do $$
declare missing_tables text;
begin
  select string_agg(t.table_name,', ' order by t.table_name) into missing_tables
  from (values
    ('profiles'),('teacher_requests'),('exams'),('questions'),('exam_attempts'),
    ('student_answers'),('results'),('notifications'),('platform_settings')
  ) as t(table_name)
  where to_regclass('public.' || t.table_name) is null;
  if missing_tables is not null then raise exception 'Repair incomplete; missing tables: %',missing_tables; end if;
  if not exists(select 1 from pg_constraint c
    where c.conrelid='public.profiles'::regclass and c.conname='profiles_role_check'
      and c.contype='c' and pg_get_constraintdef(c.oid) ilike '%admin%') then
    raise exception 'Repair incomplete; profiles_role_check does not allow admin';
  end if;
  if not exists(select 1 from pg_constraint c
    where c.conrelid='public.profiles'::regclass and c.conname='profiles_requested_role_check'
      and c.contype='c' and pg_get_constraintdef(c.oid) ilike '%student%'
      and pg_get_constraintdef(c.oid) ilike '%teacher%'
      and pg_get_constraintdef(c.oid) not ilike '%admin%') then
    raise exception 'Repair incomplete; profiles_requested_role_check was not preserved';
  end if;
  if not exists(select 1 from pg_trigger where tgrelid='auth.users'::regclass and tgname='on_auth_user_created' and not tgisinternal) then
    raise exception 'Repair incomplete; auth profile trigger is missing';
  end if;
  if not exists(select 1 from pg_trigger where tgrelid='public.profiles'::regclass and tgname='profile_role_guard' and not tgisinternal) then
    raise exception 'Repair incomplete; profile role guard is missing';
  end if;
  if exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname in (
      'profiles','teacher_requests','exams','questions','exam_attempts',
      'student_answers','results','notifications','platform_settings'
    ) and not c.relrowsecurity) then
    raise exception 'Repair incomplete; RLS is disabled on an ExamGuard table';
  end if;
end;
$$;

notify pgrst, 'reload schema';
commit;
