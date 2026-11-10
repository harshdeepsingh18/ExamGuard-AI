import { Navigate, Link } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { useAuth } from '../context/AuthContext'

export function AuthCallback() {
 const { user, profile, loading, error } = useAuth()
 const params = new URLSearchParams(window.location.search)
 const providerError = params.get('error_description') || params.get('error')

 if (user && profile) return <Navigate to="/" replace />
 if (!loading && !user && !providerError) return <Navigate to="/login" replace />

 return <main className="auth-bg"><div className="auth-card card">
  <h1>{providerError || error ? 'Sign-in needs attention' : 'Finishing sign-in…'}</h1>
  {(providerError || error) ? <><div className="error" role="alert">{providerError || error}</div>{user && <button className="btn secondary" onClick={async () => { await supabase.auth.signOut(); window.location.assign('/login') }}>Sign out and try again</button>}<p><Link to="/login">Back to sign in</Link></p></> : <p className="muted">Restoring your Supabase session and loading your profile.</p>}
 </div></main>
}
