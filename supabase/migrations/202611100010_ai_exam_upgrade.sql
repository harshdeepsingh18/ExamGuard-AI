-- Additive monitoring, AI draft, and descriptive grading support.
begin;

alter table public.exams
  add column if not exists monitoring_enabled boolean not null default true,
  add column if not exists camera_required boolean not null default false;

alter table public.questions
  add column if not exists question_type text not null default 'mcq',
  add column if not exists answer_key text not null default '',
  add column if not exists grading_rubric text not null default '';

alter table public.student_answers
  add column if not exists answer_text text;

alter table public.results
  add column if not exists review_status text not null default 'approved',
  add column if not exists ai_suggested_score numeric,
  add column if not exists grading_feedback text,
  add column if not exists grading_reviewed_at timestamptz,
  add column if not exists grading_reviewed_by uuid references public.profiles(id);

do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.questions'::regclass and conname='questions_question_type_check') then
    alter table public.questions add constraint questions_question_type_check
      check(question_type in ('mcq','true_false','fill_blank','short_answer','long_answer'));
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.results'::regclass and conname='results_review_status_check') then
    alter table public.results add constraint results_review_status_check
      check(review_status in ('approved','pending','needs_review','rejected'));
  end if;
end $$;

create table if not exists public.exam_monitoring_events (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null references public.exam_attempts(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  event_type text not null check(event_type in ('tab_hidden','window_blur','camera_started','camera_stopped','face_absent','multiple_people','camera_unsupported','camera_denied')),
  occurred_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb check(jsonb_typeof(metadata)='object'),
  created_at timestamptz not null default now()
);
create index if not exists monitoring_attempt_time on public.exam_monitoring_events(attempt_id,occurred_at);
alter table public.exam_monitoring_events enable row level security;
drop policy if exists monitoring_event_student_insert on public.exam_monitoring_events;
drop policy if exists monitoring_event_teacher_read on public.exam_monitoring_events;
create policy monitoring_event_student_insert on public.exam_monitoring_events for insert to authenticated
  with check(student_id=auth.uid() and exists(
    select 1 from public.exam_attempts a join public.exams e on e.id=a.exam_id
    where a.id=attempt_id and a.student_id=auth.uid() and a.status='in_progress' and e.monitoring_enabled
  ));
create policy monitoring_event_teacher_read on public.exam_monitoring_events for select to authenticated
  using(exists(select 1 from public.exam_attempts a join public.exams e on e.id=a.exam_id
    where a.id=attempt_id and (e.teacher_id=auth.uid() or public.is_admin())));
revoke all on public.exam_monitoring_events from public,anon;
grant select,insert on public.exam_monitoring_events to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('ai-question-sources','ai-question-sources',false,20971520,array['application/pdf']::text[])
on conflict(id) do update set public=false,file_size_limit=20971520,allowed_mime_types=array['application/pdf']::text[];
drop policy if exists ai_source_owner_read on storage.objects;
drop policy if exists ai_source_owner_insert on storage.objects;
drop policy if exists ai_source_owner_delete on storage.objects;
create policy ai_source_owner_read on storage.objects for select to authenticated
  using(bucket_id='ai-question-sources' and name ~ '^[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}/[^/]+[.]pdf$'
    and exists(select 1 from public.exams e where e.id::text=split_part(name,'/',1) and e.teacher_id=auth.uid()));
create policy ai_source_owner_insert on storage.objects for insert to authenticated
  with check(bucket_id='ai-question-sources' and name ~ '^[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}/[^/]+[.]pdf$'
    and split_part(name,'/',2)=auth.uid()::text
    and exists(select 1 from public.exams e where e.id::text=split_part(name,'/',1) and e.teacher_id=auth.uid() and not e.published));
create policy ai_source_owner_delete on storage.objects for delete to authenticated
  using(bucket_id='ai-question-sources' and split_part(name,'/',2)=auth.uid()::text
    and exists(select 1 from public.exams e where e.id::text=split_part(name,'/',1) and e.teacher_id=auth.uid()));

-- AI output remains a teacher-owned draft until reviewed and saved as questions.
create table if not exists public.ai_question_drafts (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.exams(id) on delete cascade,
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  source_storage_path text not null,
  source_filename text not null,
  config jsonb not null default '{}'::jsonb,
  questions jsonb not null default '[]'::jsonb check(jsonb_typeof(questions)='array'),
  status text not null default 'needs_review' check(status in ('needs_review','approved','discarded')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create index if not exists ai_question_drafts_teacher on public.ai_question_drafts(teacher_id,created_at desc);
alter table public.ai_question_drafts enable row level security;
drop policy if exists ai_question_drafts_owner_all on public.ai_question_drafts;
create policy ai_question_drafts_owner_all on public.ai_question_drafts for all to authenticated
  using(teacher_id=auth.uid() and (public.is_approved_teacher() or public.is_admin()))
  with check(teacher_id=auth.uid() and (public.is_approved_teacher() or public.is_admin()) and exists(
    select 1 from public.exams e where e.id=exam_id and e.teacher_id=auth.uid() and e.published=false
  ));
revoke all on public.ai_question_drafts from public,anon;
grant select,insert,update,delete on public.ai_question_drafts to authenticated;

create table if not exists public.ai_grade_suggestions (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null references public.exam_attempts(id) on delete cascade,
  question_id uuid not null references public.questions(id) on delete cascade,
  student_answer text not null,
  suggested_marks numeric not null check(suggested_marks>=0),
  max_marks numeric not null check(max_marks>0),
  explanation text not null,
  confidence text not null check(confidence in ('high','medium','low')),
  status text not null default 'needs_review' check(status in ('needs_review','approved','rejected')),
  reviewed_marks numeric,
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  unique(attempt_id,question_id)
);
alter table public.ai_grade_suggestions enable row level security;
drop policy if exists ai_grade_suggestions_teacher_all on public.ai_grade_suggestions;
create policy ai_grade_suggestions_teacher_all on public.ai_grade_suggestions for all to authenticated
  using(exists(select 1 from public.exam_attempts a join public.exams e on e.id=a.exam_id
    where a.id=attempt_id and (e.teacher_id=auth.uid() or public.is_admin())))
  with check(exists(select 1 from public.exam_attempts a join public.exams e on e.id=a.exam_id
    where a.id=attempt_id and (e.teacher_id=auth.uid() or public.is_admin())));
revoke all on public.ai_grade_suggestions from public,anon;
grant select,insert,update on public.ai_grade_suggestions to authenticated;

-- Extend the existing safe student payload; answer keys stay teacher-only.
create or replace function public.start_exam(p_exam uuid) returns jsonb
language plpgsql security definer set search_path=public as $$
declare e public.exams; aid uuid; qs jsonb;
begin
  if auth.uid() is null or public.current_role() not in ('student','admin') then raise exception 'Student access required'; end if;
  select * into e from public.exams where id=p_exam and published
    and (available_from is null or available_from<=now()) and (available_until is null or available_until>now());
  if not found then raise exception 'Exam unavailable'; end if;
  select id into aid from public.exam_attempts where exam_id=p_exam and student_id=auth.uid() and status='in_progress' limit 1;
  if aid is null then insert into public.exam_attempts(exam_id,student_id) values(p_exam,auth.uid()) returning id into aid; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'prompt',q.prompt,'description',q.description,'options',q.options,
    'points',q.points,'position',q.position,'question_type',q.question_type) order by q.position),'[]'::jsonb)
    into qs from public.questions q where q.exam_id=p_exam;
  return jsonb_build_object('attempt_id',aid,'attempt_started_at',(select started_at from public.exam_attempts where id=aid),
    'saved_answers',(select coalesce(jsonb_agg(jsonb_build_object('question_id',question_id,'selected_answer',selected_answer,'answer_text',answer_text)),'[]'::jsonb) from public.student_answers where attempt_id=aid),
    'exam',jsonb_build_object('id',e.id,'title',e.title,'description',e.description,'duration_minutes',e.duration_minutes,
      'monitoring_enabled',e.monitoring_enabled,'camera_required',e.camera_required), 'questions',qs);
end $$;
revoke all on function public.start_exam(uuid) from public,anon;
grant execute on function public.start_exam(uuid) to authenticated;

create or replace function public.save_exam_answers(p_attempt uuid,p_answers jsonb) returns void
language plpgsql security definer set search_path=public as $$
declare a public.exam_attempts; e public.exams;
begin
  select * into a from public.exam_attempts where id=p_attempt and student_id=auth.uid() and status='in_progress' for update;
  if not found then raise exception 'Attempt unavailable'; end if;
  select * into e from public.exams where id=a.exam_id;
  if now()>a.started_at+make_interval(mins=>e.duration_minutes) then raise exception 'Time limit expired'; end if;
  if jsonb_typeof(p_answers) is distinct from 'array' then raise exception 'Invalid answers'; end if;
  if exists(select 1 from jsonb_array_elements(p_answers) x
    left join public.questions q on q.id=(x->>'question_id')::uuid and q.exam_id=a.exam_id
    where q.id is null or (q.question_type in ('mcq','true_false') and
      ((x->>'selected_answer') is null or (x->>'selected_answer')::int<0 or (x->>'selected_answer')::int>=jsonb_array_length(q.options)))
      or (q.question_type not in ('mcq','true_false') and length(coalesce(x->>'answer_text',''))>10000)) then
    raise exception 'Invalid answer';
  end if;
  insert into public.student_answers(attempt_id,question_id,selected_answer,answer_text)
  select a.id,(x->>'question_id')::uuid,nullif(x->>'selected_answer','')::int,nullif(x->>'answer_text','')
    from jsonb_array_elements(p_answers) x
  on conflict(attempt_id,question_id) do update set selected_answer=excluded.selected_answer,
    answer_text=excluded.answer_text,updated_at=now();
end $$;
revoke all on function public.save_exam_answers(uuid,jsonb) from public,anon;
grant execute on function public.save_exam_answers(uuid,jsonb) to authenticated;

-- MCQs are scored immediately; descriptive items keep the result unpublished and pending review.
create or replace function public.submit_exam(p_attempt uuid,p_answers jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare a public.exam_attempts; e public.exams; s numeric:=0; m numeric:=0; passed boolean; ended_at timestamptz:=now(); has_descriptive boolean;
begin
  select * into a from public.exam_attempts where id=p_attempt and student_id=auth.uid() and status='in_progress' for update;
  if not found then raise exception 'Attempt unavailable or already submitted'; end if;
  select * into e from public.exams where id=a.exam_id;
  if jsonb_typeof(p_answers) is distinct from 'array' then raise exception 'Invalid answers'; end if;
  if ended_at>a.started_at+make_interval(mins=>e.duration_minutes) then
    update public.exam_attempts set status='expired',submitted_at=ended_at,updated_at=ended_at where id=a.id;
    return jsonb_build_object('expired',true);
  end if;
  if e.exam_type='pdf' then
    if e.pdf_storage_path is null or not e.pdf_enabled then raise exception 'Question-paper PDF is unavailable'; end if;
    update public.exam_attempts set status='submitted',submitted_at=ended_at,updated_at=ended_at where id=a.id;
    return jsonb_build_object('submitted',true,'pdf_only',true);
  end if;
  perform public.save_exam_answers(p_attempt,p_answers);
  select coalesce(sum(q.points) filter(where q.question_type in ('mcq','true_false') and sa.selected_answer=q.correct_answer),0),
    coalesce(sum(q.points),0),
    coalesce(bool_or(q.question_type not in ('mcq','true_false')),false)
    into s,m,has_descriptive from public.questions q left join public.student_answers sa
    on sa.question_id=q.id and sa.attempt_id=a.id where q.exam_id=a.exam_id;
  passed:=s>=e.passing_marks;
  update public.exam_attempts set status='submitted',submitted_at=ended_at,updated_at=ended_at where id=a.id;
  insert into public.results(attempt_id,student_id,exam_id,score,max_score,percentage,passed,published,review_status)
    values(a.id,a.student_id,a.exam_id,s,m,case when m>0 then round(s*100/m,2) else 0 end,passed,false,
      case when has_descriptive then 'pending' else 'approved' end)
    on conflict(attempt_id) do update set score=excluded.score,max_score=excluded.max_score,
      percentage=excluded.percentage,passed=excluded.passed,published=false,review_status=excluded.review_status,updated_at=ended_at;
  return jsonb_build_object('score',s,'max_score',m,'percentage',case when m>0 then round(s*100/m,2) else 0 end,
    'passed',passed,'published',false,'review_required',has_descriptive);
end $$;
revoke all on function public.submit_exam(uuid,jsonb) from public,anon;
grant execute on function public.submit_exam(uuid,jsonb) to authenticated;

create or replace function public.review_exam_grade(p_result uuid,p_publish boolean default false) returns void
language plpgsql security definer set search_path=public as $$
declare r public.results; e public.exams; final_score numeric;
begin
  select * into r from public.results where id=p_result for update;
  if not found then raise exception 'Result not found'; end if;
  select * into e from public.exams where id=r.exam_id;
  if not (public.is_admin() or e.teacher_id=auth.uid()) then raise exception 'Exam owner or admin access required'; end if;
  if exists(select 1 from public.questions q join public.student_answers a on a.question_id=q.id
    join public.exam_attempts t on t.id=a.attempt_id where t.id=r.attempt_id
    and q.question_type not in ('mcq','true_false') and nullif(btrim(a.answer_text),'') is not null
    and not exists(select 1 from public.ai_grade_suggestions g where g.attempt_id=r.attempt_id and g.question_id=q.id and g.status in ('approved','rejected')))
  then raise exception 'Review every descriptive answer before publishing'; end if;
  select r.score+coalesce(sum(case when status='approved' then reviewed_marks else 0 end),0)
    into final_score from public.ai_grade_suggestions where attempt_id=r.attempt_id;
  final_score:=coalesce(final_score,r.score);
  update public.results set score=final_score,percentage=case when max_score>0 then round(final_score*100/max_score,2) else 0 end,
    passed=final_score>=e.passing_marks,published=p_publish,
    review_status=case when p_publish then 'approved' else 'pending' end,
    grading_reviewed_at=now(),grading_reviewed_by=auth.uid(),updated_at=now() where id=r.id;
end $$;
revoke all on function public.review_exam_grade(uuid,boolean) from public,anon;
grant execute on function public.review_exam_grade(uuid,boolean) to authenticated;

notify pgrst,'reload schema';
commit;
