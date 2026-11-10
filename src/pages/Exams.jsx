import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { FileText } from 'lucide-react'
import { supabase, configured } from '../lib/supabase'
import { useAuth } from '../context/AuthContext'

export function Exams() {
  const { profile } = useAuth()
  const [exams, setExams] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  useEffect(() => {
    if (!configured) { setLoading(false); return }
    supabase.from('exams').select('id,title,description,exam_type,pdf_filename,pdf_size_bytes,duration_minutes,available_from,available_until,teacher:profiles!exams_teacher_id_fkey(full_name)')
      .eq('published', true).order('created_at', { ascending: false })
      .then(({ data, error: queryError }) => {
        setExams(data || [])
        setError(queryError?.message || '')
        setLoading(false)
      })
  }, [])

  return <>
    <div className="row between"><div><h2 style={{ fontSize: 20, margin: 0 }}>Exam library</h2><p className="muted small">Published exams available for you to take.</p></div>{['teacher','admin'].includes(profile?.role) && <Link className="btn" to="/teacher">Manage your exams</Link>}</div>
    {!configured && <div className="notice">Connect Supabase to browse real published exams.</div>}
    {error && <div className="error">{error}</div>}
    {loading ? <div className="grid exam-library-grid">{[1,2,3].map(item => <div key={item} className="card exam-skeleton"/> )}</div> : exams.length ? <div className="grid exam-library-grid">
      {exams.map(exam => <article className="card" key={exam.id}>
        <div className="row between"><span className="badge">PUBLISHED</span>{exam.exam_type === 'pdf' && <span className="badge pdf-badge"><FileText size={13}/> PDF PAPER</span>}</div>
        <h3>{exam.title}</h3><p className="muted small exam-description">{exam.description || 'A focused practice exam.'}</p>
        {exam.exam_type === 'pdf' && <div className="notice pdf-summary"><FileText size={16}/><span>{exam.pdf_filename || 'Question paper PDF'}</span></div>}
        <div className="row between small muted"><span>{exam.duration_minutes} minutes</span><span>{exam.teacher?.full_name || 'ExamGuard teacher'}</span></div>
        <Link className="btn" style={{ width: '100%', marginTop: 16 }} to={`/exam/${exam.id}`}>Start exam</Link>
      </article>)}
    </div> : <div className="card muted small">{configured ? 'No exams are available right now.' : 'No exam data loaded.'}</div>}
  </>
}
