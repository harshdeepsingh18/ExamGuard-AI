import { useCallback, useEffect, useState } from 'react'
import { FileText, Upload, X, Eye, RefreshCw } from 'lucide-react'
import { supabase, configured } from '../lib/supabase'
import { useAuth } from '../context/AuthContext'
import { createExamPaperSignedUrl, formatFileSize, removeExamPaper, uploadExamPaper, validatePdf } from '../lib/examPapers'

const emptyOptions = ['', '', '', '']

export function Teacher() {
  const { profile } = useAuth()
  const [exams, setExams] = useState([])
  const [results, setResults] = useState([])
  const [title, setTitle] = useState('')
  const [description, setDescription] = useState('')
  const [duration, setDuration] = useState(30)
  const [passing, setPassing] = useState(1)
  const [examType, setExamType] = useState('online')
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

  const load = useCallback(async () => {
    const [examResponse, resultResponse, questionResponse] = await Promise.all([
      supabase.from('exams').select('id,title,description,exam_type,pdf_storage_path,pdf_filename,pdf_size_bytes,pdf_enabled,published,duration_minutes,created_at').order('created_at', { ascending: false }),
      supabase.from('results').select('id,score,max_score,passed,published,created_at,exam:exams(title),student:profiles!results_student_id_fkey(full_name)').order('created_at', { ascending: false }).limit(30),
      supabase.from('questions').select('exam_id'),
    ])
    const loadError = examResponse.error || resultResponse.error || questionResponse.error
    if (loadError) setError(loadError.message)
    const counts = (questionResponse.data || []).reduce((all, item) => {
      all[item.exam_id] = (all[item.exam_id] || 0) + 1
      return all
    }, {})
    const ownedExams = (examResponse.data || []).map(exam => ({ ...exam, question_count: counts[exam.id] || 0 }))
    setExams(ownedExams)
    setResults(resultResponse.data || [])
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
    }).select('id').single()
    setBusy(false)
    if (createError) {
      setError(createError.message)
      return
    }
    setTitle('')
    setDescription('')
    setExamId(data.id)
    setNotice(examType === 'pdf' ? 'PDF exam draft created. Upload the question paper below.' : 'Exam draft created. Add questions, then publish it.')
    await load()
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
    const { error: publishError } = await supabase.from('results').update({ published: true }).eq('id', resultId)
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
            <label className={`exam-type-option ${examType === 'pdf' ? 'selected' : ''}`}><input type="radio" name="exam-type" value="pdf" checked={examType === 'pdf'} onChange={() => setExamType('pdf')}/><span><b>PDF question paper</b><small>Upload a paper for students to view during the timed exam.</small></span></label>
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

    <div className="section-heading"><h2>Manage your exams</h2></div>
    <div className="grid">
      {exams.map(exam => <section className="card" key={exam.id}>
        <div className="row between"><div><div className="row"><span className="badge">{exam.exam_type === 'pdf' ? 'PDF PAPER' : 'ONLINE'}</span><span className={`badge ${exam.published ? '' : 'pending'}`}>{exam.published ? 'Published' : 'Draft'}</span></div><h3>{exam.title}</h3><p className="muted small">{exam.duration_minutes} min · {exam.exam_type === 'pdf' ? 'PDF question paper' : `${exam.question_count} questions`}</p></div><button className="btn danger" onClick={() => deleteExam(exam)}>Delete exam</button></div>
        {exam.exam_type === 'pdf' && <PdfUploadCard exam={exam} file={files[exam.id]} onFile={file => setSelectedFile(exam.id, file)} progress={progress[exam.id] || 0} uploading={uploadingId === exam.id} preview={previews[exam.id]} onUpload={() => uploadPaper(exam)} onRemove={() => removePaper(exam)} onPreview={() => previewPaper(exam)} />}
        {exam.exam_type === 'online' && exam.question_count === 0 && <div className="notice">Add at least one question before publishing this exam.</div>}
        {!exam.published && <button className="btn" disabled={busy || (exam.exam_type === 'pdf' ? !exam.pdf_storage_path || !exam.pdf_enabled : exam.question_count === 0)} onClick={() => publishExam(exam)}>{exam.exam_type === 'pdf' && !exam.pdf_storage_path ? 'Upload a PDF to publish' : 'Publish exam'}</button>}
      </section>)}
      {!exams.length && <div className="card muted small">No exams created yet.</div>}
    </div>

    <div className="section-heading"><h2>Recent online results</h2></div>
    <div className="card table-wrap"><table><thead><tr><th>Student</th><th>Exam</th><th>Score</th><th>Result</th><th>Visibility</th></tr></thead><tbody>{results.map(result => <tr key={result.id}><td>{result.student?.full_name || 'Student'}</td><td>{result.exam?.title}</td><td>{result.score} / {result.max_score}</td><td>{result.passed ? 'Passed' : 'Not passed'}</td><td>{result.published ? 'Published' : <button className="btn secondary" onClick={() => publishResult(result.id)}>Publish result</button>}</td></tr>)}</tbody></table>{!results.length && <p className="muted small">Online results appear after students submit exams.</p>}</div>
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
