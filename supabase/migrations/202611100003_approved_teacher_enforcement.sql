create or replace function public.is_approved_teacher() returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(exists(select 1 from public.profiles where id=auth.uid() and role='teacher' and teacher_status='approved'),false)
$$;
revoke all on function public.is_approved_teacher() from public; grant execute on function public.is_approved_teacher() to authenticated;
drop policy if exists exam_update on public.exams;
drop policy if exists exam_delete on public.exams;
drop policy if exists question_teacher_all on public.questions;
create policy exam_update on public.exams for update to authenticated using((teacher_id=auth.uid() and public.is_approved_teacher()) or public.is_admin()) with check((teacher_id=auth.uid() and public.is_approved_teacher()) or public.is_admin());
create policy exam_delete on public.exams for delete to authenticated using((teacher_id=auth.uid() and public.is_approved_teacher()) or public.is_admin());
create policy question_teacher_all on public.questions for all to authenticated using(exists(select 1 from public.exams e where e.id=exam_id and ((e.teacher_id=auth.uid() and public.is_approved_teacher()) or public.is_admin()))) with check(exists(select 1 from public.exams e where e.id=exam_id and ((e.teacher_id=auth.uid() and public.is_approved_teacher()) or public.is_admin())));
