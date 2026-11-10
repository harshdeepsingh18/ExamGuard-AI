-- Additive, repeatable repair for the report fields used by Admin.jsx and ExamRoom.jsx.
-- It preserves existing tables and rows and does not access or expose Storage files.
begin;

do $$
declare required record;
begin
  if to_regclass('public.exams') is null or to_regclass('public.profiles') is null then
    raise exception 'Required public.exams and public.profiles tables must exist first';
  end if;
  if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='exams' and column_name='id' and udt_name='uuid')
     or not exists(select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='id' and udt_name='uuid') then
    raise exception 'public.exams.id and public.profiles.id must be uuid';
  end if;
  if to_regprocedure('public.current_role()') is null or to_regprocedure('public.is_admin()') is null then
    raise exception 'Expected ExamGuard authorization functions are missing';
  end if;
  for required in select * from (values
    ('exam_type','text','NO'),('pdf_storage_path','text','YES'),('pdf_filename','text','YES'),
    ('pdf_size_bytes','int8','YES'),('pdf_enabled','bool','NO'),('published','bool','NO'),
    ('available_from','timestamptz','YES'),('available_until','timestamptz','YES')
  ) as cols(column_name,udt_name,is_nullable)
  loop
    if not exists(select 1 from information_schema.columns c where c.table_schema='public'
      and c.table_name='exams' and c.column_name=required.column_name
      and c.udt_name=required.udt_name and c.is_nullable=required.is_nullable) then
      raise exception 'public.exams is missing required PDF support column %; run migration 202611100008_exam_pdf_support.sql first',required.column_name;
    end if;
  end loop;
  if not exists(select 1 from information_schema.columns where table_schema='public'
    and table_name='profiles' and column_name='full_name' and udt_name='text') then
    raise exception 'public.profiles.full_name text is required for the existing admin report query';
  end if;
end;
$$;

create table if not exists public.exam_pdf_reports (
  id uuid not null default gen_random_uuid(),
  exam_id uuid not null,
  reporter_id uuid not null,
  reason text not null,
  status text not null default 'pending',
  admin_note text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);

-- Fail closed if a pre-existing object with this name has a different shape.
do $$
declare required record;
begin
  for required in select * from (values
    ('id','uuid','NO'),('exam_id','uuid','NO'),('reporter_id','uuid','NO'),
    ('reason','text','NO'),('status','text','NO'),('admin_note','text','YES'),
    ('created_at','timestamptz','NO'),('reviewed_at','timestamptz','YES')
  ) as cols(column_name,udt_name,is_nullable)
  loop
    if not exists(select 1 from information_schema.columns c
      where c.table_schema='public' and c.table_name='exam_pdf_reports'
        and c.column_name=required.column_name and c.udt_name=required.udt_name
        and c.is_nullable=required.is_nullable) then
      raise exception 'public.exam_pdf_reports has an unexpected or missing column: %',required.column_name;
    end if;
  end loop;
end;
$$;

alter table public.exam_pdf_reports alter column id set default gen_random_uuid();
alter table public.exam_pdf_reports alter column status set default 'pending';
alter table public.exam_pdf_reports alter column created_at set default now();

do $$
declare id_att smallint; existing_pk smallint[];
begin
  select attnum into id_att from pg_attribute where attrelid='public.exam_pdf_reports'::regclass and attname='id' and not attisdropped;
  select conkey into existing_pk from pg_constraint where conrelid='public.exam_pdf_reports'::regclass and contype='p';
  if existing_pk is null then
    alter table public.exam_pdf_reports add constraint exam_pdf_reports_pkey primary key(id);
  elsif existing_pk <> array[id_att]::smallint[] then
    raise exception 'public.exam_pdf_reports has a different primary key; inspect before continuing';
  end if;
end;
$$;

do $$
begin
  if not exists(select 1 from pg_constraint where conrelid='public.exam_pdf_reports'::regclass and contype='f'
    and conname='exam_pdf_reports_exam_id_fkey' and confrelid='public.exams'::regclass and confdeltype='c'
    and conkey=array[(select attnum from pg_attribute where attrelid='public.exam_pdf_reports'::regclass and attname='exam_id')]::smallint[]
    and confkey=array[(select attnum from pg_attribute where attrelid='public.exams'::regclass and attname='id')]::smallint[]) then
    if exists(select 1 from pg_constraint where conrelid='public.exam_pdf_reports'::regclass and conname='exam_pdf_reports_exam_id_fkey') then
      raise exception 'exam_pdf_reports_exam_id_fkey exists with an unexpected definition';
    end if;
    alter table public.exam_pdf_reports add constraint exam_pdf_reports_exam_id_fkey
      foreign key(exam_id) references public.exams(id) on delete cascade not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.exam_pdf_reports'::regclass and contype='f'
    and conname='exam_pdf_reports_reporter_id_fkey' and confrelid='public.profiles'::regclass and confdeltype='c'
    and conkey=array[(select attnum from pg_attribute where attrelid='public.exam_pdf_reports'::regclass and attname='reporter_id')]::smallint[]
    and confkey=array[(select attnum from pg_attribute where attrelid='public.profiles'::regclass and attname='id')]::smallint[]) then
    if exists(select 1 from pg_constraint where conrelid='public.exam_pdf_reports'::regclass and conname='exam_pdf_reports_reporter_id_fkey') then
      raise exception 'exam_pdf_reports_reporter_id_fkey exists with an unexpected definition';
    end if;
    alter table public.exam_pdf_reports add constraint exam_pdf_reports_reporter_id_fkey
      foreign key(reporter_id) references public.profiles(id) on delete cascade not valid;
  end if;
  if not (select convalidated from pg_constraint where conrelid='public.exam_pdf_reports'::regclass and conname='exam_pdf_reports_exam_id_fkey') then
    alter table public.exam_pdf_reports validate constraint exam_pdf_reports_exam_id_fkey;
  end if;
  if not (select convalidated from pg_constraint where conrelid='public.exam_pdf_reports'::regclass and conname='exam_pdf_reports_reporter_id_fkey') then
    alter table public.exam_pdf_reports validate constraint exam_pdf_reports_reporter_id_fkey;
  end if;
end;
$$;

do $$
begin
  if exists(select 1 from public.exam_pdf_reports where length(btrim(reason)) not between 5 and 1000
    or status not in ('pending','reviewed','dismissed')) then
    raise exception 'Existing PDF report rows have unsupported reasons or statuses';
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.exam_pdf_reports'::regclass and conname='exam_pdf_reports_reason_check') then
    alter table public.exam_pdf_reports add constraint exam_pdf_reports_reason_check check(length(btrim(reason)) between 5 and 1000);
  elsif (select pg_get_constraintdef(oid) from pg_constraint where conrelid='public.exam_pdf_reports'::regclass and conname='exam_pdf_reports_reason_check') not ilike '%length(btrim(reason))%5%1000%' then
    raise exception 'exam_pdf_reports_reason_check exists with an unexpected definition';
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.exam_pdf_reports'::regclass and conname='exam_pdf_reports_status_check') then
    alter table public.exam_pdf_reports add constraint exam_pdf_reports_status_check check(status in ('pending','reviewed','dismissed'));
  elsif (select pg_get_constraintdef(oid) from pg_constraint where conrelid='public.exam_pdf_reports'::regclass and conname='exam_pdf_reports_status_check') not ilike '%status%pending%reviewed%dismissed%' then
    raise exception 'exam_pdf_reports_status_check exists with an unexpected definition';
  end if;
end;
$$;

create index if not exists exam_pdf_reports_status_created on public.exam_pdf_reports(status,created_at desc);
create index if not exists exam_pdf_reports_exam on public.exam_pdf_reports(exam_id,created_at desc);
create index if not exists exam_pdf_reports_reporter_created on public.exam_pdf_reports(reporter_id,created_at desc);
alter table public.exam_pdf_reports enable row level security;

-- Preserve unknown policies by stopping for manual review. Only the known
-- application policies below are replaced on subsequent runs.
do $$
begin
  if exists(select 1 from pg_policies where schemaname='public' and tablename='exam_pdf_reports'
    and policyname not in ('exam_pdf_reports_read','exam_pdf_reports_submit','exam_pdf_reports_admin_update')) then
    raise exception 'Unrecognized policy exists on public.exam_pdf_reports; inspect before continuing';
  end if;
end;
$$;

drop policy if exists exam_pdf_reports_read on public.exam_pdf_reports;
drop policy if exists exam_pdf_reports_submit on public.exam_pdf_reports;
drop policy if exists exam_pdf_reports_admin_update on public.exam_pdf_reports;
create policy exam_pdf_reports_read on public.exam_pdf_reports for select to authenticated
  using (reporter_id=auth.uid() or public.is_admin());
create policy exam_pdf_reports_submit on public.exam_pdf_reports for insert to authenticated with check (
  reporter_id=auth.uid() and public.current_role()='student' and status='pending'
  and reviewed_at is null and admin_note is null
  and exists(select 1 from public.exams e where e.id=exam_id and e.exam_type='pdf'
    and e.pdf_storage_path is not null and e.pdf_enabled and e.published
    and (e.available_from is null or e.available_from<=now())
    and (e.available_until is null or e.available_until>now()))
);
create policy exam_pdf_reports_admin_update on public.exam_pdf_reports for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

revoke all on public.exam_pdf_reports from public,anon;
grant select,insert,update on public.exam_pdf_reports to authenticated;
revoke delete on public.exam_pdf_reports from authenticated;

notify pgrst,'reload schema';
commit;
