-- Bring an existing profiles table up to the current teacher approval schema.
-- Safe to run repeatedly.
alter table public.profiles
 add column if not exists teacher_status text not null default 'none';

-- Existing teacher accounts have not gone through approval, so keep them pending.
update public.profiles
 set teacher_status='pending'
 where role='teacher' and teacher_status='none';

-- Enforce supported states even if profiles was created by an older schema.
do $$ begin
 if not exists (
  select 1 from pg_constraint
  where conrelid='public.profiles'::regclass
   and conname='profiles_teacher_status_check'
 ) then
  alter table public.profiles add constraint profiles_teacher_status_check
   check (teacher_status in ('none','pending','approved','rejected'));
 end if;
end $$;
