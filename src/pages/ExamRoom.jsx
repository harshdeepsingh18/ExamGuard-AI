import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { Camera, CheckCircle2, Clock3, ExternalLink, FileText, RefreshCw, ShieldAlert } from 'lucide-react'
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
  const [monitorWarnings, setMonitorWarnings] = useState(0)
  const [cameraStatus, setCameraStatus] = useState('Not started')
  const [cameraStream, setCameraStream] = useState(null)
  const videoRef = useRef(null)
  const lastEventRef = useRef({})
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
      setAnswers(Object.fromEntries((data.saved_answers || []).map(answer => [answer.question_id, answer.answer_text ?? answer.selected_answer])))
      const elapsed = Math.floor((Date.now() - new Date(data.attempt_started_at).getTime()) / 1000)
      setSeconds(Math.max(0, data.exam.duration_minutes * 60 - elapsed))
      setLoading(false)
    }
    openExam()
    return () => { active = false }
  }, [id])

  const submit = useCallback(async (confirmPdf = true) => {
    if (busy || expired || submitted || !exam || !configured) return
    if (paper?.exam_type === 'pdf' && confirmPdf && !confirm('Finish and submit this PDF exam?')) return
    setBusy(true)
    const p_answers = Object.entries(answers).map(([question_id, answer]) => typeof answer === 'number' ? ({ question_id, selected_answer: answer }) : ({ question_id, answer_text: answer }))
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
      const p_answers = Object.entries(answers).map(([question_id, answer]) => typeof answer === 'number' ? ({ question_id, selected_answer: answer }) : ({ question_id, answer_text: answer }))
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

  const recordMonitoringEvent = useCallback(async (eventType, metadata = {}) => {
    if (!exam?.attempt_id || !exam.exam.monitoring_enabled) return
    const now = Date.now()
    if (now - (lastEventRef.current[eventType] || 0) < 4000) return
    lastEventRef.current[eventType] = now
    setMonitorWarnings(value => value + 1)
    const { error: eventError } = await supabase.from('exam_monitoring_events').insert({ attempt_id: exam.attempt_id, student_id: profile.id, event_type: eventType, metadata })
    if (eventError) setError(`Monitoring event could not be saved: ${eventError.message}`)
  }, [exam, profile?.id])

  useEffect(() => {
    if (!timerActive || !exam?.exam.monitoring_enabled) return
    const onVisibility = () => { if (document.visibilityState === 'hidden') recordMonitoringEvent('tab_hidden') }
    const onBlur = () => recordMonitoringEvent('window_blur')
    document.addEventListener('visibilitychange', onVisibility)
    window.addEventListener('blur', onBlur)
    return () => { document.removeEventListener('visibilitychange', onVisibility); window.removeEventListener('blur', onBlur) }
  }, [timerActive, exam?.exam.monitoring_enabled, recordMonitoringEvent])

  const startCamera = async () => {
    if (!navigator.mediaDevices?.getUserMedia) {
      setCameraStatus('This browser does not support camera access')
      await recordMonitoringEvent('camera_unsupported')
      return
    }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ video: true, audio: false })
      setCameraStream(stream)
      setCameraStatus('Camera on · local preview only')
      await recordMonitoringEvent('camera_started')
    } catch {
      setCameraStatus('Camera permission denied or unavailable')
      await recordMonitoringEvent('camera_denied')
    }
  }

  const stopCamera = async () => {
    cameraStream?.getTracks().forEach(track => track.stop())
    setCameraStream(null)
    setCameraStatus('Camera off')
    await recordMonitoringEvent('camera_stopped')
  }

  useEffect(() => {
    if (!cameraStream || !timerActive) return
    const video = videoRef.current
    if (video) video.srcObject = cameraStream
    if (!('FaceDetector' in window)) { setCameraStatus('Camera on · face checks are unsupported in this browser'); return }
    let active = true
    const detector = new window.FaceDetector({ fastMode: true, maxDetectedFaces: 3 })
    const checkFaces = async () => {
      if (!active || video?.readyState < 2) return
      try {
        const faces = await detector.detect(video)
        if (faces.length === 0) await recordMonitoringEvent('face_absent')
        if (faces.length > 1) await recordMonitoringEvent('multiple_people', { visible_face_count: Math.min(faces.length, 3) })
      } catch { setCameraStatus('Camera on · face checks are unavailable') }
    }
    const timer = setInterval(checkFaces, 10000)
    return () => { active = false; clearInterval(timer) }
  }, [cameraStream, timerActive, recordMonitoringEvent])

  useEffect(() => {
    if (timerActive || !cameraStream) return
    cameraStream.getTracks().forEach(track => track.stop())
    setCameraStream(null)
    setCameraStatus('Camera off')
  }, [timerActive, cameraStream])

  useEffect(() => () => cameraStream?.getTracks().forEach(track => track.stop()), [cameraStream])

  useEffect(() => {
    if (seconds === 0 && !busy && !result && !expired && !submitted) submit(false)
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
  if (result) return <CompletionCard title="Exam submitted" message={result.review_required ? 'Your answers are submitted. Descriptive answers need teacher review before the final result is published.' : 'Your answers are submitted. The teacher will publish your result when it is ready.'} onBack={() => navigate('/exams')}/>

  const pdfOnly = paper?.exam_type === 'pdf'
  return <>
    <header className="exam-room-header">
      <div><div className="badge">EXAM IN PROGRESS</div><h2>{exam.exam.title}</h2><p className="muted small">{exam.exam.description}</p></div>
      <div className="exam-clock"><Clock3 size={17}/><span>{Math.floor(seconds / 60)}:{String(seconds % 60).padStart(2, '0')}</span></div>
    </header>
    {error && <div className="error">{error}</div>}

    {exam.exam.monitoring_enabled && <section className="notice monitoring-notice">
      <div className="row between"><div className="row"><ShieldAlert size={19}/><div><b>Exam monitoring is on</b><div className="small">We record when this tab is hidden, the window loses focus, and any optional camera status or face-count flags. These signals are for teacher review and do not automatically determine misconduct or your result.</div></div></div><span className="badge">{monitorWarnings} events</span></div>
      <div className="row between monitoring-camera-row"><div><b><Camera size={15}/> Camera: {cameraStatus}</b><div className="small">No video is recorded or uploaded. Camera permission is optional and requested only if you choose to start it{exam.exam.camera_required ? ' (your teacher requested it)' : ''}.</div></div>{cameraStream ? <button type="button" className="btn secondary" onClick={stopCamera}>Turn camera off</button> : <button type="button" className="btn secondary" onClick={startCamera}>Give permission and start camera</button>}</div>
      {cameraStream && <video ref={videoRef} autoPlay playsInline muted className="monitor-camera-preview" aria-label="Local camera preview"/>}
    </section>}

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
        {['mcq','true_false'].includes(item.question_type || 'mcq') ? item.options.map((option, optionIndex) => <label key={optionIndex} className={`question-option ${answers[item.id] === optionIndex ? 'selected' : ''}`}><input type="radio" name={item.id} checked={answers[item.id] === optionIndex} onChange={() => setAnswers(current => ({ ...current, [item.id]: optionIndex }))}/><span>{option}</span></label>) : <label className="field"><span>{item.question_type === 'long_answer' ? 'Your answer (long answer)' : item.question_type === 'fill_blank' ? 'Your answer' : 'Your answer (short answer)'}</span><textarea className="input" rows={item.question_type === 'long_answer' ? 8 : 3} maxLength={10000} value={answers[item.id] || ''} onChange={event => setAnswers(current => ({ ...current, [item.id]: event.target.value }))}/></label>}
      </article>)}
      {!exam.questions.length && <div className="notice">This exam has no questions yet. Contact the teacher.</div>}
      <button className="btn" disabled={busy || !exam.questions.length} onClick={() => { if (confirm('Submit your answers now?')) submit() }}>{busy ? 'Submitting...' : 'Submit exam'}</button>
    </div>}
  </>
}

function CompletionCard({ title, message, onBack }) {
  return <div className="card exam-completion"><CheckCircle2 size={44} color="#43a36a"/><h2>{title}</h2><p className="muted">{message}</p><button className="btn" onClick={onBack}>Back to exam library</button></div>
}
