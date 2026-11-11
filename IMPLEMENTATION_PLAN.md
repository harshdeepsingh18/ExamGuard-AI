# ExamGuard AI upgrade plan

## Existing architecture reviewed

- React 18 + Vite with React Router; authenticated screens live in `src/pages` and share `AppLayout`.
- Supabase Auth and `profiles` are the identity/role source. The browser uses only the public Supabase key.
- PostgreSQL migrations through `202611100009_exam_pdf_reports.sql` define exams, MCQ questions, attempts, answers, results, teacher workflows, and private PDF Storage.
- `start_exam`, `save_exam_answers`, and `submit_exam` are the trusted exam lifecycle. Students do not read answer keys directly.
- Teacher UI creates MCQ and PDF exams and publishes results; student UI shows exams/results; Admin UI handles users and existing PDF reports.
- `server/` is empty. There is no AI provider integration, OCR pipeline, monitoring-event model, or descriptive grading today.

## Implementation sequence

1. Add migration `202611100010_ai_exam_upgrade.sql`: additive question types/answer keys, event and AI review tables, narrowly scoped RLS, and safe answer/result workflow support. Keep existing Auth, tables, private Storage, and MCQ behavior.
2. Add Supabase Edge Functions for private PDF-to-question generation and descriptive answer suggestions. Require authenticated approved teachers, ownership checks, bounded input, server-side provider secrets, structured output, and teacher approval before saving/publishing.
3. Add teacher UI for uploading source PDFs to existing private storage, editing/reviewing generated questions, monitoring events, and approving/overriding suggested grades.
4. Add student-facing monitoring disclosure, visibility/focus event logging, optional explicit camera consent, clear status/warnings, and graceful unsupported/denied-camera behavior. Store event metadata only, never video.
5. Add result visibility and monitoring summaries to the relevant dashboards and responsive styling.
6. Document migration, Edge Function secrets/deployment, OCR/provider setup, and manual browser/Supabase workflow checks. Run the requested build and lint checks; report external workflows that cannot be verified without a configured Supabase project/provider.

## Safety invariants

- No automatic cheating decisions or automatic failure from focus/camera signals.
- Camera stays off until the student opts in, browser permission succeeds, and the exam explicitly requires it; no video is uploaded or recorded.
- Generated questions and descriptive grades remain suggestions until a teacher reviews them.
- AI credentials stay in Edge Function secrets. Database access is constrained by RLS and exam ownership.
