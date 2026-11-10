-- ExamGuard AI repair, step 3 of 4: trusted workflow functions and triggers.
-- Run after steps 1 and 2. The profile table and existing profile rows are retained.
begin;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path='' as $$
declare account_type text:=coalesce(new.raw_user_meta_data->>'account_type','student'); display_name text:=coalesce(nullif(btrim(new.raw_user_meta_data->>'full_name'),''),nullif(btrim(new.raw_user_meta_data->>'name'),''),nullif(split_part(coalesce(new.email,''),'@',1),''),'');
begin
 if account_type not in ('student','teacher') then account_type:='student'; end if;
 insert into public.profiles(id,full_name,role,requested_role,teacher_approved,teacher_status) values(new.id,display_name,account_type,account_type,false,case when account_type='teacher' then 'pending' else 'none' end) on conflict(id) do nothing;
 if account_type='teacher' then insert into public.teacher_requests(user_id) values(new.id) on conflict(user_id) do nothing; end if;
 return new;
end $$;

create or replace function public.protect_profile_role() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is not null and not public.is_admin() then
   new.role:=old.role; new.requested_role:=old.requested_role; new.teacher_approved:=old.teacher_approved; new.teacher_status:=old.teacher_status;
 elsif auth.uid() is not null then
   -- Admins may approve/reject but cannot set an inconsistent approval flag.
   new.teacher_approved:=(new.role='teacher' and new.teacher_status='approved');
 end if;
 return new;
end $$;

create or replace function public.start_exam(p_exam uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare e public.exams; a public.exam_attempts; qs jsonb;
begin
 if auth.uid() is null or public.current_role() not in ('student','admin') then raise exception 'Student access required'; end if;
 select * into e from public.exams where id=p_exam and published and (available_from is null or available_from<=now()) and (available_until is null or available_until>now()) for share;
 if not found then raise exception 'Exam unavailable'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_exam::text||':'||auth.uid()::text,0));
 select * into a from public.exam_attempts where exam_id=p_exam and student_id=auth.uid() and status='in_progress' order by started_at desc limit 1 for update;
 if not found then insert into public.exam_attempts(exam_id,student_id,attempt_number) select p_exam,auth.uid(),coalesce(max(attempt_number),0)+1 from public.exam_attempts where exam_id=p_exam and student_id=auth.uid() returning * into a; end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'prompt',q.prompt,'description',q.description,'options',q.options,'points',q.points,'position',q.position) order by q.position),'[]'::jsonb) into qs from public.questions q where q.exam_id=p_exam;
 return jsonb_build_object('attempt_id',a.id,'attempt_started_at',a.started_at,'saved_answers',(select coalesce(jsonb_agg(jsonb_build_object('question_id',sa.question_id,'selected_answer',sa.selected_answer)),'[]'::jsonb) from public.student_answers sa where sa.attempt_id=a.id),'exam',jsonb_build_object('id',e.id,'title',e.title,'description',e.description,'duration_minutes',e.duration_minutes),'questions',qs);
end $$;

create or replace function public.save_exam_answers(p_attempt uuid,p_answers jsonb) returns void language plpgsql security definer set search_path='' as $$
declare a public.exam_attempts; e public.exams;
begin
 select * into a from public.exam_attempts where id=p_attempt and student_id=auth.uid() and status='in_progress' for update;
 if not found then raise exception 'Attempt unavailable'; end if;
 select * into e from public.exams where id=a.exam_id;
 if now()>a.started_at+make_interval(mins=>e.duration_minutes) then raise exception 'Time limit expired'; end if;
 if jsonb_typeof(p_answers) is distinct from 'array' then raise exception 'Invalid answers'; end if;
 if exists(select 1 from jsonb_array_elements(p_answers) x left join public.questions q on q.id=(x->>'question_id')::uuid and q.exam_id=a.exam_id where q.id is null or coalesce((x->>'selected_answer')::integer,-1)<0 or coalesce((x->>'selected_answer')::integer,-1)>=jsonb_array_length(q.options)) then raise exception 'Invalid answer selection'; end if;
 insert into public.student_answers(attempt_id,question_id,selected_answer) select a.id,(x->>'question_id')::uuid,(x->>'selected_answer')::integer from jsonb_array_elements(p_answers) x on conflict(attempt_id,question_id) do update set selected_answer=excluded.selected_answer,updated_at=now();
end $$;

create or replace function public.submit_exam(p_attempt uuid,p_answers jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.exam_attempts; e public.exams; s numeric:=0; m numeric:=0; passed boolean; ended_at timestamptz:=now();
begin
 select * into a from public.exam_attempts where id=p_attempt and student_id=auth.uid() and status='in_progress' for update;
 if not found then raise exception 'Attempt unavailable or already submitted'; end if;
 select * into e from public.exams where id=a.exam_id;
 if jsonb_typeof(p_answers) is distinct from 'array' then raise exception 'Invalid answers'; end if;
 if ended_at>a.started_at+make_interval(mins=>e.duration_minutes) then
   update public.exam_attempts set status='expired',submitted_at=ended_at,time_spent_seconds=e.duration_minutes*60,updated_at=ended_at where id=a.id;
   return jsonb_build_object('expired',true);
 end if;
 perform public.save_exam_answers(p_attempt,p_answers);
 select coalesce(sum(q.points) filter(where sa.selected_answer=q.correct_answer),0),coalesce(sum(q.points),0) into s,m from public.questions q left join public.student_answers sa on sa.question_id=q.id and sa.attempt_id=a.id where q.exam_id=a.exam_id;
 passed:=s>=e.passing_marks;
 update public.exam_attempts set status='submitted',submitted_at=ended_at,time_spent_seconds=greatest(0,extract(epoch from (ended_at-started_at))::integer),score=s,max_score=m,updated_at=ended_at where id=a.id;
 insert into public.results(attempt_id,student_id,exam_id,score,max_score,percentage,passed,published) values(a.id,a.student_id,a.exam_id,s,m,case when m>0 then round(s*100/m,2) else 0 end,passed,false);
 return jsonb_build_object('score',s,'max_score',m,'percentage',case when m>0 then round(s*100/m,2) else 0 end,'passed',passed,'published',false);
end $$;

create or replace function public.review_teacher(p_request uuid,p_approve boolean) returns void language plpgsql security definer set search_path='' as $$
declare uid uuid;
begin
 if not public.is_admin() then raise exception 'Admin access required'; end if;
 update public.teacher_requests set status=case when p_approve then 'approved' else 'rejected' end,reviewed_by=auth.uid(),reviewed_at=now() where id=p_request and status='pending' returning user_id into uid;
 if uid is null then raise exception 'Pending request not found'; end if;
 update public.profiles set role=case when p_approve then 'teacher' else 'student' end,teacher_status=case when p_approve then 'approved' else 'rejected' end,teacher_approved=p_approve where id=uid;
 insert into public.notifications(user_id,title,body) values(uid,'Teacher request reviewed',case when p_approve then 'Your teacher access has been approved.' else 'Your teacher access request was declined.' end);
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();
drop trigger if exists profile_role_guard on public.profiles;
create trigger profile_role_guard before update on public.profiles for each row execute function public.protect_profile_role();

-- Fill only missing auth/profile links; existing profile rows remain untouched.
insert into public.profiles(id,full_name,role,requested_role,teacher_approved,teacher_status)
select u.id,
       coalesce(nullif(btrim(u.raw_user_meta_data->>'full_name'),''),nullif(btrim(u.raw_user_meta_data->>'name'),''),nullif(split_part(coalesce(u.email,''),'@',1),''),''),
       case when u.raw_user_meta_data->>'account_type'='teacher' then 'teacher' else 'student' end,
       case when u.raw_user_meta_data->>'account_type'='teacher' then 'teacher' else 'student' end,
       false,
       case when u.raw_user_meta_data->>'account_type'='teacher' then 'pending' else 'none' end
from auth.users u
where not exists(select 1 from public.profiles p where p.id=u.id)
on conflict(id) do nothing;
insert into public.teacher_requests(user_id)
select p.id from public.profiles p where p.role='teacher' and p.teacher_status='pending'
on conflict(user_id) do nothing;

revoke all on function public.handle_new_user(),public.protect_profile_role() from public,anon,authenticated;
revoke all on function public.start_exam(uuid),public.save_exam_answers(uuid,jsonb),public.submit_exam(uuid,jsonb),public.review_teacher(uuid,boolean) from public,anon;
grant execute on function public.start_exam(uuid),public.save_exam_answers(uuid,jsonb),public.submit_exam(uuid,jsonb),public.review_teacher(uuid,boolean) to authenticated;

notify pgrst,'reload schema';
commit;
