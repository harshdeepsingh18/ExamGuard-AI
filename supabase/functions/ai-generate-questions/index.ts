import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' }
Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
  try {
    const token = request.headers.get('Authorization') || ''
    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: token } } })
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    if (authError || !user) return json({ error: 'Sign in to generate questions.' }, 401)
    const { data: profile, error: profileError } = await supabase.from('profiles').select('role,teacher_status').eq('id', user.id).single()
    if (profileError) return json({ error: `Could not verify your account: ${profileError.message}` }, 500)
    if (!(profile?.role === 'admin' || (profile?.role === 'teacher' && profile.teacher_status === 'approved'))) return json({ error: 'Approved teacher access is required.' }, 403)
    const body = await request.json()
    const { exam_id, storage_path, filename, count, difficulty, topic, question_types, total_marks } = body
    if (!exam_id || !storage_path || typeof filename !== 'string' || !Array.isArray(question_types)) return json({ error: 'Exam, source PDF, and question types are required.' }, 400)
    if (!Number.isInteger(count) || count < 1 || count > 40) return json({ error: 'Choose between 1 and 40 questions.' }, 400)
    if (!['easy', 'medium', 'hard', 'mixed'].includes(difficulty)) return json({ error: 'Invalid difficulty.' }, 400)
    const allowedTypes = ['mcq', 'true_false', 'fill_blank', 'short_answer', 'long_answer']
    const types = [...new Set(question_types.filter((type: unknown): type is string => typeof type === 'string' && allowedTypes.includes(type)))]
    if (!types.length) return json({ error: 'Select at least one supported question type.' }, 400)
    const { data: exam, error: examError } = await supabase.from('exams').select('id,teacher_id,exam_type,published').eq('id', exam_id).single()
    if (examError || !exam || exam.teacher_id !== user.id || exam.published || exam.exam_type !== 'online') return json({ error: 'Choose an unpublished online exam that you own.' }, 403)
    const storageParts = typeof storage_path === 'string' ? storage_path.split('/') : []
    const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
    if (storageParts.length !== 3 || storageParts[0] !== exam.id || storageParts[1] !== user.id || !uuidPattern.test(storageParts[2].replace(/\.pdf$/i, '')) || !storageParts[2].toLowerCase().endsWith('.pdf')) {
      return json({ error: 'The PDF path must belong to your exam and account.' }, 400)
    }
    const { data: pdf, error: fileError } = await supabase.storage.from('ai-question-sources').download(storage_path)
    if (fileError || !pdf) return json({ error: `Could not read the private PDF: ${fileError?.message || 'file missing'}` }, 400)
    if (pdf.size > 20 * 1024 * 1024) return json({ error: 'PDF must be 20 MB or smaller.' }, 413)
    if (await pdf.slice(0, 5).text() !== '%PDF-') return json({ error: 'The uploaded file is not a valid PDF.' }, 400)
    const apiKey = Deno.env.get('OPENAI_API_KEY')
    if (!apiKey) return json({ error: 'AI provider is not configured on this Edge Function.' }, 503)
    const form = new FormData()
    form.append('purpose', 'user_data')
    form.append('file', pdf, filename.slice(0, 180))
    const upload = await fetch('https://api.openai.com/v1/files', { method: 'POST', headers: { Authorization: `Bearer ${apiKey}` }, body: form })
    const uploaded = await upload.json()
    if (!upload.ok) return json({ error: `AI provider could not read this PDF: ${uploaded.error?.message || upload.statusText}` }, 422)
    const prompt = `Create exactly ${count} original examination questions from the attached PDF. Difficulty: ${difficulty}. Topic: ${String(topic || 'all relevant topics').slice(0, 160)}. Allowed types: ${types.join(', ')}. Target total marks: ${Math.max(1, Math.min(500, Number(total_marks) || count))}. Return JSON only: {"questions":[{"question_type":"mcq|true_false|fill_blank|short_answer|long_answer","prompt":"...","options":["...","...","...","..."],"answer_key":"...","grading_rubric":"...","explanation":"...","points":1}]}. MCQ must have exactly four options and answer_key must exactly match one option. True/false must have two options ["True","False"]. Other options should be ["",""]. Keep answer key/rubric concise. Do not invent facts absent from the source. Do not duplicate questions. These are unreviewed suggestions; identify ambiguities in the explanation.`
    const generated = await fetch('https://api.openai.com/v1/responses', { method: 'POST', headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ model: Deno.env.get('OPENAI_MODEL') || 'gpt-4.1-mini', input: [{ role: 'user', content: [{ type: 'input_text', text: prompt }, { type: 'input_file', file_id: uploaded.id }] }], text: { format: { type: 'json_object' } } }) })
    const response = await generated.json()
    if (!generated.ok) return json({ error: response.error?.message || 'AI generation failed.' }, 502)
    const output = (response.output || []).flatMap((item: any) => item.content || []).find((item: any) => item.type === 'output_text')?.text
    const parsed = JSON.parse(output || '{}')
    const generatedQuestions = Array.isArray(parsed.questions) ? parsed.questions : []
    const questions = generatedQuestions.slice(0, count).flatMap((raw: unknown) => {
      if (!raw || typeof raw !== 'object') return []
      const q = raw as Record<string, unknown>
      const questionType = typeof q.question_type === 'string' && types.includes(q.question_type) ? q.question_type : types[0]
      const options = questionType === 'mcq'
        ? Array.isArray(q.options) && q.options.length === 4 ? q.options.map((value: unknown) => String(value).slice(0, 500)) : []
        : questionType === 'true_false' ? ['True', 'False'] : ['', '']
      const prompt = String(q.prompt || '').slice(0, 3000).trim()
      const answerKey = String(q.answer_key || '').slice(0, 5000).trim()
      const answerMatchesOption = questionType !== 'mcq' && questionType !== 'true_false'
        ? true
        : options.some((option: string) => option.toLowerCase() === answerKey.toLowerCase())
      if (!prompt || !answerKey || !answerMatchesOption) return []
      const points = Number(q.points)
      return [{
        question_type: questionType,
        prompt,
        options,
        answer_key: answerKey,
        grading_rubric: String(q.grading_rubric || '').slice(0, 3000),
        explanation: String(q.explanation || '').slice(0, 1000),
        points: Number.isFinite(points) ? Math.max(0.5, Math.min(100, points)) : 1,
      }]
    })
    if (!questions.length) return json({ error: 'The PDF did not produce usable questions. Try a smaller or clearer PDF.' }, 422)
    const { data: draft, error: saveError } = await supabase.from('ai_question_drafts').insert({ exam_id, teacher_id: user.id, source_storage_path: storage_path, source_filename: filename, config: { count, difficulty, topic: String(topic || '').slice(0, 160), question_types: types, total_marks }, questions }).select('id,questions,status,created_at').single()
    if (saveError) return json({ error: saveError.message }, 400)
    return json({ draft })
  } catch (error) { return json({ error: error instanceof Error ? error.message : 'Question generation failed.' }, 500) }
})
