import { createContext, useContext, useEffect, useState } from 'react'
import { supabase, configured } from '../lib/supabase'

const AuthContext = createContext(null)
const PROFILE_FIELDS = 'id,full_name,role,teacher_status'

export function AuthProvider({ children }) {
 const [session, setSession] = useState(null)
 const [profile, setProfile] = useState(null)
 const [loading, setLoading] = useState(configured)
 const [error, setError] = useState('')

 // Supabase emits INITIAL_SESSION after restoring storage and processing OAuth
 // callback URLs. Subscribe once and keep this callback synchronous.
 useEffect(() => {
  if (!configured) { setLoading(false); return }
  const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, nextSession) => {
   setSession(nextSession)
   setError('')
   if (!nextSession) {
    setProfile(null)
    setLoading(false)
   } else {
    setLoading(true)
   }
  })
  return () => subscription.unsubscribe()
 }, [])

 // The database trigger creates this row in the same transaction as auth.users.
 // The client only reads it; it never attempts to manufacture a missing profile.
 useEffect(() => {
  let active = true
  if (!session?.user) {
   setProfile(null)
   if (configured) setLoading(false)
   return () => { active = false }
  }
  setProfile(null)
  setLoading(true)
  supabase.from('profiles').select(PROFILE_FIELDS).eq('id', session.user.id).maybeSingle()
   .then(({ data, error: queryError }) => {
    if (!active) return
    if (queryError) throw queryError
    if (!data) throw new Error('Your account was created, but its profile is missing. Apply the fresh auth migration in Supabase, then sign out and create the account again.')
    setProfile(data)
    setError('')
   })
   .catch(e => {
    if (active) {
     setProfile(null)
     setError(e.message || 'Could not load your profile.')
    }
   })
   .finally(() => { if (active) setLoading(false) })
  return () => { active = false }
 }, [session])

 const refreshProfile = async () => {
  if (!session?.user) return
  const { data, error: queryError } = await supabase.from('profiles').select(PROFILE_FIELDS).eq('id', session.user.id).single()
  if (queryError) { setError(queryError.message); return }
  setProfile(data)
  setError('')
 }

 return <AuthContext.Provider value={{ session, user: session?.user, profile, loading, error, setError, refreshProfile }}>{children}</AuthContext.Provider>
}

export const useAuth = () => useContext(AuthContext)
