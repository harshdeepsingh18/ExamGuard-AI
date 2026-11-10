-- Recover profiles for users who signed up before the auth trigger was installed.
-- The caller can only create their own profile. Teacher selection remains pending;
-- admin can never be assigned through this public function.
create or replace function public.ensure_own_profile() returns void
language plpgsql security definer set search_path=public as $$
declare
 uid uuid := auth.uid();
 account_type text;
 display_name text;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 select coalesce(raw_user_meta_data->>'account_type','student'), coalesce(raw_user_meta_data->>'full_name','')
 into account_type, display_name from auth.users where id=uid;
 if not found then raise exception 'Authenticated user was not found'; end if;
 insert into public.profiles(id,full_name,role,teacher_status)
 values(uid,display_name,case when account_type='teacher' then 'teacher' else 'student' end,case when account_type='teacher' then 'pending' else 'none' end)
 on conflict(id) do nothing;
 if account_type='teacher' then
  insert into public.teacher_requests(user_id) values(uid) on conflict(user_id) do nothing;
 end if;
end $$;
revoke all on function public.ensure_own_profile() from public;
grant execute on function public.ensure_own_profile() to authenticated;
