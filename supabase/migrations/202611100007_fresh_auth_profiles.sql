-- Fresh-auth flow: every auth.users insert atomically creates its public profile.
-- No client-side profile recovery is needed or permitted.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
 account_type text := coalesce(new.raw_user_meta_data->>'account_type', 'student');
 display_name text := coalesce(
  nullif(btrim(new.raw_user_meta_data->>'full_name'), ''),
  nullif(btrim(new.raw_user_meta_data->>'name'), ''),
  nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
  ''
 );
begin
 if account_type not in ('student', 'teacher') then account_type := 'student'; end if;
 insert into public.profiles(id,full_name,role,teacher_status)
 values(new.id,display_name,account_type,case when account_type='teacher' then 'pending' else 'none' end)
 on conflict (id) do nothing;
 if account_type='teacher' then
  insert into public.teacher_requests(user_id) values(new.id) on conflict (user_id) do nothing;
 end if;
 return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
 after insert on auth.users
 for each row execute function public.handle_new_user();

-- Remove the former client-callable repair path. Profile rows are created only
-- inside the auth.users transaction by handle_new_user().
drop function if exists public.ensure_own_profile();

notify pgrst, 'reload schema';
