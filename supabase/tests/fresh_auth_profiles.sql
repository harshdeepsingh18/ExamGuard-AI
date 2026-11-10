-- Run in Supabase SQL Editor after all migrations against a project with no
-- auth users. The transaction rolls back, leaving the project empty.
begin;

do $$
declare
 student_id uuid := gen_random_uuid();
 google_id uuid := gen_random_uuid();
 profile_row public.profiles%rowtype;
begin
 insert into auth.users(id, aud, role, email, encrypted_password, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
 values(student_id, 'authenticated', 'authenticated', student_id::text || '@fresh-auth.test', '',
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"full_name":"Fresh Student","account_type":"student"}'::jsonb, now(), now());

 select * into profile_row from public.profiles where id=student_id;
 if not found or profile_row.full_name <> 'Fresh Student' or profile_row.role <> 'student' or profile_row.teacher_status <> 'none' then
  raise exception 'Fresh email signup did not create the expected student profile';
 end if;

 insert into auth.users(id, aud, role, email, encrypted_password, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
 values(google_id, 'authenticated', 'authenticated', google_id::text || '@fresh-auth.test', '',
  '{"provider":"google","providers":["google"]}'::jsonb,
  '{"name":"Fresh Google User","account_type":"admin"}'::jsonb, now(), now());

 select * into profile_row from public.profiles where id=google_id;
 if not found or profile_row.full_name <> 'Fresh Google User' or profile_row.role <> 'student' or profile_row.teacher_status <> 'none' then
  raise exception 'Fresh Google signup did not create a safe default profile';
 end if;

 if exists(select 1 from public.teacher_requests where user_id in (student_id, google_id)) then
  raise exception 'Student profiles must not create teacher requests';
 end if;
end;
$$;

rollback;
