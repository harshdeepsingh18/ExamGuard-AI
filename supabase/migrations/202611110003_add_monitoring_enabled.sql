-- Add the per-exam monitoring switch without changing existing exam rows.
begin;

do $$
begin
  if to_regclass('public.exams') is null then
    raise exception 'public.exams must exist before adding monitoring_enabled';
  end if;
end;
$$;

alter table public.exams
  add column if not exists monitoring_enabled boolean not null default false;

do $$
declare
  actual_type text;
  actual_not_null boolean;
begin
  select t.typname, a.attnotnull
    into actual_type, actual_not_null
  from pg_attribute a
  join pg_type t on t.oid = a.atttypid
  left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
  where a.attrelid = 'public.exams'::regclass
    and a.attname = 'monitoring_enabled'
    and a.attnum > 0
    and not a.attisdropped;

  if not found then
    raise exception 'public.exams.monitoring_enabled was not created';
  end if;
  if actual_type <> 'bool' or not actual_not_null then
    raise exception 'public.exams.monitoring_enabled must be BOOLEAN NOT NULL';
  end if;
end;
$$;

-- A preceding AI-upgrade migration used DEFAULT true. Change only the default;
-- existing exam values and rows are deliberately left untouched.
alter table public.exams
  alter column monitoring_enabled set default false;

do $$
begin
  if (
    select replace(coalesce(pg_get_expr(d.adbin, d.adrelid), ''), ' ', '')
    from pg_attribute a
    left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
    where a.attrelid = 'public.exams'::regclass
      and a.attname = 'monitoring_enabled'
      and a.attnum > 0
      and not a.attisdropped
  ) <> 'false' then
    raise exception 'public.exams.monitoring_enabled must have DEFAULT false';
  end if;
end;
$$;

notify pgrst, 'reload schema';
commit;
