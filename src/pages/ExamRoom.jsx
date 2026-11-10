import { useCallback, useEffect, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { CheckCircle2, Clock3, ExternalLink, FileText, RefreshCw } from 'lucide-react'
import { configured, supabase } from '../lib/supabase'
import { useAuth } from '../context/AuthContext'
import { createExamPaperSignedUrl, formatFileSize } from '../lib/examPapers'

export function ExamRoom() {
  const { id } = useParams()
  const navigate = useNavigate()
  const { profile } = useAuth()
  const [exam, setExam] = useState(null)
  const [paper, setPaper] = useState(null)
  const [answers, setAnswers] = useState({})
  const [seconds, setSeconds] = useState(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [result, setResult] = useState(null)
  const [expired, setExpired] = useState(false)
  const [submitted, setSubmitted] = useState(false)
  const [showPaper, setShowPaper] = useState(false)
  const [reportReason, setReportReason] = useState('')
  const [reportMessage, setReportMessage] = useState('')
  const timerActive = seconds !== null && !result && !expired && !submitted

  useEffect(() => {
    if (!configured) { setError('Connect Supabase before starting an exam.'); setLoading(false); return }
    let active = true
    const openExam = async () => {
      const { data, error: startError } = await supabase.rpc('start_exam', { p_exam: id })
      if (!active) return
      if (startError) {
        setError(startError.message)
        setLoading(false)
        return
      }
      const { data: paperData, error: paperError } = await supabase.from('exams')
        .select('exam_type,pdf_storage_path,pdf_filename,pdf_size_bytes,pdf_enabled')
        .eq('id', id).single()
      if (!active) return
      if (paperError) {
        setError(paperError.message)
        setLoading(false)
        return
      }
      setExam(data)
      setPaper(paperData)
      setAnswers(Object.fromEntries((data.saved_answers || []).map(answer => [answer.question_id, answer.selected_answer])))
      const elapsed = Math.floor((Date.now() - new Date(data.attempt_started_at).getTime()) / 1000)
      setSeconds(Math.max(0, data.exam.duration_minutes * 60 - elapsed))
      setLoading(false)
    }
    openExam()
    return () => { active = false }
  }, [id])

  const submit = useCallback(async () => {
    if (busy || expired || submitted || !exam || !configured) return
    if (paper?.exam_type === 'pdf' && !confirm('Finish and submit this PDF exam?')) return
    setBusy(true)
    const p_answers = Object.entries(answers).map(([question_id, selected_answer]) => ({ question_id, selected_answer }))
    const { data, error: submitError } = await supabase.rpc('submit_exam', { p_attempt: exam.attempt_id, p_answers })
    setBusy(false)
    if (submitError) setError(submitError.message)
    else if (data?.expired) setExpired(true)
    else if (data?.pdf_only) setSubmitted(true)
    else setResult(data)
  }, [answers, busy, expired, exam, paper?.exam_type, submitted])

  useEffect(() => {
    if (!exam || paper?.exam_type === 'pdf' || !Object.keys(answers).length || result || expired || submitted || !configured) return
    const timer = setTimeout(() => {
      const p_answers = Object.entries(answers).map(([question_id, selected_answer]) => ({ question_id, selected_answer }))
      supabase.rpc('save_exam_answers', { p_attempt: exam.attempt_id, p_answers }).then(({ error: saveError }) => {
        if (saveError) setError(saveError.message)
      })
    }, 350)
    return () => clearTimeout(timer)
  }, [answers, exam, expired, paper?.exam_type, result, submitted])

  useEffect(() => {
    if (!timerActive) return
    const timer = setInterval(() => setSeconds(value => value <= 1 ? 0 : value - 1), 1000)
    return () => clearInterval(timer)
  }, [timerActive])

  useEffect(() => {
    if (seconds === 0 && !busy && !result && !expired && !submitted) submit()
  }, [seconds, busy, result, expired, submitted, submit])

  const refreshPaperUrl = useCallback(async () => {
    if (!paper?.pdf_storage_path) return
    setError('')
    try {
      const url = await createExamPaperSignedUrl(paper.pdf_storage_path, 600)
      setShowPaper(true)
      setPaper(current => ({ ...current, signedUrl: url }))
    } catch (urlError) {
      setError(`The question paper could not be opened: ${urlError.message}`)
    }
  }, [paper?.pdf_storage_path])

  useEffect(() => {
    if (!showPaper || !paper?.pdf_storage_path) return
    const refreshTimer = setInterval(refreshPaperUrl, 8 * 60 * 1000)
    return () => clearInterval(refreshTimer)
  }, [showPaper, paper?.pdf_storage_path, refreshPaperUrl])

  const reportPaper = async event => {
    event.preventDefault()
    const { error: reportError } = await supabase.from('exam_pdf_reports').insert({ exam_id: id, reporter_id: profile.id, reason: reportReason.trim() })
    if (reportError) setReportMessage(reportError.message)
    else { setReportMessage('Report sent to the admin team.'); setReportReason('') }
  }

  if (loading) return <div className="center-screen"><div className="spinner"/></div>
  if (error && !exam) return <div className="card"><div className="error">{error}</div><button className="btn secondary" onClick={() => navigate('/exams')}>Back to exams</button></div>
  if (expired) return <CompletionCard title="Time is up" message="Your attempt was marked as expired." onBack={() => navigate('/exams')}/>
  if (submitted) return <CompletionCard title="Exam submitted" message="Your PDF exam attempt was recorded. This paper is not automatically graded online." onBack={() => navigate('/exams')}/>
  if (result) return <div className="card exam-completion"><CheckCircle2 size={44} color="#43a36a"/><div className="badge" style={{ marginTop: 14 }}>{result.passed ? 'PASSED' : 'RESULT'}</div><h2>{exam.exam.title}</h2><div className="exam-score">{result.score}<span className="muted"> / {result.max_score}</span></div><p className="muted">{result.passed ? 'Great work. Your result has been saved.' : 'Your result has been saved. Keep practicing.'}</p><button className="btn" onClick={() => navigate('/exams')}>Back to exam library</button></div>

  const pdfOnly = paper?.exam_type === 'pdf'
  return <>
    <header className="exam-room-header">
      <div><div className="badge">EXAM IN PROGRESS</div><h2>{exam.exam.title}</h2><p className="muted small">{exam.exam.description}</p></div>
      <div className="exam-clock"><Clock3 size={17}/><span>{Math.floor(seconds / 60)}:{String(seconds % 60).padStart(2, '0')}</span></div>
    </header>
    {error && <div className="error">{error}</div>}

    {pdfOnly ? <section className="card pdf-student-card">
      <div className="row"><FileText size={26}/><div><h3>{paper.pdf_filename || 'Question paper PDF'}</h3><p className="muted small">{paper.pdf_size_bytes ? formatFileSize(paper.pdf_size_bytes) : 'Private exam attachment'}</p></div></div>
      <p>Open the question paper below. The exam timer continues while you view it.</p>
      <button className="btn pdf-view-button" onClick={refreshPaperUrl}><FileText size={17}/>{showPaper ? 'Refresh question paper link' : 'View Question Paper PDF'}<RefreshCw size={15}/></button>
      {showPaper && paper.signedUrl && <div className="pdf-student-viewer"><div className="row between pdf-viewer-toolbar"><b>Question paper</b><a href={paper.signedUrl} target="_blank" rel="noreferrer"><ExternalLink size={15}/> Open separately</a></div><iframe title="Exam question paper PDF" src={`${paper.signedUrl}#toolbar=1&navpanes=1&zoom=page-width`}/><p className="muted small">Use the PDF viewer controls to navigate pages and zoom. If your mobile browser cannot display the embedded paper, open it separately using the temporary link above.</p></div>}
      <form className="pdf-report-form" onSubmit={reportPaper}><label htmlFor="paper-report">Report a problem with this paper</label><div className="row"><input className="input" id="paper-report" minLength="5" maxLength="1000" required value={reportReason} onChange={event => setReportReason(event.target.value)} placeholder="Describe the issue"/><button className="btn secondary">Report</button></div>{reportMessage && <p className="muted small">{reportMessage}</p>}</form>
      <button className="btn" disabled={busy} onClick={submit}>{busy ? 'Submitting...' : 'Submit exam'}</button>
    </section> : <div className="exam-questions">
      {exam.questions.map((item, index) => <article className="card" key={item.id}>
        <div className="row between"><span className="badge">QUESTION {index + 1} / {exam.questions.length}</span><span className="muted small">{item.points} points</span></div>
        <h3>{item.prompt}</h3>{item.description && <p className="muted small">{item.description}</p>}
        {item.options.map((option, optionIndex) => <label key={optionIndex} className={`question-option ${answers[item.id] === optionIndex ? 'selected' : ''}`}><input type="radio" name={item.id} checked={answers[item.id] === optionIndex} onChange={() => setAnswers(current => ({ ...current, [item.id]: optionIndex }))}/><span>{option}</span></label>)}
      </article>)}
      {!exam.questions.length && <div className="notice">This exam has no questions yet. Contact the teacher.</div>}
      <button className="btn" disabled={busy || !exam.questions.length} onClick={() => { if (confirm('Submit your answers now?')) submit() }}>{busy ? 'Submitting...' : 'Submit exam'}</button>
    </div>}
  </>
}

function CompletionCard({ title, message, onBack }) {
  return <div className="card exam-completion"><CheckCircle2 size={44} color="#43a36a"/><h2>{title}</h2><p className="muted">{message}</p><button className="btn" onClick={onBack}>Back to exam library</button></div>
}
