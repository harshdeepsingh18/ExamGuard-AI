-- Teacher may read student names only when they have a result for one of their own exams.
create policy profile_teacher_result_read on public.profiles for select to authenticated
using (exists(select 1 from public.results r join public.exams e on e.id=r.exam_id where r.student_id=profiles.id and e.teacher_id=auth.uid()));
