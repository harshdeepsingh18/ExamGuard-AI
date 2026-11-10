create or replace function public.save_exam_answers(p_attempt uuid,p_answers jsonb) returns void language plpgsql security definer set search_path=public as $$
declare a public.exam_attempts; e public.exams; begin
 select * into a from public.exam_attempts where id=p_attempt and student_id=auth.uid() and status='in_progress' for update;
 if not found then raise exception 'Attempt unavailable'; end if;
 select * into e from public.exams where id=a.exam_id;
 if now()>a.started_at + make_interval(mins=>e.duration_minutes) then raise exception 'Time limit expired'; end if;
 if jsonb_typeof(p_answers)<>'array' then raise exception 'Invalid answers'; end if;
 if exists(select 1 from jsonb_array_elements(p_answers) x left join public.questions q on q.id=(x->>'question_id')::uuid and q.exam_id=a.exam_id where q.id is null or (x->>'selected_answer')::int<0 or (x->>'selected_answer')::int>=jsonb_array_length(q.options)) then raise exception 'Invalid answer selection'; end if;
 insert into public.student_answers(attempt_id,question_id,selected_answer)
 select a.id,(x->>'question_id')::uuid,(x->>'selected_answer')::int from jsonb_array_elements(p_answers) x
 on conflict(attempt_id,question_id) do update set selected_answer=excluded.selected_answer,updated_at=now();
end $$;
revoke all on function public.save_exam_answers(uuid,jsonb) from public; grant execute on function public.save_exam_answers(uuid,jsonb) to authenticated;
