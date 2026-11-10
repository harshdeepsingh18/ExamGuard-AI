-- Creates the report table used by ExamRoom.jsx and Admin.jsx.
-- Run the complete file in Supabase SQL Editor. It does not touch PDF objects.
begin;

do $$
begin
  if to_regclass('public.exams') is null or to_regclass('public.profiles') is null then
    raise exception 'Create or repair public.exams and public.profiles before this report table';
  end if;
  if to_regprocedure('public.current_role()') is null or to_regprocedure('public.is_admin()') is null then
    raise exception 'ExamGuard current_role() and is_admin() functions must exist before applying report policies';
  end if;
end;
$$;

create table if not exists public.exam_pdf_reports (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null constraint exam_pdf_reports_exam_id_fkey
    references public.exams(id) on delete cascade,
  reporter_id uuid not null constraint exam_pdf_reports_reporter_id_fkey
    references public.profiles(id) on delete cascade,
  reason text not null constraint exam_pdf_reports_reason_check
    check (length(btrim(reason)) between 5 and 1000),
  status text not null default 'pending' constraint exam_pdf_reports_status_check
    check (status in ('pending','reviewed','dismissed')),
  admin_note text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);

create index if not exists exam_pdf_reports_status_created
  on public.exam_pdf_reports(status,created_at desc);
create index if not exists exam_pdf_reports_exam
  on public.exam_pdf_reports(exam_id,created_at desc);
create index if not exists exam_pdf_reports_reporter_created
  on public.exam_pdf_reports(reporter_id,created_at desc);

alter table public.exam_pdf_reports enable row level security;

-- Keep any unrelated policies intact. Refuse to replace unknown report policies.
do $$
begin
  if exists(select 1 from pg_policies where schemaname='public'
    and tablename='exam_pdf_reports'
    and policyname not in ('exam_pdf_reports_read','exam_pdf_reports_submit','exam_pdf_reports_admin_update')) then
    raise exception 'Unrecognized policy exists on public.exam_pdf_reports; inspect it before continuing';
  end if;
end;
$$;

drop policy if exists exam_pdf_reports_read on public.exam_pdf_reports;
drop policy if exists exam_pdf_reports_submit on public.exam_pdf_reports;
drop policy if exists exam_pdf_reports_admin_update on public.exam_pdf_reports;

create policy exam_pdf_reports_read on public.exam_pdf_reports
  for select to authenticated
  using (reporter_id=auth.uid() or public.is_admin());

create policy exam_pdf_reports_submit on public.exam_pdf_reports
  for insert to authenticated
  with check (
    reporter_id=auth.uid()
    and public.current_role()='student'
    and status='pending'
    and reviewed_at is null
    and admin_note is null
    and exists(select 1 from public.exams e
      where e.id=public.exam_pdf_reports.exam_id
        and e.exam_type in ('pdf','both')
        and e.pdf_storage_path is not null and e.pdf_enabled and e.published
        and (e.available_from is null or e.available_from<=now())
        and (e.available_until is null or e.available_until>now()))
  );

create policy exam_pdf_reports_admin_update on public.exam_pdf_reports
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

revoke all on public.exam_pdf_reports from public,anon;
grant select,insert,update on public.exam_pdf_reports to authenticated;
revoke delete on public.exam_pdf_reports from authenticated;

notify pgrst,'reload schema';
commit;
