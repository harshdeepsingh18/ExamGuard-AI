-- ExamGuard AI schema. Apply in the Supabase SQL editor before running the app.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    full_name text not null default '',
    role text not null default 'student' check (role in ('student', 'teacher')),
    requested_role text not null default 'student' check (requested_role in ('student', 'teacher')),
    teacher_approved boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create or replace function public.create_examguard_profile()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
    insert into public.profiles (id, full_name, requested_role, role, teacher_approved)
    values (
        new.id,
        coalesce(new.raw_user_meta_data ->> 'full_name', ''),
        case when new.raw_user_meta_data ->> 'requested_role' = 'teacher' then 'teacher' else 'student' end,
        'student',
        false
    ) on conflict (id) do nothing;
    return new;
end;
$$;

drop trigger if exists examguard_auth_user_created on auth.users;
create trigger examguard_auth_user_created after insert on auth.users
for each row execute function public.create_examguard_profile();

create or replace function public.protect_profile_role()
returns trigger language plpgsql as $$
begin
    if auth.uid() is not null and (
        new.role is distinct from old.role or
        new.requested_role is distinct from old.requested_role or
        new.teacher_approved is distinct from old.teacher_approved
    ) then
        raise exception 'Account role and teacher approval can only be changed by an administrator';
    end if;
    new.updated_at = now();
    return new;
end;
$$;
drop trigger if exists examguard_protect_profile_role on public.profiles;
create trigger examguard_protect_profile_role before update on public.profiles
for each row execute function public.protect_profile_role();

create table if not exists public.exams (
    id uuid primary key default gen_random_uuid(),
    teacher_id uuid not null references public.profiles(id) on delete cascade,
    title text not null,
    subject text not null,
    description text not null default '',
    exam_date date not null,
    start_time time not null,
    duration_minutes integer not null check (duration_minutes between 1 and 600),
    total_marks numeric(8,2) not null check (total_marks > 0),
    passing_marks numeric(8,2) not null default 0 check (passing_marks >= 0),
    rules text not null default '',
    question_paper_path text,
    extracted_text text not null default '',
    published boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    check (passing_marks <= total_marks)
);
create index if not exists exams_published_date_idx on public.exams(published, exam_date, start_time);
create index if not exists exams_teacher_idx on public.exams(teacher_id, created_at desc);

create or replace function public.guard_exam_changes()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
    total numeric(8,2);
    question_total numeric(8,2);
    question_count integer;
begin
    if tg_op = 'INSERT' then
        if new.published then raise exception 'Exams must be reviewed before publishing'; end if;
        return new;
    end if;
    if old.published then
        if not new.published and not exists(select 1 from public.exam_attempts a where a.exam_id = old.id) then
            new.updated_at = now();
            return new;
        end if;
        raise exception 'Published exams cannot be changed after students have started';
    end if;
    if new.teacher_id is distinct from old.teacher_id then raise exception 'Exam owner cannot be changed'; end if;
    if new.published then
        select coalesce(sum(marks), 0), count(*) into question_total, question_count from public.questions where exam_id = old.id;
        total := new.total_marks;
        if question_count = 0 or abs(question_total - total) > 0.0001 then
            raise exception 'Question marks must equal total marks before publishing';
        end if;
        if not exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'teacher' and p.teacher_approved) then
            raise exception 'Approved teacher access is required';
        end if;
    end if;
    new.updated_at = now();
    return new;
end;
$$;
drop trigger if exists examguard_guard_exam_changes on public.exams;
create trigger examguard_guard_exam_changes before insert or update on public.exams
for each row execute function public.guard_exam_changes();

create table if not exists public.questions (
    id uuid primary key default gen_random_uuid(),
    exam_id uuid not null references public.exams(id) on delete cascade,
    position integer not null,
    question_type text not null check (question_type in ('multiple_choice', 'multiple_select', 'true_false', 'short_answer', 'long_answer')),
    prompt text not null,
    options jsonb not null default '[]'::jsonb,
    marks numeric(8,2) not null check (marks > 0),
    created_at timestamptz not null default now(),
    unique (exam_id, position)
);
create index if not exists questions_exam_idx on public.questions(exam_id, position);

-- Keep answer keys separate so students cannot read them through the Data API.
create table if not exists public.question_keys (
    question_id uuid primary key references public.questions(id) on delete cascade,
    correct_answer jsonb not null
);
alter table public.question_keys enable row level security;
drop policy if exists question_key_teacher_read on public.question_keys;
create policy question_key_teacher_read on public.question_keys for select to authenticated using (
    exists(select 1 from public.questions q join public.exams e on e.id = q.exam_id join public.profiles p on p.id = e.teacher_id where q.id = question_id and e.teacher_id = auth.uid() and p.role = 'teacher' and p.teacher_approved)
);
drop policy if exists question_key_teacher_write on public.question_keys;
create policy question_key_teacher_write on public.question_keys for all to authenticated using (
    exists(select 1 from public.questions q join public.exams e on e.id = q.exam_id join public.profiles p on p.id = e.teacher_id where q.id = question_id and e.teacher_id = auth.uid() and p.role = 'teacher' and p.teacher_approved and not e.published)
) with check (
    exists(select 1 from public.questions q join public.exams e on e.id = q.exam_id join public.profiles p on p.id = e.teacher_id where q.id = question_id and e.teacher_id = auth.uid() and p.role = 'teacher' and p.teacher_approved and not e.published)
);

create table if not exists public.exam_attempts (
    id uuid primary key default gen_random_uuid(),
    exam_id uuid not null references public.exams(id) on delete cascade,
    student_id uuid not null references public.profiles(id) on delete cascade,
    started_at timestamptz not null default now(),
    submitted_at timestamptz,
    status text not null default 'in_progress' check (status in ('in_progress', 'submitted', 'graded')),
    created_at timestamptz not null default now(),
    unique (exam_id, student_id)
);
create index if not exists attempts_student_idx on public.exam_attempts(student_id, created_at desc);
create index if not exists attempts_exam_idx on public.exam_attempts(exam_id, status);

create table if not exists public.student_answers (
    id uuid primary key default gen_random_uuid(),
    attempt_id uuid not null references public.exam_attempts(id) on delete cascade,
    question_id uuid not null references public.questions(id) on delete cascade,
    answer jsonb not null default 'null'::jsonb,
    marks_awarded numeric(8,2),
    updated_at timestamptz not null default now(),
    unique (attempt_id, question_id)
);

create table if not exists public.proctoring_events (
    id uuid primary key default gen_random_uuid(),
    attempt_id uuid not null references public.exam_attempts(id) on delete cascade,
    event_type text not null check (event_type in ('tab_hidden', 'fullscreen_exit', 'face_missing', 'multiple_faces', 'camera_error')),
    occurred_at timestamptz not null default now(),
    details jsonb not null default '{}'::jsonb
);
create index if not exists proctor_events_attempt_idx on public.proctoring_events(attempt_id, occurred_at);

create table if not exists public.exam_results (
    id uuid primary key default gen_random_uuid(),
    attempt_id uuid not null unique references public.exam_attempts(id) on delete cascade,
    exam_id uuid not null references public.exams(id) on delete cascade,
    student_id uuid not null references public.profiles(id) on delete cascade,
    marks_obtained numeric(8,2) not null default 0,
    total_marks numeric(8,2) not null,
    published boolean not null default false,
    graded_at timestamptz not null default now()
);
create index if not exists results_student_idx on public.exam_results(student_id, graded_at desc);
create index if not exists results_exam_idx on public.exam_results(exam_id);

create or replace function public.finalize_exam_attempt()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
    earned numeric(8,2);
    maximum numeric(8,2);
begin
    if old.status = 'in_progress' and new.status = 'submitted' then
        if new.id is distinct from old.id or new.exam_id is distinct from old.exam_id or
           new.student_id is distinct from old.student_id or new.started_at is distinct from old.started_at then
            raise exception 'Attempt identity and start time cannot be changed';
        end if;
        new.submitted_at = now();
        select coalesce(sum(case when q.question_type in ('multiple_choice', 'multiple_select', 'true_false')
                                  and a.answer = k.correct_answer then q.marks else 0 end), 0),
               coalesce(sum(q.marks), 0)
          into earned, maximum
          from public.questions q
          left join public.question_keys k on k.question_id = q.id
          left join public.student_answers a on a.question_id = q.id and a.attempt_id = new.id
         where q.exam_id = new.exam_id;

        insert into public.exam_results (attempt_id, exam_id, student_id, marks_obtained, total_marks)
        values (new.id, new.exam_id, new.student_id, earned, maximum)
        on conflict (attempt_id) do update set marks_obtained = excluded.marks_obtained, total_marks = excluded.total_marks;
    elsif new.status is distinct from old.status then
        raise exception 'Submitted attempts cannot be reopened or changed';
    end if;
    return new;
end;
$$;
drop trigger if exists examguard_finalize_attempt on public.exam_attempts;
create trigger examguard_finalize_attempt before update of status on public.exam_attempts
for each row execute function public.finalize_exam_attempt();

create or replace function public.publish_exam_result(target_result uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
    target_exam uuid;
    attempt_key uuid;
    new_marks numeric(8,2);
begin
    select r.exam_id, r.attempt_id into target_exam, attempt_key from public.exam_results r where r.id = target_result;
    if target_exam is null or not exists(select 1 from public.exams e where e.id = target_exam and e.teacher_id = auth.uid()) then
        raise exception 'Result not found or access denied';
    end if;
    select coalesce(sum(case
        when q.question_type in ('multiple_choice', 'multiple_select', 'true_false') and a.answer = k.correct_answer then q.marks
        when q.question_type in ('multiple_choice', 'multiple_select', 'true_false') then 0
        else coalesce(a.marks_awarded, 0)
    end), 0) into new_marks
    from public.questions q
    left join public.question_keys k on k.question_id = q.id
    left join public.student_answers a on a.question_id = q.id and a.attempt_id = attempt_key
    where q.exam_id = target_exam;
    update public.exam_results set marks_obtained = new_marks, published = true where id = target_result;
    insert into public.notifications(user_id, title, body)
    select r.student_id, 'Exam result published', e.title || ': ' || new_marks::text || ' / ' || r.total_marks::text
      from public.exam_results r join public.exams e on e.id = r.exam_id where r.id = target_result;
end;
$$;

create or replace function public.grade_submission_answer(target_answer uuid, awarded numeric)
returns void language plpgsql security definer set search_path = '' as $$
declare
    max_marks numeric(8,2);
    submission uuid;
    attempt_state text;
    is_published boolean;
begin
    select q.marks, a.attempt_id, at.status, coalesce(r.published, false)
      into max_marks, submission, attempt_state, is_published
      from public.student_answers a join public.questions q on q.id = a.question_id
      join public.exam_attempts at on at.id = a.attempt_id
      left join public.exam_results r on r.attempt_id = a.attempt_id
     where a.id = target_answer and q.question_type in ('short_answer', 'long_answer');
    if max_marks is null or attempt_state <> 'submitted' or is_published or awarded < 0 or awarded > max_marks or not public.teaches_attempt(submission) then
        raise exception 'Answer not found or awarded marks are out of range';
    end if;
    perform set_config('examguard.grading', 'true', true);
    update public.student_answers set marks_awarded = awarded where id = target_answer;
end;
$$;

create or replace function public.protect_student_answer()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
    state text;
begin
    select status into state from public.exam_attempts where id = new.attempt_id;
    if (state <> 'in_progress' or not public.is_attempt_open(new.attempt_id)) and
       current_setting('examguard.grading', true) is distinct from 'true' then
        raise exception 'Submitted answers cannot be changed';
    end if;
    if new.marks_awarded is distinct from old.marks_awarded and
       current_setting('examguard.grading', true) is distinct from 'true' then
        raise exception 'Marks can only be assigned through teacher grading';
    end if;
    new.updated_at = now();
    return new;
end;
$$;
drop trigger if exists examguard_protect_student_answer on public.student_answers;
create trigger examguard_protect_student_answer before insert or update on public.student_answers
for each row execute function public.protect_student_answer();

create table if not exists public.notifications (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references public.profiles(id) on delete cascade,
    title text not null,
    body text not null,
    read_at timestamptz,
    created_at timestamptz not null default now()
);
create index if not exists notifications_user_idx on public.notifications(user_id, created_at desc);

create or replace function public.owns_exam(target_exam uuid)
returns boolean language sql stable security definer set search_path = '' as $$
    select exists(select 1 from public.exams e join public.profiles p on p.id = e.teacher_id where e.id = target_exam and e.teacher_id = auth.uid() and p.role = 'teacher' and p.teacher_approved)
$$;
create or replace function public.owns_attempt(target_attempt uuid)
returns boolean language sql stable security definer set search_path = '' as $$
    select exists(select 1 from public.exam_attempts a where a.id = target_attempt and a.student_id = auth.uid())
$$;
create or replace function public.teaches_attempt(target_attempt uuid)
returns boolean language sql stable security definer set search_path = '' as $$
    select exists(
        select 1 from public.exam_attempts a join public.exams e on e.id = a.exam_id join public.profiles p on p.id = e.teacher_id
        where a.id = target_attempt and e.teacher_id = auth.uid() and p.role = 'teacher' and p.teacher_approved
    )
$$;
create or replace function public.is_attempt_open(target_attempt uuid)
returns boolean language sql stable security definer set search_path = '' as $$
    select exists(
        select 1 from public.exam_attempts a join public.exams e on e.id = a.exam_id
         where a.id = target_attempt and a.status = 'in_progress'
           and a.started_at + make_interval(mins => e.duration_minutes) > now()
    )
$$;

alter table public.profiles enable row level security;
alter table public.exams enable row level security;
alter table public.questions enable row level security;
alter table public.exam_attempts enable row level security;
alter table public.student_answers enable row level security;
alter table public.proctoring_events enable row level security;
alter table public.exam_results enable row level security;
alter table public.notifications enable row level security;

drop policy if exists profile_read_self on public.profiles;
create policy profile_read_self on public.profiles for select to authenticated using (id = auth.uid());
drop policy if exists profile_update_self on public.profiles;
create policy profile_update_self on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
drop policy if exists profile_read_exam_students on public.profiles;
create policy profile_read_exam_students on public.profiles for select to authenticated using (
    exists(select 1 from public.exam_attempts a join public.exams e on e.id = a.exam_id where a.student_id = profiles.id and e.teacher_id = auth.uid())
);

drop policy if exists exam_read_available on public.exams;
create policy exam_read_available on public.exams for select to authenticated using (published or teacher_id = auth.uid());
drop policy if exists exam_teacher_insert on public.exams;
create policy exam_teacher_insert on public.exams for insert to authenticated with check (
    teacher_id = auth.uid() and exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'teacher' and p.teacher_approved)
);
drop policy if exists exam_teacher_update on public.exams;
create policy exam_teacher_update on public.exams for update to authenticated using (
    teacher_id = auth.uid() and exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'teacher' and p.teacher_approved)
) with check (
    teacher_id = auth.uid() and exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'teacher' and p.teacher_approved)
);
drop policy if exists exam_teacher_delete on public.exams;
create policy exam_teacher_delete on public.exams for delete to authenticated using (
    teacher_id = auth.uid() and exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'teacher' and p.teacher_approved)
);

drop policy if exists question_read_available on public.questions;
create policy question_read_available on public.questions for select to authenticated using (
    exists(select 1 from public.exams e where e.id = exam_id and (e.published or e.teacher_id = auth.uid()))
);
drop policy if exists question_teacher_write on public.questions;
create policy question_teacher_write on public.questions for all to authenticated using (
    public.owns_exam(exam_id) and exists(select 1 from public.exams e where e.id = exam_id and not e.published)
) with check (
    public.owns_exam(exam_id) and exists(select 1 from public.exams e where e.id = exam_id and not e.published)
);

drop policy if exists attempts_read_owner_or_teacher on public.exam_attempts;
create policy attempts_read_owner_or_teacher on public.exam_attempts for select to authenticated using (student_id = auth.uid() or exists(select 1 from public.exams e where e.id = exam_id and e.teacher_id = auth.uid()));
drop policy if exists attempts_student_insert on public.exam_attempts;
create policy attempts_student_insert on public.exam_attempts for insert to authenticated with check (student_id = auth.uid() and exists(select 1 from public.exams e where e.id = exam_id and e.published));
drop policy if exists attempts_student_update on public.exam_attempts;
create policy attempts_student_update on public.exam_attempts for update to authenticated using (student_id = auth.uid()) with check (student_id = auth.uid());

drop policy if exists answers_read_owner_or_teacher on public.student_answers;
create policy answers_read_owner_or_teacher on public.student_answers for select to authenticated using (public.owns_attempt(attempt_id) or public.teaches_attempt(attempt_id));
drop policy if exists answers_student_write on public.student_answers;
create policy answers_student_write on public.student_answers for all to authenticated using (public.owns_attempt(attempt_id) and public.is_attempt_open(attempt_id)) with check (public.owns_attempt(attempt_id) and public.is_attempt_open(attempt_id));
drop policy if exists answers_teacher_grade on public.student_answers;

drop policy if exists events_read_owner_or_teacher on public.proctoring_events;
create policy events_read_owner_or_teacher on public.proctoring_events for select to authenticated using (public.owns_attempt(attempt_id) or public.teaches_attempt(attempt_id));
drop policy if exists events_student_insert on public.proctoring_events;
create policy events_student_insert on public.proctoring_events for insert to authenticated with check (public.owns_attempt(attempt_id) and public.is_attempt_open(attempt_id));

drop policy if exists results_read_owner_or_teacher on public.exam_results;
create policy results_read_owner_or_teacher on public.exam_results for select to authenticated using (
    (student_id = auth.uid() and published) or exists(select 1 from public.exams e where e.id = exam_id and e.teacher_id = auth.uid())
);
drop policy if exists notifications_read_own on public.notifications;
create policy notifications_read_own on public.notifications for select to authenticated using (user_id = auth.uid());
drop policy if exists notifications_update_own on public.notifications;
create policy notifications_update_own on public.notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('question-papers', 'question-papers', false, 10485760, array['application/pdf'])
on conflict (id) do nothing;
drop policy if exists question_papers_teacher_upload on storage.objects;
create policy question_papers_teacher_upload on storage.objects for insert to authenticated with check (
    bucket_id = 'question-papers' and (storage.foldername(name))[1] = auth.uid()::text and
    exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'teacher' and p.teacher_approved)
);
drop policy if exists question_papers_owner_read on storage.objects;
create policy question_papers_owner_read on storage.objects for select to authenticated using (
    bucket_id = 'question-papers' and (owner_id = auth.uid()::text or exists(select 1 from public.exams e where e.question_paper_path = name and e.teacher_id = auth.uid()))
);
