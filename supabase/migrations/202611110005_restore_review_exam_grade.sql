-- Restore result review using the verified objective-answer schema.
-- Does not alter result rows, table definitions, or RLS policies.
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
      and procedure_row.oid
        <> coalesce(
          to_regprocedure('public.review_exam_grade(uuid,boolean)')::oid,
          0::oid
        )
  ) then
    raise exception
      'A different public.review_exam_grade signature exists; inspect it before applying this migration';
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
      ('ai_grade_suggestions', 'question_id'),
      ('ai_grade_suggestions', 'status'),
      ('ai_grade_suggestions', 'reviewed_marks'),
      ('ai_grade_suggestions', 'max_marks')
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
  approved_ai_score numeric;
  final_score numeric;
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

  if e.exam_type <> 'pdf' and p_publish and exists (
    select 1
    from public.ai_grade_suggestions as suggestion
    join public.questions as question_row
      on question_row.id = suggestion.question_id
     and question_row.exam_id = r.exam_id
    where suggestion.attempt_id = r.attempt_id
      and suggestion.status not in ('approved', 'rejected')
  ) then
    raise exception 'Review every AI grading suggestion before publishing';
  end if;

  if e.exam_type <> 'pdf' and exists (
    select 1
    from public.ai_grade_suggestions as suggestion
    join public.questions as question_row
      on question_row.id = suggestion.question_id
     and question_row.exam_id = r.exam_id
    where suggestion.attempt_id = r.attempt_id
      and suggestion.status = 'approved'
      and (
        suggestion.reviewed_marks is null
        or suggestion.reviewed_marks < 0
        or suggestion.reviewed_marks > suggestion.max_marks
      )
  ) then
    raise exception 'Approved grading marks are missing or outside the suggestion maximum';
  end if;

  if e.exam_type = 'pdf' then
    -- PDF submissions have no online answer rows. Preserve the manually
    -- reviewed score already stored on the result.
    final_score := r.score;
  else
    select coalesce(sum(question_row.points), 0)
      into objective_score
    from public.questions as question_row
    where question_row.exam_id = r.exam_id
      and exists (
        select 1
        from public.student_answers as answer_row
        where answer_row.attempt_id = r.attempt_id
          and answer_row.question_id = question_row.id
          and answer_row.selected_answer = question_row.correct_answer
      )
      and not exists (
        select 1
        from public.ai_grade_suggestions as suggestion
        where suggestion.attempt_id = r.attempt_id
          and suggestion.question_id = question_row.id
          and suggestion.status = 'approved'
      );

    select coalesce(sum(suggestion.reviewed_marks), 0)
      into approved_ai_score
    from public.ai_grade_suggestions as suggestion
    join public.questions as question_row
      on question_row.id = suggestion.question_id
     and question_row.exam_id = r.exam_id
    where suggestion.attempt_id = r.attempt_id
      and suggestion.status = 'approved';

    final_score := objective_score + approved_ai_score;
  end if;

  if e.exam_type <> 'pdf'
     and (final_score < 0 or final_score > r.max_score) then
    raise exception 'Calculated result score is outside the result maximum';
  end if;

  if e.exam_type = 'pdf' then
    update public.results as result_row
    set published = p_publish,
        review_status = case when p_publish then 'approved' else 'pending' end,
        updated_at = now()
    where result_row.id = r.id;
  else
    update public.results as result_row
    set score = final_score,
        percentage = case
          when result_row.max_score > 0
            then round(final_score * 100 / result_row.max_score, 2)
          else 0
        end,
        passed = final_score >= e.passing_marks,
        published = p_publish,
        review_status = case when p_publish then 'approved' else 'pending' end,
        updated_at = now()
    where result_row.id = r.id;
  end if;
end;
$$;

revoke all on function public.review_exam_grade(uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.review_exam_grade(uuid, boolean)
  to authenticated;

notify pgrst, 'reload schema';
commit;
