import { useState } from 'react'
import { Link, Navigate, useNavigate } from 'react-router-dom'
import { Eye, EyeOff, ShieldCheck, Mail, ArrowLeft } from 'lucide-react'
import { configured, supabase } from '../lib/supabase'
import { useAuth } from '../context/AuthContext'

const callbackUrl = () => `${window.location.origin}/auth/callback`

export function AuthPage({ signup = false }) {
 const recovery = new URLSearchParams(window.location.search).get('mode') === 'recovery'
 const [mode, setMode] = useState(signup ? 'signup' : recovery ? 'newpassword' : 'login')
 const [fullName, setFullName] = useState(''), [email, setEmail] = useState(''), [password, setPassword] = useState(''), [confirm, setConfirm] = useState('')
 const [role, setRole] = useState('student'), [terms, setTerms] = useState(false), [show, setShow] = useState(false), [busy, setBusy] = useState(false)
 const [error, setError] = useState(''), [message, setMessage] = useState('')
 const nav = useNavigate(), { user, profile, error: authError } = useAuth()
 if (user && profile && mode !== 'newpassword') return <Navigate to="/" replace />
 const run = async fn => { if (busy) return; setError(''); setMessage(''); setBusy(true); try { await fn() } catch (e) { setError(e.message || 'Something went wrong. Please try again.') } finally { setBusy(false) } }
 const submit = e => {
  e.preventDefault()
  if (!configured) { setError('Supabase is not configured. Set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY in .env.'); return }
  if (['signup', 'newpassword'].includes(mode)) {
   if (password.length < 8) { setError('Use a password with at least 8 characters.'); return }
   if (password !== confirm) { setError('Your passwords do not match.'); return }
  }
  if (mode === 'signup' && !terms) { setError('Please accept the terms to continue.'); return }
  run(async () => {
   if (mode === 'signup') {
    const { data, error: e } = await supabase.auth.signUp({ email, password, options: { data: { full_name: fullName, account_type: role }, emailRedirectTo: callbackUrl() } })
    if (e) throw e
    if (data.session) nav('/')
    else setMessage('Check your inbox to verify your email, then sign in.')
   } else if (mode === 'login') {
    const { error: e } = await supabase.auth.signInWithPassword({ email, password })
    if (e) throw e
    nav('/')
   } else if (mode === 'reset') {
    const { error: e } = await supabase.auth.resetPasswordForEmail(email, { redirectTo: `${window.location.origin}/login?mode=recovery` })
    if (e) throw e
    setMessage('Password reset instructions have been sent if that email is registered.')
   } else {
    const { error: e } = await supabase.auth.updateUser({ password })
    if (e) throw e
    setMode('login'); setPassword(''); setConfirm(''); setMessage('Your password has been updated. Sign in with your new password.')
    window.history.replaceState({}, '', '/login')
   }
  })
 }
 const google = () => run(async () => {
  if (!configured) throw Error('Set Supabase environment variables before continuing.')
  const { error: e } = await supabase.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: callbackUrl() } })
  if (e) throw e
 })
 const heading = mode === 'signup' ? 'Build your confidence.' : mode === 'reset' ? 'Reset your password.' : mode === 'newpassword' ? 'Choose a new password.' : 'Welcome back.'
 return <main className="auth-bg"><div className="auth-card card"><Link to="/" className="brand"><span className="brand-mark"><ShieldCheck size={19} /></span>ExamGuard AI</Link><h1>{heading}</h1><p className="muted small">{mode === 'signup' ? 'One focused session at a time.' : mode === 'newpassword' ? 'Choose a secure password for your account.' : 'Sign in to pick up where you left off.'}</p>
  {!configured && <div className="notice">Supabase setup required: add your project URL and anon key to <code>.env</code>.</div>}{authError && <div className="error" role="alert">{authError}{user && <div style={{ marginTop: 10 }}><button type="button" className="btn secondary" onClick={async () => { await supabase.auth.signOut(); window.location.reload() }}>Clear saved session and sign in again</button></div>}</div>}{error && <div className="error" role="alert">{error}</div>}{message && <div className="success" role="status">{message}</div>}
  {!['reset', 'newpassword'].includes(mode) && <><button className="btn secondary" onClick={google} disabled={busy} style={{ width: '100%', marginTop: 14, background: '#f4f6f4', color: '#37463b' }}>G&nbsp; Continue with Google</button><div className="row" style={{ margin: '20px 0', color: '#9aa49d', fontSize: 11 }}><span style={{ height: 1, background: '#e8eee9', flex: 1 }} /><span>OR WITH EMAIL</span><span style={{ height: 1, background: '#e8eee9', flex: 1 }} /></div></>}
  <form onSubmit={submit}>
   {mode === 'signup' && <><Field label="Full name"><input className="input" autoComplete="name" required value={fullName} onChange={e => setFullName(e.target.value)} placeholder="Your name" /></Field><Field label="I am joining as"><select className="input" value={role} onChange={e => setRole(e.target.value)}><option value="student">Student</option><option value="teacher">Teacher (approval required)</option></select></Field></>}
   {!['newpassword'].includes(mode) && <Field label="Email address"><input className="input" type="email" autoComplete="email" required value={email} onChange={e => setEmail(e.target.value)} placeholder="you@example.com" /></Field>}
   {mode !== 'reset' && <><Field label={mode === 'newpassword' ? 'New password' : 'Password'}><div style={{ position: 'relative' }}><input className="input" style={{ paddingRight: 42 }} type={show ? 'text' : 'password'} autoComplete={mode === 'login' ? 'current-password' : 'new-password'} required value={password} onChange={e => setPassword(e.target.value)} placeholder="At least 8 characters" /><button type="button" className="btn ghost" aria-label={show ? 'Hide password' : 'Show password'} onClick={() => setShow(!show)} style={{ position: 'absolute', right: 3, top: 3, padding: 9 }}>{show ? <EyeOff size={16} /> : <Eye size={16} />}</button></div></Field>
    {['signup', 'newpassword'].includes(mode) && <Field label="Confirm password"><input className="input" type={show ? 'text' : 'password'} autoComplete="new-password" required value={confirm} onChange={e => setConfirm(e.target.value)} placeholder="Re-enter password" /></Field>}
    {mode === 'signup' && <label className="row small muted" style={{ alignItems: 'flex-start' }}><input type="checkbox" checked={terms} onChange={e => setTerms(e.target.checked)} />I agree to the terms and privacy policy.</label>}
   </>}
   {mode === 'login' && <div style={{ textAlign: 'right', marginTop: -5 }}><button type="button" className="btn ghost small" style={{ padding: 4 }} onClick={() => setMode('reset')}>Forgot password?</button></div>}
   <button className="btn" disabled={busy} style={{ width: '100%', marginTop: 18 }}>{busy ? 'Please wait…' : mode === 'signup' ? 'Create account' : mode === 'reset' ? 'Send reset link' : mode === 'newpassword' ? 'Update password' : 'Sign in'}</button>
  </form>
  <p className="small muted" style={{ textAlign: 'center', marginTop: 20 }}>{mode === 'reset' || mode === 'newpassword' ? <button className="btn ghost" onClick={() => setMode('login')}><ArrowLeft size={14} /> Back to sign in</button> : mode === 'signup' ? <>Already registered? <button className="btn ghost small" onClick={() => setMode('login')}>Sign in</button></> : <>New to ExamGuard? <button className="btn ghost small" onClick={() => setMode('signup')}>Create account</button></>}</p>
  <div className="muted" style={{ textAlign: 'center', fontSize: 10, marginTop: 10 }}><Mail size={12} style={{ verticalAlign: 'middle', marginRight: 5 }} />Secure sign-in, powered by Supabase</div>
 </div></main>
}
function Field({ label, children }) { return <div className="field"><label>{label}</label>{children}</div> }
