-- ExamGuard AI schema repair, step 1 of 4.
-- Run in the Supabase SQL Editor. This file never creates, drops, or rewrites profiles.
-- Existing profile rows are inspected only; this transaction creates missing app tables.

begin;

do $$
begin
  if to_regclass('public.profiles') is null then
    raise exception 'public.profiles is required and was not found';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='profiles'
      and column_name='id' and udt_name='uuid'
  ) then raise exception 'public.profiles.id must be uuid'; end if;
end;
$$;

create extension if not exists pgcrypto;

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
  instructions text not null default '',
  duration_minutes integer not null check (duration_minutes between 1 and 600),
  total_marks numeric not null default 0 check (total_marks >= 0),
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
  time_spent_seconds integer not null default 0 check (time_spent_seconds>=0),
  score numeric,
  max_score numeric,
  attempt_number integer not null default 1 check (attempt_number>0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
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
  percentage numeric not null default 0 check (percentage between 0 and 100),
  passed boolean not null,
  published boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
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

-- Add only the additional feature columns to earlier versions of these tables.
alter table public.exams add column if not exists instructions text not null default '';
alter table public.exams add column if not exists total_marks numeric not null default 0;
alter table public.exam_attempts add column if not exists time_spent_seconds integer not null default 0;
alter table public.exam_attempts add column if not exists score numeric;
alter table public.exam_attempts add column if not exists max_score numeric;
alter table public.exam_attempts add column if not exists attempt_number integer not null default 1;
alter table public.exam_attempts add column if not exists created_at timestamptz not null default now();
alter table public.exam_attempts add column if not exists updated_at timestamptz not null default now();
alter table public.results add column if not exists percentage numeric not null default 0;
alter table public.results add column if not exists published boolean not null default false;
alter table public.results add column if not exists updated_at timestamptz not null default now();

-- Fail closed if an already-present related table does not match the app contract.
do $$
declare required record;
begin
  for required in select * from (values
    ('exams','id','uuid'),('exams','teacher_id','uuid'),('exams','title','text'),('exams','description','text'),('exams','instructions','text'),('exams','duration_minutes','int4'),('exams','total_marks','numeric'),('exams','passing_marks','numeric'),('exams','available_from','timestamptz'),('exams','available_until','timestamptz'),('exams','published','bool'),('exams','created_at','timestamptz'),('exams','updated_at','timestamptz'),
    ('questions','id','uuid'),('questions','exam_id','uuid'),('questions','prompt','text'),('questions','description','text'),('questions','options','jsonb'),('questions','correct_answer','int4'),('questions','points','numeric'),('questions','position','int4'),('questions','created_at','timestamptz'),
    ('exam_attempts','id','uuid'),('exam_attempts','exam_id','uuid'),('exam_attempts','student_id','uuid'),('exam_attempts','started_at','timestamptz'),('exam_attempts','submitted_at','timestamptz'),('exam_attempts','status','text'),('exam_attempts','time_spent_seconds','int4'),('exam_attempts','score','numeric'),('exam_attempts','max_score','numeric'),('exam_attempts','attempt_number','int4'),('exam_attempts','created_at','timestamptz'),('exam_attempts','updated_at','timestamptz'),
    ('student_answers','id','uuid'),('student_answers','attempt_id','uuid'),('student_answers','question_id','uuid'),('student_answers','selected_answer','int4'),('student_answers','updated_at','timestamptz'),
    ('results','id','uuid'),('results','attempt_id','uuid'),('results','student_id','uuid'),('results','exam_id','uuid'),('results','score','numeric'),('results','max_score','numeric'),('results','percentage','numeric'),('results','passed','bool'),('results','published','bool'),('results','created_at','timestamptz'),('results','updated_at','timestamptz'),
    ('teacher_requests','id','uuid'),('teacher_requests','user_id','uuid'),('teacher_requests','status','text'),('teacher_requests','note','text'),('teacher_requests','reviewed_by','uuid'),('teacher_requests','reviewed_at','timestamptz'),('teacher_requests','created_at','timestamptz'),
    ('notifications','id','uuid'),('notifications','user_id','uuid'),('notifications','title','text'),('notifications','body','text'),('notifications','read_at','timestamptz'),('notifications','created_at','timestamptz'),
    ('platform_settings','key','text'),('platform_settings','value','jsonb'),('platform_settings','updated_at','timestamptz')
  ) as v(table_name,column_name,udt_name)
  loop
    if not exists(select 1 from information_schema.columns c
      where c.table_schema='public' and c.table_name=required.table_name
        and c.column_name=required.column_name and c.udt_name=required.udt_name) then
      raise exception 'public.% missing required column % (%); no repair changes were committed',required.table_name,required.column_name,required.udt_name;
    end if;
  end loop;
end;
$$;

-- Ensure the expected primary key exists on every application table. Existing
-- different primary keys abort rather than being replaced.
do $$
declare k record; att smallint; existing_key smallint[];
begin
  for k in select * from (values
    ('teacher_requests','id'),('exams','id'),('questions','id'),('exam_attempts','id'),
    ('student_answers','id'),('results','id'),('notifications','id'),('platform_settings','key')
  ) as v(table_name,column_name)
  loop
    select a.attnum into att from pg_attribute a
      where a.attrelid=format('public.%I',k.table_name)::regclass and a.attname=k.column_name and not a.attisdropped;
    select c.conkey into existing_key from pg_constraint c
      where c.conrelid=format('public.%I',k.table_name)::regclass and c.contype='p';
    if existing_key is null then
      execute format('alter table public.%I add constraint %I primary key (%I)',k.table_name,k.table_name || '_repair_pkey',k.column_name);
    elsif existing_key <> array[att]::smallint[] then
      raise exception 'public.% has a different primary key; inspect before continuing',k.table_name;
    end if;
    existing_key := null;
  end loop;
end;
$$;

-- Ensure all required foreign keys exist and are validated. An orphaned row
-- causes this transaction to stop without deleting or rewriting that row.
do $$
declare f record; src_att smallint; dst_att smallint; fk_name text; fk_oid oid;
begin
  for f in select * from (values
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
  ) as v(src_table,src_col,dst_schema,dst_table,dst_col,delete_action)
  loop
    select attnum into src_att from pg_attribute
      where attrelid=format('public.%I',f.src_table)::regclass and attname=f.src_col and not attisdropped;
    select attnum into dst_att from pg_attribute
      where attrelid=format('%I.%I',f.dst_schema,f.dst_table)::regclass and attname=f.dst_col and not attisdropped;
    select c.oid,c.conname into fk_oid,fk_name from pg_constraint c
      where c.contype='f' and c.conrelid=format('public.%I',f.src_table)::regclass
        and c.confrelid=format('%I.%I',f.dst_schema,f.dst_table)::regclass
        and c.conkey=array[src_att]::smallint[] and c.confkey=array[dst_att]::smallint[];
    if fk_oid is null then
      fk_name := f.src_table || '_' || f.src_col || '_fkey';
      execute format('alter table public.%I add constraint %I foreign key (%I) references %I.%I(%I) on delete %s',
        f.src_table,fk_name,f.src_col,f.dst_schema,f.dst_table,f.dst_col,f.delete_action);
    else
      if not (select convalidated from pg_constraint where oid=fk_oid) then
        execute format('alter table public.%I validate constraint %I',f.src_table,fk_name);
      end if;
    end if;
    fk_oid := null;
    fk_name := null;
  end loop;
end;
$$;

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

notify pgrst, 'reload schema';
commit;
