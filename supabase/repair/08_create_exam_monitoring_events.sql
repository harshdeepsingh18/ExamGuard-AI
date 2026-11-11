-- Standalone, repeatable repair for exam monitoring events.
begin;

do $$
begin
  if to_regclass('public.profiles') is null
     or to_regclass('public.exams') is null
     or to_regclass('public.exam_attempts') is null then
    raise exception 'public.profiles, public.exams, and public.exam_attempts must exist first';
  end if;

  if to_regprocedure('public.is_admin()') is null
     or to_regprocedure('public.is_approved_teacher()') is null then
    raise exception 'ExamGuard admin and approved-teacher helper functions must exist first';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'exams'
      and column_name = 'monitoring_enabled' and udt_name = 'bool'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'exam_attempts'
      and column_name = 'status' and udt_name = 'text'
  ) then
    raise exception 'Exam monitoring requires exams.monitoring_enabled and exam_attempts.status';
  end if;
end;
$$;

create table if not exists public.exam_monitoring_events (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null references public.exam_attempts(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  event_type text not null
    check (event_type in (
      'tab_hidden',
      'window_blur',
      'camera_started',
      'camera_stopped',
      'face_absent',
      'multiple_people',
      'camera_unsupported',
      'camera_denied'
    )),
  occurred_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz not null default now()
);

do $$
declare
  expected record;
  actual_type text;
  actual_not_null boolean;
  actual_default text;
  definition text;
begin
  for expected in
    select * from (values
      ('id', 'uuid', true, 'gen_random_uuid()'),
      ('attempt_id', 'uuid', true, null),
      ('student_id', 'uuid', true, null),
      ('event_type', 'text', true, null),
      ('occurred_at', 'timestamptz', true, 'now()'),
      ('metadata', 'jsonb', true, '''{}''::jsonb'),
      ('created_at', 'timestamptz', true, 'now()')
    ) as required(column_name, type_name, not_null, default_expression)
  loop
    select t.typname, a.attnotnull, pg_get_expr(d.adbin, d.adrelid)
      into actual_type, actual_not_null, actual_default
    from pg_attribute a
    join pg_type t on t.oid = a.atttypid
    left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
    where a.attrelid = 'public.exam_monitoring_events'::regclass
      and a.attname = expected.column_name
      and a.attnum > 0
      and not a.attisdropped;

    if not found then
      raise exception 'public.exam_monitoring_events is missing column %', expected.column_name;
    end if;
    if actual_type <> expected.type_name or actual_not_null <> expected.not_null then
      raise exception 'public.exam_monitoring_events.% has an incompatible type or nullability', expected.column_name;
    end if;
    if expected.default_expression is not null
       and replace(coalesce(actual_default, ''), ' ', '')
         <> replace(expected.default_expression, ' ', '') then
      raise exception 'public.exam_monitoring_events.% has an incompatible default', expected.column_name;
    end if;
  end loop;

  if not exists (
    select 1
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
    where c.conrelid = 'public.exam_monitoring_events'::regclass
      and c.contype = 'p'
      and cardinality(c.conkey) = 1
      and a.attname = 'id'
  ) then
    raise exception 'public.exam_monitoring_events.id must be the primary key';
  end if;

  if not exists (
    select 1
    from pg_constraint c
    join pg_attribute src on src.attrelid = c.conrelid and src.attnum = c.conkey[1]
    join pg_attribute dst on dst.attrelid = c.confrelid and dst.attnum = c.confkey[1]
    where c.conrelid = 'public.exam_monitoring_events'::regclass
      and c.contype = 'f'
      and cardinality(c.conkey) = 1 and cardinality(c.confkey) = 1
      and src.attname = 'attempt_id'
      and c.confrelid = 'public.exam_attempts'::regclass and dst.attname = 'id'
      and c.confdeltype = 'c'
  ) then
    raise exception 'attempt_id must reference public.exam_attempts(id) ON DELETE CASCADE';
  end if;

  if not exists (
    select 1
    from pg_constraint c
    join pg_attribute src on src.attrelid = c.conrelid and src.attnum = c.conkey[1]
    join pg_attribute dst on dst.attrelid = c.confrelid and dst.attnum = c.confkey[1]
    where c.conrelid = 'public.exam_monitoring_events'::regclass
      and c.contype = 'f'
      and cardinality(c.conkey) = 1 and cardinality(c.confkey) = 1
      and src.attname = 'student_id'
      and c.confrelid = 'public.profiles'::regclass and dst.attname = 'id'
      and c.confdeltype = 'c'
  ) then
    raise exception 'student_id must reference public.profiles(id) ON DELETE CASCADE';
  end if;

  select pg_get_constraintdef(c.oid) into definition
  from pg_constraint c
  where c.conrelid = 'public.exam_monitoring_events'::regclass
    and c.contype = 'c'
    and pg_get_constraintdef(c.oid) ilike '%event_type%';
  if definition is null
     or definition not ilike '%tab_hidden%'
     or definition not ilike '%window_blur%'
     or definition not ilike '%camera_started%'
     or definition not ilike '%camera_stopped%'
     or definition not ilike '%face_absent%'
     or definition not ilike '%multiple_people%'
     or definition not ilike '%camera_unsupported%'
     or definition not ilike '%camera_denied%'
     or length(definition) - length(replace(definition, '''', '')) <> 16 then
    raise exception 'public.exam_monitoring_events has an incompatible event_type constraint';
  end if;

  select pg_get_constraintdef(c.oid) into definition
  from pg_constraint c
  where c.conrelid = 'public.exam_monitoring_events'::regclass
    and c.contype = 'c'
    and pg_get_constraintdef(c.oid) ilike '%metadata%';
  if definition is null
     or definition not ilike '%jsonb_typeof%'
     or definition not ilike '%object%'
     or length(definition) - length(replace(definition, '''', '')) <> 2 then
    raise exception 'public.exam_monitoring_events has an incompatible metadata constraint';
  end if;

  if exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'exam_monitoring_events'
      and policyname not in (
        'monitoring_event_student_insert',
        'monitoring_event_teacher_read',
        'monitoring_event_admin_read'
      )
  ) then
    raise exception 'Unrecognized policy exists on public.exam_monitoring_events; inspect it before continuing';
  end if;
end;
$$;

create index if not exists monitoring_attempt_time
  on public.exam_monitoring_events (attempt_id, occurred_at);

alter table public.exam_monitoring_events enable row level security;

drop policy if exists monitoring_event_student_insert
  on public.exam_monitoring_events;
drop policy if exists monitoring_event_teacher_read
  on public.exam_monitoring_events;
drop policy if exists monitoring_event_admin_read
  on public.exam_monitoring_events;

create policy monitoring_event_student_insert
  on public.exam_monitoring_events
  for insert
  to authenticated
  with check (
    student_id = auth.uid()
    and exists (
      select 1
      from public.exam_attempts a
      join public.exams e on e.id = a.exam_id
      where a.id = exam_monitoring_events.attempt_id
        and a.student_id = auth.uid()
        and a.status = 'in_progress'
        and e.monitoring_enabled
    )
  );

create policy monitoring_event_teacher_read
  on public.exam_monitoring_events
  for select
  to authenticated
  using (
    public.is_approved_teacher()
    and exists (
      select 1
      from public.exam_attempts a
      join public.exams e on e.id = a.exam_id
      where a.id = exam_monitoring_events.attempt_id
        and a.student_id = exam_monitoring_events.student_id
        and e.teacher_id = auth.uid()
    )
  );

create policy monitoring_event_admin_read
  on public.exam_monitoring_events
  for select
  to authenticated
  using (public.is_admin());

revoke all on table public.exam_monitoring_events from public, anon, authenticated;
grant select, insert on table public.exam_monitoring_events to authenticated;

notify pgrst, 'reload schema';
commit;
