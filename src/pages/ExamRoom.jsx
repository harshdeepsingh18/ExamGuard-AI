import { useCallback, useEffect, useState } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { Clock3, CheckCircle2 } from 'lucide-react'
import { configured, supabase } from '../lib/supabase'

export function ExamRoom() {
 const { id } = useParams(), navigate = useNavigate()
 const [exam, setExam] = useState(null), [answers, setAnswers] = useState({}), [seconds, setSeconds] = useState(null)
 const [loading, setLoading] = useState(true), [busy, setBusy] = useState(false), [error, setError] = useState(''), [result, setResult] = useState(null), [expired, setExpired] = useState(false)
 useEffect(() => {
  if (!configured) { setError('Connect Supabase before starting an exam.'); setLoading(false); return }
  let active = true
  supabase.rpc('start_exam', { p_exam: id }).then(({ data, error: e }) => {
   if (!active) return
   if (e) setError(e.message)
   else { setExam(data); setAnswers(Object.fromEntries((data.saved_answers || []).map(a => [a.question_id, a.selected_answer]))); const elapsed = Math.floor((Date.now() - new Date(data.attempt_started_at).getTime()) / 1000); setSeconds(Math.max(0, data.exam.duration_minutes * 60 - elapsed)) }
   setLoading(false)
  })
  return () => { active = false }
 }, [id])
 const submit = useCallback(async () => {
  if (busy || expired || !exam || !configured) return
  setBusy(true)
  const p_answers = Object.entries(answers).map(([question_id, selected_answer]) => ({ question_id, selected_answer }))
  const { data, error: e } = await supabase.rpc('submit_exam', { p_attempt: exam.attempt_id, p_answers })
  setBusy(false)
  if (e) setError(e.message)
  else if (data?.expired) setExpired(true)
  else setResult(data)
 }, [answers, busy, expired, exam])
 useEffect(() => {
  if (!exam || !Object.keys(answers).length || result || expired || !configured) return
  const timer = setTimeout(() => {
   const p_answers = Object.entries(answers).map(([question_id, selected_answer]) => ({ question_id, selected_answer }))
   supabase.rpc('save_exam_answers', { p_attempt: exam.attempt_id, p_answers }).then(({ error: e }) => { if (e) setError(e.message) })
  }, 350)
  return () => clearTimeout(timer)
 }, [answers, exam, expired, result])
 useEffect(() => {
  if (seconds === null || result || expired) return
  const timer = setInterval(() => setSeconds(value => value <= 1 ? 0 : value - 1), 1000)
  return () => clearInterval(timer)
 }, [seconds, result, expired])
 useEffect(() => { if (seconds === 0 && !busy && !result && !expired) submit() }, [seconds, busy, result, expired, submit])
 if (loading) return <div className="center-screen"><div className="spinner" /></div>
 if (error && !exam) return <div className="card"><div className="error">{error}</div><button className="btn secondary" onClick={() => navigate('/exams')}>Back to exams</button></div>
 if (expired) return <div className="card" style={{ maxWidth: 650, margin: '30px auto', textAlign: 'center', padding: 36 }}><Clock3 size={44} /><h2>Time is up</h2><p className="muted">Your attempt was marked as expired.</p><button className="btn" onClick={() => navigate('/exams')}>Back to exam library</button></div>
 if (result) return <div className="card" style={{ maxWidth: 650, margin: '30px auto', textAlign: 'center', padding: 36 }}><CheckCircle2 size={44} color="#43a36a" /><div className="badge" style={{ marginTop: 14 }}>{result.passed ? 'PASSED' : 'RESULT'}</div><h2>{exam.exam.title}</h2><div style={{ font: '800 42px Manrope', margin: '24px 0' }}>{result.score}<span className="muted" style={{ fontSize: 18 }}> / {result.max_score}</span></div><p className="muted">{result.passed ? 'Great work. Your result has been saved.' : 'Your result has been saved. Keep practicing and try again.'}</p><button className="btn" onClick={() => navigate('/exams')}>Back to exam library</button></div>
 return <><div className="row between"><div><div className="badge">EXAM IN PROGRESS</div><h2 style={{ marginBottom: 4 }}>{exam.exam.title}</h2><p className="muted small">{exam.exam.description}</p></div><div className="badge" style={{ fontSize: 14, padding: '10px 13px' }}><Clock3 size={15} style={{ marginRight: 7 }} />{Math.floor(seconds / 60)}:{String(seconds % 60).padStart(2, '0')}</div></div>{error && <div className="error">{error}</div>}<div style={{ maxWidth: 850 }}>{exam.questions.map((q, i) => <div className="card" key={q.id} style={{ margin: '16px 0' }}><div className="row between"><span className="badge">QUESTION {i + 1} / {exam.questions.length}</span><span className="muted small">{q.points} points</span></div><h3 style={{ fontSize: 17 }}>{q.prompt}</h3>{q.description && <p className="muted small">{q.description}</p>}{q.options.map((option, j) => <label key={j} className={`question-option ${answers[q.id] === j ? 'selected' : ''}`}><input type="radio" name={q.id} checked={answers[q.id] === j} onChange={() => setAnswers(value => ({ ...value, [q.id]: j }))} /><span>{option}</span></label>)}</div>)}{exam.questions.length === 0 && <div className="notice">This exam has no questions yet. Contact the teacher.</div>}<button className="btn" disabled={busy || !exam.questions.length} onClick={() => { if (confirm('Submit your answers now?')) submit() }}>{busy ? 'Submitting...' : 'Submit exam'}</button></div></>
}


