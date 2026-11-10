import { Navigate, Outlet } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'

export function ProtectedRoute({ roles }) {
 const { user, profile, loading, error } = useAuth()
 if (loading) return <div className="center-screen"><div className="spinner" /></div>
 if (!user) return <Navigate to="/login" replace />
 if (!profile) return <div className="center-screen"><div className="notice">{error || 'Your profile is missing. Apply the latest Supabase migrations, then sign out and back in.'}</div></div>
 if (roles && !roles.includes(profile.role)) return <Navigate to="/" replace />
 if (profile.role === 'teacher' && profile.teacher_status !== 'approved') return <Navigate to="/teacher-pending" replace />
 return <Outlet />
}
