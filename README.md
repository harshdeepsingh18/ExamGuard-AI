# ExamGuard AI

Flask and Supabase examination platform for teacher-managed assessments, timed student attempts, answer review, results, and consent-based proctoring.

## Setup

1. Create a virtual environment and install dependencies:

   ```powershell
   py -m venv .venv
   .\.venv\Scripts\Activate.ps1
   pip install -r requirements.txt
   ```

2. In the Supabase SQL Editor, apply [`supabase/schema.sql`](supabase/schema.sql). It creates the application tables, RLS policies, auth profile trigger, private PDF bucket, and result/grade functions.

3. Set these values in `.env`:

   ```text
   SUPABASE_URL=https://your-project.supabase.co
   SUPABASE_KEY=your-anon-or-publishable-key
   SECRET_KEY=generate-a-long-random-value
   SESSION_COOKIE_SECURE=false
   EXAM_TIMEZONE=Asia/Kolkata
   PASSWORD_RESET_REDIRECT_URL=http://127.0.0.1:5000/reset-password
   ```

   Use the Supabase anon/publishable key only. Never put a service-role key in the app or browser. Add the password reset URL to Supabase Auth's allowed redirect URLs. For an HTTPS deployment, set `SESSION_COOKIE_SECURE=true` and use an HTTPS reset URL.

4. Configure Supabase Auth email confirmation and SMTP for the deployment, then run:

   ```powershell
   flask --app app run --debug
   ```

## Exam workflow

- Students and teacher applicants register through Supabase Auth. Every new profile starts with student access. Teacher approval is an administrator action; after verifying the applicant, run this in the Supabase SQL Editor with their profile UUID:

  ```sql
  update public.profiles
  set role = 'teacher', teacher_approved = true
  where id = 'PROFILE-UUID' and requested_role = 'teacher';
  ```

- Approved teachers create drafts, optionally upload text based PDFs (up to 10 MB), review extracted text, add structured questions and answer keys, and publish when question marks equal the exam total.
- Students start one attempt per exam. Answers autosave, objective questions are scored automatically, and written answers can be graded by the exam owner before results are published.
- During an exam, tab visibility and fullscreen changes can be logged. Camera checks are optional and require a student click and browser permission. Frames are sent to the server for face counting, processed in memory, and not saved as video. Monitoring events are context for a teacher, not proof of misconduct.

## Current limitations

- Scanned PDFs need OCR and are rejected with a clear message; only selectable text is extracted.
- Teachers approve accounts manually in Supabase; there is no administrator UI yet.
- Charts, settings/profile editing, exam announcements, question bank reuse, and exam editing after publication are not included.
- Face detection needs the OpenCV and MediaPipe packages installed on the server. Camera access requires HTTPS or localhost and may not be available in every browser.
- The default filesystem session store is suitable for a single server instance. Use a shared production session store when deploying multiple instances.
