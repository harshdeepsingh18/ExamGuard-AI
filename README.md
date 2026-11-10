# ExamGuard AI

A responsive examination platform built with React, Vite, Tailwind CSS, and Supabase. Supabase Auth handles identity; PostgreSQL stores profiles, exams, attempts, answers, results, and notifications. Row Level Security (RLS) applies authorization at the data boundary.

## Architecture

- `src/components`: route guards and shared UI
- `src/context`: one Supabase session/profile provider
- `src/layouts`: responsive authenticated navigation
- `src/pages`: authentication, student, teacher, admin, settings, and exam workflows
- `src/lib`: Supabase browser client
- `src/styles`: Tailwind base and responsive design system
- `supabase/migrations`: schema, RLS, and secure RPCs
- `server`: reserved for optional trusted integrations; no service-role backend is needed by this app

Exam start and submission use Postgres functions. Students never have direct SELECT access to the answer key table. `start_exam` returns question content without correct-answer fields; `save_exam_answers` validates and persists answer selections as they change. `submit_exam` checks the attempt owner and time limit, scores server-side, and creates the result. Resuming an in-progress attempt preserves its server-side start time. Teacher approval also uses an admin-checked function.

## Requirements

- Node.js 20 or newer
- A Supabase project
- Google Cloud project only if Google sign-in is enabled

## Local setup

1. Create a Supabase project at [supabase.com](https://supabase.com).
2. In Supabase **SQL Editor**, run the migration files in numeric order from `202611100001_initial_schema.sql` through `202611100007_fresh_auth_profiles.sql`. The final migration installs the fresh auth trigger and removes the obsolete profile recovery RPC.
3. In project **Settings > API**, copy the Project URL and anon/public key. Never use the service-role key in this browser app.
4. Copy `.env.example` to `.env` and fill:
   - `VITE_SUPABASE_URL`: Supabase project URL.
   - `VITE_SUPABASE_ANON_KEY`: Supabase publishable/anon key.
   - The app uses the current browser origin for OAuth, signup verification, and password reset redirects. No separate frontend URL variable is needed.
5. Run `npm install`, then `npm run dev`.

## Supabase Auth configuration

In **Authentication > URL Configuration**:

- Site URL: your canonical frontend URL.
- Redirect URLs: add `http://localhost:5173/auth/callback` for development and the exact production `https://your-domain/auth/callback` URL. Add the app origin as the Site URL. Avoid wildcard redirects in production.

To enable Google in **Authentication > Providers > Google**:

1. Create an OAuth 2.0 Web application credential in Google Cloud Console.
2. Add local and production frontend URLs under **Authorized JavaScript origins**.
3. Copy Supabase's callback shown by the Google provider page (usually `https://<project-ref>.supabase.co/auth/v1/callback`) into **Authorized redirect URIs**.
4. Put the Google client ID and secret into Supabase provider settings. Do not put the client secret in this repository.
5. Confirm the production site and redirects in Supabase URL Configuration.

Email verification and reset email templates are configured in Supabase Auth. Signup requests a verification email when enabled. Every new auth user gets a `public.profiles` row from the database trigger in the same transaction, including a first-time Google user. Do not create profiles from the browser.

## First admin

Public signup deliberately cannot select an admin role. After creating the designated admin account, use Supabase SQL Editor under project owner access to promote that account:

```sql
update public.profiles p set role='admin', teacher_status='approved'
from auth.users u where p.id=u.id and u.email='admin@example.com';
```

Treat this provisioning step as an owner-only operation. Admins can approve/reject teacher requests and manage roles in the dashboard. Teacher accounts start as pending and cannot create or manage exams until approved.

## Deploy

Build with `npm run build`; deploy `dist/` to any static host. Configure `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` in that host's build environment. Add the deployed `/auth/callback` URL to Supabase Redirect URLs. No Express API or server secret is needed for the current feature set; Supabase RPCs enforce exam submission and teacher review. Do not deploy a service-role key to the frontend.

## Included workflows

- Supabase email/password signup and login, Google OAuth sign-in/sign-up, password reset, automatic profile creation, persistent sessions, sign out
- Student dashboard, published exam browsing, timed exam sessions, server-side scoring, result history, notifications, profile editing
- Pending teacher onboarding; approved teacher exam creation, question authoring, publishing, deleting, and student result review
- Admin teacher request review, user role management, exam monitoring, and overview analytics
- Responsive layouts, keyboardable form controls, loading/error states, and light/dark theme toggle

## Security notes and manual configuration

- RLS is enabled on every application table. The browser uses only the public anon key.
- `profiles.role` and `teacher_status` are guarded from self-updates by a database trigger. Teacher approvals are transactional through `review_teacher`.
- To allow a teacher to score an exam with a custom threshold, set `passing_marks` to the desired number of points. The default is one point.
- Optional availability windows are supported by schema; the current teacher form creates exams without a window. Admin user listing is capped at 200 in the dashboard.
- Configure SMTP/email verification, password reset templates, Google credentials, production host variables and redirects, and seed the first admin as described above.
- Review institution-specific privacy/retention policies and legal terms before public launch. Terms checkbox is currently a simple acknowledgement, not a hosted legal document.

## Verification

Run `npm run build` and `npm run lint` for the client checks. To check first-user profile creation against a completely empty Auth user table, run `supabase/tests/fresh_auth_profiles.sql` in the Supabase SQL Editor after applying all migrations; the script inserts temporary email and Google-shaped auth rows, checks their profiles, and rolls back. Complete browser OAuth still requires the Google provider credentials and allowed redirect URLs configured above.





