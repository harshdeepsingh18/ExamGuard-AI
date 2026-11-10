import { useEffect, useState } from 'react'
import { supabase, configured } from '../lib/supabase'
import { formatFileSize } from '../lib/examPapers'

export function Admin() {
  const [profiles, setProfiles] = useState([])
  const [requests, setRequests] = useState([])
  const [exams, setExams] = useState([])
  const [results, setResults] = useState([])
  const [reports, setReports] = useState([])
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)

  const load = async () => {
    const [profileRows, teacherRequests, examRows, resultRows, reportRows] = await Promise.all([
      supabase.from('profiles').select('id,full_name,role,teacher_status,created_at').order('created_at', { ascending: false }).limit(200),
      supabase.from('teacher_requests').select('id,user_id,status,created_at,profile:profiles!teacher_requests_user_id_fkey(full_name)').eq('status', 'pending').order('created_at'),
      supabase.from('exams').select('id,title,exam_type,pdf_filename,pdf_size_bytes,pdf_storage_path,pdf_enabled,published,teacher:profiles!exams_teacher_id_fkey(full_name)').order('created_at', { ascending: false }).limit(100),
      supabase.from('results').select('id,score,max_score,passed'),
      supabase.from('exam_pdf_reports').select('id,exam_id,reason,status,admin_note,created_at,exam:exams(title,pdf_filename,pdf_size_bytes,pdf_enabled,published),reporter:profiles!exam_pdf_reports_reporter_id_fkey(full_name)').order('created_at', { ascending: false }).limit(100),
    ])
    setProfiles(profileRows.data || [])
    setRequests(teacherRequests.data || [])
    setExams(examRows.data || [])
    setResults(resultRows.data || [])
    setReports(reportRows.data || [])
    setError(profileRows.error?.message || teacherRequests.error?.message || examRows.error?.message || resultRows.error?.message || reportRows.error?.message || '')
    setLoading(false)
  }

  useEffect(() => { if (configured) load(); else setLoading(false) }, [])

  const reviewTeacher = async (requestId, approve) => {
    const { error: reviewError } = await supabase.rpc('review_teacher', { p_request: requestId, p_approve: approve })
    if (reviewError) setError(reviewError.message)
    else await load()
  }

  const setRole = async (id, role) => {
    if (!confirm(`Change this user's role to ${role}?`)) return
    const { error: roleError } = await supabase.from('profiles').update({ role, teacher_status: role === 'teacher' ? 'approved' : 'none' }).eq('id', id)
    if (roleError) setError(roleError.message)
    else await load()
  }

  const updateReport = async (report, status) => {
    const { error: reportError } = await supabase.from('exam_pdf_reports').update({ status, reviewed_at: new Date().toISOString() }).eq('id', report.id)
    if (reportError) setError(reportError.message)
    else await load()
  }

  const setPaperEnabled = async (exam, enabled) => {
    const changes = enabled ? { pdf_enabled: true } : { pdf_enabled: false, published: false }
    const { error: paperError } = await supabase.from('exams').update(changes).eq('id', exam.id)
    if (paperError) setError(paperError.message)
    else {
      setError('')
      await load()
    }
  }

  if (!configured) return <div className="notice">Configure Supabase to view the admin dashboard.</div>
  if (loading) return <div className="center-screen"><div className="spinner"/></div>

  const pdfExams = exams.filter(exam => exam.pdf_storage_path)
  return <>
    {error && <div className="error">{error}</div>}
    <div className="grid stats">
      <Metric label="Registered users" value={profiles.length}/><Metric label="Students" value={profiles.filter(row => row.role === 'student').length}/>
      <Metric label="Teachers" value={profiles.filter(row => row.role === 'teacher').length}/><Metric label="Pending requests" value={requests.length}/>
      <Metric label="Exams" value={exams.length}/><Metric label="Submitted results" value={results.length}/>
      <Metric label="Passing rate" value={results.length ? `${Math.round(100 * results.filter(row => row.passed).length / results.length)}%` : '—'}/>
      <Metric label="PDF papers" value={pdfExams.length}/>
    </div>

    <div className="section-heading"><h2>Teacher access requests</h2></div>
    <div className="card table-wrap"><table><thead><tr><th>Applicant</th><th>Requested</th><th>Actions</th></tr></thead><tbody>{requests.map(request => <tr key={request.id}><td>{request.profile?.full_name || 'Teacher applicant'}</td><td>{new Date(request.created_at).toLocaleDateString()}</td><td><div className="row"><button className="btn" onClick={() => reviewTeacher(request.id, true)}>Approve</button><button className="btn danger" onClick={() => reviewTeacher(request.id, false)}>Reject</button></div></td></tr>)}</tbody></table>{!requests.length && <p className="muted small">No teacher requests need review.</p>}</div>

    <div className="section-heading"><h2>PDF attachment reports</h2><span className="muted small">Storage access stays governed by Storage policies.</span></div>
    <div className="grid">{reports.map(report => <article className="card" key={report.id}>
      <div className="row between"><div><span className={`badge ${report.status === 'pending' ? 'pending' : ''}`}>{report.status}</span><h3>{report.exam?.title || 'Exam removed'}</h3></div><span className="muted small">{new Date(report.created_at).toLocaleString()}</span></div>
      <p>{report.reason}</p><p className="muted small">Reported by {report.reporter?.full_name || 'Student'} · {report.exam?.pdf_filename || 'No current PDF'}{report.exam?.pdf_size_bytes ? ` · ${formatFileSize(report.exam.pdf_size_bytes)}` : ''}</p>
      {report.status === 'pending' && <div className="row pdf-actions"><button className="btn secondary" onClick={() => updateReport(report, 'reviewed')}>Mark reviewed</button><button className="btn ghost" onClick={() => updateReport(report, 'dismissed')}>Dismiss report</button>{report.exam && <button className="btn danger" onClick={() => setPaperEnabled({ id: report.exam_id }, false)}>Disable and unpublish paper</button>}</div>}
    </article>)}{!reports.length && <div className="card muted small">No PDF reports have been submitted.</div>}</div>

    <div className="section-heading"><h2>User management</h2><span className="muted small">Showing latest 200 accounts</span></div>
    <div className="card table-wrap"><table><thead><tr><th>Name</th><th>Role</th><th>Teacher status</th><th>Joined</th><th>Manage</th></tr></thead><tbody>{profiles.map(person => <tr key={person.id}><td>{person.full_name || 'Unnamed account'}</td><td><span className="badge">{person.role}</span></td><td>{person.teacher_status}</td><td>{new Date(person.created_at).toLocaleDateString()}</td><td><select className="input" style={{ padding: 7, width: 125 }} value={person.role} onChange={event => setRole(person.id, event.target.value)}><option value="student">Student</option><option value="teacher">Teacher</option><option value="admin">Admin</option></select></td></tr>)}</tbody></table></div>

    <div className="section-heading"><h2>Exam monitoring</h2></div>
    <div className="card table-wrap"><table><thead><tr><th>Exam</th><th>Teacher</th><th>Format / PDF metadata</th><th>Published</th><th>Attachment access</th></tr></thead><tbody>{exams.map(exam => <tr key={exam.id}><td>{exam.title}</td><td>{exam.teacher?.full_name || 'Teacher'}</td><td>{exam.pdf_filename ? `${exam.pdf_filename} · ${formatFileSize(exam.pdf_size_bytes)}` : exam.exam_type === 'pdf' ? 'PDF missing' : 'Online questions'}</td><td>{exam.published ? 'Yes' : 'No'}</td><td>{exam.pdf_storage_path && <button className={`btn ${exam.pdf_enabled ? 'danger' : 'secondary'}`} onClick={() => setPaperEnabled(exam, !exam.pdf_enabled)}>{exam.pdf_enabled ? 'Disable and unpublish' : 'Enable attachment'}</button>}</td></tr>)}</tbody></table></div>
  </>
}

function Metric({ label, value }) { return <div className="card"><div className="stat-label">{label}</div><div className="stat-value">{value}</div></div> }
