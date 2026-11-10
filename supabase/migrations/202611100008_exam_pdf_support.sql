-- Private question-paper PDF support. Additive: does not recreate or remove exams,
-- profiles, auth users, results, or any existing application policy.
begin;

alter table public.exams
  add column if not exists exam_type text not null default 'online',
  add column if not exists pdf_storage_path text,
  add column if not exists pdf_filename text,
  add column if not exists pdf_size_bytes bigint,
  add column if not exists pdf_enabled boolean not null default true;

-- Keep submit_exam compatible with the current app workflow across installations
-- that applied migrations without the standalone repair bundle.
alter table public.exam_attempts
  add column if not exists time_spent_seconds integer not null default 0,
  add column if not exists score numeric,
  add column if not exists max_score numeric,
  add column if not exists attempt_number integer not null default 1,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now();
alter table public.results
  add column if not exists percentage numeric not null default 0,
  add column if not exists published boolean not null default false,
  add column if not exists updated_at timestamptz not null default now();

do $$
begin
  if exists (select 1 from public.exams where exam_type not in ('online','pdf')) then
    raise exception 'Existing exams.exam_type values are unsupported; inspect before continuing';
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.exams'::regclass and conname='exams_exam_type_check') then
    alter table public.exams add constraint exams_exam_type_check check (exam_type in ('online','pdf'));
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.exams'::regclass and conname='exams_pdf_metadata_check') then
    alter table public.exams add constraint exams_pdf_metadata_check check (
      (pdf_storage_path is null and pdf_filename is null and pdf_size_bytes is null)
      or (pdf_storage_path is not null and pdf_filename is not null
          and pdf_size_bytes between 1 and 20971520
          and pdf_storage_path like id::text || '/%')
    );
  end if;
end;
$$;

create index if not exists exams_pdf_type on public.exams(exam_type) where pdf_storage_path is not null;

-- Supabase Storage serves only private, 20 MiB PDF objects from this bucket.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('exam-question-papers','exam-question-papers',false,20971520,array['application/pdf']::text[])
on conflict (id) do update set
  name=excluded.name,
  public=false,
  file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

-- Reports are separate from storage authorization. Admins can review a report
-- and disable an attachment without gaining a Storage bypass.
create table if not exists public.exam_pdf_reports (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.exams(id) on delete cascade,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reason text not null check (length(btrim(reason)) between 5 and 1000),
  status text not null default 'pending' check (status in ('pending','reviewed','dismissed')),
  admin_note text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create index if not exists exam_pdf_reports_status_created on public.exam_pdf_reports(status,created_at desc);
create index if not exists exam_pdf_reports_exam on public.exam_pdf_reports(exam_id,created_at desc);

alter table public.exam_pdf_reports enable row level security;
drop policy if exists exam_pdf_reports_read on public.exam_pdf_reports;
drop policy if exists exam_pdf_reports_submit on public.exam_pdf_reports;
drop policy if exists exam_pdf_reports_admin_update on public.exam_pdf_reports;
create policy exam_pdf_reports_read on public.exam_pdf_reports
  for select to authenticated using (reporter_id=auth.uid() or public.is_admin());
create policy exam_pdf_reports_submit on public.exam_pdf_reports
  for insert to authenticated with check (
    reporter_id=auth.uid() and public.current_role()='student'
    and exists (select 1 from public.exams e where e.id=exam_id and e.exam_type='pdf'
      and e.pdf_storage_path is not null and e.pdf_enabled and e.published
      and (e.available_from is null or e.available_from<=now())
      and (e.available_until is null or e.available_until>now()))
  );
create policy exam_pdf_reports_admin_update on public.exam_pdf_reports
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
grant select,insert,update on public.exam_pdf_reports to authenticated;
revoke insert,update,delete on public.exam_pdf_reports from anon;

-- Do not remove other Storage policies. These narrowly scoped policies require
-- the exam UUID to be the first path segment and the exam row to match the object.
drop policy if exists exam_pdf_storage_read on storage.objects;
drop policy if exists exam_pdf_storage_insert on storage.objects;
drop policy if exists exam_pdf_storage_delete on storage.objects;
create policy exam_pdf_storage_read on storage.objects
  for select to authenticated using (
    bucket_id='exam-question-papers' and name ~ '^[0-9a-fA-F-]{36}/[^/]+[.]pdf$'
    and exists (select 1 from public.exams e
      where e.id::text=split_part(name,'/',1) and e.pdf_storage_path=name
        and ((e.teacher_id=auth.uid() and public.is_approved_teacher())
          or (e.exam_type='pdf' and e.pdf_enabled and e.published
            and public.current_role()='student'
            and (e.available_from is null or e.available_from<=now())
            and (e.available_until is null or e.available_until>now()))))
  );
create policy exam_pdf_storage_insert on storage.objects
  for insert to authenticated with check (
    bucket_id='exam-question-papers' and name ~ '^[0-9a-fA-F-]{36}/[^/]+[.]pdf$'
    and exists (select 1 from public.exams e
      where e.id::text=split_part(name,'/',1) and e.exam_type='pdf'
        and e.teacher_id=auth.uid() and public.is_approved_teacher())
  );
create policy exam_pdf_storage_delete on storage.objects
  for delete to authenticated using (
    bucket_id='exam-question-papers' and name ~ '^[0-9a-fA-F-]{36}/[^/]+[.]pdf$'
    and exists (select 1 from public.exams e
      where e.id::text=split_part(name,'/',1) and e.exam_type='pdf'
        and e.teacher_id=auth.uid() and public.is_approved_teacher())
  );

create or replace function public.guard_exam_content_type() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.published then
    if new.exam_type='pdf' and (new.pdf_storage_path is null or not new.pdf_enabled) then
      raise exception 'Upload and enable a question-paper PDF before publishing this exam';
    elsif new.exam_type='online' and not exists(select 1 from public.questions q where q.exam_id=new.id) then
      raise exception 'Add at least one online question before publishing this exam';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists exams_content_type_guard on public.exams;
create trigger exams_content_type_guard before insert or update of published,exam_type,pdf_storage_path,pdf_enabled
  on public.exams for each row execute function public.guard_exam_content_type();

create or replace function public.guard_question_exam_type() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from public.exams e where e.id=new.exam_id and e.exam_type='pdf') then
    raise exception 'PDF-only exams do not accept online questions';
  end if;
  return new;
end $$;
drop trigger if exists questions_exam_type_guard on public.questions;
create trigger questions_exam_type_guard before insert or update of exam_id on public.questions
  for each row execute function public.guard_question_exam_type();

-- PDF-only submissions are recorded as completed attempts, not falsely graded
-- as zero-point online tests. Online exam scoring and answer validation remain intact.
create or replace function public.submit_exam(p_attempt uuid,p_answers jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a public.exam_attempts; e public.exams; s numeric:=0; m numeric:=0; passed boolean; ended_at timestamptz:=now();
begin
  select * into a from public.exam_attempts
    where id=p_attempt and student_id=auth.uid() and status='in_progress' for update;
  if not found then raise exception 'Attempt unavailable or already submitted'; end if;
  select * into e from public.exams where id=a.exam_id;
  if jsonb_typeof(p_answers) is distinct from 'array' then raise exception 'Invalid answers'; end if;
  if ended_at>a.started_at+make_interval(mins=>e.duration_minutes) then
    update public.exam_attempts set status='expired',submitted_at=ended_at,
      time_spent_seconds=e.duration_minutes*60,updated_at=ended_at where id=a.id;
    return jsonb_build_object('expired',true);
  end if;
  if e.exam_type='pdf' then
    if e.pdf_storage_path is null or not e.pdf_enabled then raise exception 'Question-paper PDF is unavailable'; end if;
    update public.exam_attempts set status='submitted',submitted_at=ended_at,
      time_spent_seconds=greatest(0,extract(epoch from (ended_at-started_at))::integer),updated_at=ended_at
      where id=a.id;
    return jsonb_build_object('submitted',true,'pdf_only',true);
  end if;
  perform public.save_exam_answers(p_attempt,p_answers);
  select coalesce(sum(q.points) filter(where sa.selected_answer=q.correct_answer),0),
         coalesce(sum(q.points),0) into s,m
    from public.questions q left join public.student_answers sa
      on sa.question_id=q.id and sa.attempt_id=a.id where q.exam_id=a.exam_id;
  passed:=s>=e.passing_marks;
  update public.exam_attempts set status='submitted',submitted_at=ended_at,
    time_spent_seconds=greatest(0,extract(epoch from (ended_at-started_at))::integer),
    score=s,max_score=m,updated_at=ended_at where id=a.id;
  insert into public.results(attempt_id,student_id,exam_id,score,max_score,percentage,passed,published)
    values(a.id,a.student_id,a.exam_id,s,m,case when m>0 then round(s*100/m,2) else 0 end,passed,false)
    on conflict(attempt_id) do update set score=excluded.score,max_score=excluded.max_score,
      percentage=excluded.percentage,passed=excluded.passed,updated_at=ended_at;
  return jsonb_build_object('score',s,'max_score',m,
    'percentage',case when m>0 then round(s*100/m,2) else 0 end,'passed',passed,'published',false);
end $$;
revoke all on function public.submit_exam(uuid,jsonb) from public,anon;
grant execute on function public.submit_exam(uuid,jsonb) to authenticated;
revoke all on function public.guard_exam_content_type() from public,anon,authenticated;
revoke all on function public.guard_question_exam_type() from public,anon,authenticated;

notify pgrst,'reload schema';
commit;
