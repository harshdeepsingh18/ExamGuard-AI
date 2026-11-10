-- Retire the old client-invoked profile recovery function.
-- New profiles are created atomically by public.handle_new_user().
drop function if exists public.ensure_own_profile();
