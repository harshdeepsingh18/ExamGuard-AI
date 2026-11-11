-- Restore result review using the verified objective-answer schema.
-- Does not alter tables, existing result rows, or RLS policies.
begin;

do $$
begin
  if to_regclass('public.results') is null
     or to_regclass('public.exams') is null
     or to_regclass('public.exam_attempts') is null
     or to_regclass('public.questions') is null
     or to_regclass('public.student_answers') is null
     or to_regclass('public.ai_grade_suggestions') is null then
    raise exception
      'Result review requires results, exams, exam_attempts, questions, student_answers, and ai_grade_suggestions';
  end if;

  if to_regprocedure('public.is_admin()') is null
     or to_regprocedure('public.is_approved_teacher()') is null then
    raise exception
      'Result review requires public.is_admin() and public.is_approved_teacher()';
  end if;

  if exists (
    select 1
    from pg_proc as procedure_row
    join pg_namespace as namespace_row
      on namespace_row.oid = procedure_row.pronamespace
    where namespace_row.nspname = 'public'
      and procedure_row.proname = 'review_exam_grade'
      and procedure_row.oid <> coalesce(
        to_regprocedure('public.review_exam_grade(uuid,boolean)')::oid,
        0::oid
      )
  ) then
    raise exception
      'A different public.review_exam_grade signature exists; inspect it before applying this repair';
  end if;

  if to_regprocedure('public.review_exam_grade(uuid,boolean)') is not null
     and exists (
       select 1
       from pg_proc as procedure_row
       where procedure_row.oid =
         to_regprocedure('public.review_exam_grade(uuid,boolean)')
         and procedure_row.proargnames[1:2]
           is distinct from array['p_result', 'p_publish']::text[]
     ) then
    raise exception
      'Existing review_exam_grade argument names differ; inspect the function before replacing it';
  end if;

  if exists (
    select required.table_name, required.column_name
    from (values
      ('results', 'id'),
      ('results', 'attempt_id'),
      ('results', 'student_id'),
      ('results', 'exam_id'),
      ('results', 'score'),
      ('results', 'max_score'),
      ('results', 'percentage'),
      ('results', 'passed'),
      ('results', 'published'),
      ('results', 'updated_at'),
      ('results', 'review_status'),
      ('exams', 'id'),
      ('exams', 'exam_type'),
      ('exams', 'teacher_id'),
      ('exams', 'passing_marks'),
      ('exam_attempts', 'id'),
      ('exam_attempts', 'exam_id'),
      ('exam_attempts', 'student_id'),
      ('exam_attempts', 'status'),
      ('questions', 'id'),
      ('questions', 'exam_id'),
      ('questions', 'correct_answer'),
      ('questions', 'points'),
      ('student_answers', 'attempt_id'),
      ('student_answers', 'question_id'),
      ('student_answers', 'selected_answer'),
      ('ai_grade_suggestions', 'attempt_id'),
      ('ai_grade_suggestions', 'status')
    ) as required(table_name, column_name)
    where not exists (
      select 1
      from information_schema.columns as actual
      where actual.table_schema = 'public'
        and actual.table_name = required.table_name
        and actual.column_name = required.column_name
    )
  ) then
    raise exception
      'A required result-review column is missing from the verified application schema';
  end if;

end;
$$;

create or replace function public.review_exam_grade(
  p_result uuid,
  p_publish boolean default false
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.results%rowtype;
  e public.exams%rowtype;
  attempt_status text;
  objective_score numeric;
  objective_max_score numeric;
begin
  if auth.uid() is null or p_result is null then
    raise exception 'Result not found or access denied';
  end if;

  if p_publish is null then
    raise exception 'p_publish must be true or false';
  end if;

  select result_row.*
    into r
  from public.results as result_row
  where result_row.id = p_result
  for update;

  if not found then
    raise exception 'Result not found or access denied';
  end if;

  select exam_row.*
    into e
  from public.exams as exam_row
  where exam_row.id = r.exam_id;

  if not found
     or not coalesce(
       public.is_admin()
       or (
         public.is_approved_teacher()
         and e.teacher_id = auth.uid()
       ),
       false
     ) then
    raise exception 'Result not found or access denied';
  end if;

  select attempt_row.status
    into attempt_status
  from public.exam_attempts as attempt_row
  where attempt_row.id = r.attempt_id
    and attempt_row.exam_id = r.exam_id
    and attempt_row.student_id = r.student_id;

  if not found or attempt_status is distinct from 'submitted' then
    raise exception 'Result does not belong to a submitted attempt';
  end if;

  if e.exam_type = 'pdf' then
    raise exception
      'PDF result creation and manual grading are not supported by the current application workflow';
  end if;

  if e.exam_type is distinct from 'online' then
    raise exception 'Unsupported exam_type; only online and pdf are supported';
  end if;

  if exists (
    select 1
    from public.ai_grade_suggestions as suggestion
    where suggestion.attempt_id = r.attempt_id
      and suggestion.status is distinct from 'rejected'
  ) then
    raise exception
      'AI grading suggestions cannot be safely applied with the current schema; reject or resolve them before reviewing this result';
  end if;

  select
    coalesce(sum(question_row.points), 0),
    coalesce(sum(question_row.points) filter (
      where exists (
        select 1
        from public.student_answers as answer_row
        where answer_row.attempt_id = r.attempt_id
          and answer_row.question_id = question_row.id
          and answer_row.selected_answer = question_row.correct_answer
      )
    ), 0)
    into objective_max_score, objective_score
  from public.questions as question_row
  where question_row.exam_id = r.exam_id;

  if r.max_score is distinct from objective_max_score then
    raise exception
      'Stored result maximum does not match the objective question maximum; inspect the result before review';
  end if;

  if objective_score < 0
     or objective_score > objective_max_score then
    raise exception
      'Calculated objective score is outside the objective maximum';
  end if;

  update public.results as result_row
  set score = objective_score,
      percentage = case
        when objective_max_score > 0
          then round(objective_score * 100 / objective_max_score, 2)
        else 0
      end,
      passed = objective_score >= coalesce(e.passing_marks, 0),
      published = p_publish,
      review_status = case
        when p_publish then 'approved'
        else 'pending'
      end,
      updated_at = now()
  where result_row.id = r.id;
end;
$$;

do $$
declare
  grantee_name text;
begin
  for grantee_name in
    select distinct role_row.rolname
    from pg_proc as procedure_row
    cross join lateral aclexplode(
      coalesce(
        procedure_row.proacl,
        acldefault('f', procedure_row.proowner)
      )
    ) as acl_row
    join pg_roles as role_row
      on role_row.oid = acl_row.grantee
    where procedure_row.oid =
      to_regprocedure('public.review_exam_grade(uuid,boolean)')
      and acl_row.grantee <> procedure_row.proowner
      and acl_row.grantee <> 0
  loop
    execute format(
      'revoke all privileges on function public.review_exam_grade(uuid, boolean) from %I',
      grantee_name
    );
  end loop;

  revoke all on function public.review_exam_grade(uuid, boolean)
    from public;
end;
$$;

grant execute on function public.review_exam_grade(uuid, boolean)
  to authenticated;

notify pgrst, 'reload schema';
commit;
