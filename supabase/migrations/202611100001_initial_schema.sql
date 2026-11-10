-- ExamGuard AI initial schema. Apply in Supabase SQL Editor.
create extension if not exists pgcrypto;
create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 full_name text not null default '', role text not null default 'student' check (role in ('student','teacher','admin')),
 teacher_status text not null default 'none' check (teacher_status in ('none','pending','approved','rejected')),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.teacher_requests (
 id uuid primary key default gen_random_uuid(), user_id uuid not null unique references public.profiles(id) on delete cascade,
 status text not null default 'pending' check (status in ('pending','approved','rejected')),
 note text, reviewed_by uuid references public.profiles(id), reviewed_at timestamptz, created_at timestamptz not null default now()
);
create table public.exams (
 id uuid primary key default gen_random_uuid(), teacher_id uuid not null references public.profiles(id),
 title text not null, description text not null default '', duration_minutes int not null check(duration_minutes between 1 and 600),
 passing_marks numeric not null default 0 check(passing_marks >= 0), available_from timestamptz, available_until timestamptz,
 published boolean not null default false, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 check(available_until is null or available_from is null or available_until > available_from)
);
create table public.questions (
 id uuid primary key default gen_random_uuid(), exam_id uuid not null references public.exams(id) on delete cascade,
 prompt text not null, description text not null default '', options jsonb not null check(jsonb_typeof(options)='array' and jsonb_array_length(options)>=2),
 correct_answer int not null check(correct_answer>=0), points numeric not null default 1 check(points>0), position int not null default 0, created_at timestamptz not null default now()
);
create table public.exam_attempts (
 id uuid primary key default gen_random_uuid(), exam_id uuid not null references public.exams(id), student_id uuid not null references public.profiles(id),
 started_at timestamptz not null default now(), submitted_at timestamptz, status text not null default 'in_progress' check(status in ('in_progress','submitted','expired')),
 unique(exam_id, student_id, id)
);
create table public.student_answers (
 id uuid primary key default gen_random_uuid(), attempt_id uuid not null references public.exam_attempts(id) on delete cascade,
 question_id uuid not null references public.questions(id), selected_answer int, updated_at timestamptz not null default now(), unique(attempt_id,question_id)
);
create table public.results (
 id uuid primary key default gen_random_uuid(), attempt_id uuid not null unique references public.exam_attempts(id) on delete cascade,
 student_id uuid not null references public.profiles(id), exam_id uuid not null references public.exams(id), score numeric not null,
 max_score numeric not null, passed boolean not null, created_at timestamptz not null default now()
);
create table public.notifications (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
 title text not null, body text not null default '', read_at timestamptz, created_at timestamptz not null default now()
);
create table public.platform_settings (
 key text primary key, value jsonb not null default '{}'::jsonb, updated_at timestamptz not null default now()
);
create index exams_published_window on public.exams(published,available_from,available_until);
create index exams_teacher on public.exams(teacher_id,created_at desc);
create index questions_exam_position on public.questions(exam_id,position);
create index attempts_student on public.exam_attempts(student_id,started_at desc);
create index attempts_exam on public.exam_attempts(exam_id,status);
create index results_student on public.results(student_id,created_at desc);
create index notifications_user on public.notifications(user_id,created_at desc);

create or replace function public.current_role() returns text language sql stable security definer set search_path=public as $$ select role from public.profiles where id=auth.uid() $$;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$ select coalesce(public.current_role()='admin',false) $$;
revoke all on function public.current_role() from public; grant execute on function public.current_role() to authenticated;
revoke all on function public.is_admin() from public; grant execute on function public.is_admin() to authenticated;

-- Signup role is chosen from user metadata, but admin cannot be self-assigned.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
 account_type text := coalesce(new.raw_user_meta_data->>'account_type', 'student');
 display_name text := coalesce(
  new.raw_user_meta_data->>'full_name',
  new.raw_user_meta_data->>'name',
  split_part(coalesce(new.email, ''), '@', 1),
  ''
 );
begin
 -- Public signup metadata can request student or pending teacher only; it cannot grant admin.
 if account_type not in ('student', 'teacher') then account_type := 'student'; end if;
 insert into public.profiles(id,full_name,role,teacher_status)
 values(new.id,display_name,account_type,case when account_type='teacher' then 'pending' else 'none' end)
 on conflict (id) do nothing;
 if account_type='teacher' then
  insert into public.teacher_requests(user_id) values(new.id) on conflict (user_id) do nothing;
 end if;
 return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();
create or replace function public.protect_profile_role() returns trigger language plpgsql as $$ begin
 if auth.uid() is not null and not public.is_admin() then new.role:=old.role; new.teacher_status:=old.teacher_status; end if; new.updated_at:=now(); return new; end $$;
create trigger profile_role_guard before update on public.profiles for each row execute function public.protect_profile_role();

alter table public.profiles enable row level security; alter table public.teacher_requests enable row level security; alter table public.exams enable row level security; alter table public.questions enable row level security; alter table public.exam_attempts enable row level security; alter table public.student_answers enable row level security; alter table public.results enable row level security; alter table public.notifications enable row level security; alter table public.platform_settings enable row level security;
create policy profile_read on public.profiles for select to authenticated using(id=auth.uid() or public.is_admin());
create policy profile_update on public.profiles for update to authenticated using(id=auth.uid() or public.is_admin()) with check(id=auth.uid() or public.is_admin());
create policy request_read on public.teacher_requests for select to authenticated using(user_id=auth.uid() or public.is_admin());
create policy request_admin_update on public.teacher_requests for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy exam_read on public.exams for select to authenticated using(published or teacher_id=auth.uid() or public.is_admin());
create policy exam_insert on public.exams for insert to authenticated with check(teacher_id=auth.uid() and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='teacher' and p.teacher_status='approved'));
create policy exam_update on public.exams for update to authenticated using(teacher_id=auth.uid() and public.current_role()='teacher' or public.is_admin()) with check(teacher_id=auth.uid() and public.current_role()='teacher' or public.is_admin());
create policy exam_delete on public.exams for delete to authenticated using(teacher_id=auth.uid() and public.current_role()='teacher' or public.is_admin());
create policy question_teacher_all on public.questions for all to authenticated using(exists(select 1 from public.exams e where e.id=exam_id and (e.teacher_id=auth.uid() and public.current_role()='teacher' or public.is_admin()))) with check(exists(select 1 from public.exams e where e.id=exam_id and (e.teacher_id=auth.uid() and public.current_role()='teacher' or public.is_admin())));
create policy attempts_read on public.exam_attempts for select to authenticated using(student_id=auth.uid() or exists(select 1 from public.exams e where e.id=exam_id and e.teacher_id=auth.uid()) or public.is_admin());
create policy results_read on public.results for select to authenticated using(student_id=auth.uid() or exists(select 1 from public.exams e where e.id=exam_id and e.teacher_id=auth.uid()) or public.is_admin());
create policy answers_read on public.student_answers for select to authenticated using(exists(select 1 from public.exam_attempts a where a.id=attempt_id and (a.student_id=auth.uid() or exists(select 1 from public.exams e where e.id=a.exam_id and e.teacher_id=auth.uid()) or public.is_admin())));
create policy notification_self on public.notifications for all to authenticated using(user_id=auth.uid() or public.is_admin()) with check(user_id=auth.uid() or public.is_admin());
create policy settings_read on public.platform_settings for select to authenticated using(true);
create policy settings_admin_write on public.platform_settings for all to authenticated using(public.is_admin()) with check(public.is_admin());

-- Start attempt and return exam content without answer keys. Questions table has no student SELECT policy.
create or replace function public.start_exam(p_exam uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare e public.exams; aid uuid; qs jsonb; begin
 if auth.uid() is null or public.current_role() not in ('student','admin') then raise exception 'Student access required'; end if;
 select * into e from public.exams where id=p_exam and published and (available_from is null or available_from<=now()) and (available_until is null or available_until>now());
 if not found then raise exception 'Exam unavailable'; end if;
 select id into aid from public.exam_attempts where exam_id=p_exam and student_id=auth.uid() and status='in_progress' limit 1;
 if aid is null then insert into public.exam_attempts(exam_id,student_id) values(p_exam,auth.uid()) returning id into aid; end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'prompt',q.prompt,'description',q.description,'options',q.options,'points',q.points,'position',q.position) order by q.position),'[]'::jsonb) into qs from public.questions q where q.exam_id=p_exam;
 return jsonb_build_object('attempt_id',aid,'attempt_started_at',(select started_at from public.exam_attempts where id=aid),'saved_answers',(select coalesce(jsonb_agg(jsonb_build_object('question_id',question_id,'selected_answer',selected_answer)),'[]'::jsonb) from public.student_answers where attempt_id=aid),'exam',jsonb_build_object('id',e.id,'title',e.title,'description',e.description,'duration_minutes',e.duration_minutes),'questions',qs);
end $$;
revoke all on function public.start_exam(uuid) from public; grant execute on function public.start_exam(uuid) to authenticated;
create or replace function public.submit_exam(p_attempt uuid,p_answers jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare a public.exam_attempts; e public.exams; score numeric:=0; maxscore numeric:=0; passed boolean; begin
 select * into a from public.exam_attempts where id=p_attempt and student_id=auth.uid() and status='in_progress' for update;
 if not found then raise exception 'Attempt unavailable'; end if;
 select * into e from public.exams where id=a.exam_id;
 if now()>a.started_at + make_interval(mins=>e.duration_minutes) then update public.exam_attempts set status='expired',submitted_at=now() where id=a.id; raise exception 'Time limit expired'; end if;
 if jsonb_typeof(p_answers)<>'array' then raise exception 'Invalid answers'; end if;
 insert into public.student_answers(attempt_id,question_id,selected_answer)
 select a.id,(x->>'question_id')::uuid,(x->>'selected_answer')::int from jsonb_array_elements(p_answers) x
 on conflict(attempt_id,question_id) do update set selected_answer=excluded.selected_answer,updated_at=now();
 select coalesce(sum(q.points) filter(where sa.selected_answer=q.correct_answer),0),coalesce(sum(q.points),0) into score,maxscore from public.questions q left join public.student_answers sa on sa.question_id=q.id and sa.attempt_id=a.id where q.exam_id=a.exam_id;
 passed:=score>=e.passing_marks;
 update public.exam_attempts set status='submitted',submitted_at=now() where id=a.id;
 insert into public.results(attempt_id,student_id,exam_id,score,max_score,passed) values(a.id,a.student_id,a.exam_id,score,maxscore,passed)
 on conflict(attempt_id) do update set score=excluded.score,max_score=excluded.max_score,passed=excluded.passed;
 return jsonb_build_object('score',score,'max_score',maxscore,'passed',passed);
end $$;
revoke all on function public.submit_exam(uuid,jsonb) from public; grant execute on function public.submit_exam(uuid,jsonb) to authenticated;

-- Teacher approvals are transactional and admin-only.
create or replace function public.review_teacher(p_request uuid,p_approve boolean) returns void language plpgsql security definer set search_path=public as $$
declare uid uuid; begin if not public.is_admin() then raise exception 'Admin access required'; end if;
 update public.teacher_requests set status=case when p_approve then 'approved' else 'rejected' end,reviewed_by=auth.uid(),reviewed_at=now() where id=p_request and status='pending' returning user_id into uid;
 if uid is null then raise exception 'Pending request not found'; end if;
 update public.profiles set teacher_status=case when p_approve then 'approved' else 'rejected' end where id=uid;
 insert into public.notifications(user_id,title,body) values(uid,'Teacher request reviewed',case when p_approve then 'Your teacher access has been approved.' else 'Your teacher access request was declined.' end);
end $$;
revoke all on function public.review_teacher(uuid,boolean) from public; grant execute on function public.review_teacher(uuid,boolean) to authenticated;



