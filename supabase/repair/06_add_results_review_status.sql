-- Adds the result review state without replacing or modifying existing result rows.
begin;

do $$
begin
  if to_regclass('public.results') is null then
    raise exception 'public.results must exist before adding review_status';
  end if;
end;
$$;

alter table public.results
  add column if not exists review_status text not null default 'approved';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.results'::regclass
      and conname = 'results_review_status_check'
  ) then
    alter table public.results
      add constraint results_review_status_check
      check (review_status in ('approved', 'pending', 'needs_review', 'rejected'));
  end if;
end;
$$;

notify pgrst, 'reload schema';
commit;
