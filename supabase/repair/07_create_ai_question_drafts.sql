-- Standalone repair: create AI question drafts without replacing existing tables or rows.
begin;

do $$
begin
  if to_regclass('public.profiles') is null
     or to_regclass('public.exams') is null then
    raise exception 'public.profiles and public.exams must exist before creating AI question drafts';
  end if;

  if to_regprocedure('public.is_admin()') is null
     or to_regprocedure('public.is_approved_teacher()') is null then
    raise exception 'ExamGuard admin and approved-teacher helper functions must exist first';
  end if;
end;
$$;

create table if not exists public.ai_question_drafts (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.exams(id) on delete cascade,
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  source_storage_path text not null,
  source_filename text not null,
  config jsonb not null default '{}'::jsonb
    constraint ai_question_drafts_config_object_check
    check (jsonb_typeof(config) = 'object'),
  questions jsonb not null default '[]'::jsonb
    constraint ai_question_drafts_questions_array_check
    check (jsonb_typeof(questions) = 'array'),
  status text not null default 'needs_review'
    constraint ai_question_drafts_status_check
    check (status in ('needs_review', 'approved', 'discarded')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);

do $$
declare
  required_column record;
  column_type text;
  column_required boolean;
  column_default text;
  constraint_definition text;
begin
  for required_column in
    select * from (values
      ('id', 'uuid', true, 'gen_random_uuid()'),
      ('exam_id', 'uuid', true, null),
      ('teacher_id', 'uuid', true, null),
      ('source_storage_path', 'text', true, null),
      ('source_filename', 'text', true, null),
      ('config', 'jsonb', true, '''{}''::jsonb'),
      ('questions', 'jsonb', true, '''[]''::jsonb'),
      ('status', 'text', true, '''needs_review''::text'),
      ('created_at', 'timestamptz', true, 'now()'),
      ('reviewed_at', 'timestamptz', false, null)
    ) as expected(column_name, udt_name, not_null, default_expression)
  loop
    select t.typname, c.attnotnull, pg_get_expr(d.adbin, d.adrelid)
      into column_type, column_required, column_default
    from pg_attribute c
    join pg_type t on t.oid = c.atttypid
    left join pg_attrdef d
      on d.adrelid = c.attrelid and d.adnum = c.attnum
    where c.attrelid = 'public.ai_question_drafts'::regclass
      and c.attname = required_column.column_name
      and c.attnum > 0
      and not c.attisdropped;

    if not found then
      raise exception 'public.ai_question_drafts is missing required column %',
        required_column.column_name;
    end if;

    if column_type <> required_column.udt_name
       or column_required <> required_column.not_null then
      raise exception 'public.ai_question_drafts.% has an incompatible type or nullability',
        required_column.column_name;
    end if;

    if required_column.default_expression is not null
       and replace(coalesce(column_default, ''), ' ', '')
         <> replace(required_column.default_expression, ' ', '') then
      raise exception 'public.ai_question_drafts.% has an incompatible default',
        required_column.column_name;
    end if;
  end loop;

  if not exists (
    select 1
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
    where c.conrelid = 'public.ai_question_drafts'::regclass
      and c.contype = 'p'
      and cardinality(c.conkey) = 1
      and a.attname = 'id'
  ) then
    raise exception 'public.ai_question_drafts.id must be the primary key';
  end if;

  if not exists (
    select 1
    from pg_constraint c
    join pg_attribute src on src.attrelid = c.conrelid and src.attnum = c.conkey[1]
    join pg_attribute dst on dst.attrelid = c.confrelid and dst.attnum = c.confkey[1]
    where c.conrelid = 'public.ai_question_drafts'::regclass
      and c.contype = 'f'
      and cardinality(c.conkey) = 1
      and cardinality(c.confkey) = 1
      and src.attname = 'exam_id'
      and c.confrelid = 'public.exams'::regclass
      and dst.attname = 'id'
      and c.confdeltype = 'c'
  ) then
    raise exception 'public.ai_question_drafts.exam_id must reference public.exams(id) with ON DELETE CASCADE';
  end if;

  if not exists (
    select 1
    from pg_constraint c
    join pg_attribute src on src.attrelid = c.conrelid and src.attnum = c.conkey[1]
    join pg_attribute dst on dst.attrelid = c.confrelid and dst.attnum = c.confkey[1]
    where c.conrelid = 'public.ai_question_drafts'::regclass
      and c.contype = 'f'
      and cardinality(c.conkey) = 1
      and cardinality(c.confkey) = 1
      and src.attname = 'teacher_id'
      and c.confrelid = 'public.profiles'::regclass
      and dst.attname = 'id'
      and c.confdeltype = 'c'
  ) then
    raise exception 'public.ai_question_drafts.teacher_id must reference public.profiles(id) with ON DELETE CASCADE';
  end if;

  select pg_get_constraintdef(c.oid)
    into constraint_definition
  from pg_constraint c
  where c.conrelid = 'public.ai_question_drafts'::regclass
    and c.contype = 'c'
    and pg_get_constraintdef(c.oid) ilike '%status%';

  if constraint_definition is null
     or constraint_definition not ilike '%needs_review%'
     or constraint_definition not ilike '%approved%'
     or constraint_definition not ilike '%discarded%'
     or length(constraint_definition) - length(replace(constraint_definition, '''', '')) <> 6 then
    raise exception 'public.ai_question_drafts has an incompatible status constraint';
  end if;

  select pg_get_constraintdef(c.oid)
    into constraint_definition
  from pg_constraint c
  where c.conrelid = 'public.ai_question_drafts'::regclass
    and c.contype = 'c'
    and pg_get_constraintdef(c.oid) ilike '%questions%';

  if constraint_definition is null
     or constraint_definition not ilike '%jsonb_typeof%'
     or constraint_definition not ilike '%array%'
     or length(constraint_definition) - length(replace(constraint_definition, '''', '')) <> 2 then
    raise exception 'public.ai_question_drafts has an incompatible questions constraint';
  end if;

  if exists (
    select 1
    from pg_constraint c
    where c.conrelid = 'public.ai_question_drafts'::regclass
      and c.contype = 'c'
      and pg_get_constraintdef(c.oid) ilike '%config%'
      and (
        pg_get_constraintdef(c.oid) not ilike '%jsonb_typeof%'
        or pg_get_constraintdef(c.oid) not ilike '%object%'
        or length(pg_get_constraintdef(c.oid))
          - length(replace(pg_get_constraintdef(c.oid), '''', '')) <> 2
      )
  ) then
    raise exception 'public.ai_question_drafts has an incompatible config constraint';
  end if;
end;
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint c
    where c.conrelid = 'public.ai_question_drafts'::regclass
      and c.contype = 'c'
      and pg_get_constraintdef(c.oid) ilike '%config%'
      and pg_get_constraintdef(c.oid) ilike '%jsonb_typeof%'
      and pg_get_constraintdef(c.oid) ilike '%object%'
  ) then
    alter table public.ai_question_drafts
      add constraint ai_question_drafts_config_object_check
      check (jsonb_typeof(config) = 'object');
  end if;

  if exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'ai_question_drafts'
      and policyname not in (
        'ai_question_drafts_owner_all',
        'ai_question_drafts_select',
        'ai_question_drafts_insert',
        'ai_question_drafts_update'
      )
  ) then
    raise exception
      'Unrecognized policy exists on public.ai_question_drafts; inspect it before continuing';
  end if;
end;
$$;

alter table public.ai_question_drafts enable row level security;

drop policy if exists ai_question_drafts_owner_all
  on public.ai_question_drafts;
drop policy if exists ai_question_drafts_select
  on public.ai_question_drafts;
drop policy if exists ai_question_drafts_insert
  on public.ai_question_drafts;
drop policy if exists ai_question_drafts_update
  on public.ai_question_drafts;

create policy ai_question_drafts_select
  on public.ai_question_drafts
  for select
  to authenticated
  using (
    public.is_admin()
    or (
      teacher_id = auth.uid()
      and public.is_approved_teacher()
      and exists (
        select 1
        from public.exams e
        where e.id = ai_question_drafts.exam_id
          and e.teacher_id = auth.uid()
      )
    )
  );

create policy ai_question_drafts_insert
  on public.ai_question_drafts
  for insert
  to authenticated
  with check (
    (
      teacher_id = auth.uid()
      and public.is_approved_teacher()
      and exists (
        select 1
        from public.exams e
        where e.id = ai_question_drafts.exam_id
          and e.teacher_id = auth.uid()
          and e.published = false
      )
    )
    or (
      public.is_admin()
      and teacher_id = auth.uid()
      and exists (
        select 1
        from public.exams e
        where e.id = ai_question_drafts.exam_id
          and e.teacher_id = auth.uid()
          and e.published = false
      )
    )
  );

create policy ai_question_drafts_update
  on public.ai_question_drafts
  for update
  to authenticated
  using (
    public.is_admin()
    or (
      teacher_id = auth.uid()
      and public.is_approved_teacher()
      and exists (
        select 1
        from public.exams e
        where e.id = ai_question_drafts.exam_id
          and e.teacher_id = auth.uid()
          and e.published = false
      )
    )
  )
  with check (
    (
      public.is_admin()
      and exists (
        select 1
        from public.exams e
        where e.id = ai_question_drafts.exam_id
          and e.teacher_id = ai_question_drafts.teacher_id
      )
    )
    or (
      teacher_id = auth.uid()
      and public.is_approved_teacher()
      and exists (
        select 1
        from public.exams e
        where e.id = ai_question_drafts.exam_id
          and e.teacher_id = auth.uid()
          and e.published = false
      )
    )
  );

revoke all on table public.ai_question_drafts from public, anon, authenticated;
grant select, insert, update
  on table public.ai_question_drafts to authenticated;

create index if not exists ai_question_drafts_teacher
  on public.ai_question_drafts (teacher_id, created_at desc);

notify pgrst, 'reload schema';
commit;
