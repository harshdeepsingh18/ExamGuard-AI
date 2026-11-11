import { useCallback, useEffect, useState } from 'react'
import { FileText, Upload, X, Eye, RefreshCw } from 'lucide-react'
import { supabase, configured } from '../lib/supabase'
import { useAuth } from '../context/AuthContext'
import { createExamPaperSignedUrl, formatFileSize, removeExamPaper, uploadExamPaper, validatePdf } from '../lib/examPapers'

const emptyOptions = ['', '', '', '']
const resultReviewRequiredStatuses = new Set(['pending', 'needs_review'])

export function Teacher() {
  const { profile } = useAuth()
  const [exams, setExams] = useState([])
  const [results, setResults] = useState([])
  const [title, setTitle] = useState('')
  const [description, setDescription] = useState('')
  const [duration, setDuration] = useState(30)
  const [passing, setPassing] = useState(1)
  const [examType, setExamType] = useState('online')
  const [monitoringEnabled, setMonitoringEnabled] = useState(true)
  const [cameraRequired, setCameraRequired] = useState(false)
  const [question, setQuestion] = useState('')
  const [options, setOptions] = useState(emptyOptions)
  const [correct, setCorrect] = useState(0)
  const [examId, setExamId] = useState('')
  const [files, setFiles] = useState({})
  const [progress, setProgress] = useState({})
  const [previews, setPreviews] = useState({})
  const [uploadingId, setUploadingId] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [sourceFile, setSourceFile] = useState(null)
  const [aiConfig, setAiConfig] = useState({ count: 5, difficulty: 'medium', topic: '', total_marks: 5, question_types: ['mcq', 'short_answer'] })
  const [aiBusy, setAiBusy] = useState(false)
  const [drafts, setDrafts] = useState([])
  const [monitorEvents, setMonitorEvents] = useState([])
  const [gradeSuggestions, setGradeSuggestions] = useState([])
  const [gradeInputs, setGradeInputs] = useState({})

  const load = useCallback(async () => {
    const [examResponse, resultResponse, questionResponse, draftResponse, eventResponse, gradeResponse] = await Promise.all([
      supabase.from('exams').select('id,title,description,exam_type,pdf_storage_path,pdf_filename,pdf_size_bytes,pdf_enabled,published,duration_minutes,created_at').order('created_at', { ascending: false }),
      supabase.from('results').select('id,attempt_id,score,max_score,passed,published,review_status,created_at,exam:exams(title),student:profiles!results_student_id_fkey(full_name)').order('created_at', { ascending: false }).limit(30),
      supabase.from('questions').select('exam_id'),
      supabase.from('ai_question_drafts').select('id,exam_id,source_filename,questions,status,created_at').order('created_at', { ascending: false }).limit(20),
      supabase.from('exam_monitoring_events').select('id,event_type,occurred_at,attempt:exam_attempts(exam:exams(title),student:profiles!exam_attempts_student_id_fkey(full_name))').order('occurred_at', { ascending: false }).limit(100),
      supabase.from('ai_grade_suggestions').select('id,attempt_id,question_id,student_answer,suggested_marks,max_marks,explanation,confidence,status,reviewed_marks,question:questions(prompt),attempt:exam_attempts(exam:exams(title),student:profiles!exam_attempts_student_id_fkey(full_name))').order('created_at', { ascending: false }).limit(100),
    ])
    const loadError = examResponse.error || resultResponse.error || questionResponse.error || draftResponse.error || (eventResponse.error?.code !== '42P01' && eventResponse.error) || (gradeResponse.error?.code !== '42P01' && gradeResponse.error)
    if (loadError) setError(loadError.message)
    const counts = (questionResponse.data || []).reduce((all, item) => {
      all[item.exam_id] = (all[item.exam_id] || 0) + 1
      return all
    }, {})
    const ownedExams = (examResponse.data || []).map(exam => ({ ...exam, question_count: counts[exam.id] || 0 }))
    setExams(ownedExams)
    setResults(resultResponse.data || [])
    setDrafts(draftResponse.data || [])
    setMonitorEvents(eventResponse.data || [])
    setGradeSuggestions(gradeResponse.data || [])
    if (!examId && ownedExams.length) setExamId(ownedExams.find(exam => exam.exam_type === 'online')?.id || '')
  }, [examId])

  useEffect(() => {
    if (configured && (profile?.teacher_status === 'approved' || profile?.role === 'admin')) load()
  }, [load, profile?.role, profile?.teacher_status])

  const createExam = async event => {
    event.preventDefault()
    setError('')
    setNotice('')
    setBusy(true)
    const { data, error: createError } = await supabase.from('exams').insert({
      teacher_id: profile.id,
      title: title.trim(),
      description: description.trim(),
      duration_minutes: Number(duration),
      passing_marks: Number(passing),
      exam_type: examType,
      monitoring_enabled: monitoringEnabled,
      camera_required: cameraRequired,
    }).select('id').single()
    setBusy(false)
    if (createError) {
      setError(createError.message)
      return
    }
    setTitle('')
    setDescription('')
    setExamId(examType === 'online' ? data.id : (exams.find(exam => exam.exam_type === 'online')?.id || ''))
    setNotice(examType === 'pdf' ? 'PDF exam draft created. Upload the question paper below.' : 'Exam draft created. Add questions, then publish it.')
    await load()
  }

  const generateQuestions = async event => {
    event.preventDefault()
    setError(''); setNotice('')
    const target = exams.find(item => item.id === examId)
    if (!target || target.published) { setError('Choose an unpublished online exam first.'); return }
    try {
      await validatePdf(sourceFile)
      setAiBusy(true)
      const { data: { user }, error: authError } = await supabase.auth.getUser()
      if (authError) throw authError
      if (!user) throw new Error('Your session expired. Sign in again and retry.')
      const path = `${target.id}/${user.id}/${crypto.randomUUID()}.pdf`
      const { error: uploadError } = await supabase.storage.from('ai-question-sources').upload(path, sourceFile, { contentType: 'application/pdf', upsert: false })
      if (uploadError) throw uploadError
      const { data, error: functionError } = await supabase.functions.invoke('ai-generate-questions', { body: { exam_id: target.id, storage_path: path, filename: sourceFile.name, ...aiConfig } })
      if (functionError) throw functionError
      if (data?.error) throw new Error(data.error)
      setSourceFile(null)
      setNotice(`Generated ${data.draft.questions.length} draft questions. Review each answer key before approving.`)
      await load()
    } catch (generationError) { setError(generationError.message || 'Could not generate questions.') }
    finally { setAiBusy(false) }
  }

  const approveDraft = async draft => {
    setError('')
    const target = exams.find(item => item.id === draft.exam_id)
    if (!target || target.published) { setError('This draft exam is no longer editable.'); return }
    const rows = draft.questions || []
    const normalized = rows.map(row => ({ ...row, prompt: String(row.prompt || '').trim(), options: Array.isArray(row.options) ? row.options : ['', ''] }))
    if (normalized.some(row => !row.prompt || !row.answer_key?.trim())) { setError('Every question needs a prompt and answer key.'); return }
    const seen = new Set()
    if (normalized.some(row => { const key = row.prompt.toLowerCase().replace(/\s+/g, ' '); if (seen.has(key)) return true; seen.add(key); return false })) { setError('Remove duplicate questions before approval.'); return }
    const records = []
    for (const row of normalized) {
      const kind = row.question_type
      const correct = kind === 'mcq' || kind === 'true_false' ? row.options.findIndex(option => option.trim().toLowerCase() === row.answer_key.trim().toLowerCase()) : 0
      if ((kind === 'mcq' || kind === 'true_false') && correct < 0) { setError(`Answer key must match an option for: ${row.prompt}`); return }
      records.push({ exam_id: draft.exam_id, prompt: row.prompt, description: row.explanation || '', options: kind === 'mcq' ? row.options : kind === 'true_false' ? ['True', 'False'] : ['', ''], correct_answer: correct, points: Number(row.points) || 1, position: Date.now() % 100000 + records.length, question_type: kind, answer_key: row.answer_key.trim(), grading_rubric: row.grading_rubric || '' })
    }
    const { error: insertError } = await supabase.from('questions').insert(records)
    if (insertError) { setError(insertError.message); return }
    const { error: updateError } = await supabase.from('ai_question_drafts').update({ status: 'approved', reviewed_at: new Date().toISOString() }).eq('id', draft.id)
    if (updateError) setError(`Questions saved, but draft status was not updated: ${updateError.message}`)
    else { setNotice('Teacher-approved questions added to the exam. Edit them below before publishing if needed.'); await load() }
  }

  const generateGrades = async attemptId => {
    setError('')
    const { data, error: functionError } = await supabase.functions.invoke('ai-grade-answer', { body: { attempt_id: attemptId } })
    if (functionError || data?.error) { setError(functionError?.message || data?.error); return }
    setNotice(`Created ${data.suggestions?.length || 0} grading suggestions. Review each before publishing results.`)
    await load()
  }

  const reviewSuggestion = async (suggestion, marks, approve) => {
    const value = Number(marks)
    if (!Number.isFinite(value) || value < 0 || value > Number(suggestion.max_marks)) { setError(`Marks must be between 0 and ${suggestion.max_marks}.`); return }
    const { data: { user } } = await supabase.auth.getUser()
    const { error: reviewError } = await supabase.from('ai_grade_suggestions').update({ status: approve ? 'approved' : 'rejected', reviewed_marks: approve ? value : 0, reviewed_by: user.id, reviewed_at: new Date().toISOString() }).eq('id', suggestion.id)
    if (reviewError) setError(reviewError.message)
    else await load()
  }

  const addQuestion = async event => {
    event.preventDefault()
    setError('')
    setBusy(true)
    const { error: insertError } = await supabase.from('questions').insert({
      exam_id: examId,
      prompt: question.trim(),
      options,
      correct_answer: Number(correct),
      position: Date.now() % 100000,
    })
    setBusy(false)
    if (insertError) setError(insertError.message)
    else {
      setQuestion('')
      setOptions(emptyOptions)
      setNotice('Question added.')
      await load()
    }
  }

  const setSelectedFile = (id, file) => {
    setFiles(current => ({ ...current, [id]: file }))
    setError('')
  }

  const uploadPaper = async exam => {
    const file = files[exam.id]
    setError('')
    try {
      await validatePdf(file)
      setUploadingId(exam.id)
      setProgress(current => ({ ...current, [exam.id]: 0 }))
      const path = `${exam.id}/${crypto.randomUUID()}.pdf`
      await uploadExamPaper(file, path, value => setProgress(current => ({ ...current, [exam.id]: value })))
      const { error: saveError } = await supabase.from('exams').update({
        pdf_storage_path: path,
        pdf_filename: file.name,
        pdf_size_bytes: file.size,
        pdf_enabled: true,
      }).eq('id', exam.id).select('id').single()
      if (saveError) {
        await removeExamPaper(path).catch(() => {})
        throw saveError
      }
      if (exam.pdf_storage_path) {
        try { await removeExamPaper(exam.pdf_storage_path) }
        catch { setNotice('PDF saved, but the previous file could not be removed. Contact an administrator to clean up the old private file.') }
      }
      const signedUrl = await createExamPaperSignedUrl(path)
      setPreviews(current => ({ ...current, [exam.id]: { path, url: signedUrl } }))
      setFiles(current => ({ ...current, [exam.id]: null }))
      setNotice(`Uploaded ${file.name}. Preview it before publishing.`)
      await load()
    } catch (uploadError) {
      setError(uploadError.message || 'Could not upload the PDF.')
    } finally {
      setUploadingId('')
    }
  }

  const removePaper = async exam => {
    if (!confirm(`Remove ${exam.pdf_filename || 'this question paper'} from ${exam.title}?`)) return
    setError('')
    setBusy(true)
    const { error: detachError } = await supabase.from('exams').update({
      published: false,
      pdf_storage_path: null,
      pdf_filename: null,
      pdf_size_bytes: null,
    }).eq('id', exam.id).select('id').single()
    if (detachError) {
      setBusy(false)
      setError(detachError.message)
      return
    }
    try {
      await removeExamPaper(exam.pdf_storage_path)
      setNotice('Question paper removed. The exam is now an unpublished PDF draft.')
    } catch (removeError) {
      setError(`The paper was detached, but Storage could not remove the old file: ${removeError.message}`)
    }
    setPreviews(current => { const next = { ...current }; delete next[exam.id]; return next })
    setBusy(false)
    await load()
  }

  const previewPaper = async exam => {
    setError('')
    try {
      const url = await createExamPaperSignedUrl(exam.pdf_storage_path)
      setPreviews(current => ({ ...current, [exam.id]: { path: exam.pdf_storage_path, url } }))
    } catch (previewError) {
      setError(`Could not open the private PDF: ${previewError.message}`)
    }
  }

  const publishExam = async exam => {
    setError('')
    const { error: publishError } = await supabase.from('exams').update({ published: true }).eq('id', exam.id)
    if (publishError) setError(publishError.message)
    else {
      setNotice('Exam published.')
      await load()
    }
  }

  const publishResult = async resultId => {
    const { error: publishError } = await supabase.rpc('review_exam_grade', { p_result: resultId, p_publish: true })
    if (publishError) setError(publishError.message)
    else { setNotice('Result published.'); await load() }
  }

  const deleteExam = async exam => {
    if (!confirm(`Delete the exam “${exam.title}”? This cannot be undone.`)) return
    const { count, error: countError } = await supabase.from('exam_attempts').select('id', { count: 'exact', head: true }).eq('exam_id', exam.id)
    if (countError) { setError(countError.message); return }
    if (count) { setError('This exam has student attempts and cannot be deleted.'); return }
    if (exam.pdf_storage_path) {
      const { error: detachError } = await supabase.from('exams').update({ published: false, pdf_storage_path: null, pdf_filename: null, pdf_size_bytes: null }).eq('id', exam.id)
      if (detachError) { setError(detachError.message); return }
      try { await removeExamPaper(exam.pdf_storage_path) }
      catch (removeError) { setError(`Could not remove the private paper, so the exam was kept: ${removeError.message}`); return }
    }
    const { error: deleteError } = await supabase.from('exams').delete().eq('id', exam.id)
    if (deleteError) setError(deleteError.message)
    else { setNotice('Exam deleted.'); await load() }
  }

  if (!configured) return <div className="notice">Configure Supabase to manage exams.</div>
  if (profile?.teacher_status !== 'approved' && profile?.role !== 'admin') return <div className="notice">Teacher access must be approved before you can create or manage exams.</div>

  const onlineExams = exams.filter(exam => exam.exam_type === 'online')
  const canManagePdfs = profile.role === 'teacher' && profile.teacher_status === 'approved'
  const publishedCount = exams.filter(exam => exam.published).length
  const average = results.length ? `${Math.round(results.reduce((sum, row) => sum + (row.max_score ? row.score / row.max_score * 100 : 0), 0) / results.length)}%` : '—'

  return <>
    <div className="row between"><div><h2 style={{ marginBottom: 4 }}>Teaching overview</h2><p className="muted small">Create online exams or publish a private PDF question paper.</p></div><span className="badge">{profile.role === 'admin' ? 'ADMIN' : 'APPROVED TEACHER'}</span></div>
    {error && <div className="error">{error}</div>}{notice && <div className="success">{notice}</div>}
    <div className="grid stats"><Metric label="Your exams" value={exams.length}/><Metric label="Published" value={publishedCount}/><Metric label="Student results" value={results.length}/><Metric label="Average score" value={average}/></div>

    <div className="grid" style={{ gridTemplateColumns: 'minmax(280px,1fr) minmax(320px,1.2fr)' }}>
      <section className="card">
        <h2 style={{ fontSize: 17 }}>Create an exam</h2>
        <form onSubmit={createExam}>
          <Field label="Exam title"><input className="input" required maxLength={160} value={title} onChange={event => setTitle(event.target.value)} placeholder="e.g. Algebra foundations"/></Field>
          <Field label="Description"><textarea className="input" value={description} onChange={event => setDescription(event.target.value)} rows="3" placeholder="What will students be assessed on?"/></Field>
          <div className="row"><Field label="Duration (minutes)"><input className="input" type="number" min="1" max="600" value={duration} onChange={event => setDuration(event.target.value)}/></Field><Field label="Passing marks"><input className="input" type="number" min="0" step="0.5" value={passing} onChange={event => setPassing(event.target.value)}/></Field></div>
          <fieldset className="exam-type-picker"><legend>Question format</legend>
            <label className={`exam-type-option ${examType === 'online' ? 'selected' : ''}`}><input type="radio" name="exam-type" value="online" checked={examType === 'online'} onChange={() => setExamType('online')}/><span><b>Online questions</b><small>Add questions and answer options in ExamGuard.</small></span></label>
            <label className={`exam-type-option ${examType === 'pdf' ? 'selected' : ''}`}><input type="radio" name="exam-type" value="pdf" checked={examType === 'pdf'} disabled={!canManagePdfs} onChange={() => setExamType('pdf')}/><span><b>PDF question paper</b><small>{canManagePdfs ? 'Upload a paper for students to view during the timed exam.' : 'PDF uploads are available to approved teacher owners.'}</small></span></label>
          </fieldset>
          <fieldset className="exam-type-picker"><legend>Monitoring and privacy</legend>
            <label className="exam-type-option"><input type="checkbox" checked={monitoringEnabled} onChange={event => setMonitoringEnabled(event.target.checked)}/><span><b>Record focus and tab changes</b><small>Stores event timestamps for teacher review. Never an automatic misconduct decision.</small></span></label>
            <label className="exam-type-option"><input type="checkbox" checked={cameraRequired} onChange={event => setCameraRequired(event.target.checked)}/><span><b>Request optional webcam checks</b><small>Students must explicitly grant permission; no video is stored. Face checks depend on browser support.</small></span></label>
          </fieldset>
          <button className="btn" disabled={busy}>{busy ? 'Creating...' : 'Create draft exam'}</button>
        </form>
      </section>

      <section className="card">
        <h2 style={{ fontSize: 17 }}>Add an online question</h2>
        {!onlineExams.length ? <p className="muted small">Create an online exam first. PDF exams use the uploaded paper instead.</p> : <>
          <Field label="Choose online exam"><select className="input" value={examId} onChange={event => setExamId(event.target.value)}><option value="">Select...</option>{onlineExams.map(exam => <option key={exam.id} value={exam.id}>{exam.title}</option>)}</select></Field>
          {examId && <form onSubmit={addQuestion}>
            <Field label="Question"><textarea className="input" required value={question} onChange={event => setQuestion(event.target.value)} rows="2"/></Field>
            {options.map((option, index) => <Field key={index} label={`Option ${index + 1}`}><input className="input" required value={option} onChange={event => setOptions(current => current.map((item, itemIndex) => itemIndex === index ? event.target.value : item))}/></Field>)}
            <Field label="Correct answer"><select className="input" value={correct} onChange={event => setCorrect(event.target.value)}>{options.map((_, index) => <option key={index} value={index}>Option {index + 1}</option>)}</select></Field>
            <button className="btn" disabled={busy}>Add question</button>
          </form>}
        </>}
      </section>
    </div>

    <section className="card" style={{ marginTop: 18 }}>
      <div className="row between"><div><h2 style={{ fontSize: 17, marginBottom: 4 }}>AI Question Generator</h2><p className="muted small">Upload a source PDF to a private bucket. Generated questions stay drafts until you approve them.</p></div><span className="badge">TEACHER REVIEW REQUIRED</span></div>
      <form onSubmit={generateQuestions} className="grid" style={{ gridTemplateColumns: 'repeat(auto-fit,minmax(170px,1fr))', alignItems: 'end' }}>
        <Field label="Unpublished online exam"><select className="input" value={examId} onChange={event => setExamId(event.target.value)} required><option value="">Select exam</option>{onlineExams.filter(exam => !exam.published).map(exam => <option key={exam.id} value={exam.id}>{exam.title}</option>)}</select></Field>
        <Field label="Source PDF"><input className="input" type="file" accept="application/pdf,.pdf" onChange={event => setSourceFile(event.target.files?.[0] || null)} required /></Field>
        <Field label="Question count"><input className="input" type="number" min="1" max="40" value={aiConfig.count} onChange={event => setAiConfig(c => ({ ...c, count: Number(event.target.value) }))}/></Field>
        <Field label="Difficulty"><select className="input" value={aiConfig.difficulty} onChange={event => setAiConfig(c => ({ ...c, difficulty: event.target.value }))}>{['easy','medium','hard','mixed'].map(value => <option key={value}>{value}</option>)}</select></Field>
        <Field label="Topic"><input className="input" maxLength="160" value={aiConfig.topic} onChange={event => setAiConfig(c => ({ ...c, topic: event.target.value }))} placeholder="All relevant topics"/></Field>
        <Field label="Total marks"><input className="input" type="number" min="1" max="500" value={aiConfig.total_marks} onChange={event => setAiConfig(c => ({ ...c, total_marks: Number(event.target.value) }))}/></Field>
        <Field label="Question types"><div className="small">{[['mcq','Multiple choice'],['true_false','True / false'],['fill_blank','Fill in blanks'],['short_answer','Short answer'],['long_answer','Long answer']].map(([value,label]) => <label key={value} style={{ display: 'block', margin: '5px 0' }}><input type="checkbox" checked={aiConfig.question_types.includes(value)} onChange={event => setAiConfig(c => ({ ...c, question_types: event.target.checked ? [...c.question_types,value] : c.question_types.filter(item => item !== value) }))}/> {label}</label>)}</div></Field>
        <button className="btn" disabled={aiBusy || !sourceFile}>{aiBusy ? 'Reading PDF and generating…' : 'Generate draft questions'}</button>
      </form>
      <p className="muted small">Scanned PDF OCR is handled by the configured AI PDF input. Large, encrypted, or unreadable PDFs return an error; the source stays in private Storage.</p>
    </section>

    <div className="section-heading"><h2>Generated question drafts</h2></div>
    <div className="grid">{drafts.filter(draft => draft.status === 'needs_review').map(draft => <section className="card" key={draft.id}>
      <div className="row between"><div><span className="badge pending">NEEDS REVIEW</span><h3>{draft.source_filename}</h3><p className="muted small">{exams.find(item => item.id === draft.exam_id)?.title || 'Exam'} · {draft.questions.length} suggestions · {new Date(draft.created_at).toLocaleString()}</p></div><button className="btn" onClick={() => approveDraft(draft)}>Approve and add all</button></div>
      {(draft.questions || []).map((item, index) => <article className="generated-question" key={index}>
        <div className="row between"><b>Question {index + 1}</b><span className="badge">{item.question_type} · {item.points} marks</span></div>
        <Field label="Prompt"><textarea className="input" value={item.prompt} onChange={event => setDrafts(current => current.map(row => row.id === draft.id ? { ...row, questions: row.questions.map((q, i) => i === index ? { ...q, prompt: event.target.value } : q) } : row))}/></Field>
        {item.question_type === 'mcq' && (item.options || []).map((option, optionIndex) => <Field key={optionIndex} label={`Option ${optionIndex + 1}`}><input className="input" value={option} onChange={event => setDrafts(current => current.map(row => row.id === draft.id ? { ...row, questions: row.questions.map((q, i) => i === index ? { ...q, options: q.options.map((v, oi) => oi === optionIndex ? event.target.value : v) } : q) } : row))}/></Field>)}
        <Field label="Suggested answer key (verify against PDF)"><textarea className="input" value={item.answer_key} onChange={event => setDrafts(current => current.map(row => row.id === draft.id ? { ...row, questions: row.questions.map((q, i) => i === index ? { ...q, answer_key: event.target.value } : q) } : row))}/></Field>
        <Field label="Grading rubric"><textarea className="input" value={item.grading_rubric || ''} onChange={event => setDrafts(current => current.map(row => row.id === draft.id ? { ...row, questions: row.questions.map((q, i) => i === index ? { ...q, grading_rubric: event.target.value } : q) } : row))}/></Field>
        <p className="muted small">AI note: {item.explanation}</p>
      </article>)}
      <button className="btn danger" onClick={async () => { const { error: discardError } = await supabase.from('ai_question_drafts').update({ status: 'discarded', reviewed_at: new Date().toISOString() }).eq('id', draft.id); if (discardError) setError(discardError.message); else await load() }}>Discard draft</button>
    </section>)}{!drafts.some(draft => draft.status === 'needs_review') && <div className="card muted small">No question drafts need review.</div>}</div>

    <div className="section-heading"><h2>Manage your exams</h2></div>
    <div className="grid">
      {exams.map(exam => <section className="card" key={exam.id}>
        <div className="row between"><div><div className="row"><span className="badge">{exam.exam_type === 'pdf' ? 'PDF PAPER' : 'ONLINE'}</span><span className={`badge ${exam.published ? '' : 'pending'}`}>{exam.published ? 'Published' : 'Draft'}</span></div><h3>{exam.title}</h3><p className="muted small">{exam.duration_minutes} min · {exam.exam_type === 'pdf' ? 'PDF question paper' : `${exam.question_count} questions`}</p></div>{(!exam.pdf_storage_path || canManagePdfs) && <button className="btn danger" onClick={() => deleteExam(exam)}>Delete exam</button>}</div>
        {exam.exam_type === 'pdf' && (canManagePdfs ? <PdfUploadCard exam={exam} file={files[exam.id]} onFile={file => setSelectedFile(exam.id, file)} progress={progress[exam.id] || 0} uploading={uploadingId === exam.id} preview={previews[exam.id]} onUpload={() => uploadPaper(exam)} onRemove={() => removePaper(exam)} onPreview={() => previewPaper(exam)} /> : <p className="muted small">Private PDF metadata: {exam.pdf_filename || 'Not uploaded'}{exam.pdf_size_bytes ? ` · ${formatFileSize(exam.pdf_size_bytes)}` : ''}. Only its approved teacher owner can manage or preview the file.</p>)}
        {exam.exam_type === 'online' && exam.question_count === 0 && <div className="notice">Add at least one question before publishing this exam.</div>}
        {!exam.published && <button className="btn" disabled={busy || (exam.exam_type === 'pdf' ? !exam.pdf_storage_path || !exam.pdf_enabled : exam.question_count === 0)} onClick={() => publishExam(exam)}>{exam.exam_type === 'pdf' && !exam.pdf_storage_path ? 'Upload a PDF to publish' : 'Publish exam'}</button>}
      </section>)}
      {!exams.length && <div className="card muted small">No exams created yet.</div>}
    </div>

    <div className="section-heading"><h2>AI grading dashboard</h2><span className="muted small">AI grades stay unpublished until teacher review.</span></div>
    <div className="card table-wrap"><table><thead><tr><th>Student</th><th>Exam</th><th>Score</th><th>Review status</th><th>Actions</th></tr></thead><tbody>{results.map(result => <tr key={result.id}><td>{result.student?.full_name || 'Student'}</td><td>{result.exam?.title}</td><td>{result.score} / {result.max_score}</td><td>{result.review_status}</td><td><div className="row">{resultReviewRequiredStatuses.has(result.review_status) && <button className="btn secondary" onClick={() => generateGrades(result.attempt_id)}>Suggest descriptive grades</button>}{result.published ? 'Published' : <button className="btn" onClick={() => publishResult(result.id)}>Review and publish</button>}</div></td></tr>)}</tbody></table>{!results.length && <p className="muted small">Submitted online exams appear here.</p>}</div>
    <div className="grid" style={{ marginTop: 14 }}>{gradeSuggestions.map(suggestion => <article className="card" key={suggestion.id}>
      <div className="row between"><div><span className={`badge ${suggestion.status === 'needs_review' ? 'pending' : ''}`}>{suggestion.status}</span><h3>{suggestion.question?.prompt || 'Descriptive answer'}</h3><p className="muted small">{suggestion.attempt?.exam?.title} · {suggestion.attempt?.student?.full_name || 'Student'} · AI confidence: {suggestion.confidence}</p></div><span className="badge">{suggestion.suggested_marks} / {suggestion.max_marks} suggested</span></div>
      <blockquote className="student-answer">{suggestion.student_answer}</blockquote><p className="small">AI explanation: {suggestion.explanation}</p>
      {suggestion.status === 'needs_review' && <div className="row"><Field label="Teacher marks"><input className="input" type="number" min="0" max={suggestion.max_marks} step="0.5" value={gradeInputs[suggestion.id] ?? suggestion.suggested_marks} onChange={event => setGradeInputs(current => ({ ...current, [suggestion.id]: event.target.value }))}/></Field><button className="btn" onClick={() => reviewSuggestion(suggestion, gradeInputs[suggestion.id] ?? suggestion.suggested_marks, true)}>Approve marks</button><button className="btn danger" onClick={() => reviewSuggestion(suggestion, 0, false)}>Reject suggestion</button></div>}
    </article>)}{!gradeSuggestions.length && <div className="card muted small">No descriptive answer evaluations yet.</div>}</div>

    <div className="section-heading"><h2>Exam monitoring report</h2><span className="muted small">Events are review signals only; no automatic misconduct decisions.</span></div>
    <div className="card table-wrap"><table><thead><tr><th>Time</th><th>Exam</th><th>Student</th><th>Event</th></tr></thead><tbody>{monitorEvents.map(event => <tr key={event.id}><td>{new Date(event.occurred_at).toLocaleString()}</td><td>{event.attempt?.exam?.title || 'Exam'}</td><td>{event.attempt?.student?.full_name || 'Student'}</td><td><span className="badge pending">{event.event_type.replaceAll('_', ' ')}</span></td></tr>)}</tbody></table>{!monitorEvents.length && <p className="muted small">No monitoring events have been reported.</p>}</div>
  </>
}

function PdfUploadCard({ exam, file, onFile, progress, uploading, preview, onUpload, onRemove, onPreview }) {
  const choose = event => onFile(event.target.files?.[0] || null)
  return <div className="pdf-upload-card">
    <div className="row"><FileText size={20}/><div><b>{exam.pdf_filename || 'Question paper PDF'}</b><div className="muted small">{exam.pdf_size_bytes ? formatFileSize(exam.pdf_size_bytes) : 'No PDF attached yet'}</div></div></div>
    <label className="pdf-dropzone" onDragOver={event => event.preventDefault()} onDrop={event => { event.preventDefault(); onFile(event.dataTransfer.files?.[0] || null) }}>
      <Upload size={22}/><b>Drop a PDF here or browse files</b><span className="muted small">PDF only · Maximum 20 MB</span><input type="file" accept="application/pdf,.pdf" onChange={choose} disabled={uploading}/>
    </label>
    {file && <div className="pdf-selected row between"><span>{file.name} · {formatFileSize(file.size)}</span><button type="button" className="btn ghost" aria-label="Remove selected file" onClick={() => onFile(null)}><X size={16}/></button></div>}
    {uploading && <div className="pdf-progress-wrap"><div className="row between small"><span>Uploading PDF...</span><b>{progress}%</b></div><progress className="pdf-progress" max="100" value={progress}/></div>}
    <div className="row pdf-actions"><button className="btn" disabled={!file || uploading} onClick={onUpload}>{uploading ? 'Uploading...' : exam.pdf_storage_path ? 'Replace PDF' : 'Upload PDF'}</button>{exam.pdf_storage_path && <><button className="btn secondary" disabled={uploading} onClick={onPreview}><Eye size={15}/> Preview</button><button className="btn danger" disabled={uploading} onClick={onRemove}>Remove PDF</button></>}</div>
    {preview?.path === exam.pdf_storage_path && <div className="pdf-preview"><div className="row between"><b>PDF preview</b><a href={preview.url} target="_blank" rel="noreferrer">Open in new tab</a></div><iframe title={`Preview of ${exam.pdf_filename}`} src={`${preview.url}#toolbar=1&navpanes=1&zoom=page-width`} /></div>}
  </div>
}

function Metric({ label, value }) { return <div className="card"><div className="stat-label">{label}</div><div className="stat-value">{value}</div></div> }
function Field({ label, children }) { return <div className="field"><label>{label}</label>{children}</div> }
