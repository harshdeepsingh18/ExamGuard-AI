-- Add the per-exam camera requirement used by the student pre-exam permission gate.
begin;

do $$
begin
  if to_regclass('public.exams') is null then
    raise exception 'public.exams must exist before adding camera_required';
  end if;
end;
$$;

alter table public.exams
  add column if not exists camera_required boolean not null default false;

do $$
declare
  actual_type text;
  actual_not_null boolean;
begin
  select t.typname, a.attnotnull
    into actual_type, actual_not_null
  from pg_attribute a
  join pg_type t on t.oid = a.atttypid
  where a.attrelid = 'public.exams'::regclass
    and a.attname = 'camera_required'
    and a.attnum > 0
    and not a.attisdropped;

  if not found then
    raise exception 'public.exams.camera_required was not created';
  end if;
  if actual_type <> 'bool' or not actual_not_null then
    raise exception 'public.exams.camera_required must be BOOLEAN NOT NULL';
  end if;
end;
$$;

alter table public.exams
  alter column camera_required set default false;

notify pgrst, 'reload schema';
commit;
