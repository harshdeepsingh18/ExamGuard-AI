-- ExamGuard AI repair, step 2 of 4: role constraints, RLS and grants.
-- Run after 01_create_exam_tables.sql. Existing profile rows and the
-- "Users can view own profile" policy are preserved.
begin;

do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='requested_role')
     or not exists (select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='teacher_approved') then
    raise exception 'Expected existing profile authorization columns are missing';
  end if;
  if exists(select 1 from public.profiles where role not in ('student','teacher','admin') or requested_role not in ('student','teacher')) then
    raise exception 'Unexpected profile role data; inspect before repairing constraints';
  end if;
  if exists(select 1 from public.profiles where teacher_status not in ('none','pending','approved','rejected')) then
    raise exception 'Unexpected teacher_status data; inspect before repairing constraints';
  end if;
  if exists(select 1 from pg_policies where schemaname='public'
    and tablename in ('profiles','teacher_requests','exams','questions','exam_attempts','student_answers','results','notifications','platform_settings')
    and policyname not in ('Users can view own profile','profile_read','profile_update','profile_teacher_result_read','request_read','request_admin_update','exam_read','exam_insert','exam_update','exam_delete','question_teacher_all','attempts_read','results_read','result_publish','answers_read','notification_self','settings_read','settings_admin_write')) then
    raise exception 'Unrecognized RLS policy found on an ExamGuard table; inspect it before replacing the policy set';
  end if;
  if exists(select 1 from pg_constraint where conrelid='public.profiles'::regclass and contype='c'
    and conname not in ('profiles_role_check','profiles_requested_role_check','profiles_teacher_status_check','profiles_role_repair_check')
    and pg_get_constraintdef(oid) ilike '%role%') then
    raise exception 'Unrecognized profile role constraint; inspect before continuing';
  end if;
end $$;
do $$ begin
 if not exists(select 1 from pg_constraint where conrelid='public.profiles'::regclass and conname='profiles_teacher_status_check') then
   alter table public.profiles add constraint profiles_teacher_status_check check(teacher_status in ('none','pending','approved','rejected'));
 elsif (select pg_get_constraintdef(oid) from pg_constraint where conrelid='public.profiles'::regclass and conname='profiles_teacher_status_check') not ilike '%teacher_status%none%pending%approved%rejected%' then
   raise exception 'Existing profiles_teacher_status_check differs from the supported status set';
 end if;
end $$;

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles drop constraint if exists profiles_role_repair_check;
alter table public.profiles add constraint profiles_role_check check(role in ('student','teacher','admin'));
-- Keep the existing requested_role constraint intact; add it only if absent.
do $$ begin
 if exists(select 1 from pg_constraint where conrelid='public.profiles'::regclass and conname='profiles_requested_role_check'
    and pg_get_constraintdef(oid) not ilike '%requested_role%student%teacher%') then
   raise exception 'Existing profiles_requested_role_check differs from the student/teacher constraint';
 end if;
 if not exists(select 1 from pg_constraint where conrelid='public.profiles'::regclass and conname='profiles_requested_role_check') then
   alter table public.profiles add constraint profiles_requested_role_check check(requested_role in ('student','teacher'));
 end if;
end $$;

create or replace function public.current_role() returns text language sql stable security definer set search_path='' as $$ select p.role from public.profiles p where p.id=auth.uid() $$;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path='' as $$ select coalesce(public.current_role()='admin',false) $$;
create or replace function public.is_approved_teacher() returns boolean language sql stable security definer set search_path='' as $$ select coalesce(exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='teacher' and p.teacher_status='approved' and p.teacher_approved),false) $$;

alter table public.profiles enable row level security;
alter table public.teacher_requests enable row level security;
alter table public.exams enable row level security;
alter table public.questions enable row level security;
alter table public.exam_attempts enable row level security;
alter table public.student_answers enable row level security;
alter table public.results enable row level security;
alter table public.notifications enable row level security;
alter table public.platform_settings enable row level security;

-- Replace only ExamGuard-owned policy names, retaining user-created policies.
drop policy if exists profile_read on public.profiles;
drop policy if exists profile_update on public.profiles;
drop policy if exists profile_teacher_result_read on public.profiles;
drop policy if exists request_read on public.teacher_requests;
drop policy if exists request_admin_update on public.teacher_requests;
drop policy if exists exam_read on public.exams;
drop policy if exists exam_insert on public.exams;
drop policy if exists exam_update on public.exams;
drop policy if exists exam_delete on public.exams;
drop policy if exists question_teacher_all on public.questions;
drop policy if exists attempts_read on public.exam_attempts;
drop policy if exists results_read on public.results;
drop policy if exists result_publish on public.results;
drop policy if exists answers_read on public.student_answers;
drop policy if exists notification_self on public.notifications;
drop policy if exists settings_read on public.platform_settings;
drop policy if exists settings_admin_write on public.platform_settings;

-- Preserve legacy own-profile read policy; this additional policy adds admin reads.
create policy profile_read on public.profiles for select to authenticated using(id=auth.uid() or public.is_admin());
create policy profile_update on public.profiles for update to authenticated using(id=auth.uid() or public.is_admin()) with check(id=auth.uid() or public.is_admin());
create policy profile_teacher_result_read on public.profiles for select to authenticated using(exists(select 1 from public.results r join public.exams e on e.id=r.exam_id where r.student_id=profiles.id and e.teacher_id=auth.uid() and public.is_approved_teacher()));
create policy request_read on public.teacher_requests for select to authenticated using(user_id=auth.uid() or public.is_admin());
create policy request_admin_update on public.teacher_requests for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy exam_read on public.exams for select to authenticated using(published or teacher_id=auth.uid() or public.is_admin());
create policy exam_insert on public.exams for insert to authenticated with check((teacher_id=auth.uid() and public.is_approved_teacher()) or public.is_admin());
create policy exam_update on public.exams for update to authenticated using((teacher_id=auth.uid() and public.is_approved_teacher()) or public.is_admin()) with check((teacher_id=auth.uid() and public.is_approved_teacher()) or public.is_admin());
create policy exam_delete on public.exams for delete to authenticated using((teacher_id=auth.uid() and public.is_approved_teacher()) or public.is_admin());
create policy question_teacher_all on public.questions for all to authenticated using(exists(select 1 from public.exams e where e.id=exam_id and ((e.teacher_id=auth.uid() and public.is_approved_teacher()) or public.is_admin()))) with check(exists(select 1 from public.exams e where e.id=exam_id and ((e.teacher_id=auth.uid() and public.is_approved_teacher()) or public.is_admin())));
create policy attempts_read on public.exam_attempts for select to authenticated using(student_id=auth.uid() or (public.is_approved_teacher() and exists(select 1 from public.exams e where e.id=exam_id and e.teacher_id=auth.uid())) or public.is_admin());
create policy results_read on public.results for select to authenticated using((student_id=auth.uid() and published) or (public.is_approved_teacher() and exists(select 1 from public.exams e where e.id=exam_id and e.teacher_id=auth.uid())) or public.is_admin());
create policy result_publish on public.results for update to authenticated using(exists(select 1 from public.exams e where e.id=exam_id and ((e.teacher_id=auth.uid() and public.is_approved_teacher()) or public.is_admin()))) with check(exists(select 1 from public.exams e where e.id=exam_id and ((e.teacher_id=auth.uid() and public.is_approved_teacher()) or public.is_admin())));
create policy answers_read on public.student_answers for select to authenticated using(exists(select 1 from public.exam_attempts a where a.id=attempt_id and (a.student_id=auth.uid() or (public.is_approved_teacher() and exists(select 1 from public.exams e where e.id=a.exam_id and e.teacher_id=auth.uid())) or public.is_admin())));
create policy notification_self on public.notifications for all to authenticated using(user_id=auth.uid() or public.is_admin()) with check(user_id=auth.uid() or public.is_admin());
create policy settings_read on public.platform_settings for select to authenticated using(true);
create policy settings_admin_write on public.platform_settings for all to authenticated using(public.is_admin()) with check(public.is_admin());

grant usage on schema public to authenticated;
grant select,update on public.profiles to authenticated;
grant select,update on public.teacher_requests to authenticated;
grant select,insert,update,delete on public.exams,public.questions to authenticated;
grant select on public.exam_attempts,public.student_answers to authenticated;
grant select,update(published) on public.results to authenticated;
grant select,insert,update,delete on public.notifications,public.platform_settings to authenticated;
revoke all on public.profiles,public.teacher_requests,public.exams,public.questions,public.exam_attempts,public.student_answers,public.results,public.notifications,public.platform_settings from anon;
revoke insert,delete on public.profiles,public.teacher_requests from authenticated;
revoke insert,update,delete on public.exam_attempts,public.student_answers from authenticated;
revoke insert,update,delete on public.results from authenticated;
revoke update(score,max_score,percentage,passed,attempt_id,student_id,exam_id,created_at,updated_at) on public.results from authenticated;
revoke all on function public.current_role() from public,anon;
revoke all on function public.is_admin() from public,anon;
revoke all on function public.is_approved_teacher() from public,anon;
grant execute on function public.current_role(),public.is_admin(),public.is_approved_teacher() to authenticated;

notify pgrst,'reload schema';
commit;
